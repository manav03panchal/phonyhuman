defmodule SymphonyElixirWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets the `Content-Security-Policy` response header.

  Accepts a `:policy` option:

    * `:browser` (default) — allows self-hosted scripts, inline scripts
      (required for the LiveSocket bootstrap), stylesheets, WebSocket
      connections, and images.
    * `:api` — restrictive policy suitable for JSON-only endpoints.

  ## Examples

      plug SymphonyElixirWeb.Plugs.ContentSecurityPolicy
      plug SymphonyElixirWeb.Plugs.ContentSecurityPolicy, policy: :api
  """

  @behaviour Plug

  import Plug.Conn

  @browser_policy [
                    "default-src 'self'",
                    "script-src 'self' 'unsafe-inline'",
                    "style-src 'self' 'unsafe-inline'",
                    "connect-src 'self' ws: wss:",
                    "img-src 'self' data:",
                    "font-src 'self'",
                    "object-src 'none'",
                    "frame-ancestors 'none'"
                  ]
                  |> Enum.join("; ")

  @api_policy [
                "default-src 'none'",
                "frame-ancestors 'none'"
              ]
              |> Enum.join("; ")

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    policy =
      case Keyword.get(opts, :policy, :browser) do
        :browser -> @browser_policy
        :api -> @api_policy
      end

    put_resp_header(conn, "content-security-policy", policy)
  end
end
