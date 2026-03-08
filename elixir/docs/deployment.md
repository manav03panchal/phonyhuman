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

## Volumes

| Mount Point                     | Purpose                                           |
| ------------------------------- | ------------------------------------------------- |
| `/etc/symphony/WORKFLOW.md`     | Workflow configuration (required, mount read-only) |
| `/var/symphony/workspaces`      | Agent workspaces (persistent named volume)         |
| `/var/log/symphony`             | Application logs                                   |
| `/home/symphony/.ssh`           | SSH keys for git operations (mount read-only)      |
| `/home/symphony/.gitconfig`     | Git configuration (mount read-only)                |

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

The container health check probes `GET /health` on port 4000. This
lightweight endpoint returns 200 when the orchestrator is running and 503
during graceful shutdown.

## Running Standalone (without Compose)

```bash
docker run --rm \
  -p 4000:4000 \
  --env-file .env \
  -v $(pwd)/WORKFLOW.md:/etc/symphony/WORKFLOW.md:ro \
  -v symphony_workspaces:/var/symphony/workspaces \
  -v ~/.ssh:/home/symphony/.ssh:ro \
  -v ~/.gitconfig:/home/symphony/.gitconfig:ro \
  phonyhuman
```

## Security Notes

- The container runs as a non-root user (`symphony`, UID 999).
- SSH keys and `.gitconfig` are mounted read-only.
- Secrets are passed via environment variables, never baked into the image.
- `SECRET_KEY_BASE` must be set for production; generate with `mix phx.gen.secret`.
