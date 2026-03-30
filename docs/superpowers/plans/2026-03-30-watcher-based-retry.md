# Watcher-Based Retry Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace passive 60s retry polling with an active in-process watcher that patches Chrome within 3 seconds of it closing.

**Architecture:** macOS gets a new `cmd_watcher` subcommand that polls `pgrep` every 3s in a background process, spawned when Chrome is detected running. Windows simply reduces the existing watch daemon timeout from 60s to 10s. Both platforms remove the backoff function.

**Tech Stack:** Bash (macOS), PowerShell (Windows), existing custom test framework

**Spec:** `docs/superpowers/specs/2026-03-30-watcher-based-retry-design.md`

---

## Chunk 1: macOS Core — Watcher + Spawn

### Task 1: Add `is_watcher_running` helper to `patch.sh`

**Files:**
- Modify: `patch.sh` (after `should_attempt_retry_now` function, before `remove_pending` function)

> **Note on line numbers:** All line references are based on the original file. As tasks are applied sequentially, line numbers will drift. Use function names and surrounding context to locate insertion points, not hard-coded line numbers.

- [ ] **Step 1: Write the helper function**

Insert after the `should_attempt_retry_now` function, before `remove_pending`:

```bash
WATCHER_PID_FILE="$INSTALL_DIR/watcher.pid"

is_watcher_running() {
    if [ ! -f "$WATCHER_PID_FILE" ]; then
        return 1
    fi
    local saved_pid saved_ts
    read -r saved_pid saved_ts < "$WATCHER_PID_FILE" 2>/dev/null || return 1
    if [ -z "$saved_pid" ] || [ -z "$saved_ts" ]; then
        return 1
    fi
    if ! kill -0 "$saved_pid" 2>/dev/null; then
        return 1
    fi
    # Guard against PID reuse: check process start time
    local proc_start
    proc_start=$(ps -p "$saved_pid" -o lstart= 2>/dev/null) || return 1
    local proc_epoch
    proc_epoch=$(date -j -f "%a %b %d %T %Y" "$proc_start" "+%s" 2>/dev/null) || return 1
    # Allow 2s tolerance for start time rounding
    local diff=$(( proc_epoch - saved_ts ))
    if [ "$diff" -lt -2 ] || [ "$diff" -gt 2 ]; then
        return 1
    fi
    return 0
}
```

- [ ] **Step 2: Verify script still parses**

Run: `bash -n patch.sh`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): add is_watcher_running helper with PID+timestamp validation"
```

---

### Task 2: Add `cmd_watcher` subcommand to `patch.sh`

**Files:**
- Modify: `patch.sh` (insert before the `cmd_run()` function)

- [ ] **Step 1: Write `cmd_watcher` function**

Insert before `cmd_run()` function:

```bash
cmd_watcher() {
    local pid_file="$WATCHER_PID_FILE"
    if is_watcher_running; then
        log "Watcher: another instance already running, exiting."
        return 0
    fi

    local my_ts
    my_ts=$(date +%s)
    echo "$$ $my_ts" > "$pid_file"
    trap 'rm -f "$pid_file"' EXIT

    log "Watcher started (PID=$$), waiting for Chrome to close..."

    while is_chrome_running; do
        sleep 3
    done

    log "Watcher: Chrome closed, triggering reconcile."
    rm -f "$pid_file"
    trap - EXIT

    NEEDS_PATCH_CHROME_VERSION="$(get_chrome_version_or_unknown)"
    reconcile_patch_state "watcher" || true
}
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): add cmd_watcher subcommand — polls pgrep every 3s"
```

---

### Task 3: Add `spawn_watcher` helper to `patch.sh`

**Files:**
- Modify: `patch.sh` (insert right after `cmd_watcher`, before `cmd_run`)

- [ ] **Step 1: Write `spawn_watcher` function**

```bash
spawn_watcher() {
    if is_watcher_running; then
        log "Watcher already running, skipping spawn."
        return 0
    fi
    "$0" watcher >> "$LOG_FILE" 2>&1 &
    disown
    log "Watcher spawned (PID=$!)."
}
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): add spawn_watcher helper for background watcher launch"
```

---

### Task 4: Wire `spawn_watcher` into `reconcile_patch_state` drifted branch

**Files:**
- Modify: `patch.sh` — `reconcile_patch_state` function, `drifted)` case, `is_chrome_running` branch

- [ ] **Step 1: Add spawn_watcher call**

Change the `drifted)` branch from:

```bash
        drifted)
            if is_chrome_running; then
                upsert_pending_record "blocked" "$patch_reason"
                write_last_result "blocked" "$patch_reason" "$chrome_ver" "Will auto-fix after Chrome closes"
                return 0
            fi
