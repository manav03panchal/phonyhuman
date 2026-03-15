defmodule SymphonyElixirWeb.RateLimiterSweeperTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Plugs.RateLimiter.Sweeper

  @table :symphony_rate_limiter

  setup do
    # Ensure the ETS table exists for sweep tests
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:public, :set, :named_table, {:write_concurrency, true}])
    else
      :ets.delete_all_objects(@table)
    end

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined do
        :ets.delete_all_objects(@table)
      end
    end)

    :ok
  end

  describe "sweep/0" do
    test "deletes expired entries" do
      now = System.system_time(:second)
      window = 60
      # An old window_start that is > 2 windows in the past
      old_window = div(now, window) * window - 3 * window

      :ets.insert(@table, {{:default, "1.2.3.4", old_window}, 5})
      assert :ets.info(@table, :size) == 1

      deleted = Sweeper.sweep()
      assert deleted == 1
      assert :ets.info(@table, :size) == 0
    end

    test "preserves current window entries" do
      now = System.system_time(:second)
      window = 60
      current_window = div(now, window) * window

      :ets.insert(@table, {{:default, "1.2.3.4", current_window}, 3})
      assert :ets.info(@table, :size) == 1

      deleted = Sweeper.sweep()
      assert deleted == 0
      assert :ets.info(@table, :size) == 1
    end

    test "preserves previous window entries (within 2x threshold)" do
      now = System.system_time(:second)
      window = 60
      previous_window = div(now, window) * window - window

      :ets.insert(@table, {{:default, "1.2.3.4", previous_window}, 2})

      deleted = Sweeper.sweep()
      assert deleted == 0
      assert :ets.info(@table, :size) == 1
    end

    test "deletes only expired entries in a mixed set" do
      now = System.system_time(:second)
      window = 60
      current_window = div(now, window) * window
      old_window = current_window - 3 * window
      very_old_window = current_window - 10 * window

      :ets.insert(@table, [
        {{:default, "1.2.3.4", current_window}, 3},
        {{:default, "1.2.3.4", old_window}, 5},
        {{:otel, "5.6.7.8", very_old_window}, 10},
        {{:default, "9.0.1.2", current_window}, 1}
      ])

      assert :ets.info(@table, :size) == 4

      deleted = Sweeper.sweep()
      assert deleted == 2
      assert :ets.info(@table, :size) == 2

      # Current entries remain
      assert :ets.lookup(@table, {:default, "1.2.3.4", current_window}) == [
               {{:default, "1.2.3.4", current_window}, 3}
             ]

      assert :ets.lookup(@table, {:default, "9.0.1.2", current_window}) == [
               {{:default, "9.0.1.2", current_window}, 1}
             ]
    end

    test "returns 0 when table does not exist" do
      # Temporarily delete the table
      :ets.delete(@table)

      assert Sweeper.sweep() == 0
    end
  end

  describe "GenServer lifecycle" do
    test "starts and schedules periodic sweeps" do
      name = :"sweeper_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Sweeper.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles :sweep message" do
      now = System.system_time(:second)
      window = 60
      old_window = div(now, window) * window - 3 * window
      :ets.insert(@table, {{:default, "10.0.0.1", old_window}, 99})

      name = :"sweeper_msg_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Sweeper.start_link(name: name)

      # Manually send :sweep to trigger immediate cleanup
      send(pid, :sweep)
      # Give the GenServer time to process
      Process.sleep(50)

      assert :ets.info(@table, :size) == 0
      GenServer.stop(pid)
    end
  end
end
