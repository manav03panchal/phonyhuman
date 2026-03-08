defmodule SymphonyElixir.TelemetryCollector do
  @moduledoc """
  Lightweight OTLP/HTTP receiver that accepts OpenTelemetry metric and log
  export requests from Claude Code processes, extracts `claude_code.*` data,
  aggregates per session, and forwards to the orchestrator.
  """

  use GenServer
  require Logger

  @default_port 4318
  @claude_code_prefix "claude_code."

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ingest_metrics(GenServer.server(), map()) :: :ok
  def ingest_metrics(server \\ __MODULE__, payload) do
    GenServer.cast(server, {:ingest_metrics, payload})
  end

  @spec ingest_logs(GenServer.server(), map()) :: :ok
  def ingest_logs(server \\ __MODULE__, payload) do
    GenServer.cast(server, {:ingest_logs, payload})
  end

  @spec get_state(GenServer.server()) :: map()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec bound_port(GenServer.server()) :: non_neg_integer() | nil
  def bound_port(server \\ __MODULE__) do
    GenServer.call(server, :bound_port)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, configured_port())
    orchestrator = Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator)

    case start_listener(port, opts) do
      {:ok, listener_ref} ->
        # Unlink so a listener crash doesn't take down the collector;
        # monitor instead to log and clear the ref.
        Process.unlink(listener_ref)
        listener_monitor = Process.monitor(listener_ref)
        bound = resolve_bound_port(listener_ref)

        {:ok,
         %{
           sessions: %{},
           orchestrator: orchestrator,
           listener_ref: listener_ref,
           listener_monitor: listener_monitor,
           port: port,
           bound_port: bound
         }}

      {:error, reason} ->
        Logger.warning("TelemetryCollector failed to start HTTP listener: #{inspect(reason)}")
        {:ok, %{sessions: %{}, orchestrator: orchestrator, listener_ref: nil, listener_monitor: nil, port: port, bound_port: nil}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{listener_monitor: ref} = state) do
    Logger.warning("TelemetryCollector listener exited: #{inspect(reason)}")
    {:noreply, %{state | listener_ref: nil, listener_monitor: nil, bound_port: nil}}
  end

  @impl true
  def handle_cast({:ingest_metrics, payload}, state) do
    sessions = parse_resource_metrics(payload)
    new_state = merge_sessions(state, sessions)
    notify_orchestrator(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:ingest_logs, payload}, state) do
    sessions = parse_resource_logs(payload)
    new_state = merge_log_sessions(state, sessions)
    notify_orchestrator(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.sessions, state}
  end

  def handle_call(:bound_port, _from, state) do
    {:reply, state.bound_port, state}
  end

  @impl true
  def terminate(_reason, %{listener_ref: ref}) when is_pid(ref) do
    if Process.alive?(ref), do: Supervisor.stop(ref, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -------------------------------------------------------------------
  # OTLP Metric Parsing
  # -------------------------------------------------------------------

  @doc false
  def parse_resource_metrics(%{"resourceMetrics" => resource_metrics}) when is_list(resource_metrics) do
    Enum.reduce(resource_metrics, %{}, fn rm, acc ->
      session_id = extract_session_id(rm)
      metrics = extract_scope_metrics(Map.get(rm, "scopeMetrics", []))

      if metrics != %{} do
        Map.update(acc, session_id, metrics, &deep_merge_metrics(&1, metrics))
      else
        acc
      end
    end)
  end

  def parse_resource_metrics(_), do: %{}

  @doc false
  def parse_resource_logs(%{"resourceLogs" => resource_logs}) when is_list(resource_logs) do
    Enum.reduce(resource_logs, %{}, fn rl, acc ->
      session_id = extract_session_id(rl)
      events = extract_scope_logs(Map.get(rl, "scopeLogs", []))

      if events != [] do
        Map.update(acc, session_id, %{events: events}, fn existing ->
          Map.update(existing, :events, events, &(&1 ++ events))
        end)
      else
        acc
      end
    end)
  end

  def parse_resource_logs(_), do: %{}

  # -------------------------------------------------------------------
  # Internals
  # -------------------------------------------------------------------

  defp configured_port do
    Application.get_env(:symphony_elixir, :telemetry_collector_port, @default_port)
  end

  defp resolve_bound_port(bandit_pid) when is_pid(bandit_pid) do
    children = Supervisor.which_children(bandit_pid)

    case Enum.find(children, fn {id, _, _, _} -> id == :listener end) do
      {:listener, listener_pid, _, _} when is_pid(listener_pid) ->
        state = :sys.get_state(listener_pid)

        case state do
          %{local_info: {_ip, port}} when is_integer(port) -> port
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_bound_port(_), do: nil

  defp start_listener(port, opts) when is_integer(port) and port >= 0 do
    collector = Keyword.get(opts, :name, __MODULE__)

    plug_opts = %{collector: collector}

    bandit_opts = [
      plug: {SymphonyElixir.TelemetryCollector.Router, plug_opts},
      port: port,
      ip: {127, 0, 0, 1},
      thousand_island_options: [num_acceptors: 2]
    ]

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  defp start_listener(_port, _opts), do: {:error, :invalid_port}

  defp extract_session_id(%{"resource" => %{"attributes" => attrs}}) when is_list(attrs) do
    Enum.find_value(attrs, "unknown", fn
      %{"key" => "session.id", "value" => %{"stringValue" => id}} -> id
      _ -> nil
    end)
  end

  defp extract_session_id(_), do: "unknown"

  defp extract_scope_metrics(scope_metrics) when is_list(scope_metrics) do
    Enum.reduce(scope_metrics, %{}, fn sm, acc ->
      metrics = Map.get(sm, "metrics", [])

      Enum.reduce(metrics, acc, fn metric, inner_acc ->
        name = Map.get(metric, "name", "")

        if String.starts_with?(name, @claude_code_prefix) do
          data_points = extract_data_points(metric)
          Map.put(inner_acc, name, data_points)
        else
          inner_acc
        end
      end)
    end)
  end

  defp extract_scope_metrics(_), do: %{}

  defp extract_data_points(metric) do
    cond do
      Map.has_key?(metric, "sum") ->
        get_in(metric, ["sum", "dataPoints"]) |> parse_data_points()

      Map.has_key?(metric, "gauge") ->
        get_in(metric, ["gauge", "dataPoints"]) |> parse_data_points()

      Map.has_key?(metric, "histogram") ->
        get_in(metric, ["histogram", "dataPoints"]) |> parse_histogram_points()

      true ->
        []
    end
  end

  defp parse_data_points(nil), do: []

  defp parse_data_points(points) when is_list(points) do
    Enum.map(points, fn point ->
      value =
        cond do
          Map.has_key?(point, "asInt") -> parse_int_value(point["asInt"])
          Map.has_key?(point, "asDouble") -> point["asDouble"]
          true -> 0
        end

      attrs = parse_attributes(Map.get(point, "attributes", []))
      %{value: value, attributes: attrs}
    end)
  end

  defp parse_data_points(_), do: []

  defp parse_histogram_points(nil), do: []

  defp parse_histogram_points(points) when is_list(points) do
    Enum.map(points, fn point ->
      attrs = parse_attributes(Map.get(point, "attributes", []))

      %{
        value: Map.get(point, "sum", 0),
        count: Map.get(point, "count", 0),
        attributes: attrs
      }
    end)
  end

  defp parse_histogram_points(_), do: []

  defp parse_attributes(attrs) when is_list(attrs) do
    Map.new(attrs, fn
      %{"key" => key, "value" => %{"stringValue" => v}} -> {key, v}
      %{"key" => key, "value" => %{"intValue" => v}} -> {key, parse_int_value(v)}
      %{"key" => key, "value" => %{"doubleValue" => v}} -> {key, v}
      %{"key" => key, "value" => %{"boolValue" => v}} -> {key, v}
      %{"key" => key} -> {key, nil}
    end)
  end

  defp parse_attributes(_), do: %{}

  defp parse_int_value(v) when is_integer(v), do: v
  defp parse_int_value(v) when is_binary(v), do: String.to_integer(v)
  defp parse_int_value(v), do: v

  defp extract_scope_logs(scope_logs) when is_list(scope_logs) do
    Enum.flat_map(scope_logs, fn sl ->
      log_records = Map.get(sl, "logRecords", [])

      log_records
      |> Enum.filter(fn record ->
        body = get_in(record, ["body", "stringValue"]) || ""
        String.starts_with?(body, @claude_code_prefix)
      end)
      |> Enum.map(fn record ->
        %{
          name: get_in(record, ["body", "stringValue"]),
          attributes: parse_attributes(Map.get(record, "attributes", [])),
          timestamp: Map.get(record, "timeUnixNano"),
          severity: Map.get(record, "severityText")
        }
      end)
    end)
  end

  defp extract_scope_logs(_), do: []

  defp merge_sessions(state, new_sessions) do
    updated =
      Enum.reduce(new_sessions, state.sessions, fn {session_id, metrics}, acc ->
        Map.update(acc, session_id, metrics, &deep_merge_metrics(&1, metrics))
      end)

    %{state | sessions: updated}
  end

  defp merge_log_sessions(state, new_sessions) do
    updated =
      Enum.reduce(new_sessions, state.sessions, fn {session_id, data}, acc ->
        Map.update(acc, session_id, data, fn existing ->
          Map.update(existing, :events, Map.get(data, :events, []), fn existing_events ->
            existing_events ++ Map.get(data, :events, [])
          end)
        end)
      end)

    %{state | sessions: updated}
  end

  defp deep_merge_metrics(existing, new) do
    Map.merge(existing, new, fn
      _key, old_val, new_val when is_list(old_val) and is_list(new_val) ->
        new_val

      _key, old_val, new_val when is_map(old_val) and is_map(new_val) ->
        deep_merge_metrics(old_val, new_val)

      _key, _old_val, new_val ->
        new_val
    end)
  end

  defp notify_orchestrator(%{sessions: sessions, orchestrator: orchestrator}) do
    Enum.each(sessions, fn {session_id, metrics} ->
      send_to_orchestrator(orchestrator, session_id, metrics)
    end)
  end

  defp send_to_orchestrator(orchestrator, session_id, metrics) do
    if is_pid(orchestrator) do
      send(orchestrator, {:otel_metrics, session_id, metrics})
    else
      case Process.whereis(orchestrator) do
        nil -> :ok
        pid -> send(pid, {:otel_metrics, session_id, metrics})
      end
    end
  end
end

defmodule SymphonyElixir.TelemetryCollector.Router do
  @moduledoc """
  Plug router that receives OTLP/HTTP JSON export requests and forwards
  them to the TelemetryCollector GenServer.
  """

  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000
  )

  plug(SymphonyElixirWeb.Plugs.RateLimiter, namespace: :otel)
  plug(:match)
  plug(:dispatch)

  post "/v1/metrics" do
    collector = conn.private[:collector] || SymphonyElixir.TelemetryCollector
    SymphonyElixir.TelemetryCollector.ingest_metrics(collector, conn.body_params)
    send_resp(conn, 200, ~s({"partialSuccess":{}}))
  end

  post "/v1/logs" do
    collector = conn.private[:collector] || SymphonyElixir.TelemetryCollector
    SymphonyElixir.TelemetryCollector.ingest_logs(collector, conn.body_params)
    send_resp(conn, 200, ~s({"partialSuccess":{}}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl Plug
  def call(conn, opts) when is_map(opts) do
    conn
    |> Plug.Conn.put_private(:collector, Map.get(opts, :collector, SymphonyElixir.TelemetryCollector))
    |> super(opts)
  end
end
