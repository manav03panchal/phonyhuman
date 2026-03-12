#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# phonyhuman installer
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/manav03panchal/phonyhuman/main/install.sh | sh
#
# Environment:
#   PHONYHUMAN_VERSION   Pin to a specific version (e.g. "0.1.0")
#   GITHUB_TOKEN         Auth token for private repo access
#   PHONYHUMAN_HOME      Install directory (default: ~/.phonyhuman)
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

GITHUB_REPO="manav03panchal/phonyhuman"
INSTALL_DIR="${PHONYHUMAN_HOME:-$HOME/.phonyhuman}"

# ── Color helpers ────────────────────────────────────────────────────
if [ -t 1 ]; then
    bold()  { printf "\033[1m%s\033[0m" "$*"; }
    green() { printf "\033[32m%s\033[0m" "$*"; }
    red()   { printf "\033[31m%s\033[0m" "$*"; }
    cyan()  { printf "\033[36m%s\033[0m" "$*"; }
    dim()   { printf "\033[90m%s\033[0m" "$*"; }
    yellow(){ printf "\033[33m%s\033[0m" "$*"; }
else
    bold()  { printf "%s" "$*"; }
    green() { printf "%s" "$*"; }
    red()   { printf "%s" "$*"; }
    cyan()  { printf "%s" "$*"; }
    dim()   { printf "%s" "$*"; }
    yellow(){ printf "%s" "$*"; }
fi

die() { echo ""; red "  ERROR: $1"; echo ""; exit 1; }

# ── Banner ───────────────────────────────────────────────────────────
echo ""
echo "  🤪 $(bold "phonyhuman installer")"
dim "  Autonomous issue orchestration powered by Claude Code"; echo ""
echo ""

# ── Detect OS/arch ───────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
    linux)  OS="linux" ;;
    darwin) OS="darwin" ;;
    *)      die "Unsupported OS: $OS" ;;
esac

case "$ARCH" in
    x86_64|amd64)   ARCH="x86_64" ;;
    aarch64|arm64)   ARCH="arm64" ;;
    *)               ARCH="$ARCH" ;;
esac

dim "  Platform: ${OS}/${ARCH}"; echo ""

# ── Check prerequisites ─────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
    die "curl is required but not found"
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required but not found. Install Python 3.11+: https://python.org"
fi

if ! command -v tar >/dev/null 2>&1; then
    die "tar is required but not found"
fi

# ── Fetch release info ───────────────────────────────────────────────
AUTH_HEADER=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
fi

if [ -n "${PHONYHUMAN_VERSION:-}" ]; then
    VERSION="$PHONYHUMAN_VERSION"
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/tags/v${VERSION}"
    echo "  Pinned version: v${VERSION}"
else
    echo "  Fetching latest release..."
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
fi

if [ -n "$AUTH_HEADER" ]; then
    RELEASE_JSON=$(curl -sSL -H "$AUTH_HEADER" "$RELEASE_URL" 2>/dev/null) || die "Failed to fetch release info"
else
    RELEASE_JSON=$(curl -sSL "$RELEASE_URL" 2>/dev/null) || die "Failed to fetch release info"
fi

VERSION=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null) || die "Failed to parse release"

if [ -z "$VERSION" ]; then
    die "Could not determine version. Check that releases exist at:
  https://github.com/$GITHUB_REPO/releases"
fi

echo "  Version: $(green "v${VERSION}")"

# ── Find tarball URL ─────────────────────────────────────────────────
# Platform-specific tarball (TUI binary is native)
PLATFORM="${OS}-${ARCH}"
dim "  Looking for tarball: ${PLATFORM}"; echo ""

TARBALL_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
platform = '${PLATFORM}'
# Try platform-specific first, then fall back to generic
fallback = None
for asset in data.get('assets', []):
    name = asset['name']
    if name.endswith('.tar.gz') and platform in name:
        print(asset['browser_download_url'])
        sys.exit(0)
    elif name.endswith('.tar.gz') and '-' not in name.replace('phonyhuman-','').replace('.tar.gz','').replace('.',''):
        fallback = asset['browser_download_url']
if fallback:
    print(fallback)
" 2>/dev/null)

if [ -z "$TARBALL_URL" ]; then
    die "No tarball found in release v${VERSION}"
fi

# ── Download and extract ─────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "  Downloading..."

