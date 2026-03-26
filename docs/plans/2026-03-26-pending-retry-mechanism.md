# Pending-Retry Mechanism Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix auto-patch not executing after Chrome updates by replacing time-based cooldown with version-based skip and adding a pending-retry mechanism for when Chrome is running.

**Architecture:** When a trigger fires (WatchPaths/boot/registry), compare Chrome's current version against last-patched version. If Chrome is running and needs patching, create a pending flag file and exit immediately (no 10-min wait). A KeepAlive LaunchAgent (macOS) or async watch loop (Windows) retries every 60 seconds until Chrome closes.

**Tech Stack:** Bash (macOS), PowerShell (Windows), launchd KeepAlive/PathState, Win32 async RegNotifyChangeKeyValue

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `patch.sh` | Modify | Version comparison, pending flag, retry subcommand, retry LaunchAgent, log fix |
| `patch.ps1` | Modify | Version comparison, pending flag, async watch with pending retry |

**No changes needed:** `install.sh`, `install.ps1`, `launcher.vbs` — they call `enable` which handles all setup.

**New runtime state files:**
- `~/.gemini-chrome-autoinstall/patched-version.txt` — last successfully patched Chrome version
- `~/.gemini-chrome-autoinstall/pending` — exists only when a deferred install is waiting

---

## Chunk 1: macOS (patch.sh)

### Task 1: Add version comparison and pending flag helpers

**Files:** Modify `patch.sh:1-16` (variables) and add new functions after line 96

- [ ] **Step 1: Add new variables, remove obsolete ones**

Replace the variables block (lines 10-15):

```bash
# Remove these:
COOLDOWN_FILE="/tmp/gemini-chrome-autoinstall.lock"
LOCK_TIMEOUT=300  # 5 minutes
WAIT_INTERVAL=5   # seconds
MAX_WAIT=600      # 10 minutes

# Add these:
INSTALL_DIR="$HOME/.gemini-chrome-autoinstall"
PENDING_FILE="$INSTALL_DIR/pending"
PATCHED_VERSION_FILE="$INSTALL_DIR/patched-version.txt"
RETRY_LABEL="com.gemini-chrome-autoinstall.retry"
RETRY_PLIST="$RETRY_LABEL.plist"
```

Keep `ACTIVE_LOCK_DIR`, `LOG_FILE`, `CORE_INSTALL_URL` unchanged.

- [ ] **Step 2: Fix log() double-write**

Replace `log()` (line 18-20):

```bash
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}
```

- [ ] **Step 3: Add version comparison functions**

Add after `run_core_install()` (after line 106):

```bash
get_chrome_version() {
    /usr/libexec/PlistBuddy -c "Print :KSVersion" \
        "/Applications/Google Chrome.app/Contents/Info.plist" 2>/dev/null
}

get_patched_version() {
    cat "$PATCHED_VERSION_FILE" 2>/dev/null
}

save_patched_version() {
    mkdir -p "$(dirname "$PATCHED_VERSION_FILE")"
    printf '%s' "$1" > "$PATCHED_VERSION_FILE"
}

needs_patch() {
    local chrome_ver
    chrome_ver=$(get_chrome_version)
    if [ -z "$chrome_ver" ]; then
        log "Cannot read Chrome version. Skipping."
        return 1
    fi
    local patched_ver
    patched_ver=$(get_patched_version)
    if [ "$chrome_ver" = "$patched_ver" ]; then
        log "Already patched for Chrome $chrome_ver. Skipping."
        return 1
    fi
    return 0
}

create_pending() {
    mkdir -p "$(dirname "$PENDING_FILE")"
    get_chrome_version > "$PENDING_FILE"
    log "Chrome is running. Created pending flag for deferred install."
}

remove_pending() {
    rm -f "$PENDING_FILE"
}
```

- [ ] **Step 4: Remove obsolete functions**

Delete `check_cooldown()` (lines 22-36) and `wait_for_chrome_to_close()` (lines 85-96). These are fully replaced by the new mechanism.

- [ ] **Step 5: Verify syntax**

Run: `bash -n patch.sh`
Expected: no output (clean parse)

---

