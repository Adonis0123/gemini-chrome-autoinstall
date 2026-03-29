# Self-Update Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add silent self-update to `patch.sh` and `patch.ps1` so installed tools auto-update from GitHub.

**Architecture:** Piggyback on existing `run` / `scheduled` triggers. Fetch remote `VERSION` file, compare with local, download new scripts if different. 24h cooldown via timestamp file.

**Tech Stack:** Bash (macOS), PowerShell (Windows), `curl` / `Invoke-WebRequest`, `python3 -m http.server` for tests.

**Spec:** `docs/superpowers/specs/2026-03-29-self-update-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `patch.sh` | Modify | Add `RAW_BASE` vars (after line 24), add `check_self_update()` function (before `cmd_run`), call from `cmd_run()` |
| `patch.ps1` | Modify | Add `$RawBase` vars (after line 27), add `Update-Self` function (before `Invoke-Run`), call from `Invoke-Run` and `Invoke-Scheduled` |
| `tests/self-update/fixtures/newer/VERSION` | Create | Fixture: `v99.0.0` |
| `tests/self-update/fixtures/newer/patch.sh` | Create | Fixture: minimal placeholder script |
| `tests/self-update/fixtures/newer/patch.ps1` | Create | Fixture: minimal placeholder script |
| `tests/self-update/fixtures/newer/launcher.vbs` | Create | Fixture: minimal placeholder |
| `tests/self-update/fixtures/same/VERSION` | Create | Fixture: copy of current VERSION |
| `tests/self-update/fixtures/same/patch.sh` | Create | Fixture: copy of current patch.sh |
| `tests/self-update/fixtures/partial/VERSION` | Create | Fixture: `v99.0.0` (but no patch.sh) |
| `tests/self-update/run-tests.sh` | Create | macOS test runner with 8 test cases |
| `tests/self-update/run-tests.ps1` | Create | Windows test runner with 8 test cases |

---

## Chunk 1: macOS Implementation

### Task 1: Add `RAW_BASE` variables to `patch.sh`

**Files:**
- Modify: `patch.sh:24` (after `NEEDS_PATCH_CHROME_VERSION=""`)

- [ ] **Step 1: Add variables**

Add after line 24 (`NEEDS_PATCH_CHROME_VERSION=""`):

```bash
REPO="Adonis0123/gemini-chrome-autoinstall"
BRANCH="master"
RAW_BASE="${GEMINI_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
```

- [ ] **Step 2: Verify script still loads**

Run: `bash patch.sh help`
Expected: Usage text prints normally, no errors.

- [ ] **Step 3: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(mac): add RAW_BASE variable for self-update"
```

---

### Task 2: Add `check_self_update()` function to `patch.sh`

**Files:**
- Modify: `patch.sh` (insert before `cmd_run()` at line 723)

- [ ] **Step 1: Add the function**

Insert before `cmd_run()` (line 723):

```bash
check_self_update() {
    local check_file="$INSTALL_DIR/last-update-check"
    local now=$(date +%s)

    # 24h cooldown
    if [ -f "$check_file" ]; then
        local last=$(cat "$check_file")
        if [ $((now - last)) -lt 86400 ]; then
            return 0
        fi
    fi

    # Fetch remote version
    local remote_ver
    remote_ver=$(curl -fsSL --max-time 5 "$RAW_BASE/VERSION" 2>/dev/null) || {
        log "Self-update check failed: network error"
        return 0
    }
    remote_ver=$(echo "$remote_ver" | tr -d '\n')
    local local_ver=$(get_tool_version)

    # Update timestamp before download — intentional: if download fails,
    # we still wait 24h before retrying to avoid hammering the network.
    # Natural retry happens on the next day's trigger cycle.
    echo "$now" > "$check_file"

    [ "$remote_ver" = "$local_ver" ] && return 0

    # Download to temp, then move
    local tmp=$(mktemp -d)
    curl -fsSL --max-time 10 "$RAW_BASE/patch.sh" -o "$tmp/patch.sh" &&
    curl -fsSL --max-time 5  "$RAW_BASE/VERSION" -o "$tmp/VERSION" || {
        log "Self-update download failed"
        rm -rf "$tmp"
        return 0
    }
    chmod +x "$tmp/patch.sh"
    mv "$tmp/patch.sh" "$INSTALL_DIR/patch.sh"
    mv "$tmp/VERSION"  "$INSTALL_DIR/VERSION"
    rm -rf "$tmp"
    log "Self-updated from $local_ver to $remote_ver"
}
```

