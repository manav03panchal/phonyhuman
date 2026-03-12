defmodule SymphonyElixirWeb.ContentSecurityPolicyTest do
  use ExUnit.Case

  alias SymphonyElixirWeb.Plugs.ContentSecurityPolicy

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

    orchestrator_name = :"csp_test_orchestrator_#{System.unique_integer([:positive])}"

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

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      :persistent_term.put(:symphony_shutting_down, false)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

    :ok
  end

  describe "Content-Security-Policy on API routes" do
    test "health endpoint includes CSP header with restrictive API policy" do
      conn = get(build_conn(), "/health")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "script-src"
    end

    test "API state endpoint includes CSP header" do
      conn = get(build_conn(), "/api/v1/state")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
    end
  end

  describe "ContentSecurityPolicy plug unit" do
    test "browser policy includes script-src with unsafe-inline" do
      conn =
        build_conn()
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' 'unsafe-inline'"
      assert csp =~ "default-src 'self'"
      assert csp =~ "style-src 'self' 'unsafe-inline'"
      assert csp =~ "connect-src 'self' ws: wss:"
      assert csp =~ "img-src 'self' data:"
      assert csp =~ "font-src 'self'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
    end

    test "api policy is restrictive" do
      conn =
        build_conn()
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init(policy: :api))

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp == "default-src 'none'; frame-ancestors 'none'"
    end
  end
end
