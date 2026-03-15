# Deployment Guide

## Environment Variables

### Required (production)

| Variable | Description |
|---|---|
| `SECRET_KEY_BASE` | Phoenix secret key for signing cookies and tokens. Generate with `mix phx.gen.secret`. Required in `MIX_ENV=prod`; auto-generated in dev/test. |

### Optional

| Variable | Default | Description |
|---|---|---|
| `PHX_SERVER` | _(unset)_ | Set to any value (e.g. `true`) to start the HTTP server. Required for serving HTTP traffic in production. |
| `PORT` | `4000` | HTTP listen port. |
| `HOST` | `localhost` | Hostname for URL generation. |
| `ALLOWED_ORIGINS` | _(unset)_ | Comma-separated list of allowed origins for CSRF/WebSocket checks. When unset, origin checking is enabled with default behavior. |
| `SHUTDOWN_TIMEOUT_MS` | `60000` | Maximum time (ms) to wait for running agents to finish during graceful shutdown. |

## Configuration Files

| File | Purpose |
|---|---|
| `config/config.exs` | Base configuration shared across all environments. |
| `config/dev.exs` | Development defaults: debug logging, no server auto-start. |
| `config/test.exs` | Test settings: warning-level logging, telemetry collector disabled. |
| `config/prod.exs` | Production defaults: info-level logging, no server auto-start (use `PHX_SERVER`). |
| `config/runtime.exs` | Runtime configuration loaded from environment variables. Runs at boot in all environments. |

## Running in Production

```sh
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export PHX_SERVER=true
export PORT=4000
export HOST=example.com

MIX_ENV=prod mix phx.server
```

# Docker Deployment

This guide covers building and running the Symphony (phonyhuman) orchestrator
in Docker containers.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2+
- A `WORKFLOW.md` configuration file (see `elixir/WORKFLOW.md` for an example)
- A Linear API key

## Quick Start

```bash
# 1. Create an .env file with your secrets
cp .env.example .env
# Edit .env and fill in LINEAR_API_KEY, SECRET_KEY_BASE, etc.

# 2. Place your WORKFLOW.md at the project root
# Ensure it contains:
#   server:
#     host: "0.0.0.0"
#     port: 4000

# 3. Build and start
docker-compose up -d

# 4. View logs
docker-compose logs -f orchestrator

# 5. Open the dashboard
open http://localhost:4000
```

## Building the Image

From the `elixir/` directory:

```bash
docker build -t phonyhuman .
```

Build arguments (override with `--build-arg`):

| Argument         | Default                      | Description           |
| ---------------- | ---------------------------- | --------------------- |
| `ELIXIR_VERSION` | `1.19.5`                     | Elixir version        |
| `OTP_VERSION`    | `28.4`                       | Erlang/OTP version    |
| `DEBIAN_VERSION` | `bookworm-20260223-slim`     | Debian base tag       |

## Docker Environment Variables

Pass these via `.env` file or the `environment` section in `docker-compose.yml`:

| Variable           | Required | Description                                      |
| ------------------ | -------- | ------------------------------------------------ |
| `LINEAR_API_KEY`   | Yes      | Linear API token for issue tracking               |
| `SECRET_KEY_BASE`  | Yes      | Phoenix secret key base (`mix phx.gen.secret`)    |
| `SOURCE_REPO_URL`  | No       | Repository URL for workspace cloning              |
| `LINEAR_ASSIGNEE`  | No       | Filter issues by assignee                         |
| `SYMPHONY_PORT`    | No       | Host port to map (default: 4000)                  |
| `GIT_AUTHOR_NAME`  | No       | Git author name for commits made inside the container |
| `GIT_AUTHOR_EMAIL` | No       | Git author email for commits made inside the container |
| `GIT_COMMITTER_NAME` | No     | Git committer name (defaults to `GIT_AUTHOR_NAME` if unset) |
| `GIT_COMMITTER_EMAIL` | No    | Git committer email (defaults to `GIT_AUTHOR_EMAIL` if unset) |

## Volumes

| Mount Point                     | Purpose                                           |
| ------------------------------- | ------------------------------------------------- |
| `/etc/symphony/WORKFLOW.md`     | Workflow configuration (required, mount read-only) |
| `/var/symphony/workspaces`      | Agent workspaces (persistent named volume)         |
| `/var/log/symphony`             | Application logs                                   |
| `/home/symphony/.ssh/known_hosts` | SSH known hosts for host verification (read-only) |
| `/run/ssh-agent/ssh-auth.sock`    | SSH agent socket forwarded from host               |

## WORKFLOW.md Configuration for Docker

Your `WORKFLOW.md` must set the server host to `0.0.0.0` so the web dashboard
is accessible from outside the container:

```yaml
server:
  host: "0.0.0.0"
  port: 4000
workspace:
  root: /var/symphony/workspaces
```

The `--port 4000` CLI flag in the default CMD overrides the WORKFLOW.md port
setting, but the host binding must be set in WORKFLOW.md.

