defmodule SymphonyElixir.Orchestrator.FleetPause do
  @moduledoc false

  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Orchestrator.Dispatch

  @min_fleet_pause_ms 1_000

  @doc false
  def fleet_paused?(%State{fleet_paused_until: nil}), do: false

  def fleet_paused?(%State{fleet_paused_until: %DateTime{} = paused_until}) do
    DateTime.compare(DateTime.utc_now(), paused_until) == :lt
  end

  @doc false
  def classify_fleet_error(%State{} = state, _issue_id, %{event: event} = update) do
    error_type = extract_error_type(update)
    is_global = extract_is_global(update)

    cond do
      error_type == "usage_cap" and is_global == true ->
        retry_after_ms = parse_retry_after(update)

        trigger_fleet_pause(
          state,
          "Global usage cap reached",
          retry_after_ms
        )

      error_type == "rate_limit" ->
        state
        |> increment_consecutive_limit_failures()
        |> maybe_trigger_pattern_fleet_pause()

      event in [:turn_completed, "turn/completed"] ->
        reset_consecutive_limit_failures(state)

      true ->
        state
    end
  end

  @doc false
  def trigger_fleet_pause(%State{} = state, reason, retry_after_ms) do
    default_ms = Config.fleet_pause_default_ms()
    max_ms = Config.fleet_pause_max_ms()
    pause_ms = (retry_after_ms || default_ms) |> max(@min_fleet_pause_ms) |> min(max_ms)
    paused_until = DateTime.add(DateTime.utc_now(), pause_ms, :millisecond)
    attempt = state.fleet_pause_attempt + 1

    Logger.warning("Fleet paused: #{reason}. Resuming at #{DateTime.to_iso8601(paused_until)} (attempt #{attempt})")

    Process.send_after(self(), :fleet_pause_expired, pause_ms)

    %{
      state
      | fleet_paused_until: paused_until,
        fleet_pause_reason: reason,
        fleet_pause_attempt: attempt,
        fleet_probe_active: false,
        fleet_probe_started_at: nil
    }
  end

  @doc false
  def clear_fleet_pause(%State{} = state) do
    Logger.info("Fleet resumed: probe succeeded, clearing fleet pause")

    %{
      state
      | fleet_paused_until: nil,
        fleet_pause_reason: nil,
        fleet_pause_attempt: 0,
        fleet_probe_active: false,
        fleet_probe_started_at: nil,
        consecutive_limit_failures: 0,
        last_limit_failure_at: nil
    }
  end

  @doc false
  def extend_fleet_pause(%State{} = state) do
    default_ms = Config.fleet_pause_default_ms()
    max_ms = Config.fleet_pause_max_ms()
    attempt = state.fleet_pause_attempt
    extension_ms = min(default_ms * (1 <<< min(attempt, 10)), max_ms)

    Logger.warning("Fleet probe failed; extending pause by #{div(extension_ms, 60_000)} minutes (attempt #{attempt + 1})")

    trigger_fleet_pause(state, "Probe failed, extending pause", extension_ms)
  end

  @doc false
  def increment_consecutive_limit_failures(%State{} = state) do
    %{
      state
      | consecutive_limit_failures: state.consecutive_limit_failures + 1,
        last_limit_failure_at: DateTime.utc_now()
    }
  end

  @doc false
  def reset_consecutive_limit_failures(%State{} = state) do
    %{state | consecutive_limit_failures: 0, last_limit_failure_at: nil}
  end

  @doc false
  def maybe_trigger_pattern_fleet_pause(%State{} = state) do
    threshold = Config.fleet_pause_pattern_threshold()
    window_ms = Config.fleet_pause_pattern_window_ms()

    cond do
      state.consecutive_limit_failures < threshold ->
        state

      is_nil(state.last_limit_failure_at) ->
        state

      true ->
        elapsed_ms = DateTime.diff(DateTime.utc_now(), state.last_limit_failure_at, :millisecond)

        if elapsed_ms <= window_ms do
          trigger_fleet_pause(state, "Pattern detection: #{state.consecutive_limit_failures} failures within #{div(window_ms, 1000)}s", nil)
        else
          reset_consecutive_limit_failures(state)
        end
    end
  end

  @doc false
  def parse_retry_after(update) when is_map(update) do
    raw =
      Map.get(update, :retry_after) ||
        Map.get(update, "retry_after") ||
        get_in_fleet(update, [:payload, :retry_after]) ||
        get_in_fleet(update, [:payload, "retry_after"]) ||
        get_in_fleet(update, ["payload", "retry_after"])

    parse_retry_after_value(raw)
  end

  def parse_retry_after(_), do: nil

  @doc false
  def dispatch_probe_agent(%State{} = state) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} when issues != [] ->
        probe_issue = select_probe_candidate(issues, state)

        if probe_issue do
          Logger.info("Dispatching probe agent for #{issue_context(probe_issue)}")
          do_dispatch_probe(state, probe_issue)
        else
          Logger.warning("No candidate issues for fleet probe; rescheduling")
          reschedule_fleet_probe(state)
        end

      _ ->
        Logger.warning("Could not fetch issues for fleet probe; rescheduling")
        reschedule_fleet_probe(state)
    end
  end

  @doc false
  def select_probe_candidate(issues, %State{running: running, claimed: claimed}) do
    issues
    |> Enum.reject(fn issue ->
      Map.has_key?(running, issue.id) or Map.has_key?(claimed, issue.id)
    end)
    |> Dispatch.sort_issues_for_dispatch()
    |> List.last()
  end

  @doc false
  def probe_stalled?(%State{fleet_probe_started_at: nil}, _timeout_ms), do: true

  def probe_stalled?(%State{fleet_probe_started_at: started_at}, timeout_ms) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond) >= timeout_ms
  end

  @doc false
  def force_kill_stalled_probe(%State{running: running} = state) do
    case Enum.find(running, fn {_id, entry} -> Map.get(entry, :is_fleet_probe, false) end) do
      {issue_id, %{pid: pid, ref: ref}} ->
        if is_pid(pid), do: terminate_task(pid)
        if is_reference(ref), do: Process.demonitor(ref, [:flush])

        %{
          state
          | running: Map.delete(running, issue_id),
            fleet_probe_active: false,
            fleet_probe_started_at: nil
        }

      nil ->
        %{state | fleet_probe_active: false, fleet_probe_started_at: nil}
    end
  end

  @doc false
  def reschedule_fleet_probe(%State{} = state) do
    Process.send_after(self(), :fleet_pause_expired, 60_000)
    state
  end

  # --- Private helpers ---

  defp extract_error_type(%{error_type: error_type}) when is_binary(error_type), do: error_type

  defp extract_error_type(update) when is_map(update) do
    Map.get(update, "error_type") ||
      get_in_fleet(update, [:payload, :error_type]) ||
      get_in_fleet(update, [:payload, "error_type"]) ||
      get_in_fleet(update, ["payload", "error_type"])
  end

  defp extract_error_type(_), do: nil

  defp extract_is_global(%{is_global: is_global}) when is_boolean(is_global), do: is_global

  defp extract_is_global(update) when is_map(update) do
    Map.get(update, "is_global") ||
      get_in_fleet(update, [:payload, :is_global]) ||
      get_in_fleet(update, [:payload, "is_global"]) ||
      get_in_fleet(update, ["payload", "is_global"])
  end

  defp extract_is_global(_), do: nil

  defp get_in_fleet(update, keys) when is_map(update) and is_list(keys) do
    Enum.reduce_while(keys, update, fn key, acc ->
      if is_map(acc), do: {:cont, Map.get(acc, key)}, else: {:halt, nil}
    end)
  end

  defp parse_retry_after_value(ms) when is_integer(ms) and ms > 0, do: ms

  defp parse_retry_after_value(value) when is_binary(value) do
    trimmed = String.trim(String.downcase(value))

    cond do
      String.contains?(trimmed, "hour") ->
        case Integer.parse(trimmed) do
          {n, _} when n > 0 -> n * 3_600_000
          _ -> nil
        end

      String.contains?(trimmed, "minute") or String.contains?(trimmed, "min") ->
        case Integer.parse(trimmed) do
          {n, _} when n > 0 -> n * 60_000
          _ -> nil
        end

      String.contains?(trimmed, "second") or String.contains?(trimmed, "sec") ->
        case Integer.parse(trimmed) do
          {n, _} when n > 0 -> n * 1_000
          _ -> nil
        end

      true ->
        case Integer.parse(trimmed) do
          {n, _} when n > 0 -> n
          _ -> nil
        end
    end
  end

  defp parse_retry_after_value(_), do: nil

  defp do_dispatch_probe(%State{} = state, issue) do
    recipient = self()

    case SymphonyElixir.AgentSupervisor.start_agent(fn ->
           AgentRunner.run(issue, recipient, attempt: nil)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Probe agent dispatched: #{issue_context(issue)} pid=#{inspect(pid)}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: nil,
            agent_app_server_pid: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: 0,
            started_at: DateTime.utc_now(),
            is_fleet_probe: true,
            otel_input_tokens: 0,
            otel_output_tokens: 0,
            otel_cache_read_tokens: 0,
            otel_cache_creation_tokens: 0,
            otel_cost_usd: 0.0,
            otel_tool_calls: 0,
            otel_tool_duration_total_ms: 0,
            otel_tool_errors: 0,
            otel_api_errors: 0,
            otel_lines_changed: 0,
            otel_commits_count: 0,
            otel_prs_count: 0,
            otel_active_time_seconds: 0
          })

        %{
          state
          | running: running,
            claimed: Map.put(state.claimed, issue.id, DateTime.utc_now()),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            fleet_probe_active: true,
            fleet_probe_started_at: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.error("Failed to spawn probe agent: #{inspect(reason)}")
        reschedule_fleet_probe(state)
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp terminate_task(pid) when is_pid(pid) do
    case SymphonyElixir.AgentSupervisor.stop_agent(pid) do
      :ok -> :ok
      {:error, :not_found} -> Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok
end
