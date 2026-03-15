# phonyhuman update — self-update + workflow generation
# Sourced by bin/phonyhuman; do not execute directly.

cmd_update() {
    banner
    echo "  Checking for updates..."

    local api_url="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    local auth_header=""
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header="Authorization: token $GITHUB_TOKEN"
    fi

    local release_json_file
    release_json_file=$(mktemp "${TMPDIR:-/tmp}/phonyhuman-release-XXXXXXXXXX.json")
    trap "rm -f '$release_json_file'" RETURN
    if [[ -n "$auth_header" ]]; then
        curl -sSL -H "$auth_header" -o "$release_json_file" "$api_url" 2>/dev/null || die "Failed to check for updates"
    else
        curl -sSL -o "$release_json_file" "$api_url" 2>/dev/null || die "Failed to check for updates"
    fi

    local latest_version
    latest_version=$(python3 -c "import json; print(json.load(open('$release_json_file')).get('tag_name','').lstrip('v'))" 2>/dev/null) || die "Failed to parse release info"

    if [[ -z "$latest_version" ]]; then
        die "Could not determine latest version"
    fi

    if [[ "$latest_version" == "$VERSION" ]]; then
        green "  Already up to date ($VERSION)"; echo ""
        echo ""
        return 0
    fi

    echo "  Current: $VERSION"
    echo "  Latest:  $latest_version"
    echo ""

    # Find platform-specific tarball URL
    local os_name arch_name platform
    os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch_name="$(uname -m)"
    case "$arch_name" in
        aarch64|arm64) arch_name="arm64" ;;
        x86_64|amd64)  arch_name="x86_64" ;;
    esac
    platform="${os_name}-${arch_name}"

    local tarball_url
    tarball_url=$(python3 - "$platform" "$release_json_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[2]))
platform = sys.argv[1]
fallback = None
for asset in data.get('assets', []):
    name = asset['name']
    if name.endswith('.tar.gz') and platform in name:
        print(asset['browser_download_url'])
        sys.exit(0)
    elif name.endswith('.tar.gz') and fallback is None:
        fallback = asset['browser_download_url']
if fallback:
    print(fallback)
PYEOF
)

    if [[ -z "$tarball_url" ]]; then
        die "No tarball found in latest release"
    fi

    echo "  Downloading v${latest_version}..."

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}"' EXIT

    if [[ -n "$auth_header" ]]; then
        curl -sSL -H "$auth_header" -o "$tmpdir/phonyhuman.tar.gz" "$tarball_url" || die "Download failed"
    else
        curl -sSL -o "$tmpdir/phonyhuman.tar.gz" "$tarball_url" || die "Download failed"
    fi

    # ── Verify checksum ──────────────────────────────────────────────
    local tarball_name checksums_url expected_sum actual_sum
    tarball_name=$(basename "$tarball_url")
    checksums_url=$(python3 -c "
import sys, json
data = json.load(open('$release_json_file'))
for asset in data.get('assets', []):
    if asset['name'] == 'checksums.txt':
        print(asset['browser_download_url'])
        sys.exit(0)
" 2>/dev/null)

    if [[ -n "$checksums_url" ]]; then
        echo "  Verifying checksum..."
        if [[ -n "$auth_header" ]]; then
            curl -sSL -H "$auth_header" -o "$tmpdir/checksums.txt" "$checksums_url" || die "Failed to download checksums"
        else
            curl -sSL -o "$tmpdir/checksums.txt" "$checksums_url" || die "Failed to download checksums"
        fi

        expected_sum=$(grep "  ${tarball_name}$" "$tmpdir/checksums.txt" | head -1 | awk '{print $1}')
        if [[ -z "$expected_sum" ]]; then
            die "Checksum for $tarball_name not found in checksums.txt"
        fi

        if command -v sha256sum &>/dev/null; then
            actual_sum=$(sha256sum "$tmpdir/phonyhuman.tar.gz" | awk '{print $1}')
        elif command -v shasum &>/dev/null; then
            actual_sum=$(shasum -a 256 "$tmpdir/phonyhuman.tar.gz" | awk '{print $1}')
        else
            die "Neither sha256sum nor shasum found — cannot verify checksum"
        fi

        if [[ "$actual_sum" != "$expected_sum" ]]; then
            die "Checksum verification failed!
  Expected: $expected_sum
  Got:      $actual_sum
  The downloaded file may be corrupted or tampered with."
        fi
        green "  Checksum verified"; echo ""
    else
        yellow "  Warning: checksums.txt not found in release, skipping verification"; echo ""
    fi

    # ── Verify GPG signature ──────────────────────────────────────
    local sig_url key_url
    sig_url=$(python3 -c "
import sys, json
data = json.load(open('$release_json_file'))
for asset in data.get('assets', []):
    if asset['name'] == 'checksums.txt.asc':
        print(asset['browser_download_url'])
        sys.exit(0)
" 2>/dev/null)

    if [[ -n "$sig_url" ]]; then
        if command -v gpg &>/dev/null; then
            echo "  Verifying GPG signature..."

            if [[ -n "$auth_header" ]]; then
                curl -sSL -H "$auth_header" -o "$tmpdir/checksums.txt.asc" "$sig_url" || die "Failed to download GPG signature"
            else
                curl -sSL -o "$tmpdir/checksums.txt.asc" "$sig_url" || die "Failed to download GPG signature"
            fi

            key_url="https://raw.githubusercontent.com/$GITHUB_REPO/main/release-signing-key.asc"
            if [[ -n "$auth_header" ]]; then
                curl -sSL -H "$auth_header" -o "$tmpdir/release-key.asc" "$key_url" || die "Failed to download signing key"
            else
                curl -sSL -o "$tmpdir/release-key.asc" "$key_url" || die "Failed to download signing key"
            fi

            local saved_gnupghome="${GNUPGHOME:-}"
            export GNUPGHOME="$tmpdir/gnupg"
            mkdir -p "$GNUPGHOME"
            chmod 700 "$GNUPGHOME"

            gpg --batch --quiet --import "$tmpdir/release-key.asc" 2>/dev/null

            if gpg --batch --verify "$tmpdir/checksums.txt.asc" "$tmpdir/checksums.txt" 2>/dev/null; then
                green "  GPG signature verified"; echo ""
            else
                die "GPG signature verification failed! The release may have been tampered with."
            fi

            if [[ -n "$saved_gnupghome" ]]; then
                export GNUPGHOME="$saved_gnupghome"
            else
                unset GNUPGHOME
            fi
        else
            yellow "  Warning: gpg not found, skipping signature verification"; echo ""
        fi
    else
        yellow "  Warning: No GPG signature found in release, skipping signature verification"; echo ""
    fi

    # Extract to staging directory first, then validate paths before installing.
    # Prevents path-traversal attacks via crafted tarballs with ../../ entries.
    local staging_dir="$tmpdir/staging"
    mkdir -p "$staging_dir"
    tar xzf "$tmpdir/phonyhuman.tar.gz" -C "$staging_dir" --strip-components=0

    # Reject tarball if any extracted path escapes the staging directory
    local real_staging
    real_staging=$(cd "$staging_dir" && pwd -P)
    while IFS= read -r -d '' entry; do
        local real_entry
        real_entry=$(cd "$(dirname "$entry")" && pwd -P)/$(basename "$entry")
        case "$real_entry" in
            "$real_staging"/*)
                ;; # safe — inside staging
            *)
                die "Path traversal detected in tarball: $(basename "$entry") resolves outside staging directory. Aborting update."
                ;;
        esac
    done < <(find "$staging_dir" -mindepth 1 -print0)

    # Safe: copy validated contents to install directory
    cp -a "$staging_dir"/. "$PHONYHUMAN_HOME/"

    # Ensure executables
    chmod +x "$PHONYHUMAN_HOME/bin/phonyhuman"
    chmod +x "$PHONYHUMAN_HOME/bin/symphony-escript" 2>/dev/null || true
    chmod +x "$PHONYHUMAN_HOME/bin/symphony-tui" 2>/dev/null || true

    echo ""
    green "  Updated to v${latest_version}!"; echo ""
    echo ""
}

# ── TOML parsing + workflow generation (ported from run-symphony.sh) ──

generate_workflow() {
    local config_file="$1"
    local workflow_file="$2"
    local shim_path="$3"

    export PHONYHUMAN_SKILLS_DIR="$SKILLS_DIR"
    python3 - "$config_file" "$workflow_file" "$shim_path" <<'PYEOF'
import sys, os, tomllib, json

config_file, workflow_file, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(config_file, "rb") as f:
        cfg = tomllib.load(f)
except tomllib.TOMLDecodeError as e:
    print(f"ERROR:Failed to parse {config_file}: {e}")
    sys.exit(1)

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

active_states   = linear.get("active_states", ["Todo", "In Progress", "Merging", "Rework"])
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

# Resolve skills directory
# Prefer project-local skills (.codex/skills/) when local_repo is set,
# so agents in each workspace find skills relative to their working directory.
local_repo_path = repo.get("local_repo", "")
local_skills = ""
if local_repo_path:
    candidate = os.path.join(os.path.expanduser(local_repo_path), ".codex", "skills")
    if os.path.isdir(candidate):
        local_skills = ".codex/skills"  # relative — resolved per workspace

skills_dir = os.environ.get("PHONYHUMAN_SKILLS_DIR", "")
if not skills_dir:
    bin_dir = os.path.dirname(shim_path)
    parent_dir = os.path.dirname(bin_dir)
    if os.path.isdir(os.path.join(parent_dir, "skills")):
        skills_dir = os.path.join(parent_dir, "skills")

# Project-local skills take priority (relative path works in each worktree/clone)
if local_skills:
    skills_dir = local_skills

custom_prompt = prompt_cfg.get("template", "")
if not custom_prompt:
    # Try loading from template file
    template_candidates = [
        os.path.join(os.path.dirname(shim_path), "..", "templates", "default-prompt.md"),
        os.path.join(os.environ.get("PHONYHUMAN_HOME", os.path.expanduser("~/.phonyhuman")), "templates", "default-prompt.md"),
    ]
    for candidate in template_candidates:
        candidate = os.path.normpath(candidate)
        if os.path.isfile(candidate):
            with open(candidate) as tf:
                custom_prompt = tf.read()
            # Inject resolved paths into placeholders
            custom_prompt = custom_prompt.replace("{{skills_path}}", skills_dir)
            custom_prompt = custom_prompt.replace("{{linear_cli_path}}", linear_cli_path)
            break

    if not custom_prompt:
        # Inline fallback (minimal prompt for repo checkouts without templates)
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
2. Do not enter plan mode (EnterPlanMode) or ask the user questions (AskUserQuestion). There is no human to respond.
3. Only stop early for a true blocker (missing required auth/permissions/secrets).
4. Final message must report completed actions and blockers only.
5. Work only in the provided repository copy. Do not touch any other path.

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
def yaml_quote(value):
    """Quote a string for safe YAML embedding (handles :, #, {, etc.)."""
    special_chars = (':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|',
                     '-', '<', '>', '=', '!', '%', '@', '`', '"', "'")
    s = str(value)
    if any(c in s for c in special_chars) or s != s.strip() or not s:
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return s

def yaml_list(items):
    return "\n".join(f"    - {yaml_quote(s)}" for s in items)

def yaml_block_scalar(value, indent=4):
    """Format a multiline string as a YAML literal block scalar body.

    All lines are re-indented to the given level, preserving relative
    indentation.  This prevents YAML injection through unindented lines
    or document markers (e.g. ``---``).
    """
    prefix = " " * indent
    lines = str(value).splitlines()
    if not lines:
        return prefix
    # Determine minimum indentation of non-empty lines
    min_indent = None
    for line in lines:
        stripped = line.lstrip()
        if stripped:
            leading = len(line) - len(stripped)
            if min_indent is None or leading < min_indent:
                min_indent = leading
    if min_indent is None:
        min_indent = 0
    result = []
    for line in lines:
        stripped = line.lstrip()
        if stripped:
            relative = len(line) - len(stripped) - min_indent
            result.append(prefix + " " * relative + stripped)
        else:
            result.append("")
    return "\n".join(result)

before_run     = repo.get("before_run", "")
after_run      = repo.get("after_run", "")
local_repo     = repo.get("local_repo", "")

# Default to worktree mode if local_repo is set, clone mode otherwise
if local_repo:
    worktree_after_create = (
        f'export LOCAL_REPO={local_repo!r}\n'
        'BRANCH="symphony/$(basename "$PWD")"\n'
        'git -C "$LOCAL_REPO" fetch origin main\n'
        'git -C "$LOCAL_REPO" worktree add "$PWD" -b "$BRANCH" origin/main'
    )
    worktree_before_remove = (
        f'export LOCAL_REPO={local_repo!r}\n'
        'git -C "$LOCAL_REPO" worktree remove "$PWD" --force 2>/dev/null || true'
    )
    after_create  = repo.get("after_create", worktree_after_create)
    before_remove = repo.get("before_remove", worktree_before_remove)
else:
    after_create  = repo.get("after_create", 'git clone --depth 1 "$SOURCE_REPO_URL" .')
    before_remove = repo.get("before_remove", "")

hooks_section = f"  after_create: |\n{yaml_block_scalar(after_create)}\n"
if before_run:
    hooks_section += f"  before_run: |\n{yaml_block_scalar(before_run)}\n"
if after_run:
    hooks_section += f"  after_run: |\n{yaml_block_scalar(after_run)}\n"
if before_remove:
    hooks_section += f"  before_remove: |\n{yaml_block_scalar(before_remove)}\n"

workflow = f"""---
tracker:
  kind: linear
  project_slug: {yaml_quote(slug)}
  active_states:
{yaml_list(active_states)}
  terminal_states:
{yaml_list(terminal_states)}
polling:
  interval_ms: {poll_ms}
workspace:
  root: {yaml_quote(ws_root)}
hooks:
{hooks_section}agent:
  max_concurrent_agents: {max_agents}
  max_turns: {max_turns}
agent_server:
  command: {yaml_quote("python3 " + shim_path)}
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
