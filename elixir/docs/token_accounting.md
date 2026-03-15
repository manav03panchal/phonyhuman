# Token Accounting

This document explains how Claude Code reports token usage through its `stream-json` output format and how Symphony accounts for it.

It is based on the current implementation in:

- `claude-shim.py` -- the shim that wraps the Claude CLI
- `elixir/lib/symphony_elixir/agent_server/server.ex` -- event parsing and usage extraction
- `elixir/lib/symphony_elixir/orchestrator.ex` -- token delta computation and accumulation

## Short Version

- Claude Code emits a `stream-json` event stream. The final `result` event carries a flat `usage` object with per-turn cumulative token counts.
- There is no `total` vs `last` distinction. Each result event gives one authoritative usage snapshot for the turn.
- The shim forwards Claude Code events as notifications. The orchestrator extracts usage and accumulates it across turns.

## Claude Code Stream-JSON Format

The shim invokes the Claude CLI with `--output-format stream-json`. This produces one JSON object per line on stdout. The key event types are:

| Event type   | Purpose                                    |
| ------------ | ------------------------------------------ |
| `assistant`  | Streamed assistant message content         |
| `result`     | Final turn result with usage and metadata  |

### The `result` Event

The `result` event is emitted once at the end of a turn. It is the authoritative source for token usage and turn metadata.

Example:

```json
{
  "type": "result",
  "subtype": "success",
  "cost_usd": 0.012,
  "duration_ms": 8340,
  "num_turns": 1,
  "is_error": false,
  "result": "I've updated the configuration file as requested.",
  "session_id": "abc123-def456",
  "model": "claude-sonnet-4-20250514",
  "usage": {
    "input_tokens": 2150,
    "output_tokens": 483,
    "cache_read_input_tokens": 1024,
    "cache_creation_input_tokens": 512
  }
}
```

### Usage Fields

The `usage` object is flat with these fields:

| Field                          | Type    | Description                                          |
| ------------------------------ | ------- | ---------------------------------------------------- |
| `input_tokens`                 | integer | Total input tokens consumed during the turn          |
| `output_tokens`                | integer | Total output tokens generated during the turn        |
| `cache_read_input_tokens`      | integer | Input tokens served from prompt cache                |
| `cache_creation_input_tokens`  | integer | Input tokens written to prompt cache                 |

These are per-turn cumulative values. There is no separate "last" or "delta" field -- the usage object is the complete accounting for the turn.

### Additional Metadata Fields

The `result` event carries metadata alongside usage:

| Field         | Type    | Description                                      |
| ------------- | ------- | ------------------------------------------------ |
| `cost_usd`    | float   | Estimated cost in USD for the turn               |
| `duration_ms` | integer | Wall-clock duration of the turn in milliseconds  |
| `num_turns`   | integer | Number of agentic turns within this invocation   |
| `model`       | string  | Model identifier used for the turn               |

## How The Shim Forwards Events

The shim (`claude-shim.py`) wraps the Claude CLI process and bridges its output into the JSON-RPC notification stream that `app_server.ex` consumes.

### Event Forwarding

1. The shim spawns `claude -p <prompt> --output-format stream-json --dangerously-skip-permissions --allowedTools <list> --verbose`.
2. It reads stdout line-by-line, parsing each line as JSON.
3. Every parsed event is forwarded as a notification:

   ```json
   {
     "method": "item/message",
     "params": {
       "event": {
         "type": "claude_event",
         "event": { "...raw Claude Code event..." }
       }
     }
   }
   ```

4. The final `result` event (containing `usage`) is captured and also forwarded through this same path.

### Turn Completion

When the Claude process exits successfully, the shim sends a `turn/completed` notification:

```json
{
  "method": "turn/completed",
  "params": {
    "turnId": "...",
    "threadId": "..."
  }
}
```

The `turn/completed` notification signals the end of the turn. Token usage arrives via the `result` event forwarded as an `item/message` notification.

## How The App Server Processes Events

`app_server.ex` receives the JSON-RPC stream from the shim and routes events:

1. **Notification parsing**: Each incoming JSON line is decoded. The `method` field determines routing.
2. **Usage extraction**: For every payload, `maybe_set_usage/2` checks for a `usage` key. If found and it is a map, it is attached to the event metadata:

   ```elixir
   defp maybe_set_usage(metadata, payload) when is_map(payload) do
     usage = Map.get(payload, "usage") || Map.get(payload, :usage)
     if is_map(usage), do: Map.put(metadata, :usage, usage), else: metadata
   end
   ```

3. **Event emission**: The event is emitted to the orchestrator as a map containing `:event`, `:payload`, `:raw`, `:timestamp`, and optionally `:usage`.

This means usage data flows through `item/message` events (which carry the Claude Code result) and is available on any event whose payload contains a `usage` map.

## How The Orchestrator Accumulates Tokens

The orchestrator (`orchestrator.ex`) maintains per-entry and global token totals. It processes each update through a delta-based accumulation pipeline.

### State Structure

Global totals are tracked in `state.agent_totals`:

