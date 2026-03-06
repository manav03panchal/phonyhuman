# Symphony + Claude Code

A fork of [OpenAI's Symphony](https://github.com/openai/symphony) that uses **Claude Code** instead of Codex. Works with your Claude Max subscription — no Anthropic API key needed.

Symphony polls your Linear board for issues, spins up isolated workspaces, and dispatches Claude Code agents to implement them autonomously.

## How it works

```
Linear (issues) → Symphony (orchestrator) → Claude Code (agents)
                                          ↘ linear-cli (feedback)
```

1. You create issues in Linear with requirements
2. Symphony polls for new issues every few seconds
3. For each issue, it clones your repo into an isolated workspace
4. Claude Code picks up the issue, reads the requirements, writes code, commits, and updates Linear
5. Repeat — multiple agents run in parallel

## Prerequisites

- **Claude Code** with a Max subscription (`claude` CLI in PATH)
- **Elixir 1.19+** / OTP 28 (install via [mise](https://mise.jdx.dev/), asdf, or [elixir-lang.org](https://elixir-lang.org/install.html))
- **Python 3.11+** (for the protocol shim)
- **Linear account** with a personal API key

## Quick start

```bash
# Clone
git clone https://github.com/manav03panchal/symphony-claude.git
cd symphony-claude

# Generate a config
./run-symphony.sh --init my-project.toml
```

Edit `my-project.toml`:

```toml
[linear]
api_key = ""                  # or set LINEAR_API_KEY env var
project_slug = "my-project-abc123"

[repo]
url = "git@github.com:your-org/your-repo.git"

[agent]
max_concurrent = 5
max_turns = 20
poll_interval_ms = 10000

[workspace]
root = "~/symphony-workspaces"
```

Run it:

```bash
# With the key in the config
./run-symphony.sh my-project.toml

# Or with env var
LINEAR_API_KEY="lin_api_..." ./run-symphony.sh my-project.toml
```

The launcher auto-detects Elixir, builds Symphony on first run, validates your Linear connection, and starts the dashboard.

## Configuration

### Required fields

| Field | Description |
|---|---|
| `linear.api_key` | Linear personal API token (`lin_api_...`). Can also use `LINEAR_API_KEY` env var |
| `linear.project_slug` | From your Linear project URL: `linear.app/team/project/<SLUG>` |
| `repo.url` | Git clone URL (SSH or HTTPS) |

### Optional fields

```toml
[linear]
# Customize which states Symphony watches
active_states = ["Todo", "In Progress"]
terminal_states = ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

[repo]
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

## What agents do

Each agent follows this workflow on every issue:

1. **Fetches** the issue details from Linear
2. **Moves** it to "In Progress"
3. **Creates a Workpad** comment on the issue to track progress
4. **Implements** the requirements — reads code, writes changes, commits
5. **Updates the Workpad** with progress, test results, notes
6. **Moves to "Done"** when all acceptance criteria are met

Agents interact with Linear using `linear-cli.py`, which supports:

```bash
linear-cli.py get-issue HUM-5          # fetch issue details
linear-cli.py comment HUM-5 "message"  # post a comment
linear-cli.py edit-comment <id> "body"  # update a comment
linear-cli.py get-comments HUM-5       # list comments
linear-cli.py set-state HUM-5 "Done"   # move issue state
linear-cli.py attach-url HUM-5 <url>   # attach a link
linear-cli.py graphql <query>          # raw GraphQL
```

## Architecture

```
run-symphony.sh          TOML config → generates WORKFLOW.md → launches Symphony
  └─ Symphony (Elixir)   Polls Linear, manages workspaces, dispatches agents
       └─ claude-shim.py Speaks Codex JSON-RPC protocol, drives Claude Code CLI
            └─ claude     Your Claude Max subscription does the actual work
```

### Key files

| File | Purpose |
|---|---|
| `run-symphony.sh` | Launcher — reads TOML, validates, builds, runs |
| `claude-shim.py` | Protocol adapter (Codex JSON-RPC → Claude Code CLI) |
| `linear-cli.py` | CLI for agents to read/write Linear issues |
| `example.toml` | Documented config template |
| `elixir/` | Symphony orchestrator (Elixir/OTP) |

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

Pull upstream changes from OpenAI's Symphony:

```bash
git pull upstream main
```

## License

This project is based on [OpenAI's Symphony](https://github.com/openai/symphony), licensed under [Apache License 2.0](LICENSE).
