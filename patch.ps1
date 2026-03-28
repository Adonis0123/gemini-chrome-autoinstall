param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "uninstall", "status", "run", "retry", "manual", "watch", "scheduled", "help")]
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
$ChromeUpdateClientPath = "HKCU:\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}"
$ChromeUpdateRegistrySubKey = "Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}"
$ChromeUpdateVersionName = "pv"
$RetryInterval = 60  # seconds
$CoreInstallUrl = "https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.ps1"
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

function Get-PendingPatchReason {
    $patchReason = Get-PendingField -Key "patch_reason"
    if ($patchReason) {
        return $patchReason
    }

    $pendingReason = Get-PendingField -Key "reason"
    if ($pendingReason) {
        return $pendingReason
    }

    return "unknown"
}

function Get-PendingAge {
    if (-not (Test-Path $PendingFile)) {
        return "n/a"
    }

    $firstSeenAt = Get-PendingField -Key "first_seen_at"
    if (-not $firstSeenAt) {
        return "unknown"
    }

    try {
        $firstSeen = [DateTime]::Parse($firstSeenAt).ToUniversalTime()
        $age = [Math]::Max([int]([DateTime]::UtcNow - $firstSeen).TotalSeconds, 0)
        return "$age" + "s"
    }
    catch {
        return "unknown"
    }
}

