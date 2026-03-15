defmodule SymphonyElixir.OrchestratorShutdownTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Orchestrator.State

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
        poll_check_in_progress: false,
        running: %{},
        completed: %{},
        claimed: %{},
        retry_attempts: %{},
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        agent_rate_limits: nil,
        fleet_paused_until: nil,
        fleet_pause_reason: nil,
        fleet_pause_attempt: 0,
        fleet_probe_active: false,
        consecutive_limit_failures: 0,
        last_limit_failure_at: nil
      },
      overrides
    )
  end

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  # Inject a running entry into the orchestrator. The monitor is created inside
  # the orchestrator process so DOWN messages are delivered to the GenServer.
  defp inject_running_entry(pid, issue_id, identifier, task_pid) do
    :sys.replace_state(pid, fn state ->
      ref = Process.monitor(task_pid)

      entry = %{
        pid: task_pid,
        ref: ref,
        identifier: identifier,
        issue: %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Test issue",
          description: "Test",
          state: "In Progress",
          url: "https://example.org/issues/#{identifier}"
        },
        session_id: nil,
        turn_count: 0,
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
        agent_cache_read_tokens: 0,
        agent_cache_creation_tokens: 0,
        agent_cost_usd: 0.0,
        agent_model: nil,
        retry_attempt: 0,
        started_at: DateTime.utc_now(),
        otel_input_tokens: 0,
        otel_output_tokens: 0,
        otel_cache_read_tokens: 0,
        otel_cache_creation_tokens: 0,
        otel_cost_usd: 0.0,
        otel_tool_executions: [],
        otel_api_errors: 0,
        otel_lines_changed: 0,
        otel_commits_count: 0,
        otel_prs_count: 0,
        otel_active_time_seconds: 0
      }

      %{
        state
        | running: Map.put(state.running, issue_id, entry),
          claimed: Map.put(state.claimed, issue_id, DateTime.utc_now())
      }
    end)
  end

  # Gracefully stop the orchestrator, triggering terminate/2 without killing the test process.
  defp graceful_stop(pid, timeout) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> :timeout
    end
  end

  # Spawn a process not linked to the test process.
  defp spawn_unlinked(fun) do
    spawn(fun)
  end

  describe "orchestrator stops polling on shutdown signal" do
    test "tick is ignored when shutting_down flag is set" do
      name = Module.concat(__MODULE__, :TickShutdownOrchestrator)
      pid = start_orchestrator(name)

      :persistent_term.put(:symphony_shutting_down, true)

      on_exit(fn ->
        :persistent_term.put(:symphony_shutting_down, false)
      end)

      initial_state = :sys.get_state(pid)

      send(pid, :tick)
      Process.sleep(50)

      state_after_tick = :sys.get_state(pid)

      # poll_check_in_progress should NOT have changed to true
      assert state_after_tick.poll_check_in_progress == initial_state.poll_check_in_progress
    end

    test "run_poll_cycle is ignored when shutting_down flag is set" do
      name = Module.concat(__MODULE__, :PollShutdownOrchestrator)
      pid = start_orchestrator(name)

      :persistent_term.put(:symphony_shutting_down, true)

      on_exit(fn ->
        :persistent_term.put(:symphony_shutting_down, false)
      end)

      initial_state = :sys.get_state(pid)

      send(pid, :run_poll_cycle)
      Process.sleep(50)

      state_after_poll = :sys.get_state(pid)

      assert map_size(state_after_poll.running) == map_size(initial_state.running)
    end

    test "can_dispatch? returns false when shutting_down flag is set" do
      :persistent_term.put(:symphony_shutting_down, true)

      on_exit(fn ->
        :persistent_term.put(:symphony_shutting_down, false)
      end)

      state = base_state()

      issue = %Issue{
        id: "issue-shutdown-dispatch",
        identifier: "MT-500",
        title: "Test",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-500"
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end
  end

  describe "agents receive stop signal during drain (terminate/2)" do
    setup do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "5000")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      :ok
    end

    test "agents that finish within timeout are drained gracefully" do
      name = Module.concat(__MODULE__, :DrainGracefulOrchestrator)
      pid = start_orchestrator(name)

      task_pid = spawn_unlinked(fn -> Process.sleep(200) end)
      inject_running_entry(pid, "issue-drain-1", "MT-601", task_pid)

      state = :sys.get_state(pid)
      assert map_size(state.running) == 1

      log =
        capture_log(fn ->
          assert graceful_stop(pid, 10_000) == :ok
        end)

      refute Process.alive?(pid)
      assert log =~ "Draining 1 agents"
      assert log =~ "MT-601 finished during shutdown drain"
      assert log =~ "Shutdown drain complete: 1 finished, 0 force-killed"
    end

    test "multiple agents are drained concurrently" do
      name = Module.concat(__MODULE__, :DrainMultipleOrchestrator)
      pid = start_orchestrator(name)

      task1 = spawn_unlinked(fn -> Process.sleep(50) end)
      task2 = spawn_unlinked(fn -> Process.sleep(150) end)

      inject_running_entry(pid, "issue-m1", "MT-701", task1)
      inject_running_entry(pid, "issue-m2", "MT-702", task2)

      state = :sys.get_state(pid)
      assert map_size(state.running) == 2

      log =
        capture_log(fn ->
          assert graceful_stop(pid, 10_000) == :ok
        end)

      refute Process.alive?(pid)
      assert log =~ "Draining 2 agents"
      assert log =~ "Shutdown drain complete: 2 finished, 0 force-killed"
    end
  end

  describe "timeout-based force termination" do
    test "agents exceeding timeout are force-killed" do
      name = Module.concat(__MODULE__, :ForceKillOrchestrator)
      pid = start_orchestrator(name)

      task_pid = spawn_unlinked(fn -> Process.sleep(:infinity) end)
      inject_running_entry(pid, "issue-timeout-1", "MT-801", task_pid)

      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "200")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      log =
        capture_log(fn ->
          assert graceful_stop(pid, 10_000) == :ok
        end)

      refute Process.alive?(pid)
      assert log =~ "Draining 1 agents"
      assert log =~ "Timeout: force-killing 1 agents"
      assert log =~ "Shutdown drain complete: 0 finished, 1 force-killed"
    end

    test "no orphan agent processes remain after force shutdown" do
      name = Module.concat(__MODULE__, :NoOrphanOrchestrator)
      pid = start_orchestrator(name)

      task_pid = spawn_unlinked(fn -> Process.sleep(:infinity) end)
      assert Process.alive?(task_pid)

      inject_running_entry(pid, "issue-orphan-1", "MT-901", task_pid)

      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "100")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      capture_log(fn ->
        assert graceful_stop(pid, 10_000) == :ok
      end)

      # Give a moment for the force-kill to propagate
      Process.sleep(50)

      refute Process.alive?(pid)
      refute Process.alive?(task_pid)
    end
  end

  describe "shutdown with no active agents" do
    test "clean shutdown when no agents are running" do
      name = Module.concat(__MODULE__, :EmptyShutdownOrchestrator)
      pid = start_orchestrator(name)

      state = :sys.get_state(pid)
      assert map_size(state.running) == 0

      log =
        capture_log(fn ->
          assert graceful_stop(pid, 5_000) == :ok
        end)

      refute Process.alive?(pid)
      assert log =~ "Shutdown: no active agents to drain"
    end
  end

  describe "child_spec/1 shutdown timeout" do
    test "uses finite shutdown based on shutdown_timeout_ms plus safety margin" do
      spec = Orchestrator.child_spec([])

      expected = Config.shutdown_timeout_ms() + 5_000
      assert spec.shutdown == expected
    end

    test "shutdown value changes with SHUTDOWN_TIMEOUT_MS env var" do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "30000")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      spec = Orchestrator.child_spec([])

      assert spec.shutdown == 35_000
    end
  end

  describe "shutdown_timeout_ms configuration" do
    test "default timeout is 60_000ms" do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.delete_env("SHUTDOWN_TIMEOUT_MS")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      assert Config.shutdown_timeout_ms() == 60_000
    end

    test "env var overrides default" do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "30000")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      assert Config.shutdown_timeout_ms() == 30_000
    end

    test "invalid env var falls back to default" do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "not_a_number")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      assert Config.shutdown_timeout_ms() == 60_000
    end

    test "env var with trailing garbage falls back to default" do
      old_val = System.get_env("SHUTDOWN_TIMEOUT_MS")
      System.put_env("SHUTDOWN_TIMEOUT_MS", "123abc")

      on_exit(fn ->
        if old_val,
          do: System.put_env("SHUTDOWN_TIMEOUT_MS", old_val),
          else: System.delete_env("SHUTDOWN_TIMEOUT_MS")
      end)

      assert Config.shutdown_timeout_ms() == 60_000
    end
  end
end
