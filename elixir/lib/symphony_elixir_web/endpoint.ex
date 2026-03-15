defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @compile_session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "compile_time_placeholder",
    encryption_salt: "compile_time_placeholder",
    same_site: "Lax",
    secure: Mix.env() == :prod
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @compile_session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 1_000_000
  )

  plug(Plug.Head)
  plug(:runtime_session)
  plug(SymphonyElixirWeb.Router)

  @doc false
  def runtime_session(conn, _opts) do
    config = Application.get_env(:symphony_elixir, __MODULE__, [])

    session_opts =
      @compile_session_options
      |> Keyword.put(:signing_salt, config[:session_signing_salt] || "dev_signing_salt")
      |> Keyword.put(:encryption_salt, config[:session_encryption_salt] || "dev_encryption_salt")

    opts = Plug.Session.init(session_opts)
    Plug.Session.call(conn, opts)
  end
end
