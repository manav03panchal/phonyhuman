defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_agent_command "claude app-server"
  @default_agent_turn_timeout_ms 3_600_000
  @default_agent_read_timeout_ms 5_000
  @default_agent_stall_timeout_ms 300_000
  @default_shutdown_timeout_ms 60_000
  @default_fleet_pause_default_ms 1_800_000
  @default_fleet_pause_max_ms 14_400_000
  @default_fleet_pause_pattern_window_ms 60_000
  @default_fleet_pause_pattern_threshold 3
  @default_fleet_probe_timeout_ms 300_000
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_observability_terminal_dashboard false
  @default_server_host "127.0.0.1"

  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 fleet_pause_default_ms: [
                                   type: :pos_integer,
                                   default: @default_fleet_pause_default_ms
                                 ],
                                 fleet_pause_max_ms: [
                                   type: :pos_integer,
                                   default: @default_fleet_pause_max_ms
                                 ],
                                 fleet_pause_pattern_window_ms: [
                                   type: :pos_integer,
                                   default: @default_fleet_pause_pattern_window_ms
                                 ],
                                 fleet_pause_pattern_threshold: [
                                   type: :pos_integer,
                                   default: @default_fleet_pause_pattern_threshold
                                 ],
                                 fleet_probe_timeout_ms: [
                                   type: :pos_integer,
                                   default: @default_fleet_probe_timeout_ms
                                 ],
                                 shutdown_timeout_ms: [
                                   type: :pos_integer,
                                   default: @default_shutdown_timeout_ms
                                 ]
                               ]
                             ],
                             agent_server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_agent_command],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_stall_timeout_ms
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms],
                                 allow_shell_hooks: [type: :boolean, default: true]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ],
                                 terminal_dashboard: [
                                   type: :boolean,
                                   default: @default_observability_terminal_dashboard
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  def workflow_options_schema, do: @workflow_options_schema
end
