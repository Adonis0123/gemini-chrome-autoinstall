param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "uninstall", "status", "run", "manual", "watch", "scheduled", "help")]
    [string]$Command = "help"
)

$ErrorActionPreference = "Stop"
$TaskName = "GeminiChromeAutoPatch"  # legacy: only used for cleanup of old scheduled task
$RunRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunRegName = "GeminiChromeAutoPatch"
$ScriptPath = $PSScriptRoot
$InstallDir = if ($env:GEMINI_INSTALL_DIR) { $env:GEMINI_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall" }
$LogFile = if ($env:GEMINI_LOG_FILE) { $env:GEMINI_LOG_FILE } else { Join-Path $env:LOCALAPPDATA "gemini-chrome-autoinstall.log" }
$LocalStatePath = if ($env:GEMINI_LOCAL_STATE_PATH) { $env:GEMINI_LOCAL_STATE_PATH } else { "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State" }
$ActiveLockDir = Join-Path $env:TEMP "gemini-chrome-autoinstall.active.lock"
$VersionFile = Join-Path $InstallDir "chrome-version.txt"
$PendingFile = Join-Path $InstallDir "pending"
$PatchedVersionFile = Join-Path $InstallDir "patched-version.txt"
$LastResultFile = Join-Path $InstallDir "last-result"
$ToolVersionFile = Join-Path $PSScriptRoot "VERSION"
$CoreInstallCommand = $env:GEMINI_CORE_INSTALL_CMD
$RetryInterval = 60  # seconds
$CoreInstallUrl = "https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.ps1"
$script:NeedsPatchReason = ""
$script:NeedsPatchChromeVersion = $null

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    $logDir = Split-Path $LogFile -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-NowIso {
    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-ToolVersion {
    if (Test-Path $ToolVersionFile) {
        return (Get-Content $ToolVersionFile -Raw).Trim()
    }
    return "unknown"
}

function Get-MetadataField {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $line = Get-Content -Path $Path -ErrorAction SilentlyContinue |
        Where-Object { $_ -like "$Key=*" } |
        Select-Object -First 1

    if ($line) {
        return $line.Substring($Key.Length + 1)
    }
    return $null
}

function Get-PendingField {
    param([string]$Key)
    Get-MetadataField -Path $PendingFile -Key $Key
}

function Get-PendingRetryCount {
    $value = Get-PendingField -Key "retry_count"
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed)) {
        return $parsed
    }
    return 0
}

function Write-PendingMetadata {
    param(
        [string]$Reason,
        [string]$FirstSeenAt,
        [string]$LastAttemptAt,
        [int]$RetryCount,
        [string]$DetectedVersion
    )

    $dir = Split-Path $PendingFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    @(
        "pending"
        "reason=$Reason"
        "first_seen_at=$FirstSeenAt"
        "last_attempt_at=$LastAttemptAt"
        "retry_count=$RetryCount"
        "detected_version=$DetectedVersion"
        "platform=windows"
    ) | Set-Content -Path $PendingFile
}

function Write-LastResult {
    param(
        [string]$Status,
        [string]$Reason,
        [string]$ChromeVersion,
        [string]$Hint
    )

    $dir = Split-Path $LastResultFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    @(
        "status=$Status"
        "reason=$Reason"
        "timestamp=$(Get-NowIso)"
        "chrome_version=$ChromeVersion"
        "tool_version=$(Get-ToolVersion)"
        "hint=$Hint"
    ) | Set-Content -Path $LastResultFile
}

function Get-LastResultField {
    param([string]$Key)
    Get-MetadataField -Path $LastResultFile -Key $Key
}

