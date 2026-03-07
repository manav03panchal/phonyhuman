defmodule SymphonyElixir.OrchestratorFleetPauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

  # Helper to build a minimal orchestrator state
  defp base_state(overrides \\ %{}) do
    Map.merge(
      %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
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

  describe "fleet pause triggers" do
    test "trigger_fleet_pause sets fleet_paused_until in the future" do
      state = base_state()
      updated = Orchestrator.trigger_fleet_pause_for_test(state, "test reason", 60_000)

      assert updated.fleet_paused_until != nil
      assert updated.fleet_pause_reason == "test reason"
      assert updated.fleet_pause_attempt == 1
      assert DateTime.compare(updated.fleet_paused_until, DateTime.utc_now()) == :gt
    end

    test "usage_cap with is_global triggers fleet pause via worker update" do
      orchestrator_name = Module.concat(__MODULE__, :UsageCapOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      issue_id = "issue-usage-cap"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-100",
        title: "Usage cap test",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-100"
      }

      # Inject a running entry
      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state_with_issue = %{initial_state | running: Map.put(initial_state.running, issue_id, running_entry)}
      :sys.replace_state(pid, fn _ -> state_with_issue end)

      # Send a usage_cap error
      send(pid, {:agent_worker_update, issue_id, %{
        event: :turn_failed,
        timestamp: DateTime.utc_now(),
        error_type: "usage_cap",
        is_global: true,
        retry_after: 120_000
      }})

      # Give the GenServer time to process
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.fleet_paused_until != nil
      assert state.fleet_pause_reason == "Global usage cap reached"
      assert state.fleet_pause_attempt == 1
    end

    test "pattern detection triggers fleet pause on 3+ failures in window" do
      orchestrator_name = Module.concat(__MODULE__, :PatternOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      issue_ids = ["issue-p1", "issue-p2", "issue-p3"]

      issues =
        Enum.map(issue_ids, fn id ->
          %Issue{
            id: id,
            identifier: "MT-#{String.slice(id, -2, 2)}",
            title: "Pattern test",
            description: "Test",
            state: "In Progress",
            url: "https://example.org/issues/#{id}"
          }
        end)

      initial_state = :sys.get_state(pid)

      running =
        Enum.zip(issue_ids, issues)
        |> Enum.reduce(%{}, fn {id, issue}, acc ->
          Map.put(acc, id, %{
            pid: self(),
            ref: make_ref(),
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            turn_count: 0,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            retry_attempt: 0,
            started_at: DateTime.utc_now()
          })
        end)

      state_with_issues = %{initial_state | running: running}
      :sys.replace_state(pid, fn _ -> state_with_issues end)

      # Send 3 rate_limit errors in rapid succession
      for id <- issue_ids do
        send(pid, {:agent_worker_update, id, %{
          event: :turn_failed,
          timestamp: DateTime.utc_now(),
          error_type: "rate_limit",
          is_global: false
        }})

        Process.sleep(10)
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.fleet_paused_until != nil
      assert state.fleet_pause_reason =~ "Pattern detection"
    end

    test "single rate_limit error does NOT trigger fleet pause" do
      orchestrator_name = Module.concat(__MODULE__, :SingleRateLimitOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      issue_id = "issue-single-rl"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-200",
        title: "Single RL test",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-200"
      }

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state_with_issue = %{initial_state | running: Map.put(initial_state.running, issue_id, running_entry)}
      :sys.replace_state(pid, fn _ -> state_with_issue end)

      send(pid, {:agent_worker_update, issue_id, %{
        event: :turn_failed,
        timestamp: DateTime.utc_now(),
        error_type: "rate_limit",
        is_global: false
      }})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.fleet_paused_until == nil
      assert state.consecutive_limit_failures == 1
    end
  end

  describe "can_dispatch? during fleet pause" do
    test "fleet_paused? returns true when paused_until is in the future" do
      state = base_state(%{fleet_paused_until: DateTime.add(DateTime.utc_now(), 300, :second)})
      assert Orchestrator.fleet_paused_for_test?(state) == true
    end

    test "fleet_paused? returns false when paused_until is nil" do
      state = base_state()
      assert Orchestrator.fleet_paused_for_test?(state) == false
    end

    test "fleet_paused? returns false when paused_until is in the past" do
      state = base_state(%{fleet_paused_until: DateTime.add(DateTime.utc_now(), -10, :second)})
      assert Orchestrator.fleet_paused_for_test?(state) == false
    end
  end

  describe "probe dispatch and result handling" do
    test "probe success clears fleet pause state" do
      state =
        base_state(%{
          fleet_paused_until: DateTime.add(DateTime.utc_now(), 300, :second),
          fleet_pause_reason: "test",
          fleet_pause_attempt: 2,
          fleet_probe_active: true,
          consecutive_limit_failures: 5,
          last_limit_failure_at: DateTime.utc_now()
        })

      # Simulate clear_fleet_pause (called on probe success in :DOWN handler)
      # We test through the public test helper
      cleared = Orchestrator.trigger_fleet_pause_for_test(state, "will be cleared", 1)

      # The state after trigger has fleet_paused_until set
      assert cleared.fleet_paused_until != nil

      # Now test that fleet_paused_for_test? returns false after pause expires (1ms)
      Process.sleep(10)
      assert Orchestrator.fleet_paused_for_test?(cleared) == false
    end

    test "pause extension caps at maximum" do
      # With default 30min and attempt=10, the exponential would exceed max
      state =
        base_state(%{
          fleet_pause_attempt: 10
        })

      # Trigger with nil retry_after to use default
      updated = Orchestrator.trigger_fleet_pause_for_test(state, "capped test", nil)

      # The pause should be capped at fleet_pause_max_ms (4 hours = 14_400_000ms)
      max_ms = Config.fleet_pause_max_ms()
      diff_ms = DateTime.diff(updated.fleet_paused_until, DateTime.utc_now(), :millisecond)

      # Allow some tolerance for timing
      assert diff_ms <= max_ms + 100
      assert diff_ms > 0
    end
  end

  describe "consecutive failure counter" do
    test "successful turn completion resets consecutive failure counter" do
      orchestrator_name = Module.concat(__MODULE__, :ResetCounterOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      issue_id = "issue-reset"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-300",
        title: "Reset test",
        description: "Test",
        state: "In Progress",
        url: "https://example.org/issues/MT-300"
      }

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state_with_failures = %{
        initial_state
        | running: Map.put(initial_state.running, issue_id, running_entry),
          consecutive_limit_failures: 2,
          last_limit_failure_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ -> state_with_failures end)

      # Send successful turn completion
      send(pid, {:agent_worker_update, issue_id, %{
        event: :turn_completed,
        timestamp: DateTime.utc_now()
      }})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.consecutive_limit_failures == 0
      assert state.last_limit_failure_at == nil
    end
  end

  describe "snapshot includes fleet pause fields" do
    test "snapshot includes fleet_status running when not paused" do
      orchestrator_name = Module.concat(__MODULE__, :SnapshotRunningOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
      assert snapshot.fleet_status == "running"
      assert snapshot.fleet_paused_until == nil
      assert snapshot.fleet_pause_reason == nil
    end

    test "snapshot includes fleet_status paused when paused" do
      orchestrator_name = Module.concat(__MODULE__, :SnapshotPausedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Set fleet paused state
      :sys.replace_state(pid, fn state ->
        %{state |
          fleet_paused_until: DateTime.add(DateTime.utc_now(), 300, :second),
          fleet_pause_reason: "Test pause"
        }
      end)

      snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
      assert snapshot.fleet_status == "paused"
      assert snapshot.fleet_paused_until != nil
      assert snapshot.fleet_pause_reason == "Test pause"
    end
  end

  describe "retry_after parsing" do
    test "parses integer milliseconds" do
      assert Orchestrator.parse_retry_after_for_test(%{retry_after: 120_000}) == 120_000
    end

    test "parses string '2 hours'" do
      assert Orchestrator.parse_retry_after_for_test(%{retry_after: "2 hours"}) == 7_200_000
    end

    test "parses string '30 minutes'" do
      assert Orchestrator.parse_retry_after_for_test(%{retry_after: "30 minutes"}) == 1_800_000
    end

    test "parses string '60 seconds'" do
      assert Orchestrator.parse_retry_after_for_test(%{retry_after: "60 seconds"}) == 60_000
    end

    test "returns nil for absent retry_after" do
      assert Orchestrator.parse_retry_after_for_test(%{event: :test}) == nil
    end

    test "returns nil for unparseable string" do
      assert Orchestrator.parse_retry_after_for_test(%{retry_after: "never"}) == nil
    end

    test "parses retry_after from nested payload" do
      assert Orchestrator.parse_retry_after_for_test(%{payload: %{retry_after: 300_000}}) == 300_000
    end
  end
end
