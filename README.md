# phonyhuman 🤪

A fork of [OpenAI's Symphony](https://github.com/openai/symphony) that uses **Claude Code** instead of Codex. Works with your Claude Max subscription — no Anthropic API key needed.

phonyhuman 🤪 polls your Linear board for issues, spins up isolated workspaces, and dispatches Claude Code agents to implement them autonomously.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manav03panchal/phonyhuman/main/install.sh | sh
```

## Quick start

```bash
# Generate a config + package skills into your project
phonyhuman init my-project

# Edit my-project.toml with your Linear + repo details, then:
phonyhuman run my-project.toml
```

`phonyhuman init` creates your config **and** copies all agent skills into `.codex/skills/` so your project is self-contained. Skills can be customized per-project — re-running init won't overwrite existing skills.

## How it works

```
PRD → Claude Code (prd skill) → Linear (issues) → phonyhuman 🤪 → Claude Code (agents)
```

1. **Plan**: Feed a PRD to Claude Code — the `prd` skill decomposes it into Linear issues with acceptance criteria, validation steps, and dependency chains
2. **Review**: Issues land in Backlog. Move them to Todo when ready
3. **Execute**: phonyhuman 🤪 picks up Todo issues, dispatches Claude Code agents in isolated workspaces
4. **Implement**: Agents write code, commit, push branches, open PRs, and move issues to Human Review
5. **Review**: Humans review PRs, approve (→ Merging) or request changes (→ Rework)
6. **Land**: Agents squash-merge approved PRs and move issues to Done

Multiple agents run in parallel. Dependencies are respected — blocked issues wait.

## Commands

```
phonyhuman init [name]     Generate config + package skills into .codex/skills/
phonyhuman run <config>    Run the orchestrator
phonyhuman doctor          Check all prerequisites
phonyhuman version         Show version
phonyhuman update          Self-update from GitHub releases
phonyhuman help            Usage info
```

## Prerequisites

- **Claude Code** with a Max subscription (`claude` CLI in PATH)
- **Erlang/OTP 28** (auto-installed via [mise](https://mise.jdx.dev/) if missing)
- **Python 3.11+** (for the protocol shim)
- **Linear account** with a personal API key
- **GitHub CLI** (`gh`) — recommended for the PR workflow ([install](https://cli.github.com))

## Skills

phonyhuman 🤪 ships with agent skills that are packaged into your project on `init`:

| Skill | Purpose |
|---|---|
| **prd** | Decompose a PRD into Linear issues with dependencies, acceptance criteria, and validation |
| **sprint-planning** | Reference guide for Scrum Masters — issue structure, sizing, and workflow conventions |
| **linear** | Raw Linear GraphQL operations (comments, state transitions, attachments) |
| **commit** | Produce well-formed git commits with conventional types and rationale |
| **push** | Push branches, create/update PRs with proper titles and descriptions |
| **pull** | Sync feature branches with origin/main, resolve merge conflicts |
| **land** | Squash-merge approved PRs after conflict/CI checks |

### PRD → Issues workflow

The `prd` skill handles the full planning pipeline:

1. Reads a PRD (file, URL, or pasted text)
2. Scans the target repo for tech stack, patterns, and file structure
3. Finds or **creates** the Linear project if it doesn't exist
4. Verifies and **creates** required workflow states (Human Review, Merging, Rework) if missing
5. Decomposes the PRD into agent-sized issues (1–5 files each, single responsibility)
6. Creates all issues in **Backlog** with `blockedBy` dependency chains
7. Summarizes parallel tracks, critical path, and estimated points

### Agent execution workflow

When phonyhuman 🤪 dispatches an agent, it uses the `commit`, `push`, `pull`, `land`, and `linear` skills through the workflow prompt. Each agent:

1. Picks up an issue from Todo, moves to In Progress
2. Creates a Codex Workpad comment on the issue
3. Plans, implements, validates against acceptance criteria
4. Pushes a branch, opens a PR with the `symphony` label
5. Runs a PR feedback sweep (addresses review comments)
6. Moves to Human Review when all checks pass
7. After approval, squash-merges via the `land` skill

## Configuration

Edit the generated `.toml` file:

```toml
[linear]
api_key = ""                  # or set LINEAR_API_KEY env var
project_slug = "my-project-abc123"

[repo]
url = "git@github.com:your-org/your-repo.git"
local_repo = "/path/to/local/checkout"  # enables fast worktree mode

[agent]
max_concurrent = 5
max_turns = 20
poll_interval_ms = 10000

[workspace]
root = "~/symphony-workspaces"
```

### Required fields

| Field | Description |
|---|---|
| `linear.api_key` | Linear personal API token (`lin_api_...`). Can also use `LINEAR_API_KEY` env var |
| `linear.project_slug` | From your Linear project URL: `linear.app/team/project/<SLUG>` |
| `repo.url` | Git clone URL (SSH or HTTPS) |

### Optional fields

```toml
[linear]
# Customize which states phonyhuman watches
active_states = ["Todo", "In Progress", "Merging", "Rework"]
terminal_states = ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

[repo]
# Use worktree mode (default when local_repo is set) for fast workspace creation
local_repo = "/path/to/your/repo"

# Custom workspace hooks (shell commands)
after_create = 'git clone --depth 1 "$SOURCE_REPO_URL" . && npm install'
before_run = "git pull origin main"
after_run = "npm run lint"

[agent]
max_concurrent = 5        # parallel agents (default: 5)
max_turns = 20             # max turns per issue (default: 20)
poll_interval_ms = 10000   # poll interval in ms (default: 10000)

[workspace]
root = "~/symphony-workspaces"

# Enable live web dashboard
[server]
port = 4000

# Custom prompt template (Liquid syntax)
[prompt]
template = """
Your custom prompt here...
{{ issue.identifier }} {{ issue.title }}
"""
```

### Finding your project slug

Right-click your project in Linear → Copy link. The slug is the last part of the URL:

```
https://linear.app/myteam/project/my-project-abc123
                                   ^^^^^^^^^^^^^^^^^ this
```

### Required Linear workflow states

Your Linear team must have these states configured:

| State | Type | Purpose |
|---|---|---|
| **Backlog** | Backlog | Issues not yet ready for agents |
| **Todo** | Unstarted | Ready for agent pickup |
| **In Progress** | Started | Agent is actively working |
| **Human Review** | Started | PR ready for human review |
| **Merging** | Started | Human approved; agent landing PR |
| **Rework** | Started | Changes requested; agent re-implements |
| **Done** | Completed | PR merged, issue complete |

**Human Review**, **Merging**, and **Rework** must be named exactly as shown — agents use exact string matching. The `prd` skill can create these automatically when setting up a new project.

## PR workflow and Linear states

```
Backlog → Todo → In Progress → Human Review → Merging → Done
                                    ↑              |
                                    └── Rework ←───┘
```

| State | What happens |
|---|---|
| **Backlog** | Agent ignores. Issues await human review / sprint planning |
| **Todo** | Agent picks up issue within seconds, moves to In Progress |
| **In Progress** | Agent implements, creates branch, opens PR, runs tests |
| **Human Review** | PR is ready; agent waits for human approval |
| **Rework** | Reviewer requested changes; agent closes PR, starts fresh |
| **Merging** | Human approved; agent monitors CI and squash-merges |
| **Done** | PR merged, issue complete |

## Architecture

```
phonyhuman 🤪            TOML config → generates WORKFLOW.md → launches Symphony
  └─ Symphony (Elixir)   Polls Linear, manages workspaces, dispatches agents
       └─ claude-shim.py Speaks Codex JSON-RPC protocol, drives Claude Code CLI
            └─ claude     Your Claude Max subscription does the actual work
```

### Key files

| File | Purpose |
|---|---|
| `bin/phonyhuman` | CLI — reads TOML, validates, builds, runs |
| `claude-shim.py` | Protocol adapter (Codex JSON-RPC → Claude Code CLI) |
| `linear-cli.py` | CLI for agents to read/write Linear issues |
| `skills/` | Agent skills (packaged into projects on init) |
| `templates/default-prompt.md` | Workflow prompt template for agents |
| `example.toml` | Documented config template |
| `elixir/` | Symphony orchestrator (Elixir/OTP) |
| `install.sh` | Curl-installable installer |

### How the shim works

Symphony was built to talk to OpenAI's Codex via a JSON-RPC 2.0 protocol over stdio. `claude-shim.py` is a drop-in replacement that:

- Responds to `initialize`, `thread/start`, `turn/start` RPC messages
- Spawns `claude -p <prompt> --output-format stream-json --dangerously-skip-permissions` for each turn
- Streams Claude's events back as notifications
- Emits `turn/completed` or `turn/failed` when done
- Handles `linear_graphql` tool calls from Symphony

Zero dependencies — just Python stdlib.

## Web dashboard

Add a port to your config to enable the live dashboard:

```toml
[server]
port = 4000
```

Then open `http://localhost:4000` to see running agents, token usage, and issue status.

## Updating

```bash
phonyhuman update
```

## Environment variables

| Variable | Description |
|---|---|
| `PHONYHUMAN_HOME` | Install directory (default: `~/.phonyhuman`) |
| `LINEAR_API_KEY` | Linear personal API token |
| `SOURCE_REPO_URL` | Git clone URL (overrides config) |
| `GITHUB_TOKEN` | Auth token for private repo / self-update |
| `PHONYHUMAN_VERSION` | Pin installer to a specific version |

## License

This project is based on [OpenAI's Symphony](https://github.com/openai/symphony), licensed under [Apache License 2.0](LICENSE).