function Enter-ActiveLock {
    try {
        New-Item -Path $ActiveLockDir -ItemType Directory -ErrorAction Stop | Out-Null
        $PID | Out-File -FilePath (Join-Path $ActiveLockDir "pid") -NoNewline
        return $true
    }
    catch {
        # Check if the lock holder is still alive
        $pidFile = Join-Path $ActiveLockDir "pid"
        $stale = $false
        if (Test-Path $pidFile) {
            $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
            if ($oldPid) {
                $proc = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
                if (-not $proc) { $stale = $true }
            } else {
                $stale = $true
            }
        } else {
            # Lock dir exists but no pid file — stale from old version
            $stale = $true
        }

        if ($stale) {
            Write-Log "Removing stale active lock (previous run did not clean up)."
            Exit-ActiveLock
            try {
                New-Item -Path $ActiveLockDir -ItemType Directory -ErrorAction Stop | Out-Null
                $PID | Out-File -FilePath (Join-Path $ActiveLockDir "pid") -NoNewline
                return $true
            } catch {}
        }

        Write-Log "Skipped: another run is already in progress."
        Write-Host "Another run is already in progress."
        return $false
    }
}

function Exit-ActiveLock {
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
}

function Invoke-CoreInstall {
    Write-Log "Chrome is closed. Running Gemini-in-Chrome install script..."
    if ($CoreInstallCommand) {
        try {
            Invoke-Expression $CoreInstallCommand | Out-Null
            Write-Log "Install completed successfully."
            return $true
        }
        catch {
            Write-Log "Install failed: $_"
            return $false
        }
    }

    try {
        Invoke-RestMethod -Uri $CoreInstallUrl | Invoke-Expression
        Write-Log "Install completed successfully."
        return $true
    }
    catch {
        Write-Log "Install failed: $_"
        return $false
    }
}

function Get-ChromeRegistryVersion {
    if ($env:GEMINI_CHROME_VERSION) {
        return $env:GEMINI_CHROME_VERSION
    }

    try {
        $regPath = "HKCU:\Software\Google\Chrome\BLBeacon"
        return (Get-ItemProperty -Path $regPath -Name "version" -ErrorAction Stop).version
    }
    catch {
        return (Get-LocalStateVersion)
    }
}

function Get-LocalStateVersion {
    if (-not (Test-Path $LocalStatePath)) {
        return $null
    }

    try {
        $json = Get-Content -Path $LocalStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        return $json.last_version
    }
    catch {
        return $null
    }
}

function Get-LocalStateHealth {
    if (-not (Test-Path $LocalStatePath)) {
        return "unknown"
    }

    $raw = Get-Content -Path $LocalStatePath -Raw -ErrorAction SilentlyContinue
    if ($raw -match '"variations_country"\s*:\s*"us"' -and $raw -match '"is_glic_eligible"\s*:\s*true') {
        return "healthy"
    }
    if ($raw -match '"is_glic_eligible"\s*:\s*false' -or $raw -match '"variations_country"\s*:\s*"cn"') {
        return "drifted"
    }
    return "unknown"
}

function Test-IsChromeRunning {
    if ($env:GEMINI_CHROME_RUNNING) {
        return $env:GEMINI_CHROME_RUNNING -eq "1"
    }

    return [bool](Get-Process chrome -ErrorAction SilentlyContinue)
}

function Save-ChromeVersion {
    param([string]$Version)
    $dir = Split-Path $VersionFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $VersionFile -Value $Version -NoNewline
}

function Get-SavedChromeVersion {
    if (Test-Path $VersionFile) {
        return (Get-Content $VersionFile -Raw).Trim()
    }
    return $null
}

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
    $script:NeedsPatchChromeVersion = $chromeVer
    if (-not $chromeVer) {
        Write-Log "Cannot read Chrome version. Skipping."
        $script:NeedsPatchReason = "chrome_version_unavailable"
        return $false
    }
    $patchedVer = Get-PatchedVersion
    if ($chromeVer -eq $patchedVer) {
        Write-Log "Already patched for Chrome $chromeVer. Skipping."
        $script:NeedsPatchReason = "already_patched"
        return $false
    }
    $script:NeedsPatchReason = "needs_patch"
    return $true
}

function Set-Pending {
    $now = Get-NowIso
    $firstSeen = Get-PendingField -Key "first_seen_at"
    if (-not $firstSeen) {
        $firstSeen = $now
    }
    $retryCount = (Get-PendingRetryCount) + 1
    $detectedVersion = if ($script:NeedsPatchChromeVersion) { $script:NeedsPatchChromeVersion } else { Get-ChromeRegistryVersion }
    Write-PendingMetadata -Reason "chrome_running" -FirstSeenAt $firstSeen -LastAttemptAt $now -RetryCount $retryCount -DetectedVersion $detectedVersion
    Write-Log "Chrome is running. Created pending flag for deferred install."
}