```elixir
%{
  input_tokens: 0,
  output_tokens: 0,
  total_tokens: 0,
  seconds_running: 0
}
```

Per-entry (per-issue) fields track both accumulated tokens and the last reported values used for delta computation:

- `agent_input_tokens`, `agent_output_tokens`, `agent_total_tokens` -- accumulated totals
- `last_reported_input_tokens`, `last_reported_output_tokens`, `last_reported_total_tokens` -- high-water marks from the source
- `turn_count` -- number of completed turns for the entry

### Usage Extraction

`extract_token_usage/1` searches for token data across multiple payload paths:

1. Direct `:usage` key on the update
2. Nested within `:payload`
3. The update map itself as a fallback

Within each candidate, it tries two extraction strategies in order:

1. **Absolute token usage** (`absolute_token_usage_from_payload/1`): Looks for deeply nested paths like `params.tokenUsage.total` -- used when the source provides cumulative thread totals.
2. **Turn-completed usage** (`turn_completed_usage_from_payload/1`): Extracts `usage` from events with method `turn/completed`.

The extracted map is validated by `integer_token_map?/1`, which accepts multiple naming conventions (`input_tokens`, `prompt_tokens`, `inputTokens`, etc.).

### Delta Computation

`extract_token_delta/2` computes the delta between the current update's usage and the previously reported values:

```
delta = max(0, next_reported_total - previous_reported_total)
```

For each token dimension (input, output, total):

1. Read the new reported value from the extracted usage.
2. Read the previous high-water mark from the running entry (`last_reported_*_tokens`).
3. If the new value is greater than or equal to the previous, the delta is the difference.
4. Otherwise the delta is 0 (protects against decreasing values).

### Accumulation

`integrate_agent_update/2` applies the computed delta:

```elixir
agent_input_tokens:  existing_input  + delta.input_tokens
agent_output_tokens: existing_output + delta.output_tokens
agent_total_tokens:  existing_total  + delta.total_tokens
```

The high-water marks are updated to the maximum of the old and new reported values. The delta is also applied to the global `agent_totals` via `apply_token_delta/2`, which floors each total at zero.

## Accounting Strategy

### Core Rule

**The `result` event's `usage` field is the authoritative per-turn total.** Claude Code gives one cumulative usage snapshot per turn -- there is no `total` vs `last` distinction to reconcile.

### Why Delta Computation Still Matters

Even though each turn provides a single cumulative usage value, the orchestrator uses delta computation because:

1. **Multiple events per turn**: Claude Code events stream throughout the turn. The orchestrator may see intermediate usage reports before the final result.
2. **High-water mark protection**: If an earlier event reports a higher value than a later one (due to event ordering), the delta is clamped to zero rather than going negative.
3. **Cross-turn accumulation**: Per-entry totals span multiple turns. Each turn's usage is added as a delta to the running total.

### What Symphony Tracks

| Metric            | Scope     | Source                                    |
| ----------------- | --------- | ----------------------------------------- |
| `input_tokens`    | Per-entry | Accumulated from `result.usage`           |
| `output_tokens`   | Per-entry | Accumulated from `result.usage`           |
| `total_tokens`    | Per-entry | Accumulated from `result.usage`           |
| `turn_count`      | Per-entry | Incremented on each turn completion       |
| `seconds_running` | Global    | Accumulated wall-clock time               |

### What Symphony Does Not Track (Yet)

The following fields are available in the Claude Code result event but are not currently extracted by the orchestrator:

- `cost_usd` -- per-turn cost estimate
- `model` -- model identifier
- `duration_ms` -- per-turn wall-clock duration
- `num_turns` -- agentic sub-turns within a single invocation
- `cache_read_input_tokens` -- prompt cache reads
- `cache_creation_input_tokens` -- prompt cache writes

These fields are forwarded through the event stream and can be extracted if needed.

## Implementation Reference

### File Map

| Component      | File                                              | Key Functions                                                    |
| -------------- | ------------------------------------------------- | ---------------------------------------------------------------- |
| Shim           | `claude-shim.py`                                  | `ClaudeRunner.run()`, `run_turn()`                               |
| App Server     | `elixir/lib/symphony_elixir/agent_server/server.ex` | `handle_incoming/6`, `maybe_set_usage/2`, `emit_turn_event/6`    |
| Orchestrator   | `elixir/lib/symphony_elixir/orchestrator.ex`        | `integrate_agent_update/2`, `extract_token_delta/2`, `extract_token_usage/1` |

### Naming Convention Support

The orchestrator accepts token fields in multiple naming styles for compatibility:

- Snake case: `input_tokens`, `output_tokens`, `total_tokens`
- API style: `prompt_tokens`, `completion_tokens`
- Camel case: `inputTokens`, `outputTokens`, `totalTokens`

Both string and atom keys are supported.

## Implementation Checklist

- Extract usage from Claude Code `result` events via the `item/message` notification path
- Use delta computation against high-water marks to avoid double-counting
- Accumulate per-entry and global totals
- Floor all totals at zero
- Do not assume event ordering -- rely on high-water mark comparison
- Key totals by issue entry, not by thread or turn alone