## External CLI Tools

Symphony agents require `claude` (Claude Code CLI) and optionally `gh`
(GitHub CLI) to operate. These are **not** included in the container image
to keep it small and avoid bundling credentials.

### Mounting from the host

Bind-mount the host binaries into the container:

```yaml
# In docker-compose.yml, uncomment:
volumes:
  - /usr/local/bin/claude:/usr/local/bin/claude:ro
  - /usr/local/bin/gh:/usr/local/bin/gh:ro
```

Ensure the binaries are statically linked or that their runtime dependencies
are available inside the container.

### Authentication

- **Claude CLI**: Set `ANTHROPIC_API_KEY` in your `.env` file.
- **GitHub CLI**: Mount `~/.config/gh` or set `GH_TOKEN` in `.env`.

## Health Check

The container health check probes `GET /health` on port 4000.

**Response when running normally** — `200 OK`:

```json
{
  "status": "ok",
  "uptime_seconds": 3421,
  "active_agents": 2
}
```

**Response during graceful shutdown** — `503 Service Unavailable`:

```json
{
  "status": "shutting_down"
}
```

The docker-compose health check is configured with `interval=30s`,
`timeout=5s`, `start_period=30s`, and `retries=3`. The Dockerfile defines
a shorter `start_period` of 15 s, but docker-compose overrides it.

## Graceful Shutdown

When the orchestrator receives a termination signal (e.g. `SIGTERM` from
`docker stop`), it performs a graceful shutdown sequence:

1. **Health endpoint switches to 503** — load balancers and the Docker
   health check see `shutting_down` and stop sending traffic.
2. **New dispatches are blocked** — the orchestrator stops assigning new
   issues to agents.
3. **Agent drain** — running agents are given time to finish. The default
   drain timeout is **60 seconds**. Agents that complete within the window
   are logged as finished; agents still running after the deadline are
   force-killed and their workspaces cleaned up.
4. **Summary** — the orchestrator logs the count of agents that finished
   versus those that were force-killed.

The drain timeout is configurable via the `SHUTDOWN_TIMEOUT_MS` environment
variable (value in milliseconds). For example, `SHUTDOWN_TIMEOUT_MS=120000`
gives agents two minutes to complete.

## Log Redaction

Log redaction is active by default in production. All log output is piped
through a redacting formatter that replaces sensitive patterns with
`[REDACTED]` before they reach disk or stdout. Redacted patterns include:

- Linear API keys (`lin_api_…`)
- GitHub tokens (`ghp_…`, `ghu_…`)
- OpenAI / Anthropic keys (`sk-…`)
- Bearer tokens, query-string tokens, and password fields

Logs are written to a rotating disk log under the configured `--logs-root`
(default `/var/log/symphony`), with a 10 MB max file size and 5 rotated files.

## Circuit Breaker (Linear API)

All Linear API calls are wrapped in a circuit breaker. During sustained
Linear outages the breaker opens and fails fast instead of queuing up
requests:

| Parameter          | Default   |
|--------------------|-----------|
| Failure threshold  | 5 consecutive failures |
| Cooldown           | 60 s      |
| Half-open probe    | 15 s interval |

**State transitions:**

- **Closed → Open** — after 5 consecutive failures, the breaker opens and
  immediately returns `{:error, :circuit_open}` for all calls.
- **Open → Half-open** — after the cooldown period, one probe call is
  allowed through.
- **Half-open → Closed** — if the probe succeeds, the breaker resets.
- **Half-open → Open** — if the probe fails, the breaker re-opens with
  a shorter probe interval (15 s).

When the breaker is open, the orchestrator skips polling and issue
dispatching until Linear recovers, avoiding cascading failures.

## Running Standalone (without Compose)

```bash
docker run --rm \
  -p 4000:4000 \
  --env-file .env \
  -e SSH_AUTH_SOCK=/run/ssh-agent/ssh-auth.sock \
  -v $(pwd)/WORKFLOW.md:/etc/symphony/WORKFLOW.md:ro \
  -v symphony_workspaces:/var/symphony/workspaces \
  -v $SSH_AUTH_SOCK:/run/ssh-agent/ssh-auth.sock:ro \
  -v ~/.ssh/known_hosts:/home/symphony/.ssh/known_hosts:ro \
  -e GIT_AUTHOR_NAME="Your Name" \
  -e GIT_AUTHOR_EMAIL="you@example.com" \
  phonyhuman
```

## Security Notes

- The container runs as a non-root user (`symphony`, UID 999).
- SSH private keys are **never** mounted into the container; the host SSH agent is forwarded via `SSH_AUTH_SOCK`.
- Secrets are passed via environment variables, never baked into the image.
- The host `~/.gitconfig` is **not** mounted into the container to avoid leaking tokens, signing keys, or `credential.helper` configurations. Git identity is set via `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` environment variables instead.
- `SECRET_KEY_BASE` must be set for production; generate with `mix phx.gen.secret`.