- [ ] **Step 2: Call from `cmd_run()`**

Change `cmd_run()` from:

```bash
cmd_run() {
    log "Run triggered."
    reconcile_patch_state "run" || true
```

To:

```bash
cmd_run() {
    check_self_update
    log "Run triggered."
    reconcile_patch_state "run" || true
```

- [ ] **Step 3: Verify script still loads**

Run: `bash patch.sh help`
Expected: Usage text prints normally.

- [ ] **Step 4: Commit**

```bash
git add patch.sh
git commit -m "🎉 feat(mac): add check_self_update function and call from cmd_run"
```

---

## Chunk 2: Windows Implementation

### Task 3: Add `$RawBase` variables to `patch.ps1`

**Files:**
- Modify: `patch.ps1:27` (after `$script:NeedsPatchChromeVersion = $null`)

- [ ] **Step 1: Add variables**

Add after line 27 (`$script:NeedsPatchChromeVersion = $null`):

```powershell
$Repo = "Adonis0123/gemini-chrome-autoinstall"
$Branch = "master"
$RawBase = if ($env:GEMINI_RAW_BASE) { $env:GEMINI_RAW_BASE } else { "https://raw.githubusercontent.com/$Repo/$Branch" }
```

- [ ] **Step 2: Commit**

```bash
git add patch.ps1
git commit -m "🎉 feat(win): add RawBase variable for self-update"
```

---

### Task 4: Add `Update-Self` function to `patch.ps1`

**Files:**
- Modify: `patch.ps1` (insert before `Invoke-Run` at line 708)

- [ ] **Step 1: Add the function**

Insert before `function Invoke-Run` (line 708):

```powershell
function Update-Self {
    $checkFile = Join-Path $InstallDir "last-update-check"
    $now = [int](Get-Date -UFormat %s)

    # 24h cooldown (with parse protection for corrupted timestamp files)
    if (Test-Path $checkFile) {
        $last = 0
        [int]::TryParse((Get-Content $checkFile -Raw).Trim(), [ref]$last) | Out-Null
        if (($now - $last) -lt 86400) { return }
    }

    # Fetch remote version
    try {
        $remoteVer = (Invoke-WebRequest -Uri "$RawBase/VERSION" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
    } catch {
        Write-Log "Self-update check failed: $_"
        return
    }
    $localVer = Get-ToolVersion

    # Update timestamp before download — intentional: avoids hammering
    # the network on repeated failures. Retry happens next day.
    $now | Set-Content $checkFile -NoNewline

    if ($remoteVer -eq $localVer) { return }

    # Download to temp, then move
    $tmp = Join-Path $env:TEMP "gemini-self-update"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Invoke-WebRequest -Uri "$RawBase/patch.ps1"    -OutFile "$tmp\patch.ps1"    -TimeoutSec 10 -UseBasicParsing
        Invoke-WebRequest -Uri "$RawBase/launcher.vbs" -OutFile "$tmp\launcher.vbs" -TimeoutSec 5  -UseBasicParsing
        Invoke-WebRequest -Uri "$RawBase/VERSION"      -OutFile "$tmp\VERSION"      -TimeoutSec 5  -UseBasicParsing
    } catch {
        Write-Log "Self-update download failed: $_"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Move-Item "$tmp\patch.ps1"    (Join-Path $InstallDir "patch.ps1")    -Force
    Move-Item "$tmp\launcher.vbs" (Join-Path $InstallDir "launcher.vbs") -Force
    Move-Item "$tmp\VERSION"      (Join-Path $InstallDir "VERSION")      -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Self-updated from $localVer to $remoteVer"
}
```

