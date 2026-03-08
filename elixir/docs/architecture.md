# Architecture Overview

This document describes the internals of the Symphony orchestrator: how it starts, polls for work, dispatches agents, tracks tokens, handles failures, and shuts down.

## Supervisor Tree

The application starts a flat `one_for_one` supervisor with `max_restarts: 10, max_seconds: 30`. Children start in order and are restarted independently.

```
SymphonyElixir.Supervisor (:one_for_one)
│
├── Phoenix.PubSub
│     Real-time event bus for dashboard and observability.
│
├── AgentSupervisor (Task.Supervisor)
│     Spawns per-issue agent tasks. Isolates agent crashes
│     from the rest of the tree. max_restarts: 10, max_seconds: 60.
│
├── RestartMonitor (GenServer)
│     Watches AgentSupervisor; logs warnings on termination.
│
├── WorkflowStore (GenServer)
│     Caches WORKFLOW.md (YAML frontmatter + prompt template).
│     Polls for file changes every 1 second.
│
├── Linear.CircuitBreaker (GenServer)
│     Wraps Linear API calls with failure tracking.
│     5 failures → open, 60s cooldown, 15s probe interval.
│
├── Orchestrator (GenServer, shutdown: :infinity)
│     Main polling loop. Dispatches issues to agents,
│     tracks running entries, manages fleet pause/probe.
│
├── TelemetryCollector (GenServer)
│     OTLP/HTTP receiver on :4318. Aggregates Claude Code
│     metrics and forwards them to Orchestrator.
│
├── HttpServer (conditional — requires server.port config)
│     Phoenix/Bandit endpoint. Hosts dashboard, health
│     check, and observability API.
│
└── StatusDashboard (GenServer)
      Terminal UI renderer. Refreshes orchestrator state
      every 16ms render cycle with 1s data refresh.
```

Source: `lib/symphony_elixir.ex` — `SymphonyElixir.Application.start/2`

### Startup Sequence

1. Configure log file with stderr redaction via `LogRedactor`.
2. Set persistent terms: `symphony_started_at`, `symphony_shutting_down = false`.
3. Start supervisor tree (children in order above).
4. Orchestrator schedules initial `:tick` after 0ms delay.

### Shutdown Sequence

1. `prep_stop/1` — set `symphony_shutting_down = true`, blocking new dispatches.
2. Orchestrator `terminate/2` — drain running agents up to `shutdown_timeout_ms`, then force-kill stragglers and clean up workspaces.
3. `stop/1` — render offline status dashboard.

## Data Flow

```
                          ┌───────────────┐
                          │  Linear API   │
                          └──────┬────────┘
                                 │ GraphQL (via CircuitBreaker)
                                 ▼
┌──────────────────────────────────────────────────────────┐
│                     Orchestrator                         │
│                                                          │
│  :tick ──► maybe_dispatch ──► choose_issues              │
│                                    │                     │
│              ┌─────────────────────┘                     │
│              ▼                                           │
│     AgentSupervisor.start_agent(fn -> ... end)           │
│              │                                           │
│              │  {:agent_worker_update, ...}               │
│              │◄──────────────────────────┐               │
│              │                           │               │
│  running map + agent_totals              │               │
│              │                           │               │
│              ▼                           │               │
│     PubSub.broadcast(:orchestrator_update)│               │
└──────────┬───────────────────────────────┘               │
           │                               │               │
           ▼                               │               │
  ┌─────────────────┐            ┌─────────┴──────────┐    │
  │ StatusDashboard  │            │    AgentRunner     │    │
  │  (terminal UI)   │            │                    │    │
  └─────────────────┘            │  Workspace.create  │    │
           │                     │  before_run hook    │    │
           ▼                     │  run_agent_turns ───┼────┘
  ┌─────────────────┐            │  after_run hook     │
  │ DashboardLive   │            │  cleanup            │
  │  (Phoenix LV)   │            └────────┬────────────┘
  └─────────────────┘                     │
                                          ▼
                                 ┌─────────────────┐
                                 │   AgentServer    │
                                 │  (JSON-RPC/stdio)│
                                 │                  │
                                 │  initialize      │
                                 │  thread/start    │
                                 │  turn/start      │
                                 │  receive_loop    │
                                 └─────────────────┘
                                          │
                                          ▼
                                 ┌─────────────────┐
                                 │   Claude Code    │
                                 │   (subprocess)   │
                                 └─────────────────┘
```

