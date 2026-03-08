defmodule SymphonyElixirWeb.HealthController do
  @moduledoc """
  Lightweight health check endpoint for monitoring and orchestration.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.Endpoint

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    if :persistent_term.get(:symphony_shutting_down, false) do
      conn
      |> put_status(503)
      |> json(%{status: "shutting_down"})
    else
      conn
      |> json(%{
        status: "ok",
        uptime_seconds: uptime_seconds(),
        active_agents: active_agents()
      })
    end
  end

  defp uptime_seconds do
    started_at = :persistent_term.get(:symphony_started_at, System.monotonic_time(:second))
    System.monotonic_time(:second) - started_at
  end

  defp active_agents do
    orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

    case SymphonyElixir.Orchestrator.snapshot(orchestrator, 5_000) do
      %{running: running} -> length(running)
      _ -> 0
    end
  end
end
