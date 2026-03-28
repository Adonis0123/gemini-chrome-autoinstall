#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_MODE="${GEMINI_FAKE_INSTALL_MODE:-success}"

if [[ -z "${GEMINI_LOCAL_STATE_PATH:-}" ]]; then
  echo "GEMINI_LOCAL_STATE_PATH is required" >&2
  exit 2
fi

mkdir -p "$(dirname "${GEMINI_LOCAL_STATE_PATH}")"

case "${INSTALL_MODE}" in
  success)
    cp "$SCRIPT_DIR/../fixtures/local-state/healthy.json" "$GEMINI_LOCAL_STATE_PATH"
    ;;
  verify_fail)
    cp "$SCRIPT_DIR/../fixtures/local-state/drifted-glic-false.json" "$GEMINI_LOCAL_STATE_PATH"
    ;;
  patch_fail)
    exit 1
    ;;
  *)
    echo "Unknown GEMINI_FAKE_INSTALL_MODE: ${INSTALL_MODE}" >&2
    exit 2
    ;;
esac
