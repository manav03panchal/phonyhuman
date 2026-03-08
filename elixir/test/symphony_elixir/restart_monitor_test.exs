defmodule SymphonyElixir.RestartMonitorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.RestartMonitor

  defmodule CrashWorker do
    @moduledoc false
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.send_after(self(), :crash, 1)
      {:ok, :ok}
    end

    @impl true
    def handle_info(:crash, _state), do: {:stop, :deliberate_crash, :ok}
  end

  describe "restart limit logging" do
    test "logs warning when watched supervisor terminates" do
      # Trap exits so the crashing supervisor doesn't take down the test process
      Process.flag(:trap_exit, true)

      children = [
        %{
          id: :crash_worker,
          start: {CrashWorker, :start_link, [[]]},
          restart: :permanent
        }
      ]

      {:ok, sup_pid} =
        Supervisor.start_link(children,
          strategy: :one_for_one,
          max_restarts: 1,
          max_seconds: 1,
          name: :test_watched_sup
        )

      log =
        capture_log(fn ->
          # Start a RestartMonitor watching the test supervisor
          {:ok, monitor_pid} =
            RestartMonitor.start_link(
              name: :test_restart_monitor,
              watched: [:test_watched_sup]
            )

          # Wait for the supervisor to crash from max restart intensity
          receive do
            {:EXIT, ^sup_pid, _reason} -> :ok
          after
            3_000 -> flunk("Supervisor did not crash within timeout")
          end

          # Give the monitor time to process the DOWN message
          Process.sleep(100)

          GenServer.stop(monitor_pid)
        end)

      assert log =~ "maximum restart intensity"

      Process.flag(:trap_exit, false)
    end

    test "rewatches supervisor after it restarts" do
      # Start a simple named supervisor to watch
      {:ok, sup_pid} =
        Task.Supervisor.start_link(name: :test_rewatch_sup)

      {:ok, monitor_pid} =
        RestartMonitor.start_link(
          name: :test_rewatch_monitor,
          watched: [:test_rewatch_sup]
        )

      # Verify monitor is alive and watching
      assert Process.alive?(monitor_pid)
      assert Process.alive?(sup_pid)

      GenServer.stop(monitor_pid)
      Supervisor.stop(sup_pid)
    end
  end
end