### Polling Cycle

The Orchestrator runs a timer-driven loop:

1. **`:tick`** fires every `poll_interval_ms` (default 30s). Sets `poll_check_in_progress = true`, schedules `:run_poll_cycle` after 20ms (render delay).
2. **`:run_poll_cycle`** refreshes runtime config, calls `maybe_dispatch(state)`, then schedules the next `:tick`.
3. **`maybe_dispatch`** reconciles running issues against Linear state, fetches candidates via CircuitBreaker, checks available slots, and calls `choose_issues`.

### Issue Selection

Issues are sorted by `(priority_rank, created_at, identifier)`. Each candidate is checked against:

- `can_dispatch?` — not fleet-paused and not shutting down.
- `candidate_issue?` — has required fields, in active state, not terminal.
- Not blocked by a non-terminal blocker (for "Todo" issues).
- Not already claimed or running.
- `available_slots > 0` — respects `max_concurrent_agents` (default 10).
- `state_slots_available?` — respects per-state limits from `max_concurrent_agents_by_state`.

### Dispatch

1. Revalidate issue state via fresh Linear fetch.
2. Spawn agent task under AgentSupervisor.
3. Monitor with `Process.monitor(pid)`.
4. Add to `running` map and `claimed` set.

### Issue Reconciliation

On each poll cycle, `reconcile_running_issues/1` refreshes all running issue states from Linear:

- **Terminal state** (Done, Closed, Cancelled, Duplicate) — terminate agent and clean up workspace.
- **Re-routed** (assignee changed) — terminate agent.
- **Active** — refresh issue data in the running entry.

### Agent Completion

When the monitored task exits (`:DOWN` message):

- **Normal exit** — schedule continuation check (issue may still need work).
- **Error exit** — schedule retry with exponential backoff: `min(10_000 * 2^attempt, max_retry_backoff_ms)`.
- **Probe agent** — see Fleet Pause section below.

## OTel Pipeline

Claude Code processes emit OpenTelemetry metrics over OTLP/HTTP. Symphony collects these to supplement the primary token accounting from agent events.

```
Claude Code agent
       │
       │  OTLP/HTTP POST
       ▼
TelemetryCollector (:4318)
  /v1/metrics    ──► parse OTLP ExportMetricsServiceRequest
  /v1/logs       ──► parse OTLP ExportLogsServiceRequest
       │
       │  {:otel_metrics, session_id, metrics}
       ▼
Orchestrator
       │
       │  match session_id → issue_id in running map
       │  merge into running entry otel_* fields
       ▼
running_entry.otel_input_tokens
running_entry.otel_output_tokens
running_entry.otel_cost_usd
running_entry.otel_tool_executions
running_entry.otel_api_errors
running_entry.otel_lines_changed
running_entry.otel_commits_count
running_entry.otel_prs_count
running_entry.otel_active_time_seconds
```

### Metric Parsing

1. Extract `session.id` from OTLP resource attributes.
2. Extract `claude_code.*` metrics from scope metrics.
3. Parse data points across sum, gauge, and histogram formats.
4. Aggregate per session in TelemetryCollector GenServer state.

### OTel vs Agent Token Accounting

Both pipelines feed into the orchestrator but serve different purposes:

| Source | Path | Fields |
| --- | --- | --- |
| Agent events | `:agent_worker_update` → delta computation | `agent_input_tokens`, `agent_output_tokens`, etc. |
| OTel metrics | `:otel_metrics` → direct merge | `otel_input_tokens`, `otel_output_tokens`, etc. |

On agent completion, OTel metrics (tool executions, API errors, lines changed, commits, PRs, active time) are folded into `agent_totals`.

## Token Accounting

Token usage flows through the agent event stream and is accumulated via delta computation. See `docs/token_accounting.md` for the full deep-dive.

### Summary

Claude Code reports **absolute cumulative values** per turn. The Orchestrator computes deltas against high-water marks to avoid double-counting.

```
Agent update arrives with usage: {input_tokens: 150, output_tokens: 80}
                                          │
                                          ▼
             ┌─────────────────────────────────────────┐
             │  extract_token_delta(running_entry, update)  │
             │                                              │
             │  previous reported input: 100                │
             │  new reported input:      150                │
             │  delta input:              50                │
             └──────────────────┬───────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
          running_entry                agent_totals
     agent_input_tokens += 50     input_tokens += 50
     last_reported_input = 150    (floored at 0)
```

