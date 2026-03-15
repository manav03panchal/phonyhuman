defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  require Logger

  alias NimbleOptions
  alias SymphonyElixir.HookValidator
  alias SymphonyElixir.Workflow

  @sensitive_fields [:api_key, :linear_api_token]

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @min_agent_stall_timeout_ms 30_000
  @default_agent_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_agent_thread_sandbox "workspace-write"
  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type agent_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer(),
          allow_shell_hooks: boolean()
        }

  @spec sensitive_fields() :: [atom()]
  def sensitive_fields, do: @sensitive_fields

  @spec sensitive?(atom()) :: boolean()
  def sensitive?(field) when is_atom(field), do: field in @sensitive_fields

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms),
      allow_shell_hooks: Map.get(hooks, :allow_shell_hooks, true)
    }
  end

  @spec allow_shell_hooks?() :: boolean()
  def allow_shell_hooks? do
    get_in(validated_workflow_options(), [:hooks, :allow_shell_hooks])
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec fleet_pause_default_ms() :: pos_integer()
  def fleet_pause_default_ms do
    get_in(validated_workflow_options(), [:agent, :fleet_pause_default_ms])
  end

  @spec fleet_pause_max_ms() :: pos_integer()
  def fleet_pause_max_ms do
    get_in(validated_workflow_options(), [:agent, :fleet_pause_max_ms])
  end

  @spec fleet_pause_pattern_window_ms() :: pos_integer()
  def fleet_pause_pattern_window_ms do
    get_in(validated_workflow_options(), [:agent, :fleet_pause_pattern_window_ms])
  end

  @spec fleet_pause_pattern_threshold() :: pos_integer()
  def fleet_pause_pattern_threshold do
    get_in(validated_workflow_options(), [:agent, :fleet_pause_pattern_threshold])
  end

  @spec fleet_probe_timeout_ms() :: pos_integer()
  def fleet_probe_timeout_ms do
    get_in(validated_workflow_options(), [:agent, :fleet_probe_timeout_ms])
  end

  @spec shutdown_timeout_ms() :: pos_integer()
  def shutdown_timeout_ms do
    case System.get_env("SHUTDOWN_TIMEOUT_MS") do
      nil ->
        get_in(validated_workflow_options(), [:agent, :shutdown_timeout_ms])

      value ->
        case Integer.parse(value) do
          {ms, ""} when ms > 0 -> ms
          _ -> get_in(validated_workflow_options(), [:agent, :shutdown_timeout_ms])
        end
    end
  end

  @spec agent_command() :: String.t()
  def agent_command do
    get_in(validated_workflow_options(), [:agent_server, :command])
  end

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    get_in(validated_workflow_options(), [:agent_server, :turn_timeout_ms])
  end

  @spec agent_approval_policy() :: String.t() | map()
  def agent_approval_policy do
    case resolve_agent_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_agent_approval_policy
    end
  end

  @spec agent_thread_sandbox() :: String.t()
  def agent_thread_sandbox do
    case resolve_agent_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_agent_thread_sandbox
    end
  end

  @spec agent_turn_sandbox_policy(Path.t() | nil) :: map()
  def agent_turn_sandbox_policy(workspace \\ nil) do
    case resolve_agent_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_agent_turn_sandbox_policy(workspace)
    end
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    get_in(validated_workflow_options(), [:agent_server, :read_timeout_ms])
  end

  @spec agent_stall_timeout_ms() :: pos_integer() | :disabled
  def agent_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:agent_server, :stall_timeout_ms])
    |> clamp_stall_timeout()
  end

  @spec agent_mcp_servers() :: map() | nil
  def agent_mcp_servers do
    case fetch_agent_mcp_servers() do
      :missing -> nil
      nil -> nil
      servers when is_map(servers) and map_size(servers) == 0 -> nil
      servers when is_map(servers) -> servers
      _ -> nil
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec observability_terminal_dashboard?() :: boolean()
  def observability_terminal_dashboard? do
    get_in(validated_workflow_options(), [:observability, :terminal_dashboard])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project(),
         :ok <- require_valid_agent_runtime_settings(),
         :ok <- require_agent_command(),
         :ok <- validate_hook_commands() do
      warn_state_limits_exceeding_global()
    end
  end

  @spec agent_runtime_settings(Path.t() | nil) :: {:ok, agent_runtime_settings()} | {:error, term()}
  def agent_runtime_settings(workspace \\ nil) do
    with {:ok, approval_policy} <- resolve_agent_approval_policy(),
         {:ok, thread_sandbox} <- resolve_agent_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_agent_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        slug = linear_project_slug()

        if is_binary(slug) and byte_size(slug) > 0 do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_agent_command do
    if byte_size(String.trim(agent_command())) > 0 do
      :ok
    else
      {:error, :missing_agent_command}
    end
  end

  defp require_valid_agent_runtime_settings do
    case agent_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_hook_commands do
    hooks = workspace_hooks()
    allow = hooks.allow_shell_hooks
    HookValidator.validate_all_hooks(hooks, allow)
  end

  defp warn_state_limits_exceeding_global do
    global_max = max_concurrent_agents()
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])

    Enum.each(state_limits, fn {state, limit} ->
      if limit > global_max do
        Logger.warning("Per-state agent limit for #{inspect(state)} (#{limit}) exceeds global max_concurrent_agents (#{global_max})")
      end
    end)

    :ok
  end

  @validated_opts_key :__symphony_config_validated_opts__

  defp validated_workflow_options do
    config = workflow_config()
    config_hash = :erlang.phash2(config)

    case Process.get(@validated_opts_key) do
      {^config_hash, opts} ->
        opts

      _ ->
        opts =
          config
          |> SymphonyElixir.Config.Parser.extract_workflow_options()
          |> NimbleOptions.validate!(SymphonyElixir.Config.Schema.workflow_options_schema())

        Process.put(@validated_opts_key, {config_hash, opts})
        opts
    end
  end

  @doc """
  Clears the per-process validated workflow options cache.
  Useful for tests that modify config mid-process.
  """
  @spec clear_validated_opts_cache() :: :ok
  def clear_validated_opts_cache do
    Process.delete(@validated_opts_key)
    :ok
  end

  defp fetch_agent_server_value(key, default) do
    config = workflow_config()

    case resolve_config_value(config, [["agent", key]]) do
      :missing ->
        case resolve_config_value(config, [["codex", key]]) do
          :missing ->
            default

          value ->
            Logger.warning("Config section [codex] is deprecated, use [agent] instead")
            value
        end

      value ->
        value
    end
  end

  defp fetch_agent_mcp_servers do
    config = workflow_config()

    case resolve_config_value(config, [["agent_server", "mcp_servers"], ["agent", "mcp_servers"]]) do
      :missing -> :missing
      value -> value
    end
  end

  defp resolve_agent_approval_policy do
    case fetch_agent_server_value("approval_policy", :missing) do
      :missing ->
        {:ok, @default_agent_approval_policy}

      nil ->
        {:ok, @default_agent_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_agent_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_agent_approval_policy, value}}
    end
  end

  defp resolve_agent_thread_sandbox do
    case fetch_agent_server_value("thread_sandbox", :missing) do
      :missing ->
        {:ok, @default_agent_thread_sandbox}

      nil ->
        {:ok, @default_agent_thread_sandbox}

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_agent_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_agent_thread_sandbox, value}}
    end
  end

  defp resolve_agent_turn_sandbox_policy(workspace) do
    case fetch_agent_server_value("turn_sandbox_policy", :missing) do
      :missing ->
        {:ok, default_agent_turn_sandbox_policy(workspace)}

      nil ->
        {:ok, default_agent_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_agent_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp default_agent_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp clamp_stall_timeout(0), do: :disabled

  defp clamp_stall_timeout(ms) when is_integer(ms) and ms < 0 do
    Logger.warning("agent_stall_timeout_ms is negative (#{ms}), treating as disabled")

    :disabled
  end

  defp clamp_stall_timeout(ms) when is_integer(ms) and ms < @min_agent_stall_timeout_ms do
    Logger.warning("agent_stall_timeout_ms #{ms} is below minimum #{@min_agent_stall_timeout_ms}, clamping to minimum")

    @min_agent_stall_timeout_ms
  end

  defp clamp_stall_timeout(ms) when is_integer(ms), do: ms

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