- [ ] **Step 2: Call from `Invoke-Run`**

Change `Invoke-Run` from:

```powershell
function Invoke-Run {
    Write-Log "Run triggered."
    [void](Invoke-Reconcile -Trigger "run")
}
```

To:

```powershell
function Invoke-Run {
    Update-Self
    Write-Log "Run triggered."
    [void](Invoke-Reconcile -Trigger "run")
}
```

- [ ] **Step 3: Call from `Invoke-Scheduled`**

Change `Invoke-Scheduled` from:

```powershell
function Invoke-Scheduled {
    Write-Log "Scheduled entry triggered."

    [void](Invoke-Reconcile -Trigger "startup")
```

To:

```powershell
function Invoke-Scheduled {
    Update-Self
    Write-Log "Scheduled entry triggered."

    [void](Invoke-Reconcile -Trigger "startup")
```

- [ ] **Step 4: Commit**

```bash
git add patch.ps1
git commit -m "🎉 feat(win): add Update-Self function and call from Invoke-Run and Invoke-Scheduled"
```

---

## Chunk 3: Test Fixtures

### Task 5: Create test fixture files

**Files:**
- Create: `tests/self-update/fixtures/newer/VERSION`
- Create: `tests/self-update/fixtures/newer/patch.sh`
- Create: `tests/self-update/fixtures/newer/patch.ps1`
- Create: `tests/self-update/fixtures/newer/launcher.vbs`
- Create: `tests/self-update/fixtures/same/VERSION`
- Create: `tests/self-update/fixtures/same/patch.sh`
- Create: `tests/self-update/fixtures/partial/VERSION`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p tests/self-update/fixtures/newer
mkdir -p tests/self-update/fixtures/same
mkdir -p tests/self-update/fixtures/partial
```

- [ ] **Step 2: Create "newer" fixtures**

`tests/self-update/fixtures/newer/VERSION`:
```
v99.0.0
```

`tests/self-update/fixtures/newer/patch.sh`:
```bash
#!/usr/bin/env bash
# Self-update test fixture — newer version placeholder
echo "patch.sh v99.0.0 fixture"
```

`tests/self-update/fixtures/newer/patch.ps1`:
```powershell
# Self-update test fixture — newer version placeholder
Write-Host "patch.ps1 v99.0.0 fixture"
```

`tests/self-update/fixtures/newer/launcher.vbs`:
```vbs
' Self-update test fixture — newer version placeholder
WScript.Echo "launcher.vbs v99.0.0 fixture"
```

- [ ] **Step 3: Create "same" fixtures**

`tests/self-update/fixtures/same/VERSION` — copy current VERSION content:
```bash
cp VERSION tests/self-update/fixtures/same/VERSION
cp patch.sh tests/self-update/fixtures/same/patch.sh
```

- [ ] **Step 4: Create "partial" fixtures (VERSION only, no patch.sh)**

`tests/self-update/fixtures/partial/VERSION`:
```
v99.0.0
```

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "🧪 test: add self-update test fixtures"
```

---

## Chunk 4: macOS Test Runner

### Task 6: Create macOS test runner

**Files:**
- Create: `tests/self-update/run-tests.sh`

- [ ] **Step 1: Write the test runner**

