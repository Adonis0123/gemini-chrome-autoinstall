$ErrorActionPreference = "Stop"

$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "master"
$RawBase = if ($env:GEMINI_RAW_BASE) { $env:GEMINI_RAW_BASE } else { "https://raw.githubusercontent.com/$Repo/$Branch" }
$InstallDir = if ($env:GEMINI_INSTALL_DIR) { $env:GEMINI_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall" }
$SkipEnableValue = if ($env:GEMINI_SKIP_ENABLE) { $env:GEMINI_SKIP_ENABLE } else { "0" }
$SkipFirstPatchValue = if ($env:GEMINI_SKIP_FIRST_PATCH) { $env:GEMINI_SKIP_FIRST_PATCH } else { "0" }
$SkipEnable = $SkipEnableValue -eq "1"
$SkipFirstPatch = $SkipFirstPatchValue -eq "1"
$ProfilePath = if ($env:GEMINI_PROFILE_PATH) { $env:GEMINI_PROFILE_PATH } else { $PROFILE }

function Get-OldValidatedWatcherProcess {
    # Inline mirror of patch.ps1's Get-ValidatedWatcherProcess. We can't
    # dot-source the target patch.ps1 because it may be an older version
    # that doesn't export the function (or doesn't match the current
    # file format). Any change to watcher.pid format or the validation
    # logic MUST be made here AND in patch.ps1's Get-ValidatedWatcherProcess.
    #
    # Returns the live Process object iff watcher.pid points to a
    # PowerShell process whose identity is confirmed by either:
    #   * new format: "<pid> <StartTime.Ticks>" → exact Ticks match
    #   * legacy format: "<pid>"                → ±5s mtime window
    param([string]$PidFilePath)

    if (-not (Test-Path $PidFilePath)) { return $null }
    try {
        $content = (Get-Content $PidFilePath -Raw -ErrorAction Stop)
        if (-not $content) { return $null }
        $parts = $content.Trim().Split(' ', 2)
        $savedPid = $parts[0]
        if (-not $savedPid) { return $null }

        $savedTicks = $null
        if ($parts.Count -ge 2 -and $parts[1]) {
            try { $savedTicks = [long]$parts[1] } catch { $savedTicks = $null }
        }

        $proc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.HasExited) { return $null }
        if ($proc.ProcessName -notin @('powershell', 'pwsh')) { return $null }

        try {
            $procStart = $proc.StartTime
        } catch {
            return $null
        }

        if ($null -ne $savedTicks) {
            if ($procStart.Ticks -ne $savedTicks) { return $null }
        } else {
            try {
                $pidFileTime = (Get-Item $PidFilePath -ErrorAction Stop).LastWriteTime
            } catch {
                return $null
            }
            if ([Math]::Abs(($pidFileTime - $procStart).TotalSeconds) -gt 5) {
                return $null
            }
        }
        return $proc
    } catch {}
    return $null
}

function Download-OrCopy {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $sourceUri = "$RawBase/$RelativePath"
    $downloadParams = @{
        Uri = $sourceUri
        OutFile = $DestinationPath
    }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
        $downloadParams.UseBasicParsing = $true
    }

    try {
        Invoke-WebRequest @downloadParams
        return
    }
    catch {
        $baseLocalPath = if ($RawBase -match '^[A-Za-z]:\\' -or $RawBase.StartsWith('/') -or $RawBase.StartsWith('.')) {
            Join-Path $RawBase $RelativePath
        } else {
            $null
        }
        $scriptLocalPath = Join-Path $PSScriptRoot $RelativePath
        if ($baseLocalPath -and (Test-Path $baseLocalPath)) {
            Copy-Item -Path $baseLocalPath -Destination $DestinationPath -Force
            return
        }
        if (Test-Path $scriptLocalPath) {
            Copy-Item -Path $scriptLocalPath -Destination $DestinationPath -Force
            return
        }
        throw "Failed to fetch $RelativePath from $RawBase and no local fallback found."
    }
}

function Read-ProfileText {
    # Keep the profile's own encoding: BOM if present, otherwise the
    # encoding this PowerShell uses for BOM-less scripts (ANSI on 5.1,
    # UTF-8 on 7+). Rewriting it as anything else would garble non-ASCII
    # content the user already has there.
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = [System.Text.Encoding]::Default
    $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true); $skip = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $skip = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true); $skip = 2
    }
    return @{
        Text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
        Encoding = $encoding
    }
}

