defmodule SymphonyElixirWeb.BearerAuthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixirWeb.Plugs.BearerAuth

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply,
       Keyword.get(state, :snapshot, %{
         running: [],
         retrying: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: %{}
       }), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}, state}
    end

    def handle_call({:fleet_pause, _reason}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call(:fleet_resume, _from, state) do
      {:reply, :ok, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    orchestrator_name = Module.concat(__MODULE__, :AuthOrchestrator)

    {:ok, _pid} =
      start_supervised(
        {StaticOrchestrator,
         name: orchestrator_name,
         snapshot: %{
           running: [],
           retrying: [],
           agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: %{}
         }}
      )

    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 50
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    :ok
  end

  describe "when SYMPHONY_API_KEY is set" do
    setup do
      original = System.get_env("SYMPHONY_API_KEY")
      System.put_env("SYMPHONY_API_KEY", "test-secret-key-123")

      on_exit(fn ->
        restore_env("SYMPHONY_API_KEY", original)
      end)

      :ok
    end

    test "POST /api/v1/refresh returns 401 without Authorization header" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/refresh")

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
    end

    test "POST /api/v1/fleet/pause returns 401 without Authorization header" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/pause")

      assert conn.status == 401
    end

    test "POST /api/v1/fleet/resume returns 401 without Authorization header" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/resume")

      assert conn.status == 401
    end

    test "POST returns 401 with wrong Bearer token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer wrong-key")
        |> post("/api/v1/refresh")

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "unauthorized"
      assert body["error"]["message"] == "Invalid or missing API key"
    end

    test "POST returns 401 with non-Bearer authorization" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> post("/api/v1/refresh")

      assert conn.status == 401
    end

    test "POST /api/v1/refresh succeeds with correct Bearer token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-secret-key-123")
        |> post("/api/v1/refresh")

      assert conn.status in [200, 202]
    end

    test "POST /api/v1/fleet/pause succeeds with correct Bearer token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-secret-key-123")
        |> post("/api/v1/fleet/pause")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "paused"
    end

    test "POST /api/v1/fleet/resume succeeds with correct Bearer token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-secret-key-123")
        |> post("/api/v1/fleet/resume")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "resumed"
    end

    test "GET routes remain unauthenticated" do
      conn = build_conn() |> get("/health")
      assert conn.status in [200, 503]

      conn = build_conn() |> get("/api/v1/state")
      assert conn.status in [200, 503]
    end
  end

  describe "when SYMPHONY_API_KEY is not set" do
    setup do
      original = System.get_env("SYMPHONY_API_KEY")
      System.delete_env("SYMPHONY_API_KEY")

      on_exit(fn ->
        restore_env("SYMPHONY_API_KEY", original)
      end)

      :ok
    end

    test "POST /api/v1/refresh passes through without auth" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/refresh")

      assert conn.status in [200, 202]
    end

    test "POST /api/v1/fleet/pause passes through without auth" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/pause")

      assert conn.status == 200
    end

    test "POST /api/v1/fleet/resume passes through without auth" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/fleet/resume")

      assert conn.status == 200
    end
  end

  describe "plug init" do
    test "init returns opts unchanged" do
      assert BearerAuth.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "method not allowed still works" do
    test "GET /api/v1/refresh returns 405" do
      conn = build_conn() |> get("/api/v1/refresh")
      assert conn.status == 405
    end

    test "PUT /api/v1/fleet/pause returns 405" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/fleet/pause", "")

      assert conn.status == 405
    end
  end
end
