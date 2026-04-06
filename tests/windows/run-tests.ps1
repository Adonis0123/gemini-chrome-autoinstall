param(
  [string]$Case = ""
)

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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
    "GEMINI_SKIP_FIRST_PATCH",
    "GEMINI_SKIP_SELF_UPDATE",
    "GEMINI_SKIP_WATCHER_START"
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

  # Keep every test case offline and side-effect-free:
  #   * GEMINI_SKIP_SELF_UPDATE=1 prevents Update-Self from downloading
  #     anything from GitHub or triggering Stop-WatchProcess.
  #   * GEMINI_SKIP_WATCHER_START=1 prevents install.ps1 from spawning a
  #     background wscript/powershell watcher that would outlive the test
  #     run and pollute the host (we saw one such orphan in the wild).
  # Both are registered in $managedKeys so they survive per-case snapshot.
  $env:GEMINI_SKIP_SELF_UPDATE = "1"
  $env:GEMINI_SKIP_WATCHER_START = "1"

  $statusCaseRoot = Join-Path $RunRoot "status-shows-tool-version"
  $statusEnv = @{
    "USERPROFILE" = Join-Path $statusCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $statusCaseRoot "localappdata"
    "TEMP" = Join-Path $statusCaseRoot "temp"
    "TMP" = Join-Path $statusCaseRoot "temp"
    "TMPDIR" = Join-Path $statusCaseRoot "temp"
  }
  Invoke-Case "status-shows-tool-version" {
    $statusOutputPath = Join-Path $statusCaseRoot "status.txt"
    & "$RepoRoot\patch.ps1" status *> $statusOutputPath
    if (-not $?) { throw "patch.ps1 status failed" }
    $scriptOutput = Get-Content -Path $statusOutputPath -Raw
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
    $installRoot = Join-Path $installCaseRoot "install"
    $env:GEMINI_INSTALL_DIR = $installRoot
    $env:GEMINI_PROFILE_PATH = Join-Path $installCaseRoot "profile.ps1"
    $env:GEMINI_SKIP_ENABLE = "1"
    $env:GEMINI_SKIP_FIRST_PATCH = "1"
    $installOutputPath = Join-Path $installCaseRoot "install.txt"
    & "$RepoRoot\install.ps1" *> $installOutputPath
    if (-not $?) { throw "install.ps1 failed" }
    $output = Get-Content -Path $installOutputPath -Raw
    Assert-Contains $output "Tool version: v"
    Assert-PathExists (Join-Path $installRoot "VERSION")
  } -CaseEnv $installEnv

  # Regression guard for install.ps1's old-watcher cleanup: the dummy
  # PowerShell we spawn here has a CommandLine that does NOT match
  # "patch.ps1.*watch", so the CommandLine scan on its own would miss
  # it — exactly the scenario (empty/mismatching CommandLine) that was
  # the root cause of this whole PR. install.ps1 must fall back to the
  # PID file primary path to identify and kill it.
  $installPidKillCaseRoot = Join-Path $RunRoot "install-kills-watcher-via-pidfile"
  $installPidKillInstallRoot = Join-Path $installPidKillCaseRoot "install"
  $installPidKillEnv = @{
    "USERPROFILE" = Join-Path $installPidKillCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $installPidKillCaseRoot "localappdata"
    "TEMP" = Join-Path $installPidKillCaseRoot "temp"
    "TMP" = Join-Path $installPidKillCaseRoot "temp"
    "TMPDIR" = Join-Path $installPidKillCaseRoot "temp"
  }
  Invoke-Case "install-kills-watcher-via-pidfile" {
    New-Item -ItemType Directory -Force -Path $installPidKillInstallRoot | Out-Null
    $env:GEMINI_INSTALL_DIR = $installPidKillInstallRoot
    $env:GEMINI_PROFILE_PATH = Join-Path $installPidKillCaseRoot "profile.ps1"
    $env:GEMINI_SKIP_ENABLE = "1"
    $env:GEMINI_SKIP_FIRST_PATCH = "1"

    # Dummy PowerShell — stand-in for a live old watcher whose
    # Win32_Process.CommandLine does not contain "patch.ps1 watch"
    # (the exact invisibility that wscript.exe launches produce).
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $proc = Get-Process -Id $dummy.Id
      $pidFile = Join-Path $installPidKillInstallRoot "watcher.pid"
      "$($proc.Id) $($proc.StartTime.Ticks)" | Set-Content $pidFile -NoNewline

      $installOutputPath = Join-Path $installPidKillCaseRoot "install.txt"
      & "$RepoRoot\install.ps1" *> $installOutputPath
      if (-not $?) { throw "install.ps1 failed in install-kills-watcher-via-pidfile" }

      $still = Get-Process -Id $dummy.Id -ErrorAction SilentlyContinue
      if ($still -and -not $still.HasExited) {
        Write-Host "[FAIL] install.ps1 did not kill old watcher PID $($dummy.Id) via PID file"
        $global:Failures++
      } else {
        Write-Host "[PASS] install.ps1 killed old watcher PID $($dummy.Id) via PID file"
      }
      Assert-FileMissing $pidFile
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $installPidKillEnv

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
    if (-not $?) { throw "patch.ps1 run failed in tri-state-healthy" }
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
    $statusOutputPath = Join-Path $driftedGlicCaseRoot "status.txt"
    & "$RepoRoot\patch.ps1" status *> $statusOutputPath
    if (-not $?) { throw "patch.ps1 status failed in tri-state-drifted-glic" }
    $scriptOutput = Get-Content -Path $statusOutputPath -Raw
    Assert-Contains $scriptOutput "Current state: drifted"
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
    if (-not $?) { throw "patch.ps1 run failed in tri-state-unknown-missing-fields" }
    Assert-FileContains (Join-Path $unknownRuntimeRoot "last-result") "status=detect_error"
    Assert-FileContains (Join-Path $unknownRuntimeRoot "last-result") "reason=missing_required_fields"
  } -CaseEnv $unknownEnv

  $manualUnknownCaseRoot = Join-Path $RunRoot "manual-unknown-recovers"
  $manualUnknownRuntimeRoot = Join-Path $manualUnknownCaseRoot "runtime"
  $manualUnknownLocalStatePath = Join-Path $manualUnknownRuntimeRoot "Local State"
  $manualUnknownEnv = @{
    "USERPROFILE" = Join-Path $manualUnknownCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $manualUnknownCaseRoot "localappdata"
    "TEMP" = Join-Path $manualUnknownCaseRoot "temp"
    "TMP" = Join-Path $manualUnknownCaseRoot "temp"
    "TMPDIR" = Join-Path $manualUnknownCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $manualUnknownRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = $manualUnknownLocalStatePath
    "GEMINI_CORE_INSTALL_CMD" = "$RepoRoot\tests\helpers\fake-core-install.ps1"
    "GEMINI_FAKE_INSTALL_MODE" = "success"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "manual-unknown-recovers" {
    New-Item -ItemType Directory -Force -Path $manualUnknownRuntimeRoot | Out-Null
    Copy-Item (Join-Path $FixtureDir "unknown-invalid.json") $manualUnknownLocalStatePath -Force
    & "$RepoRoot\patch.ps1" manual | Out-Null
    if (-not $?) { throw "patch.ps1 manual failed in manual-unknown-recovers" }
    Assert-FileContains (Join-Path $manualUnknownRuntimeRoot "last-result") "status=healthy"
  } -CaseEnv $manualUnknownEnv

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
    if (-not $?) { throw "patch.ps1 run failed in chrome-running-creates-pending" }
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
    if (-not $?) { throw "patch.ps1 run failed in retry-settles-after-close" }
    $env:GEMINI_CHROME_RUNNING = "0"
    & "$RepoRoot\patch.ps1" retry | Out-Null
    if (-not $?) { throw "patch.ps1 retry failed in retry-settles-after-close" }
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
    if (-not $?) { throw "patch.ps1 run failed in patch-failure-recorded" }
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
    if (-not $?) { throw "patch.ps1 run failed in verify-failure-recorded" }
    Assert-FileContains (Join-Path $verifyFailureRuntimeRoot "last-result") "status=verify_failed"
  } -CaseEnv $verifyFailureEnv

  # Regression guard for the watcher PID check: Test-WatcherRunning must
  # recognise a live PowerShell process pointed to by watcher.pid *without*
  # reading Win32_Process.CommandLine (which can be empty for watchers
  # launched via wscript.exe / early-session Run-key chains). The test
  # spawns a dummy PowerShell sleep, writes its PID into watcher.pid, then
  # asserts that `patch.ps1 status` reports the watcher as RUNNING.
  $watcherDetectCaseRoot = Join-Path $RunRoot "watcher-detect-accepts-live-pid"
  $watcherDetectRuntimeRoot = Join-Path $watcherDetectCaseRoot "runtime"
  $watcherDetectEnv = @{
    "USERPROFILE" = Join-Path $watcherDetectCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $watcherDetectCaseRoot "localappdata"
    "TEMP" = Join-Path $watcherDetectCaseRoot "temp"
    "TMP" = Join-Path $watcherDetectCaseRoot "temp"
    "TMPDIR" = Join-Path $watcherDetectCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $watcherDetectRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "watcher-detect-accepts-live-pid" {
    New-Item -ItemType Directory -Force -Path $watcherDetectRuntimeRoot | Out-Null
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $pidFile = Join-Path $watcherDetectRuntimeRoot "watcher.pid"
      $dummy.Id | Set-Content $pidFile -NoNewline
      # PID file mtime should be within 60s of process StartTime by design;
      # both were just created, so the guard accepts them.
      $statusOutputPath = Join-Path $watcherDetectCaseRoot "status.txt"
      & "$RepoRoot\patch.ps1" status *> $statusOutputPath
      if (-not $?) { throw "patch.ps1 status failed in watcher-detect-accepts-live-pid" }
      $scriptOutput = Get-Content -Path $statusOutputPath -Raw
      Assert-Contains $scriptOutput "Watcher:      RUNNING (PID $($dummy.Id))"
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $watcherDetectEnv

  # Complements the positive case: when watcher.pid's mtime is much earlier
  # than the process StartTime, Test-WatcherRunning must reject it because
  # the PID has likely been reused. Guards against a regression where the
  # time-window check is dropped or widened.
  $watcherRejectCaseRoot = Join-Path $RunRoot "watcher-detect-rejects-stale-pidfile"
  $watcherRejectRuntimeRoot = Join-Path $watcherRejectCaseRoot "runtime"
  $watcherRejectEnv = @{
    "USERPROFILE" = Join-Path $watcherRejectCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $watcherRejectCaseRoot "localappdata"
    "TEMP" = Join-Path $watcherRejectCaseRoot "temp"
    "TMP" = Join-Path $watcherRejectCaseRoot "temp"
    "TMPDIR" = Join-Path $watcherRejectCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $watcherRejectRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "watcher-detect-rejects-stale-pidfile" {
    New-Item -ItemType Directory -Force -Path $watcherRejectRuntimeRoot | Out-Null
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $pidFile = Join-Path $watcherRejectRuntimeRoot "watcher.pid"
      $dummy.Id | Set-Content $pidFile -NoNewline
      # Skew pidfile mtime 10 minutes into the past — this simulates a stale
      # PID file whose PID has been reused by an unrelated PowerShell process.
      (Get-Item $pidFile).LastWriteTime = $dummy.StartTime.AddMinutes(-10)
      $statusOutputPath = Join-Path $watcherRejectCaseRoot "status.txt"
      & "$RepoRoot\patch.ps1" status *> $statusOutputPath
      if (-not $?) { throw "patch.ps1 status failed in watcher-detect-rejects-stale-pidfile" }
      $scriptOutput = Get-Content -Path $statusOutputPath -Raw
      Assert-Contains $scriptOutput "Watcher:      not running"
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $watcherRejectEnv

  # New-format watcher.pid ("<pid> <StartTime.Ticks>"): an EXACT Ticks match
  # on the live process must be accepted as our watcher. The tests above
  # exercise the legacy (pid-only) compat path; these two exercise the
  # current format that Invoke-Watch actually writes.
  $ticksAcceptCaseRoot = Join-Path $RunRoot "watcher-detect-accepts-ticks-match"
  $ticksAcceptRuntimeRoot = Join-Path $ticksAcceptCaseRoot "runtime"
  $ticksAcceptEnv = @{
    "USERPROFILE" = Join-Path $ticksAcceptCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $ticksAcceptCaseRoot "localappdata"
    "TEMP" = Join-Path $ticksAcceptCaseRoot "temp"
    "TMP" = Join-Path $ticksAcceptCaseRoot "temp"
    "TMPDIR" = Join-Path $ticksAcceptCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $ticksAcceptRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "watcher-detect-accepts-ticks-match" {
    New-Item -ItemType Directory -Force -Path $ticksAcceptRuntimeRoot | Out-Null
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $pidFile = Join-Path $ticksAcceptRuntimeRoot "watcher.pid"
      # Refresh the process object so StartTime is populated reliably.
      $proc = Get-Process -Id $dummy.Id
      "$($proc.Id) $($proc.StartTime.Ticks)" | Set-Content $pidFile -NoNewline
      $statusOutputPath = Join-Path $ticksAcceptCaseRoot "status.txt"
      & "$RepoRoot\patch.ps1" status *> $statusOutputPath
      if (-not $?) { throw "patch.ps1 status failed in watcher-detect-accepts-ticks-match" }
      $scriptOutput = Get-Content -Path $statusOutputPath -Raw
      Assert-Contains $scriptOutput "Watcher:      RUNNING (PID $($dummy.Id))"
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $ticksAcceptEnv

  # Rejection side of the new format: a deliberately wrong Ticks value (or
  # a stale value that doesn't match the live process) must be rejected.
  # This covers the PID-reuse scenario the legacy time-window heuristic
  # could not fully close — a reused PID would have a different Ticks.
  $ticksRejectCaseRoot = Join-Path $RunRoot "watcher-detect-rejects-ticks-mismatch"
  $ticksRejectRuntimeRoot = Join-Path $ticksRejectCaseRoot "runtime"
  $ticksRejectEnv = @{
    "USERPROFILE" = Join-Path $ticksRejectCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $ticksRejectCaseRoot "localappdata"
    "TEMP" = Join-Path $ticksRejectCaseRoot "temp"
    "TMP" = Join-Path $ticksRejectCaseRoot "temp"
    "TMPDIR" = Join-Path $ticksRejectCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $ticksRejectRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "watcher-detect-rejects-ticks-mismatch" {
    New-Item -ItemType Directory -Force -Path $ticksRejectRuntimeRoot | Out-Null
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $pidFile = Join-Path $ticksRejectRuntimeRoot "watcher.pid"
      $proc = Get-Process -Id $dummy.Id
      # Simulate PID reuse: the pidfile records some other Ticks (1h off).
      $fakeTicks = $proc.StartTime.AddHours(-1).Ticks
      "$($proc.Id) $fakeTicks" | Set-Content $pidFile -NoNewline
      $statusOutputPath = Join-Path $ticksRejectCaseRoot "status.txt"
      & "$RepoRoot\patch.ps1" status *> $statusOutputPath
      if (-not $?) { throw "patch.ps1 status failed in watcher-detect-rejects-ticks-mismatch" }
      $scriptOutput = Get-Content -Path $statusOutputPath -Raw
      Assert-Contains $scriptOutput "Watcher:      not running"
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $ticksRejectEnv

  # Direct regression guard for Stop-WatchProcess: a stale watcher.pid whose
  # PID has been reused by an unrelated PowerShell process must NOT get
  # killed. Before this guard, Update-Self / Invoke-Disable would cheerfully
  # Stop-Process any powershell.exe whose PID happened to match.
  $stopReuseCaseRoot = Join-Path $RunRoot "stop-watcher-rejects-reused-pid"
  $stopReuseRuntimeRoot = Join-Path $stopReuseCaseRoot "runtime"
  $stopReuseEnv = @{
    "USERPROFILE" = Join-Path $stopReuseCaseRoot "home"
    "LOCALAPPDATA" = Join-Path $stopReuseCaseRoot "localappdata"
    "TEMP" = Join-Path $stopReuseCaseRoot "temp"
    "TMP" = Join-Path $stopReuseCaseRoot "temp"
    "TMPDIR" = Join-Path $stopReuseCaseRoot "temp"
    "GEMINI_INSTALL_DIR" = $stopReuseRuntimeRoot
    "GEMINI_LOCAL_STATE_PATH" = Join-Path $FixtureDir "healthy.json"
    "GEMINI_CHROME_VERSION" = "136.0.7103.49"
    "GEMINI_CHROME_RUNNING" = "0"
  }
  Invoke-Case "stop-watcher-rejects-reused-pid" {
    New-Item -ItemType Directory -Force -Path $stopReuseRuntimeRoot | Out-Null
    # Spawn a long-running PowerShell that stands in for "some unrelated
    # user script whose PID happens to match our stale watcher.pid".
    $dummy = Start-Process -FilePath "powershell.exe" `
      -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' `
      -PassThru -WindowStyle Hidden
    try {
      $pidFile = Join-Path $stopReuseRuntimeRoot "watcher.pid"
      $dummy.Id | Set-Content $pidFile -NoNewline
      (Get-Item $pidFile).LastWriteTime = $dummy.StartTime.AddMinutes(-10)

      # Dot-source patch.ps1 in a child scope (using 'help' so the final
      # switch is a no-op that touches nothing — no registry, no network,
      # no Chrome) and then invoke Stop-WatchProcess directly. Running it
      # through Invoke-Disable would have the side effect of wiping the
      # real machine's HKCU Run key.
      & {
        . "$RepoRoot\patch.ps1" help *> $null
        Stop-WatchProcess *> $null
      }

      $stillAlive = Get-Process -Id $dummy.Id -ErrorAction SilentlyContinue
      if ($stillAlive -and -not $stillAlive.HasExited) {
        Write-Host "[PASS] Stop-WatchProcess did not kill unrelated PID $($dummy.Id)"
      } else {
        Write-Host "[FAIL] Stop-WatchProcess killed unrelated PID $($dummy.Id)"
        $global:Failures++
      }
      Assert-FileMissing $pidFile
    }
    finally {
      Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
  } -CaseEnv $stopReuseEnv

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
