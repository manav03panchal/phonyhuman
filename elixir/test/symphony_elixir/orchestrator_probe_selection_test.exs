defmodule SymphonyElixir.OrchestratorProbeSelectionTest do
  use SymphonyElixir.TestSupport

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

  defp make_issue(id, opts) do
    identifier = Keyword.get(opts, :identifier, "MT-#{id}")
    priority = Keyword.get(opts, :priority, 3)

    %Issue{
      id: id,
      identifier: identifier,
      title: "Test issue #{id}",
      description: "Test",
      state: "In Progress",
      priority: priority,
      url: "https://example.org/issues/#{id}"
    }
  end

  describe "select_probe_candidate_for_test/2" do
    test "selects lowest-priority (last sorted) issue when none are running or claimed" do
      issues = [
        make_issue("a", priority: 1),
        make_issue("b", priority: 3),
        make_issue("c", priority: 4)
      ]

      state = base_state()
      result = Orchestrator.select_probe_candidate_for_test(issues, state)

      assert result.id == "c"
    end

    test "skips issue that is already running" do
      running_issue = make_issue("running-1", priority: 4)
      other_issue = make_issue("other-1", priority: 1)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: running_issue.identifier,
        issue: running_issue,
        session_id: nil,
        turn_count: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state = base_state(%{running: %{"running-1" => running_entry}})
      result = Orchestrator.select_probe_candidate_for_test([running_issue, other_issue], state)

      # Should pick other_issue since running_issue is filtered out
      assert result.id == "other-1"
    end

    test "skips issue that is already claimed" do
      claimed_issue = make_issue("claimed-1", priority: 4)
      other_issue = make_issue("other-2", priority: 1)

      state = base_state(%{claimed: %{"claimed-1" => DateTime.utc_now()}})
      result = Orchestrator.select_probe_candidate_for_test([claimed_issue, other_issue], state)

      # Should pick other_issue since claimed_issue is filtered out
      assert result.id == "other-2"
    end

    test "returns nil when all candidates are running or claimed" do
      issue_a = make_issue("a", priority: 1)
      issue_b = make_issue("b", priority: 3)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue_a.identifier,
        issue: issue_a,
        session_id: nil,
        turn_count: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state =
        base_state(%{
          running: %{"a" => running_entry},
          claimed: %{"b" => DateTime.utc_now()}
        })

      result = Orchestrator.select_probe_candidate_for_test([issue_a, issue_b], state)
      assert result == nil
    end

    test "selects correct candidate when some issues are running and some are claimed" do
      issue_a = make_issue("a", priority: 1)
      issue_b = make_issue("b", priority: 2)
      issue_c = make_issue("c", priority: 4)

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: issue_c.identifier,
        issue: issue_c,
        session_id: nil,
        turn_count: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      state =
        base_state(%{
          running: %{"c" => running_entry},
          claimed: %{"b" => DateTime.utc_now()}
        })

      result = Orchestrator.select_probe_candidate_for_test([issue_a, issue_b, issue_c], state)

      # Only issue_a is available; it should be selected
      assert result.id == "a"
    end

    test "returns nil for empty issue list" do
      state = base_state()
      result = Orchestrator.select_probe_candidate_for_test([], state)
      assert result == nil
    end
  end
end
