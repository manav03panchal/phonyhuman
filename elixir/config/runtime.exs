import Config

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  secret_key_base: SymphonyElixir.RuntimeConfig.secret_key_base!(config_env()),
  check_origin: SymphonyElixir.RuntimeConfig.check_origin()
