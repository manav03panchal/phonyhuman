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

  describe "rate limiting with invalid RATE_LIMIT_RPM" do
    setup do
      if :ets.whereis(:symphony_rate_limiter) != :undefined do
        :ets.delete_all_objects(:symphony_rate_limiter)
      end

      original = System.get_env("RATE_LIMIT_RPM")
      System.put_env("RATE_LIMIT_RPM", "abc")

      on_exit(fn ->
        restore_env("RATE_LIMIT_RPM", original)

        if :ets.whereis(:symphony_rate_limiter) != :undefined do
          :ets.delete_all_objects(:symphony_rate_limiter)
        end
      end)

      :ok
    end

    test "falls back to default RPM when RATE_LIMIT_RPM is non-integer" do
      log =
        capture_log(fn ->
          # With default RPM of 100, 4 requests should all succeed (not hit rate limit)
          for _ <- 1..4 do
            conn = build_conn() |> get("/api/v1/state")
            assert conn.status in [200, 503]
          end
        end)

      assert log =~ "RATE_LIMIT_RPM=abc is not a valid positive integer"
    end
  end

  describe "concurrent plug init" do
    test "concurrent ensure_table calls don't crash" do
      # Delete and recreate the table owned by the test process so it
      # persists across concurrent Task processes (ETS tables are owned
      # by their creator and destroyed when that process exits).
      if :ets.whereis(:symphony_rate_limiter) != :undefined do
        :ets.delete(:symphony_rate_limiter)
      end

      # First request creates the table owned by the test process
      # (Phoenix.ConnTest.dispatch runs in the calling process)
      conn = build_conn() |> get("/api/v1/state")
      assert conn.status in [200, 429, 503]
      assert :ets.whereis(:symphony_rate_limiter) != :undefined

      # Now spawn concurrent requests — each hits ensure_table which
      # attempts :ets.new and rescues ArgumentError (table exists).
      # This verifies the atomic try/rescue pattern handles concurrency.
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            conn = build_conn() |> get("/api/v1/state")
            conn.status
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All requests should succeed (no crashes from ensure_table)
      assert Enum.all?(results, fn status -> status in [200, 429, 503] end)

      # Table should still exist and be usable
      assert :ets.whereis(:symphony_rate_limiter) != :undefined
      assert :ets.info(:symphony_rate_limiter, :type) == :set
    end

    test "ensure_table atomic creation pattern handles concurrent :ets.new" do
      # Directly test the atomic try/rescue pattern by racing 50 processes
      # to create the same named ETS table.
      table = :test_concurrent_create

      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end

      barrier = :counters.new(1, [])
      n = 50

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            :counters.add(barrier, 1, 1)
            # Spin until all tasks are ready to race
            Stream.repeatedly(fn -> :counters.get(barrier, 1) end)
            |> Enum.find(&(&1 >= n))

            try do
              :ets.new(table, [:public, :set, :named_table])
              :created
            rescue
              ArgumentError -> :already_exists
            end
          end)
        end

      results = Task.await_many(tasks, 5_000)

      created_count = Enum.count(results, &(&1 == :created))
      exists_count = Enum.count(results, &(&1 == :already_exists))

      # At least one must have created the table
      assert created_count >= 1
      # All tasks completed without crashing
      assert created_count + exists_count == n

      # Cleanup
      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end
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

  describe "X-Forwarded-For client IP extraction" do
    setup do
      if :ets.whereis(:symphony_rate_limiter) != :undefined do
        :ets.delete_all_objects(:symphony_rate_limiter)
      end

      original_rpm = System.get_env("RATE_LIMIT_RPM")
      original_proxies = System.get_env("TRUSTED_PROXY_IPS")
      System.put_env("RATE_LIMIT_RPM", "3")
      System.put_env("TRUSTED_PROXY_IPS", "127.0.0.1")

      on_exit(fn ->
        restore_env("RATE_LIMIT_RPM", original_rpm)
        restore_env("TRUSTED_PROXY_IPS", original_proxies)

        if :ets.whereis(:symphony_rate_limiter) != :undefined do
          :ets.delete_all_objects(:symphony_rate_limiter)
        end
      end)

      :ok
    end

    test "uses X-Forwarded-For IP for rate limiting" do
      # Exhaust the limit for client 10.0.0.1
      for _ <- 1..3 do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.1")
        |> get("/api/v1/state")
      end

      # 4th request from same forwarded IP should be rate limited
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.1")
        |> get("/api/v1/state")

      assert conn.status == 429
    end

    test "different X-Forwarded-For IPs get separate rate limit buckets" do
      # Exhaust the limit for client 10.0.0.1
      for _ <- 1..3 do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.1")
        |> get("/api/v1/state")
      end

      # Request from different forwarded IP should not be rate limited
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.2")
        |> get("/api/v1/state")

      assert conn.status in [200, 503]
    end

    test "uses leftmost IP from multi-IP X-Forwarded-For" do
      # Exhaust with "10.0.0.1, proxy1, proxy2"
      for _ <- 1..3 do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.1, 192.168.1.1, 172.16.0.1")
        |> get("/api/v1/state")
      end

      # Same leftmost IP should be rate limited
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.1, 192.168.1.99")
        |> get("/api/v1/state")

      assert conn.status == 429
    end

    test "falls back to remote_ip when X-Forwarded-For is absent" do
      # Requests without X-Forwarded-For should use conn.remote_ip
      for _ <- 1..3 do
        build_conn() |> get("/api/v1/state")
      end

      conn = build_conn() |> get("/api/v1/state")
      assert conn.status == 429
    end

    test "falls back to remote_ip when X-Forwarded-For is empty" do
      for _ <- 1..3 do
        build_conn()
        |> put_req_header("x-forwarded-for", "")
        |> get("/api/v1/state")
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "")
        |> get("/api/v1/state")

      assert conn.status == 429
    end
  end
end
