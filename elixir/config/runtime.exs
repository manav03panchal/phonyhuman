import Config

host = System.get_env("HOST", "localhost")
port = SymphonyElixir.RuntimeConfig.parse_port()

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  url: [host: host, port: port],
  http: [port: port],
  secret_key_base: SymphonyElixir.RuntimeConfig.secret_key_base!(config_env()),
  check_origin: SymphonyElixir.RuntimeConfig.check_origin()

if System.get_env("PHX_SERVER") do
  config :symphony_elixir, SymphonyElixirWeb.Endpoint, server: true
end
