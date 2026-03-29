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

Write-Host "Installing gemini-chrome-autoinstall..."
Write-Host ""

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

# Register shortcut functions in PowerShell profile
$patchScriptPath = Join-Path $InstallDir "patch.ps1"
$fixFunc = "function gemini-chrome-fix { & `"$patchScriptPath`" manual }"
$statusFunc = "function gemini-chrome-status { & `"$patchScriptPath`" status }"

if (!(Test-Path $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
}

$profileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
if (!$profileContent) { $profileContent = "" }

$changed = $false
if ($profileContent -notmatch 'function gemini-chrome-fix') {
    Add-Content $ProfilePath "`n$fixFunc"
    $changed = $true
}
if ($profileContent -notmatch 'function gemini-chrome-status') {
    Add-Content $ProfilePath "`n$statusFunc"
    $changed = $true
}

if ($changed) {
    Write-Host "Shortcut functions added to PowerShell profile."
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
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  gemini-chrome-status"
Write-Host "  Manual fix:    gemini-chrome-fix"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