`tests/self-update/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
TEST_INSTALL_DIR=$(mktemp -d)
TEST_LOG_FILE="$TEST_INSTALL_DIR/test.log"
PORT=18923
PASS=0
FAIL=0

cleanup() {
    stop_server
    rm -rf "$TEST_INSTALL_DIR"
}
trap cleanup EXIT

# --- Helpers ---

start_server() { # $1 = fixture dir
    cd "$1" && python3 -m http.server $PORT &>/dev/null &
    SERVER_PID=$!
    sleep 0.5
    cd "$SCRIPT_DIR"
}

stop_server() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        unset SERVER_PID
    fi
}

reset_install_dir() {
    rm -rf "$TEST_INSTALL_DIR"
    mkdir -p "$TEST_INSTALL_DIR"
    cp "$PROJECT_ROOT/patch.sh" "$TEST_INSTALL_DIR/patch.sh"
    chmod +x "$TEST_INSTALL_DIR/patch.sh"
    echo "" > "$TEST_LOG_FILE"
}

assert_contains() { # $1=file, $2=pattern, $3=test name
    if grep -q "$2" "$1" 2>/dev/null; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (expected '$2' in $(basename "$1"))"
    fi
}

assert_not_contains() { # $1=file, $2=pattern, $3=test name
    if ! grep -q "$2" "$1" 2>/dev/null; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (did not expect '$2' in $(basename "$1"))"
    fi
}

assert_file_content() { # $1=file, $2=expected, $3=test name
    local actual
    actual=$(tr -d '\n' < "$1")
    if [ "$actual" = "$2" ]; then
        ((PASS++)); echo "  ✓ PASS: $3"
    else
        ((FAIL++)); echo "  ✗ FAIL: $3 (expected '$2', got '$actual')"
    fi
}

assert_file_exists() { # $1=file, $2=test name
    if [ -f "$1" ]; then
        ((PASS++)); echo "  ✓ PASS: $2"
    else
        ((FAIL++)); echo "  ✗ FAIL: $2 (file not found: $1)"
    fi
}

assert_file_not_exists() { # $1=file, $2=test name
    if [ ! -f "$1" ]; then
        ((PASS++)); echo "  ✓ PASS: $2"
    else
        ((FAIL++)); echo "  ✗ FAIL: $2 (file should not exist: $1)"
    fi
}

run_patch() { # runs patch.sh run in isolated env
    GEMINI_INSTALL_DIR="$TEST_INSTALL_DIR" \
    GEMINI_RAW_BASE="http://localhost:$PORT" \
    GEMINI_LOG_FILE="$TEST_LOG_FILE" \
    GEMINI_LOCAL_STATE_PATH="/dev/null" \
        bash "$TEST_INSTALL_DIR/patch.sh" run 2>/dev/null || true
}

# === Tests ===

echo "=== Self-Update Tests (macOS) ==="
echo ""

# --- Test 1: Remote has newer version ---
echo "Test 1: Remote has newer version"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated to v99.0.0"
assert_contains "$TEST_LOG_FILE" "Self-updated from v0.0.1 to v99.0.0" "Log contains Self-updated message"
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created"
echo ""

# --- Test 2: Version identical ---
echo "Test 2: Version identical"
reset_install_dir
cp "$PROJECT_ROOT/VERSION" "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/same"
run_patch
stop_server
assert_not_contains "$TEST_LOG_FILE" "Self-updated" "No Self-updated log"
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created"
echo ""

# --- Test 3: Cooldown not expired ---
echo "Test 3: Cooldown not expired (should skip)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
echo "$(date +%s)" > "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged (cooldown active)"
assert_not_contains "$TEST_LOG_FILE" "Self-updated" "No Self-updated log"
echo ""

# --- Test 4: Cooldown expired ---
echo "Test 4: Cooldown expired (should check)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
echo "$(( $(date +%s) - 90000 ))" > "$TEST_INSTALL_DIR/last-update-check"  # 25 hours ago
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated after cooldown expired"
assert_contains "$TEST_LOG_FILE" "Self-updated" "Log contains Self-updated message"
echo ""

# --- Test 5: Network unreachable ---
echo "Test 5: Network unreachable"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
# No server started — use unreachable address
GEMINI_INSTALL_DIR="$TEST_INSTALL_DIR" \
GEMINI_RAW_BASE="http://127.0.0.1:19999" \
GEMINI_LOG_FILE="$TEST_LOG_FILE" \
GEMINI_LOCAL_STATE_PATH="/dev/null" \
    bash "$TEST_INSTALL_DIR/patch.sh" run 2>/dev/null || true
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged"
assert_contains "$TEST_LOG_FILE" "network error" "Log contains network error"
echo ""

# --- Test 6: Partial download failure ---
echo "Test 6: Partial download failure (VERSION only, no patch.sh)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
local_patch_hash=$(md5 -q "$TEST_INSTALL_DIR/patch.sh")
start_server "$FIXTURES/partial"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v0.0.1" "VERSION unchanged after partial failure"
assert_contains "$TEST_LOG_FILE" "download failed" "Log contains download failed"
new_patch_hash=$(md5 -q "$TEST_INSTALL_DIR/patch.sh")
if [ "$local_patch_hash" = "$new_patch_hash" ]; then
    ((PASS++)); echo "  ✓ PASS: patch.sh unchanged"
else
    ((FAIL++)); echo "  ✗ FAIL: patch.sh was modified"
fi
echo ""

# --- Test 7: First check (no timestamp file) ---
echo "Test 7: First check (no timestamp file)"
reset_install_dir
echo "v0.0.1" > "$TEST_INSTALL_DIR/VERSION"
rm -f "$TEST_INSTALL_DIR/last-update-check"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_exists "$TEST_INSTALL_DIR/last-update-check" "Timestamp file created on first check"
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION updated on first check"
echo ""

# --- Test 8: No local VERSION file ---
echo "Test 8: No local VERSION file"
reset_install_dir
rm -f "$TEST_INSTALL_DIR/VERSION"
start_server "$FIXTURES/newer"
run_patch
stop_server
assert_file_content "$TEST_INSTALL_DIR/VERSION" "v99.0.0" "VERSION created from remote"
assert_contains "$TEST_LOG_FILE" "Self-updated from unknown to v99.0.0" "Log shows update from unknown"
echo ""

# === Results ===
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/self-update/run-tests.sh
```