### Task 2: Rewrite cmd_run, add cmd_retry, update cmd_manual

**Files:** Modify `patch.sh:247-315` (cmd_run, cmd_manual) and add cmd_retry

- [ ] **Step 1: Rewrite cmd_run**

Replace `cmd_run()` (lines 247-273):

```bash
cmd_run() {
    log "Run triggered."

    if ! needs_patch; then
        return 0
    fi

    if ! acquire_active_lock; then
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        create_pending
    else
        if run_core_install; then
            save_patched_version "$(get_chrome_version)"
            remove_pending
        else
            status=1
        fi
    fi

    disarm_active_lock_cleanup
    release_active_lock
    return $status
}
```

Key changes: no cooldown check, no waiting. If Chrome is running → create pending → exit immediately.

- [ ] **Step 2: Add cmd_retry**

Add after `cmd_run()`:

```bash
cmd_retry() {
    if [ ! -f "$PENDING_FILE" ]; then
        return 0
    fi

    log "Retry: pending install found."

    if ! needs_patch; then
        log "Retry: no longer needs patching. Clearing pending."
        remove_pending
        return 0
    fi

    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        log "Retry: Chrome still running. Will retry later."
        return 0
    fi

    if ! acquire_active_lock; then
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if run_core_install; then
        save_patched_version "$(get_chrome_version)"
        remove_pending
        log "Retry: install completed successfully."
    else
        status=1
    fi

    disarm_active_lock_cleanup
    release_active_lock
    return $status
}
```

- [ ] **Step 3: Update cmd_manual**

Replace `cmd_manual()` (lines 275-315):

```bash
cmd_manual() {
    log "Manual install triggered."

    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        printf "Chrome is running. Close it to continue? (Y/N): "
        read -r response < /dev/tty
        if [ "$response" = "Y" ] || [ "$response" = "y" ]; then
            log "Closing Chrome (user confirmed)..."
            killall "Google Chrome" 2>/dev/null
            # Brief wait for Chrome to exit
            local waited=0
            while pgrep -x "Google Chrome" >/dev/null 2>&1; do
                if [ "$waited" -ge 30 ]; then
                    echo "Chrome did not exit in time. Please close it manually and retry."
                    return 1
                fi
                sleep 2
                waited=$(( waited + 2 ))
            done
        else
            echo "Cancelled."
            return 0
        fi
    fi

    if ! acquire_active_lock; then
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if run_core_install; then
        save_patched_version "$(get_chrome_version)"
        remove_pending
    else
        status=1
    fi

    disarm_active_lock_cleanup
    release_active_lock

    if [ "$status" -eq 0 ]; then
        log "Reopening Chrome..."
        open -a "Google Chrome"
    fi

    return $status
}
```

- [ ] **Step 4: Update case dispatch**

Add `retry` to the case statement (line 318):

```bash
case "${1:-help}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    retry)     cmd_retry ;;
    manual)    cmd_manual ;;
    *)
        echo "Usage: $0 {enable|disable|uninstall|status|run|retry|manual}"
        ...
esac
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n patch.sh`

---

### Task 3: Update cmd_enable/disable/status/uninstall for retry agent

**Files:** Modify `patch.sh` cmd_enable, cmd_disable, cmd_status, cmd_uninstall

- [ ] **Step 1: Update cmd_enable — add retry LaunchAgent**

Add unload for retry agent at line 113, and add the third plist after the watcher plist (after line 159). Then load it alongside the others.

```bash
cmd_enable() {
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Unload existing agents first (idempotent re-install)
    launchctl unload "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" 2>/dev/null || true

    cat > "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${BOOT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    cat > "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${WATCHER_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>run</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>/Applications/Google Chrome.app/Contents/Info.plist</string>
	</array>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    cat > "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${RETRY_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>retry</string>
	</array>
	<key>KeepAlive</key>
	<dict>
		<key>PathState</key>
		<dict>
			<key>${HOME}/.gemini-chrome-autoinstall/pending</key>
			<true/>
		</dict>
	</dict>
	<key>ThrottleInterval</key>
	<integer>60</integer>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    launchctl load "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$RETRY_PLIST"

    log "Enabled: all LaunchAgents loaded."
    echo "Done. All LaunchAgents are now enabled."
}
```

