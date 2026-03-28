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

if (-not $SkipFirstPatch) {
    Write-Host ""
    Write-Host "Running first-time patch..."
    Write-Host ""
    & (Join-Path $InstallDir "patch.ps1") manual
}

# Register shortcut functions in PowerShell profile
$fixFunc = 'function gemini-chrome-fix { & "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual }'
$statusFunc = 'function gemini-chrome-status { & "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status }'

if (!(Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (!$profileContent) { $profileContent = "" }

$changed = $false
if ($profileContent -notmatch 'function gemini-chrome-fix') {
    Add-Content $profilePath "`n$fixFunc"
    $changed = $true
}
if ($profileContent -notmatch 'function gemini-chrome-status') {
    Add-Content $profilePath "`n$statusFunc"
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
Write-Host "Installation complete!"
Write-Host "Auto-monitoring is enabled: registry watcher detects Chrome updates in real time."
Write-Host "Tool version: $((Get-Content (Join-Path $InstallDir 'VERSION') -Raw).Trim())"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  gemini-chrome-status"
Write-Host "  Manual fix:    gemini-chrome-fix"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
