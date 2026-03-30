# Watcher-Based Retry Design

## Problem

When Chrome is running during a patch trigger, the system writes a `pending` flag and relies on a retry LaunchAgent (macOS) or watch daemon timeout (Windows) to periodically check if Chrome has closed. The current retry interval is 60 seconds with an internal backoff that increases the effective interval to 5 minutes after 10 retries. This causes two issues:

1. **Missed windows**: If the user closes Chrome briefly and reopens it, the 60s-5min check interval often misses the gap entirely.
2. **Excessive idle retries**: Hundreds of no-op retries accumulate (e.g., 886 retries over 15 hours) with no benefit.

## Solution

Replace passive periodic polling with an **active in-process watcher** that detects Chrome closing within seconds.

## Architecture

### Current flow

```
trigger → Chrome running → write pending → EXIT
retry agent (60s + backoff) → Chrome running? → skip → ...loop...
retry agent → Chrome closed → patch (delay: 0-300s)
```

### New flow

```
trigger → Chrome running → write pending → SPAWN WATCHER → EXIT
watcher (pgrep + sleep 3s) → Chrome closed → reconcile → EXIT (delay: 0-3s)
retry agent (60s, no backoff) → backs up watcher; spawns new watcher if needed
```

## macOS Implementation

### New `cmd_watcher` subcommand

Responsibilities:
1. Write `$PID $EPOCH_SECONDS` to `$INSTALL_DIR/watcher.pid`; exit if another watcher is already running (validate PID alive via `kill -0` AND startup timestamp matches to guard against PID reuse)
2. Loop: `pgrep -x "Google Chrome"` + `sleep 3`
3. When Chrome closes: remove PID file, call `reconcile_patch_state "watcher"` inline (not `exec "$0" run`, to avoid triggering self-update or re-entering full cmd_run flow). Watcher is **fire-once**: exits after reconcile regardless of success or failure. If reconcile fails, retry agent handles subsequent attempts.
4. Trap on EXIT to clean up PID file
5. When `reconcile_patch_state` encounters `unknown` state with trigger `"watcher"`, it follows the same conservative path as `"run"` — logs `detect_error` and returns without force-patching. This is intentional.

### New `spawn_watcher` helper

Called from within `reconcile_patch_state` in the `drifted` branch, after `upsert_pending_record` and `write_last_result`, before `return 0`, when Chrome is detected as running. Also called from `cmd_retry` when Chrome is running.

1. Check PID file — if valid watcher already running (PID alive + timestamp match), skip
2. Launch `"$0" watcher >> "$LOG_FILE" 2>&1 &` + `disown` (log to main log file, not /dev/null)
3. Log spawned PID

### Retry LaunchAgent changes

- `ThrottleInterval`: keep at 60 (unchanged) — serves as fallback if watcher dies
- `cmd_retry`: if watcher is already running (PID file valid), early return; otherwise if Chrome is running, call `spawn_watcher`; if Chrome is not running, proceed with patch directly
- Remove `should_attempt_retry_now()` backoff function

### Status display

`cmd_status` must read `watcher.pid`, validate the PID, and display watcher running state (PID, uptime).

### Uninstall cleanup

`cmd_uninstall` must read `watcher.pid` and kill the watcher process before removing install directory.

## Windows Implementation

Minimal changes — the existing `Invoke-Watch` daemon already detects Chrome close transitions (`$chromeWasRunning -and -not $chromeIsRunning`). The problem is the 60s timeout interval.

### Changes

1. `$RetryInterval`: 60 → 10 (10-second timeout in `WaitForSingleObject`, balancing responsiveness vs system call frequency)
2. Delete `Should-AttemptRetryNow` function
3. Simplify `Invoke-PendingInstall`: remove backoff check, directly proceed if pending exists and Chrome is not running

### Why no WMI events

The existing watch daemon architecture (registry monitor + timeout loop + Chrome state transition detection) is sufficient. Adding `Register-WmiEvent` would introduce a parallel mechanism with no meaningful benefit over a 10-second timeout.

## Concurrency

