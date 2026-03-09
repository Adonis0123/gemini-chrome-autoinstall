param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "uninstall", "status", "run", "manual", "watch", "scheduled", "help")]
    [string]$Command = "help"
)

$ErrorActionPreference = "Stop"
$TaskName = "GeminiChromeAutoPatch"
$ScriptPath = $PSScriptRoot
$LogFile = Join-Path $env:LOCALAPPDATA "gemini-chrome-autoinstall.log"
$LockFile = Join-Path $env:TEMP "gemini-chrome-autoinstall.lock"
$ActiveLockDir = Join-Path $env:TEMP "gemini-chrome-autoinstall.active.lock"
$VersionFile = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall\chrome-version.txt"
$LockTimeout = 300   # 5 minutes
$WaitInterval = 5    # seconds
$MaxWait = 600       # 10 minutes
$CoreInstallUrl = "https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.ps1"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-Cooldown {
    if (Test-Path $LockFile) {
        $lockTime = (Get-Item $LockFile).LastWriteTime
        $age = [int](New-TimeSpan -Start $lockTime -End (Get-Date)).TotalSeconds
        if ($age -lt $LockTimeout) {
            Write-Log "Skipped: last run was ${age}s ago (< ${LockTimeout}s)."
            return $false
        }
    }

    return $true
}

function Enter-ActiveLock {
    try {
        New-Item -Path $ActiveLockDir -ItemType Directory -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log "Skipped: another run is already in progress."
        Write-Host "Another run is already in progress."
        return $false
    }
}

function Exit-ActiveLock {
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
}

function Wait-ForChromeToExit {
    $waited = 0
    while (Get-Process chrome -ErrorAction SilentlyContinue) {
        if ($waited -ge $MaxWait) {
            Write-Log "Timeout: Chrome still running after ${MaxWait}s. Aborting."
            return $false
        }
        Write-Log "Chrome is running. Waiting... (${waited}s / ${MaxWait}s)"
        Start-Sleep -Seconds $WaitInterval
        $waited += $WaitInterval
    }

    return $true
}

function Invoke-CoreInstall {
    Write-Log "Chrome is closed. Running Gemini-in-Chrome install script..."
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

function Invoke-Enable {
    $patchScript = Join-Path $ScriptPath "patch.ps1"

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$patchScript`" scheduled"

    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Hours 4) `
        -RepetitionDuration ([TimeSpan]::MaxValue)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($triggerLogon, $triggerRepeat) `
        -Settings $settings `
        -Principal $principal `
        -Description "Automatically re-install Gemini-in-Chrome extension after Chrome updates" `
        -Force | Out-Null

    Write-Log "Enabled: scheduled task '$TaskName' registered (logon + every 4h)."
    Write-Host "Done. Scheduled task '$TaskName' is now enabled (logon + every 4h repeat)."
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

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Disabled: scheduled task '$TaskName' removed."
        Write-Host "Done. Scheduled task '$TaskName' has been removed."
    }
    catch {
        Write-Host "Task '$TaskName' not found or already removed."
    }
}

function Invoke-Status {
    Write-Host "=== Gemini Chrome AutoInstall Status ==="

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Host "  Task:      REGISTERED ($($task.State))"
    }
    catch {
        Write-Host "  Task:      NOT REGISTERED"
    }

    $watchProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "patch\.ps1.*watch" }
    if ($watchProcs) {
        Write-Host "  Watcher:   RUNNING (PID $($watchProcs[0].ProcessId))"
    } else {
        Write-Host "  Watcher:   not running"
    }

    if (Get-Process chrome -ErrorAction SilentlyContinue) {
        Write-Host "  Chrome:    RUNNING"
    }
    else {
        Write-Host "  Chrome:    not running"
    }

    $savedVer = Get-SavedChromeVersion
    $regVer = Get-ChromeRegistryVersion
    if ($savedVer) {
        Write-Host "  Saved ver: $savedVer"
    } else {
        Write-Host "  Saved ver: (none)"
    }
    if ($regVer) {
        Write-Host "  Reg ver:   $regVer"
    } else {
        Write-Host "  Reg ver:   (not found)"
    }

    if (Test-Path $ActiveLockDir) {
        Write-Host "  Running:   YES (patch is currently in progress)"
    }
    else {
        Write-Host "  Running:   no"
    }

    if (Test-Path $LockFile) {
        $lockTime = (Get-Item $LockFile).LastWriteTime
        $age = [int](New-TimeSpan -Start $lockTime -End (Get-Date)).TotalSeconds
        Write-Host "  Last run:  ${age}s ago"
    }
    else {
        Write-Host "  Last run:  never"
    }

    Write-Host "  Log:       $LogFile"
}