- [ ] **Step 3: Run all tests**

Run: `bash tests/self-update/run-tests.sh`
Expected: All 8 tests pass (some may need debugging — fix any failures).

- [ ] **Step 4: Commit**

```bash
git add tests/self-update/run-tests.sh
git commit -m "🧪 test: add macOS self-update test runner with 8 test cases"
```

---

## Chunk 5: Windows Test Runner

### Task 7: Create Windows test runner

**Files:**
- Create: `tests/self-update/run-tests.ps1`

- [ ] **Step 1: Write the test runner**

`tests/self-update/run-tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run all tests (Windows only)**

Run: `powershell -File tests/self-update/run-tests.ps1`
Expected: All 8 tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/self-update/run-tests.ps1
git commit -m "🧪 test: add Windows self-update test runner with 8 test cases"
```

---

## Chunk 6: Documentation Update

### Task 8: Update CLAUDE.md with self-update details

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add self-update section to CLAUDE.md**

Add to the `### Key paths at runtime` table:

```
| Update check | `$INSTALL_DIR/last-update-check` | `$InstallDir\last-update-check` |
```

Add a new subsection under `## Architecture`:

```markdown
### Self-update mechanism
- Triggered at the start of `run` (macOS) and `run`/`scheduled` (Windows)
- Fetches `VERSION` from `raw.githubusercontent.com`, compares with local
- If different, downloads new script files to temp dir, then moves to install dir
- 24h cooldown via `last-update-check` timestamp file
- Network failures are logged and silently skipped — never blocks core patch logic
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: add self-update mechanism to CLAUDE.md"
```

---

## Task Dependency Graph

```
Task 1 (RAW_BASE vars in patch.sh)
  → Task 2 (check_self_update in patch.sh)

Task 3 (RawBase vars in patch.ps1)
  → Task 4 (Update-Self in patch.ps1)

Task 5 (Test fixtures) — independent

Task 2 + Task 5
  → Task 6 (macOS test runner)

Task 4 + Task 5
  → Task 7 (Windows test runner)

Task 6 + Task 7
  → Task 8 (CLAUDE.md docs)
```

Tasks 1-2 (macOS) and Tasks 3-4 (Windows) can be done in parallel.
Task 5 (fixtures) can be done in parallel with Tasks 1-4.
Task 6 (macOS tests) requires Tasks 2 and 5.
Task 7 (Windows tests) requires Tasks 4 and 5.
Task 8 (docs) is last.
