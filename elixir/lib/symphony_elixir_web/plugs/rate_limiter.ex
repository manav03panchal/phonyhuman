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

  require Logger

  import Bitwise
  import Plug.Conn

  @default_rpm 100
  @window_seconds 60
  @table :symphony_rate_limiter

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    table = Keyword.get(opts, :table, @table)
    ensure_table(table)

    rpm = Keyword.get_lazy(opts, :rpm, &rpm_from_env/0)
    namespace = Keyword.get(opts, :namespace, :default)
    ip = client_ip(conn)
    now = System.system_time(:second)
    window_start = div(now, @window_seconds) * @window_seconds
    key = {namespace, ip, window_start}

    count = :ets.update_counter(table, key, {2, 1}, {key, 0})

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

  defp ensure_table(table) do
    :ets.new(table, [:public, :set, :named_table, {:write_concurrency, true}])
  rescue
    ArgumentError -> :ok
  end

  defp client_ip(conn) do
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()

    if trusted_proxy?(remote) do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded
          |> String.split(",", parts: 2)
          |> hd()
          |> String.trim()
          |> case do
            "" -> remote
            ip -> ip
          end

        [] ->
          remote
      end
    else
      remote
    end
  end

  defp trusted_proxy?(remote_ip) do
    case trusted_proxies() do
      [] -> false
      proxies -> Enum.any?(proxies, &cidr_match?(&1, remote_ip))
    end
  end

  defp trusted_proxies do
    case System.get_env("TRUSTED_PROXY_IPS") do
      nil -> []
      "" -> []
      val -> val |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp cidr_match?(cidr, ip) do
    case String.contains?(cidr, "/") do
      true -> cidr_range_match?(cidr, ip)
      false -> cidr == ip
    end
  end

  defp cidr_range_match?(cidr, ip_str) do
    with [net_str, mask_str] <- String.split(cidr, "/", parts: 2),
         {mask_bits, ""} <- Integer.parse(mask_str),
         {:ok, net_addr} <- :inet.parse_address(String.to_charlist(net_str)),
         {:ok, ip_addr} <- :inet.parse_address(String.to_charlist(ip_str)) do
      net_int = ip_to_integer(net_addr)
      ip_int = ip_to_integer(ip_addr)
      total_bits = tuple_size(net_addr) * 8
      shift = total_bits - mask_bits
      net_int >>> shift == ip_int >>> shift
    else
      _ -> false
    end
  end

  defp ip_to_integer({a, b, c, d}), do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    Bitwise.bsl(a, 112) + Bitwise.bsl(b, 96) + Bitwise.bsl(c, 80) + Bitwise.bsl(d, 64) +
      Bitwise.bsl(e, 48) + Bitwise.bsl(f, 32) + Bitwise.bsl(g, 16) + h
  end

  defp rpm_from_env do
    case System.get_env("RATE_LIMIT_RPM") do
      nil ->
        @default_rpm

      val ->
        case Integer.parse(val) do
          {rpm, ""} when rpm > 0 ->
            rpm

          _ ->
            Logger.warning("RATE_LIMIT_RPM=#{val} is not a valid positive integer, falling back to #{@default_rpm}")

            @default_rpm
        end
    end
  end
end
