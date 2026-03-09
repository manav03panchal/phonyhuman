defmodule SymphonyElixirWeb.EventsController do
  @moduledoc """
  Server-Sent Events endpoint for real-time orchestrator state updates.

  Clients connect to `GET /api/v1/events` and receive a stream of SSE events:

    - `state_update` — full orchestrator state snapshot (sent on connect and on each PubSub broadcast)
    - `heartbeat` — periodic keepalive comment to detect stale connections

  The controller subscribes to `ObservabilityPubSub` so updates arrive within
  milliseconds of the orchestrator broadcasting a change.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @heartbeat_interval_ms 15_000

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, _params) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    ObservabilityPubSub.subscribe()
    conn = send_state_update(conn)
    schedule_heartbeat()
    sse_loop(conn)
  end

  defp sse_loop(conn) do
    receive do
      :observability_updated ->
        conn = send_state_update(conn)
        sse_loop(conn)

      :heartbeat ->
        case Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            schedule_heartbeat()
            sse_loop(conn)

          {:error, _reason} ->
            conn
        end
    after
      sse_idle_timeout_ms() -> conn
    end
  end

  defp send_state_update(conn) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    data = Jason.encode!(payload)

    event = "event: state_update\ndata: #{data}\n\n"

    case Conn.chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp sse_idle_timeout_ms do
    Endpoint.config(:sse_idle_timeout_ms) || :infinity
  end
end
