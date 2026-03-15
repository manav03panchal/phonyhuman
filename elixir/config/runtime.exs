import Config

host = System.get_env("HOST", "localhost")
port = SymphonyElixir.RuntimeConfig.parse_port()

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  url: [host: host, port: port],
  http: [port: port],
  secret_key_base: SymphonyElixir.RuntimeConfig.secret_key_base!(config_env()),
  check_origin: SymphonyElixir.RuntimeConfig.check_origin(),
  live_view: [signing_salt: SymphonyElixir.RuntimeConfig.signing_salt("LIVE_VIEW_SIGNING_SALT")],
  session_signing_salt: SymphonyElixir.RuntimeConfig.signing_salt("SESSION_SIGNING_SALT"),
  session_encryption_salt: SymphonyElixir.RuntimeConfig.signing_salt("SESSION_ENCRYPTION_SALT")

if System.get_env("PHX_SERVER") do
  config :symphony_elixir, SymphonyElixirWeb.Endpoint, server: true
end
