$ErrorActionPreference = "Stop"

$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "main"
$RawBase = "https://raw.githubusercontent.com/$Repo/$Branch"
$InstallDir = Join-Path $env:USERPROFILE ".gemini-chrome-autoinstall"

Write-Host "Installing gemini-chrome-autoinstall..."
Write-Host ""

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Invoke-WebRequest -Uri "$RawBase/patch.ps1" -OutFile (Join-Path $InstallDir "patch.ps1") -UseBasicParsing

& (Join-Path $InstallDir "patch.ps1") enable

Write-Host ""
Write-Host "Installation complete!"
Write-Host "The extension will be re-installed automatically after every Chrome update."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Check status:  & `"$InstallDir\patch.ps1`" status"
Write-Host "  Uninstall:     & `"$InstallDir\patch.ps1`" uninstall"
