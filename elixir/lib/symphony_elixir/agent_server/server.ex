defmodule SymphonyElixir.AgentServer.Server do
  @moduledoc """
  Minimal client for the agent server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{AgentServer.DynamicTool, AgentServer.Protocol, Config}

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(workspace) do
      metadata = port_metadata(port)
      expanded_workspace = Path.expand(workspace)

      try do
        with {:ok, session_policies} <- session_policies(expanded_workspace),
             {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
          {:ok,
           %{
             port: port,
             metadata: metadata,
             approval_policy: session_policies.approval_policy,
             auto_approve_requests: session_policies.approval_policy == "never",
             thread_sandbox: session_policies.thread_sandbox,
             turn_sandbox_policy: session_policies.turn_sandbox_policy,
             thread_id: thread_id,
             workspace: expanded_workspace
           }}
        else
          {:error, reason} ->
            stop_port(port)
            {:error, reason}
        end
      rescue
        e ->
          Logger.error("Unexpected exception during session init, closing port: #{Exception.message(e)}")
          stop_port(port)
          {:error, {:session_init_error, Exception.message(e)}}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &Protocol.default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case Protocol.start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Agent session started for #{issue_context(issue)} session_id=#{session_id}")

        Protocol.emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Agent session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Agent session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            Protocol.emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Agent session failed for #{issue_context(issue)}: #{inspect(reason)}")
        Protocol.emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())

    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp start_port(workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      env = otel_env_vars()

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(Config.agent_command())],
            cd: String.to_charlist(workspace),
            env: env,
            line: Protocol.port_line_bytes()
          ]
        )

      {:ok, port}
    end
  end

  defp otel_env_vars do
    # Port.open env: replaces the entire environment, so we must include
    # all inherited vars plus our OTel additions.
    base =
      System.get_env()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    if System.get_env("SYMPHONY_OTEL_DISABLED") == "1" do
      base
    else
      endpoint = System.get_env("SYMPHONY_OTEL_ENDPOINT") || "http://127.0.0.1:4318"

      otel = [
        {~c"CLAUDE_CODE_ENABLE_TELEMETRY", ~c"1"},
        {~c"OTEL_METRICS_EXPORTER", ~c"otlp"},
        {~c"OTEL_LOGS_EXPORTER", ~c"otlp"},
        {~c"OTEL_EXPORTER_OTLP_PROTOCOL", ~c"http/protobuf"},
        {~c"OTEL_EXPORTER_OTLP_ENDPOINT", String.to_charlist(endpoint)},
        {~c"OTEL_METRIC_EXPORT_INTERVAL", ~c"5000"},
        {~c"OTEL_LOGS_EXPORT_INTERVAL", ~c"2000"}
      ]

      otel_keys = MapSet.new(Enum.map(otel, fn {k, _} -> k end))
      filtered_base = Enum.reject(base, fn {k, _} -> MapSet.member?(otel_keys, k) end)
      filtered_base ++ otel
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{agent_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp session_policies(workspace) do
    Config.agent_runtime_settings(workspace)
  end

  defp do_start_session(port, workspace, session_policies) do
    case Protocol.send_initialize(port) do
      :ok -> Protocol.start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    Protocol.receive_loop(port, on_message, Config.agent_turn_timeout_ms(), "", tool_executor, auto_approve_requests)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end
end
