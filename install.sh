#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="Adonis0123/gemini-chrome-autoinstall"
BRANCH="master"
RAW_BASE="${GEMINI_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
INSTALL_DIR="${GEMINI_INSTALL_DIR:-$HOME/.gemini-chrome-autoinstall}"
SKIP_ENABLE="${GEMINI_SKIP_ENABLE:-0}"
SKIP_FIRST_PATCH="${GEMINI_SKIP_FIRST_PATCH:-0}"

download_or_copy() {
    local rel_path="$1"
    local out_path="$2"
    local base_local_path=""

    if [ -d "$RAW_BASE" ]; then
        base_local_path="$RAW_BASE/$rel_path"
    elif [[ "$RAW_BASE" == /* || "$RAW_BASE" == ./* || "$RAW_BASE" == ../* ]]; then
        base_local_path="$RAW_BASE/$rel_path"
    fi

    if [ -n "$base_local_path" ] && [ -f "$base_local_path" ]; then
        cp "$base_local_path" "$out_path"
        return 0
    fi

    if curl -fsSL "$RAW_BASE/$rel_path" -o "$out_path"; then
        return 0
    fi

    if [ -f "$SCRIPT_DIR/$rel_path" ]; then
        cp "$SCRIPT_DIR/$rel_path" "$out_path"
        return 0
    fi

    echo "Failed to fetch $rel_path from $RAW_BASE and no local fallback found." >&2
    return 1
}

echo "Installing gemini-chrome-autoinstall..."
echo ""

# Clean up stale locks from previous installs
rmdir /tmp/gemini-chrome-autoinstall.active.lock 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
download_or_copy "patch.sh" "$INSTALL_DIR/patch.sh"
download_or_copy "VERSION" "$INSTALL_DIR/VERSION"
chmod +x "$INSTALL_DIR/patch.sh"
ln -sf patch.sh "$INSTALL_DIR/gemini-chrome-autopatch"

if [ "$SKIP_ENABLE" != "1" ]; then
    "$INSTALL_DIR/patch.sh" enable
fi

first_patch_ok=true
if [ "$SKIP_FIRST_PATCH" != "1" ]; then
    echo ""
    echo "Running first-time patch..."
    echo ""
    "$INSTALL_DIR/patch.sh" manual || true
    last_result_file="$INSTALL_DIR/last-result"
    if [ -f "$last_result_file" ]; then
        result_status=$(grep -m1 '^status=' "$last_result_file" | cut -d= -f2)
        if [ -n "$result_status" ] && [ "$result_status" != "healthy" ]; then
            first_patch_ok=false
        fi
    fi
fi

echo ""
if [ "$first_patch_ok" = true ]; then
    echo "Installation complete!"
    echo "The extension will be re-installed automatically after every Chrome update."
else
    echo "Installation complete, but the initial patch did not succeed."
    echo "Auto-monitoring is enabled and will retry automatically."
    echo "You can also run 'gemini-chrome-fix' manually after closing Chrome."
fi
tool_version="unknown"
if [ -s "$INSTALL_DIR/VERSION" ]; then
    tool_version=$(tr -d '\n' < "$INSTALL_DIR/VERSION")
fi
echo "Tool version: $tool_version"
echo ""
echo "Useful commands:"
echo "  Check status:  $INSTALL_DIR/patch.sh status"
echo "  Manual fix:    $INSTALL_DIR/patch.sh manual"
echo "  Shortcut name: gemini-chrome-fix"
echo "  Uninstall:     $INSTALL_DIR/patch.sh uninstall"
