#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
BOOT_LABEL="com.gemini-chrome-autoinstall.boot"
WATCHER_LABEL="com.gemini-chrome-autoinstall.watcher"
BOOT_PLIST="$BOOT_LABEL.plist"
WATCHER_PLIST="$WATCHER_LABEL.plist"
LOCK_FILE="/tmp/gemini-chrome-autoinstall.lock"
LOG_FILE="$HOME/Library/Logs/gemini-chrome-autoinstall.log"
LOCK_TIMEOUT=300  # 5 minutes
WAIT_INTERVAL=5   # seconds
MAX_WAIT=600      # 10 minutes

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cmd_enable() {
    mkdir -p "$LAUNCH_AGENTS_DIR"

    cat > "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${BOOT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    cat > "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${WATCHER_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>run</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>/Applications/Google Chrome.app/Contents/Info.plist</string>
	</array>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    launchctl load "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"

    log "Enabled: both LaunchAgents loaded."
    echo "Done. Both LaunchAgents are now enabled."
}

cmd_disable() {
    if [ -f "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"
    fi

    log "Disabled: both LaunchAgents unloaded and removed."
    echo "Done. Both LaunchAgents are now disabled."
}

cmd_status() {
    echo "=== Gemini Chrome AutoInstall Status ==="

    local boot_loaded=false
    local watcher_loaded=false

    if launchctl list 2>/dev/null | grep -q "$BOOT_LABEL"; then
        boot_loaded=true
    fi
    if launchctl list 2>/dev/null | grep -q "$WATCHER_LABEL"; then
        watcher_loaded=true
    fi

    if $boot_loaded; then
        echo "  Boot agent:    LOADED"
    else
        echo "  Boot agent:    NOT LOADED"
    fi

    if $watcher_loaded; then
        echo "  Watcher agent: LOADED"
    else
        echo "  Watcher agent: NOT LOADED"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" ]; then
        echo "  Boot plist:    INSTALLED"
    else
        echo "  Boot plist:    NOT INSTALLED"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" ]; then
        echo "  Watcher plist: INSTALLED"
    else
        echo "  Watcher plist: NOT INSTALLED"
    fi

    if [ -f "$LOCK_FILE" ]; then
        local lock_time
        lock_time=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local age=$(( now - lock_time ))
        echo "  Last run:      ${age}s ago"
    else
        echo "  Last run:      never"
    fi
}

cmd_uninstall() {
    cmd_disable
    rm -f "$LOCK_FILE"
    rm -rf "$HOME/.gemini-chrome-autoinstall"
    log "Uninstalled: all files removed."
    echo "Done. gemini-chrome-autoinstall has been completely removed."
}

cmd_run() {
    log "Run triggered."

    # Dedup: skip if lock file exists and is less than 5 minutes old
    if [ -f "$LOCK_FILE" ]; then
        local lock_time
        lock_time=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local age=$(( now - lock_time ))
        if [ "$age" -lt "$LOCK_TIMEOUT" ]; then
            log "Skipped: last run was ${age}s ago (< ${LOCK_TIMEOUT}s)."
            return 0
        fi
    fi

    # Wait for Chrome to close
    local waited=0
    while pgrep -x "Google Chrome" >/dev/null 2>&1; do
        if [ "$waited" -ge "$MAX_WAIT" ]; then
            log "Timeout: Chrome still running after ${MAX_WAIT}s. Aborting."
            return 1
        fi
        log "Chrome is running. Waiting... (${waited}s / ${MAX_WAIT}s)"
        sleep "$WAIT_INTERVAL"
        waited=$(( waited + WAIT_INTERVAL ))
    done

    # Create lock file
    touch "$LOCK_FILE"

    # Execute the install script
    log "Chrome is closed. Running Gemini-in-Chrome install script..."
    if curl -fsSL https://raw.githubusercontent.com/nicepkg/Gemini-in-Chrome/main/install.sh | bash; then
        log "Install completed successfully."
    else
        log "Install failed with exit code $?."
        return 1
    fi
}

# Main
case "${1:-help}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    *)
        echo "Usage: $0 {enable|disable|uninstall|status|run}"
        echo ""
        echo "Commands:"
        echo "  enable      Install and load LaunchAgents"
        echo "  disable     Unload and remove LaunchAgents"
        echo "  uninstall   Disable and remove all installed files"
        echo "  status      Show current status"
        echo "  run         Execute the patch (waits for Chrome to close)"
        exit 1
        ;;
esac
