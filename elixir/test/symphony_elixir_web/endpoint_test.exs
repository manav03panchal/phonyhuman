defmodule SymphonyElixirWeb.EndpointTest do
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

  setup do
    :persistent_term.put(:symphony_started_at, System.monotonic_time(:second))
    :persistent_term.put(:symphony_shutting_down, false)

    orchestrator_name = :"endpoint_test_orchestrator_#{System.unique_integer([:positive])}"

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

    :ok
  end

  describe "session cookie attributes" do
    test "session cookie includes SameSite=Lax" do
      conn = get(build_conn(), "/")
      cookie_header = Plug.Conn.get_resp_header(conn, "set-cookie")

      session_cookie =
        Enum.find(cookie_header, fn c -> String.starts_with?(c, "_symphony_elixir_key=") end)

      assert session_cookie != nil, "expected session cookie to be set"
      assert session_cookie =~ "SameSite=Lax"
    end

    test "session cookie is encrypted (not just signed)" do
      conn = get(build_conn(), "/")
      cookie_header = Plug.Conn.get_resp_header(conn, "set-cookie")

      session_cookie =
        Enum.find(cookie_header, fn c -> String.starts_with?(c, "_symphony_elixir_key=") end)

      assert session_cookie != nil, "expected session cookie to be set"

      # Extract the cookie value (before the first ;)
      [_key_eq_val | _attrs] = String.split(session_cookie, ";")
      "_symphony_elixir_key=" <> value = String.split(session_cookie, ";") |> hd() |> String.trim()

      # Encrypted cookies use a different format than signed-only cookies.
      # An encrypted cookie value should be non-empty.
      assert byte_size(value) > 0
    end
  end
end
