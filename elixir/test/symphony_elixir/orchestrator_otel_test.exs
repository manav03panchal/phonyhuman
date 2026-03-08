defmodule SymphonyElixir.OrchestratorOtelTest do
  use SymphonyElixir.TestSupport

  test "handle_info merges OTel metrics into running entry with matching session_id" do
    issue_id = "issue-otel-1"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-300",
      title: "OTel test",
      description: "OTel integration",
      state: "In Progress",
      url: "https://example.org/issues/MT-300"
    }

    orchestrator_name = Module.concat(__MODULE__, :OtelOrchestrator1)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-otel-abc",
      turn_count: 0,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      agent_cache_read_tokens: 0,
      agent_cache_creation_tokens: 0,
      agent_cost_usd: 0.0,
      agent_model: nil,
      started_at: started_at,
      otel_input_tokens: 0,
      otel_output_tokens: 0,
      otel_cache_read_tokens: 0,
      otel_cache_creation_tokens: 0,
      otel_cost_usd: 0.0,
      otel_tool_executions: [],
      otel_api_errors: 0,
      otel_lines_changed: 0,
      otel_commits_count: 0,
      otel_prs_count: 0,
      otel_active_time_seconds: 0
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    # Send OTel metrics with token data
    otel_metrics = %{
      "claude_code.token.usage" => [
        %{value: 500, attributes: %{"type" => "input"}},
        %{value: 200, attributes: %{"type" => "output"}},
        %{value: 100, attributes: %{"type" => "cache_read"}},
        %{value: 50, attributes: %{"type" => "cache_creation"}}
      ],
      "claude_code.cost.usage" => [
        %{value: 0.05, attributes: %{"model" => "claude-sonnet-4-20250514"}}
      ],
      "claude_code.lines_of_code.count" => [
        %{value: 42, attributes: %{}}
      ],
      "claude_code.commit.count" => [
        %{value: 3, attributes: %{}}
      ],
      "claude_code.pull_request.count" => [
        %{value: 1, attributes: %{}}
      ],
      "claude_code.active_time.total" => [
        %{value: 120, attributes: %{}}
      ],
      events: [
        %{
          name: "claude_code.tool_result",
          attributes: %{"tool_name" => "Read", "duration_ms" => 150, "success" => true},
          timestamp: "1700000000000000000",
          severity: "INFO"
        },
        %{
          name: "claude_code.tool_result",
          attributes: %{"tool_name" => "Edit", "duration_ms" => 300, "success" => true},
          timestamp: "1700000001000000000",
          severity: "INFO"
        },
        %{
          name: "claude_code.api_error",
          attributes: %{"error" => "rate_limit"},
          timestamp: "1700000002000000000",
          severity: "ERROR"
        }
      ]
    }

    send(pid, {:otel_metrics, "sess-otel-abc", otel_metrics})

    # Allow GenServer to process
    _ = :sys.get_state(pid)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot

    # OTel token data is stored in otel_* fields
    assert entry.otel_input_tokens == 500
    assert entry.otel_output_tokens == 200
    assert entry.otel_cache_read_tokens == 100
    assert entry.otel_cache_creation_tokens == 50
    assert entry.otel_cost_usd == 0.05

    # OTel-only metrics
    assert entry.otel_lines_changed == 42
    assert entry.otel_commits_count == 3
    assert entry.otel_prs_count == 1
    assert entry.otel_active_time_seconds == 120

    # Tool executions
    assert length(entry.otel_tool_executions) == 2

    assert Enum.any?(entry.otel_tool_executions, fn t ->
             t.name == "Read" and t.duration_ms == 150 and t.success == true
           end)

    assert Enum.any?(entry.otel_tool_executions, fn t ->
             t.name == "Edit" and t.duration_ms == 300 and t.success == true
           end)

    # API errors
    assert entry.otel_api_errors == 1

    # Stream-json fields are untouched
    assert entry.agent_input_tokens == 0
    assert entry.agent_output_tokens == 0
    assert entry.agent_total_tokens == 0
  end

  test "handle_info logs warning and discards OTel metrics for unknown session_id" do
    orchestrator_name = Module.concat(__MODULE__, :OtelOrchestrator2)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    log =
      capture_log(fn ->
        send(
          pid,
          {:otel_metrics, "unknown-session-xyz",
           %{
             "claude_code.token.usage" => [%{value: 100, attributes: %{"type" => "input"}}]
           }}
        )

        # Allow GenServer to process
        _ = :sys.get_state(pid)
      end)

    assert log =~ "unknown session_id=unknown-session-xyz"

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
  end

  test "OTel data appears in build_snapshot output" do
    issue_id = "issue-otel-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-301",
      title: "OTel snapshot test",
      description: "Verify OTel in snapshot",
      state: "In Progress",
      url: "https://example.org/issues/MT-301"
    }

    orchestrator_name = Module.concat(__MODULE__, :OtelSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-snapshot-otel",
      turn_count: 1,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_app_server_pid: nil,
      agent_input_tokens: 100,
      agent_output_tokens: 50,
      agent_total_tokens: 150,
      agent_last_reported_input_tokens: 100,
      agent_last_reported_output_tokens: 50,
      agent_last_reported_total_tokens: 150,
      agent_cache_read_tokens: 10,
      agent_cache_creation_tokens: 5,
      agent_cost_usd: 0.01,
      agent_model: "claude-sonnet-4-20250514",
      started_at: started_at,
      otel_input_tokens: 500,
      otel_output_tokens: 200,
      otel_cache_read_tokens: 80,
      otel_cache_creation_tokens: 40,
      otel_cost_usd: 0.05,
      otel_tool_executions: [
        %{name: "Bash", duration_ms: 500, success: true}
      ],
      otel_api_errors: 2,
      otel_lines_changed: 99,
      otel_commits_count: 4,
      otel_prs_count: 1,
      otel_active_time_seconds: 300
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot

    # OTel fields present in snapshot
    assert entry.otel_input_tokens == 500
    assert entry.otel_output_tokens == 200
    assert entry.otel_cache_read_tokens == 80
    assert entry.otel_cache_creation_tokens == 40
    assert entry.otel_cost_usd == 0.05
    assert entry.otel_tool_executions == [%{name: "Bash", duration_ms: 500, success: true}]
    assert entry.otel_api_errors == 2
    assert entry.otel_lines_changed == 99
    assert entry.otel_commits_count == 4
    assert entry.otel_prs_count == 1
    assert entry.otel_active_time_seconds == 300

    # Stream-json fields still present and correct
    assert entry.agent_input_tokens == 100
    assert entry.agent_output_tokens == 50
    assert entry.agent_total_tokens == 150
  end

  test "stream-json final totals take precedence over OTel live data" do
    issue_id = "issue-otel-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-302",
      title: "Precedence test",
      description: "Stream-json vs OTel precedence",
      state: "In Progress",
      url: "https://example.org/issues/MT-302"
    }

    orchestrator_name = Module.concat(__MODULE__, :OtelPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-precedence",
      turn_count: 0,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      agent_cache_read_tokens: 0,
      agent_cache_creation_tokens: 0,
      agent_cost_usd: 0.0,
      agent_model: nil,
      started_at: started_at,
      otel_input_tokens: 0,
      otel_output_tokens: 0,
      otel_cache_read_tokens: 0,
      otel_cache_creation_tokens: 0,
      otel_cost_usd: 0.0,
      otel_tool_executions: [],
      otel_api_errors: 0,
      otel_lines_changed: 0,
      otel_commits_count: 0,
      otel_prs_count: 0,
      otel_active_time_seconds: 0
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    # Step 1: OTel provides real-time token data
    send(
      pid,
      {:otel_metrics, "sess-precedence",
       %{
         "claude_code.token.usage" => [
           %{value: 500, attributes: %{"type" => "input"}},
           %{value: 200, attributes: %{"type" => "output"}}
         ]
       }}
    )

    _ = :sys.get_state(pid)

    snapshot1 = GenServer.call(pid, :snapshot)
    assert %{running: [entry1]} = snapshot1
    # OTel shows live data
    assert entry1.otel_input_tokens == 500
    assert entry1.otel_output_tokens == 200
    # Stream-json is still 0 (no turn completed yet)
    assert entry1.agent_input_tokens == 0
    assert entry1.agent_output_tokens == 0

    # Step 2: Stream-json turn/completed arrives with authoritative totals
    now = DateTime.utc_now()

    send(
      pid,
      {:agent_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "turn/completed",
           "params" => %{
             "usage" => %{
               "input_tokens" => 520,
               "output_tokens" => 210,
               "total_tokens" => 730
             }
           }
         },
         timestamp: now
       }}
    )

    _ = :sys.get_state(pid)

    snapshot2 = GenServer.call(pid, :snapshot)
    assert %{running: [entry2]} = snapshot2
    # Stream-json agent_* tokens are now the authoritative values
    assert entry2.agent_input_tokens == 520
    assert entry2.agent_output_tokens == 210
    assert entry2.agent_total_tokens == 730
    # OTel values remain as the last reported live data
    assert entry2.otel_input_tokens == 500
    assert entry2.otel_output_tokens == 200
  end

  test "OTel fields are included in agent_totals after session completion" do
    issue_id = "issue-otel-totals"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-303",
      title: "OTel totals test",
      description: "Verify OTel in agent_totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-303"
    }

    orchestrator_name = Module.concat(__MODULE__, :OtelTotalsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-totals",
      turn_count: 1,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_app_server_pid: nil,
      agent_input_tokens: 100,
      agent_output_tokens: 50,
      agent_total_tokens: 150,
      agent_last_reported_input_tokens: 100,
      agent_last_reported_output_tokens: 50,
      agent_last_reported_total_tokens: 150,
      agent_cache_read_tokens: 0,
      agent_cache_creation_tokens: 0,
      agent_cost_usd: 0.01,
      agent_model: nil,
      started_at: started_at,
      otel_input_tokens: 500,
      otel_output_tokens: 200,
      otel_cache_read_tokens: 0,
      otel_cache_creation_tokens: 0,
      otel_cost_usd: 0.05,
      otel_tool_executions: [
        %{name: "Bash", duration_ms: 500, success: true}
      ],
      otel_api_errors: 2,
      otel_lines_changed: 50,
      otel_commits_count: 3,
      otel_prs_count: 1,
      otel_active_time_seconds: 120
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    # Simulate process completion
    send(pid, {:DOWN, process_ref, :process, self(), :normal})

    # Wait for processing
    _ = :sys.get_state(pid)

    completed_state = :sys.get_state(pid)
    totals = completed_state.agent_totals

    # OTel-only fields carry forward to agent_totals
    assert totals.tool_executions == [%{name: "Bash", duration_ms: 500, success: true}]
    assert totals.api_errors == 2
    assert totals.lines_changed == 50
    assert totals.commits_count == 3
    assert totals.prs_count == 1
    assert totals.active_time_seconds == 120
  end
end
