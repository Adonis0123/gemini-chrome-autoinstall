#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/local-state"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gemini-chrome-autoinstall-tests.XXXXXX")"
export TMPDIR="$TMP_ROOT"

trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_CASES=("$@")
FAILURES=0
CASE_OUTPUT=""
CASES_RUN=0

should_run_case() {
  local case_name="$1"
  if [[ "${#TEST_CASES[@]}" -eq 0 ]]; then
    return 0
  fi

  local requested
  for requested in "${TEST_CASES[@]}"; do
    if [[ "${requested}" == "${case_name}" ]]; then
      return 0
    fi
  done

  return 1
}

run_case() {
  local case_name="$1"
  shift

  if ! should_run_case "${case_name}"; then
    return 2
  fi

  echo "==> ${case_name}"
  CASES_RUN=$((CASES_RUN + 1))
  local case_home="$TMP_ROOT/home/${case_name}"
  mkdir -p "$case_home/Library/Logs"

  set +e
  CASE_OUTPUT="$(cd "$REPO_ROOT" && HOME="$case_home" "$@" 2>&1)"
  local command_exit=$?
  set -e

  if [[ ${command_exit} -ne 0 ]]; then
    echo "[FAIL] command failed with exit ${command_exit}"
    if [[ -n "${CASE_OUTPUT}" ]]; then
      echo "${CASE_OUTPUT}"
    fi
    echo
    FAILURES=$((FAILURES + 1))
  fi

  return "${command_exit}"
}

assert_contains() {
  local output="$1"
  local expected="$2"

  if [[ "${output}" == *"${expected}"* ]]; then
    echo "[PASS] output contains: ${expected}"
  else
    echo "[FAIL] output missing expected string: ${expected}"
    echo "  expected: ${expected}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"

  if [[ ! -f "${file_path}" ]]; then
    echo "[FAIL] missing file: ${file_path}"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  if grep -Fq -- "${expected}" "${file_path}"; then
    echo "[PASS] file contains: ${expected}"
  else
    echo "[FAIL] file missing expected text: ${expected}"
    echo "  expected in: ${file_path}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_file_missing() {
  local file_path="$1"

  if [[ -f "${file_path}" ]]; then
    echo "[FAIL] expected file to be missing: ${file_path}"
    FAILURES=$((FAILURES + 1))
  else
    echo "[PASS] file is missing: ${file_path}"
  fi
}

if run_case "status-shows-tool-version" env bash patch.sh status; then
  assert_contains "${CASE_OUTPUT}" "Tool version:"
fi

if run_case "install-prints-version" env \
  GEMINI_INSTALL_DIR="$TMPDIR/install" \
  GEMINI_SKIP_ENABLE="1" \
  GEMINI_SKIP_FIRST_PATCH="1" \
  bash install.sh; then
  assert_contains "${CASE_OUTPUT}" "Tool version: v"
  assert_file_contains "$TMPDIR/install/VERSION" "v"
fi

TRI_STATE_RUNTIME_DIR="$TMP_ROOT/runtime/tri-state-healthy"
if run_case "tri-state-healthy" env \
  GEMINI_INSTALL_DIR="$TRI_STATE_RUNTIME_DIR" \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/healthy.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash patch.sh run; then
  assert_file_contains "$TRI_STATE_RUNTIME_DIR/last-result" "status=healthy"
fi

if run_case "tri-state-drifted-country" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime/tri-state-drifted-country" \
  GEMINI_LOCAL_STATE_PATH="$TMPDIR/runtime/tri-state-drifted-country/local-state.json" \
  GEMINI_CORE_INSTALL_CMD="$REPO_ROOT/tests/helpers/fake-core-install.sh" \
  GEMINI_FAKE_INSTALL_MODE="success" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash -c "mkdir -p \"$TMPDIR/runtime/tri-state-drifted-country\" && cp \"$FIXTURE_DIR/drifted-variations-country.json\" \"$TMPDIR/runtime/tri-state-drifted-country/local-state.json\" && bash patch.sh run"; then
  assert_file_contains "$TMPDIR/runtime/tri-state-drifted-country/last-result" "status=healthy"
fi