| Scenario | Handling |
|----------|----------|
| Multiple triggers spawn watcher | PID file + `kill -0` + timestamp check: only one watcher at a time |
| Watcher and retry agent race to patch | Existing active lock (`mkdir` atomic) prevents concurrent patches |
| Watcher running, new trigger fires | PID file check → skip spawn, log |
| Fallback agent fires while watcher running | `cmd_retry` checks PID file → watcher alive → early return |

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Chrome closes and reopens quickly (< 3s) | Watcher detects close → calls `reconcile_patch_state "watcher"` → reconcile re-checks `is_chrome_running` → if Chrome is back, writes pending and spawns new watcher |
| Chrome stays open for days | Watcher sleeps in loop; CPU ~ 0%, no impact |
| Watcher process killed unexpectedly | PID file becomes stale (PID dead or timestamp mismatch) → retry agent (60s) detects pending + no valid watcher → spawns new watcher |
| PID reuse after watcher crash | Timestamp in PID file won't match replacement process → treated as stale → new watcher spawned |
| System sleep/wake | Watcher process survives sleep, resumes loop after wake |
| Successful patch | Removes pending file + PID file; watcher exits; retry agent finds no pending |
| `patch.sh uninstall` | Reads PID file, kills watcher, removes PID file and install directory |
| Chrome Canary/Beta/Dev | Not affected — `pgrep -x "Google Chrome"` only matches stable Chrome (existing behavior, not a regression) |

## Testing Strategy

### Fake Chrome process

macOS: copy `/bin/sleep` to a temp path named `"Google Chrome"`, launch it as a controllable process.
Windows: launch a named process or mock `Test-IsChromeRunning` function.

Test helpers: `tests/helpers/fake-chrome.sh` and `tests/helpers/fake-chrome.ps1`.

### Test cases

| Case | Assertion |
|------|-----------|
| `watcher-patches-on-chrome-close` | Start fake Chrome → spawn watcher → kill fake Chrome → verify patch executed |
| `watcher-no-duplicate-spawn` | Spawn watcher → spawn again → verify only one watcher process (PID file) |
| `watcher-stale-pid-recovery` | Write nonexistent PID to watcher.pid → call spawn_watcher → verify old PID file replaced, new watcher started |
| `watcher-cleanup-on-uninstall` | Spawn watcher → uninstall → verify watcher killed and PID file removed |
| `retry-agent-respawns-watcher` | Spawn watcher → kill it → trigger retry → verify new watcher spawned |
| `watcher-response-time` | Start fake Chrome → spawn watcher → kill fake Chrome → assert patch triggered within 10 seconds (relaxed for CI) |
| `watcher-cpu-idle` | Spawn watcher with fake Chrome running 60s → measure watcher process CPU time via `ps -p $PID -o cputime=` → assert < 1 second of CPU over 60 seconds |

### Performance test

Measure watcher process accumulated CPU time (`ps -p $PID -o cputime=`) over 60 seconds with fake Chrome running. Assert total CPU time < 1 second (equivalent to < 1.7% average).

### Windows test notes

Windows tests focus on the reduced `$RetryInterval` behavior and backoff removal, not watcher spawn logic (Windows has no new watcher process). Key cases: verify Chrome close detection within 10s, verify no backoff skipping.

## Change Summary

### macOS (`patch.sh`)

- **Add**: `cmd_watcher` subcommand (~30 lines)
- **Add**: `spawn_watcher()` helper (~15 lines)
- **Modify**: main `case` dispatch block — add `watcher)` case + update usage text
- **Modify**: `reconcile_patch_state` — call `spawn_watcher` in drifted + chrome_running branch
- **Modify**: `cmd_retry` — check watcher alive → early return; else spawn_watcher or patch
- **Modify**: `cmd_status` — display watcher running state from PID file
- **Modify**: `cmd_uninstall` — kill watcher process via PID file
- **Delete**: `should_attempt_retry_now()` function
- **Note**: retry plist `ThrottleInterval` stays at 60 (unchanged)

### Windows (`patch.ps1`)

- **Modify**: `$RetryInterval` 60 → 10
- **Delete**: `Should-AttemptRetryNow` function
- **Modify**: `Invoke-PendingInstall` — remove backoff check

### Tests

- **Add**: `tests/helpers/fake-chrome.sh` + `tests/helpers/fake-chrome.ps1`
- **Add**: 7 macOS test cases in `tests/macos/run-tests.sh` (including stale PID + performance)
- **Add**: Windows test cases for reduced interval behavior in `tests/windows/run-tests.ps1`

### Unchanged

- Boot agent, watcher agent (Info.plist), fallback agent (30min StartInterval)
- `reconcile_patch_state` / `Invoke-Reconcile` core logic (only adding spawn_watcher call point)
- Self-update, active lock, pending file format
- `install.sh` / `install.ps1`
- Retry plist `ThrottleInterval` (stays 60)

## Estimated scope

- macOS: +70 lines (watcher + status), -15 lines (backoff), +100 lines tests
- Windows: 3 modifications, +40 lines tests
