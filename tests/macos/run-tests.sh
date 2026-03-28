#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/local-state"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gemini-chrome-autoinstall-tests.XXXXXX")"
export TMPDIR="$TMP_ROOT"

trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_CASE="${1:-}"
FAILURES=0
CASE_OUTPUT=""

run_case() {
  local case_name="$1"
  shift

  if [[ -n "${TEST_CASE}" && "${TEST_CASE}" != "${case_name}" ]]; then
    CASE_EXECUTED=0
    return 2
  fi

  CASE_EXECUTED=1
  echo "==> ${case_name}"

  set +e
  CASE_OUTPUT="$(cd "$REPO_ROOT" && "$@" 2>&1)"
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

if run_case "tri-state-healthy" env \
  GEMINI_INSTALL_DIR="$TMPDIR/runtime" \
  GEMINI_LOCAL_STATE_PATH="$FIXTURE_DIR/healthy.json" \
  GEMINI_CHROME_VERSION="136.0.7103.49" \
  GEMINI_CHROME_RUNNING="0" \
  bash patch.sh run; then
  assert_file_contains "$TMPDIR/runtime/last-result" "status=healthy"
fi

if [[ "${TEST_CASE}" != "" ]]; then
  echo "[INFO] requested case: ${TEST_CASE}"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "FAILED: ${FAILURES} checks failed."
  exit 1
fi

echo "PASSED"
exit 0
