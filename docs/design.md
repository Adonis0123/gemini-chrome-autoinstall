# Gemini Chrome AutoInstall Design

## 1. Goal

`gemini-chrome-autoinstall` is a state-driven repair tool for Gemini-in-Chrome.

The tool does not assume a Chrome version change automatically means patching is required. Instead it uses version changes and trigger events as signals, then checks `Local State` to decide whether the machine is actually:

- `healthy`
- `drifted`
- `unknown`
- `pending`

The system only writes when Chrome is closed. If Chrome is still open, it records `pending` metadata and retries later.

## 2. Architecture

### Core flow

```text
trigger
  -> read Chrome version signal
  -> inspect Local State
  -> detect current patch state
  -> if healthy: record healthy version and clear stale pending
  -> if drifted + Chrome open: record pending
  -> if drifted + Chrome closed: run upstream patch + verify result
  -> if unknown / patch_failed / verify_failed: record failure and surface manual recovery
```

### Responsibility split

| Layer | Responsibility |
|------|----------------|
| `install.sh` / `install.ps1` | Download scripts, register startup hooks, expose current tool version |
| `patch.sh` / `patch.ps1` | Detect state, reconcile drift, maintain pending metadata, expose status |
| Trigger layer | LaunchAgents on macOS, Run key + watcher on Windows |

## 3. Runtime Files

### macOS

| Item | Path |
|------|------|
| Install directory | `~/.gemini-chrome-autoinstall/` |
| Pending metadata | `~/.gemini-chrome-autoinstall/pending` |
| Last healthy version | `~/.gemini-chrome-autoinstall/patched-version.txt` |
| Last result metadata | `~/.gemini-chrome-autoinstall/last-result` |
| Log | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Active lock | `/tmp/gemini-chrome-autoinstall.active.lock/` |

### Windows

| Item | Path |
|------|------|
| Install directory | `%USERPROFILE%\.gemini-chrome-autoinstall\` |
| Pending metadata | `%USERPROFILE%\.gemini-chrome-autoinstall\pending` |
| Last healthy version | `%USERPROFILE%\.gemini-chrome-autoinstall\patched-version.txt` |
| Last result metadata | `%USERPROFILE%\.gemini-chrome-autoinstall\last-result` |
| Log | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |
| Active lock | `%TEMP%\gemini-chrome-autoinstall.active.lock\` |

### Metadata file format

`pending`

```text
pending
reason=blocked
patch_reason=variations_country=cn
first_seen_at=2026-03-29T08:00:00Z
last_attempt_at=2026-03-29T08:04:00Z
retry_count=4
detected_version=136.0.7103.49
platform=macos
```

`last-result`

```text
status=healthy
reason=ok
timestamp=2026-03-29T08:05:00Z
chrome_version=136.0.7103.49
tool_version=v0.1.2
hint=
```

## 4. State Model

### Detector states

| State | Meaning |
|------|---------|
| `healthy` | Required `Local State` fields match expected patched values |
| `drifted` | `Local State` proves the machine has fallen out of the expected patched state |
| `unknown` | The tool cannot prove health because the file is missing, invalid, or missing required fields |

### User-facing current states

| Current state | Meaning |
|------|---------|
| `healthy` | Verified healthy and no pending retry remains |
| `drifted` | Drift is confirmed and the machine is not currently blocked by pending metadata |
| `pending` | Drift has been detected but automatic repair is waiting or retrying |
| `unknown` | Detection could not prove the current state safely |

### Failure/result states

| Result | Meaning |
|------|---------|
| `detect_error` | Detection failed or required fields were missing |
| `blocked` | Chrome is still open or another run is active |
| `patch_failed` | Upstream patch command exited unsuccessfully |
| `verify_failed` | Patch command returned success, but `Local State` still was not healthy afterwards |

## 5. Health Detection

The detector currently checks these `Local State` signals:

- `variations_country == "us"`
- trailing country value in `variations_permanent_consistency_country == "us"`
- at least one `profile.info_cache.*.is_glic_eligible` value exists
- no `is_glic_eligible == false`

Detector rules:

- missing file or invalid JSON -> `unknown`
- missing required fields -> `unknown`
- `variations_country != "us"` -> `drifted`
- trailing `variations_permanent_consistency_country != "us"` -> `drifted`
- any `is_glic_eligible == false` -> `drifted`
- otherwise -> `healthy`

## 6. macOS Trigger Model

macOS uses four LaunchAgents:

| Label | Trigger | Action |
|------|---------|--------|
| `com.gemini-chrome-autoinstall.boot` | login | `patch.sh run` |
| `com.gemini-chrome-autoinstall.watcher` | Chrome app metadata changes | `patch.sh run` |
| `com.gemini-chrome-autoinstall.retry` | `pending` exists | `patch.sh retry` |
| `com.gemini-chrome-autoinstall.fallback` | every 30 minutes | `patch.sh run` |

The boot and watcher agents discover potential drift quickly. The retry and fallback agents help the system converge after blocked writes or missed file events.

## 7. Windows Trigger Model

Windows uses a login startup entry plus a background registry watcher.

### Startup

- Run key: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\GeminiChromeAutoPatch`
- Startup command: `patch.ps1 scheduled`