function Remove-Pending {
    Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue
}

function Test-Pending {
    return (Test-Path $PendingFile)
}

function Invoke-PendingInstall {
    if (-not (Test-Pending)) { return }
    if (Test-IsChromeRunning) {
        $now = Get-NowIso
        $firstSeen = Get-PendingField -Key "first_seen_at"
        if (-not $firstSeen) {
            $firstSeen = $now
        }
        $retryCount = (Get-PendingRetryCount) + 1
        $detectedVersion = if ($script:NeedsPatchChromeVersion) { $script:NeedsPatchChromeVersion } else { Get-ChromeRegistryVersion }
        Write-PendingMetadata -Reason "chrome_running" -FirstSeenAt $firstSeen -LastAttemptAt $now -RetryCount $retryCount -DetectedVersion $detectedVersion
        Write-LastResult -Status "pending" -Reason "chrome_running" -ChromeVersion $detectedVersion -Hint "retry scheduled"
        return
    }
    if (-not (Test-NeedsPatch)) {
        Write-Log "Retry: no longer needs patching. Clearing pending."
        Remove-Pending
        Write-LastResult -Status "healthy" -Reason "already_patched" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "pending cleared"
        return
    }

    Write-Log "Retry: pending install found, Chrome is closed. Installing."
    if (-not (Enter-ActiveLock)) { return }

    try {
        if (Invoke-CoreInstall) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
            Write-Log "Retry: install completed successfully."
            Write-LastResult -Status "healthy" -Reason "patched" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "patched successfully"
        } else {
            Write-LastResult -Status "unknown" -Reason "core_install_failed" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "check core installer output"
        }
    }
    finally {
        Exit-ActiveLock
    }
}

