$installMode = if ($env:GEMINI_FAKE_INSTALL_MODE) { $env:GEMINI_FAKE_INSTALL_MODE } else { "success" }
switch ($installMode) {
    "success"     { Copy-Item "$PSScriptRoot\..\fixtures\local-state\healthy.json" $env:GEMINI_LOCAL_STATE_PATH -Force }
    "verify_fail" { Copy-Item "$PSScriptRoot\..\fixtures\local-state\drifted-glic-false.json" $env:GEMINI_LOCAL_STATE_PATH -Force }
    "patch_fail"  { exit 1 }
    default       { Write-Error "Unknown GEMINI_FAKE_INSTALL_MODE: $installMode"; exit 2 }
}
