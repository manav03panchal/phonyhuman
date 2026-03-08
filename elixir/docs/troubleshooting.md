# Troubleshooting

Common runtime issues and how to resolve them.

---

## EADDRINUSE on startup

**Symptom:** Symphony fails to start with an `eaddrinuse` error on port 4318
(telemetry collector) or 4000 (HTTP server).

**Cause:** A previous Symphony instance is still holding the port. This
typically happens after an unclean shutdown or when running multiple instances.

**Fix:**

```bash
# Find and kill the process holding the port
kill $(lsof -t -i :4318)

# Or for the HTTP server port
kill $(lsof -t -i :4000)
```

Symphony has built-in stale instance detection (`SymphonyElixir.CLI.detect_stale_pid/1`)
that will identify the blocking PID and suggest the kill command automatically
when it encounters this error.

---

## "malformed JSON event from agent"

**Symptom:** Log messages about malformed JSON from an agent's stdout stream.

**Cause:** Claude Code's shim layer prints debug lines to stdout (prefixed with
`[claude-shim]` or `[shim]`). These are not JSON and cannot be parsed, but they
are **cosmetic** — not a real error. The agent is still running normally.

**Details:**

- Lines prefixed with `[claude-shim]` or `[shim]` are recognized by
  `SymphonyElixir.AgentServer.Server.shim_debug_line?/1` and are silently
  filtered — they do not produce `:malformed` events.
- Other non-JSON output is logged at debug level (or warning level if it
  contains error-related keywords) and emitted as a `:malformed` message, but
  this does not affect agent operation.
- Non-JSON output is truncated to 1,000 bytes in logs.

**Action:** No action required. If you see these messages frequently, check that
the agent's shim is not producing unexpected output.

---

## Tokens / TPS showing 0

**Symptom:** The dashboard shows 0 tokens or 0 TPS even though agents are
running.

**Cause:** Token usage counters only update when API calls complete — not during
streaming. Until the first API response finishes, all token fields
(`input_tokens`, `output_tokens`, `total_tokens`, `cache_read_tokens`,
`cache_creation_tokens`, `cost_usd`) remain at zero.

**Details:**

- Token data is extracted from completed agent messages in
  `SymphonyElixir.Orchestrator` and aggregated in `SymphonyElixir.StatusDashboard`.
- TPS (tokens per second) is calculated over a 5-second sliding window
  (`@throughput_window_ms`). Short-lived idle gaps will show as 0.
- OTel metrics (collected on port 4318 by `SymphonyElixir.TelemetryCollector`)
  are a secondary reporting path. Only metrics with the `claude_code.` prefix
  are extracted — if you rely on OTel, verify that your agent is emitting
  metrics with that prefix.

**Action:** Wait for at least one API call to complete. If tokens remain at 0
after agents have been running for a while, check that agent processes are alive
and not stuck in a crash loop (see next section).

---

## Random stops / process exits

**Symptom:** Agent processes stop unexpectedly or the entire application
restarts.

**Cause:** The OTP supervisor's `max_restarts` limit was exceeded, causing the
supervisor to shut down its child tree.

**Current limits:**

| Supervisor | max_restarts | max_seconds | Strategy |
|---|---|---|---|
| `SymphonyElixir.Supervisor` (main) | 10 | 30 | `:one_for_one` |
| `SymphonyElixir.AgentSupervisor` | 10 | 60 | `Task.Supervisor` |

If an agent crashes more than 10 times within 60 seconds, the agent supervisor
shuts down. If infrastructure processes crash more than 10 times within 30
seconds, the entire application stops.

**Common crash-loop causes:**

- **Linear API down** — The circuit breaker (`SymphonyElixir.Linear.CircuitBreaker`)
  should absorb this, but if the breaker itself is restarting, crashes can
  propagate.
- **Workspace hook failures** — A hook command that consistently fails can cause
  repeated agent task crashes.
- **Agent port exits** — The underlying Claude Code process exits unexpectedly
  (OOM, signal, broken pipe).

**Diagnosis:**

```bash
# Check recent logs for crash reasons
grep -i "shutdown\|crash\|restart\|max_restarts" log/symphony.log
```

Look for `** (EXIT)` or `[error]` entries that show the crash reason. The
`SymphonyElixir.RestartMonitor` watches the agent supervisor and logs warnings
when restart rates are high.

---

## Dashboard not updating

**Symptom:** The web dashboard at `http://localhost:4000` is stale or not
showing real-time updates.

**Checks:**

