defmodule SymphonyElixir.ConfigCacheTest do
  use SymphonyElixir.TestSupport

  describe "validated options caching" do
    test "process dictionary cache avoids redundant computation for same config" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 7)

      # First call computes and caches
      assert Config.max_concurrent_agents() == 7

      # Second call should return same value from cache
      assert Config.max_concurrent_agents() == 7
      assert Config.poll_interval_ms() == 30_000
    end

    test "process dictionary cache invalidates when config changes" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      assert Config.max_concurrent_agents() == 5

      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8)
      assert Config.max_concurrent_agents() == 8
    end

    test "clear_validated_opts_cache/0 clears the process dictionary cache" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 3)
      assert Config.max_concurrent_agents() == 3

      Config.clear_validated_opts_cache()

      # Should recompute after cache clear
      assert Config.max_concurrent_agents() == 3
    end
  end

  describe "WorkflowStore ETS cache" do
    test "current_cached returns workflow from ETS when WorkflowStore is running" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)

      assert {:ok, workflow} = WorkflowStore.current_cached()
      assert is_map(workflow.config)
    end

    test "current_cached returns :miss when ETS table does not exist" do
      # Spawn a task where the ETS table lookup will fail because we use a
      # private helper that checks a non-existent table name.
      # Since the real table is a named global, we verify the :miss path
      # by clearing the :workflow key and checking that empty lookup returns :miss.
      :ets.delete(:symphony_workflow_cache, :workflow)

      assert WorkflowStore.current_cached() == :miss

      # Restore by force-reloading
      WorkflowStore.force_reload()
      assert {:ok, _} = WorkflowStore.current_cached()
    end

    test "Workflow.current reads from ETS without GenServer call" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 6)

      # Workflow.current should succeed via ETS cache
      assert {:ok, workflow} = Workflow.current()
      assert is_map(workflow.config)
    end

    test "ETS cache is updated on force_reload" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 2)

      assert {:ok, workflow} = WorkflowStore.current_cached()
      assert workflow.config["agent"]["max_concurrent_agents"] == 2

      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 9)

      assert {:ok, updated} = WorkflowStore.current_cached()
      assert updated.config["agent"]["max_concurrent_agents"] == 9
    end

    test "Workflow.current falls through to GenServer when ETS cache is empty" do
      :ets.delete(:symphony_workflow_cache, :workflow)

      # Should still return valid workflow via GenServer fallback
      assert {:ok, workflow} = Workflow.current()
      assert is_map(workflow.config)
    end

    test "GenServer current returns last-good workflow when file is deleted" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)

      # Delete the workflow file
      File.rm!(Workflow.workflow_file_path())

      # GenServer should return last-known-good workflow from cached state
      assert {:ok, workflow} = WorkflowStore.current()
      assert is_map(workflow.config)
    end
  end
end