```

To:

```bash
        drifted)
            if is_chrome_running; then
                upsert_pending_record "blocked" "$patch_reason"
                write_last_result "blocked" "$patch_reason" "$chrome_ver" "Will auto-fix after Chrome closes"
                spawn_watcher
                return 0
            fi
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): spawn watcher from reconcile when Chrome is running"
```

---

### Task 5: Rewrite `cmd_retry` — remove backoff, add watcher support

**Files:**
- Modify: `patch.sh` — `cmd_retry` function (full replacement)

- [ ] **Step 1: Replace cmd_retry**

Find `cmd_retry()` and replace the entire function with:

```bash
cmd_retry() {
    if [ ! -f "$PENDING_FILE" ]; then
        return 0
    fi

    log "Retry: pending install found."
    NEEDS_PATCH_CHROME_VERSION="$(get_chrome_version_or_unknown)"

    local pending_patch_reason
    pending_patch_reason=$(get_pending_patch_reason)

    if is_chrome_running; then
        if is_watcher_running; then
            log "Retry: watcher already active, skipping."
            return 0
        fi
        upsert_pending_record "blocked" "$pending_patch_reason"
        write_last_result "blocked" "$pending_patch_reason" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "Will auto-fix after Chrome closes"
        spawn_watcher
        log "Retry: Chrome still running. Watcher spawned."
        return 0
    fi

    reconcile_patch_state "retry" || true
    return 0
}
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "♻️ refactor(macos): rewrite cmd_retry — remove backoff, spawn watcher"
```

---

### Task 6: Delete `should_attempt_retry_now` function

**Files:**
- Modify: `patch.sh` — delete `should_attempt_retry_now` function

- [ ] **Step 1: Remove the function**

Find and delete the entire `should_attempt_retry_now` function:

```bash
should_attempt_retry_now() {
    local retry_count="$1"
    if [ "$retry_count" -lt 10 ]; then
        return 0
    fi
    [ $(( retry_count % 5 )) -eq 0 ]
}
```

- [ ] **Step 2: Verify no remaining references**

Run: `grep -n "should_attempt_retry_now" patch.sh`
Expected: no output (all references removed in Task 5)

- [ ] **Step 3: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 4: Commit**

```bash
git add patch.sh
git commit -m "♻️ refactor(macos): delete should_attempt_retry_now backoff function"
```

---

### Task 7: Add `watcher)` to case dispatch + usage text

**Files:**
- Modify: `patch.sh` — main `case "${1:-help}" in` block at bottom of file

- [ ] **Step 1: Add watcher case**

Add `watcher)   cmd_watcher ;;` after the `retry)` line, and update the usage text:

```bash
case "${1:-help}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    retry)     cmd_retry ;;
    watcher)   cmd_watcher ;;
    manual)    cmd_manual ;;
    *)
        echo "Usage: $0 {enable|disable|uninstall|status|run|retry|watcher|manual}"
        echo ""
        echo "Commands:"
        echo "  enable      Install and load boot/watcher/retry/fallback LaunchAgents"
        echo "  disable     Unload and remove all LaunchAgents"
        echo "  uninstall   Disable and remove all installed files"
        echo "  status      Show current status"
        echo "  run         Reconcile local state (creates/updates pending if blocked)"
        echo "  retry       Retry pending reconcile (called by KeepAlive agent)"
        echo "  watcher     Wait for Chrome to close, then reconcile (background)"
        echo "  manual      Re-install immediately after you close Chrome"
        exit 1
        ;;
