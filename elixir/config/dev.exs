import Config

# Development-friendly defaults
config :logger, level: :debug

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  server: false,
  code_reloader: false
