#!/usr/bin/env bash
# Fake Chrome process for testing watcher behavior.
# Usage:
#   source tests/helpers/fake-chrome.sh
#   start_fake_chrome   # launches a background process named "Google Chrome"
#   stop_fake_chrome    # kills it
#   FAKE_CHROME_PID     # holds the PID

FAKE_CHROME_PID=""

start_fake_chrome() {
    local fake_bin="${TMPDIR}/Google Chrome"
    if [ ! -f "$fake_bin" ]; then
        cp /bin/sleep "$fake_bin"
        chmod +x "$fake_bin"
    fi
    "$fake_bin" 9999 &
    FAKE_CHROME_PID=$!
}

stop_fake_chrome() {
    if [ -n "$FAKE_CHROME_PID" ]; then
        kill "$FAKE_CHROME_PID" 2>/dev/null || true
        wait "$FAKE_CHROME_PID" 2>/dev/null || true
        FAKE_CHROME_PID=""
    fi
}