if run_case "status-drifted-permanent-country-while-running" env \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/drifted-permanent-country.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="1" \
  bash patch.sh status; then
  assert_contains "${CASE_OUTPUT}" "Current state: drifted"
fi

if run_case "tri-state-unknown-missing-glic" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime/tri-state-unknown-missing-glic" \
  GEMINI_LOCAL_STATE_PATH="$TMPDIR/runtime/tri-state-unknown-missing-glic/local-state.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash -c "mkdir -p \"$TMPDIR/runtime/tri-state-unknown-missing-glic\" && cp \"$FIXTURE_DIR/unknown-missing-glic.json\" \"$TMPDIR/runtime/tri-state-unknown-missing-glic/local-state.json\" && bash patch.sh run"; then
  assert_file_contains "$TMPDIR/runtime/tri-state-unknown-missing-glic/last-result" "status=detect_error"
  assert_file_contains "$TMPDIR/runtime/tri-state-unknown-missing-glic/last-result" "reason=missing_required_fields"
fi

if run_case "tri-state-unknown-invalid-json" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime" \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/unknown-invalid.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash patch.sh run; then
  assert_file_contains "$TMPDIR/runtime/last-result" "status=detect_error"
fi

if run_case "chrome-running-creates-pending" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime" \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/drifted-variations-country.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="1" \
  bash patch.sh run; then
  assert_file_contains "$TMPDIR/runtime/pending" "reason=blocked"
  assert_file_contains "$TMPDIR/runtime/last-result" "status=blocked"
fi

if run_case "pending-settles-after-close" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime" \
  GEMINI_LOCAL_STATE_PATH="$TMPDIR/runtime/Local State" \
  GEMINI_CORE_INSTALL_CMD="$REPO_ROOT/tests/helpers/fake-core-install.sh" \
  GEMINI_FAKE_INSTALL_MODE="success" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash patch.sh retry; then
  assert_file_missing "$TMPDIR/runtime/pending"
  assert_file_contains "$TMPDIR/runtime/last-result" "status=healthy"
fi

if run_case "patch-failure-recorded" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime" \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/drifted-glic-false.json" \
  GEMINI_CORE_INSTALL_CMD="$REPO_ROOT/tests/helpers/fake-core-install.sh" \
  GEMINI_FAKE_INSTALL_MODE="patch_fail" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash patch.sh run; then
  assert_file_contains "$TMPDIR/runtime/last-result" "status=patch_failed"
fi

if run_case "verify-failure-recorded" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime/verify-failure" \
  GEMINI_LOCAL_STATE_PATH="$TMPDIR/runtime/verify-failure/local-state.json" \
  GEMINI_CORE_INSTALL_CMD="$REPO_ROOT/tests/helpers/fake-core-install.sh" \
  GEMINI_FAKE_INSTALL_MODE="verify_fail" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash -c "mkdir -p \"$TMPDIR/runtime/verify-failure\" && cp \"$FIXTURE_DIR/drifted-glic-false.json\" \"$TMPDIR/runtime/verify-failure/local-state.json\" && bash patch.sh run"; then
  assert_file_contains "$TMPDIR/runtime/verify-failure/last-result" "status=verify_failed"
fi

WATCHER_RUNTIME_DIR="$TMP_ROOT/runtime/watcher-patches"
if run_case "watcher-patches-on-chrome-close" bash -c "
  mkdir -p '$WATCHER_RUNTIME_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_RUNTIME_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_RUNTIME_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_RUNTIME_DIR/local-state.json'
  export GEMINI_CORE_INSTALL_CMD='$REPO_ROOT/tests/helpers/fake-core-install.sh'
  export GEMINI_FAKE_INSTALL_MODE='success'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_RUNTIME_DIR/test.log'

  fake_bin='${TMPDIR}/Google Chrome'
  cp /bin/sleep \"\$fake_bin\" 2>/dev/null || true; chmod +x \"\$fake_bin\"
  \"\$fake_bin\" 9999 &
  CHROME_PID=\$!

  bash patch.sh watcher &
  WATCHER_PID=\$!
  sleep 2

  kill \"\$CHROME_PID\" 2>/dev/null; wait \"\$CHROME_PID\" 2>/dev/null || true

  for i in \$(seq 1 10); do
    kill -0 \"\$WATCHER_PID\" 2>/dev/null || break
    sleep 1
  done
  wait \"\$WATCHER_PID\" 2>/dev/null || true
