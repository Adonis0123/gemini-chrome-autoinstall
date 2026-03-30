# Watcher-Based Retry Design

## Problem

When Chrome is running during a patch trigger, the system writes a `pending` flag and relies on a retry LaunchAgent (macOS) or watch daemon timeout (Windows) to periodically check if Chrome has closed. The current retry interval is 60 seconds with an internal backoff that increases the effective interval to 5 minutes after 10 retries. This causes two issues:

1. **Missed windows**: If the user closes Chrome briefly and reopens it, the 60s–5min check interval often misses the gap entirely.
2. **Excessive idle retries**: Hundreds of no-op retries accumulate (e.g., 886 retries over 15 hours) with no benefit.

## Solution

Replace passive periodic polling with an **active in-process watcher** that detects Chrome closing within seconds.

## Architecture

### Current flow

```
trigger → Chrome running → write pending → EXIT
retry agent (60s + backoff) → Chrome running? → skip → ...loop...
retry agent → Chrome closed → patch (delay: 0–300s)
```

### New flow

```
trigger → Chrome running → write pending → SPAWN WATCHER → EXIT
watcher (pgrep + sleep 3s) → Chrome closed → patch → EXIT (delay: 0–3s)
retry agent (300s fallback) → only if watcher died unexpectedly
```

## macOS Implementation

### New `cmd_watcher` subcommand

Responsibilities:
1. Write PID to `$INSTALL_DIR/watcher.pid`; exit if another watcher is already running (`kill -0` check)
2. Loop: `pgrep -x "Google Chrome"` + `sleep 3`
3. When Chrome closes: `rm` PID file, `exec "$0" run` to trigger full patch flow
4. Trap on EXIT to clean up PID file

### New `spawn_watcher` helper

Called from `cmd_run` and `cmd_retry` when Chrome is running:
1. Check PID file — if watcher already running, skip
2. Launch `$0 watcher </dev/null >/dev/null 2>&1 &` + `disown`
3. Log spawned PID

### Retry LaunchAgent changes

- `ThrottleInterval`: 60 → 300 (5 minutes, fallback only)
- `cmd_retry`: if Chrome is running, call `spawn_watcher` instead of just logging
- Remove `should_attempt_retry_now()` backoff function

### Uninstall cleanup

`cmd_uninstall` must read `watcher.pid` and kill the watcher process before removing install directory.

## Windows Implementation

Minimal changes — the existing `Invoke-Watch` daemon already detects Chrome close transitions (`$chromeWasRunning -and -not $chromeIsRunning`). The problem is the 60s timeout interval.

### Changes

1. `$RetryInterval`: 60 → 5 (5-second timeout in `WaitForSingleObject`)
2. Delete `Should-AttemptRetryNow` function
3. Simplify `Invoke-PendingInstall`: remove backoff check, directly proceed if pending exists and Chrome is not running

### Why no WMI events

The existing watch daemon architecture (registry monitor + timeout loop + Chrome state transition detection) is sufficient. Adding `Register-WmiEvent` would introduce a parallel mechanism with no meaningful benefit over a 5-second timeout.

## Concurrency

| Scenario | Handling |
|----------|----------|
| Multiple triggers spawn watcher | PID file + `kill -0` check: only one watcher at a time |
| Watcher and retry agent race to patch | Existing active lock (`mkdir` atomic) prevents concurrent patches |
| Watcher running, new trigger fires | PID file check → skip spawn, log |

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Chrome closes and reopens quickly (< 3s) | Watcher detects close → triggers `cmd_run` → `cmd_run` re-checks `is_chrome_running` → if Chrome is back, writes pending and spawns new watcher |
| Chrome stays open for days | Watcher sleeps in loop; CPU ≈ 0%, no impact |
| Watcher process killed unexpectedly | PID file becomes stale → retry agent (5min) detects pending → spawns new watcher |
| System sleep/wake | Watcher process survives sleep, resumes loop after wake |
| Successful patch | Removes pending file + PID file; watcher exits; retry agent finds no pending |
| `patch.sh uninstall` | Reads PID file, kills watcher, removes PID file and install directory |

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
| `watcher-cleanup-on-uninstall` | Spawn watcher → uninstall → verify watcher killed and PID file removed |
| `retry-agent-respawns-watcher` | Spawn watcher → kill it → trigger retry → verify new watcher spawned |
| `watcher-response-time` | Start fake Chrome → spawn watcher → kill fake Chrome → assert patch triggered within 5 seconds |
| `watcher-cpu-idle` | Spawn watcher with fake Chrome running 60s → sample CPU → assert < 1% average |

### Performance test

Sample watcher process CPU every 5 seconds over 60 seconds while fake Chrome is running. Assert average CPU < 1%.

## Change Summary

### macOS (`patch.sh`)

- **Add**: `cmd_watcher` subcommand (~30 lines)
- **Add**: `spawn_watcher()` helper (~15 lines)
- **Modify**: `cmd_run` / `cmd_retry` — call `spawn_watcher` when Chrome is running
- **Modify**: `cmd_uninstall` — kill watcher process via PID file
- **Modify**: `cmd_enable` — retry plist `ThrottleInterval` 60 → 300
- **Delete**: `should_attempt_retry_now()` function

### Windows (`patch.ps1`)

- **Modify**: `$RetryInterval` 60 → 5
- **Delete**: `Should-AttemptRetryNow` function
- **Modify**: `Invoke-PendingInstall` — remove backoff check

### Tests

- **Add**: `tests/helpers/fake-chrome.sh` + `tests/helpers/fake-chrome.ps1`
- **Add**: 6 macOS test cases in `tests/macos/run-tests.sh`
- **Add**: corresponding Windows test cases in `tests/windows/run-tests.ps1`

### Unchanged

- Boot agent, watcher agent (Info.plist), fallback agent
- `reconcile_patch_state` / `Invoke-Reconcile` core logic
- Self-update, active lock, pending file format
- `install.sh` / `install.ps1`

## Estimated scope

- macOS: +60 lines (watcher), -15 lines (backoff), +80 lines tests
- Windows: 3 modifications, +60 lines tests
