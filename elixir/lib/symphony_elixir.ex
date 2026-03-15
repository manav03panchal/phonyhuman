defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :persistent_term.put(:symphony_started_at, System.monotonic_time(:second))
    :persistent_term.put(:symphony_shutting_down, false)
    SymphonyElixir.StatusDashboard.check_go_tui_binary()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      SymphonyElixir.AgentSupervisor,
      {SymphonyElixir.RestartMonitor, watched: [SymphonyElixir.AgentSupervisor]},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Linear.CircuitBreaker,
      SymphonyElixirWeb.Plugs.RateLimiter.Sweeper,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.TelemetryCollector,
      SymphonyElixir.HttpServer
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor,
      max_restarts: 10,
      max_seconds: 30
    )
  end

  @impl true
  def prep_stop(state) do
    :persistent_term.put(:symphony_shutting_down, true)
    state
  end

  @impl true
  def stop(_state) do
    :ok
  end
end
