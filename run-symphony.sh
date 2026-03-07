#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# run-symphony.sh — Plug-and-play Symphony launcher with Claude Code
#
# DEPRECATED: Use 'phonyhuman' instead.
#   Install: curl -sSL https://raw.githubusercontent.com/manav03panchal/phonyhuman/main/install.sh | sh
#   Then:    phonyhuman run my-project.toml
#
# Usage:
#   ./run-symphony.sh my-project.toml
#   ./run-symphony.sh                    # uses ./symphony.toml
#   ./run-symphony.sh --init             # generate a new config
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Deprecation notice ───────────────────────────────────────────────
echo ""
printf "\033[33m  ⚠  run-symphony.sh is deprecated. Use 'phonyhuman' instead:\033[0m\n"
echo ""
printf "\033[36m  curl -sSL https://raw.githubusercontent.com/manav03panchal/phonyhuman/main/install.sh | sh\033[0m\n"
printf "\033[36m  phonyhuman run my-project.toml\033[0m\n"
echo ""
printf "\033[90m  Continuing with legacy launcher...\033[0m\n"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYMPHONY_BIN="$SCRIPT_DIR/elixir/bin/symphony"
SHIM_PATH="$SCRIPT_DIR/claude-shim.py"

# ── Color helpers ────────────────────────────────────────────────────
bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }
cyan()  { printf "\033[36m%s\033[0m" "$*"; }
dim()   { printf "\033[90m%s\033[0m" "$*"; }

die() { echo ""; red "  ERROR: $1"; echo ""; exit 1; }

banner() {
    echo ""
    bold "  ♫ Symphony + Claude Code"; echo ""
    dim "  Autonomous issue orchestration powered by your Claude Max subscription"; echo ""
    echo ""
}

# ── Find Elixir/OTP ─────────────────────────────────────────────────
find_elixir() {
    if command -v elixir &>/dev/null; then return 0; fi
    local search_dirs=(
        "$HOME/.elixir-install/installs"
        "$HOME/.asdf/installs/elixir"
        "$HOME/.mise/installs/elixir"
    )
    for base in "${search_dirs[@]}"; do
        if [[ -d "$base" ]]; then
            local elixir_bin
            elixir_bin=$(find "$base" -name "elixir" -type f -path "*/bin/elixir" 2>/dev/null | head -1)
            if [[ -n "$elixir_bin" ]]; then
                export PATH="$(dirname "$elixir_bin"):$PATH"
                local erl_bin
                erl_bin=$(find "$(dirname "$base")" -name "erl" -type f -path "*/bin/erl" 2>/dev/null | head -1)
                if [[ -n "$erl_bin" ]]; then
                    export PATH="$(dirname "$erl_bin"):$PATH"
                fi
                return 0
            fi
        fi
    done
    return 1
}

# ── --init: generate config ──────────────────────────────────────────
do_init() {
    local target="${1:-symphony.toml}"
    if [[ -f "$target" ]]; then
        die "$target already exists"
    fi
    cp "$SCRIPT_DIR/example.toml" "$target"
    green "  Created $target"; echo ""
    dim "  Edit it with your Linear + repo details, then run:"; echo ""
    echo "  ./run-symphony.sh $target"
    echo ""
    exit 0
}

# ── Parse TOML and generate WORKFLOW.md ──────────────────────────────
generate_workflow() {
    local config_file="$1"
    local workflow_file="$2"

    python3 - "$config_file" "$workflow_file" "$SHIM_PATH" <<'PYEOF'
import sys, os, tomllib, json

config_file, workflow_file, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_file, "rb") as f:
    cfg = tomllib.load(f)

linear   = cfg.get("linear", {})
repo     = cfg.get("repo", {})
agent    = cfg.get("agent", {})
workspace = cfg.get("workspace", {})
server   = cfg.get("server", {})
prompt_cfg = cfg.get("prompt", {})

api_key      = linear.get("api_key", "") or os.environ.get("LINEAR_API_KEY", "")
slug         = linear.get("project_slug", "")
repo_url     = repo.get("url", "") or os.environ.get("SOURCE_REPO_URL", "")
max_agents   = agent.get("max_concurrent", 5)
max_turns    = agent.get("max_turns", 20)
poll_ms      = agent.get("poll_interval_ms", 10000)
ws_root      = workspace.get("root", "~/symphony-workspaces")
port         = server.get("port", None)

active_states   = linear.get("active_states", ["Todo", "In Progress"])
terminal_states = linear.get("terminal_states", ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])

errors = []
if not api_key:      errors.append("linear.api_key (or LINEAR_API_KEY env var)")
if not slug:         errors.append("linear.project_slug")
if not repo_url:     errors.append("repo.url (or SOURCE_REPO_URL env var)")
if errors:
    print("MISSING:" + "|".join(errors))
    sys.exit(1)

