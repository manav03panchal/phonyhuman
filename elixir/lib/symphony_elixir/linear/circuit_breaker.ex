defmodule SymphonyElixir.Linear.CircuitBreaker do
  @moduledoc """
  Circuit breaker for Linear API calls.

  Tracks consecutive failures and opens the circuit after a configurable
  threshold is reached. While open, calls return `{:error, :circuit_open}`
  without making HTTP requests. After a cooldown period the circuit
  transitions to half-open and allows a single probe call through. A
  successful probe closes the circuit; a failed probe re-opens it with a
  shorter probe interval cooldown.

  The wrapped function executes in the caller's process to preserve
  process dictionary and message semantics.
  """

  use GenServer
  require Logger

  @default_failure_threshold 5
  @default_cooldown_ms 60_000
  @default_probe_interval_ms 15_000

  defmodule State do
    @moduledoc false

    @type circuit_state :: :closed | :open | :half_open

    @type t :: %__MODULE__{
            status: circuit_state(),
            failure_count: non_neg_integer(),
            failure_threshold: pos_integer(),
            cooldown_ms: pos_integer(),
            probe_interval_ms: pos_integer(),
            opened_at: integer() | nil
          }

    defstruct [
      :failure_threshold,
      :cooldown_ms,
      :probe_interval_ms,
      status: :closed,
      failure_count: 0,
      opened_at: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call((-> result), keyword()) :: result | {:error, :circuit_open}
        when result: term()
  def call(fun, opts \\ []) when is_function(fun, 0) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.call(name, :acquire) do
      :allow ->
        result = fun.()
        GenServer.call(name, {:report, classify_result(result)})
        result

      :reject ->
        {:error, :circuit_open}
    end
  end

  @spec status(keyword()) :: State.circuit_state()
  def status(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :status)
  end

  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :reset)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    state = %State{
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
      probe_interval_ms: Keyword.get(opts, :probe_interval_ms, @default_probe_interval_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, _from, %State{} = state) do
    case state.status do
      :closed ->
        {:reply, :allow, state}

      :open ->
        maybe_allow_probe(state)

      :half_open ->
        {:reply, :reject, state}
    end
  end

  def handle_call(:status, _from, %State{} = state) do
    {:reply, state.status, state}
  end

  def handle_call(:reset, _from, %State{} = state) do
    {:reply, :ok, %State{state | status: :closed, failure_count: 0, opened_at: nil}}
  end

  def handle_call({:report, outcome}, _from, %State{} = state) do
    {:reply, :ok, apply_outcome(outcome, state)}
  end

  # Private helpers

  defp maybe_allow_probe(%State{opened_at: opened_at} = state) do
    elapsed = now_ms() - (opened_at || 0)
    cooldown = effective_cooldown(state)

    if elapsed >= cooldown do
      Logger.info("Circuit breaker: open -> half_open (attempting probe after #{elapsed}ms)")
      {:reply, :allow, %State{state | status: :half_open}}
    else
      {:reply, :reject, state}
    end
  end

  defp apply_outcome(:success, %State{status: :half_open} = state) do
    Logger.info("Circuit breaker: half_open -> closed (probe succeeded, failure_count=#{state.failure_count})")

    %State{state | status: :closed, failure_count: 0, opened_at: nil}
  end

  defp apply_outcome(:failure, %State{status: :half_open} = state) do
    new_count = state.failure_count + 1

    Logger.warning("Circuit breaker: half_open -> open (probe failed, failure_count=#{new_count})")

    %State{state | status: :open, failure_count: new_count, opened_at: now_ms()}
  end

  defp apply_outcome(:success, %State{} = state) do
    %State{state | failure_count: 0}
  end

  defp apply_outcome(:failure, %State{failure_count: count, failure_threshold: threshold} = state) do
    new_count = count + 1

    if new_count >= threshold do
      Logger.warning("Circuit breaker: closed -> open (failure_count=#{new_count}, threshold=#{threshold})")

      %State{state | status: :open, failure_count: new_count, opened_at: now_ms()}
    else
      %State{state | failure_count: new_count}
    end
  end

  defp effective_cooldown(%State{failure_count: count, failure_threshold: threshold} = state) do
    if count > threshold do
      state.probe_interval_ms
    else
      state.cooldown_ms
    end
  end

  @doc false
  @spec classify_result(term()) :: :success | :failure
  def classify_result({:ok, _}), do: :success
  def classify_result(:ok), do: :success
  def classify_result({:error, _}), do: :failure
  def classify_result(_), do: :success

  defp now_ms, do: System.monotonic_time(:millisecond)
end
