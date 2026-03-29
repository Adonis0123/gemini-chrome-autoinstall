$installMode = if ($env:GEMINI_FAKE_INSTALL_MODE) { $env:GEMINI_FAKE_INSTALL_MODE } else { "success" }
if (-not $env:GEMINI_LOCAL_STATE_PATH) {
  Write-Error "GEMINI_LOCAL_STATE_PATH is required"
  exit 2
}
$destinationDir = Split-Path -Path $env:GEMINI_LOCAL_STATE_PATH -Parent
New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null

switch ($installMode) {
    "success"     { Copy-Item "$PSScriptRoot\..\fixtures\local-state\healthy.json" $env:GEMINI_LOCAL_STATE_PATH -Force }
    "verify_fail" { Copy-Item "$PSScriptRoot\..\fixtures\local-state\drifted-glic-false.json" $env:GEMINI_LOCAL_STATE_PATH -Force }
    "patch_fail"  { exit 1 }
    default       { Write-Error "Unknown GEMINI_FAKE_INSTALL_MODE: $installMode"; exit 2 }
}