function Invoke-Uninstall {
    Invoke-Disable
    Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path $VersionFile -Force -ErrorAction SilentlyContinue
    $installDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"
    if (Test-Path $installDir) {
        Remove-Item -Path $installDir -Recurse -Force
    }
    Write-Log "Uninstalled: all files removed."
    Write-Host "Done. gemini-chrome-autoinstall has been completely removed."
}

function Invoke-Run {
    Write-Log "Run triggered."

    if (-not (Test-Cooldown)) {
        return $false
    }

    if (-not (Enter-ActiveLock)) {
        return $false
    }

    try {
        if (-not (Wait-ForChromeToExit)) {
            return $false
        }

        New-Item -Path $LockFile -ItemType File -Force | Out-Null
        return (Invoke-CoreInstall)
    }
    finally {
        Exit-ActiveLock
    }
}

function Invoke-Manual {
    Write-Log "Manual install triggered."

    if (Get-Process chrome -ErrorAction SilentlyContinue) {
        $response = Read-Host "Chrome is running. Close it to continue? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Log "Closing Chrome (user confirmed)..."
            Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
            if (-not (Wait-ForChromeToExit)) {
                Write-Host "Chrome did not exit in time. Please close it manually and retry."
                return
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
        New-Item -Path $LockFile -ItemType File -Force | Out-Null
        [void](Invoke-CoreInstall)
    }
    finally {
        Exit-ActiveLock
    }
}

function Get-ChromeRegistryVersion {
    try {
        $regPath = "HKCU:\Software\Google\Chrome\BLBeacon"
        return (Get-ItemProperty -Path $regPath -Name "version" -ErrorAction Stop).version
    }
    catch {
        return $null
    }
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

    # P/Invoke for RegNotifyChangeKeyValue
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class RegistryWatcher {
    public const int HKEY_CURRENT_USER = unchecked((int)0x80000001);
    public const int KEY_NOTIFY = 0x0010;
    public const int REG_NOTIFY_CHANGE_LAST_SET = 0x00000004;

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegOpenKeyEx(
        int hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegNotifyChangeKeyValue(
        IntPtr hKey, bool bWatchSubtree, int dwNotifyFilter, IntPtr hEvent, bool fAsynchronous);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(IntPtr hKey);
}
"@ -ErrorAction SilentlyContinue

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
        return
    }

    try {
        while ($true) {
            # Block until a value changes
            $notifyResult = [RegistryWatcher]::RegNotifyChangeKeyValue(
                $hKey, $false,
                [RegistryWatcher]::REG_NOTIFY_CHANGE_LAST_SET,
                [IntPtr]::Zero, $false
            )

            if ($notifyResult -ne 0) {
                Write-Log "Watch: RegNotifyChangeKeyValue failed (error $notifyResult). Exiting."
                break
            }

            $newVersion = Get-ChromeRegistryVersion
            $savedVersion = Get-SavedChromeVersion

            if ($newVersion -and $newVersion -ne $savedVersion) {
                Write-Log "Watch: Chrome version changed ($savedVersion -> $newVersion). Triggering patch."
                if (Invoke-Run) {
                    Save-ChromeVersion $newVersion
                }
            }

            # Re-register: must close and reopen the key for next notification
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
        Write-Log "Watch stopped."
    }
}

function Invoke-Scheduled {
    Write-Log "Scheduled task entry triggered."

    # Fallback poll FIRST: compare before watch can overwrite version file
    $currentVersion = Get-ChromeRegistryVersion
    $savedVersion = Get-SavedChromeVersion

    if ($currentVersion -and $savedVersion -and $currentVersion -ne $savedVersion) {
        Write-Log "Scheduled: version mismatch detected ($savedVersion -> $currentVersion). Triggering patch."
        if (Invoke-Run) {
            Save-ChromeVersion $currentVersion
        }
    } elseif ($currentVersion -and -not $savedVersion) {
        Write-Log "Scheduled: no saved version found. Saving current version $currentVersion."
        if (Invoke-Run) {
            Save-ChromeVersion $currentVersion
        }
    } else {
        Write-Log "Scheduled: no version change detected."
    }

    # Then ensure watch process is running
    $watchRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "patch\.ps1.*watch" }

    if (-not $watchRunning) {
        Write-Log "Scheduled: starting watch process in background."
        $patchScript = Join-Path $ScriptPath "patch.ps1"
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$patchScript`" watch" `
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
        Write-Host "  enable      Register scheduled task for auto-patching"
        Write-Host "  disable     Remove scheduled task and stop watcher"
        Write-Host "  uninstall   Disable and remove all installed files"
        Write-Host "  status      Show current status (incl. watcher and versions)"
        Write-Host "  run         Execute the patch (waits for Chrome to close)"
        Write-Host "  manual      Re-install immediately (offers to close Chrome)"
        Write-Host "  watch       Start registry watcher (runs as background daemon)"
    }
}