esac
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): add watcher subcommand to case dispatch and usage text"
```

---

### Task 8: Update `cmd_status` to show watcher state

**Files:**
- Modify: `patch.sh` — `cmd_status` function

- [ ] **Step 1: Add watcher status display**

After the `fallback_agent_state` block (after `if [ -f "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" ]` check), add:

```bash
    local watcher_state="not running"
    if is_watcher_running; then
        local watcher_pid
        read -r watcher_pid _ < "$WATCHER_PID_FILE" 2>/dev/null
        watcher_state="running (PID $watcher_pid)"
    fi
```

Then add the echo line after the `Fallback agent:` echo line:

```bash
    echo "Watcher process: ${watcher_state}"
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Run existing status test to confirm no regression**

Run: `bash tests/macos/run-tests.sh status-shows-tool-version`
Expected: PASSED

- [ ] **Step 4: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): show watcher process state in cmd_status output"
```

---

### Task 9: Update `cmd_uninstall` to kill watcher

**Files:**
- Modify: `patch.sh` — `cmd_uninstall` function (full replacement)

- [ ] **Step 1: Add watcher cleanup**

Replace `cmd_uninstall`:

```bash
cmd_uninstall() {
    # Kill watcher process if running
    if [ -f "$WATCHER_PID_FILE" ]; then
        local watcher_pid
        read -r watcher_pid _ < "$WATCHER_PID_FILE" 2>/dev/null
        if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
            kill "$watcher_pid" 2>/dev/null || true
            log "Killed watcher process (PID $watcher_pid)."
        fi
    fi
    cmd_disable
    rm -rf "$ACTIVE_LOCK_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Uninstalled: all files removed."
    echo "Done. gemini-chrome-autoinstall has been completely removed."
}
```

- [ ] **Step 2: Verify script parses**

Run: `bash -n patch.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(macos): kill watcher process on uninstall"
```

---

## Chunk 2: Windows Changes

### Task 10: Reduce `$RetryInterval` from 60 to 10

**Files:**
- Modify: `patch.ps1:25`

- [ ] **Step 1: Change the value**

Change line 25 from:

```powershell
$RetryInterval = 60  # seconds
```

To:

```powershell
$RetryInterval = 10  # seconds — reduced for faster Chrome-close detection
```

- [ ] **Step 2: Commit**

```bash
git add patch.ps1
git commit -m "🎉 feat(windows): reduce RetryInterval 60s → 10s for faster Chrome-close detection"
```

---

### Task 11: Delete `Should-AttemptRetryNow` and simplify `Invoke-PendingInstall`

**Files:**
- Modify: `patch.ps1:462-470` (delete function)
- Modify: `patch.ps1:560-584` (simplify `Invoke-PendingInstall`)

- [ ] **Step 1: Delete `Should-AttemptRetryNow` function**

Delete lines 462-470:

```powershell
function Should-AttemptRetryNow {
    param([int]$RetryCount)

    if ($RetryCount -lt 10) {
        return $true
    }

    return ($RetryCount % 5) -eq 0
}
```

- [ ] **Step 2: Simplify `Invoke-PendingInstall`**

Replace `Invoke-PendingInstall` (lines 560-584) with:

```powershell
function Invoke-PendingInstall {
    if (-not (Test-Pending)) {
        return
    }

    Write-Log "Retry: pending install found."
    $script:NeedsPatchChromeVersion = Get-ChromeVersionOrUnknown
    $pendingPatchReason = Get-PendingPatchReason

    if (Test-IsChromeRunning) {
        Upsert-PendingRecord -Reason "blocked" -PatchReason $pendingPatchReason
        Write-LastResult -Status "blocked" -Reason $pendingPatchReason -ChromeVersion $script:NeedsPatchChromeVersion -Hint "Will auto-fix after Chrome closes"
        return
    }

    [void](Invoke-Reconcile -Trigger "retry")
}
```

- [ ] **Step 3: Verify no remaining references to `Should-AttemptRetryNow`**

Run: `grep -n "Should-AttemptRetryNow" patch.ps1`
Expected: no output

- [ ] **Step 4: Commit**

```bash
git add patch.ps1
git commit -m "♻️ refactor(windows): delete Should-AttemptRetryNow, simplify Invoke-PendingInstall"
```

---

## Chunk 3: macOS Tests

### Task 12: Create `tests/helpers/fake-chrome.sh`

**Files:**
- Create: `tests/helpers/fake-chrome.sh`

- [ ] **Step 1: Write the fake Chrome helper**

```bash
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
```

- [ ] **Step 2: Verify it works**

Run: `bash -c 'TMPDIR=/tmp source tests/helpers/fake-chrome.sh && start_fake_chrome && pgrep -x "Google Chrome" && stop_fake_chrome && echo OK'`
Expected: a PID number, then `OK`

- [ ] **Step 3: Commit**

```bash
git add tests/helpers/fake-chrome.sh
git commit -m "✅ test: add fake-chrome.sh helper for watcher tests"
```

---

### Task 13: Add watcher test cases to `tests/macos/run-tests.sh`

**Files:**
- Modify: `tests/macos/run-tests.sh` (insert before the final summary block at line 212)

**Note:** Tests run inside `bash -c` subshells, so `fake-chrome.sh` cannot be `source`d into the parent test harness. Each test case defines its own inline `start_fake` helper. The `fake-chrome.sh` file serves as reference documentation and for interactive use.

- [ ] **Step 1: Add test case `watcher-patches-on-chrome-close`**

Insert before line 212 (before `if [[ "${#TEST_CASES[@]}" -gt 0 ]]`):

```bash
WATCHER_RUNTIME_DIR="$TMP_ROOT/runtime/watcher-patches"
if run_case "watcher-patches-on-chrome-close" bash -c "
  mkdir -p '$WATCHER_RUNTIME_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_RUNTIME_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_RUNTIME_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_RUNTIME_DIR/local-state.json'
  export GEMINI_CORE_INSTALL_CMD='$REPO_ROOT/tests/helpers/fake-core-install.sh'
  export GEMINI_FAKE_INSTALL_MODE='success'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_RUNTIME_DIR/test.log'

  start_fake_chrome() {
    local fake_bin='${TMPDIR}/Google Chrome'
    cp /bin/sleep \"\$fake_bin\" 2>/dev/null; chmod +x \"\$fake_bin\"
    \"\$fake_bin\" 9999 &
    echo \$!
  }
  CHROME_PID=\$(start_fake_chrome)

  bash patch.sh watcher &
  WATCHER_PID=\$!

  sleep 2
  kill \"\$CHROME_PID\" 2>/dev/null; wait \"\$CHROME_PID\" 2>/dev/null || true

  # Wait up to 10s for watcher to finish
  for i in \$(seq 1 10); do
    kill -0 \"\$WATCHER_PID\" 2>/dev/null || break
    sleep 1
  done
  wait \"\$WATCHER_PID\" 2>/dev/null || true
