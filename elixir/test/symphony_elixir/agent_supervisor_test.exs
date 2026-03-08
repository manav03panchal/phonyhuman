defmodule SymphonyElixir.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSupervisor

  describe "supervisor isolation" do
    test "agent crash does not take down infrastructure processes" do
      # Start a standalone AgentSupervisor for this test
      {:ok, sup} = AgentSupervisor.start_link(name: :test_agent_sup)

      # Start a "fake infrastructure" process (not linked to test process)
      infra_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Start an agent that will crash
      {:ok, agent_pid} =
        Task.Supervisor.start_child(:test_agent_sup, fn ->
          raise "deliberate agent crash"
        end)

      # Wait for the agent to crash
      ref = Process.monitor(agent_pid)
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, _reason}, 1_000

      # The infrastructure process should still be alive
      assert Process.alive?(infra_pid)

      # The agent supervisor should still be alive
      assert Process.alive?(sup)

      # Clean up
      Process.exit(infra_pid, :kill)
      Supervisor.stop(sup)
    end

    test "multiple agent crashes within limits keep supervisor alive" do
      {:ok, sup} = AgentSupervisor.start_link(name: :test_multi_crash_sup)

      # Crash a few agents — should stay within the 10/60s limit
      for _ <- 1..3 do
        {:ok, pid} =
          Task.Supervisor.start_child(:test_multi_crash_sup, fn ->
            raise "deliberate crash"
          end)

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      end

      # Supervisor should still be alive after 3 crashes
      assert Process.alive?(sup)

      Supervisor.stop(sup)
    end
  end

  describe "start_agent/1 and stop_agent/1" do
    test "start_agent starts a task under the application agent supervisor" do
      test_pid = self()

      {:ok, pid} =
        AgentSupervisor.start_agent(fn ->
          send(test_pid, :agent_ran)
          :ok
        end)

      assert is_pid(pid)
      assert_receive :agent_ran, 2_000
    end

    test "stop_agent terminates a running agent" do
      {:ok, pid} =
        AgentSupervisor.start_agent(fn ->
          Process.sleep(:infinity)
        end)

      assert Process.alive?(pid)
      assert :ok = AgentSupervisor.stop_agent(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end
end
