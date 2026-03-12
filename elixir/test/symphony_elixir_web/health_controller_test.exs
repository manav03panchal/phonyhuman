defmodule SymphonyElixirWeb.HealthControllerTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule MockOrchestrator do
    use GenServer

    def start_link(snapshot, name), do: GenServer.start_link(__MODULE__, snapshot, name: name)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  setup do
    :persistent_term.put(:symphony_started_at, System.monotonic_time(:second))
    :persistent_term.put(:symphony_shutting_down, false)

    on_exit(fn ->
      :persistent_term.put(:symphony_shutting_down, false)
    end)

    :ok
  end

  describe "GET /health" do
    test "returns 200 with status, uptime_seconds, and active_agents" do
      orchestrator_name = :"health_test_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MockOrchestrator.start_link(
          %{running: [%{issue_id: "a"}, %{issue_id: "b"}], retrying: [], agent_totals: %{}},
          orchestrator_name
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

      conn = get(build_conn(), "/health")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert is_integer(body["uptime_seconds"])
      assert body["uptime_seconds"] >= 0
      assert body["active_agents"] == 2
    end

    test "returns 503 during shutdown" do
      orchestrator_name = :"health_shutdown_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MockOrchestrator.start_link(
          %{running: [], retrying: [], agent_totals: %{}},
          orchestrator_name
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

      :persistent_term.put(:symphony_shutting_down, true)

      conn = get(build_conn(), "/health")
      body = json_response(conn, 503)

      assert body["status"] == "shutting_down"
    end

    test "returns active_agents 0 when orchestrator is unavailable" do
      start_test_endpoint(orchestrator: :nonexistent_orchestrator, snapshot_timeout_ms: 5_000)

      conn = get(build_conn(), "/health")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["active_agents"] == 0
    end
  end

  describe "security headers on API routes" do
    test "API responses include security headers" do
      orchestrator_name = :"headers_test_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MockOrchestrator.start_link(
          %{running: [], retrying: [], agent_totals: %{}},
          orchestrator_name
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

      conn = get(build_conn(), "/health")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "strict-transport-security") == ["max-age=63072000"]

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
    end

    test "API state endpoint includes security headers" do
      orchestrator_name = :"headers_api_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MockOrchestrator.start_link(
          %{
            running: [],
            retrying: [],
            agent_totals: %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: 0
            },
            rate_limits: nil
          },
          orchestrator_name
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

      conn = get(build_conn(), "/api/v1/state")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end
end
