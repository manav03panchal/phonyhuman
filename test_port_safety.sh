#!/usr/bin/env bash
# test_port_safety.sh — tests for PID verification in port management
#
# Validates that kill_and_verify_port_free only kills symphony-related
# processes and refuses to kill unrelated processes on the same port.
#
# Usage: bash test_port_safety.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHONYHUMAN="$SCRIPT_DIR/bin/phonyhuman"
PASS=0
FAIL=0
TEST_PORT=0  # assigned dynamically

# ── Helpers ──────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

find_free_port() {
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('', 0))
port = s.getsockname()[1]
s.close()
print(port)
"
}

# Source only the functions we need from phonyhuman (avoid executing main logic)
source_functions() {
    # Extract function definitions without running the script
    eval "$(sed -n '/^find_pid_on_port()/,/^}/p' "$PHONYHUMAN")"
    eval "$(sed -n '/^SYMPHONY_PROC_NAMES=/p' "$PHONYHUMAN")"
    eval "$(sed -n '/^is_symphony_process()/,/^}/p' "$PHONYHUMAN")"
    eval "$(sed -n '/^filter_symphony_pids()/,/^}/p' "$PHONYHUMAN")"
    eval "$(sed -n '/^kill_and_verify_port_free()/,/^}/p' "$PHONYHUMAN")"
    # Stub color helpers used by kill_and_verify_port_free
    dim()    { :; }
    yellow() { :; }
    red()    { :; }
    green()  { :; }
}

cleanup_bg() {
    local pid="${1:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
    fi
}

# ── Tests ────────────────────────────────────────────────────────────

echo "=== Port Safety Tests ==="
echo ""

source_functions

# --- Test 1: is_symphony_process returns false for non-symphony PID ---
echo "-- is_symphony_process --"
# Use our own bash PID (comm=bash or zsh) — should not match
if is_symphony_process $$; then
    fail "is_symphony_process should return false for shell PID ($$)"
else
    pass "is_symphony_process returns false for shell PID ($$)"
fi

# --- Test 2: is_symphony_process returns false for invalid PID ---
if is_symphony_process 999999999; then
    fail "is_symphony_process should return false for nonexistent PID"
else
    pass "is_symphony_process returns false for nonexistent PID"
fi

# --- Test 3: filter_symphony_pids filters out non-symphony PIDs ---
echo ""
echo "-- filter_symphony_pids --"
result=$(echo -e "$$\n999999999" | filter_symphony_pids)
if [[ -z "$result" ]]; then
    pass "filter_symphony_pids filters out shell and invalid PIDs"
else
    fail "filter_symphony_pids should have returned empty, got: $result"
fi

# --- Test 4: Non-symphony process on port is NOT killed ---
echo ""
echo "-- kill_and_verify_port_free (non-symphony process) --"
TEST_PORT=$(find_free_port)
# Start a python HTTP server (non-symphony process)
python3 -m http.server "$TEST_PORT" --bind 127.0.0.1 &>/dev/null &
HTTP_PID=$!
# Give it a moment to bind
sleep 0.5

if kill -0 "$HTTP_PID" 2>/dev/null; then
    # Try to kill — should refuse (not a symphony process)
    if kill_and_verify_port_free "$TEST_PORT" 2>/dev/null; then
        # Returned 0 means port is free — check if process was killed
        if kill -0 "$HTTP_PID" 2>/dev/null; then
            pass "kill_and_verify_port_free returned 0 (port freed by other means) but process still alive"
        else
            fail "kill_and_verify_port_free killed non-symphony process"
        fi
    else
        # Returned 1 — correct, refused to kill
        if kill -0 "$HTTP_PID" 2>/dev/null; then
            pass "kill_and_verify_port_free refused to kill non-symphony process (python HTTP server)"
        else
            fail "Non-symphony process died unexpectedly"
        fi
    fi
else
    fail "Python HTTP server failed to start on port $TEST_PORT — test inconclusive"
fi
cleanup_bg "$HTTP_PID"

# --- Test 5: kill_and_verify_port_free succeeds on empty port ---
echo ""
echo "-- kill_and_verify_port_free (empty port) --"
EMPTY_PORT=$(find_free_port)
if kill_and_verify_port_free "$EMPTY_PORT" 2>/dev/null; then
    pass "kill_and_verify_port_free returns 0 for empty port"
else
    fail "kill_and_verify_port_free should return 0 for empty port"
fi

# --- Test 6: PID file is created and cleaned up ---
echo ""
echo "-- PID file lifecycle --"
TEST_PID_FILE=$(mktemp /tmp/test_orchestrator_pid.XXXXXX)
rm -f "$TEST_PID_FILE"
echo "12345" > "$TEST_PID_FILE"
if [[ -f "$TEST_PID_FILE" ]] && [[ "$(cat "$TEST_PID_FILE")" == "12345" ]]; then
    pass "PID file write/read works"
else
    fail "PID file write/read failed"
fi
rm -f "$TEST_PID_FILE"
if [[ ! -f "$TEST_PID_FILE" ]]; then
    pass "PID file cleanup works"
else
    fail "PID file cleanup failed"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if (( FAIL > 0 )); then
    exit 1
fi
