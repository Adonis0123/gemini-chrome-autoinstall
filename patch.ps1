param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "uninstall", "status", "run", "help")]
    [string]$Command = "help"
)

$ErrorActionPreference = "Stop"
$TaskName = "GeminiChromeAutoPatch"
$ScriptPath = $PSScriptRoot
$LogFile = Join-Path $env:LOCALAPPDATA "gemini-chrome-autoinstall.log"
$LockFile = Join-Path $env:TEMP "gemini-chrome-autoinstall.lock"
$LockTimeout = 300   # 5 minutes
$WaitInterval = 5    # seconds
$MaxWait = 600       # 10 minutes

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
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
    $installDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"
    if (Test-Path $installDir) {
        Remove-Item -Path $installDir -Recurse -Force
    }
    Write-Log "Uninstalled: all files removed."
    Write-Host "Done. gemini-chrome-autoinstall has been completely removed."
}

function Invoke-Run {
    Write-Log "Run triggered."

    # Dedup: skip if lock file exists and is less than 5 minutes old
    if (Test-Path $LockFile) {
        $lockTime = (Get-Item $LockFile).LastWriteTime
        $age = [int](New-TimeSpan -Start $lockTime -End (Get-Date)).TotalSeconds
        if ($age -lt $LockTimeout) {
            Write-Log "Skipped: last run was ${age}s ago (< ${LockTimeout}s)."
            return
        }
    }

    # Wait for Chrome to close
    $waited = 0
    while (Get-Process chrome -ErrorAction SilentlyContinue) {
        if ($waited -ge $MaxWait) {
            Write-Log "Timeout: Chrome still running after ${MaxWait}s. Aborting."
            return
        }
        Write-Log "Chrome is running. Waiting... (${waited}s / ${MaxWait}s)"
        Start-Sleep -Seconds $WaitInterval
        $waited += $WaitInterval
    }

    # Create lock file
    New-Item -Path $LockFile -ItemType File -Force | Out-Null

    # Execute the install script
    Write-Log "Chrome is closed. Running Gemini-in-Chrome install script..."
    try {
        Invoke-RestMethod https://raw.githubusercontent.com/nicepkg/Gemini-in-Chrome/main/install.ps1 | Invoke-Expression
        Write-Log "Install completed successfully."
    }
    catch {
        Write-Log "Install failed: $_"
    }
}

switch ($Command) {
    "enable"    { Invoke-Enable }
    "disable"   { Invoke-Disable }
    "uninstall" { Invoke-Uninstall }
    "status"    { Invoke-Status }
    "run"       { Invoke-Run }
    default {
        Write-Host "Usage: .\patch.ps1 {enable|disable|uninstall|status|run}"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  enable      Register scheduled task for auto-patching"
        Write-Host "  disable     Remove scheduled task"
        Write-Host "  uninstall   Disable and remove all installed files"
        Write-Host "  status      Show current status"
        Write-Host "  run         Execute the patch (waits for Chrome to close)"
    }
}
