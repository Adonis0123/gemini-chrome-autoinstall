param(
  [string]$Case = ""
)

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..").Path
$FixtureDir = Join-Path $RepoRoot "tests\fixtures\local-state"
$RunRoot = Join-Path $env:TEMP ("gemini-chrome-autoinstall-tests-" + [guid]::NewGuid().ToString())
$RequestedCases = @()
if ($Case) {
  $RequestedCases = @(
    $Case.Split(",") |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne "" }
  )
}

$global:Failures = 0
$global:CasesRun = 0

function Should-RunCase {
  param([string]$Name)

  if ($RequestedCases.Count -eq 0) {
    return $true
  }

  return $RequestedCases -contains $Name
}

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Action,
    [hashtable]$CaseEnv = @{}
  )

  if (-not (Should-RunCase -Name $Name)) {
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
    "GEMINI_CORE_INSTALL_CMD",
    "GEMINI_FAKE_INSTALL_MODE",
    "GEMINI_PROFILE_PATH",
    "GEMINI_SKIP_ENABLE",
    "GEMINI_SKIP_FIRST_PATCH"
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

function Assert-PathExists {
  param([string]$Path)

  if (Test-Path $Path) {
    Write-Host "[PASS] path exists: $Path"
  }
  else {
    Write-Host "[FAIL] missing path: $Path"
    $global:Failures++
  }
}

function Assert-FileMissing {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    Write-Host "[PASS] file is missing: $Path"
  }
  else {
    Write-Host "[FAIL] unexpected file present: $Path"
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

  $installCaseRoot = Join-Path $RunRoot "install-prints-version"
  $installEnv = @{
    "USERPROFILE" = Join-Path $installCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $installCaseRoot "localappdata"
    "TEMP" = Join-Path $installCaseRoot "temp"
    "TMP" = Join-Path $installCaseRoot "temp"
    "TMPDIR" = Join-Path $installCaseRoot "temp"
  }
  Invoke-Case "install-prints-version" {
    $env:GEMINI_INSTALL_DIR = "$RunRoot\install"
    $env:GEMINI_PROFILE_PATH = "$RunRoot\profile.ps1"
    $env:GEMINI_SKIP_ENABLE = "1"
    $env:GEMINI_SKIP_FIRST_PATCH = "1"
    $output = & "$RepoRoot\install.ps1" | Out-String
    Assert-Contains $output "Tool version: v"
    Assert-PathExists "$RunRoot\install\VERSION"
  } -CaseEnv $installEnv

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

  $driftedGlicCaseRoot = Join-Path $RunRoot "tri-state-drifted-glic"
  $driftedGlicRuntimeRoot = Join-Path $driftedGlicCaseRoot "runtime"
  $driftedGlicEnv = @{
    "USERPROFILE" = Join-Path $driftedGlicCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $driftedGlicCaseRoot "localappdata"
    "TEMP" = Join-Path $driftedGlicCaseRoot "temp"
    "TMP" = Join-Path $driftedGlicCaseRoot "temp"
    "TMPDIR" = Join-Path $driftedGlicCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $driftedGlicRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "drifted-glic-false.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "tri-state-drifted-glic" {
    New-Item -ItemType Directory -Force -Path $driftedGlicRuntimeRoot | Out-Null
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $driftedGlicRuntimeRoot "last-result") "status=drifted"
  } -CaseEnv $driftedGlicEnv

  $unknownCaseRoot = Join-Path $RunRoot "tri-state-unknown-missing-fields"
  $unknownRuntimeRoot = Join-Path $unknownCaseRoot "runtime"
  $unknownEnv = @{
    "USERPROFILE" = Join-Path $unknownCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $unknownCaseRoot "localappdata"
    "TEMP" = Join-Path $unknownCaseRoot "temp"
    "TMP" = Join-Path $unknownCaseRoot "temp"
    "TMPDIR" = Join-Path $unknownCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $unknownRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "unknown-missing-fields.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "tri-state-unknown-missing-fields" {
    New-Item -ItemType Directory -Force -Path $unknownRuntimeRoot | Out-Null
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $unknownRuntimeRoot "last-result") "status=detect_error"
    Assert-FileContains (Join-Path $unknownRuntimeRoot "last-result") "reason=missing_required_fields"
  } -CaseEnv $unknownEnv

  $blockedCaseRoot = Join-Path $RunRoot "chrome-running-creates-pending"
  $blockedRuntimeRoot = Join-Path $blockedCaseRoot "runtime"
  $blockedEnv = @{
    "USERPROFILE" = Join-Path $blockedCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $blockedCaseRoot "localappdata"
    "TEMP" = Join-Path $blockedCaseRoot "temp"
    "TMP" = Join-Path $blockedCaseRoot "temp"
    "TMPDIR" = Join-Path $blockedCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $blockedRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "drifted-variations-country.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "1"
  }
  Invoke-Case "chrome-running-creates-pending" {
    New-Item -ItemType Directory -Force -Path $blockedRuntimeRoot | Out-Null
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $blockedRuntimeRoot "pending") "reason=blocked"
    Assert-FileContains (Join-Path $blockedRuntimeRoot "last-result") "status=blocked"
  } -CaseEnv $blockedEnv

  $retryCaseRoot = Join-Path $RunRoot "retry-settles-after-close"
  $retryRuntimeRoot = Join-Path $retryCaseRoot "runtime"
  $retryLocalStatePath = Join-Path $retryRuntimeRoot "Local State"
  $retryEnv = @{
    "USERPROFILE" = Join-Path $retryCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $retryCaseRoot "localappdata"
    "TEMP" = Join-Path $retryCaseRoot "temp"
    "TMP" = Join-Path $retryCaseRoot "temp"
    "TMPDIR" = Join-Path $retryCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $retryRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = $retryLocalStatePath
    "GEMINI_CORE_INSTALL_CMD" = "$RepoRoot\tests\helpers\fake-core-install.ps1"
    "GEMINI_FAKE_INSTALL_MODE" = "success"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "1"
  }
  Invoke-Case "retry-settles-after-close" {
    New-Item -ItemType Directory -Force -Path $retryRuntimeRoot | Out-Null
    Copy-Item (Join-Path $FixtureDir "drifted-variations-country.json") $retryLocalStatePath -Force
    & "$RepoRoot\patch.ps1" run | Out-Null
    $env:GEMINI_CHROME_RUNNING = "0"
    & "$RepoRoot\patch.ps1" retry | Out-Null
    Assert-FileMissing (Join-Path $retryRuntimeRoot "pending")
    Assert-FileContains (Join-Path $retryRuntimeRoot "last-result") "status=healthy"
  } -CaseEnv $retryEnv

  $patchFailureCaseRoot = Join-Path $RunRoot "patch-failure-recorded"
  $patchFailureRuntimeRoot = Join-Path $patchFailureCaseRoot "runtime"
  $patchFailureEnv = @{
    "USERPROFILE" = Join-Path $patchFailureCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $patchFailureCaseRoot "localappdata"
    "TEMP" = Join-Path $patchFailureCaseRoot "temp"
    "TMP" = Join-Path $patchFailureCaseRoot "temp"
    "TMPDIR" = Join-Path $patchFailureCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $patchFailureRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "drifted-glic-false.json"
    "GEMINI_CORE_INSTALL_CMD" = "$RepoRoot\tests\helpers\fake-core-install.ps1"
    "GEMINI_FAKE_INSTALL_MODE" = "patch_fail"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "patch-failure-recorded" {
    New-Item -ItemType Directory -Force -Path $patchFailureRuntimeRoot | Out-Null
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $patchFailureRuntimeRoot "last-result") "status=patch_failed"
  } -CaseEnv $patchFailureEnv

  $verifyFailureCaseRoot = Join-Path $RunRoot "verify-failure-recorded"
  $verifyFailureRuntimeRoot = Join-Path $verifyFailureCaseRoot "runtime"
  $verifyFailureLocalStatePath = Join-Path $verifyFailureRuntimeRoot "Local State"
  $verifyFailureEnv = @{
    "USERPROFILE" = Join-Path $verifyFailureCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $verifyFailureCaseRoot "localappdata"
    "TEMP" = Join-Path $verifyFailureCaseRoot "temp"
    "TMP" = Join-Path $verifyFailureCaseRoot "temp"
    "TMPDIR" = Join-Path $verifyFailureCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $verifyFailureRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = $verifyFailureLocalStatePath
    "GEMINI_CORE_INSTALL_CMD" = "$RepoRoot\tests\helpers\fake-core-install.ps1"
    "GEMINI_FAKE_INSTALL_MODE" = "verify_fail"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "verify-failure-recorded" {
    New-Item -ItemType Directory -Force -Path $verifyFailureRuntimeRoot | Out-Null
    Copy-Item (Join-Path $FixtureDir "drifted-variations-country.json") $verifyFailureLocalStatePath -Force
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $verifyFailureRuntimeRoot "last-result") "status=verify_failed"
  } -CaseEnv $verifyFailureEnv

  if ($RequestedCases.Count -gt 0 -and $CasesRun -eq 0) {
    Write-Host "[FAIL] unknown test case(s): $($RequestedCases -join ',')"
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
