defmodule SymphonyElixir.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for agent processes, backed by Task.Supervisor.

  Isolates agent crashes from infrastructure processes (HTTP server, telemetry,
  orchestrator) by supervising all agent tasks in a separate subtree with higher
  restart limits than the main application supervisor.
  """

  require Logger

  @max_restarts 10
  @max_seconds 60

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Task.Supervisor.start_link(
      Keyword.merge(
        [name: __MODULE__, max_restarts: @max_restarts, max_seconds: @max_seconds],
        opts
      )
    )
  end

  @spec start_agent((-> any())) :: DynamicSupervisor.on_start_child()
  def start_agent(fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(__MODULE__, fun)
  end

  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
    Task.Supervisor.terminate_child(__MODULE__, pid)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