function Invoke-Enable {
    $launcherVbs = Join-Path $ScriptPath "launcher.vbs"
    if (-not (Test-Path $launcherVbs)) {
        Write-Log "Error: launcher.vbs not found at $launcherVbs"
        Write-Host "Error: launcher.vbs not found. Please re-run install."
        return
    }

    $taskCommand = "wscript.exe `"$launcherVbs`" scheduled"

    # Remove legacy scheduled task if it exists (ignore errors - may need admin)
    try { schtasks /delete /tn $TaskName /f 2>&1 | Out-Null } catch {}

    # Register via HKCU Run key (no admin required)
    try {
        Set-ItemProperty -Path $RunRegPath -Name $RunRegName -Value $taskCommand -ErrorAction Stop
    } catch {
        Write-Log "Error: failed to set registry Run key: $_"
        Write-Host "Error: failed to register startup entry."
        return
    }

    Write-Log "Enabled: registry Run key '$RunRegName' registered (at logon)."
    Write-Host "Done. Startup entry '$RunRegName' is now enabled (at logon)."
}

function Stop-WatchProcess {
    $watchProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "patch\.ps1.*watch" }
    foreach ($proc in $watchProcs) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "Stopped watch process (PID $($proc.ProcessId))."
        } catch {}
    }
}

function Invoke-Disable {
    Stop-WatchProcess

    # Remove legacy scheduled task if it exists (ignore errors - may need admin)
    try { schtasks /delete /tn $TaskName /f 2>&1 | Out-Null } catch {}

    # Remove registry Run key
    $existing = Get-ItemProperty -Path $RunRegPath -Name $RunRegName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-ItemProperty -Path $RunRegPath -Name $RunRegName -ErrorAction SilentlyContinue
        Write-Log "Disabled: registry Run key '$RunRegName' removed."
        Write-Host "Done. Startup entry '$RunRegName' has been removed."
    } else {
        Write-Host "Startup entry '$RunRegName' not found or already removed."
    }
}

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
    Write-Host "  Tool version: $(Get-ToolVersion)"

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

    $lastStatus = Get-LastResultField -Key "status"
    if ($lastStatus) {
        Write-Host "  Last result:  $lastStatus"
    }

    Write-Host "  Log:          $LogFile"
}

function Invoke-Uninstall {
    Invoke-Disable
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
    Write-Log "Uninstalled: all files removed."
    Write-Host "Done. gemini-chrome-autoinstall has been completely removed."
}

function Invoke-Run {
    Write-Log "Run triggered."

    if (-not (Test-NeedsPatch)) {
        $health = Get-LocalStateHealth
        Write-LastResult -Status $health -Reason $script:NeedsPatchReason -ChromeVersion $script:NeedsPatchChromeVersion -Hint "no patch needed"
        return $false
    }

    if (-not (Enter-ActiveLock)) {
        Write-LastResult -Status "unknown" -Reason "active_lock_busy" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "another run in progress"
        return $false
    }

    try {
        if (Test-IsChromeRunning) {
            Set-Pending
            Write-LastResult -Status "pending" -Reason "chrome_running" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "close Chrome and wait for retry"
            return $false
        }

        $success = Invoke-CoreInstall
        if ($success) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
            Write-LastResult -Status "healthy" -Reason "patched" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "patched successfully"
        } else {
            Write-LastResult -Status "unknown" -Reason "core_install_failed" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "check core installer output"
        }
        return $success
    }
    finally {
        Exit-ActiveLock
    }
}

function Invoke-Manual {
    Write-Log "Manual install triggered."

    if (Test-IsChromeRunning) {
        $response = Read-Host "Chrome is running. Close it to continue? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Log "Closing Chrome (user confirmed)..."
            Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
            $waited = 0
            while (Test-IsChromeRunning) {
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
        Write-LastResult -Status "unknown" -Reason "active_lock_busy" -ChromeVersion (Get-ChromeRegistryVersion) -Hint "another run in progress"
        return
    }

    try {
        $success = Invoke-CoreInstall
        if ($success) {
            Save-PatchedVersion (Get-ChromeRegistryVersion)
            Remove-Pending
            Write-LastResult -Status "healthy" -Reason "manual_patched" -ChromeVersion (Get-ChromeRegistryVersion) -Hint "patched successfully"
        } else {
            Write-LastResult -Status "unknown" -Reason "manual_install_failed" -ChromeVersion (Get-ChromeRegistryVersion) -Hint "check core installer output"
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

    # P/Invoke for async RegNotifyChangeKeyValue
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
                        if (Test-IsChromeRunning) {
                            Set-Pending
                            Write-LastResult -Status "pending" -Reason "chrome_running" -ChromeVersion $newVersion -Hint "close Chrome and wait for retry"
                        } else {
                            if (Enter-ActiveLock) {
                                try {
                                    if (Invoke-CoreInstall) {
                                        Save-PatchedVersion $newVersion
                                        Remove-Pending
                                        Write-LastResult -Status "healthy" -Reason "patched" -ChromeVersion $newVersion -Hint "patched successfully"
                                    } else {
                                        Write-LastResult -Status "unknown" -Reason "core_install_failed" -ChromeVersion $newVersion -Hint "check core installer output"
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

switch ($Command) {
    "enable"    { Invoke-Enable }
    "disable"   { Invoke-Disable }
    "uninstall" { Invoke-Uninstall }
    "status"    { Invoke-Status }
    "run"       { Invoke-Run }
    "manual"    { Invoke-Manual }
    "watch"     { Invoke-Watch }
    "scheduled" { Invoke-Scheduled }
    default {
        Write-Host "Usage: .\patch.ps1 {enable|disable|uninstall|status|run|manual|watch}"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  enable      Register startup entry for auto-patching"
        Write-Host "  disable     Remove startup entry and stop watcher"
        Write-Host "  uninstall   Disable and remove all installed files"
        Write-Host "  status      Show current status (incl. watcher and versions)"
        Write-Host "  run         Execute the patch (creates pending if Chrome is running)"
        Write-Host "  manual      Re-install immediately (offers to close Chrome)"
        Write-Host "  watch       Start registry watcher (runs as background daemon)"
    }
}
