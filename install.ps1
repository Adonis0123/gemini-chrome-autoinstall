$ErrorActionPreference = "Stop"

$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "master"
$RawBase = "https://raw.githubusercontent.com/$Repo/$Branch"
$InstallDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"

Write-Host "Installing gemini-chrome-autoinstall..."
Write-Host ""

# Clean up stale locks from previous installs
$ActiveLock = Join-Path $env:TEMP "gemini-chrome-autoinstall.active.lock"
if (Test-Path $ActiveLock) { Remove-Item -Path $ActiveLock -Force -Recurse -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$downloadParams = @{
    Uri = "$RawBase/patch.ps1"
    OutFile = (Join-Path $InstallDir "patch.ps1")
}
if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
    $downloadParams.UseBasicParsing = $true
}
Invoke-WebRequest @downloadParams

& (Join-Path $InstallDir "patch.ps1") enable

# Register shortcut functions in PowerShell profile
$profilePath = $PROFILE
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
Write-Host "Auto-check at logon is enabled. For same-session Chrome updates, use the manual fix command after you close Chrome."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  gemini-chrome-status"
Write-Host "  Manual fix:    gemini-chrome-fix"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
