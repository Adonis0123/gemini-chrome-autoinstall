#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
TEST_INSTALL_DIR=$(mktemp -d)
TEST_LOG_FILE="$TEST_INSTALL_DIR/test.log"
PORT=18923
PASS=0
FAIL=0

cleanup() {
    stop_server
    rm -rf "$TEST_INSTALL_DIR"
}
trap cleanup EXIT

# --- Helpers ---

kill_port() {
    local pids
    pids=$(lsof -ti :$PORT 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 0.3
    fi
}

start_server() { # $1 = fixture dir
    kill_port
    python3 -m http.server $PORT -d "$1" &>/dev/null &
    SERVER_PID=$!
    sleep 0.5
}

stop_server() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        unset SERVER_PID
    fi
    kill_port
}

reset_install_dir() {
    rm -rf "$TEST_INSTALL_DIR"
    mkdir -p "$TEST_INSTALL_DIR"
    cp "$PROJECT_ROOT/patch.sh" "$TEST_INSTALL_DIR/patch.sh"
    chmod +x "$TEST_INSTALL_DIR/patch.sh"
    echo "" > "$TEST_LOG_FILE"
}

assert_contains() { # $1=file, $2=pattern, $3=test name
    if grep -q "$2" "$1" 2>/dev/null; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (expected '$2' in $(basename "$1"))"
    fi
}

assert_not_contains() { # $1=file, $2=pattern, $3=test name
    if ! grep -q "$2" "$1" 2>/dev/null; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (did not expect '$2' in $(basename "$1"))"
    fi
}

assert_file_content() { # $1=file, $2=expected, $3=test name
    local actual
    actual=$(tr -d '\n' < "$1")
    if [ "$actual" = "$2" ]; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (expected '$2', got '$actual')"
    fi
}

assert_file_exists() { # $1=file, $2=test name
    if [ -f "$1" ]; then
        ((PASS++)); echo "  ✓ PASS: $2"
    else
        ((FAIL++)); echo "  ✗ FAIL: $2 (file not found: $1)"
    fi
}

assert_file_not_exists() { # $1=file, $2=test name
    if [ ! -f "$1" ]; then
        ((PASS++)); echo "  ✓ PASS: $2"
    else
        ((FAIL++)); echo "  ✗ FAIL: $2 (file should not exist: $1)"
    fi
}

run_patch() { # runs patch.sh run in isolated env
    GEMINI_INSTALL_DIR="$TEST_INSTALL_DIR" \
    GEMINI_RAW_BASE="http://localhost:$PORT" \
    GEMINI_LOG_FILE="$TEST_LOG_FILE" \
    GEMINI_LOCAL_STATE_PATH="/dev/null" \
        bash "$TEST_INSTALL_DIR/patch.sh" run 2>/dev/null || true
}

# === Tests ===

echo "=== Self-Update Tests (macOS) ==="
echo ""

# --- Test 1: Remote has newer version ---
echo "Test 1: Remote has newer version"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated to v99.0.0"
assert_contains "$TEST_LOG_FILE" "Self-updated from v0.0.1 to v99.0.0" "Log contains Self-updated message"
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created"
echo ""

# --- Test 2: Version identical ---
echo "Test 2: Version identical"
reset_install_dir
cp "$PROJECT_ROOT/VERSION" "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/same"
run_patch
stop_server
assert_not_contains "$TEST_LOG_FILE" "Self-updated" "No Self-updated log"
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created"
echo ""

# --- Test 3: Cooldown not expired ---
echo "Test 3: Cooldown not expired (should skip)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
echo "$(date +%s)" > "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged (cooldown active)"
assert_not_contains "$TEST_LOG_FILE" "Self-updated" "No Self-updated log"
echo ""

# --- Test 4: Cooldown expired ---
echo "Test 4: Cooldown expired (should check)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
echo "$(( $(date +%s) - 90000 ))" > "$TEST_INSTALL_DIR/last-update-check"  # 25 hours ago
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated after cooldown expired"
assert_contains "$TEST_LOG_FILE" "Self-updated" "Log contains Self-updated message"
echo ""

# --- Test 5: Network unreachable ---
echo "Test 5: Network unreachable"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
# No server started — use unreachable address
GEMINI_INSTALL_DIR="$TEST_INSTALL_DIR" \
GEMINI_RAW_BASE="http://127.0.0.1:19999" \
GEMINI_LOG_FILE="$TEST_LOG_FILE" \
GEMINI_LOCAL_STATE_PATH="/dev/null" \
    bash "$TEST_INSTALL_DIR/patch.sh" run 2>/dev/null || true
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged"
assert_contains "$TEST_LOG_FILE" "network error" "Log contains network error"
echo ""

# --- Test 6: Partial download failure ---
echo "Test 6: Partial download failure (VERSION only, no patch.sh)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
local_patch_hash=$(md5 -q "$TEST_INSTALL_DIR/patch.sh")
start_server "$FIXTURES/partial"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged after partial failure"
assert_contains "$TEST_LOG_FILE" "download failed" "Log contains download failed"
new_patch_hash=$(md5 -q "$TEST_INSTALL_DIR/patch.sh")
if [ "$local_patch_hash" = "$new_patch_hash" ]; then
    ((PASS++)); echo "  ✓ PASS: patch.sh unchanged"
else
    ((FAIL++)); echo "  ✗ FAIL: patch.sh was modified"
fi
echo ""

# --- Test 7: First check (no timestamp file) ---
echo "Test 7: First check (no timestamp file)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created on first check"
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated on first check"
echo ""

# --- Test 8: No local VERSION file ---
echo "Test 8: No local VERSION file"
reset_install_dir
rm -f "$TEST_INSTALL_DIR/VERSION"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION created from remote"
assert_contains "$TEST_LOG_FILE" "Self-updated from unknown to v99.0.0" "Log shows update from unknown"
echo ""

# === Results ===
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
