defmodule SymphonyElixirWeb.RateLimiterTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.get(state, :snapshot, %{running: [], retrying: []}), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)

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

  describe "request body size limit" do
    test "rejects request bodies larger than 1MB" do
      large_body = String.duplicate("x", 1_000_001)

      assert_error_sent(413, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, :post, "/api/v1/refresh", large_body)
      end)
    end
  end

  describe "rate limiting" do
    setup do
      if :ets.whereis(:symphony_rate_limiter) != :undefined do
        :ets.delete_all_objects(:symphony_rate_limiter)
      end

      original = System.get_env("RATE_LIMIT_RPM")
      System.put_env("RATE_LIMIT_RPM", "3")

      on_exit(fn ->
        restore_env("RATE_LIMIT_RPM", original)

        if :ets.whereis(:symphony_rate_limiter) != :undefined do
          :ets.delete_all_objects(:symphony_rate_limiter)
        end
      end)

      :ok
    end

    test "allows requests within rate limit" do
      conn = build_conn() |> get("/api/v1/state")
      assert conn.status in [200, 503]
    end

    test "returns 429 after exceeding rate limit" do
      for _ <- 1..3 do
        build_conn() |> get("/api/v1/state")
      end

      conn = build_conn() |> get("/api/v1/state")
      assert conn.status == 429
    end

    test "429 response includes Retry-After header" do
      for _ <- 1..3 do
        build_conn() |> get("/api/v1/state")
      end

      conn = build_conn() |> get("/api/v1/state")
      assert conn.status == 429

      [retry_after] = get_resp_header(conn, "retry-after")
      {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0 and seconds <= 60
    end

    test "429 response body contains error JSON" do
      for _ <- 1..3 do
        build_conn() |> get("/api/v1/state")
      end

      conn = build_conn() |> get("/api/v1/state")
      assert conn.status == 429

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "rate_limited"
      assert body["error"]["message"] == "Too Many Requests"
    end
  end
end
