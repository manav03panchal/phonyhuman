import Config

# Test-specific settings: disable server, keep info level for log capture tests
config :logger, level: :info

config :symphony_elixir, SymphonyElixirWeb.Endpoint, server: false

config :symphony_elixir, telemetry_collector_port: 0
