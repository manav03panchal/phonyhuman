defmodule SymphonyElixir.RestartMonitor do
  @moduledoc """
  Monitors supervisor processes and logs a warning when any of them terminate,
  which typically indicates that the supervisor reached its maximum restart
  intensity.

  Started as a child of the application supervisor, after the supervisors it
  watches.
  """

  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @impl true
  def init(opts) do
    watched = Keyword.get(opts, :watched, [])
    refs = establish_monitors(watched)
    {:ok, %{watched: watched, refs: refs}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refs: refs} = state) do
    case Map.pop(refs, ref) do
      {name, remaining} when not is_nil(name) ->
        Logger.warning(
          "Supervisor #{inspect(name)} terminated (reason: #{inspect(reason)}); " <>
            "this may indicate that maximum restart intensity was reached"
        )

        schedule_rewatch()
        {:noreply, %{state | refs: remaining}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:rewatch, %{watched: watched, refs: old_refs} = state) do
    demonitor_all(old_refs)
    new_refs = establish_monitors(watched)
    {:noreply, %{state | refs: new_refs}}
  end

  defp establish_monitors(names) do
    for name <- names,
        pid = Process.whereis(name),
        is_pid(pid),
        into: %{} do
      {Process.monitor(pid), name}
    end
  end

  defp demonitor_all(refs) do
    for {ref, _name} <- refs, do: Process.demonitor(ref, [:flush])
    :ok
  end

  defp schedule_rewatch do
    Process.send_after(self(), :rewatch, 500)
  end
end
