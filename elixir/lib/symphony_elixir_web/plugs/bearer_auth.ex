defmodule SymphonyElixirWeb.Plugs.BearerAuth do
  @moduledoc """
  Bearer token authentication plug for protected API endpoints.

  Reads the expected API key from the `SYMPHONY_API_KEY` environment variable.
  When the variable is set, requests must include an `Authorization: Bearer <key>`
  header with a matching key. When unset, all requests pass through (dev/test convenience).

  Uses constant-time comparison to prevent timing attacks.
  """

  @behaviour Plug

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case api_key() do
      nil -> conn
      expected -> verify_token(conn, expected)
    end
  end

  defp verify_token(conn, expected) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if Plug.Crypto.secure_compare(token, expected) do
          conn
        else
          unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing API key"}}))
    |> halt()
  end

  defp api_key do
    System.get_env("SYMPHONY_API_KEY")
  end
end
