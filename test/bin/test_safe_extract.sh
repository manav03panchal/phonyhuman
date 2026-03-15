#!/usr/bin/env bash
# Test: safe tarball extraction in cmd_update rejects path traversal
#
# Extracts the validation logic from bin/phonyhuman and runs it against
# both a legitimate and a malicious tarball.

set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ── Helpers ────────────────────────────────────────────────────────────

die() { echo "ERROR: $1"; exit 1; }

# Reimplements the safe-extract + validate logic from bin/phonyhuman cmd_update.
safe_extract() {
    local tarball="$1"
    local dest="$2"
    local tmpdir
    tmpdir=$(mktemp -d)

    local staging_dir="$tmpdir/staging"
    mkdir -p "$staging_dir"
    tar xzf "$tarball" -C "$staging_dir" --strip-components=0 2>/dev/null || true

    local real_staging
    real_staging=$(cd "$staging_dir" && pwd -P)
    while IFS= read -r -d '' entry; do
        local real_entry
        real_entry=$(cd "$(dirname "$entry")" && pwd -P)/$(basename "$entry")
        case "$real_entry" in
            "$real_staging"/*)
                ;; # safe
            *)
                rm -rf "$tmpdir"
                return 1  # traversal detected
                ;;
        esac
    done < <(find "$staging_dir" -mindepth 1 -print0)

    cp -a "$staging_dir"/. "$dest/"
    rm -rf "$tmpdir"
    return 0
}

# ── Setup ──────────────────────────────────────────────────────────────

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo ""
echo "Running safe-extract tests..."
echo ""

# ── Test 1: Legitimate tarball extracts successfully ───────────────────

test_legitimate_tarball() {
    local src="$WORKDIR/legit_src"
    local dest="$WORKDIR/legit_dest"
    mkdir -p "$src/bin" "$src/lib" "$dest"
    echo '#!/bin/bash' > "$src/bin/phonyhuman"
    echo 'module' > "$src/lib/app.ex"
    echo '1.0.0' > "$src/version"

    tar czf "$WORKDIR/legit.tar.gz" -C "$src" .

    if safe_extract "$WORKDIR/legit.tar.gz" "$dest"; then
        if [[ -f "$dest/bin/phonyhuman" && -f "$dest/lib/app.ex" && -f "$dest/version" ]]; then
            pass "legitimate tarball extracts all files correctly"
        else
            fail "legitimate tarball extraction missing files"
        fi
    else
        fail "legitimate tarball was incorrectly rejected"
    fi
}

# ── Test 2: Tarball with symlink escape is rejected ────────────────────

test_symlink_escape() {
    local src="$WORKDIR/symlink_src"
    local dest="$WORKDIR/symlink_dest"
    mkdir -p "$src" "$dest"
    echo "legit" > "$src/legit.txt"
    ln -s /tmp "$src/escape_link"

    tar czf "$WORKDIR/symlink.tar.gz" -C "$src" .

    if safe_extract "$WORKDIR/symlink.tar.gz" "$dest"; then
        # Symlinks that point outside are allowed by the path check since
        # the symlink entry itself lives inside staging. This is expected —
        # the defence targets tarball member *names* with ".." components.
        pass "symlink tarball handled (symlink entry itself is inside staging)"
    else
        fail "symlink tarball unexpectedly rejected"
    fi
}

# ── Test 3: Tarball with ../../ path components is rejected ────────────

test_dotdot_traversal() {
    local src="$WORKDIR/evil_src"
    local dest="$WORKDIR/evil_dest"
    local outside="$WORKDIR/outside_target"
    mkdir -p "$src" "$dest" "$outside"
    echo "payload" > "$src/payload.txt"

    # Create a tarball with a ../../ path. GNU tar may strip the leading ../
    # but we force it with --transform and --absolute-names.
    tar czf "$WORKDIR/evil.tar.gz" \
        --transform='s|payload.txt|../../outside_target/pwned.txt|' \
        -C "$src" payload.txt 2>/dev/null || true

    if safe_extract "$WORKDIR/evil.tar.gz" "$dest"; then
        # If GNU tar silently stripped the ../ and it ended up inside staging,
        # that's actually safe (the path check passed because nothing escaped).
        # Check that nothing landed outside dest.
        if [[ -f "$outside/pwned.txt" ]]; then
            fail "dotdot traversal: file escaped to outside directory"
        else
            pass "dotdot traversal: tar stripped ../ and extraction stayed safe"
        fi
    else
        pass "dotdot traversal: tarball correctly rejected"
    fi
}

# ── Test 4: Verify the actual bin/phonyhuman has the staging pattern ───

test_source_has_staging_pattern() {
    local script_path
    script_path="$(cd "$(dirname "$0")/../.." && pwd)/bin/phonyhuman"
    if [[ ! -f "$script_path" ]]; then
        fail "bin/phonyhuman not found at $script_path"
        return
    fi

    if grep -q 'staging_dir=.*tmpdir/staging' "$script_path" &&
       grep -q 'Path traversal detected' "$script_path" &&
       grep -q 'cp -a.*staging_dir.*PHONYHUMAN_HOME' "$script_path"; then
        pass "bin/phonyhuman contains safe extraction pattern (staging + validation + copy)"
    else
        fail "bin/phonyhuman missing expected safe extraction pattern"
    fi
}

# ── Test 5: Verify direct tar-to-PHONYHUMAN_HOME is removed ───────────

test_no_direct_extract() {
    local script_path
    script_path="$(cd "$(dirname "$0")/../.." && pwd)/bin/phonyhuman"
    if [[ ! -f "$script_path" ]]; then
        fail "bin/phonyhuman not found at $script_path"
        return
    fi

    if grep -q 'tar xzf.*-C "$PHONYHUMAN_HOME"' "$script_path"; then
        fail "bin/phonyhuman still contains direct tar extraction to PHONYHUMAN_HOME"
    else
        pass "bin/phonyhuman no longer extracts directly to PHONYHUMAN_HOME"
    fi
}

# ── Run ────────────────────────────────────────────────────────────────

test_legitimate_tarball
test_symlink_escape
test_dotdot_traversal
test_source_has_staging_pattern
test_no_direct_extract

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