# Export for Symphony's hook to use
print(f"EXPORT:LINEAR_API_KEY={api_key}")
print(f"EXPORT:SOURCE_REPO_URL={repo_url}")
if port:
    print(f"PORT:{port}")

# Custom prompt or default
linear_cli_path = os.path.join(os.path.dirname(shim_path), "linear-cli.py")

custom_prompt = prompt_cfg.get("template", "")
if not custom_prompt:
    custom_prompt = r"""You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets).
3. Final message must report completed actions and blockers only.
4. Work only in the provided repository copy. Do not touch any other path.

## Linear CLI — interact with Linear issues

You have a CLI tool to read/write Linear issues. Use it via bash:

```
# Get full issue details
python3 """ + linear_cli_path + r""" get-issue {{ issue.identifier }}

# Post a progress comment
python3 """ + linear_cli_path + r""" comment <issue-uuid> "Your comment here"

# Edit an existing comment (use for workpad updates)
python3 """ + linear_cli_path + r""" edit-comment <comment-uuid> "Updated body"

# Get all comments on the issue
python3 """ + linear_cli_path + r""" get-comments {{ issue.identifier }}

# Move issue to a new state
python3 """ + linear_cli_path + r""" set-state {{ issue.identifier }} "Done"
python3 """ + linear_cli_path + r""" set-state {{ issue.identifier }} "In Progress"

# Attach a URL (e.g. PR link) to the issue
python3 """ + linear_cli_path + r""" attach-url {{ issue.identifier }} <url> [title]
```

The LINEAR_API_KEY is already in your environment.

## Workflow

1. **Start**: Fetch the issue to get its UUID. Move it to "In Progress" if it's in "Todo".
2. **Workpad**: Create a single comment titled `## Workpad` on the issue to track progress. Use `comment` to create it, then `edit-comment` to update it as you work.
3. **Implement**: Read the requirements, plan your approach, write code, commit with clear messages.
4. **Validate**: Run tests/build to confirm your changes work. Record results in the workpad.
5. **Update**: Keep the workpad comment current — check off completed items, add notes.
6. **Finish**: When all acceptance criteria are met, post a final summary in the workpad and move the issue to "Done".

## Default posture

- Start by understanding the ticket requirements fully before writing any code.
- Plan your approach, then implement.
- Write clean commits with descriptive messages.
- Run relevant tests before considering work complete.
- Always update the workpad comment with progress and results.
- Move the issue to "Done" when complete.
"""

# Build active/terminal state YAML lines
def yaml_list(items):
    return "\n".join(f"    - {s}" for s in items)

after_create = repo.get("after_create", 'git clone --depth 1 "$SOURCE_REPO_URL" .')
before_run   = repo.get("before_run", "")
after_run    = repo.get("after_run", "")

hooks_section = f"  after_create: |\n    {after_create}\n"
if before_run:
    hooks_section += f"  before_run: |\n    {before_run}\n"
if after_run:
    hooks_section += f"  after_run: |\n    {after_run}\n"

workflow = f"""---
tracker:
  kind: linear
  project_slug: "{slug}"
  active_states:
{yaml_list(active_states)}
  terminal_states:
{yaml_list(terminal_states)}
polling:
  interval_ms: {poll_ms}
workspace:
  root: {ws_root}
hooks:
{hooks_section}agent:
  max_concurrent_agents: {max_agents}
  max_turns: {max_turns}
codex:
  command: "python3 {shim_path}"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

{custom_prompt}
"""

with open(workflow_file, "w") as f:
    f.write(workflow)

print("OK")
PYEOF
}

# ── Main ─────────────────────────────────────────────────────────────
banner

# Handle --init
if [[ "${1:-}" == "--init" ]]; then
    do_init "${2:-symphony.toml}"
fi

# Handle --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $(basename "$0") [config.toml]"
    echo ""
    echo "Commands:"
    echo "  --init [FILE]   Generate a new config file (default: symphony.toml)"
    echo "  --help          Show this help"
    echo ""
    echo "Config format (TOML):"
    echo ""
    cat "$SCRIPT_DIR/example.toml" | sed 's/^/  /'
    echo ""
    exit 0
fi

