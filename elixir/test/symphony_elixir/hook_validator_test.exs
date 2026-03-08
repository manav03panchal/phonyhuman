defmodule SymphonyElixir.HookValidatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HookValidator

  describe "validate/2 with allow_shell_hooks=true" do
    test "safe commands pass" do
      assert :ok = HookValidator.validate("echo hello", true)
      assert :ok = HookValidator.validate("git clone --depth 1 repo .", true)
      assert :ok = HookValidator.validate("cp -r /src/. /dst", true)
      assert :ok = HookValidator.validate("npm install", true)
    end

    test "nil command passes" do
      assert :ok = HookValidator.validate(nil, true)
    end

    test "semicolons trigger warning" do
      assert {:warn, patterns} = HookValidator.validate("echo a; echo b", true)
      assert ";" in patterns
    end

    test "pipe triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("cat file | grep foo", true)
      assert "|" in patterns
    end

    test "double pipe triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("cmd1 || cmd2", true)
      assert "||" in patterns
    end

    test "double ampersand triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("cmd1 && cmd2", true)
      assert "&&" in patterns
    end

    test "command substitution triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("echo $(whoami)", true)
      assert "$(" in patterns
    end

    test "backticks trigger warning" do
      assert {:warn, patterns} = HookValidator.validate("echo `whoami`", true)
      assert "`" in patterns
    end

    test "output redirection triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("echo x > /etc/passwd", true)
      assert ">" in patterns
    end

    test "append redirection triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("echo x >> log", true)
      assert ">>" in patterns
    end

    test "input redirection triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("cat < file", true)
      assert "<" in patterns
    end

    test "heredoc triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("cat << EOF", true)
      assert "<<" in patterns
    end

    test "background operator triggers warning" do
      assert {:warn, patterns} = HookValidator.validate("sleep 10 &", true)
      assert "&" in patterns
    end

    test "multiple dangerous patterns are all reported" do
      assert {:warn, patterns} = HookValidator.validate("echo a; cat | grep foo && rm -rf /", true)
      assert ";" in patterns
      assert "|" in patterns
      assert "&&" in patterns
    end
  end

  describe "validate/2 with allow_shell_hooks=false" do
    test "safe commands pass" do
      assert :ok = HookValidator.validate("echo hello", false)
      assert :ok = HookValidator.validate("git clone --depth 1 repo .", false)
    end

    test "nil command passes" do
      assert :ok = HookValidator.validate(nil, false)
    end

    test "semicolons are rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("echo a; echo b", false)

      assert ";" in patterns
    end

    test "pipe is rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("cat file | grep foo", false)

      assert "|" in patterns
    end

    test "double ampersand is rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("cmd1 && cmd2", false)

      assert "&&" in patterns
    end

    test "double pipe is rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("cmd1 || cmd2", false)

      assert "||" in patterns
    end

    test "command substitution is rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("echo $(whoami)", false)

      assert "$(" in patterns
    end

    test "backticks are rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("echo `whoami`", false)

      assert "`" in patterns
    end

    test "background operator is rejected" do
      assert {:error, {:dangerous_hook_command, _, patterns}} =
               HookValidator.validate("sleep 10 &", false)

      assert "&" in patterns
    end
  end

  describe "validate_all_hooks/2" do
    test "all safe hooks pass" do
      hooks = %{
        after_create: "echo created",
        before_run: "echo before",
        after_run: "echo after",
        before_remove: "echo remove"
      }

      assert :ok = HookValidator.validate_all_hooks(hooks, false)
    end

    test "nil hooks pass" do
      hooks = %{after_create: nil, before_run: nil, after_run: nil, before_remove: nil}
      assert :ok = HookValidator.validate_all_hooks(hooks, false)
    end

    test "first dangerous hook causes error when allow_shell_hooks=false" do
      hooks = %{
        after_create: "echo ok",
        before_run: "cmd1 && cmd2",
        after_run: nil,
        before_remove: nil
      }

      assert {:error, {:dangerous_hook_command, "cmd1 && cmd2", _}} =
               HookValidator.validate_all_hooks(hooks, false)
    end

    test "dangerous hooks warn but pass when allow_shell_hooks=true" do
      hooks = %{
        after_create: "cmd1 && cmd2",
        before_run: nil,
        after_run: nil,
        before_remove: nil
      }

      assert :ok = HookValidator.validate_all_hooks(hooks, true)
    end
  end

  describe "config-time validation" do
    test "config validates hook commands at load time" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hook_after_create: "echo hello",
        hook_allow_shell_hooks: true
      )

      assert :ok = Config.validate!()
    end

    test "config rejects dangerous hook when allow_shell_hooks=false" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hook_after_create: "cmd1 && cmd2",
        hook_allow_shell_hooks: false
      )

      assert {:error, {:dangerous_hook_command, _, _}} = Config.validate!()
    end

    test "config allows dangerous hook when allow_shell_hooks=true (default)" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hook_after_create: "echo nope && exit 17"
      )

      assert :ok = Config.validate!()
    end
  end

  describe "audit logging of hook execution" do
    test "hook execution is audit-logged with command, exit code, and duration" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-audit-log-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo audited"
        )

        log =
          capture_log(fn ->
            assert {:ok, _workspace} = Workspace.create_for_issue("MT-AUDIT")
          end)

        assert log =~ "Workspace hook completed"
        assert log =~ "hook=after_create"
        assert log =~ ~s(command="echo audited")
        assert log =~ "exit_code=0"
        assert log =~ "duration_ms="
      after
        File.rm_rf(workspace_root)
      end
    end

    test "failed hook execution is audit-logged with exit code and duration" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-audit-fail-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "exit 42"
        )

        log =
          capture_log(fn ->
            assert {:error, {:workspace_hook_failed, "after_create", 42, _}} =
                     Workspace.create_for_issue("MT-AUDIT-FAIL")
          end)

        assert log =~ "Workspace hook failed"
        assert log =~ "hook=after_create"
        assert log =~ ~s(command="exit 42")
        assert log =~ "exit_code=42"
        assert log =~ "duration_ms="
      after
        File.rm_rf(workspace_root)
      end
    end

    test "warning logged when hook contains shell metacharacters with allow_shell_hooks=true" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-warn-meta-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo nope && exit 17",
          hook_allow_shell_hooks: true
        )

        log =
          capture_log(fn ->
            Workspace.create_for_issue("MT-WARN")
          end)

        assert log =~ "shell metacharacters"
        assert log =~ "hook=after_create"
      after
        File.rm_rf(workspace_root)
      end
    end
  end

  describe "backwards compatibility" do
    test "existing valid hooks still work with default config" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-compat-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo compat > compat.txt"
        )

        assert {:ok, workspace} = Workspace.create_for_issue("MT-COMPAT")
        assert File.read!(Path.join(workspace, "compat.txt")) == "compat\n"
      after
        File.rm_rf(workspace_root)
      end
    end

    test "allow_shell_hooks defaults to true" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert Config.allow_shell_hooks?() == true
    end

    test "allow_shell_hooks can be set to false" do
      write_workflow_file!(Workflow.workflow_file_path(), hook_allow_shell_hooks: false)
      assert Config.allow_shell_hooks?() == false
    end
  end
end
