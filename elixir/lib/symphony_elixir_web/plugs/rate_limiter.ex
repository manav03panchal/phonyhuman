defmodule SymphonyElixirWeb.Plugs.RateLimiter do
  @moduledoc """
  ETS-based per-IP rate limiter plug.

  Returns 429 Too Many Requests with a Retry-After header when the
  per-IP request count exceeds the configured threshold within a
  60-second sliding window.

  ## Options

    * `:rpm` — maximum requests per minute (default: value of
      `RATE_LIMIT_RPM` env var, or 100)
    * `:namespace` — atom key to isolate counters between different
      plug instances (default: `:default`)
  """

  @behaviour Plug

  import Plug.Conn

  @default_rpm 100
  @window_seconds 60
  @table :symphony_rate_limiter

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    ensure_table()

    rpm = Keyword.get_lazy(opts, :rpm, &rpm_from_env/0)
    namespace = Keyword.get(opts, :namespace, :default)
    ip = client_ip(conn)
    now = System.system_time(:second)
    window_start = div(now, @window_seconds) * @window_seconds
    key = {namespace, ip, window_start}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count > rpm do
      retry_after = max(window_start + @window_seconds - now, 1)

      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after))
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{error: %{code: "rate_limited", message: "Too Many Requests"}})
      )
      |> halt()
    else
      conn
    end
  end

  defp ensure_table do
    :ets.new(@table, [:public, :set, :named_table, {:write_concurrency, true}])
  rescue
    ArgumentError -> :ok
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp rpm_from_env do
    case System.get_env("RATE_LIMIT_RPM") do
      nil -> @default_rpm
      val -> String.to_integer(val)
    end
  end
end