"; then
  assert_file_contains "$WATCHER_RUNTIME_DIR/last-result" "status=healthy"
  assert_file_missing "$WATCHER_RUNTIME_DIR/pending"
fi
```

- [ ] **Step 2: Add test case `watcher-no-duplicate-spawn`**

```bash
WATCHER_DUP_DIR="$TMP_ROOT/runtime/watcher-dup"
if run_case "watcher-no-duplicate-spawn" bash -c "
  mkdir -p '$WATCHER_DUP_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_DUP_DIR'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_DUP_DIR/test.log'

  # Write a PID file for a real running process (ourselves)
  echo \"\$\$ \$(date +%s)\" > '$WATCHER_DUP_DIR/watcher.pid'

  # cmd_watcher should detect and exit
  bash patch.sh watcher
"; then
  assert_file_contains "$WATCHER_DUP_DIR/test.log" "another instance already running"
fi
```

- [ ] **Step 3: Add test case `watcher-stale-pid-recovery`**

```bash
WATCHER_STALE_DIR="$TMP_ROOT/runtime/watcher-stale"
if run_case "watcher-stale-pid-recovery" bash -c "
  mkdir -p '$WATCHER_STALE_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_STALE_DIR'
  export GEMINI_CHROME_RUNNING='0'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_STALE_DIR/test.log'

  # Write a stale PID file (nonexistent PID)
  echo '99999 1700000000' > '$WATCHER_STALE_DIR/watcher.pid'

  # cmd_watcher should start despite stale PID, detect Chrome not running, and reconcile
  bash patch.sh watcher
