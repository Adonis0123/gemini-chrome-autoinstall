param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "uninstall", "status", "run", "manual", "help")]
    [string]$Command = "help"
)

$ErrorActionPreference = "Stop"
$TaskName = "GeminiChromeAutoPatch"
$ScriptPath = $PSScriptRoot
$LogFile = Join-Path $env:LOCALAPPDATA "gemini-chrome-autoinstall.log"
$LockFile = Join-Path $env:TEMP "gemini-chrome-autoinstall.lock"
$ActiveLockDir = Join-Path $env:TEMP "gemini-chrome-autoinstall.active.lock"
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
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$patchScript`" run"

    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggerLogon `
        -Settings $settings `
        -Description "Automatically re-install Gemini-in-Chrome extension after Chrome updates" `
        -Force | Out-Null

    Write-Log "Enabled: scheduled task '$TaskName' registered."
    Write-Host "Done. Scheduled task '$TaskName' is now enabled."
}

function Invoke-Disable {
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
        Write-Host "  Task:    REGISTERED ($($task.State))"
    }
    catch {
        Write-Host "  Task:    NOT REGISTERED"
    }

    if (Test-Path $ActiveLockDir) {
        Write-Host "  Running: YES (patch is currently in progress)"
    }
    else {
        Write-Host "  Running: no"
    }

    if (Test-Path $LockFile) {
        $lockTime = (Get-Item $LockFile).LastWriteTime
        $age = [int](New-TimeSpan -Start $lockTime -End (Get-Date)).TotalSeconds
        Write-Host "  Last run: ${age}s ago"
    }
    else {
        Write-Host "  Last run: never"
    }
}

function Invoke-Uninstall {
    Invoke-Disable
    Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $ActiveLockDir -Force -Recurse -ErrorAction SilentlyContinue
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
        return
    }

    if (-not (Enter-ActiveLock)) {
        return
    }

    try {
        if (-not (Wait-ForChromeToExit)) {
            return
        }

        New-Item -Path $LockFile -ItemType File -Force | Out-Null
        [void](Invoke-CoreInstall)
    }
    finally {
        Exit-ActiveLock
    }
}

function Invoke-Manual {
    Write-Log "Manual install triggered."

    if (Get-Process chrome -ErrorAction SilentlyContinue) {
        Write-Log "Skipped: Chrome is still running. Close it first, then rerun 'manual'."
        Write-Host "Chrome is still running. Close it first, then rerun: & `"$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" manual"
        return
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

switch ($Command) {
    "enable"    { Invoke-Enable }
    "disable"   { Invoke-Disable }
    "uninstall" { Invoke-Uninstall }
    "status"    { Invoke-Status }
    "run"       { Invoke-Run }
    "manual"    { Invoke-Manual }
    default {
        Write-Host "Usage: .\patch.ps1 {enable|disable|uninstall|status|run|manual}"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  enable      Register scheduled task for auto-patching"
        Write-Host "  disable     Remove scheduled task"
        Write-Host "  uninstall   Disable and remove all installed files"
        Write-Host "  status      Show current status"
        Write-Host "  run         Execute the patch (waits for Chrome to close)"
        Write-Host "  manual      Re-install immediately after you close Chrome"
    }
}
