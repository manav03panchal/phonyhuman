defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{Dispatch, FleetPause, Reconciliation, TokenAccounting}

  # Default timeout for GenServer.call operations (e.g. refresh, fleet control).
  # Matches the snapshot default; avoids the 5 s default under heavy load.
  @call_timeout 15_000
  # 24 hours — entries older than this are pruned from completed/claimed maps.
  @completed_ttl_ms 24 * 60 * 60 * 1_000
  @claimed_ttl_ms 24 * 60 * 60 * 1_000
  # Extra time beyond shutdown_timeout_ms to allow force-kill and cleanup
  # before the supervisor gives up and brutally kills the process.
  @shutdown_safety_margin_ms 5_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0,
    cache_read_tokens: 0,
    cache_creation_tokens: 0,
    cost_usd: 0.0,
    model: nil,
    tool_calls: 0,
    tool_duration_total_ms: 0,
    tool_errors: 0,
    api_errors: 0,
    lines_changed: 0,
    commits_count: 0,
    prs_count: 0,
    active_time_seconds: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      running: %{},
      completed: %{},
      claimed: %{},
      retry_attempts: %{},
      agent_totals: nil,
      agent_rate_limits: nil,
      fleet_paused_until: nil,
      fleet_pause_reason: nil,
      fleet_pause_attempt: 0,
      fleet_probe_active: false,
      fleet_probe_started_at: nil,
      consecutive_limit_failures: 0,
      last_limit_failure_at: nil
    ]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Config.shutdown_timeout_ms() + @shutdown_safety_margin_ms
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  # --- GenServer handle_info callbacks ---

  @impl true
  def handle_info(:tick, state) do
    if shutting_down?() do
      {:noreply, state}
    else
      state = refresh_runtime_config(state)
      state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

      notify_dashboard()
      :ok = schedule_poll_cycle_start()
      {:noreply, state}
    end
  end

  def handle_info(:run_poll_cycle, state) do
    if shutting_down?() do
      {:noreply, state}
    else
      state = refresh_runtime_config(state)
      state = maybe_dispatch(state)
      state = prune_stale_entries(state)
      now_ms = System.monotonic_time(:millisecond)
      next_poll_due_at_ms = now_ms + state.poll_interval_ms
      :ok = schedule_tick(state.poll_interval_ms)

      state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_poll_due_at_ms}

      notify_dashboard()
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = TokenAccounting.record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        is_probe = Map.get(running_entry, :is_fleet_probe, false)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state =
                state
                |> Dispatch.complete_issue(issue_id)
                |> Dispatch.schedule_issue_retry(issue_id, 1, %{
                  identifier: running_entry.identifier,
                  delay_type: :continuation
                })
                |> FleetPause.reset_consecutive_limit_failures()

              if is_probe, do: FleetPause.clear_fleet_pause(state), else: state

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              state =
                Dispatch.schedule_issue_retry(state, issue_id, next_attempt, %{
                  identifier: running_entry.identifier,
                  error: "agent exited: #{inspect(reason)}"
                })

              if is_probe, do: FleetPause.extend_fleet_pause(state), else: state
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        if Map.has_key?(state.completed, issue_id) do
          Logger.debug("Late agent_worker_update for completed issue_id=#{issue_id}; applying final token delta")
          dummy_entry = %{agent_last_reported_input_tokens: 0, agent_last_reported_output_tokens: 0, agent_last_reported_total_tokens: 0}
          token_delta = TokenAccounting.extract_token_delta(dummy_entry, update)
          {:noreply, TokenAccounting.apply_agent_token_delta(state, token_delta)}
        else
          {:noreply, state}
        end

      running_entry ->
        {updated_running_entry, token_delta} = TokenAccounting.integrate_agent_update(running_entry, update)

        state =
          state
          |> TokenAccounting.apply_agent_token_delta(token_delta)
          |> TokenAccounting.apply_agent_rate_limits(update)
          |> FleetPause.classify_fleet_error(issue_id, update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id}, state) do
    result = Dispatch.handle_retry(state, issue_id)

    notify_dashboard()
    result
  end

  def handle_info(:fleet_pause_expired, %State{} = state) do
    if FleetPause.fleet_paused?(state) do
      # Timer fired but pause was extended; reschedule
      {:noreply, state}
    else
      if state.fleet_probe_active do
        probe_timeout_ms = Config.fleet_probe_timeout_ms()

        if FleetPause.probe_stalled?(state, probe_timeout_ms) do
          Logger.warning("Fleet probe stalled after #{probe_timeout_ms}ms; force-killing and rescheduling")
          state = FleetPause.force_kill_stalled_probe(state)
          {:noreply, FleetPause.extend_fleet_pause(state)}
        else
          Process.send_after(self(), :fleet_pause_expired, probe_timeout_ms)
          {:noreply, state}
        end
      else
        Logger.info("Fleet pause expired; dispatching probe agent")
        {:noreply, FleetPause.dispatch_probe_agent(state)}
      end
    end
  end

  def handle_info({:otel_metrics, session_id, metrics}, %{running: running} = state)
      when is_binary(session_id) and is_map(metrics) do
    case TokenAccounting.find_issue_id_for_session(running, session_id) do
      nil ->
        Logger.warning("OTel metrics received for unknown session_id=#{session_id}; discarding")
        {:noreply, state}

      issue_id ->
        running_entry = Map.get(running, issue_id)
        updated_entry = TokenAccounting.merge_otel_metrics(running_entry, metrics)
        state = %{state | running: Map.put(running, issue_id, updated_entry)}
        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:otel_metrics, _session_id, _metrics}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Dispatch coordinator ---

  defp maybe_dispatch(%State{} = state) do
    state = Reconciliation.reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- Dispatch.available_slots(state) > 0 do
      Dispatch.choose_issues(issues, state)
    else
      {:error, :circuit_open} ->
        Logger.warning("Linear API circuit breaker is open; skipping poll cycle")
        state

      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, :missing_agent_command} ->
        Logger.error("Agent command missing in WORKFLOW.md")
        state

      {:error, {:invalid_agent_approval_policy, value}} ->
        Logger.error("Invalid agent.approval_policy in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_agent_thread_sandbox, value}} ->
        Logger.error("Invalid agent.thread_sandbox in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_agent_turn_sandbox_policy, reason}} ->
        Logger.error("Invalid agent.turn_sandbox_policy in WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  # --- Test helpers ---

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    Reconciliation.reconcile_running_issue_states(issues, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    Reconciliation.reconcile_running_issue_states(issues, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    Dispatch.should_dispatch_issue?(issue, state, Dispatch.active_state_set(), Dispatch.terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    Dispatch.revalidate_issue_for_dispatch(issue, issue_fetcher, Dispatch.terminal_state_set())
  end

  @doc false
  @spec prune_stale_entries_for_test(term()) :: term()
  def prune_stale_entries_for_test(%State{} = state) do
    prune_stale_entries(state)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    Dispatch.sort_issues_for_dispatch(issues)
  end

  # --- Public API ---

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh, @call_timeout)
    else
      :unavailable
    end
  end

  @spec pause_fleet(String.t() | nil) :: :ok | :unavailable
  def pause_fleet(reason \\ nil), do: pause_fleet(__MODULE__, reason)

  @spec pause_fleet(GenServer.server(), String.t() | nil) :: :ok | :unavailable
  def pause_fleet(server, reason) do
    if Process.whereis(server) do
      GenServer.call(server, {:fleet_pause, reason}, @call_timeout)
    else
      :unavailable
    end
  end

  @spec resume_fleet() :: :ok | :unavailable
  def resume_fleet, do: resume_fleet(__MODULE__)

  @spec resume_fleet(GenServer.server()) :: :ok | :unavailable
  def resume_fleet(server) do
    if Process.whereis(server) do
      GenServer.call(server, :fleet_resume, @call_timeout)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def terminate(_reason, %State{running: running} = state) do
    drain_running_agents(running)
    _ = state
    :ok
  end

  # --- GenServer handle_call callbacks ---

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          title: metadata.issue.title,
          description: metadata.issue.description,
          url: metadata.issue.url,
          labels: SymphonyElixir.Linear.Issue.label_names(metadata.issue),
          state: metadata.issue.state,
          session_id: metadata.session_id,
          agent_app_server_pid: metadata.agent_app_server_pid,
          agent_input_tokens: metadata.agent_input_tokens,
          agent_output_tokens: metadata.agent_output_tokens,
          agent_total_tokens: metadata.agent_total_tokens,
          agent_cache_read_tokens: Map.get(metadata, :agent_cache_read_tokens, 0),
          agent_cache_creation_tokens: Map.get(metadata, :agent_cache_creation_tokens, 0),
          agent_cost_usd: Map.get(metadata, :agent_cost_usd, 0.0),
          agent_model: Map.get(metadata, :agent_model),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_agent_timestamp: metadata.last_agent_timestamp,
          last_agent_message: metadata.last_agent_message,
          last_agent_event: metadata.last_agent_event,
          runtime_seconds: TokenAccounting.running_seconds(metadata.started_at, now),
          otel_input_tokens: Map.get(metadata, :otel_input_tokens, 0),
          otel_output_tokens: Map.get(metadata, :otel_output_tokens, 0),
          otel_cache_read_tokens: Map.get(metadata, :otel_cache_read_tokens, 0),
          otel_cache_creation_tokens: Map.get(metadata, :otel_cache_creation_tokens, 0),
          otel_cost_usd: Map.get(metadata, :otel_cost_usd, 0.0),
          otel_tool_calls: Map.get(metadata, :otel_tool_calls, 0),
          otel_tool_duration_total_ms: Map.get(metadata, :otel_tool_duration_total_ms, 0),
          otel_tool_errors: Map.get(metadata, :otel_tool_errors, 0),
          otel_api_errors: Map.get(metadata, :otel_api_errors, 0),
          otel_lines_changed: Map.get(metadata, :otel_lines_changed, 0),
          otel_commits_count: Map.get(metadata, :otel_commits_count, 0),
          otel_prs_count: Map.get(metadata, :otel_prs_count, 0),
          otel_active_time_seconds: Map.get(metadata, :otel_active_time_seconds, 0)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    fleet_status = if FleetPause.fleet_paused?(state), do: "paused", else: "running"

    fleet_paused_until =
      case state.fleet_paused_until do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        _ -> nil
      end

    {:reply,
     %{
       running: running,
       retrying: retrying,
       agent_totals: state.agent_totals,
       rate_limits: Map.get(state, :agent_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       },
       fleet_status: fleet_status,
       fleet_paused_until: fleet_paused_until,
       fleet_pause_reason: state.fleet_pause_reason
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:fleet_pause, reason}, _from, state) do
    reason = reason || "Manual pause (operator)"
    state = FleetPause.trigger_fleet_pause(state, reason, Config.fleet_pause_default_ms())
    notify_dashboard()
    {:reply, :ok, state}
  end

  def handle_call(:fleet_resume, _from, state) do
    state = FleetPause.clear_fleet_pause(state)
    notify_dashboard()
    {:reply, :ok, state}
  end

  # --- Fleet/token test helpers ---

  @doc false
  @spec fleet_paused_for_test?(State.t()) :: boolean()
  def fleet_paused_for_test?(%State{} = state), do: FleetPause.fleet_paused?(state)

  @doc false
  @spec trigger_fleet_pause_for_test(State.t(), String.t(), integer() | nil) :: State.t()
  def trigger_fleet_pause_for_test(%State{} = state, reason, retry_after_ms),
    do: FleetPause.trigger_fleet_pause(state, reason, retry_after_ms)

  @doc false
  @spec parse_retry_after_for_test(map()) :: integer() | nil
  def parse_retry_after_for_test(update), do: FleetPause.parse_retry_after(update)

  @doc false
  @spec extract_token_delta_for_test(map(), map()) :: map()
  def extract_token_delta_for_test(running_entry, update),
    do: TokenAccounting.extract_token_delta(running_entry, update)

  @doc false
  @spec apply_token_delta_for_test(map(), map()) :: map()
  def apply_token_delta_for_test(agent_totals, token_delta),
    do: TokenAccounting.apply_token_delta(agent_totals, token_delta)

  @doc false
  @spec integrate_agent_update_for_test(map(), map()) :: map()
  def integrate_agent_update_for_test(running_entry, update),
    do: TokenAccounting.integrate_agent_update(running_entry, update)

  @doc false
  @spec select_probe_candidate_for_test([Issue.t()], State.t()) :: Issue.t() | nil
  def select_probe_candidate_for_test(issues, %State{} = state),
    do: FleetPause.select_probe_candidate(issues, state)

  # --- Pruning ---

  defp prune_stale_entries(%State{} = state) do
    now = DateTime.utc_now()

    %{
      state
      | completed: prune_map(state.completed, now, @completed_ttl_ms),
        claimed: prune_claimed(state, now),
        retry_attempts: prune_retry_attempts(state.retry_attempts, now, @completed_ttl_ms)
    }
  end

  defp prune_map(map, now, ttl_ms) when is_map(map) do
    Map.filter(map, fn {_id, inserted_at} ->
      is_struct(inserted_at, DateTime) and DateTime.diff(now, inserted_at, :millisecond) < ttl_ms
    end)
  end

  defp prune_claimed(%State{claimed: claimed, running: running, retry_attempts: retries}, now) do
    Map.filter(claimed, fn {id, inserted_at} ->
      Map.has_key?(running, id) or Map.has_key?(retries, id) or
        (is_struct(inserted_at, DateTime) and DateTime.diff(now, inserted_at, :millisecond) < @claimed_ttl_ms)
    end)
  end

  defp prune_retry_attempts(retry_attempts, now, ttl_ms) when is_map(retry_attempts) do
    Map.filter(retry_attempts, fn {_id, entry} ->
      case Map.get(entry, :last_attempt_at) do
        %DateTime{} = ts -> DateTime.diff(now, ts, :millisecond) < ttl_ms
        _ -> true
      end
    end)
  end

  # --- Scheduling ---

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  # --- State helpers ---

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  # --- Workspace cleanup ---

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    safe_id = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
    workspace = Path.join(Config.workspace_root(), safe_id)

    case Workspace.remove(workspace) do
      {:ok, _} ->
        :ok

      {:error, reason, _} ->
        Logger.warning("Workspace cleanup failed for identifier=#{identifier} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  # --- Shutdown drain logic ---

  defp shutting_down? do
    :persistent_term.get(:symphony_shutting_down, false) == true
  end

  defp terminate_task(pid) when is_pid(pid) do
    case SymphonyElixir.AgentSupervisor.stop_agent(pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp drain_running_agents(running) when map_size(running) == 0 do
    Logger.info("Shutdown: no active agents to drain")
  end

  defp drain_running_agents(running) do
    agent_count = map_size(running)
    timeout_ms = Config.shutdown_timeout_ms()
    Logger.info("Draining #{agent_count} agents (timeout: #{timeout_ms}ms)...")

    refs_to_agents = collect_agent_refs(running)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    remaining = drain_agents(refs_to_agents, deadline)

    force_kill_remaining(remaining)

    force_killed = map_size(remaining)
    finished = agent_count - force_killed

    Logger.info("Shutdown drain complete: #{finished} finished, #{force_killed} force-killed")
  end

  defp collect_agent_refs(running) do
    Enum.reduce(running, %{}, fn {issue_id, entry}, acc ->
      case entry do
        %{ref: ref, pid: pid, identifier: identifier} when is_reference(ref) ->
          Map.put(acc, ref, %{issue_id: issue_id, pid: pid, identifier: identifier})

        _ ->
          acc
      end
    end)
  end

  defp force_kill_remaining(remaining) when map_size(remaining) == 0, do: :ok

  defp force_kill_remaining(remaining) do
    Logger.warning("Timeout: force-killing #{map_size(remaining)} agents")

    Enum.each(remaining, fn {_ref, %{pid: pid, identifier: identifier}} ->
      terminate_task(pid)
      cleanup_issue_workspace(identifier)
    end)
  end

  defp drain_agents(refs_to_agents, _deadline) when map_size(refs_to_agents) == 0,
    do: refs_to_agents

  defp drain_agents(refs_to_agents, deadline) do
    time_left = deadline - System.monotonic_time(:millisecond)

    if time_left <= 0 do
      refs_to_agents
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          case Map.pop(refs_to_agents, ref) do
            {%{identifier: identifier}, rest} ->
              Logger.info("Agent #{identifier} finished during shutdown drain")
              drain_agents(rest, deadline)

            {nil, _} ->
              drain_agents(refs_to_agents, deadline)
          end
      after
        time_left ->
          refs_to_agents
      end
    end
  end
end
