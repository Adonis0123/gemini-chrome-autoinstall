$ErrorActionPreference = "Stop"

$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "main"
$RawBase = "https://raw.githubusercontent.com/$Repo/$Branch"
$InstallDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"

Write-Host "Installing gemini-chrome-autoinstall..."
Write-Host ""

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

Write-Host ""
Write-Host "Installation complete!"
Write-Host "Auto-check at logon is enabled. For same-session Chrome updates, use the manual fix command after you close Chrome."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  & `"$InstallDir\patch.ps1`" status"
Write-Host "  Manual fix:    & `"$InstallDir\patch.ps1`" manual"
Write-Host "  Shortcut name: gemini-chrome-fix"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