"; then
  # Watcher started, Chrome was not running so it ran reconcile immediately
  assert_file_contains "$WATCHER_STALE_DIR/test.log" "Watcher started"
fi
```

- [ ] **Step 4: Add test case `watcher-response-time`**

```bash
WATCHER_PERF_DIR="$TMP_ROOT/runtime/watcher-perf"
if run_case "watcher-response-time" bash -c "
  mkdir -p '$WATCHER_PERF_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_PERF_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_PERF_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_PERF_DIR/local-state.json'
  export GEMINI_CORE_INSTALL_CMD='$REPO_ROOT/tests/helpers/fake-core-install.sh'
  export GEMINI_FAKE_INSTALL_MODE='success'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_PERF_DIR/test.log'

  start_fake() {
    local fb='${TMPDIR}/Google Chrome'
    cp /bin/sleep \"\$fb\" 2>/dev/null; chmod +x \"\$fb\"
    \"\$fb\" 9999 &
    echo \$!
  }
  CPID=\$(start_fake)

  bash patch.sh watcher &
  WPID=\$!
  sleep 1

  BEFORE=\$(date +%s)
  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true

  for i in \$(seq 1 10); do
    kill -0 \"\$WPID\" 2>/dev/null || break
    sleep 1
  done
  AFTER=\$(date +%s)
  ELAPSED=\$(( AFTER - BEFORE ))
  echo \"response_time=\${ELAPSED}s\"

  wait \"\$WPID\" 2>/dev/null || true
  [ \"\$ELAPSED\" -le 10 ] || { echo 'TIMEOUT: watcher took > 10s'; exit 1; }
"; then
  assert_contains "${CASE_OUTPUT}" "response_time="
fi
```

- [ ] **Step 5: Add test case `watcher-cpu-idle`**

```bash
WATCHER_CPU_DIR="$TMP_ROOT/runtime/watcher-cpu"
if run_case "watcher-cpu-idle" bash -c "
  mkdir -p '$WATCHER_CPU_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_CPU_DIR'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_CPU_DIR/test.log'

  start_fake() {
    local fb='${TMPDIR}/Google Chrome'
    cp /bin/sleep \"\$fb\" 2>/dev/null; chmod +x \"\$fb\"
    \"\$fb\" 9999 &
    echo \$!
  }
  CPID=\$(start_fake)

  bash patch.sh watcher &
  WPID=\$!

  # Let watcher run for 15 seconds
  sleep 15
  CPUTIME=\$(ps -p \"\$WPID\" -o cputime= 2>/dev/null || echo '0:00.00')
  echo \"watcher_cputime=\${CPUTIME}\"

  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
  for i in \$(seq 1 10); do kill -0 \"\$WPID\" 2>/dev/null || break; sleep 1; done
  wait \"\$WPID\" 2>/dev/null || true

  # Parse MM:SS.xx format — assert total < 2 seconds
  SECS=\$(echo \"\$CPUTIME\" | awk -F: '{if(NF==2) print \$1*60+\$2; else print \$1}')
  RESULT=\$(echo \"\$SECS < 2\" | bc)
  [ \"\$RESULT\" -eq 1 ] || { echo \"CPU too high: \${CPUTIME}\"; exit 1; }
"; then
  assert_contains "${CASE_OUTPUT}" "watcher_cputime="
fi
```

- [ ] **Step 6: Add test case `watcher-cleanup-on-uninstall`**

```bash
WATCHER_UNINST_DIR="$TMP_ROOT/runtime/watcher-uninst"
if run_case "watcher-cleanup-on-uninstall" bash -c "
  mkdir -p '$WATCHER_UNINST_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_UNINST_DIR'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_UNINST_DIR/test.log'

  start_fake() {
    local fb='${TMPDIR}/Google Chrome'
    cp /bin/sleep \"\$fb\" 2>/dev/null; chmod +x \"\$fb\"
    \"\$fb\" 9999 &
    echo \$!
  }
  CPID=\$(start_fake)

  bash patch.sh watcher &
  WPID=\$!
  sleep 1

  # Verify watcher is running
  kill -0 \"\$WPID\" || { echo 'watcher not running'; exit 1; }

  # Run uninstall (skip disable since no LaunchAgents in test)
  bash patch.sh uninstall 2>/dev/null || true

  # Give watcher time to be killed
  sleep 1
  if kill -0 \"\$WPID\" 2>/dev/null; then
    echo 'FAIL: watcher still running after uninstall'
    kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
    exit 1
  fi
  echo 'watcher_killed=yes'
  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
"; then
  assert_contains "${CASE_OUTPUT}" "watcher_killed=yes"
fi
```

- [ ] **Step 7: Add test case `retry-agent-respawns-watcher`**

```bash
WATCHER_RESPAWN_DIR="$TMP_ROOT/runtime/watcher-respawn"
if run_case "retry-agent-respawns-watcher" bash -c "
  mkdir -p '$WATCHER_RESPAWN_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_RESPAWN_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_RESPAWN_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_RESPAWN_DIR/local-state.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_RESPAWN_DIR/test.log'

  # Create pending file to simulate existing pending state
  echo 'pending' > '$WATCHER_RESPAWN_DIR/pending'
  echo 'reason=blocked' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'patch_reason=variations_country=cn' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'first_seen_at=2026-01-01T00:00:00Z' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'last_attempt_at=2026-01-01T00:00:00Z' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'retry_count=5' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'detected_version=136.0.7103.49' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'platform=macos' >> '$WATCHER_RESPAWN_DIR/pending'

  # Write a stale watcher PID (dead process)
  echo '99999 1700000000' > '$WATCHER_RESPAWN_DIR/watcher.pid'

  # Retry should detect stale watcher and spawn new one
  bash patch.sh retry
  sleep 1

  # Check if a new watcher was spawned
  if [ -f '$WATCHER_RESPAWN_DIR/watcher.pid' ]; then
    NEW_PID=\$(head -1 '$WATCHER_RESPAWN_DIR/watcher.pid' | awk '{print \$1}')
    if [ \"\$NEW_PID\" != '99999' ] && kill -0 \"\$NEW_PID\" 2>/dev/null; then
      echo 'respawned=yes'
      kill \"\$NEW_PID\" 2>/dev/null || true
    else
      echo 'respawned=no'
    fi
  else
    echo 'respawned=no'
  fi
"; then
  assert_contains "${CASE_OUTPUT}" "respawned=yes"
fi
```

- [ ] **Step 8: Run all tests to verify**

Run: `bash tests/macos/run-tests.sh`
Expected: PASSED

- [ ] **Step 9: Commit**

```bash
git add tests/macos/run-tests.sh
git commit -m "✅ test(macos): add watcher test cases — patches on close, dedup, stale PID, uninstall, respawn, perf, CPU"
```

---

## Chunk 4: Windows Tests + Existing Test Regression

### Task 14: Add Windows test for removed backoff

**Files:**
- Modify: `tests/windows/run-tests.ps1`

- [ ] **Step 1: Verify `Should-AttemptRetryNow` is no longer called**

Run: `grep -n "Should-AttemptRetryNow" patch.ps1`
Expected: no output

- [ ] **Step 2: Verify `$RetryInterval` is 10**

Run: `grep -n "RetryInterval" patch.ps1 | head -3`
Expected: line 25 shows `$RetryInterval = 10`

- [ ] **Step 3: Commit** (if Windows tests added)

```bash
git add tests/windows/run-tests.ps1
git commit -m "✅ test(windows): verify backoff removal and reduced retry interval"
```

---

### Task 15: Run full macOS test suite and verify no regressions

**Files:**
- No changes — validation only

- [ ] **Step 1: Run all existing tests**

Run: `bash tests/macos/run-tests.sh`
Expected: PASSED (all existing + new tests pass)

- [ ] **Step 2: Run self-update tests**

Run: `bash tests/self-update/run-tests.sh`
Expected: PASSED

- [ ] **Step 3: Manual smoke test**

Run: `bash patch.sh status`
Expected: output includes `Watcher process:` line (either "running" or "not running")

---

### Task 16: Final integration commit

- [ ] **Step 1: Review all changes**

Run: `git log --oneline -10`
Expected: see all commits from this plan

- [ ] **Step 2: Verify clean working tree**

Run: `git status`
Expected: clean working directory, no untracked files
