$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Fixtures = Join-Path $ScriptDir "fixtures"
$TestInstallDir = Join-Path $env:TEMP "gemini-self-update-test-$(Get-Random)"
$TestLogFile = Join-Path $TestInstallDir "test.log"
$Port = 18923
$Pass = 0
$Fail = 0
$ServerProcess = $null

# --- Helpers ---

function Start-FixtureServer {
    param([string]$FixtureDir)
    $script:ServerProcess = Start-Process python -ArgumentList "-m", "http.server", $Port `
        -WorkingDirectory $FixtureDir -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
}

function Stop-FixtureServer {
    if ($script:ServerProcess -and -not $script:ServerProcess.HasExited) {
        Stop-Process -Id $script:ServerProcess.Id -Force -ErrorAction SilentlyContinue
        $script:ServerProcess = $null
    }
}

function Reset-InstallDir {
    if (Test-Path $TestInstallDir) { Remove-Item $TestInstallDir -Recurse -Force }
    New-Item -ItemType Directory -Path $TestInstallDir -Force | Out-Null
    Copy-Item (Join-Path $ProjectRoot "patch.ps1") (Join-Path $TestInstallDir "patch.ps1")
    Copy-Item (Join-Path $ProjectRoot "launcher.vbs") (Join-Path $TestInstallDir "launcher.vbs") -ErrorAction SilentlyContinue
    "" | Set-Content $TestLogFile
}

function Assert-Contains {
    param([string]$File, [string]$Pattern, [string]$TestName)
    if ((Get-Content $File -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($Pattern)) {
        $script:Pass++; Write-Host "  PASS: $TestName"
    } else {
        $script:Fail++; Write-Host "  FAIL: $TestName (expected '$Pattern' in $(Split-Path $File -Leaf))"
    }
}

function Assert-NotContains {
    param([string]$File, [string]$Pattern, [string]$TestName)
    if ((Get-Content $File -Raw -ErrorAction SilentlyContinue) -notmatch [regex]::Escape($Pattern)) {
        $script:Pass++; Write-Host "  PASS: $TestName"
    } else {
        $script:Fail++; Write-Host "  FAIL: $TestName (did not expect '$Pattern' in $(Split-Path $File -Leaf))"
    }
}

function Assert-FileContent {
    param([string]$File, [string]$Expected, [string]$TestName)
    $actual = (Get-Content $File -Raw).Trim()
    if ($actual -eq $Expected) {
        $script:Pass++; Write-Host "  PASS: $TestName"
    } else {
        $script:Fail++; Write-Host "  FAIL: $TestName (expected '$Expected', got '$actual')"
    }
}

function Assert-FileExists {
    param([string]$File, [string]$TestName)
    if (Test-Path $File) {
        $script:Pass++; Write-Host "  PASS: $TestName"
    } else {
        $script:Fail++; Write-Host "  FAIL: $TestName (file not found: $File)"
    }
}

function Invoke-PatchRun {
    $env:GEMINI_INSTALL_DIR = $TestInstallDir
    $env:GEMINI_RAW_BASE = "http://localhost:$Port"
    $env:GEMINI_LOG_FILE = $TestLogFile
    $env:GEMINI_LOCAL_STATE_PATH = "NUL"
    try {
        & (Join-Path $TestInstallDir "patch.ps1") run 2>$null
    } catch { }
    Remove-Item Env:\GEMINI_INSTALL_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\GEMINI_RAW_BASE -ErrorAction SilentlyContinue
    Remove-Item Env:\GEMINI_LOG_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\GEMINI_LOCAL_STATE_PATH -ErrorAction SilentlyContinue
}

# === Tests ===

Write-Host "=== Self-Update Tests (Windows) ==="
Write-Host ""

# --- Test 1: Remote has newer version ---
Write-Host "Test 1: Remote has newer version"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
Start-FixtureServer (Join-Path $Fixtures "newer")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v99.0.0" "VERSION updated to v99.0.0"
Assert-Contains $TestLogFile "Self-updated from v0.0.1 to v99.0.0" "Log contains Self-updated message"
Assert-FileExists (Join-Path $TestInstallDir "last-update-check") "Timestamp file created"
Write-Host ""

# --- Test 2: Version identical ---
Write-Host "Test 2: Version identical"
Reset-InstallDir
Copy-Item (Join-Path $ProjectRoot "VERSION") (Join-Path $TestInstallDir "VERSION")
Remove-Item (Join-Path $TestInstallDir "last-update-check") -ErrorAction SilentlyContinue
Start-FixtureServer (Join-Path $Fixtures "same")
Invoke-PatchRun
Stop-FixtureServer
Assert-NotContains $TestLogFile "Self-updated" "No Self-updated log"
Assert-FileExists (Join-Path $TestInstallDir "last-update-check") "Timestamp file created"
Write-Host ""

# --- Test 3: Cooldown not expired ---
Write-Host "Test 3: Cooldown not expired (should skip)"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
[int](Get-Date -UFormat %s) | Set-Content (Join-Path $TestInstallDir "last-update-check") -NoNewline
Start-FixtureServer (Join-Path $Fixtures "newer")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v0.0.1" "VERSION unchanged (cooldown active)"
Assert-NotContains $TestLogFile "Self-updated" "No Self-updated log"
Write-Host ""

# --- Test 4: Cooldown expired ---
Write-Host "Test 4: Cooldown expired (should check)"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
$expired = [int](Get-Date -UFormat %s) - 90000  # 25 hours ago
$expired | Set-Content (Join-Path $TestInstallDir "last-update-check") -NoNewline
Start-FixtureServer (Join-Path $Fixtures "newer")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v99.0.0" "VERSION updated after cooldown expired"
Assert-Contains $TestLogFile "Self-updated" "Log contains Self-updated message"
Write-Host ""

# --- Test 5: Network unreachable ---
Write-Host "Test 5: Network unreachable"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
Remove-Item (Join-Path $TestInstallDir "last-update-check") -ErrorAction SilentlyContinue
$env:GEMINI_INSTALL_DIR = $TestInstallDir
$env:GEMINI_RAW_BASE = "http://127.0.0.1:19999"
$env:GEMINI_LOG_FILE = $TestLogFile
$env:GEMINI_LOCAL_STATE_PATH = "NUL"
try { & (Join-Path $TestInstallDir "patch.ps1") run 2>$null } catch { }
Remove-Item Env:\GEMINI_INSTALL_DIR, Env:\GEMINI_RAW_BASE, Env:\GEMINI_LOG_FILE, Env:\GEMINI_LOCAL_STATE_PATH -ErrorAction SilentlyContinue
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v0.0.1" "VERSION unchanged"
Assert-Contains $TestLogFile "Self-update check failed" "Log contains failure message"
Write-Host ""

# --- Test 6: Partial download failure ---
Write-Host "Test 6: Partial download failure (VERSION only, no patch.ps1)"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
$originalHash = (Get-FileHash (Join-Path $TestInstallDir "patch.ps1")).Hash
Start-FixtureServer (Join-Path $Fixtures "partial")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v0.0.1" "VERSION unchanged after partial failure"
Assert-Contains $TestLogFile "download failed" "Log contains download failed"
$newHash = (Get-FileHash (Join-Path $TestInstallDir "patch.ps1")).Hash
if ($originalHash -eq $newHash) {
    $script:Pass++; Write-Host "  PASS: patch.ps1 unchanged"
} else {
    $script:Fail++; Write-Host "  FAIL: patch.ps1 was modified"
}
Write-Host ""

# --- Test 7: First check (no timestamp file) ---
Write-Host "Test 7: First check (no timestamp file)"
Reset-InstallDir
"v0.0.1" | Set-Content (Join-Path $TestInstallDir "VERSION") -NoNewline
Remove-Item (Join-Path $TestInstallDir "last-update-check") -ErrorAction SilentlyContinue
Start-FixtureServer (Join-Path $Fixtures "newer")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileExists (Join-Path $TestInstallDir "last-update-check") "Timestamp file created on first check"
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v99.0.0" "VERSION updated on first check"
Write-Host ""

# --- Test 8: No local VERSION file ---
Write-Host "Test 8: No local VERSION file"
Reset-InstallDir
Remove-Item (Join-Path $TestInstallDir "VERSION") -ErrorAction SilentlyContinue
Start-FixtureServer (Join-Path $Fixtures "newer")
Invoke-PatchRun
Stop-FixtureServer
Assert-FileContent (Join-Path $TestInstallDir "VERSION") "v99.0.0" "VERSION created from remote"
Assert-Contains $TestLogFile "Self-updated from unknown to v99.0.0" "Log shows update from unknown"
Write-Host ""

# === Cleanup & Results ===
Stop-FixtureServer
Remove-Item $TestInstallDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "================================"
Write-Host "Results: $Pass passed, $Fail failed"
Write-Host "================================"
if ($Fail -gt 0) { exit 1 } else { exit 0 }
