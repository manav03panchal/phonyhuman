# phonyhuman run + completions — main orchestrator and shell completions
# Sourced by bin/phonyhuman; do not execute directly.

cmd_run() {
    local config_arg="${1:-}"
    shift 2>/dev/null || true

    banner

    # ── Resolve config file ──────────────────────────────────────────
    local config_file
    if [[ -z "$config_arg" ]]; then
        # Try common defaults
        if [[ -f "symphony.toml" ]]; then
            config_file="symphony.toml"
        elif [[ -f "phonyhuman.toml" ]]; then
            config_file="phonyhuman.toml"
        else
            die "No config file specified and no symphony.toml or phonyhuman.toml found.
  Create one with: phonyhuman init my-project"
        fi
    elif [[ -f "$config_arg" ]]; then
        config_file="$config_arg"
    elif [[ -f "${config_arg}.toml" ]]; then
        config_file="${config_arg}.toml"
    else
        die "Config file not found: $config_arg
  Create one with: phonyhuman init ${config_arg%.toml}"
    fi

    config_file="$(cd "$(dirname "$config_file")" && pwd)/$(basename "$config_file")"
    dim "  Config: $config_file"; echo ""

    # ── Ensure runtime ───────────────────────────────────────────────
    ensure_runtime

    # ── Preflight checks ─────────────────────────────────────────────
    if ! command -v claude &>/dev/null; then
        die "'claude' CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
    fi

    if ! command -v python3 &>/dev/null; then
        die "python3 not found"
    fi

    if [[ ! -f "$SHIM_PATH" ]]; then
        die "claude-shim.py not found at $SHIM_PATH"
    fi

    # ── Build escript if needed ───────────────────────────────────────
    if [[ ! -f "$SYMPHONY_ESCRIPT" || ! -x "$SYMPHONY_ESCRIPT" ]]; then
        # Check if we're in a repo checkout with Elixir source
        local elixir_dir="$SCRIPT_PATH/../elixir"
        if [[ -d "$elixir_dir" ]]; then
            if ! find_elixir; then
                die "Elixir not found. Cannot build escript.
  Install Elixir: mise install elixir@1.19
  Or install phonyhuman from a release: curl -sSL ... | sh"
            fi
            echo "  Building Symphony escript..."
            if (cd "$elixir_dir" && mix local.hex --force --if-missing >/dev/null 2>&1 && mix setup >/dev/null 2>&1 && mix build >/dev/null 2>&1); then
                # Copy built escript to expected location
                if [[ -f "$elixir_dir/bin/symphony" && "$SYMPHONY_ESCRIPT" != "$elixir_dir/bin/symphony" ]]; then
                    cp "$elixir_dir/bin/symphony" "$SYMPHONY_ESCRIPT"
                fi
                green "  Built successfully."; echo ""
            else
                die "Failed to build escript. Run manually:
  cd $elixir_dir && mix setup && mix build"
            fi
        else
            die "Symphony escript not found at $SYMPHONY_ESCRIPT
  Re-install phonyhuman: curl -sSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | sh"
        fi
    fi

    # ── Parse config and generate workflow ────────────────────────────
    local workflow_file
    local priv_tmp
    priv_tmp=$(private_tmpdir)
    workflow_file=$(mktemp "$priv_tmp/phonyhuman-workflow-XXXXXX.md")
    chmod 600 "$workflow_file"
    trap 'rm -f "${workflow_file:-}"' EXIT

    local output
    output=$(generate_workflow "$config_file" "$workflow_file" "$SHIM_PATH" 2>&1)

    # Check for missing fields
    if echo "$output" | grep -q "^MISSING:"; then
        local missing
        missing=$(echo "$output" | grep "^MISSING:" | sed 's/^MISSING://' | tr '|' '\n')
        red "  Missing required config:"; echo ""
        while IFS= read -r field; do
            echo "    - $field"
        done <<< "$missing"
        echo ""
        die "Fill these in: $config_file"
    fi

    # Check for TOML parse errors
    if echo "$output" | grep -q "^ERROR:"; then
        local errmsg
        errmsg=$(echo "$output" | grep "^ERROR:" | sed 's/^ERROR://')
        die "$errmsg"
    fi

    # Extract exports (whitelist: only LINEAR_API_KEY and SOURCE_REPO_URL)
    while IFS= read -r line; do
        if [[ "$line" == EXPORT:* ]]; then
            local kv="${line#EXPORT:}"
            local var_name="${kv%%=*}"
            if [[ "$var_name" == "LINEAR_API_KEY" || "$var_name" == "SOURCE_REPO_URL" ]]; then
                export "$kv"
            else
                yellow "  WARNING: Ignoring unexpected export variable: $var_name"; echo "" >&2
            fi
        fi
    done <<< "$output"

    # Extract port
    local port_flag=""
    while IFS= read -r line; do
        if [[ "$line" == PORT:* ]]; then
            port_flag="${line#PORT:}"
        fi
    done <<< "$output"

    # ── Validate Linear connection ────────────────────────────────────
    dim "  Validating Linear..."; echo ""
    local linear_user
    linear_user=$(python3 -c "
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

    green "  Connected as: $linear_user"; echo ""

    # ── Read display values ───────────────────────────────────────────
    local display_vals
    display_vals=$(python3 - "$config_file" <<'PYEOF'
import tomllib, os, sys
with open(sys.argv[1], 'rb') as f: c = tomllib.load(f)
print(c.get('linear',{}).get('project_slug',''))
print(c.get('repo',{}).get('url','') or os.environ.get('SOURCE_REPO_URL',''))
print(c.get('agent',{}).get('max_concurrent',5))
print(c.get('agent',{}).get('max_turns',20))
print(c.get('agent',{}).get('poll_interval_ms',10000))
print(c.get('workspace',{}).get('root','~/symphony-workspaces'))
PYEOF
)
    local slug repo agents turns poll wsroot
    IFS=$'\n' read -rd '' slug repo agents turns poll wsroot <<< "$display_vals" || true

    # ── Create workspace root ─────────────────────────────────────────
    local wsroot_expanded="${wsroot/#\~/$HOME}"
    mkdir -p "$wsroot_expanded"

    # ── Launch ────────────────────────────────────────────────────────
    echo ""
    bold "  Launching"; echo ""
    echo "  ├─ Project:   $(cyan "$slug")"
    echo "  ├─ Repo:      $(cyan "$repo")"
    echo "  ├─ Agents:    $(cyan "$agents") max concurrent"
    echo "  ├─ Turns:     $(cyan "$turns") per agent"
    echo "  ├─ Polling:   $(cyan "${poll}ms")"
    echo "  ├─ Workspace: $(cyan "$wsroot")"
    echo "  └─ Engine:    $(green "Claude Code")"
    echo ""

    local cmd=("$SYMPHONY_ESCRIPT" "$workflow_file" --i-understand-that-this-will-be-running-without-the-usual-guardrails)

    if [[ -n "$port_flag" ]]; then
        cmd+=(--port "$port_flag")
    fi

    cmd+=("$@")

    # ── Detect TUI binary ──────────────────────────────────────────────
    local tui_bin=""
    if [[ -x "$BIN_DIR/symphony-tui" ]]; then
        tui_bin="$BIN_DIR/symphony-tui"
    elif command -v symphony-tui &>/dev/null; then
        tui_bin="$(command -v symphony-tui)"
    elif [[ -x "$SCRIPT_PATH/../tui/symphony-tui" ]]; then
        # Dev: repo checkout
        tui_bin="$SCRIPT_PATH/../tui/symphony-tui"
    fi

    # If no TUI or no port, run orchestrator in foreground as before
    if [[ -z "$tui_bin" || -z "$port_flag" ]]; then
        [[ -z "$tui_bin" ]] && dim "  Tip: build the TUI for a better experience: cd tui && go build -o symphony-tui ." && echo ""
        exec escript "${cmd[@]}"
    fi

    # ── Launch orchestrator in background, TUI in foreground ───────────
    _ORCH_PID=""
    _WORKFLOW_FILE="$workflow_file"
    _PID_FILE="${wsroot_expanded}/.orchestrator.pid"
    cleanup() {
        if [[ -n "${_ORCH_PID:-}" ]] && kill -0 "$_ORCH_PID" 2>/dev/null; then
            kill -TERM "$_ORCH_PID" 2>/dev/null
            wait "$_ORCH_PID" 2>/dev/null || true
        fi
        rm -f "${_WORKFLOW_FILE:-}" "${_PID_FILE:-}"
    }
    trap cleanup EXIT INT TERM

    # Free the port if held by a prior symphony process (verified by process name)
    if ! kill_and_verify_port_free "${port_flag}"; then
        die "Port ${port_flag} is in use by a non-symphony process and cannot be freed."
    fi

    # Verify escript is on PATH before backgrounding
    if ! command -v escript &>/dev/null; then
        find_erlang || die "Erlang/OTP not found. Cannot start orchestrator."
    fi

    local orch_log="${wsroot_expanded}/orchestrator.log"
    local escript_bin
    escript_bin="$(command -v escript)"
    "$escript_bin" "${cmd[@]}" </dev/null >"$orch_log" 2>&1 &
    _ORCH_PID=$!
    echo "$_ORCH_PID" > "$_PID_FILE"

    # Wait for health check
    local api_url="http://localhost:${port_flag}"
    local max_wait=30
    local waited=0
    dim "  Waiting for orchestrator..."; echo ""
    while (( waited < max_wait )); do
        if curl -sf "${api_url}/health" >/dev/null 2>&1; then
            break
        fi
        # Check orchestrator didn't crash
        if ! kill -0 "$_ORCH_PID" 2>/dev/null; then
            red "  Orchestrator exited unexpectedly."; echo ""
            wait "$_ORCH_PID" 2>/dev/null
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if (( waited >= max_wait )); then
        red "  Orchestrator health check timed out after ${max_wait}s"; echo ""
        cleanup
        exit 1
    fi

    green "  Orchestrator ready — launching TUI"; echo ""
    dim "  Orchestrator log: $orch_log"; echo ""
    echo ""

    # TUI in foreground — when it exits, we clean up the orchestrator
    "$tui_bin" --url "$api_url"
}

# phonyhuman completions <shell>
cmd_completions() {
    local shell="${1:-}"

    # Auto-detect shell if not specified
    if [[ -z "$shell" ]]; then
        case "$(basename "${SHELL:-}")" in
            zsh)  shell="zsh" ;;
            bash) shell="bash" ;;
            fish) shell="fish" ;;
            *)    shell="bash" ;;
        esac
    fi

    case "$shell" in
        bash)
            cat <<'BASH_COMP'
