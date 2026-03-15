# phonyhuman doctor — check all prerequisites
# Sourced by bin/phonyhuman; do not execute directly.

cmd_doctor() {
    banner
    local ok=true

    check() {
        local label="$1" hint="$2"
        shift 2
        printf "  %-20s" "$label"
        if "$@" &>/dev/null; then
            green "OK"; echo ""
        else
            red "MISSING"; echo ""
            dim "    → $hint"; echo ""
            ok=false
        fi
    }

    check_version() {
        local label="$1" hint="$2"
        shift 2
        printf "  %-20s" "$label"
        local ver
        ver=$("$@" 2>/dev/null || echo "")
        if [[ -n "$ver" ]]; then
            green "$ver"; echo ""
        else
            red "MISSING"; echo ""
            dim "    → $hint"; echo ""
            ok=false
        fi
    }

    _get_erlang_version() {
        erl -eval 'io:format("OTP ~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null \
            || { find_erlang && erl -eval 'io:format("OTP ~s", [erlang:system_info(otp_release)]), halt().' -noshell; }
    }

    _get_python_version() {
        python3 --version | head -1
    }

    _get_claude_version() {
        claude --version 2>/dev/null | head -1
    }

    echo "  $(bold "Checking prerequisites...")"
    echo ""

    check_version "Erlang/OTP" \
        "Install: mise install erlang@28" \
        _get_erlang_version

    check_version "Python" \
        "Install Python 3.11+: https://python.org" \
        _get_python_version

    check_version "Claude CLI" \
        "Install: https://docs.anthropic.com/en/docs/claude-code" \
        _get_claude_version

    check "Git" \
        "Install git: https://git-scm.com" \
        command -v git

    check "curl" \
        "Install curl" \
        command -v curl

    # gh is recommended (not required) for the PR workflow
    printf "  %-20s" "GitHub CLI (gh)"
    local gh_ver
    gh_ver=$(gh --version 2>/dev/null | head -1 || echo "")
    if [[ -n "$gh_ver" ]]; then
        green "$gh_ver"; echo ""
    else
        yellow "not found (optional)"; echo ""
        dim "    → Recommended for PR workflow: https://cli.github.com"; echo ""
    fi

    # Check escript
    printf "  %-20s" "Symphony escript"
    if [[ -f "$SYMPHONY_ESCRIPT" && -x "$SYMPHONY_ESCRIPT" ]]; then
        green "OK"; echo ""
    elif [[ -f "$SYMPHONY_ESCRIPT" ]]; then
        yellow "exists (not executable)"; echo ""
    else
        dim "not built"; echo ""
        dim "    → Will be built on first 'phonyhuman run'"; echo ""
    fi

    # Check shim
    printf "  %-20s" "claude-shim.py"
    if [[ -f "$SHIM_PATH" ]]; then
        green "OK"; echo ""
    else
        red "MISSING"; echo ""
        ok=false
    fi

    # Check linear-cli
    printf "  %-20s" "linear-cli.py"
    if [[ -f "$LINEAR_CLI" ]]; then
        green "OK"; echo ""
    else
        red "MISSING"; echo ""
        ok=false
    fi

    echo ""
    if $ok; then
        green "  All checks passed!"; echo ""
    else
        yellow "  Some checks failed. Fix the issues above and re-run 'phonyhuman doctor'."; echo ""
    fi
    echo ""
}