Note: `StandardOutPath` removed from all plists (log() writes directly to file). Only `StandardErrorPath` kept for unexpected bash errors.

- [ ] **Step 2: Update cmd_disable**

```bash
cmd_disable() {
    if [ -f "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$RETRY_PLIST"
    fi

    log "Disabled: all LaunchAgents unloaded and removed."
    echo "Done. All LaunchAgents are now disabled."
}
```

- [ ] **Step 3: Update cmd_status**

Replace entire `cmd_status()`:

```bash
cmd_status() {
    echo "=== Gemini Chrome AutoInstall Status ==="

    local boot_loaded=false
    local watcher_loaded=false
    local retry_loaded=false

    if launchctl list 2>/dev/null | grep -q "$BOOT_LABEL"; then
        boot_loaded=true
    fi
    if launchctl list 2>/dev/null | grep -q "$WATCHER_LABEL"; then
        watcher_loaded=true
    fi
    if launchctl list 2>/dev/null | grep -q "$RETRY_LABEL"; then
        retry_loaded=true
    fi

    echo "  Boot agent:    $( $boot_loaded && echo LOADED || echo 'NOT LOADED' )"
    echo "  Watcher agent: $( $watcher_loaded && echo LOADED || echo 'NOT LOADED' )"
    echo "  Retry agent:   $( $retry_loaded && echo LOADED || echo 'NOT LOADED' )"

    local chrome_ver
    chrome_ver=$(get_chrome_version)
    local patched_ver
    patched_ver=$(get_patched_version)
    echo "  Chrome ver:    ${chrome_ver:-unknown}"
    echo "  Patched ver:   ${patched_ver:-never}"

    if [ -f "$PENDING_FILE" ]; then
        echo "  Pending:       YES (waiting for Chrome to close)"
    else
        echo "  Pending:       no"
    fi

    if [ -d "$ACTIVE_LOCK_DIR" ]; then
        echo "  Running:       YES (patch in progress)"
    else
        echo "  Running:       no"
    fi
}
```

- [ ] **Step 4: Update cmd_uninstall**

```bash
cmd_uninstall() {
    cmd_disable
    rm -rf "$ACTIVE_LOCK_DIR" 2>/dev/null || true
    rm -rf "$HOME/.gemini-chrome-autoinstall"
    log "Uninstalled: all files removed."
    echo "Done. gemini-chrome-autoinstall has been completely removed."
}
```

Removed `rm -f "$COOLDOWN_FILE"` (no longer exists). `rm -rf $INSTALL_DIR` already cleans pending + patched-version files.

- [ ] **Step 5: Verify syntax and commit**

Run: `bash -n patch.sh`

```bash
git add patch.sh
git commit -m "🐛 fix(mac): replace cooldown with version-based skip and pending-retry mechanism

- Replace time-based cooldown with Chrome version comparison
- When Chrome is running, create pending flag and exit immediately (no 10-min wait)
- Add retry LaunchAgent with KeepAlive/PathState that retries every 60s when pending
- Fix log double-write by removing tee (write directly to log file)
- Remove StandardOutPath from LaunchAgent plists (only keep StandardErrorPath)"
```

---

### Task 4: macOS Verification

- [ ] **Step 1: Reload agents**

```bash
~/.gemini-chrome-autoinstall/patch.sh disable
# Copy updated patch.sh to install dir
cp patch.sh ~/.gemini-chrome-autoinstall/patch.sh
chmod +x ~/.gemini-chrome-autoinstall/patch.sh
~/.gemini-chrome-autoinstall/patch.sh enable
```

- [ ] **Step 2: Verify all three agents loaded**

```bash
launchctl list | grep gemini
```

Expected: 3 lines (boot, watcher, retry)

- [ ] **Step 3: Verify status command shows version info**

```bash
~/.gemini-chrome-autoinstall/patch.sh status
```

Expected: Chrome ver, patched ver, pending status, retry agent status

- [ ] **Step 4: Test "already patched" skip**

