#!/usr/bin/env bash
set -euo pipefail

REPO="Adonis0123/gemini-chrome-autoinstall"
BRANCH="master"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
INSTALL_DIR="$HOME/.gemini-chrome-autoinstall"

echo "Installing gemini-chrome-autoinstall..."
echo ""

# Clean up stale locks from previous installs
rmdir /tmp/gemini-chrome-autoinstall.active.lock 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
curl -fsSL "$RAW_BASE/patch.sh" -o "$INSTALL_DIR/patch.sh"
chmod +x "$INSTALL_DIR/patch.sh"

"$INSTALL_DIR/patch.sh" enable

echo ""
echo "Installation complete!"
echo "The extension will be re-installed automatically after every Chrome update."
echo ""
echo "Useful commands:"
echo "  Check status:  ~/.gemini-chrome-autoinstall/patch.sh status"
echo "  Manual fix:    ~/.gemini-chrome-autoinstall/patch.sh manual"
echo "  Shortcut name: gemini-chrome-fix"
echo "  Uninstall:     ~/.gemini-chrome-autoinstall/patch.sh uninstall"
