# Self-Update Design Spec

## Summary

Add silent self-update capability to `patch.sh` (macOS) and `patch.ps1` (Windows). The tool checks for new versions by fetching the remote `VERSION` file from `raw.githubusercontent.com`, and if a newer version exists, downloads and replaces the local scripts automatically. Checks are throttled to once per 24 hours.

## Goals

- Users who have already installed the tool receive updates automatically without manual intervention
- Zero new files, zero new triggers — piggyback on existing `run` / `scheduled` subcommands
- Graceful degradation: network failures never block the core patch logic

## Non-Goals

- User confirmation UI (notifications, dialogs)
- Rollback mechanism
- Independent updater script
- Updating the install script itself

## Design

### Trigger

`check_self_update()` / `Update-Self` is called at the top of:
- macOS: `patch.sh run` (invoked by boot agent, watcher agent)
- Windows: `patch.ps1 scheduled` (invoked by Registry Run key at login) and `patch.ps1 run`

Note: macOS retry agent calls `patch.sh retry`, not `run` — self-update is not triggered during retry cycles (the 24h cooldown would skip it anyway).

### Flow

```
run / scheduled entry
  │
  ├─ Read $INSTALL_DIR/last-update-check
  │   └─ < 24h since last check → skip, continue to patch logic
  │
  ├─ Fetch $RAW_BASE/VERSION (5s timeout)
  │   └─ Network failure → log warning, skip, continue to patch logic
  │
  ├─ Compare remote version vs local version
  │   └─ Same → update timestamp, skip
  │
  ├─ Download new files to temp directory (10s timeout)
  │   ├─ macOS: patch.sh, VERSION
  │   └─ Windows: patch.ps1, launcher.vbs, VERSION
  │   └─ Download failure → log warning, skip, local files unchanged
  │
  ├─ mv / Move-Item from temp to $INSTALL_DIR (safe replace via temp + move)
  ├─ Update last-update-check timestamp
  ├─ Log "Self-updated from {old} to {new}"
  │
  └─ Continue to original patch logic (old code for this run, new code next run)
```

### New State File

| File | Location | Content |
|------|----------|---------|
| `last-update-check` | `$INSTALL_DIR/last-update-check` | Unix timestamp (seconds since epoch) |

### 24-Hour Cooldown Logic

```
now = current unix timestamp
last = content of last-update-check (or 0 if missing)
if (now - last) < 86400: skip check
```

This prevents excessive checks in the retry scenario (60s polling loop).

### Version Comparison

Simple string comparison: `remote_ver != local_ver` triggers update. No semantic version parsing needed — any difference means update. This handles both upgrades and (rare) downgrades.

**Path consistency note:** In `patch.sh`, `TOOL_VERSION_FILE` points to `$SCRIPT_DIR/VERSION`, and in `patch.ps1`, `$ToolVersionFile` points to `$PSScriptRoot\VERSION`. Since `SCRIPT_DIR` / `$PSScriptRoot` equals `INSTALL_DIR` / `$InstallDir` in normal installations (the script runs from the install directory), reads and writes are consistent. The self-update function writes to `$INSTALL_DIR` which is the same directory. No change to `get_tool_version()` / `Get-ToolVersion` is needed.

### Data Source

Fetch `$RAW_BASE/VERSION` where `RAW_BASE` defaults to `https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master`. Users can override via `$GEMINI_RAW_BASE` environment variable.

**Important:** `RAW_BASE` / `$RawBase` currently only exists in `install.sh` / `install.ps1`. The same variable definition must be added to `patch.sh` and `patch.ps1`:

```bash
# patch.sh — add to variable declarations section
REPO="Adonis0123/gemini-chrome-autoinstall"
BRANCH="master"
RAW_BASE="${GEMINI_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
```

