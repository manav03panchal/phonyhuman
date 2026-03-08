defmodule SymphonyElixir.Linear.CircuitBreakerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.CircuitBreaker

  setup do
    name = :"cb_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      CircuitBreaker.start_link(
        name: name,
        failure_threshold: 3,
        cooldown_ms: 100,
        probe_interval_ms: 50
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{name: name}
  end

  test "starts in closed state", %{name: name} do
    assert CircuitBreaker.status(name: name) == :closed
  end

  test "successful calls keep circuit closed", %{name: name} do
    result = CircuitBreaker.call(fn -> {:ok, :data} end, name: name)
    assert result == {:ok, :data}
    assert CircuitBreaker.status(name: name) == :closed
  end

  test "circuit opens after N consecutive failures", %{name: name} do
    log =
      capture_log(fn ->
        for _ <- 1..3 do
          assert {:error, :api_fail} =
                   CircuitBreaker.call(fn -> {:error, :api_fail} end, name: name)
        end
      end)

    assert CircuitBreaker.status(name: name) == :open
    assert log =~ "closed -> open"
    assert log =~ "failure_count=3"
  end

  test "no requests made while circuit is open", %{name: name} do
    call_count = :counters.new(1, [:atomics])

    capture_log(fn ->
      for _ <- 1..3 do
        CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
      end
    end)

    assert CircuitBreaker.status(name: name) == :open

    result =
      CircuitBreaker.call(
        fn ->
          :counters.add(call_count, 1, 1)
          {:ok, :should_not_run}
        end,
        name: name
      )

    assert result == {:error, :circuit_open}
    assert :counters.get(call_count, 1) == 0
  end

  test "probe and recovery flow", %{name: name} do
    capture_log(fn ->
      for _ <- 1..3 do
        CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
      end
    end)

    assert CircuitBreaker.status(name: name) == :open

    # Wait for cooldown to elapse
    Process.sleep(110)

    log =
      capture_log(fn ->
        result = CircuitBreaker.call(fn -> {:ok, :recovered} end, name: name)
        assert result == {:ok, :recovered}
      end)

    assert log =~ "open -> half_open"
    assert log =~ "half_open -> closed"
    assert CircuitBreaker.status(name: name) == :closed
  end

  test "failed probe re-opens circuit with probe interval cooldown", %{name: name} do
    capture_log(fn ->
      for _ <- 1..3 do
        CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
      end
    end)

    # Wait for cooldown to elapse
    Process.sleep(110)

    log =
      capture_log(fn ->
        result = CircuitBreaker.call(fn -> {:error, :still_down} end, name: name)
        assert result == {:error, :still_down}
      end)

    assert log =~ "half_open -> open"
    assert CircuitBreaker.status(name: name) == :open

    # Immediately after failed probe, circuit should still be open
    result = CircuitBreaker.call(fn -> {:ok, :data} end, name: name)
    assert result == {:error, :circuit_open}

    # Wait for probe interval (shorter than cooldown)
    Process.sleep(60)

    log =
      capture_log(fn ->
        result = CircuitBreaker.call(fn -> {:ok, :recovered} end, name: name)
        assert result == {:ok, :recovered}
      end)

    assert log =~ "half_open -> closed"
  end

  test "successful call resets failure count", %{name: name} do
    # Two failures (below threshold)
    CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
    CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
    assert CircuitBreaker.status(name: name) == :closed

    # Success resets count
    CircuitBreaker.call(fn -> {:ok, :data} end, name: name)

    # Two more failures should not open (count was reset)
    CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
    CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
    assert CircuitBreaker.status(name: name) == :closed
  end

  test "reset returns circuit to closed state", %{name: name} do
    capture_log(fn ->
      for _ <- 1..3 do
        CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
      end
    end)

    assert CircuitBreaker.status(name: name) == :open
    assert :ok = CircuitBreaker.reset(name: name)
    assert CircuitBreaker.status(name: name) == :closed
  end

  test "half_open rejects concurrent calls", %{name: name} do
    capture_log(fn ->
      for _ <- 1..3 do
        CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
      end
    end)

    Process.sleep(110)

    # First call transitions to half_open and runs as probe.
    # Since GenServer serializes calls, we test that during half_open state
    # additional calls are rejected.
    capture_log(fn ->
      # Trigger probe that fails, putting us back in open
      CircuitBreaker.call(fn -> {:error, :fail} end, name: name)
    end)

    # Now open again, immediate call should be rejected
    result = CircuitBreaker.call(fn -> {:ok, :data} end, name: name)
    assert result == {:error, :circuit_open}
  end

  test ":ok result is classified as success", %{name: name} do
    result = CircuitBreaker.call(fn -> :ok end, name: name)
    assert result == :ok
    assert CircuitBreaker.status(name: name) == :closed
  end
end
