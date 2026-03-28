param(
  [string]$Case = ""
)

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..").Path
$FixtureDir = Join-Path $RepoRoot "tests\fixtures\local-state"
$RunRoot = Join-Path $env:TEMP ("gemini-chrome-autoinstall-tests-" + [guid]::NewGuid().ToString())

$global:Failures = 0

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  if ($Case -and $Case -ne $Name) {
    return
  }

  Write-Host "==> $Name"

  $originalEnv = @{}
  Get-ChildItem Env:GEMINI_* -ErrorAction SilentlyContinue | ForEach-Object {
    $originalEnv[$_.Name] = $_.Value
  }

  $caseExitCode = 0
  $caseOutput = $null

  try {
    $caseOutput = & { & $Action } 2>&1 | Out-String
    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
      $caseExitCode = $LASTEXITCODE
    }
  }
  catch {
    $caseExitCode = 1
    $caseOutput = $_.Exception.Message
  }
  finally {
    $currentEnv = @{}
    Get-ChildItem Env:GEMINI_* -ErrorAction SilentlyContinue | ForEach-Object {
      $currentEnv[$_.Name] = $_.Value
    }

    foreach ($envName in $currentEnv.Keys) {
      if (-not $originalEnv.ContainsKey($envName)) {
        Remove-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
      }
    }

    foreach ($envName in $originalEnv.Keys) {
      Set-Item -Path "Env:$envName" -Value $originalEnv[$envName]
    }
  }

  if ($caseExitCode -ne 0) {
    Write-Host "[FAIL] command failed with exit $caseExitCode"
    if ($caseOutput) {
      Write-Host $caseOutput
    }
    $global:Failures++
  }
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

  Invoke-Case "status-shows-tool-version" {
    $scriptOutput = & "$RepoRoot\patch.ps1" status | Out-String
    Assert-Contains $scriptOutput "Tool version:"
  }

  Invoke-Case "tri-state-healthy" {
    $workRoot = Join-Path $RunRoot "tri-state-healthy"
    $runtimeRoot = Join-Path $workRoot "runtime"
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    $env:GEMINI_INSTALL_DIR = $runtimeRoot
    $env:GEMINI_LOCAL_STATE_PATH = Join-Path $FixtureDir "healthy.json"
    $env:GEMINI_CHROME_VERSION = "136.0.7103.49"
    $env:GEMINI_CHROME_RUNNING = "0"
    & "$RepoRoot\patch.ps1" run | Out-Null
    Assert-FileContains (Join-Path $runtimeRoot "last-result") "status=healthy"
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