_phonyhuman() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="init run doctor version update completions help"

    case "$prev" in
        phonyhuman)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return 0
            ;;
        run)
            COMPREPLY=($(compgen -f -X '!*.toml' -- "$cur"))
            return 0
            ;;
        completions)
            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
            return 0
            ;;
    esac
}
complete -F _phonyhuman phonyhuman
BASH_COMP
            ;;
        zsh)
            cat <<'ZSH_COMP'
#compdef phonyhuman

_phonyhuman() {
    local -a commands
    commands=(
        'init:Generate a config file from template'
        'run:Run the orchestrator'
        'doctor:Check all prerequisites'
        'version:Show version'
        'update:Self-update from GitHub releases'
        'completions:Output shell completions'
        'help:Show usage info'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args'

    case "$state" in
        command)
            _describe 'command' commands
            ;;
        args)
            case "${words[1]}" in
                run)
                    _files -g '*.toml'
                    ;;
                completions)
                    _values 'shell' bash zsh fish
                    ;;
                init)
                    _message 'project name'
                    ;;
            esac
            ;;
    esac
}

_phonyhuman "$@"
ZSH_COMP
            ;;
        fish)
            cat <<'FISH_COMP'
complete -c phonyhuman -f
complete -c phonyhuman -n '__fish_use_subcommand' -a 'init' -d 'Generate a config file from template'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'run' -d 'Run the orchestrator'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'doctor' -d 'Check all prerequisites'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'version' -d 'Show version'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'update' -d 'Self-update from GitHub releases'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'completions' -d 'Output shell completions'
complete -c phonyhuman -n '__fish_use_subcommand' -a 'help' -d 'Show usage info'
complete -c phonyhuman -n '__fish_seen_subcommand_from run' -F -r -a '*.toml'
complete -c phonyhuman -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'
FISH_COMP
            ;;
        *)
            echo "Unknown shell: $shell (supported: bash, zsh, fish)" >&2
            exit 1
            ;;
    esac
}
