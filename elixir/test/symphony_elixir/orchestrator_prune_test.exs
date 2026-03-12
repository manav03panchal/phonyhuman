defmodule SymphonyElixir.OrchestratorPruneTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

  describe "prune_stale_entries_for_test/1" do
    test "removes completed entries older than TTL" do
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      recent = DateTime.utc_now()

      state = %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: %{"old-issue" => old, "recent-issue" => recent},
        claimed: %{},
        retry_attempts: %{}
      }

      pruned = Orchestrator.prune_stale_entries_for_test(state)

      refute Map.has_key?(pruned.completed, "old-issue")
      assert Map.has_key?(pruned.completed, "recent-issue")
    end

    test "removes claimed entries older than TTL when not in running or retries" do
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      recent = DateTime.utc_now()

      state = %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: %{},
        claimed: %{"stale-claim" => old, "fresh-claim" => recent},
        retry_attempts: %{}
      }

      pruned = Orchestrator.prune_stale_entries_for_test(state)

      refute Map.has_key?(pruned.claimed, "stale-claim")
      assert Map.has_key?(pruned.claimed, "fresh-claim")
    end

    test "preserves stale claimed entries that are still in running" do
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      state = %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{"active-issue" => %{pid: self()}},
        completed: %{},
        claimed: %{"active-issue" => old},
        retry_attempts: %{}
      }

      pruned = Orchestrator.prune_stale_entries_for_test(state)

      assert Map.has_key?(pruned.claimed, "active-issue")
    end

    test "preserves stale claimed entries that are pending retry" do
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      state = %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: %{},
        claimed: %{"retrying-issue" => old},
        retry_attempts: %{"retrying-issue" => %{attempt: 2, timer_ref: nil, due_at_ms: 0}}
      }

      pruned = Orchestrator.prune_stale_entries_for_test(state)

      assert Map.has_key?(pruned.claimed, "retrying-issue")
    end

    test "prunes many entries under simulated load" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -25 * 3600, :second)

      # Simulate 1000 stale completed + 1000 stale claimed + 100 recent of each
      stale_completed =
        for i <- 1..1000, into: %{} do
          {"completed-stale-#{i}", old}
        end

      recent_completed =
        for i <- 1..100, into: %{} do
          {"completed-recent-#{i}", now}
        end

      stale_claimed =
        for i <- 1..1000, into: %{} do
          {"claimed-stale-#{i}", old}
        end

      recent_claimed =
        for i <- 1..100, into: %{} do
          {"claimed-recent-#{i}", now}
        end

      state = %State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: Map.merge(stale_completed, recent_completed),
        claimed: Map.merge(stale_claimed, recent_claimed),
        retry_attempts: %{}
      }

      assert map_size(state.completed) == 1100
      assert map_size(state.claimed) == 1100

      pruned = Orchestrator.prune_stale_entries_for_test(state)

      assert map_size(pruned.completed) == 100
      assert map_size(pruned.claimed) == 100

      # Verify all remaining are the recent ones
      for i <- 1..100 do
        assert Map.has_key?(pruned.completed, "completed-recent-#{i}")
        assert Map.has_key?(pruned.claimed, "claimed-recent-#{i}")
      end
    end
  end
end
