defmodule SymphonyElixirWeb.StaticAssetSecurityTest do
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

    orchestrator_name = :"static_asset_security_orchestrator_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MockOrchestrator.start_link(
        %{running: [], retrying: [], agent_totals: %{}},
        orchestrator_name
      )

    on_exit(fn ->
      :persistent_term.put(:symphony_shutting_down, false)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)
    :ok
  end

  describe "security headers on static asset routes" do
    test "dashboard.css includes security headers" do
      conn = get(build_conn(), "/dashboard.css")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "phoenix_html.js includes security headers" do
      conn = get(build_conn(), "/vendor/phoenix_html/phoenix_html.js")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "phoenix.js includes security headers" do
      conn = get(build_conn(), "/vendor/phoenix/phoenix.js")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "phoenix_live_view.js includes security headers" do
      conn = get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end
end