function Set-ProfileShortcut {
    # Returns the updated profile text. An existing one-line definition of
    # the function (what every earlier release appended) is rewritten in
    # place, so re-running install upgrades old profiles and is a no-op on
    # current ones. A multi-line definition the user wrote is left alone.
    param([string]$Text, [string]$Name, [string]$Line)
    $escapedName = [regex]::Escape($Name)
    $oneLiner = "(?m)^[ \t]*function[ \t]+$escapedName[ \t]*\{.*\}[ \t]*(?=\r?$)"
    if ([regex]::IsMatch($Text, $oneLiner)) {
        return [regex]::Replace($Text, $oneLiner, $Line.Replace('$', '$$'))
    }
    if ([regex]::IsMatch($Text, "(?m)^[ \t]*function[ \t]+$escapedName\b")) {
        Write-Host "Note: '$Name' in your PowerShell profile is not the one-line form; left unchanged."
        return $Text
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { [Environment]::NewLine }
    return $Text + $newline + $Line + $newline
}

Write-Host "Installing gemini-chrome-autoinstall..."
Write-Host ""

# Stop old watcher process before overwriting scripts. We must identify
# watchers by BOTH their PID file AND the CommandLine scan — not just the
# CommandLine scan — because the whole reason this PR exists is that the
# watcher spawned by a Run-key → wscript → powershell chain can have an
# empty Win32_Process.CommandLine, in which case the scan below would
# silently miss it. Missing it here means the new watcher spawned at the
# end of install.ps1 would run alongside the still-live old one.
#
# Strategy:
#   1. Primary: read the PID file and validate it the same way
#      Get-ValidatedWatcherProcess does in patch.ps1 (PID + StartTime.Ticks
#      exact match, or the legacy ±5s mtime fallback for upgrade compat).
#      Works even when CommandLine is empty.
#   2. Fallback: CommandLine scan scoped to $InstallDir\patch.ps1, for
#      orphans that lost their PID file. Dedup against the primary hit.
#   3. Kill each target with the same drain-and-verify loop patch.ps1's
#      Stop-WatchProcess uses.
#   4. Only remove watcher.pid when EVERY old target is confirmed dead,
#      so a failed kill doesn't hide a live watcher from the next
#      Test-WatcherRunning call downstream.
$oldPidFile = Join-Path $InstallDir "watcher.pid"

$targetsToKill = [System.Collections.Generic.List[object]]::new()
$pidFileOwner = Get-OldValidatedWatcherProcess -PidFilePath $oldPidFile
if ($pidFileOwner) {
    $targetsToKill.Add($pidFileOwner) | Out-Null
}

$ourPatchPath = Join-Path $InstallDir "patch.ps1"
$ourPatchPattern = [regex]::Escape($ourPatchPath) + ".*watch"
$scanHits = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $ourPatchPattern }
foreach ($hit in $scanHits) {
    $alreadyTracked = $false
    foreach ($existing in $targetsToKill) {
        if ($existing.Id -eq $hit.ProcessId) { $alreadyTracked = $true; break }
    }
    if (-not $alreadyTracked) {
        $fallbackProc = Get-Process -Id $hit.ProcessId -ErrorAction SilentlyContinue
        if ($fallbackProc -and -not $fallbackProc.HasExited) {
            $targetsToKill.Add($fallbackProc) | Out-Null
        }
    }
}

