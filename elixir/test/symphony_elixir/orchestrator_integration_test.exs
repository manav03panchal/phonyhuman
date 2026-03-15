defmodule SymphonyElixir.OrchestratorIntegrationTest do
  @moduledoc """
  End-to-end integration test exercising the full orchestrator dispatch pipeline:
  orchestrator picks issue → creates workspace → starts agent → agent completes →
  orchestrator records completion.
  """

  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  describe "full dispatch pipeline" do
    test "orchestrator picks issue, creates workspace, runs agent, and records completion" do
      # Stop the default orchestrator to avoid dispatch interference
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)

      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-integration-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      # Create a fake codex script that writes a marker file when it runs
      agent_binary = Path.join(test_root, "fake-codex")
      marker_file = Path.join(test_root, "agent_ran")

      File.write!(agent_binary, """
      #!/bin/sh
      touch "#{marker_file}"
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integ"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integ"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(agent_binary, 0o755)

      issue_id = "issue-integ-#{System.unique_integer([:positive])}"
      identifier = "MT-INTEG-#{System.unique_integer([:positive])}"

      issue = %Issue{
        id: issue_id,
        identifier: identifier,
        title: "Integration test issue",
        description: "Test the full dispatch pipeline",
        state: "Todo",
        url: "https://example.org/issues/#{identifier}",
        labels: ["test"]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_command: "#{agent_binary} app-server",
        max_turns: 1,
        poll_interval_ms: 50
      )

      orchestrator_name = :"#{__MODULE__}.Orch.#{System.unique_integer([:positive])}"
      {:ok, orch_pid} = Orchestrator.start_link(name: orchestrator_name)

      try do
        # Wait for the orchestrator to dispatch and complete the agent
        assert poll_until(
                 fn ->
                   state = :sys.get_state(orch_pid)
                   Map.has_key?(state.completed, issue_id)
                 end,
                 10_000
               ),
               "Timed out waiting for orchestrator to record completion"

        # Verify workspace was created
        safe_id = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
        workspace_path = Path.join(workspace_root, safe_id)
        assert File.dir?(workspace_path), "Workspace directory should exist at #{workspace_path}"

        # Verify agent actually ran (marker file written by fake codex script)
        assert File.exists?(marker_file), "Agent should have run and written marker file"

        # Verify orchestrator state records completion with a timestamp
        state = :sys.get_state(orch_pid)
        assert %DateTime{} = state.completed[issue_id]
        assert state.running == %{} or not Map.has_key?(state.running, issue_id)
      after
        if Process.alive?(orch_pid), do: GenServer.stop(orch_pid)
        File.rm_rf(test_root)
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end
    end
  end

  defp poll_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(fun, deadline)
  end

  defp do_poll_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_poll_until(fun, deadline)
      else
        false
      end
    end
  end
end