```bash
# Set patched version to current Chrome version
~/.gemini-chrome-autoinstall/patch.sh run
tail -3 ~/Library/Logs/gemini-chrome-autoinstall.log
```

If already patched: Expected log "Already patched for Chrome X. Skipping."

- [ ] **Step 5: Test pending creation (Chrome running)**

```bash
# Clear patched version to force needs_patch=true
rm -f ~/.gemini-chrome-autoinstall/patched-version.txt
# Trigger with Chrome open
touch "/Applications/Google Chrome.app/Contents/Info.plist"
sleep 3
# Check pending was created
ls -la ~/.gemini-chrome-autoinstall/pending
tail -5 ~/Library/Logs/gemini-chrome-autoinstall.log
```

Expected: pending file exists, log shows "Created pending flag"

- [ ] **Step 6: Test retry agent activates on pending**

```bash
# Retry agent should start running because pending file exists
launchctl print gui/$(id -u)/com.gemini-chrome-autoinstall.retry 2>&1 | grep -E 'state|runs'
tail -5 ~/Library/Logs/gemini-chrome-autoinstall.log
```

Expected: retry agent runs, log shows "Retry: Chrome still running. Will retry later." every ~60s

- [ ] **Step 7: Test retry completes when Chrome closes**

```bash
# Close Chrome, wait for retry to pick up
# (close Chrome manually via Cmd+Q)
# Wait up to 60 seconds, then check
sleep 65
tail -10 ~/Library/Logs/gemini-chrome-autoinstall.log
ls ~/.gemini-chrome-autoinstall/pending 2>&1
cat ~/.gemini-chrome-autoinstall/patched-version.txt
```

Expected: log shows "Install completed", pending file removed, patched-version.txt matches Chrome version

- [ ] **Step 8: Test log no longer double-writes**

```bash
tail -20 ~/Library/Logs/gemini-chrome-autoinstall.log | sort | uniq -c | sort -rn | head -5
```

Expected: all counts = 1 (no duplicates)

---

## Chunk 2: Windows (patch.ps1)

### Task 5: Add version comparison and pending flag helpers

**Files:** Modify `patch.ps1:1-19` (variables) and add new functions

- [ ] **Step 1: Add new variables, remove obsolete ones**

Replace variables block (lines 13-18):

```powershell
# Remove these:
$LockFile = Join-Path $env:TEMP "gemini-chrome-autoinstall.lock"
$LockTimeout = 300
$WaitInterval = 5
$MaxWait = 600

# Add these:
$InstallDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"
$PendingFile = Join-Path $InstallDir "pending"
$PatchedVersionFile = Join-Path $InstallDir "patched-version.txt"
$RetryInterval = 60  # seconds
```

Keep `$ActiveLockDir`, `$LogFile`, `$CoreInstallUrl`, `$VersionFile` unchanged.

- [ ] **Step 2: Remove obsolete functions**

Delete `Test-Cooldown` (lines 29-40) and `Wait-ForChromeToExit` (lines 85-98).

- [ ] **Step 3: Add version comparison and pending functions**

Add after `Get-SavedChromeVersion`:

```powershell
function Get-PatchedVersion {
    if (Test-Path $PatchedVersionFile) {
        return (Get-Content $PatchedVersionFile -Raw).Trim()
    }
    return $null
}

function Save-PatchedVersion {
    param([string]$Version)
    $dir = Split-Path $PatchedVersionFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $PatchedVersionFile -Value $Version -NoNewline
}

function Test-NeedsPatch {
    $chromeVer = Get-ChromeRegistryVersion
    if (-not $chromeVer) {
        Write-Log "Cannot read Chrome version. Skipping."
        return $false
    }
    $patchedVer = Get-PatchedVersion
    if ($chromeVer -eq $patchedVer) {
        Write-Log "Already patched for Chrome $chromeVer. Skipping."
        return $false
    }
    return $true
}

function Set-Pending {
    $dir = Split-Path $PendingFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Get-ChromeRegistryVersion | Set-Content -Path $PendingFile -NoNewline
    Write-Log "Chrome is running. Created pending flag for deferred install."
}

function Remove-Pending {
    Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue
}

function Test-Pending {
    return (Test-Path $PendingFile)
}
```

