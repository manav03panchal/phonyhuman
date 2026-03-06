# phonyhuman

A fork of [OpenAI's Symphony](https://github.com/openai/symphony) that uses **Claude Code** instead of Codex. Works with your Claude Max subscription — no Anthropic API key needed.

phonyhuman polls your Linear board for issues, spins up isolated workspaces, and dispatches Claude Code agents to implement them autonomously.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manav03panchal/symphony-claude/main/install.sh | sh
```

## Quick start

```bash
# Generate a config
phonyhuman init my-project

# Edit my-project.toml with your Linear + repo details, then:
phonyhuman run my-project.toml
```

## How it works

```
Linear (issues) → phonyhuman (orchestrator) → Claude Code (agents)
                                             ↘ linear-cli (feedback)
```

1. You create issues in Linear with requirements
2. phonyhuman polls for new issues every few seconds
3. For each issue, it clones your repo into an isolated workspace
4. Claude Code picks up the issue, reads the requirements, writes code, commits, and updates Linear
5. Repeat — multiple agents run in parallel

## Commands

```
phonyhuman init [name]     Generate a config file from template
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

## Configuration

Edit the generated `.toml` file:

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
5. **Pushes** a branch, opens a PR, and attaches it to the Linear issue
6. **Updates the Workpad** with progress, test results, notes
7. **Moves to "Human Review"** when all acceptance criteria and PR checks pass
8. After human approval, **lands the PR** via squash-merge

### PR workflow and Linear states

Agents use a full branch-based PR workflow with these Linear states:

```
Todo → In Progress → Human Review → Merging → Done
                          ↑              |
                          └── Rework ←───┘
```

| State | What happens |
|---|---|
| **Todo** | Agent picks up issue, moves to In Progress |
| **In Progress** | Agent implements, creates branch, opens PR, runs tests |
| **Human Review** | PR is ready; agent waits for human approval |
| **Rework** | Reviewer requested changes; agent resets and re-implements |
| **Merging** | Human approved; agent monitors CI and squash-merges |
| **Done** | PR merged, issue complete |

Agents ship with skills for each phase: `commit`, `push`, `pull`, and `land`. These are installed at `~/.phonyhuman/skills/` and referenced in the generated workflow.

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
phonyhuman               TOML config → generates WORKFLOW.md → launches Symphony
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