1. **PubSub running?** — The dashboard receives updates via Phoenix PubSub on
   the `"observability:dashboard"` topic (server: `SymphonyElixir.PubSub`). If
   PubSub is not started, LiveView will render the initial state but never
   update. Verify PubSub is in the supervision tree:

   ```elixir
   # In IEx
   Process.whereis(SymphonyElixir.PubSub)
   ```

2. **LiveView WebSocket connected?** — Open browser DevTools → Network → WS
   tab. You should see an active WebSocket connection to `/live/websocket`. If
   disconnected, check for JavaScript errors or network issues.

3. **Dashboard enabled?** — The config key `[:observability, :dashboard_enabled]`
   must be `true` (default). Check your config:

   ```elixir
   # In IEx
   SymphonyElixir.Config.observability_enabled?()
   ```

4. **Refresh interval** — Dashboard refresh is controlled by
   `[:observability, :refresh_ms]` (default: 1,000ms). If set too high,
   updates will appear delayed.

---

## Circuit breaker stuck open

**Symptom:** All Linear API calls fail immediately with a circuit breaker
rejection. Log messages indicate the circuit is `:open`.

**Cause:** The circuit breaker (`SymphonyElixir.Linear.CircuitBreaker`) tripped
after 5 consecutive failures (default `@default_failure_threshold`). It stays
open for 60 seconds (`@default_cooldown_ms`) before attempting a probe, and
probes every 15 seconds (`@default_probe_interval_ms`) in the `:half_open`
state.

**Fix:**

```elixir
# In IEx — manually reset the circuit breaker
SymphonyElixir.Linear.CircuitBreaker.reset()

# Check current state
SymphonyElixir.Linear.CircuitBreaker.status()
# => %{state: :closed, failure_count: 0, ...}
```

Alternatively, restart the application — the circuit breaker starts in the
`:closed` state.

**Prevention:** If the breaker trips repeatedly, the underlying Linear API issue
must be resolved. Common causes: Linear outage, invalid API key, rate limiting.

---

## Workspace hook rejected

**Symptom:** Hook execution fails with an error about dangerous hook commands.

**Cause:** When `allow_shell_hooks` is `false` in config
(`[:hooks, :allow_shell_hooks]`), the hook validator
(`SymphonyElixir.HookValidator`) rejects commands containing shell
metacharacters.

**Blocked patterns:**

| Pattern | Description |
|---|---|
| `;` | Command separator |
| `\|\|` | Or operator |
| `\|` | Pipe |
| `&&` | And operator |
| `$(` | Command substitution |
| `` ` `` | Backtick execution |
| `>`, `>>` | Output redirection |
| `<`, `<<` | Input redirection |
| `&` | Background execution |

**Fix:**

1. Review the hook command and remove shell metacharacters. Use simple,
   single-command hooks without pipes or chaining.
2. If you need complex hooks, set `allow_shell_hooks: true` in your config.
   With this setting, dangerous patterns produce warnings instead of errors.

**Hook types that are validated:** `after_create`, `before_run`, `after_run`,
`before_remove`.

---

## Docker container restarting

**Symptom:** The Docker container enters a restart loop. Health checks fail with
HTTP 503.

**Cause:** During OTP application startup, the `/health` endpoint returns a 200
response once the HTTP server is ready. During graceful shutdown,
`SymphonyElixir.Application.prep_stop/1` sets `:symphony_shutting_down` to
`true` via `:persistent_term`, and the health controller returns 503. If the
container's `start_period` is too short for OTP to fully boot, the health check
may fail before the app is ready, triggering a restart.

**Dockerfile healthcheck defaults:**

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://localhost:4000/health > /dev/null || exit 1
```

**Fix:**

1. **Increase `start_period`** if OTP startup takes longer than 15 seconds
   (e.g., compiling modules on first boot, slow dependency initialization).
   Try `--start-period=30s` or higher.

2. **Check shutdown timeout** — The agent drain timeout is configured via
   `[:agent, :shutdown_timeout_ms]` (default: 60,000ms, overridable with
   `SHUTDOWN_TIMEOUT_MS` env var). If Docker's `stop_grace_period` is shorter
   than this timeout, the container may be killed before agents finish draining.

3. **Check logs** — If the container restarts immediately, the crash likely
   happens during supervision tree startup, not from health checks. Check
   container logs:

   ```bash
   docker logs <container-id> --tail 50
   ```

4. **Verify port binding** — Ensure nothing else in the Docker network is
   binding port 4000. The HTTP server listens on the address configured by
   `[:server, :host]` (default: `127.0.0.1`). In Docker, you may need to set
   this to `0.0.0.0` so the health check can reach it.