### Per-Entry Fields

Each running entry tracks both accumulated and last-reported values:

- `agent_input_tokens`, `agent_output_tokens`, `agent_total_tokens` — accumulated deltas.
- `agent_last_reported_input_tokens`, etc. — high-water marks. Updated via `max(old, new)` to protect against out-of-order messages.
- `agent_cache_read_tokens`, `agent_cache_creation_tokens`, `agent_cost_usd`, `agent_model`.

### Global Totals

`state.agent_totals` aggregates across all entries:

```elixir
%{
  input_tokens: integer,
  output_tokens: integer,
  total_tokens: integer,
  seconds_running: integer,
  cache_read_tokens: integer,
  cache_creation_tokens: integer,
  cost_usd: float,
  model: string | nil
}
```

All totals are floored at zero on each delta application.

## Circuit Breaker

The circuit breaker (`Linear.CircuitBreaker`) protects Linear API calls from cascade failures using a three-state machine.

```
         success
    ┌──────────────┐
    │              │
    ▼              │
┌────────┐   failure_count    ┌────────┐
│ CLOSED │ ──────────────────►│  OPEN  │
│        │   >= threshold (5) │        │
└────────┘                    └───┬────┘
    ▲                             │
    │         cooldown (60s)      │
    │              ▼              │
    │        ┌───────────┐       │
    │        │ HALF_OPEN  │       │
    │        │ (1 probe)  │       │
    │        └─────┬──────┘       │
    │              │              │
    │   success    │   failure    │
    └──────────────┘──────────────┘
```

### States

| State | Behavior |
| --- | --- |
| `:closed` | Calls pass through. Failure count increments on error. Transitions to `:open` at threshold. |
| `:open` | All calls rejected immediately with `{:error, :circuit_open}`. Transitions to `:half_open` after cooldown. |
| `:half_open` | One probe call allowed. Success → `:closed` (reset count). Failure → `:open` (reset cooldown). |

### Usage

```elixir
CircuitBreaker.call(fn -> Client.fetch_candidate_issues() end)
# {:ok, issues} | {:error, :circuit_open} | {:error, reason}
```

The wrapped function executes in the **caller's process**, preserving process dictionary and message semantics.

Source: `lib/symphony_elixir/linear/circuit_breaker.ex`

## Fleet Pause

When rate limits or usage caps are detected, the Orchestrator pauses all dispatch and uses a single probe agent to test recovery.

### Trigger Conditions

**Global usage cap** (immediate):
- Agent reports `error_type: "usage_cap"` with `is_global: true`.
- Pause duration: `min(retry_after_ms || fleet_pause_default_ms, fleet_pause_max_ms)`.
- Defaults: 30 min pause, 4 hour max.

**Rate limit pattern** (threshold-based):
- `consecutive_limit_failures` incremented on rate limit errors or turn failures.
- When count >= `fleet_pause_pattern_threshold` (default 3) within `fleet_pause_pattern_window_ms` (default 60s), fleet pauses.
- Counter resets on any successful turn.

### Pause State

```elixir
fleet_paused_until: DateTime | nil     # pause expiry
fleet_pause_reason: String | nil       # human-readable reason
fleet_pause_attempt: integer           # exponential backoff counter
fleet_probe_active: boolean            # true while probe is running
consecutive_limit_failures: integer    # rate limit failure counter
last_limit_failure_at: DateTime | nil  # timestamp of last failure
```

### Probe Agent

When the pause timer expires:

1. Fetch candidate issues.
2. Pick the **lowest-priority** issue (safest for probe).
3. Spawn a single agent with `is_fleet_probe: true`.
4. Monitor the probe.

### Probe Outcomes

| Outcome | Action |
| --- | --- |
| Normal exit | `clear_fleet_pause` — reset all pause state, resume normal dispatch. |
| Error exit | `extend_fleet_pause` — exponential backoff: `min(default_ms * 2^attempt, max_ms)`. |

Backoff examples: attempt 0 → 30 min, attempt 1 → 60 min, attempt 2 → 120 min, ..., attempt 10+ → 4 hours (capped).

### Dispatch Prevention

```elixir
defp can_dispatch?(state) do
  !fleet_paused?(state) and !shutting_down?()
end
```