if [ -n "$AUTH_HEADER" ]; then
    curl -sSL -H "$AUTH_HEADER" -H "Accept: application/octet-stream" -o "$TMPDIR/phonyhuman.tar.gz" "$TARBALL_URL" || die "Download failed"
else
    curl -sSL -o "$TMPDIR/phonyhuman.tar.gz" "$TARBALL_URL" || die "Download failed"
fi

# ── Verify checksum ─────────────────────────────────────────────────
TARBALL_NAME=$(basename "$TARBALL_URL")
CHECKSUMS_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for asset in data.get('assets', []):
    if asset['name'] == 'checksums.txt':
        print(asset['browser_download_url'])
        sys.exit(0)
" 2>/dev/null)

if [ -n "$CHECKSUMS_URL" ]; then
    echo "  Verifying checksum..."
    if [ -n "$AUTH_HEADER" ]; then
        curl -sSL -H "$AUTH_HEADER" -o "$TMPDIR/checksums.txt" "$CHECKSUMS_URL" || die "Failed to download checksums"
    else
        curl -sSL -o "$TMPDIR/checksums.txt" "$CHECKSUMS_URL" || die "Failed to download checksums"
    fi

    EXPECTED_SUM=$(grep "$TARBALL_NAME" "$TMPDIR/checksums.txt" | awk '{print $1}')
    if [ -z "$EXPECTED_SUM" ]; then
        die "Checksum for $TARBALL_NAME not found in checksums.txt"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SUM=$(sha256sum "$TMPDIR/phonyhuman.tar.gz" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL_SUM=$(shasum -a 256 "$TMPDIR/phonyhuman.tar.gz" | awk '{print $1}')
    else
        die "Neither sha256sum nor shasum found — cannot verify checksum"
    fi

    if [ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]; then
        die "Checksum verification failed!
  Expected: $EXPECTED_SUM
  Got:      $ACTUAL_SUM
  The downloaded file may be corrupted or tampered with."
    fi
    green "  Checksum verified"; echo ""
else
    yellow "  Warning: checksums.txt not found in release, skipping verification"; echo ""
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

echo "  Installing to $(cyan "$INSTALL_DIR")..."

# Extract tarball
tar xzf "$TMPDIR/phonyhuman.tar.gz" -C "$INSTALL_DIR"

# Ensure executables
chmod +x "$INSTALL_DIR/bin/phonyhuman"
chmod +x "$INSTALL_DIR/bin/symphony-escript" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/symphony-tui" 2>/dev/null || true

# ── Check for Erlang/OTP ─────────────────────────────────────────────
echo ""
echo "  Checking Erlang/OTP..."

HAS_ERLANG=false
if command -v erl >/dev/null 2>&1; then
    OTP_VER=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "")
    if [ -n "$OTP_VER" ]; then
        green "  Erlang/OTP $OTP_VER found"; echo ""
        HAS_ERLANG=true
    fi
fi

if [ "$HAS_ERLANG" = false ]; then
    # Check mise
    if command -v mise >/dev/null 2>&1; then
        MISE_ERL=$(mise where erlang 2>/dev/null || echo "")
        if [ -n "$MISE_ERL" ] && [ -x "$MISE_ERL/bin/erl" ]; then
            green "  Erlang found via mise"; echo ""
            HAS_ERLANG=true
        fi
    fi
fi

if [ "$HAS_ERLANG" = false ]; then
    echo ""
    yellow "  Erlang/OTP 28 is required but not installed."; echo ""
    echo ""

    # Try to install via mise
    if command -v mise >/dev/null 2>&1; then
        echo "  mise is available. Install Erlang with:"
        echo ""
        echo "    $(cyan "mise install erlang@28")"
        echo ""
        yellow "  Note: This builds from source and takes ~10-15 minutes."; echo ""
    else
        echo "  Install mise (version manager) first, then install Erlang:"
        echo ""
        echo "    $(cyan "curl -sSL https://mise.jdx.dev/install.sh | sh")"
        echo "    $(cyan "mise install erlang@28")"
        echo ""
        yellow "  Note: Erlang builds from source and takes ~10-15 minutes."; echo ""
        echo ""
        echo "  Alternatively, install Erlang directly:"
        echo "    https://www.erlang.org/downloads"
    fi
    echo ""
fi

# ── Add to PATH ──────────────────────────────────────────────────────
BIN_DIR="$INSTALL_DIR/bin"
PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""
ALREADY_IN_PATH=false