```powershell
# patch.ps1 — add to variable declarations section
$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "master"
$RawBase = if ($env:GEMINI_RAW_BASE) { $env:GEMINI_RAW_BASE } else { "https://raw.githubusercontent.com/$Repo/$Branch" }
```

### Error Handling

- All network operations have explicit timeouts (5s for VERSION check, 10s for script download)
- Any failure logs a message and returns — never blocks the core patch logic
- No retry within a single invocation; natural retry via next trigger cycle
- Partial downloads: download to temp dir first, only move to install dir if all files succeed

## Platform Implementation

### macOS (`patch.sh`)

New function `check_self_update()` added before `cmd_run()` logic:

```bash
check_self_update() {
    local check_file="$INSTALL_DIR/last-update-check"
    local now=$(date +%s)

    # 24h cooldown
    if [ -f "$check_file" ]; then
        local last=$(cat "$check_file")
        if [ $((now - last)) -lt 86400 ]; then
            return 0
        fi
    fi

    # Fetch remote version
    local remote_ver
    remote_ver=$(curl -fsSL --max-time 5 "$RAW_BASE/VERSION" 2>/dev/null) || {
        log "Self-update check failed: network error"
        return 0
    }
    remote_ver=$(echo "$remote_ver" | tr -d '\n')
    local local_ver=$(get_tool_version)

    # Update timestamp regardless
    echo "$now" > "$check_file"

    [ "$remote_ver" = "$local_ver" ] && return 0

    # Download to temp, then move
    local tmp=$(mktemp -d)
    curl -fsSL --max-time 10 "$RAW_BASE/patch.sh" -o "$tmp/patch.sh" &&
    curl -fsSL --max-time 5  "$RAW_BASE/VERSION" -o "$tmp/VERSION" || {
        log "Self-update download failed"
        rm -rf "$tmp"
        return 0
    }
    chmod +x "$tmp/patch.sh"
    mv "$tmp/patch.sh" "$INSTALL_DIR/patch.sh"
    mv "$tmp/VERSION"  "$INSTALL_DIR/VERSION"
    rm -rf "$tmp"
    log "Self-updated from $local_ver to $remote_ver"
}
```

Called at the start of `cmd_run()`.

### Windows (`patch.ps1`)

New function `Update-Self` added before `scheduled` subcommand logic:

```powershell
function Update-Self {
    $checkFile = Join-Path $InstallDir "last-update-check"
    $now = [int](Get-Date -UFormat %s)

    # 24h cooldown (with parse protection for corrupted timestamp files)
    if (Test-Path $checkFile) {
        $last = 0
        [int]::TryParse((Get-Content $checkFile -Raw).Trim(), [ref]$last) | Out-Null
        if (($now - $last) -lt 86400) { return }
    }

    # Fetch remote version
    try {
        $remoteVer = (Invoke-WebRequest -Uri "$RawBase/VERSION" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
    } catch {
        Write-Log "Self-update check failed: $_"
        return
    }
    $localVer = Get-ToolVersion

    # Update timestamp regardless
    $now | Set-Content $checkFile -NoNewline

    if ($remoteVer -eq $localVer) { return }

    # Download to temp, then move
    $tmp = Join-Path $env:TEMP "gemini-self-update"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Invoke-WebRequest -Uri "$RawBase/patch.ps1"    -OutFile "$tmp\patch.ps1"    -TimeoutSec 10 -UseBasicParsing
        Invoke-WebRequest -Uri "$RawBase/launcher.vbs" -OutFile "$tmp\launcher.vbs" -TimeoutSec 5  -UseBasicParsing
        Invoke-WebRequest -Uri "$RawBase/VERSION"      -OutFile "$tmp\VERSION"      -TimeoutSec 5  -UseBasicParsing
    } catch {
        Write-Log "Self-update download failed: $_"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Move-Item "$tmp\patch.ps1"    (Join-Path $InstallDir "patch.ps1")    -Force
    Move-Item "$tmp\launcher.vbs" (Join-Path $InstallDir "launcher.vbs") -Force
    Move-Item "$tmp\VERSION"      (Join-Path $InstallDir "VERSION")      -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Self-updated from $localVer to $remoteVer"
}
```

