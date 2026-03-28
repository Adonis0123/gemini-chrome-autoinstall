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