"; then
  assert_file_contains "$WATCHER_RUNTIME_DIR/last-result" "status=healthy"
  assert_file_missing "$WATCHER_RUNTIME_DIR/pending"
fi

WATCHER_DUP_DIR="$TMP_ROOT/runtime/watcher-dup"
if run_case "watcher-no-duplicate-spawn" bash -c "
  mkdir -p '$WATCHER_DUP_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_DUP_DIR'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_DUP_DIR/test.log'

  echo \"\$\$ \$(date +%s)\" > '$WATCHER_DUP_DIR/watcher.pid'
  bash patch.sh watcher
"; then
  assert_file_contains "$WATCHER_DUP_DIR/test.log" "another instance already running"
fi

WATCHER_STALE_DIR="$TMP_ROOT/runtime/watcher-stale"
if run_case "watcher-stale-pid-recovery" bash -c "
  mkdir -p '$WATCHER_STALE_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_STALE_DIR'
  export GEMINI_CHROME_RUNNING='0'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_STALE_DIR/test.log'

  echo '99999 1700000000' > '$WATCHER_STALE_DIR/watcher.pid'
  bash patch.sh watcher
"; then
  assert_file_contains "$WATCHER_STALE_DIR/test.log" "Watcher started"
fi

WATCHER_PERF_DIR="$TMP_ROOT/runtime/watcher-perf"
if run_case "watcher-response-time" bash -c "
  mkdir -p '$WATCHER_PERF_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_PERF_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_PERF_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_PERF_DIR/local-state.json'
  export GEMINI_CORE_INSTALL_CMD='$REPO_ROOT/tests/helpers/fake-core-install.sh'
  export GEMINI_FAKE_INSTALL_MODE='success'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_PERF_DIR/test.log'

  fake_bin='${TMPDIR}/Google Chrome'
  cp /bin/sleep \"\$fake_bin\" 2>/dev/null || true; chmod +x \"\$fake_bin\"
  \"\$fake_bin\" 9999 &
  CPID=\$!

  bash patch.sh watcher &
  WPID=\$!
  sleep 1

  BEFORE=\$(date +%s)
  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true

  for i in \$(seq 1 10); do
    kill -0 \"\$WPID\" 2>/dev/null || break
    sleep 1
  done
  AFTER=\$(date +%s)
  ELAPSED=\$(( AFTER - BEFORE ))
  echo \"response_time=\${ELAPSED}s\"

  wait \"\$WPID\" 2>/dev/null || true
  [ \"\$ELAPSED\" -le 10 ] || { echo 'TIMEOUT: watcher took > 10s'; exit 1; }
"; then
  assert_contains "${CASE_OUTPUT}" "response_time="
fi

WATCHER_CPU_DIR="$TMP_ROOT/runtime/watcher-cpu"
if run_case "watcher-cpu-idle" bash -c "
  mkdir -p '$WATCHER_CPU_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_CPU_DIR'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_LOG_FILE='$WATCHER_CPU_DIR/test.log'

  fake_bin='${TMPDIR}/Google Chrome'
  cp /bin/sleep \"\$fake_bin\" 2>/dev/null || true; chmod +x \"\$fake_bin\"
  \"\$fake_bin\" 9999 &
  CPID=\$!

  bash patch.sh watcher &
  WPID=\$!

  sleep 15
  CPUTIME=\$(ps -p \"\$WPID\" -o cputime= 2>/dev/null || echo '0:00.00')
  echo \"watcher_cputime=\${CPUTIME}\"

  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
  for i in \$(seq 1 10); do kill -0 \"\$WPID\" 2>/dev/null || break; sleep 1; done
  wait \"\$WPID\" 2>/dev/null || true

  SECS=\$(echo \"\$CPUTIME\" | awk -F: '{if(NF==2) print \$1*60+\$2; else print \$1}')
  RESULT=\$(echo \"\$SECS < 2\" | bc)
  [ \"\$RESULT\" -eq 1 ] || { echo \"CPU too high: \${CPUTIME}\"; exit 1; }
"; then
  assert_contains "${CASE_OUTPUT}" "watcher_cputime="
fi

WATCHER_UNINST_DIR="$TMP_ROOT/runtime/watcher-uninst"
if run_case "watcher-cleanup-on-uninstall" bash -c "
  mkdir -p '$WATCHER_UNINST_DIR'
  export GEMINI_INSTALL_DIR='$WATCHER_UNINST_DIR'
  export GEMINI_LOCAL_STATE_PATH='$FIXTURE_DIR/healthy.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_UNINST_DIR/test.log'

  fake_bin='${TMPDIR}/Google Chrome'
  cp /bin/sleep \"\$fake_bin\" 2>/dev/null || true; chmod +x \"\$fake_bin\"
  \"\$fake_bin\" 9999 &
  CPID=\$!

  bash patch.sh watcher &
  WPID=\$!
  sleep 1

  kill -0 \"\$WPID\" || { echo 'watcher not running'; exit 1; }

  bash patch.sh uninstall 2>/dev/null || true

  sleep 1
  if kill -0 \"\$WPID\" 2>/dev/null; then
    echo 'FAIL: watcher still running after uninstall'
    kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
    exit 1
  fi
  echo 'watcher_killed=yes'
  kill \"\$CPID\" 2>/dev/null; wait \"\$CPID\" 2>/dev/null || true
"; then
  assert_contains "${CASE_OUTPUT}" "watcher_killed=yes"
fi

WATCHER_RESPAWN_DIR="$TMP_ROOT/runtime/watcher-respawn"
if run_case "retry-agent-respawns-watcher" bash -c "
  mkdir -p '$WATCHER_RESPAWN_DIR'
  cp '$FIXTURE_DIR/drifted-variations-country.json' '$WATCHER_RESPAWN_DIR/local-state.json'
  export GEMINI_INSTALL_DIR='$WATCHER_RESPAWN_DIR'
  export GEMINI_LOCAL_STATE_PATH='$WATCHER_RESPAWN_DIR/local-state.json'
  export GEMINI_CHROME_VERSION='136.0.7103.49'
  export GEMINI_CHROME_RUNNING='1'
  export GEMINI_LOG_FILE='$WATCHER_RESPAWN_DIR/test.log'

  echo 'pending' > '$WATCHER_RESPAWN_DIR/pending'
  echo 'reason=blocked' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'patch_reason=variations_country=cn' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'first_seen_at=2026-01-01T00:00:00Z' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'last_attempt_at=2026-01-01T00:00:00Z' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'retry_count=5' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'detected_version=136.0.7103.49' >> '$WATCHER_RESPAWN_DIR/pending'
  echo 'platform=macos' >> '$WATCHER_RESPAWN_DIR/pending'

  echo '99999 1700000000' > '$WATCHER_RESPAWN_DIR/watcher.pid'

  bash \"\$PWD/patch.sh\" retry
  sleep 2

  if [ -f '$WATCHER_RESPAWN_DIR/watcher.pid' ]; then
    NEW_PID=\$(head -1 '$WATCHER_RESPAWN_DIR/watcher.pid' | awk '{print \$1}')
    if [ \"\$NEW_PID\" != '99999' ] && kill -0 \"\$NEW_PID\" 2>/dev/null; then
      echo 'respawned=yes'
      kill \"\$NEW_PID\" 2>/dev/null || true
    else
      echo 'respawned=no'
    fi
  else
    echo 'respawned=no'
  fi
"; then
  assert_contains "${CASE_OUTPUT}" "respawned=yes"
fi

if [[ "${#TEST_CASES[@]}" -gt 0 ]]; then
  echo "[INFO] requested cases: ${TEST_CASES[*]}"
  if [[ "${CASES_RUN}" -eq 0 ]]; then
    echo "[FAIL] unknown test case(s): ${TEST_CASES[*]}"
    exit 1
  fi
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "FAILED: ${FAILURES} checks failed."
  exit 1
fi

echo "PASSED"
exit 0