- [ ] **Step 4: Verify syntax**

Run: `powershell -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('patch.ps1', [ref]$null, [ref]$null) }"`

---

### Task 6: Rewrite Invoke-Run and Invoke-Watch

**Files:** Modify `patch.ps1` Invoke-Run (lines 237-259) and Invoke-Watch (lines 323-420)

- [ ] **Step 1: Rewrite Invoke-Run**

```powershell
function Invoke-Run {
    Write-Log "Run triggered."

    if (-not (Test-NeedsPatch)) {
        return $false
    }

    if (-not (Enter-ActiveLock)) {
        return $false
    }

    try {
        if (Get-Process chrome -ErrorAction SilentlyContinue) {
            Set-Pending
            return $false
        }

        $success = Invoke-CoreInstall
        if ($success) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
        }
        return $success
    }
    finally {
        Exit-ActiveLock
    }
}
```

- [ ] **Step 2: Add helper for pending retry install**

```powershell
function Invoke-PendingInstall {
    if (-not (Test-Pending)) { return }
    if (Get-Process chrome -ErrorAction SilentlyContinue) { return }
    if (-not (Test-NeedsPatch)) {
        Write-Log "Retry: no longer needs patching. Clearing pending."
        Remove-Pending
        return
    }

    Write-Log "Retry: pending install found, Chrome is closed. Installing."
    if (-not (Enter-ActiveLock)) { return }

    try {
        if (Invoke-CoreInstall) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
            Write-Log "Retry: install completed successfully."
        }
    }
    finally {
        Exit-ActiveLock
    }
}
```

- [ ] **Step 3: Rewrite Invoke-Watch with async registry + pending retry**

Replace entire `Invoke-Watch` function:

