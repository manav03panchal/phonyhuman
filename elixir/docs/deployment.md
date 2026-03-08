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