function Write-PendingMetadata {
    param(
        [string]$Reason,
        [string]$PatchReason,
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
        "patch_reason=$PatchReason"
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
        $overrideTarget = $CoreInstallCommand.Trim()
        if (-not $overrideTarget) {
            Write-Log "Install failed: GEMINI_CORE_INSTALL_CMD is empty."
            return $false
        }

        try {
            $resolvedTarget = (Resolve-Path -LiteralPath $overrideTarget -ErrorAction Stop).Path
        }
        catch {
            Write-Log "Install failed: GEMINI_CORE_INSTALL_CMD target '$overrideTarget' does not exist."
            return $false
        }

        if (Test-Path -LiteralPath $resolvedTarget -PathType Container) {
            Write-Log "Install failed: GEMINI_CORE_INSTALL_CMD target '$resolvedTarget' is a directory."
            return $false
        }

        try {
            & $resolvedTarget | Out-Null
            if (-not $?) {
                $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }
                throw "override exited with code $exitCode"
            }
            Write-Log "Install completed successfully."
            return $true
        }
        catch {
            Write-Log "Install failed: GEMINI_CORE_INSTALL_CMD target '$resolvedTarget' error: $_"
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

function Get-ChromeVersion {
    if ($env:GEMINI_CHROME_VERSION) {
        return $env:GEMINI_CHROME_VERSION
    }

    try {
        return (Get-ItemProperty -Path $ChromeUpdateClientPath -Name $ChromeUpdateVersionName -ErrorAction Stop).$ChromeUpdateVersionName
    }
    catch {
        return (Get-LocalStateVersion)
    }
}

function Get-ChromeVersionOrUnknown {
    $chromeVersion = Get-ChromeVersion
    if ($chromeVersion) {
        return $chromeVersion
    }
    return "unknown"
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

function Get-PatchState {
    if (-not (Test-Path $LocalStatePath)) {
        return @{ state = "unknown"; reason = "local_state_missing" }
    }

    try {
        $json = Get-Content -Path $LocalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return @{ state = "unknown"; reason = "invalid_json" }
    }

    if (-not ($json.PSObject.Properties.Name -contains "variations_country") -or
        -not ($json.PSObject.Properties.Name -contains "variations_permanent_consistency_country")) {
        return @{ state = "unknown"; reason = "missing_required_fields" }
    }

    $variationsCountry = [string]$json.variations_country
    $permanentCountryValues = @($json.variations_permanent_consistency_country)
    if ($permanentCountryValues.Count -eq 0) {
        return @{ state = "unknown"; reason = "missing_required_fields" }
    }
    $permanentCountry = [string]$permanentCountryValues[-1]

    $hasGlicTrue = $false
    $hasGlicFalse = $false
    if ($json.profile -and $json.profile.info_cache) {
        foreach ($property in $json.profile.info_cache.PSObject.Properties) {
            $profileValue = $property.Value
            if ($profileValue -and ($profileValue.PSObject.Properties.Name -contains "is_glic_eligible")) {
                if ($profileValue.is_glic_eligible -eq $true) {
                    $hasGlicTrue = $true
                }
                elseif ($profileValue.is_glic_eligible -eq $false) {
                    $hasGlicFalse = $true
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($variationsCountry) -or
        [string]::IsNullOrWhiteSpace($permanentCountry) -or
        (-not $hasGlicTrue -and -not $hasGlicFalse)) {
        return @{ state = "unknown"; reason = "missing_required_fields" }
    }

    if ($variationsCountry -ne "us") {
        return @{ state = "drifted"; reason = "variations_country=$variationsCountry" }
    }

    if ($permanentCountry -ne "us") {
        return @{ state = "drifted"; reason = "variations_permanent_consistency_country=$permanentCountry" }
    }

    if ($hasGlicFalse) {
        return @{ state = "drifted"; reason = "glic_not_eligible" }
    }

    return @{ state = "healthy"; reason = "ok" }
}

function Resolve-StateMapping {
    param(
        [string]$PatchState,
        [bool]$HasPending,
        [bool]$ChromeRunning
    )

    $resultStatus = switch ($PatchState) {
        "healthy" { "healthy" }
        "drifted" { "drifted" }
        default { "detect_error" }
    }

    $currentState = if ($HasPending) {
        "pending"
    }
    elseif ($PatchState -eq "healthy") {
        "healthy"
    }
    elseif ($PatchState -eq "drifted") {
        "drifted"
    }
    else {
        "unknown"
    }

    return @{
        resultStatus = $resultStatus
        currentState = $currentState
    }
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

function Upsert-PendingRecord {
    param(
        [string]$Reason,
        [string]$PatchReason
    )

    $now = Get-NowIso
    $firstSeen = Get-PendingField -Key "first_seen_at"
    if (-not $firstSeen) {
        $firstSeen = $now
    }
    $retryCount = (Get-PendingRetryCount) + 1
    $detectedVersion = if ($script:NeedsPatchChromeVersion) { $script:NeedsPatchChromeVersion } else { Get-ChromeVersionOrUnknown }
    Write-PendingMetadata -Reason $Reason -PatchReason $PatchReason -FirstSeenAt $firstSeen -LastAttemptAt $now -RetryCount $retryCount -DetectedVersion $detectedVersion
    Write-Log "Pending record updated ($Reason / $PatchReason, retry_count=$retryCount)."
}

function Should-AttemptRetryNow {
    param([int]$RetryCount)

    if ($RetryCount -lt 10) {
        return $true
    }

    return ($RetryCount % 5) -eq 0
}

function Remove-Pending {
    Remove-Item -Path $PendingFile -Force -ErrorAction SilentlyContinue
}

function Test-Pending {
    return (Test-Path $PendingFile)
}

function Invoke-PatchAndVerify {
    param([string]$PatchReason)

    $chromeVersion = Get-ChromeVersionOrUnknown

    if (-not (Enter-ActiveLock)) {
        Upsert-PendingRecord -Reason "active_lock_busy" -PatchReason $PatchReason
        Write-LastResult -Status "blocked" -Reason "active_lock_busy" -ChromeVersion $chromeVersion -Hint "another run in progress"
        return $true
    }

    try {
        if (-not (Invoke-CoreInstall)) {
            Upsert-PendingRecord -Reason "patch_failed" -PatchReason $PatchReason
            Write-LastResult -Status "patch_failed" -Reason $PatchReason -ChromeVersion $chromeVersion -Hint "Run gemini-chrome-fix"
            return $false
        }

        $verifyState = Get-PatchState
        if ($verifyState.state -ne "healthy") {
            Upsert-PendingRecord -Reason "verify_failed" -PatchReason $verifyState.reason
            Write-LastResult -Status "verify_failed" -Reason $verifyState.reason -ChromeVersion $chromeVersion -Hint "Run gemini-chrome-fix"
            return $false
        }

        $installedVersion = Get-ChromeVersionOrUnknown
        if ($installedVersion -ne "unknown") {
            Save-PatchedVersion $installedVersion
        }
        Remove-Pending
        Write-LastResult -Status "healthy" -Reason $verifyState.reason -ChromeVersion $installedVersion -Hint ""
        return $true
    }
    finally {
        Exit-ActiveLock
    }
}

function Invoke-Reconcile {
    param([string]$Trigger = "manual")

    $patchState = Get-PatchState
    $chromeVersion = Get-ChromeVersionOrUnknown
    $script:NeedsPatchChromeVersion = $chromeVersion

    switch ($patchState.state) {
        "healthy" {
            if ($chromeVersion -ne "unknown") {
                Save-PatchedVersion $chromeVersion
            }
            Remove-Pending
            Write-LastResult -Status "healthy" -Reason $patchState.reason -ChromeVersion $chromeVersion -Hint ""
            return $true
        }
        "unknown" {
            Write-LastResult -Status "detect_error" -Reason $patchState.reason -ChromeVersion $chromeVersion -Hint "Run gemini-chrome-fix"
            return $false
        }
        "drifted" {
            if (Test-IsChromeRunning) {
                Upsert-PendingRecord -Reason "blocked" -PatchReason $patchState.reason
                Write-LastResult -Status "blocked" -Reason $patchState.reason -ChromeVersion $chromeVersion -Hint "Chrome 关闭后将自动修复"
                return $true
            }
            return (Invoke-PatchAndVerify -PatchReason $patchState.reason)
        }
        default {
            Write-LastResult -Status "detect_error" -Reason "unknown_patch_state:$($patchState.state)" -ChromeVersion $chromeVersion -Hint "Run gemini-chrome-fix"
            return $false
        }
    }
}

function Invoke-PendingInstall {
    if (-not (Test-Pending)) {
        return
    }

    Write-Log "Retry: pending install found."
    $script:NeedsPatchChromeVersion = Get-ChromeVersionOrUnknown
    $pendingPatchReason = Get-PendingPatchReason

    if (Test-IsChromeRunning) {
        Upsert-PendingRecord -Reason "blocked" -PatchReason $pendingPatchReason
        Write-LastResult -Status "blocked" -Reason $pendingPatchReason -ChromeVersion $script:NeedsPatchChromeVersion -Hint "Chrome 关闭后将自动修复"
        return
    }

    $retryCount = Get-PendingRetryCount
    if (-not (Should-AttemptRetryNow -RetryCount $retryCount)) {
        Upsert-PendingRecord -Reason "backoff_wait" -PatchReason $pendingPatchReason
        Write-LastResult -Status "blocked" -Reason "retry_backoff" -ChromeVersion $script:NeedsPatchChromeVersion -Hint "等待下一次自动重试窗口"
        Write-Log "Retry throttled by internal backoff (retry_count=$retryCount)."
        return
    }

    [void](Invoke-Reconcile -Trigger "retry")
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

    $chromeVer = Get-ChromeVersionOrUnknown
    $patchedVer = Get-PatchedVersion
    if (-not $patchedVer) {
        $patchedVer = "never"
    }

    $patchState = Get-PatchState
    $hasPending = Test-Pending
    $chromeRunning = Test-IsChromeRunning
    $stateMapping = Resolve-StateMapping -PatchState $patchState.state -HasPending:$hasPending -ChromeRunning:$chromeRunning

    $pendingReason = Get-PendingField -Key "reason"
    if (-not $pendingReason) {
        $pendingReason = "none"
    }

    $pendingPatchReason = Get-PendingPatchReason
    if (-not $hasPending) {
        $pendingPatchReason = "none"
    }

    $pendingRetryCount = Get-PendingRetryCount
    $pendingAge = Get-PendingAge

    $lastAttempt = Get-PendingField -Key "last_attempt_at"
    if (-not $lastAttempt) {
        $lastAttempt = Get-LastResultField -Key "timestamp"
    }
    if (-not $lastAttempt) {
        $lastAttempt = "never"
    }

    Write-Host "  Tool version: $(Get-ToolVersion)"
    Write-Host "  Chrome version: $chromeVer"
    Write-Host "  Last healthy version: $patchedVer"
    Write-Host "  Current state: $($stateMapping.currentState)"
    Write-Host "  Pending reason: $pendingReason"
    Write-Host "  Pending patch reason: $pendingPatchReason"
    Write-Host "  Pending retry count: $pendingRetryCount"
    Write-Host "  Pending age: $pendingAge"
    Write-Host "  Last attempt: $lastAttempt"
    Write-Host "  Log: $LogFile"
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
    [void](Invoke-Reconcile -Trigger "run")
}

function Invoke-Manual {
    Write-Log "Manual install triggered."
    $reopenChrome = $false

    if (Test-IsChromeRunning) {
        $response = Read-Host "Chrome is running. Close it to continue? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Log "Closing Chrome (user confirmed)..."
            Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
            $reopenChrome = $true
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

    $success = Invoke-Reconcile -Trigger "manual"

    if ($success -and $reopenChrome) {
        Write-Log "Reopening Chrome..."
        Start-Process "chrome"
    }
}

function Invoke-Watch {
    Write-Log "Watch started: monitoring Google Update version changes."

    $currentVersion = Get-ChromeVersion
    if (-not $currentVersion) {
        Write-Log "Watch: Chrome version source not found. Exiting."
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
        $ChromeUpdateRegistrySubKey,
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

                $newVersion = Get-ChromeVersion
                $savedVersion = Get-SavedChromeVersion

                if ($newVersion -and $newVersion -ne $savedVersion) {
                    Write-Log "Watch: Chrome version changed ($savedVersion -> $newVersion). Triggering patch."
                    Save-ChromeVersion $newVersion
                    [void](Invoke-Reconcile -Trigger "watch")
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
                $ChromeUpdateRegistrySubKey,
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

    [void](Invoke-Reconcile -Trigger "startup")

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
    "retry"     { Invoke-PendingInstall }
    "manual"    { Invoke-Manual }
    "watch"     { Invoke-Watch }
    "scheduled" { Invoke-Scheduled }
    default {
        Write-Host "Usage: .\patch.ps1 {enable|disable|uninstall|status|run|retry|manual|watch|scheduled|help}"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  enable      Register startup entry for auto-patching"
        Write-Host "  disable     Remove startup entry and stop watcher"
        Write-Host "  uninstall   Disable and remove all installed files"
        Write-Host "  status      Show current status (incl. watcher and runtime state)"
        Write-Host "  run         Execute the patch (creates/updates pending if Chrome is running)"
        Write-Host "  retry       Retry pending install if conditions allow"
        Write-Host "  manual      Re-install immediately (offers to close Chrome)"
        Write-Host "  watch       Start registry watcher (runs as background daemon)"
        Write-Host "  scheduled   Startup entrypoint (check state + ensure watch)"
    }
}
