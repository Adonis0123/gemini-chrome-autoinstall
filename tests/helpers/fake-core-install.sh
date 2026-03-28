#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_MODE="${GEMINI_FAKE_INSTALL_MODE:-success}"

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
