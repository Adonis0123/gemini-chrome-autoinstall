param(
  [string]$Case = ""
)

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..").Path
$FixtureDir = Join-Path $RepoRoot "tests\fixtures\local-state"
$TempRoot = Join-Path $env:TEMP "gemini-chrome-autoinstall-tests"

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

$global:Failures = 0
$global:CaseOutput = ""

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  if ($Case -and $Case -ne $Name) {
    return
  }

  Write-Host "==> $Name"

  $script:caseOutput = $null
  $script:caseExitCode = 0

  try {
    $script:caseOutput = & { & $Action } 2>&1 | Out-String
    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
      $script:caseExitCode = $LASTEXITCODE
    }
  }
  catch {
    $script:caseExitCode = 1
    $script:caseOutput = $_.Exception.Message
  }

  if ($script:caseExitCode -ne 0) {
    Write-Host "[FAIL] command failed with exit $script:caseExitCode"
    if ($script:caseOutput) {
      Write-Host $script:caseOutput
    }
    $global:Failures++
  }

  $global:CaseOutput = $script:caseOutput
}

function Assert-Contains {
  param([string]$Actual, [string]$Expected)

  if ($Actual -like "*$Expected*") {
    Write-Host "[PASS] output contains: $Expected"
  }
  else {
    Write-Host "[FAIL] output missing expected string: $Expected"
    $global:Failures++
  }
}

function Assert-FileContains {
  param([string]$Path, [string]$Expected)

  if (-not (Test-Path $Path)) {
    Write-Host "[FAIL] missing file: $Path"
    $global:Failures++
    return
  }

  if (Select-String -Path $Path -Pattern $Expected -SimpleMatch -ErrorAction SilentlyContinue) {
    Write-Host "[PASS] file contains: $Expected"
  }
  else {
    Write-Host "[FAIL] file missing expected text: $Expected"
    Write-Host "  expected in: $Path"
    $global:Failures++
  }
}

Invoke-Case "status-shows-tool-version" {
  $scriptOutput = & "$RepoRoot\patch.ps1" status | Out-String
  Assert-Contains $scriptOutput "Tool version:"
}

Invoke-Case "tri-state-healthy" {
  $env:GEMINI_INSTALL_DIR = "$TempRoot\runtime"
  $env:GEMINI_LOCAL_STATE_PATH = "$FixtureDir\healthy.json"
  $env:GEMINI_CHROME_VERSION = "136.0.7103.49"
  $env:GEMINI_CHROME_RUNNING = "0"
  & "$RepoRoot\patch.ps1" run | Out-Null
  Assert-FileContains "$TempRoot\runtime\last-result" "status=healthy"
}

if ($Failures -gt 0) {
  Write-Host "FAILED: $Failures checks failed."
  exit 1
}

Write-Host "PASSED"
exit 0
