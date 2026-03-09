defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.HookValidator

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec write_mcp_json(Path.t()) :: :ok
  def write_mcp_json(workspace) when is_binary(workspace) do
    case Config.agent_mcp_servers() do
      nil ->
        :ok

      servers when is_map(servers) ->
        mcp_config = %{"mcpServers" => servers}
        mcp_path = Path.join(workspace, ".mcp.json")
        File.write!(mcp_path, Jason.encode!(mcp_config, pretty: true))
        Logger.info("Wrote .mcp.json to workspace=#{workspace}")
        :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    hooks = Config.workspace_hooks()
    allow_shell_hooks = Map.get(hooks, :allow_shell_hooks, true)

    case warn_on_dangerous_patterns(command, hook_name, allow_shell_hooks) do
      {:error, reason} ->
        {:error, reason}

      _ ->
        run_hook_command(command, workspace, issue_context, hook_name, hooks)
    end
  end

  defp run_hook_command(command, workspace, issue_context, hook_name, hooks) do
    timeout_ms = hooks[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} command=#{inspect(command)} #{issue_log_context(issue_context)} workspace=#{workspace}")

    start_time = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name, command, duration_ms)

      nil ->
        Task.shutdown(task, :brutal_kill)
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.warning(
          "Workspace hook timed out hook=#{hook_name} command=#{inspect(command)} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms} duration_ms=#{duration_ms}"
        )

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp warn_on_dangerous_patterns(command, hook_name, allow_shell_hooks) do
    case HookValidator.validate(command, allow_shell_hooks) do
      :ok ->
        :ok

      {:warn, patterns} ->
        Logger.warning(
          "Workspace hook contains shell metacharacters hook=#{hook_name} " <>
            "command=#{inspect(command)} patterns=#{inspect(patterns)}"
        )

        :ok

      {:error, {:dangerous_hook_command, _cmd, patterns}} = error ->
        Logger.error(
          "Workspace hook rejected: dangerous shell metacharacters hook=#{hook_name} " <>
            "command=#{inspect(command)} patterns=#{inspect(patterns)}"
        )

        error
    end
  end

  defp handle_hook_command_result({_output, 0}, workspace, issue_context, hook_name, command, duration_ms) do
    Logger.info("Workspace hook completed hook=#{hook_name} command=#{inspect(command)} #{issue_log_context(issue_context)} workspace=#{workspace} exit_code=0 duration_ms=#{duration_ms}")
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, command, duration_ms) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning(
      "Workspace hook failed hook=#{hook_name} command=#{inspect(command)} #{issue_log_context(issue_context)} workspace=#{workspace} exit_code=#{status} duration_ms=#{duration_ms} output=#{inspect(sanitized_output)}"
    )

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
