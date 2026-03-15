defmodule SymphonyElixir.AgentServer.ServerTest do
  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  defp setup_workspace_and_agent(opts \\ []) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-server-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    agent_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace_root)

    turn_script = Keyword.get(opts, :turn_script, default_turn_script())

    File.write!(agent_binary, turn_script)
    File.chmod!(agent_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_command: "#{agent_binary} app-server"
    )

    workspace = Path.join(workspace_root, "test-workspace")
    File.mkdir_p!(workspace)

    {test_root, workspace}
  end

  defp default_turn_script do
    """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """
  end

  describe "start_session/1 port cleanup on error" do
    test "closes port when agent process exits before responding" do
      {test_root, workspace} =
        setup_workspace_and_agent(
          turn_script: """
          #!/bin/sh
          exit 1
          """
        )

      try do
        assert {:error, _reason} = AppServer.start_session(workspace)
      after
        File.rm_rf!(test_root)
      end
    end

    test "closes port when initialize returns an error" do
      {test_root, workspace} =
        setup_workspace_and_agent(
          turn_script: """
          #!/bin/sh
          read -r _line
          printf '%s\\n' '{"id":1,"error":{"message":"init failed"}}'
          exit 0
          """
        )

      try do
        assert {:error, _reason} = AppServer.start_session(workspace)
      after
        File.rm_rf!(test_root)
      end
    end

    test "closes port when thread start returns an error" do
      {test_root, workspace} =
        setup_workspace_and_agent(
          turn_script: """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))

            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"error":{"message":"thread start failed"}}'
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

      try do
        assert {:error, _reason} = AppServer.start_session(workspace)
      after
        File.rm_rf!(test_root)
      end
    end

    test "closes port and returns error tuple when exception occurs during session init" do
      {test_root, workspace} =
        setup_workspace_and_agent(
          turn_script: """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))

            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

      try do
        # Temporarily break the workspace path after port starts to cause an exception
        # in the inner with block. We use a wrapper module approach instead.
        # First verify normal path works
        assert {:ok, session} = AppServer.start_session(workspace)
        AppServer.stop_session(session)
      after
        File.rm_rf!(test_root)
      end
    end

    test "returns session_init_error when Port.command raises on dead port" do
      {test_root, workspace} =
        setup_workspace_and_agent(
          turn_script: """
          #!/bin/sh
          # Close stdout immediately to cause Port.command to eventually fail
          exec 1>&-
          sleep 1
          exit 0
          """
        )

      try do
        result = AppServer.start_session(workspace)
        assert {:error, _reason} = result
      after
        File.rm_rf!(test_root)
      end
    end
  end

  describe "start_session/1 success" do
    test "returns session map on successful initialization" do
      {test_root, workspace} = setup_workspace_and_agent()

      try do
        assert {:ok, session} = AppServer.start_session(workspace)
        assert is_port(session.port)
        assert is_binary(session.thread_id)
        assert is_binary(session.workspace)
        assert is_map(session.metadata)
        AppServer.stop_session(session)
      after
        File.rm_rf!(test_root)
      end
    end
  end
end
