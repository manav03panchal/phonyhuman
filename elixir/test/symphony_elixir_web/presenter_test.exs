defmodule SymphonyElixirWeb.PresenterTest do
  use ExUnit.Case

  alias SymphonyElixirWeb.Presenter

  defmodule MockOrchestrator do
    use GenServer

    def start_link(snapshot, name), do: GenServer.start_link(__MODULE__, snapshot, name: name)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp start_mock(snapshot) do
    name = :"mock_orchestrator_#{System.unique_integer([:positive])}"
    {:ok, pid} = MockOrchestrator.start_link(snapshot, name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  describe "state_payload/2" do
    test "includes cache_read_tokens, cache_creation_tokens, and cost_usd in agent_totals" do
      pid = start_mock(%{
        running: [],
        retrying: [],
        agent_totals: %{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          seconds_running: 60
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)

      assert payload.agent_totals.input_tokens == 100
      assert payload.agent_totals.output_tokens == 50
      assert payload.agent_totals.total_tokens == 150
      assert payload.agent_totals.seconds_running == 60
      assert payload.agent_totals.cache_read_tokens == 0
      assert payload.agent_totals.cache_creation_tokens == 0
      assert payload.agent_totals.cost_usd == 0
    end

    test "preserves non-zero cache and cost values from snapshot" do
      pid = start_mock(%{
        running: [],
        retrying: [],
        agent_totals: %{
          input_tokens: 45_230,
          output_tokens: 8_120,
          total_tokens: 53_350,
          seconds_running: 754,
          cache_read_tokens: 31_500,
          cache_creation_tokens: 12_000,
          cost_usd: 0.42
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)

      assert payload.agent_totals.cache_read_tokens == 31_500
      assert payload.agent_totals.cache_creation_tokens == 12_000
      assert payload.agent_totals.cost_usd == 0.42
    end
  end

  describe "cache_hit_rate" do
    test "computes correct rate for non-zero values" do
      # 8000 / (15000 + 8000) * 100 ≈ 34.78%
      rate = Presenter.cache_hit_rate(15_000, 8_000)
      assert_in_delta rate, 34.78, 0.01
    end

    test "returns 0.0 when both input and cache_read are 0" do
      assert Presenter.cache_hit_rate(0, 0) == 0.0
    end

    test "returns 0.0 when cache_read is 0" do
      assert Presenter.cache_hit_rate(10_000, 0) == 0.0
    end
  end

  describe "cache_hit_rate in API output" do
    test "includes cache_hit_rate in agent_totals" do
      pid = start_mock(%{
        running: [],
        retrying: [],
        agent_totals: %{
          input_tokens: 15_000,
          output_tokens: 5_000,
          total_tokens: 20_000,
          cache_read_tokens: 8_000,
          seconds_running: 120
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)

      assert_in_delta payload.agent_totals.cache_hit_rate, 34.78, 0.01
    end

    test "includes cache_hit_rate 0.0 in agent_totals when both tokens are 0" do
      pid = start_mock(%{
        running: [],
        retrying: [],
        agent_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)

      assert payload.agent_totals.cache_hit_rate == 0.0
    end

    test "includes cache_hit_rate in per-session token map" do
      pid = start_mock(%{
        running: [
          %{
            issue_id: "issue-1",
            identifier: "MT-100",
            state: "In Progress",
            session_id: "sess-abc",
            codex_app_server_pid: nil,
            agent_input_tokens: 1_000,
            agent_output_tokens: 200,
            agent_total_tokens: 1_200,
            agent_cache_read_tokens: 800,
            agent_cost_usd: 0.15,
            model: "claude-opus-4-6",
            turn_count: 3,
            started_at: DateTime.utc_now(),
            last_codex_timestamp: nil,
            last_codex_message: nil,
            last_codex_event: nil,
            last_agent_timestamp: nil,
            last_agent_message: nil,
            last_agent_event: nil,
            runtime_seconds: 120
          }
        ],
        retrying: [],
        agent_totals: %{
          input_tokens: 1_000,
          output_tokens: 200,
          total_tokens: 1_200,
          seconds_running: 0
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)
      [entry] = payload.running

      # 800 / (1000 + 800) * 100 ≈ 44.44%
      assert_in_delta entry.tokens.cache_hit_rate, 44.44, 0.01
    end

    test "per-session cache_hit_rate is 0.0 when cache_read_tokens is absent" do
      pid = start_mock(%{
        running: [
          %{
            issue_id: "issue-2",
            identifier: "MT-200",
            state: "Todo",
            session_id: nil,
            codex_app_server_pid: nil,
            agent_input_tokens: 500,
            agent_output_tokens: 100,
            agent_total_tokens: 600,
            turn_count: 1,
            started_at: DateTime.utc_now(),
            last_codex_timestamp: nil,
            last_codex_message: nil,
            last_codex_event: nil,
            last_agent_timestamp: nil,
            last_agent_message: nil,
            last_agent_event: nil,
            runtime_seconds: 30
          }
        ],
        retrying: [],
        agent_totals: %{
          input_tokens: 500,
          output_tokens: 100,
          total_tokens: 600,
          seconds_running: 0
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)
      [entry] = payload.running

      assert entry.tokens.cache_hit_rate == 0.0
    end
  end

  describe "running_entry_payload (via state_payload)" do
    test "includes model and cost_usd in tokens map" do
      pid = start_mock(%{
        running: [
          %{
            issue_id: "issue-1",
            identifier: "MT-100",
            state: "In Progress",
            session_id: "sess-abc",
            codex_app_server_pid: nil,
            agent_input_tokens: 1_000,
            agent_output_tokens: 200,
            agent_total_tokens: 1_200,
            agent_cache_read_tokens: 800,
            agent_cost_usd: 0.15,
            model: "claude-opus-4-6",
            turn_count: 3,
            started_at: DateTime.utc_now(),
            last_codex_timestamp: nil,
            last_codex_message: nil,
            last_codex_event: nil,
            last_agent_timestamp: nil,
            last_agent_message: nil,
            last_agent_event: nil,
            runtime_seconds: 120
          }
        ],
        retrying: [],
        agent_totals: %{
          input_tokens: 1_000,
          output_tokens: 200,
          total_tokens: 1_200,
          seconds_running: 0
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)
      [entry] = payload.running

      assert entry.model == "claude-opus-4-6"
      assert entry.tokens.cost_usd == 0.15
      assert entry.tokens.cache_read_tokens == 800
      assert entry.tokens.input_tokens == 1_000
      assert entry.tokens.output_tokens == 200
      assert entry.tokens.total_tokens == 1_200
    end

    test "defaults model to nil and cost/cache to 0 when not present" do
      pid = start_mock(%{
        running: [
          %{
            issue_id: "issue-2",
            identifier: "MT-200",
            state: "Todo",
            session_id: nil,
            codex_app_server_pid: nil,
            agent_input_tokens: 500,
            agent_output_tokens: 100,
            agent_total_tokens: 600,
            turn_count: 1,
            started_at: DateTime.utc_now(),
            last_codex_timestamp: nil,
            last_codex_message: nil,
            last_codex_event: nil,
            last_agent_timestamp: nil,
            last_agent_message: nil,
            last_agent_event: nil,
            runtime_seconds: 30
          }
        ],
        retrying: [],
        agent_totals: %{
          input_tokens: 500,
          output_tokens: 100,
          total_tokens: 600,
          seconds_running: 0
        },
        rate_limits: nil
      })

      payload = Presenter.state_payload(pid, 5_000)
      [entry] = payload.running

      assert entry.model == nil
      assert entry.tokens.cost_usd == 0
      assert entry.tokens.cache_read_tokens == 0
    end
  end
end