# Check if already on PATH
case ":$PATH:" in
    *":$BIN_DIR:"*) ALREADY_IN_PATH=true ;;
esac

if [ "$ALREADY_IN_PATH" = false ]; then
    echo "  Adding $(cyan "$BIN_DIR") to PATH..."

    SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"
    ADDED=false

    add_to_rc() {
        local rc="$1"
        if [ -f "$rc" ]; then
            if ! grep -qF "$BIN_DIR" "$rc" 2>/dev/null; then
                echo "" >> "$rc"
                echo "# phonyhuman" >> "$rc"
                echo "$PATH_LINE" >> "$rc"
                dim "  Updated $rc"; echo ""
                ADDED=true
            else
                dim "  Already in $rc"; echo ""
                ADDED=true
            fi
        fi
    }

    case "$SHELL_NAME" in
        zsh)
            add_to_rc "$HOME/.zshrc"
            ;;
        bash)
            add_to_rc "$HOME/.bashrc"
            if [ "$OS" = "darwin" ]; then
                add_to_rc "$HOME/.bash_profile"
            fi
            ;;
        fish)
            FISH_CONFIG="$HOME/.config/fish/config.fish"
            if [ -f "$FISH_CONFIG" ]; then
                if ! grep -qF "$BIN_DIR" "$FISH_CONFIG" 2>/dev/null; then
                    echo "" >> "$FISH_CONFIG"
                    echo "# phonyhuman" >> "$FISH_CONFIG"
                    echo "set -gx PATH $BIN_DIR \$PATH" >> "$FISH_CONFIG"
                    dim "  Updated $FISH_CONFIG"; echo ""
                    ADDED=true
                fi
            fi
            ;;
    esac

    # Fallback to .profile
    if [ "$ADDED" = false ]; then
        add_to_rc "$HOME/.profile"
    fi

    # Add to current session
    export PATH="$BIN_DIR:$PATH"
fi

# ── Shell completions ─────────────────────────────────────────────────
echo "  Setting up completions..."

SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"

case "$SHELL_NAME" in
    zsh)
        COMP_DIR="$HOME/.zsh/completions"
        mkdir -p "$COMP_DIR"
        "$BIN_DIR/phonyhuman" completions zsh > "$COMP_DIR/_phonyhuman"
        # Ensure completion dir is in fpath
        if [ -f "$HOME/.zshrc" ]; then
            if ! grep -qF "$COMP_DIR" "$HOME/.zshrc" 2>/dev/null; then
                echo "" >> "$HOME/.zshrc"
                echo "# phonyhuman completions" >> "$HOME/.zshrc"
                echo "fpath=($COMP_DIR \$fpath)" >> "$HOME/.zshrc"
                echo "autoload -Uz compinit && compinit" >> "$HOME/.zshrc"
            fi
        fi
        dim "  Installed zsh completions"; echo ""
        ;;
    bash)
        COMP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
        mkdir -p "$COMP_DIR"
        "$BIN_DIR/phonyhuman" completions bash > "$COMP_DIR/phonyhuman"
        dim "  Installed bash completions"; echo ""
        ;;
    fish)
        COMP_DIR="$HOME/.config/fish/completions"
        mkdir -p "$COMP_DIR"
        "$BIN_DIR/phonyhuman" completions fish > "$COMP_DIR/phonyhuman.fish"
        dim "  Installed fish completions"; echo ""
        ;;
    *)
        dim "  Skipped (unsupported shell: $SHELL_NAME)"; echo ""
        ;;
esac

# ── Run doctor ───────────────────────────────────────────────────────
echo ""
"$BIN_DIR/phonyhuman" doctor

# ── Success banner ───────────────────────────────────────────────────
echo ""
echo "  ─────────────────────────────────────────────"
echo ""
echo "  🤪 $(bold "phonyhuman v${VERSION}") installed!"
echo ""
echo "  Get started:"
echo ""
echo "    $(cyan "phonyhuman init my-project")"
echo "    $(dim "# edit my-project.toml with your Linear + repo details")"
echo "    $(cyan "phonyhuman run my-project.toml")"
echo ""

if [ "$ALREADY_IN_PATH" = false ]; then
    yellow "  Restart your shell or run:"; echo ""
    echo "    $(cyan "source ~/.${SHELL_NAME}rc")"
    echo ""
fi

echo "  ─────────────────────────────────────────────"
echo ""