# Resolve config file
CONFIG_FILE="${1:-symphony.toml}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    # Try relative to script dir
    if [[ -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
        CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
    else
        die "Config file not found: $CONFIG_FILE
  Create one with: ./run-symphony.sh --init"
    fi
fi
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

dim "  Config: $CONFIG_FILE"; echo ""

# ── Preflight checks ─────────────────────────────────────────────────
if ! find_elixir; then
    die "Elixir/OTP not found. Install via: https://elixir-lang.org/install.html"
fi

if ! command -v claude &>/dev/null; then
    die "'claude' CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
fi

if ! command -v python3 &>/dev/null; then
    die "python3 not found"
fi

if [[ ! -x "$SYMPHONY_BIN" ]]; then
    echo "  Building Symphony..."
    if (cd "$SCRIPT_DIR/elixir" && mix local.hex --force --if-missing >/dev/null 2>&1 && mix setup >/dev/null 2>&1 && mix build >/dev/null 2>&1); then
        green "  Built successfully."; echo ""
    else
        die "Failed to build. Run manually: cd $SCRIPT_DIR/elixir && mix setup && mix build"
    fi
fi

# ── Parse config and generate workflow ────────────────────────────────
WORKFLOW_FILE=$(mktemp /tmp/symphony-workflow-XXXXXX.md)
trap 'rm -f "$WORKFLOW_FILE"' EXIT

OUTPUT=$(generate_workflow "$CONFIG_FILE" "$WORKFLOW_FILE" 2>&1)

# Check for missing fields
if echo "$OUTPUT" | grep -q "^MISSING:"; then
    missing=$(echo "$OUTPUT" | grep "^MISSING:" | sed 's/^MISSING://' | tr '|' '\n')
    red "  Missing required config:"; echo ""
    while IFS= read -r field; do
        echo "    - $field"
    done <<< "$missing"
    echo ""
    die "Fill these in: $CONFIG_FILE"
fi

# Extract exports
while IFS= read -r line; do
    if [[ "$line" == EXPORT:* ]]; then
        export "${line#EXPORT:}"
    fi
done <<< "$OUTPUT"

# Extract port
PORT_FLAG=""
while IFS= read -r line; do
    if [[ "$line" == PORT:* ]]; then
        PORT_FLAG="${line#PORT:}"
    fi
done <<< "$OUTPUT"

# ── Validate Linear connection ───────────────────────────────────────
dim "  Validating Linear..."; echo ""
LINEAR_USER=$(python3 -c "
import json, urllib.request, sys, os
req = urllib.request.Request('https://api.linear.app/graphql',
    data=json.dumps({'query': '{ viewer { name } }'}).encode(),
    headers={'Content-Type': 'application/json', 'Authorization': os.environ['LINEAR_API_KEY']})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.loads(r.read())
        if 'errors' in d: sys.exit(1)
        print(d['data']['viewer']['name'])
except: sys.exit(1)
" 2>/dev/null) || die "Linear API key is invalid"

green "  Connected as: $LINEAR_USER"; echo ""

# ── Read values back for display ─────────────────────────────────────
DISPLAY_VALS=$(python3 -c "
import tomllib, os
with open('$CONFIG_FILE', 'rb') as f: c = tomllib.load(f)
print(c.get('linear',{}).get('project_slug',''))
print(c.get('repo',{}).get('url','') or os.environ.get('SOURCE_REPO_URL',''))
print(c.get('agent',{}).get('max_concurrent',5))
print(c.get('agent',{}).get('max_turns',20))
print(c.get('agent',{}).get('poll_interval_ms',10000))
print(c.get('workspace',{}).get('root','~/symphony-workspaces'))
")
IFS=$'\n' read -rd '' SLUG REPO AGENTS TURNS POLL WSROOT <<< "$DISPLAY_VALS" || true

# ── Create workspace root ────────────────────────────────────────────
WSROOT_EXPANDED="${WSROOT/#\~/$HOME}"
mkdir -p "$WSROOT_EXPANDED"

# ── Launch ────────────────────────────────────────────────────────────
echo ""
bold "  Launching Symphony"; echo ""
echo "  ├─ Project:   $(cyan "$SLUG")"
echo "  ├─ Repo:      $(cyan "$REPO")"
echo "  ├─ Agents:    $(cyan "$AGENTS") max concurrent"
echo "  ├─ Turns:     $(cyan "$TURNS") per agent"
echo "  ├─ Polling:   $(cyan "${POLL}ms")"
echo "  ├─ Workspace: $(cyan "$WSROOT")"
echo "  └─ Engine:    $(green "Claude Code (Max subscription)")"
echo ""

CMD=("$SYMPHONY_BIN" "$WORKFLOW_FILE" --i-understand-that-this-will-be-running-without-the-usual-guardrails)

if [[ -n "$PORT_FLAG" ]]; then
    CMD+=(--port "$PORT_FLAG")
fi

shift 2>/dev/null || true  # consume the config file arg
CMD+=("$@")

exec "${CMD[@]}"
