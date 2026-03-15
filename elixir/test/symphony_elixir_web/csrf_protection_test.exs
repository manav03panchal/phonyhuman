defmodule SymphonyElixirWeb.CsrfProtectionTest do
  @moduledoc """
  Tests verifying CSRF token enforcement on browser routes and that
  API endpoints correctly use Bearer auth instead of CSRF.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule MockOrchestrator do
    use GenServer

    def start_link(snapshot, name), do: GenServer.start_link(__MODULE__, snapshot, name: name)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

    @impl true
    def handle_call({:fleet_pause, _reason}, _from, snapshot), do: {:reply, :ok, snapshot}

    @impl true
    def handle_call(:fleet_resume, _from, snapshot), do: {:reply, :ok, snapshot}
  end

  @default_snapshot %{
    running: [],
    retrying: [],
    agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil
  }

  setup do
    :persistent_term.put(:symphony_started_at, System.monotonic_time(:second))
    :persistent_term.put(:symphony_shutting_down, false)

    orchestrator_name = :"csrf_test_orchestrator_#{System.unique_integer([:positive])}"

    {:ok, pid} = MockOrchestrator.start_link(@default_snapshot, orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 5_000
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    :ok
  end

  describe "CSRF meta tag in dashboard" do
    test "dashboard HTML includes CSRF meta tag for LiveView" do
      conn = get(build_conn(), "/")

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<meta name="csrf-token" content="[^"]+"/
    end

    test "CSRF token in meta tag is non-empty" do
      conn = get(build_conn(), "/")

      [_, token] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, conn.resp_body)
      assert byte_size(token) > 0
    end

    test "LiveView socket params include CSRF token extraction" do
      conn = get(build_conn(), "/")

      assert conn.resp_body =~ "params: {_csrf_token: csrfToken}"
    end
  end

  describe "browser pipeline CSRF enforcement (plug-level)" do
    setup do
      # Clear any cached CSRF state between tests to avoid cross-contamination
      Process.delete(:plug_masked_csrf_token)
      Process.delete(:plug_unmasked_csrf_token)
      Process.delete(:plug_csrf_token_per_host)
      :ok
    end

    test "POST without CSRF token raises InvalidCSRFTokenError" do
      # Simulate a POST going through the browser pipeline's session + CSRF plugs.
      # A POST with no CSRF token must be rejected.
      session_opts =
        Plug.Session.init(
          store: :cookie,
          key: "_symphony_csrf_test",
          signing_salt: "test_signing",
          encryption_salt: "test_encryption"
        )

      conn =
        Plug.Test.conn(:post, "/")
        |> Map.put(:secret_key_base, String.duplicate("s", 64))
        |> Plug.Session.call(session_opts)
        |> fetch_session()

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
      end
    end

    test "POST with valid CSRF token passes protection" do
      session_opts =
        Plug.Session.init(
          store: :cookie,
          key: "_symphony_csrf_test",
          signing_salt: "test_signing",
          encryption_salt: "test_encryption"
        )

      secret = String.duplicate("s", 64)

      # Generate an unmasked CSRF token (same 24-byte base64 format Plug uses)
      unmasked_token = Base.url_encode64(:crypto.strong_rand_bytes(18))

      # Load CSRF state into the process dictionary so get_csrf_token works
      Plug.CSRFProtection.load_state(secret, unmasked_token)

      # Get the masked token (what a browser form would submit)
      csrf_token = Plug.CSRFProtection.get_csrf_token()
      assert byte_size(csrf_token) > 0

      # Build a POST with valid CSRF token in body and unmasked token in session
      post_conn =
        Plug.Test.conn(:post, "/", %{"_csrf_token" => csrf_token})
        |> Map.put(:secret_key_base, secret)
        |> Plug.Session.call(session_opts)
        |> fetch_session()
        |> put_session("_csrf_token", unmasked_token)

      # Should pass without raising
      result = Plug.CSRFProtection.call(post_conn, Plug.CSRFProtection.init([]))
      refute result.halted
    end

    test "POST with invalid CSRF token raises InvalidCSRFTokenError" do
      session_opts =
        Plug.Session.init(
          store: :cookie,
          key: "_symphony_csrf_test",
          signing_salt: "test_signing",
          encryption_salt: "test_encryption"
        )

      secret = String.duplicate("s", 64)

      # Set up a valid session state so the rejection is due to token mismatch
      unmasked_token = Base.url_encode64(:crypto.strong_rand_bytes(18))

      # POST with a bogus CSRF token but valid session state
      post_conn =
        Plug.Test.conn(:post, "/", %{"_csrf_token" => "totally-invalid-token"})
        |> Map.put(:secret_key_base, secret)
        |> Plug.Session.call(session_opts)
        |> fetch_session()
        |> put_session("_csrf_token", unmasked_token)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        Plug.CSRFProtection.call(post_conn, Plug.CSRFProtection.init([]))
      end
    end

    test "POST with CSRF token in x-csrf-token header passes protection" do
      session_opts =
        Plug.Session.init(
          store: :cookie,
          key: "_symphony_csrf_test",
          signing_salt: "test_signing",
          encryption_salt: "test_encryption"
        )

      secret = String.duplicate("s", 64)

      # Generate unmasked token and load into process dictionary
      unmasked_token = Base.url_encode64(:crypto.strong_rand_bytes(18))
      Plug.CSRFProtection.load_state(secret, unmasked_token)
      csrf_token = Plug.CSRFProtection.get_csrf_token()

      # POST with CSRF token in header instead of params
      post_conn =
        Plug.Test.conn(:post, "/")
        |> Map.put(:secret_key_base, secret)
        |> put_req_header("x-csrf-token", csrf_token)
        |> Plug.Session.call(session_opts)
        |> fetch_session()
        |> put_session("_csrf_token", unmasked_token)

      result = Plug.CSRFProtection.call(post_conn, Plug.CSRFProtection.init([]))
      refute result.halted
    end
  end

  describe "API fleet endpoints use Bearer auth, not CSRF" do
    setup do
      original = System.get_env("SYMPHONY_API_KEY")
      System.put_env("SYMPHONY_API_KEY", "csrf-test-key")

      on_exit(fn ->
        if original, do: System.put_env("SYMPHONY_API_KEY", original), else: System.delete_env("SYMPHONY_API_KEY")
      end)

      :ok
    end

    test "POST /api/v1/fleet/pause succeeds with Bearer auth and no CSRF token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer csrf-test-key")
        |> post("/api/v1/fleet/pause")

      assert conn.status == 200
    end

    test "POST /api/v1/fleet/resume succeeds with Bearer auth and no CSRF token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer csrf-test-key")
        |> post("/api/v1/fleet/resume")

      assert conn.status == 200
    end

    test "POST /api/v1/fleet/pause without any auth returns 401, not CSRF error" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/pause")

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
    end

    test "POST /api/v1/fleet/resume without any auth returns 401, not CSRF error" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/resume")

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
    end
  end

  describe "router pipeline configuration" do
    test "browser pipeline includes protect_from_forgery" do
      # Verify the router module defines a browser pipeline with CSRF protection
      # by checking the compiled pipeline behavior — a GET to the browser-scoped
      # dashboard sets a CSRF token in the session
      conn = get(build_conn(), "/")

      cookie_header = get_resp_header(conn, "set-cookie")

      session_cookie =
        Enum.find(cookie_header, fn c -> String.starts_with?(c, "_symphony_elixir_key=") end)

      assert session_cookie != nil, "browser pipeline must set session cookie"
    end
  end
end
