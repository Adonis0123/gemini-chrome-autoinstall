#!/usr/bin/env bash
set -euo pipefail

case "${GEMINI_FAKE_INSTALL_MODE:-success}" in
  success)
    cp "tests/fixtures/local-state/healthy.json" "$GEMINI_LOCAL_STATE_PATH"
    ;;
  verify_fail)
    cp "tests/fixtures/local-state/drifted-glic-false.json" "$GEMINI_LOCAL_STATE_PATH"
    ;;
  patch_fail)
    exit 1
    ;;
esac
