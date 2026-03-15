defmodule SymphonyElixirWeb.ContractTest do
  @moduledoc """
  Contract tests that validate the Presenter JSON output matches the golden
  files shared with the Go TUI. If a field name, nesting level, or type
  changes on the Elixir side, these tests fail — preventing silent contract
  drift between the Elixir API and the Go consumer.
  """
  use ExUnit.Case

  alias SymphonyElixirWeb.Presenter

  @golden_dir Path.expand("../../../contract/golden", __DIR__)

  defmodule MockOrchestrator do
    use GenServer

    def start_link(snapshot, name), do: GenServer.start_link(__MODULE__, snapshot, name: name)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp start_mock(snapshot) do
    name = :"contract_mock_#{System.unique_integer([:positive])}"
    {:ok, pid} = MockOrchestrator.start_link(snapshot, name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp read_golden!(filename) do
    @golden_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  # Extract all key paths from a JSON-decoded map, returning a sorted list of
  # dotted paths like ["counts.running", "running[].tokens.input_tokens", ...].
  # Array elements are collapsed to "[]" so we test shape, not cardinality.
  defp key_paths(map, prefix \\ "")

  defp key_paths(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      full = if prefix == "", do: key, else: "#{prefix}.#{key}"

      case value do
        v when is_map(v) and map_size(v) > 0 -> key_paths(v, full)
        [head | _] -> key_paths(head, "#{full}[]")
        _ -> [full]
      end
    end)
    |> Enum.sort()
  end

  defp key_paths(_value, prefix), do: [prefix]

  # Build a snapshot that exercises every field path the Presenter can emit.
  # Uses the same key names as the real Orchestrator.handle_call(:snapshot).
  defp full_snapshot do
    started_at = ~U[2026-03-08 11:00:00Z]
    last_event_at = ~U[2026-03-08 11:55:00Z]

    %{
      running: [
        %{
          issue_id: "uuid-issue-1",
          identifier: "HUM-100",
          state: "In Progress",
          session_id: "sess-abc",
          agent_app_server_pid: nil,
          agent_input_tokens: 10_000,
          agent_output_tokens: 2_000,
          agent_total_tokens: 12_000,
          agent_cache_read_tokens: 5_000,
          agent_cost_usd: 0.42,
          agent_model: "claude-opus-4-6",
          turn_count: 5,
          started_at: started_at,
          last_agent_timestamp: last_event_at,
          last_agent_message: "Running tests",
          last_agent_event: "tool_call_completed",
          runtime_seconds: 3300,
          otel_tool_calls: 15,
          otel_tool_duration_total_ms: 3750,
          otel_api_errors: 1,
          otel_lines_changed: 99,
          otel_commits_count: 3,
          otel_prs_count: 1,
          otel_active_time_seconds: 300
        }
      ],
      retrying: [
        %{
          issue_id: "uuid-issue-2",
          identifier: "HUM-200",
          attempt: 3,
          due_in_ms: 300_000,
          error: "rate limited"
        }
      ],
      agent_totals: %{
        input_tokens: 50_000,
        output_tokens: 15_000,
        total_tokens: 65_000,
        cache_read_tokens: 30_000,
        cache_creation_tokens: 10_000,
        cost_usd: 2.50,
        model: nil,
        seconds_running: 1_800,
        lines_changed: 250,
        commits_count: 10,
        prs_count: 3,
        tool_calls: 50,
        tool_duration_total_ms: 10_000,
        api_errors: 5,
        active_time_seconds: 1_500
      },
      rate_limits: %{
        "limit_id" => "rl-001",
        "primary" => %{"capacity" => 1000, "remaining" => 750},
        "secondary" => %{"capacity" => 5000, "remaining" => 4200},
        "credits" => 100.0
      },
      fleet_status: "running",
      fleet_paused_until: nil,
      fleet_pause_reason: nil
    }
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      agent_totals: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0,
        cache_read_tokens: 0,
        cache_creation_tokens: 0,
        cost_usd: 0.0,
        model: nil,
        tool_calls: 0,
        tool_duration_total_ms: 0,
        api_errors: 0,
        lines_changed: 0,
        commits_count: 0,
        prs_count: 0,
        active_time_seconds: 0
      },
      rate_limits: nil,
      fleet_status: "running",
      fleet_paused_until: nil,
      fleet_pause_reason: nil
    }
  end

  describe "contract: state_full golden file" do
    test "Presenter output keys match golden file keys" do
      golden = read_golden!("state_full.json")
      pid = start_mock(full_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      golden_keys = key_paths(golden)
      presenter_keys = key_paths(presenter_json)

      assert presenter_keys == golden_keys,
             "Key mismatch between Presenter output and golden file.\n" <>
               "Missing from Presenter: #{inspect(golden_keys -- presenter_keys)}\n" <>
               "Extra in Presenter: #{inspect(presenter_keys -- golden_keys)}"
    end

    test "running entry field values are correctly serialized" do
      pid = start_mock(full_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      [entry] = presenter_json["running"]

      assert entry["issue_id"] == "uuid-issue-1"
      assert entry["issue_identifier"] == "HUM-100"
      assert entry["state"] == "In Progress"
      assert entry["session_id"] == "sess-abc"
      assert entry["turn_count"] == 5
      assert entry["last_event"] == "tool_call_completed"
      assert entry["model"] == "claude-opus-4-6"
      assert entry["tokens"]["input_tokens"] == 10_000
      assert entry["tokens"]["output_tokens"] == 2_000
      assert entry["tokens"]["total_tokens"] == 12_000
      assert entry["tokens"]["cache_read_tokens"] == 5_000
      assert entry["tokens"]["cost_usd"] == 0.42
      assert entry["lines_changed"] == 99
      assert entry["commits_count"] == 3
      assert entry["prs_count"] == 1
      assert entry["tool_calls"] == 15
      assert entry["tool_avg_duration_ms"] == 250
      assert entry["api_errors"] == 1
      assert entry["active_time_seconds"] == 300
    end

    test "retrying entry field values are correctly serialized" do
      pid = start_mock(full_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      [entry] = presenter_json["retrying"]

      assert entry["issue_id"] == "uuid-issue-2"
      assert entry["issue_identifier"] == "HUM-200"
      assert entry["attempt"] == 3
      assert is_binary(entry["due_at"])
      assert entry["error"] == "rate limited"
    end

    test "agent_totals field values are correctly serialized" do
      pid = start_mock(full_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      totals = presenter_json["agent_totals"]

      assert totals["input_tokens"] == 50_000
      assert totals["output_tokens"] == 15_000
      assert totals["total_tokens"] == 65_000
      assert totals["cache_read_tokens"] == 30_000
      assert totals["cache_creation_tokens"] == 10_000
      assert totals["cost_usd"] == 2.50
      assert totals["seconds_running"] == 1_800
      assert totals["lines_changed"] == 250
      assert totals["commits_count"] == 10
      assert totals["prs_count"] == 3
      assert totals["tool_calls"] == 50
      assert totals["tool_avg_duration_ms"] == 200
      assert totals["api_errors"] == 5
      assert totals["active_time_seconds"] == 1_500
    end

    test "rate_limits are passed through with expected keys" do
      pid = start_mock(full_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      rl = presenter_json["rate_limits"]

      assert rl["limit_id"] == "rl-001"
      assert rl["primary"]["capacity"] == 1000
      assert rl["primary"]["remaining"] == 750
      assert rl["secondary"]["capacity"] == 5000
      assert rl["secondary"]["remaining"] == 4200
      assert rl["credits"] == 100.0
    end
  end

  describe "contract: state_empty golden file" do
    test "empty state keys match golden file keys" do
      golden = read_golden!("state_empty.json")
      pid = start_mock(empty_snapshot())
      payload = Presenter.state_payload(pid, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      golden_keys = key_paths(golden)
      presenter_keys = key_paths(presenter_json)

      assert presenter_keys == golden_keys
    end
  end

  describe "contract: state_error golden file" do
    test "error state keys match golden file keys" do
      golden = read_golden!("state_error.json")

      # The error path is triggered by :timeout from orchestrator
      name = :"contract_timeout_mock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Agent.start_link(fn -> nil end, name: name)

      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      # Simulate timeout by using a very short timeout with a slow orchestrator
      # Instead, we directly test the error shape by calling with a mock that returns :timeout
      timeout_name = :"contract_timeout_#{System.unique_integer([:positive])}"

      {:ok, timeout_pid} =
        GenServer.start_link(MockOrchestrator, :timeout, name: timeout_name)

      on_exit(fn -> if Process.alive?(timeout_pid), do: GenServer.stop(timeout_pid) end)

      payload = Presenter.state_payload(timeout_name, 5_000)

      presenter_json =
        payload
        |> Jason.encode!()
        |> Jason.decode!()

      golden_keys = key_paths(golden)
      presenter_keys = key_paths(presenter_json)

      assert presenter_keys == golden_keys
      assert presenter_json["error"]["code"] == "snapshot_timeout"
      assert is_binary(presenter_json["error"]["message"])
    end
  end
end
