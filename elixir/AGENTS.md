# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Claude Code agents.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Claude Code turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.

## Key Modules

### Orchestration

- `SymphonyElixir.AgentSupervisor` — DynamicSupervisor for agent processes with restart limits.
- `SymphonyElixir.RestartMonitor` — tracks agent restart frequency and enforces thresholds.

### Security & Reliability

- `SymphonyElixir.Linear.CircuitBreaker` — circuit breaker for Linear API calls.
- `SymphonyElixir.HookValidator` — validates and sanitizes shell hook commands before execution.
- `SymphonyElixir.LogRedactor` — redacts secrets from log output.
- `SymphonyElixir.RedactingFormatter` — custom Logger formatter that applies log redaction.

### Web

- `SymphonyElixirWeb.HealthController` — health check endpoint (`/healthz`).

## Configuration

Environment-specific config files live in `config/`:

- `config.exs` — shared, compile-time config.
- `dev.exs` — development overrides.
- `test.exs` — test overrides.
- `prod.exs` — production compile-time config.
- `runtime.exs` — runtime config read from environment variables at boot.

## Docker

A `Dockerfile` is provided in this directory for building a release image. A root-level `docker-compose.yml` defines the full service stack. See `docs/deployment.md` for details.
