defmodule SymphonyElixirWeb.EventsControllerTest do
  use ExUnit.Case

  import Phoenix.ConnTest

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

  defp mock_snapshot do
    %{
      running: [
        %{
          issue_id: "id-1",
          identifier: "HUM-1",
          state: "In Progress",
          session_id: "sess-1",
          turn_count: 3,
          last_agent_event: "message",
          last_agent_message: "working",
          started_at: ~U[2026-03-08 12:00:00Z],
          last_agent_timestamp: ~U[2026-03-08 12:05:00Z],
          model: "claude-opus-4.6",
          agent_input_tokens: 1000,
          agent_output_tokens: 500,
          agent_total_tokens: 1500,
          agent_cache_read_tokens: 100,
          agent_cost_usd: 0.05,
          otel_tool_executions: [],
          otel_lines_changed: 10,
          otel_commits_count: 1,
          otel_prs_count: 0,
          otel_api_errors: 0,
          otel_active_time_seconds: 300
        }
      ],
      retrying: [],
      agent_totals: %{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        seconds_running: 300
      },
      rate_limits: nil,
      fleet_status: "running",
      fleet_paused_until: nil,
      fleet_pause_reason: nil
    }
  end

  describe "GET /api/v1/events" do
    test "returns chunked response with text/event-stream content type" do
      orchestrator_name = :"events_test_orch_#{System.unique_integer([:positive])}"
      {:ok, pid} = MockOrchestrator.start_link(mock_snapshot(), orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000, sse_idle_timeout_ms: 100)

      conn = get(build_conn(), "/api/v1/events")

      assert conn.status == 200

      content_type = Plug.Conn.get_resp_header(conn, "content-type") |> List.first("")
      assert content_type =~ "text/event-stream"

      assert conn.state == :chunked
    end

    test "initial chunk contains state_update event with valid JSON" do
      orchestrator_name = :"events_init_orch_#{System.unique_integer([:positive])}"
      {:ok, pid} = MockOrchestrator.start_link(mock_snapshot(), orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000, sse_idle_timeout_ms: 100)

      conn = get(build_conn(), "/api/v1/events")

      # The response body should contain at least the initial state_update
      body = conn.resp_body || ""
      assert body =~ "event: state_update"
      assert body =~ "data: "

      # Extract the data line and verify it's valid JSON
      data_line =
        body
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "data: "))

      assert data_line != nil
      json_str = String.replace_prefix(data_line, "data: ", "")
      assert {:ok, parsed} = Jason.decode(json_str)
      assert is_binary(parsed["generated_at"])
      assert is_list(parsed["running"])
      assert length(parsed["running"]) == 1
    end

    test "includes security headers" do
      orchestrator_name = :"events_headers_orch_#{System.unique_integer([:positive])}"
      {:ok, pid} = MockOrchestrator.start_link(mock_snapshot(), orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000, sse_idle_timeout_ms: 100)

      conn = get(build_conn(), "/api/v1/events")

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "method not allowed for POST" do
      orchestrator_name = :"events_post_orch_#{System.unique_integer([:positive])}"
      {:ok, pid} = MockOrchestrator.start_link(mock_snapshot(), orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000, sse_idle_timeout_ms: 100)

      conn = post(build_conn(), "/api/v1/events")
      body = json_response(conn, 405)
      assert body["error"]["code"] == "method_not_allowed"
    end
  end
end
