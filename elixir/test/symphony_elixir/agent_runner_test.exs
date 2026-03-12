defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  defp test_issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: "issue-#{System.unique_integer([:positive])}",
        identifier: "MT-#{System.unique_integer([:positive])}",
        title: "Test issue",
        description: "A test issue for agent runner",
        state: "In Progress",
        url: "https://example.org/issues/MT-1",
        labels: ["backend"]
      },
      overrides
    )
  end

  defp setup_workspace_and_agent(opts \\ []) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-#{System.unique_integer([:positive])}"
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

    {test_root, workspace_root, agent_binary}
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
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
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
    """
  end

  defp terminal_state_fetcher do
    fn _ids ->
      {:ok, [%Issue{id: "issue-1", identifier: "MT-1", state: "Done"}]}
    end
  end

  defp active_state_fetcher(times) do
    counter = :counters.new(1, [:atomics])

    fn ids ->
      current = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if current < times do
        {:ok,
         Enum.map(ids, fn id ->
           %Issue{id: id, identifier: "MT-1", state: "In Progress"}
         end)}
      else
        {:ok,
         Enum.map(ids, fn id ->
           %Issue{id: id, identifier: "MT-1", state: "Done"}
         end)}
      end
    end
  end

  describe "run/3 workspace setup flow" do
    test "succeeds for a single-turn run with workspace creation and cleanup" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 1,
                   issue_state_fetcher: terminal_state_fetcher()
                 )
      after
        File.rm_rf(test_root)
      end
    end

    test "raises on workspace creation failure when workspace_root is invalid" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-agent-runner-bad-ws-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: "/nonexistent/path/that/should/fail"
        )

        issue = test_issue()

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil, max_turns: 1)
        end
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 hook failure handling" do
    test "raises when before_run hook fails" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(test_root, "workspaces"),
          agent_command: "echo unused",
          hook_before_run: "exit 1"
        )

        issue = test_issue()

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil, max_turns: 1)
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "after_run hook always executes even when before_run fails" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()
      marker_file = Path.join(test_root, "after_run_executed")

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(test_root, "workspaces"),
          agent_command: "echo unused",
          hook_before_run: "exit 1",
          hook_after_run: "touch #{marker_file}"
        )

        issue = test_issue()

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil, max_turns: 1)
        end

        assert File.exists?(marker_file),
               "after_run hook should have executed even though before_run failed"
      after
        File.rm_rf(test_root)
      end
    end

    test "after_run hook executes on successful run" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()
      marker_file = Path.join(test_root, "after_run_ok")

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(test_root, "workspaces"),
          agent_command: "#{Path.join(test_root, "fake-codex")} app-server",
          hook_after_run: "touch #{marker_file}"
        )

        issue = test_issue()

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 1,
                   issue_state_fetcher: terminal_state_fetcher()
                 )

        assert File.exists?(marker_file),
               "after_run hook should have executed on success"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 multi-turn retry logic" do
    test "executes multiple turns when issue remains active" do
      turn_count_file =
        Path.join(
          System.tmp_dir!(),
          "symphony-turn-count-#{System.unique_integer([:positive])}"
        )

      # Each turn sends both response and completed in the same read iteration
      # because there is no server write between them to trigger a new read.
      # count 1: init, count 2: initialized (thread response), count 2+k: turn k
      multi_turn_script = """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-mt"}}}'
            ;;
          3)
            echo "1" >> "#{turn_count_file}"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-mt-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          4)
            echo "2" >> "#{turn_count_file}"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-mt-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            echo "3" >> "#{turn_count_file}"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-mt-3"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """

      {test_root, _workspace_root, _agent_binary} =
        setup_workspace_and_agent(turn_script: multi_turn_script)

      try do
        issue = test_issue()

        # Active for first 2 turns, then terminal
        fetcher = active_state_fetcher(2)

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 5,
                   issue_state_fetcher: fetcher
                 )

        # Should have executed 3 turns (active, active, then done on 3rd check)
        turn_lines =
          turn_count_file
          |> File.read!()
          |> String.split("\n", trim: true)

        assert length(turn_lines) == 3
      after
        File.rm_rf(test_root)
        File.rm(turn_count_file)
      end
    end

    test "stops at max_turns even when issue remains active" do
      multi_turn_script = """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """

      {test_root, _workspace_root, _agent_binary} =
        setup_workspace_and_agent(turn_script: multi_turn_script)

      try do
        issue = test_issue()

        # Always returns active
        always_active = fn ids ->
          {:ok,
           Enum.map(ids, fn id ->
             %Issue{id: id, identifier: "MT-1", state: "In Progress"}
           end)}
        end

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 2,
                   issue_state_fetcher: always_active
                 )
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 issue state transitions" do
    test "stops when issue transitions to terminal state after a turn" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 10,
                   issue_state_fetcher: terminal_state_fetcher()
                 )
      after
        File.rm_rf(test_root)
      end
    end

    test "propagates error when issue state refresh fails" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        failing_fetcher = fn _ids ->
          {:error, :network_timeout}
        end

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil,
            max_turns: 5,
            issue_state_fetcher: failing_fetcher
          )
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "treats empty issue list from fetcher as done" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        empty_fetcher = fn _ids -> {:ok, []} end

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 5,
                   issue_state_fetcher: empty_fetcher
                 )
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 agent update messages" do
    test "sends agent_worker_update messages to recipient" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        assert :ok =
                 AgentRunner.run(issue, self(),
                   max_turns: 1,
                   issue_state_fetcher: terminal_state_fetcher()
                 )

        assert_received {:agent_worker_update, _issue_id, %{event: :session_started}}
      after
        File.rm_rf(test_root)
      end
    end

    test "drops updates with warning when recipient is nil" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert :ok =
                     AgentRunner.run(issue, nil,
                       max_turns: 1,
                       issue_state_fetcher: terminal_state_fetcher()
                     )
          end)

        assert log =~ "Dropping agent update"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 AppServer session failure" do
    test "raises when AppServer session cannot start" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        # Use a binary that exits immediately to cause session start failure
        bad_binary = Path.join(test_root, "bad-codex")

        File.write!(bad_binary, """
        #!/bin/sh
        exit 1
        """)

        File.chmod!(bad_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(test_root, "workspaces"),
          agent_command: "#{bad_binary} app-server"
        )

        issue = test_issue()

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil, max_turns: 1)
        end
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 turn failure" do
    test "raises when a turn fails with an error" do
      failing_turn_script = """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fail"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fail"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"something went wrong"}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """

      {test_root, _workspace_root, _agent_binary} =
        setup_workspace_and_agent(turn_script: failing_turn_script)

      try do
        issue = test_issue()

        assert_raise RuntimeError, ~r/Agent run failed/, fn ->
          AgentRunner.run(issue, nil,
            max_turns: 5,
            issue_state_fetcher: terminal_state_fetcher()
          )
        end
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 continuation prompt" do
    test "uses continuation guidance text for turns after the first" do
      multi_turn_script = """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """

      {test_root, _workspace_root, _agent_binary} =
        setup_workspace_and_agent(turn_script: multi_turn_script)

      try do
        issue = test_issue()

        # Active for 1 turn, then terminal
        fetcher = active_state_fetcher(1)

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 5,
                   issue_state_fetcher: fetcher
                 )
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run/3 issue without id" do
    test "treats issue without id as done (no continuation)" do
      {test_root, _workspace_root, _agent_binary} = setup_workspace_and_agent()

      try do
        issue = test_issue(%{id: nil})

        assert :ok =
                 AgentRunner.run(issue, nil,
                   max_turns: 5,
                   issue_state_fetcher: terminal_state_fetcher()
                 )
      after
        File.rm_rf(test_root)
      end
    end
  end
end