```powershell
function Invoke-Watch {
    Write-Log "Watch started: monitoring registry for Chrome version changes."

    $currentVersion = Get-ChromeRegistryVersion
    if (-not $currentVersion) {
        Write-Log "Watch: Chrome registry key not found. Exiting."
        return
    }
    if (-not (Get-SavedChromeVersion)) {
        Save-ChromeVersion $currentVersion
        Write-Log "Watch: initialized version file = $currentVersion"
    }
    Write-Log "Watch: current Chrome version = $currentVersion"

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class RegistryWatcher {
    public const int HKEY_CURRENT_USER = unchecked((int)0x80000001);
    public const int KEY_NOTIFY = 0x0010;
    public const int REG_NOTIFY_CHANGE_LAST_SET = 0x00000004;
    public const int WAIT_OBJECT_0 = 0x00000000;
    public const int WAIT_TIMEOUT = 0x00000102;

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegOpenKeyEx(
        int hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegNotifyChangeKeyValue(
        IntPtr hKey, bool bWatchSubtree, int dwNotifyFilter, IntPtr hEvent, bool fAsynchronous);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(IntPtr hKey);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateEvent(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int WaitForSingleObject(IntPtr hHandle, int dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ResetEvent(IntPtr hEvent);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@ -ErrorAction SilentlyContinue

    $hEvent = [RegistryWatcher]::CreateEvent([IntPtr]::Zero, $true, $false, $null)
    if ($hEvent -eq [IntPtr]::Zero) {
        Write-Log "Watch: failed to create event. Exiting."
        return
    }

    $hKey = [IntPtr]::Zero
    $result = [RegistryWatcher]::RegOpenKeyEx(
        [RegistryWatcher]::HKEY_CURRENT_USER,
        "Software\Google\Chrome\BLBeacon",
        0,
        [RegistryWatcher]::KEY_NOTIFY,
        [ref]$hKey
    )

    if ($result -ne 0) {
        Write-Log "Watch: failed to open registry key (error $result). Exiting."
        [RegistryWatcher]::CloseHandle($hEvent) | Out-Null
        return
    }

    try {
        while ($true) {
            # Register async notification
            $notifyResult = [RegistryWatcher]::RegNotifyChangeKeyValue(
                $hKey, $false,
                [RegistryWatcher]::REG_NOTIFY_CHANGE_LAST_SET,
                $hEvent, $true
            )

            if ($notifyResult -ne 0) {
                Write-Log "Watch: RegNotifyChangeKeyValue failed (error $notifyResult). Exiting."
                break
            }

            # Wait with timeout for pending retry
            $timeoutMs = $RetryInterval * 1000
            $waitResult = [RegistryWatcher]::WaitForSingleObject($hEvent, $timeoutMs)

            if ($waitResult -eq [RegistryWatcher]::WAIT_OBJECT_0) {
                # Registry changed
                [RegistryWatcher]::ResetEvent($hEvent) | Out-Null

                $newVersion = Get-ChromeRegistryVersion
                $savedVersion = Get-SavedChromeVersion

                if ($newVersion -and $newVersion -ne $savedVersion) {
                    Write-Log "Watch: Chrome version changed ($savedVersion -> $newVersion). Triggering patch."
                    Save-ChromeVersion $newVersion

                    if (Test-NeedsPatch) {
                        if (Get-Process chrome -ErrorAction SilentlyContinue) {
                            Set-Pending
                        } else {
                            if (Enter-ActiveLock) {
                                try {
                                    if (Invoke-CoreInstall) {
                                        Save-PatchedVersion $newVersion
                                        Remove-Pending
                                    }
                                } finally {
                                    Exit-ActiveLock
                                }
                            }
                        }
                    }
                }
            } elseif ($waitResult -eq [RegistryWatcher]::WAIT_TIMEOUT) {
                # Timeout — check for pending install
                Invoke-PendingInstall
            } else {
                Write-Log "Watch: WaitForSingleObject failed ($waitResult). Exiting."
                break
            }

            # Re-register: close and reopen key
            [RegistryWatcher]::RegCloseKey($hKey) | Out-Null
            $hKey = [IntPtr]::Zero
            $result = [RegistryWatcher]::RegOpenKeyEx(
                [RegistryWatcher]::HKEY_CURRENT_USER,
                "Software\Google\Chrome\BLBeacon",
                0,
                [RegistryWatcher]::KEY_NOTIFY,
                [ref]$hKey
            )
            if ($result -ne 0) {
                Write-Log "Watch: failed to reopen registry key (error $result). Exiting."
                break
            }
        }
    }
    finally {
        if ($hKey -ne [IntPtr]::Zero) {
            [RegistryWatcher]::RegCloseKey($hKey) | Out-Null
        }
        if ($hEvent -ne [IntPtr]::Zero) {
            [RegistryWatcher]::CloseHandle($hEvent) | Out-Null
        }
        Write-Log "Watch stopped."
    }
}
```

- [ ] **Step 4: Verify syntax**

Run: `powershell -Command "& { [System.Management.Automation.Language.Parser]::ParseFile('patch.ps1', [ref]$null, [ref]$errors); if ($errors) { $errors | ForEach-Object { Write-Host $_ } } else { Write-Host 'OK' } }"`

---

### Task 7: Update remaining Windows commands

**Files:** Modify `patch.ps1` Invoke-Scheduled, Invoke-Manual, Invoke-Status, Invoke-Uninstall

- [ ] **Step 1: Update Invoke-Scheduled to check pending on startup**

