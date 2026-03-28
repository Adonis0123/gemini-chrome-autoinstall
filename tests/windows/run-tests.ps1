param(
  [string]$Case = ""
)

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..").Path
$FixtureDir = Join-Path $RepoRoot "tests\fixtures\local-state"
$RunRoot = Join-Path $env:TEMP ("gemini-chrome-autoinstall-tests-" + [guid]::NewGuid().ToString())

$global:Failures = 0
$global:CasesRun = 0

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Action,
    [hashtable]$CaseEnv = @{}
  )

  if ($Case -and $Case -ne $Name) {
    return 2
  }

  Write-Host "==> $Name"
  $global:CasesRun++

  $managedKeys = @(
    "USERPROFILE",
    "LOCALAPPDATA",
    "TEMP",
    "TMP",
    "TMPDIR",
    "GEMINI_INSTALL_DIR",
    "GEMINI_LOCAL_STATE_PATH",
    "GEMINI_CHROME_VERSION",
    "GEMINI_CHROME_RUNNING",
    "GEMINI_FAKE_INSTALL_MODE"
  )

  $originalEnv = @{}
  foreach ($envName in $managedKeys) {
    if (Test-Path "Env:$envName") {
      $originalEnv[$envName] = (Get-Item "Env:$envName").Value
    }
    else {
      $originalEnv[$envName] = $null
    }
  }

  foreach ($envName in $CaseEnv.Keys) {
    if (-not $managedKeys.Contains($envName)) {
      continue
    }
    Set-Item -Path "Env:$envName" -Value $CaseEnv[$envName]
    if ($envName -in @("USERPROFILE", "LOCALAPPDATA", "TEMP", "TMP", "TMPDIR")) {
      New-Item -ItemType Directory -Force -Path $CaseEnv[$envName] | Out-Null
    }
  }

  $caseExitCode = 0
  $caseOutput = $null

  try {
    $caseOutput = & { & $Action } 2>&1 | Out-String
    if (-not $?) {
      $caseExitCode = 1
    }
    elseif ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
      $caseExitCode = $LASTEXITCODE
    }
  }
  catch {
    $caseExitCode = 1
    $caseOutput = $_.Exception.Message
  }
  finally {
    foreach ($envName in $managedKeys) {
      if ($null -eq $originalEnv[$envName]) {
        Remove-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
      }
      else {
        Set-Item -Path "Env:$envName" -Value $originalEnv[$envName]
      }
    }
  }

  if ($caseExitCode -ne 0) {
    Write-Host "[FAIL] command failed with exit $caseExitCode"
    if ($caseOutput) {
      Write-Host $caseOutput
    }
    $global:Failures++
  }

  return $caseExitCode
}

function Assert-Contains {
  param([string]$Actual, [string]$Expected)

  if (($Actual -ne $null) -and ($Actual.Contains($Expected))) {
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

try {
  New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null

  $statusCaseRoot = Join-Path $RunRoot "status-shows-tool-version"
  $statusEnv = @{
    "USERPROFILE" = Join-Path $statusCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $statusCaseRoot "localappdata"
    "TEMP" = Join-Path $statusCaseRoot "temp"
    "TMP" = Join-Path $statusCaseRoot "temp"
    "TMPDIR" = Join-Path $statusCaseRoot "temp"
  }
  Invoke-Case "status-shows-tool-version" {
    $scriptOutput = & "$RepoRoot\patch.ps1" status | Out-String
    Assert-Contains $scriptOutput "Tool version:"
  } -CaseEnv $statusEnv

  $triCaseRoot = Join-Path $RunRoot "tri-state-healthy"
  $triRuntimeRoot = Join-Path $triCaseRoot "runtime"
  $triEnv = @{
    "USERPROFILE" = Join-Path $triCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $triCaseRoot "localappdata"
    "TEMP" = Join-Path $triCaseRoot "temp"
    "TMP" = Join-Path $triCaseRoot "temp"
    "TMPDIR" = Join-Path $triCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $triRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }

  Invoke-Case "tri-state-healthy" {
    New-Item -ItemType Directory -Force -Path $triRuntimeRoot | Out-Null
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $triRuntimeRoot "last-result") "status=healthy"
  } -CaseEnv $triEnv

  if ($Case -and $CasesRun -eq 0) {
    Write-Host "[FAIL] unknown test case: $Case"
    exit 1
  }

  if ($Failures -gt 0) {
    Write-Host "FAILED: $Failures checks failed."
    exit 1
  }

  Write-Host "PASSED"
  exit 0
}
finally {
  Remove-Item -Path $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
}
