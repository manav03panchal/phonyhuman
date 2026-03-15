# phonyhuman init — generate config + package skills
# Sourced by bin/phonyhuman; do not execute directly.

cmd_init() {
    local name="${1:-}"
    local target

    if [[ -z "$name" ]]; then
        target="symphony.toml"
    else
        # Strip .toml if provided, then add it back
        name="${name%.toml}"
        target="${name}.toml"
    fi

    if [[ -f "$target" ]]; then
        die "$target already exists"
    fi

    # Find template
    local template=""
    if [[ -f "$TEMPLATE_DIR/example.toml" ]]; then
        template="$TEMPLATE_DIR/example.toml"
    elif [[ -f "$PHONYHUMAN_HOME/templates/example.toml" ]]; then
        template="$PHONYHUMAN_HOME/templates/example.toml"
    fi

    if [[ -z "$template" ]]; then
        # Generate inline if template not found
        cat > "$target" <<'TOML'
# ─────────────────────────────────────────────────────────────────────
# phonyhuman — Project Configuration
# ─────────────────────────────────────────────────────────────────────
# Edit this file with your Linear + repo details, then run:
#   phonyhuman run this-file.toml

[linear]
api_key = ""                  # Linear personal API token (lin_api_...)
                              # Can also use LINEAR_API_KEY env var instead
project_slug = ""             # From the project URL: linear.app/team/project/<SLUG>

# Optional: customize which Linear states phonyhuman watches
active_states = ["Todo", "In Progress", "Merging", "Rework"]
# terminal_states = ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

[repo]
url = ""                      # Git clone URL — SSH or HTTPS
                              # Can also use SOURCE_REPO_URL env var

# Workspace mode: set local_repo to use fast git worktrees (default).
# Each issue gets its own branch (symphony/<issue-id>) sharing git objects.
# Omit local_repo to fall back to full git clone per issue.
local_repo = ""                   # Path to your existing repo checkout

# Optional: custom workspace hooks (shell commands)
# after_create = "git clone --depth 1 \"$SOURCE_REPO_URL\" . && npm install"
# before_run = "git pull origin main"
# after_run = "npm run lint"

[agent]
max_concurrent = 5            # How many issues to work on in parallel
max_turns = 20                # Max Claude turns per issue before pausing
poll_interval_ms = 10000      # How often to check Linear for new issues (ms)

[workspace]
root = "~/symphony-workspaces" # Where issue workspaces are created

# Optional: enable the live web dashboard
# [server]
# port = 4000

# Optional: customize the prompt template sent to Claude
# Uses Liquid syntax: {{ issue.identifier }}, {{ issue.title }}, etc.
# [prompt]
# template = """
# Your custom prompt here...
# """
TOML
    else
        cp "$template" "$target"
    fi

    # ── Copy skills into .codex/skills/ ──────────────────────────────
    local skills_dest=".codex/skills"
    if [[ -d "$SKILLS_DIR" ]]; then
        mkdir -p "$skills_dest"
        local copied_skills=()
        for skill_dir in "$SKILLS_DIR"/*/; do
            [[ -d "$skill_dir" ]] || continue
            local skill_name
            skill_name=$(basename "$skill_dir")
            if [[ -d "$skills_dest/$skill_name" ]]; then
                continue  # Don't overwrite existing customized skills
            fi
            cp -r "$skill_dir" "$skills_dest/$skill_name"
            copied_skills+=("$skill_name")
        done
    fi

    # ── Add config to .gitignore ────────────────────────────────────
    local gitignore_updated=false
    if [[ -f ".gitignore" ]]; then
        if ! grep -qF "$target" ".gitignore" 2>/dev/null; then
            echo "" >> ".gitignore"
            echo "# phonyhuman config (contains API key)" >> ".gitignore"
            echo "$target" >> ".gitignore"
            gitignore_updated=true
        fi
    else
        cat > ".gitignore" <<GITIGNORE
# phonyhuman config (contains API key)
$target
GITIGNORE
        gitignore_updated=true
    fi

    banner
    green "  Created $target"; echo ""

    if $gitignore_updated; then
        green "  Added $target to .gitignore"; echo ""
    fi

    if [[ ${#copied_skills[@]} -gt 0 ]]; then
        green "  Packaged skills into $skills_dest/"; echo ""
        for s in "${copied_skills[@]}"; do
            dim "    $s"; echo ""
        done
        echo ""
    fi

    dim "  Edit it with your Linear + repo details, then run:"; echo ""
    echo "    phonyhuman run $target"
    echo ""
}