```powershell
function Invoke-Scheduled {
    Write-Log "Scheduled entry triggered."

    # Attempt pending install on startup (Chrome may be closed now)
    Invoke-PendingInstall

    # Ensure watch process is running
    $watchRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "patch\.ps1.*watch" }

    if (-not $watchRunning) {
        Write-Log "Scheduled: starting watch process in background."
        $launcherVbs = Join-Path $ScriptPath "launcher.vbs"
        Start-Process -FilePath "wscript.exe" `
            -ArgumentList "`"$launcherVbs`" watch" `
            -WindowStyle Hidden
    } else {
        Write-Log "Scheduled: watch process already running."
    }
}
```

- [ ] **Step 2: Update Invoke-Manual**

```powershell
function Invoke-Manual {
    Write-Log "Manual install triggered."

    if (Get-Process chrome -ErrorAction SilentlyContinue) {
        $response = Read-Host "Chrome is running. Close it to continue? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Log "Closing Chrome (user confirmed)..."
            Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
            $waited = 0
            while (Get-Process chrome -ErrorAction SilentlyContinue) {
                if ($waited -ge 30) {
                    Write-Host "Chrome did not exit in time. Please close it manually and retry."
                    return
                }
                Start-Sleep -Seconds 2
                $waited += 2
            }
        } else {
            Write-Host "Cancelled."
            return
        }
    }

    if (-not (Enter-ActiveLock)) {
        return
    }

    try {
        $success = Invoke-CoreInstall
        if ($success) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
        }
    }
    finally {
        Exit-ActiveLock
    }

    if ($success) {
        Write-Log "Reopening Chrome..."
        Start-Process "chrome"
    }
}
```

- [ ] **Step 3: Update Invoke-Status**

```powershell
function Invoke-Status {
    Write-Host "=== Gemini Chrome AutoInstall Status ==="

    $runEntry = Get-ItemProperty -Path $RunRegPath -Name $RunRegName -ErrorAction SilentlyContinue
    if ($runEntry) {
        Write-Host "  Startup:      REGISTERED (Registry Run key)"
    } else {
        Write-Host "  Startup:      NOT REGISTERED"
    }

    $watchProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "patch\.ps1.*watch" }
    if ($watchProcs) {
        Write-Host "  Watcher:      RUNNING (PID $($watchProcs[0].ProcessId))"
    } else {
        Write-Host "  Watcher:      not running"
    }

    $chromeVer = Get-ChromeRegistryVersion
    $patchedVer = Get-PatchedVersion
    Write-Host "  Chrome ver:   $( if ($chromeVer) { $chromeVer } else { '(not found)' } )"
    Write-Host "  Patched ver:  $( if ($patchedVer) { $patchedVer } else { 'never' } )"

    if (Test-Pending) {
        Write-Host "  Pending:      YES (waiting for Chrome to close)"
    } else {
        Write-Host "  Pending:      no"
    }

    if (Test-Path $ActiveLockDir) {
        Write-Host "  Running:      YES (patch in progress)"
    } else {
        Write-Host "  Running:      no"
    }

    Write-Host "  Log:          $LogFile"
}
```

- [ ] **Step 4: Update Invoke-Uninstall**

```powershell
function Invoke-Uninstall {
    Invoke-Disable
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
    $installDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"
    if (Test-Path $installDir) {
        Remove-Item -Path $installDir -Recurse -Force
    }
    Write-Log "Uninstalled: all files removed."
    Write-Host "Done. gemini-chrome-autoinstall has been completely removed."
}
```

Removed `$LockFile` and `$VersionFile` cleanup (handled by `$installDir` removal).

- [ ] **Step 5: Update ValidateSet and switch**

Add `retry` is NOT needed for Windows (watch daemon handles retry internally). No dispatch changes needed.

- [ ] **Step 6: Verify syntax and commit**

```bash
git add patch.ps1
git commit -m "🐛 fix(win): replace cooldown with version-based skip and pending-retry in watch daemon

- Replace time-based cooldown with Chrome version comparison
- When Chrome is running, create pending flag instead of waiting 10 minutes
- Watch daemon uses async RegNotifyChangeKeyValue with 60s timeout for pending retry
- Scheduled command checks pending on startup for cross-session recovery"
```

---

## Chunk 3: Verification & Cleanup

### Task 8: Update CLAUDE.md

**Files:** Modify `CLAUDE.md`

- [ ] **Step 1: Update architecture section**

Update the concurrency control section to reflect version-based skip replacing cooldown, and add the retry agent to the macOS trigger flow. Update key paths table:

| Item | macOS | Windows |
|------|-------|---------|
| Pending flag | `~/.gemini-chrome-autoinstall/pending` | `%USERPROFILE%\.gemini-chrome-autoinstall\pending` |
| Patched version | `~/.gemini-chrome-autoinstall/patched-version.txt` | `%USERPROFILE%\.gemini-chrome-autoinstall\patched-version.txt` |

Remove references to cooldown lock files.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: update architecture for pending-retry mechanism"
```