$allOldWatchersDead = $true
foreach ($target in $targetsToKill) {
    try {
        Stop-Process -Id $target.Id -Force -ErrorAction Stop
    } catch {
        # Re-checked by the drain loop; Stop-Process can fail silently
        # across integrity levels.
    }
    $deadline = (Get-Date).AddMilliseconds(1500)
    $dead = $false
    while ((Get-Date) -lt $deadline) {
        $still = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
        if (-not $still -or $still.HasExited) { $dead = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $dead) { $allOldWatchersDead = $false }
}

# Remove the stale PID file only when every old target is confirmed dead.
# If any one survived, keep the file so the next detection round still
# sees the live watcher.
if ($allOldWatchersDead -and (Test-Path $oldPidFile)) {
    Remove-Item $oldPidFile -Force -ErrorAction SilentlyContinue
}

# Clean up stale locks from previous installs
$ActiveLock = Join-Path $env:TEMP "gemini-chrome-autoinstall.active.lock"
if (Test-Path $ActiveLock) { Remove-Item -Path $ActiveLock -Force -Recurse -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Download-OrCopy -RelativePath "patch.ps1" -DestinationPath (Join-Path $InstallDir "patch.ps1")
Download-OrCopy -RelativePath "launcher.vbs" -DestinationPath (Join-Path $InstallDir "launcher.vbs")
Download-OrCopy -RelativePath "VERSION" -DestinationPath (Join-Path $InstallDir "VERSION")

if (-not $SkipEnable) {
    & (Join-Path $InstallDir "patch.ps1") enable
}

$firstPatchOk = $true
if (-not $SkipFirstPatch) {
    Write-Host ""
    Write-Host "Running first-time patch..."
    Write-Host ""
    & (Join-Path $InstallDir "patch.ps1") manual
    $lastResultPath = Join-Path $InstallDir "last-result"
    if (Test-Path $lastResultPath) {
        $resultStatus = (Select-String -Path $lastResultPath -Pattern '^status=(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        if ($resultStatus -and $resultStatus -ne "healthy") {
            $firstPatchOk = $false
        }
    }
}

# Register shortcut functions in PowerShell profile. When antivirus has
# quarantined patch.ps1, they explain that instead of PowerShell's
# "not recognized as the name of a cmdlet" error.
$patchScriptPath = Join-Path $InstallDir "patch.ps1"
$missingHint = "patch.ps1 not found at $patchScriptPath. It was likely quarantined by antivirus (e.g. Huorong / Windows Defender false positive). Restore it from quarantine and add $InstallDir to the antivirus trust list, or reinstall: irm https://raw.githubusercontent.com/$Repo/$Branch/install.ps1 | iex"
$quotedPath = "'" + $patchScriptPath.Replace("'", "''") + "'"
$quotedHint = "'" + $missingHint.Replace("'", "''") + "'"
$fixBody = "`$p = $quotedPath; if (Test-Path -LiteralPath `$p) { & `$p manual } else { Write-Warning $quotedHint }"
$statusBody = "`$p = $quotedPath; if (Test-Path -LiteralPath `$p) { & `$p status } else { Write-Warning $quotedHint }"
$fixFunc = "function gemini-chrome-fix { $fixBody }"
$statusFunc = "function gemini-chrome-status { $statusBody }"

if (!(Test-Path $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
}

$profileFile = Read-ProfileText -Path $ProfilePath
$profileContent = Set-ProfileShortcut -Text $profileFile.Text -Name "gemini-chrome-fix" -Line $fixFunc
$profileContent = Set-ProfileShortcut -Text $profileContent -Name "gemini-chrome-status" -Line $statusFunc

$changed = $profileContent -cne $profileFile.Text
if ($changed) {
    [System.IO.File]::WriteAllText($ProfilePath, $profileContent, $profileFile.Encoding)
}

# Make shortcuts available in current session immediately
Set-Item -Path "function:global:gemini-chrome-fix" -Value ([scriptblock]::Create($fixBody))
Set-Item -Path "function:global:gemini-chrome-status" -Value ([scriptblock]::Create($statusBody))

if ($changed) {
    Write-Host "Shortcut functions added or updated in PowerShell profile."
    Write-Host "  gemini-chrome-fix     -> manual reinstall"
    Write-Host "  gemini-chrome-status  -> check status"
} else {
    Write-Host "Shortcut functions already in PowerShell profile."
}

Write-Host ""
if ($firstPatchOk) {
    Write-Host "Installation complete!"
    Write-Host "Auto-monitoring is enabled: registry watcher detects Chrome updates in real time."
} else {
    Write-Host "Installation complete, but the initial patch did not succeed."
    Write-Host "Auto-monitoring is enabled and will retry automatically."
    Write-Host "You can also run 'gemini-chrome-fix' manually after closing Chrome."
}
Write-Host "Tool version: $((Get-Content (Join-Path $InstallDir 'VERSION') -Raw).Trim())"
# Start fresh watcher in background. Test suites set GEMINI_SKIP_WATCHER_START=1
# so they don't leak a background wscript/powershell process into the system.
$launcherVbs = Join-Path $InstallDir "launcher.vbs"
if ($env:GEMINI_SKIP_WATCHER_START -ne "1" -and (Test-Path $launcherVbs)) {
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$launcherVbs`" watch" -WindowStyle Hidden
    Write-Host "Background watcher started."
}

Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  gemini-chrome-status"
Write-Host "  Manual fix:    gemini-chrome-fix"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
