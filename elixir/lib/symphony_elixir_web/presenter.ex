defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          agent_totals: enrich_agent_totals(snapshot.agent_totals),
          rate_limits: snapshot.rate_limits,
          max_agents: Config.max_concurrent_agents(),
          fleet_status: Map.get(snapshot, :fleet_status, "running"),
          fleet_paused_until: Map.get(snapshot, :fleet_paused_until),
          fleet_pause_reason: Map.get(snapshot, :fleet_pause_reason)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        agent_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    tool_executions = Map.get(entry, :otel_tool_executions, [])
    tool_calls = length(tool_executions)

    tool_avg_duration_ms =
      if tool_calls > 0 do
        total_ms = Enum.reduce(tool_executions, 0, fn t, acc -> acc + Map.get(t, :duration_ms, 0) end)
        div(total_ms, tool_calls)
      else
        0
      end

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_message: summarize_message(entry.last_agent_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      model: Map.get(entry, :agent_model),
      tokens: %{
        input_tokens: entry.agent_input_tokens,
        output_tokens: entry.agent_output_tokens,
        total_tokens: entry.agent_total_tokens,
        cache_read_tokens: Map.get(entry, :agent_cache_read_tokens, 0),
        cache_hit_rate: cache_hit_rate(entry.agent_input_tokens, Map.get(entry, :agent_cache_read_tokens, 0)),
        cost_usd: Map.get(entry, :agent_cost_usd, 0)
      },
      lines_changed: Map.get(entry, :otel_lines_changed, 0),
      commits_count: Map.get(entry, :otel_commits_count, 0),
      prs_count: Map.get(entry, :otel_prs_count, 0),
      tool_calls: tool_calls,
      tool_avg_duration_ms: tool_avg_duration_ms,
      api_errors: Map.get(entry, :otel_api_errors, 0),
      active_time_seconds: Map.get(entry, :otel_active_time_seconds, 0)
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      tokens: %{
        input_tokens: running.agent_input_tokens,
        output_tokens: running.agent_output_tokens,
        total_tokens: running.agent_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_agent_timestamp),
        event: running.last_agent_event,
        message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp enrich_agent_totals(totals) do
    enriched =
      Map.merge(
        %{cache_read_tokens: 0, cache_creation_tokens: 0, cost_usd: 0},
        totals
      )

    tool_executions = Map.get(enriched, :tool_executions, [])
    tool_calls = length(tool_executions)

    tool_avg_duration_ms =
      if tool_calls > 0 do
        total_ms = Enum.reduce(tool_executions, 0, fn t, acc -> acc + Map.get(t, :duration_ms, 0) end)
        div(total_ms, tool_calls)
      else
        0
      end

    enriched
    |> Map.put(:cache_hit_rate, cache_hit_rate(enriched.input_tokens, enriched.cache_read_tokens))
    |> Map.put(:lines_changed, Map.get(enriched, :lines_changed, 0))
    |> Map.put(:commits_count, Map.get(enriched, :commits_count, 0))
    |> Map.put(:prs_count, Map.get(enriched, :prs_count, 0))
    |> Map.put(:tool_calls, tool_calls)
    |> Map.put(:tool_avg_duration_ms, tool_avg_duration_ms)
    |> Map.put(:api_errors, Map.get(enriched, :api_errors, 0))
    |> Map.put(:active_time_seconds, Map.get(enriched, :active_time_seconds, 0))
    |> Map.drop([:tool_executions])
  end

  @doc false
  @spec cache_hit_rate(number(), number()) :: float()
  def cache_hit_rate(_input, cache_read) when cache_read == 0, do: 0.0

  def cache_hit_rate(input, cache_read) do
    denominator = input + cache_read

    if denominator == 0 do
      0.0
    else
      cache_read / denominator * 100
    end
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