Called at the start of both the `scheduled` and `run` subcommand handlers.

### Execution Safety Note

Both Bash and PowerShell parse/load the entire script into memory before execution. Overwriting the script file on disk during `check_self_update()` / `Update-Self` does not affect the currently running process. The new code takes effect on the next invocation.

## Test Plan

### Strategy

Use `GEMINI_RAW_BASE` to point at a local HTTP server (`python3 -m http.server`) serving fixture files. Tests run in an isolated temp install directory.

### Directory Structure

```
tests/
  self-update/
    run-tests.sh          # macOS test runner
    run-tests.ps1         # Windows test runner
    fixtures/
      newer/              # VERSION=v99.0.0, patch.sh, patch.ps1
      same/               # VERSION copied from current
      malformed/          # VERSION with garbage content
```

### Test Cases

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 1 | Remote has newer version | Local VERSION=v0.0.1, remote=v99.0.0 | Files replaced, VERSION=v99.0.0, log contains "Self-updated" |
| 2 | Version identical | Local = remote VERSION | No file changes, no "Self-updated" log, timestamp updated |
| 3 | Cooldown not expired | last-update-check = now | No HTTP request made, immediate skip |
| 4 | Cooldown expired | last-update-check = 25 hours ago | Version check request made |
| 5 | Network unreachable | RAW_BASE = invalid address | Log contains "network error", patch logic continues normally |
| 6 | Partial download failure | Serve VERSION but not patch.sh | Log contains "download failed", local files unchanged |
| 7 | First check (no timestamp) | Delete last-update-check | Check executes, timestamp file created |
| 8 | No local VERSION file | Delete local VERSION | get_tool_version returns "unknown", update proceeds normally |

### Test Runner Pattern (macOS)

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
TEST_INSTALL_DIR=$(mktemp -d)
LOG_FILE="$HOME/Library/Logs/gemini-chrome-autoinstall.log"
PASS=0; FAIL=0

start_server() {
    cd "$1" && python3 -m http.server 18923 &>/dev/null &
    SERVER_PID=$!; sleep 0.5
}
stop_server() { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; }

assert_contains() {
    if grep -q "$2" "$1"; then ((PASS++)); echo "  PASS: $3"
    else ((FAIL++)); echo "  FAIL: $3 (expected '$2' in $1)"; fi
}
assert_not_contains() {
    if ! grep -q "$2" "$1"; then ((PASS++)); echo "  PASS: $3"
    else ((FAIL++)); echo "  FAIL: $3 (did not expect '$2' in $1)"; fi
}
assert_file_content() {
    local actual=$(cat "$1" | tr -d '\n')
    if [ "$actual" = "$2" ]; then ((PASS++)); echo "  PASS: $3"
    else ((FAIL++)); echo "  FAIL: $3 (expected '$2', got '$actual')"; fi
}

# Test 1: Remote newer version
# Test 2: Version identical
# ... (each test resets TEST_INSTALL_DIR state)

rm -rf "$TEST_INSTALL_DIR"
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
```

Windows test runner follows the same pattern with `Start-Process python` and PowerShell assertions.

## Changes Summary

| File | Change |
|------|--------|
| `patch.sh` | Add `RAW_BASE` variable, add `check_self_update()` function, call from `cmd_run()` |
| `patch.ps1` | Add `$RawBase` variable, add `Update-Self` function, call from `scheduled` and `run` handlers |
| `tests/self-update/` | New test directory with runners and fixtures |

## Key Paths (Updated)

| Item | macOS | Windows |
|------|-------|---------|
| Update check timestamp | `$INSTALL_DIR/last-update-check` | `$InstallDir\last-update-check` |