## Workspace Lifecycle

Each dispatched issue gets an isolated workspace directory. The full lifecycle is managed by `Workspace` with configurable shell hooks at each stage.

```
  dispatch_issue
       │
       ▼
  Workspace.create_for_issue(issue)
       │
       ├── generate safe identifier (replace non-alnum with _)
       ├── compute path: {workspace_root}/{identifier}
       ├── validate path (within root, no symlink escapes)
       ├── ensure directory exists (clean tmp artifacts if reused)
       └── run after_create hook (if newly created)
       │
       ▼
  Workspace.run_before_run_hook(workspace, issue)
       │
       ▼
  AgentRunner.run_agent_turns(workspace, issue, ...)
       │
       ├── turn 1: full prompt from WorkflowStore
       ├── turn N: continuation guidance
       ├── each turn:
       │     AgentServer.start_session(workspace)
       │     AgentServer.run_turn(session, prompt, issue)
       │     send {:agent_worker_update, ...} to Orchestrator
       │     AgentServer.stop_session(session)
       └── loop while issue in active state and turn < max_turns
       │
       ▼
  Workspace.run_after_run_hook(workspace, issue)
       │
       ▼
  (on issue terminal / reconciliation)
  Workspace.remove_issue_workspaces(identifier)
       │
       ├── run before_remove hook (ignore failures)
       └── File.rm_rf(workspace)
```

### Hooks

Four shell hooks are available, each running via `sh -lc` with the workspace as the working directory:

| Hook | Trigger | Typical Use |
| --- | --- | --- |
| `after_create` | Workspace directory first created | Clone repo, install deps |
| `before_run` | Before agent turns start | Stage repo, set up env |
| `after_run` | After all agent turns complete | Commit, push, cleanup |
| `before_remove` | Before workspace is deleted | Archive artifacts |

All hooks respect `hooks.timeout_ms` (default 60s).

### Hook Validation

`HookValidator.validate/1` checks for dangerous shell patterns: `;`, `|`, `&&`, `$(`, backticks, redirections.

- `allow_shell_hooks: true` (default) — warn only.
- `allow_shell_hooks: false` — reject with error.

### Symlink Escape Prevention

`ensure_no_symlink_components/1` walks the path from root to workspace, checking each segment with `File.lstat/1`. If any component is a symlink, the operation fails with `{:workspace_symlink_escape, ...}`.

## Implementation Reference

| Component | File |
| --- | --- |
| Application & supervisor tree | `lib/symphony_elixir.ex` |
| Orchestrator (polling, dispatch, fleet pause) | `lib/symphony_elixir/orchestrator.ex` |
| Agent runner (workspace + turn loop) | `lib/symphony_elixir/agent_runner.ex` |
| Agent server (JSON-RPC over stdio) | `lib/symphony_elixir/agent_server/server.ex` |
| Circuit breaker | `lib/symphony_elixir/linear/circuit_breaker.ex` |
| Linear client (GraphQL) | `lib/symphony_elixir/linear/client.ex` |
| Linear adapter (CircuitBreaker wrapper) | `lib/symphony_elixir/linear/adapter.ex` |
| Tracker (polymorphic dispatch) | `lib/symphony_elixir/tracker.ex` |
| Telemetry collector (OTLP/HTTP) | `lib/symphony_elixir/telemetry_collector.ex` |
| Workspace management | `lib/symphony_elixir/workspace.ex` |
| Hook validation | `lib/symphony_elixir/hook_validator.ex` |
| Workflow store (WORKFLOW.md cache) | `lib/symphony_elixir/workflow_store.ex` |
| Config (YAML frontmatter) | `lib/symphony_elixir/config.ex` |
| Status dashboard (terminal UI) | `lib/symphony_elixir/status_dashboard.ex` |
| Dashboard LiveView | `lib/symphony_elixir_web/live/dashboard_live.ex` |
| Health check | `lib/symphony_elixir_web/controllers/health_controller.ex` |
| Observability API | `lib/symphony_elixir_web/controllers/observability_api_controller.ex` |
| Rate limiter plug | `lib/symphony_elixir_web/plugs/rate_limiter.ex` |
| Log redaction | `lib/symphony_elixir/log_redactor.ex` |
| Restart monitor | `lib/symphony_elixir/restart_monitor.ex` |
