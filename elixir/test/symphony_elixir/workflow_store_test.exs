defmodule SymphonyElixir.WorkflowStoreTest do
  use SymphonyElixir.TestSupport

  describe "stamp-based polling optimization" do
    test "unchanged file does not trigger workflow reload" do
      path = Workflow.workflow_file_path()
      write_workflow_file!(path, max_concurrent_agents: 3)

      {:ok, w1} = WorkflowStore.current()
      assert w1.config["agent"]["max_concurrent_agents"] == 3

      # Poll fires internally; without file changes, same workflow is returned
      {:ok, w2} = WorkflowStore.current()
      assert w2.config["agent"]["max_concurrent_agents"] == 3
    end

    test "workflow reloads when file mtime changes" do
      path = Workflow.workflow_file_path()
      write_workflow_file!(path, max_concurrent_agents: 4)

      {:ok, w1} = WorkflowStore.current()
      assert w1.config["agent"]["max_concurrent_agents"] == 4

      # Ensure mtime advances (filesystem may have 1s resolution)
      Process.sleep(1_100)
      write_workflow_file!(path, max_concurrent_agents: 7)

      {:ok, w2} = WorkflowStore.current()
      assert w2.config["agent"]["max_concurrent_agents"] == 7
    end

    test "returns last-good workflow when file is deleted during poll" do
      path = Workflow.workflow_file_path()
      write_workflow_file!(path, max_concurrent_agents: 5)

      {:ok, w1} = WorkflowStore.current()
      assert w1.config["agent"]["max_concurrent_agents"] == 5

      File.rm!(path)

      # GenServer should return last-known-good workflow via stat error path
      {:ok, w2} = WorkflowStore.current()
      assert w2.config["agent"]["max_concurrent_agents"] == 5
    end

    test "force_reload returns error when file is missing" do
      path = Workflow.workflow_file_path()
      write_workflow_file!(path, max_concurrent_agents: 6)

      {:ok, w1} = WorkflowStore.current()
      assert w1.config["agent"]["max_concurrent_agents"] == 6

      File.rm!(path)

      # force_reload should return error but preserve last-good workflow
      assert {:error, _reason} = WorkflowStore.force_reload()

      # Cached workflow should still be accessible
      {:ok, w2} = WorkflowStore.current_cached()
      assert w2.config["agent"]["max_concurrent_agents"] == 6
    end
  end
end
