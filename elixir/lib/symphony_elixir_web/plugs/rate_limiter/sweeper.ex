defmodule SymphonyElixirWeb.Plugs.RateLimiter.Sweeper do
  @moduledoc """
  Periodic cleanup for the ETS-backed rate limiter.

  Deletes entries whose `window_start` is older than `2 * window_seconds`,
  preventing unbounded table growth.
  """

  use GenServer

  @table :symphony_rate_limiter
  @window_seconds 60
  @sweep_interval_ms :timer.seconds(@window_seconds)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @spec sweep() :: non_neg_integer()
  def sweep do
    if :ets.whereis(@table) == :undefined do
      0
    else
      now = System.system_time(:second)
      cutoff = div(now, @window_seconds) * @window_seconds - 2 * @window_seconds

      # Select keys where window_start (element 3 of the key tuple) < cutoff
      # Key format: {{namespace, ip, window_start}, count}
      match_spec = [{{:"$1", :_}, [{:<, {:element, 3, :"$1"}, cutoff}], [true]}]

      :ets.select_delete(@table, match_spec)
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
