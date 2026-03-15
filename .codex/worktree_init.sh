#!/usr/bin/env bash
set -eo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
project_root="$repo_root/elixir"

if ! command -v mise >/dev/null 2>&1; then
  echo "mise is required. Install it from https://mise.jdx.dev/getting-started.html" >&2
  exit 1
fi

cd "$project_root"

# ---------------------------------------------------------------------------
# Validate mise.toml before trusting (HUM-139)
#
# mise.toml can contain arbitrary plugin URLs, env vars, tasks (shell code),
# and hook commands.  Trusting a tampered file could execute malicious code.
# We validate that the file contains only a [tools] section with known tool
# names and safe version strings before calling `mise trust`.
# ---------------------------------------------------------------------------

mise_config="$project_root/mise.toml"

# Allowed tool names — extend this list when the project adopts new tools.
ALLOWED_TOOLS="erlang elixir"

validate_mise_toml() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    echo "error: mise.toml not found at $config_file" >&2
    return 1
  fi

  # --- 1. Reject dangerous sections -------------------------------------------
  # Only [tools] is permitted.  Sections like [plugins], [env], [tasks],
  # [hooks], and [settings] can execute or influence arbitrary commands.
  local dangerous_sections
  dangerous_sections=$(grep -E '^\s*\[' "$config_file" | grep -Eiv '^\s*\[tools\]' || true)
  if [ -n "$dangerous_sections" ]; then
    echo "error: mise.toml contains disallowed sections:" >&2
    echo "$dangerous_sections" >&2
    return 1
  fi

  # --- 2. Validate tool names -------------------------------------------------
  local tool_lines
  tool_lines=$(grep -E '^\s*[a-zA-Z_][a-zA-Z0-9_-]*\s*=' "$config_file" || true)

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local tool_name
    tool_name=$(echo "$line" | sed 's/\s*=.*//' | xargs)
    local allowed=false
    for allowed_tool in $ALLOWED_TOOLS; do
      if [ "$tool_name" = "$allowed_tool" ]; then
        allowed=true
        break
      fi
    done
    if [ "$allowed" = false ]; then
      echo "error: mise.toml contains unknown tool '$tool_name' (allowed: $ALLOWED_TOOLS)" >&2
      return 1
    fi
  done <<< "$tool_lines"

  # --- 3. Validate version strings --------------------------------------------
  # Version values must be simple semver-ish strings (digits, dots, hyphens,
  # alphanumerics).  Reject URLs, backticks, $(), semicolons, pipes, etc.
  local version_values
  version_values=$(grep -E '^\s*[a-zA-Z_]' "$config_file" | sed 's/^[^=]*=\s*//' | tr -d '"' | tr -d "'" | xargs -I{} echo "{}" || true)

  while IFS= read -r ver; do
    [ -z "$ver" ] && continue
    if echo "$ver" | grep -Eq '[;|&`$(){}<>!\\]|https?://|ftp://'; then
      echo "error: mise.toml version string looks unsafe: '$ver'" >&2
      return 1
    fi
    if ! echo "$ver" | grep -Eq '^[a-zA-Z0-9._-]+$'; then
      echo "error: mise.toml version string contains unexpected characters: '$ver'" >&2
      return 1
    fi
  done <<< "$version_values"

  return 0
}

if ! validate_mise_toml "$mise_config"; then
  echo "error: mise.toml validation failed — refusing to trust. Review the file manually." >&2
  exit 1
fi

mise trust

make setup