### Watch source

- Registry key: `HKCU:\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}`
- Version value: `pv`

### Background flow

`scheduled` does two things:

1. run a reconcile pass immediately
2. ensure `patch.ps1 watch` is running

`watch` waits on registry change notifications and also wakes up on timeout so pending retries can continue without a separate scheduler.

## 8. Concurrency Control

This system uses one concurrency primitive only:

- active lock directory (`mkdir` / `New-Item -ItemType Directory`)

Purpose:

- prevent concurrent patch attempts
- recover stale locks using stored PID checks

There is no time-based suppression path anymore. Repeated triggers are handled by current-state checks plus the active lock.

## 9. Reconcile Flow

### Automatic path

```text
run/retry/watch/startup trigger
  -> detect patch state
  -> healthy: clear pending, save healthy version, record healthy result
  -> unknown: record detect_error and surface manual command
  -> drifted + Chrome open: update pending and record blocked
  -> drifted + Chrome closed: patch + verify
```

### Patch + verify

```text
acquire active lock
  -> run upstream Gemini-in-Chrome installer
  -> if installer fails: patch_failed
  -> if installer succeeds: detect state again
  -> if still not healthy: verify_failed
  -> if healthy: save patched version, clear pending, record healthy
release active lock
```

## 10. Status Output

Current status output is designed for supportability, not just “is the agent loaded.”

Common fields:

- Tool version
- Chrome version
- Last healthy version
- Current state
- Pending reason
- Pending patch reason
- Pending retry count
- Pending age
- Last attempt

Windows also keeps startup-entry and watcher-process visibility. macOS also shows fallback-agent availability.

## 11. Manual Recovery

`gemini-chrome-fix` remains the stable escape hatch.

Use it when:

- `status` shows `detect_error`
- `status` shows `patch_failed`
- `status` shows `verify_failed`
- you want to force a user-confirmed repair path immediately

## 12. Testing Strategy

The test suite is organized around fixed `Local State` fixtures and deterministic fake installers.

### Fixture categories

- `healthy`
- `drifted-variations-country`
- `drifted-permanent-country`
- `drifted-glic-false`
- `unknown-missing-fields`
- `unknown-invalid`

### Test coverage goals

- installer version visibility
- healthy no-op
- drift detection
- pending creation while Chrome is running
- retry settle after Chrome closes
- `patch_failed`
- `verify_failed`
- richer `status` output

### Verification commands

macOS:

```bash
bash tests/macos/run-tests.sh
bash -n patch.sh
```

Windows:

```powershell
pwsh -NoLogo -NoProfile -File tests/windows/run-tests.ps1
pwsh -NoLogo -NoProfile -Command "[void][scriptblock]::Create((Get-Content patch.ps1 -Raw))"
```

### CI

GitHub Actions runs the macOS and Windows test suites in a matrix workflow so the Windows path is verified even when a local shell session does not have `pwsh`.
