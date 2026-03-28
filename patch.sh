#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
BOOT_LABEL="com.gemini-chrome-autoinstall.boot"
WATCHER_LABEL="com.gemini-chrome-autoinstall.watcher"
RETRY_LABEL="com.gemini-chrome-autoinstall.retry"
BOOT_PLIST="$BOOT_LABEL.plist"
WATCHER_PLIST="$WATCHER_LABEL.plist"
RETRY_PLIST="$RETRY_LABEL.plist"
INSTALL_DIR="${GEMINI_INSTALL_DIR:-$HOME/.gemini-chrome-autoinstall}"
PENDING_FILE="$INSTALL_DIR/pending"
PATCHED_VERSION_FILE="$INSTALL_DIR/patched-version.txt"
LAST_RESULT_FILE="$INSTALL_DIR/last-result"
ACTIVE_LOCK_DIR="/tmp/gemini-chrome-autoinstall.active.lock"
LOG_FILE="${GEMINI_LOG_FILE:-$HOME/Library/Logs/gemini-chrome-autoinstall.log}"
LOCAL_STATE_FILE="${GEMINI_LOCAL_STATE_PATH:-$HOME/Library/Application Support/Google/Chrome/Local State}"
TOOL_VERSION_FILE="${SCRIPT_DIR}/VERSION"
CORE_INSTALL_CMD="${GEMINI_CORE_INSTALL_CMD:-}"
CORE_INSTALL_URL="https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.sh"
NEEDS_PATCH_REASON=""
NEEDS_PATCH_CHROME_VERSION=""

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

timestamp_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

get_tool_version() {
    if [ -f "$TOOL_VERSION_FILE" ]; then
        tr -d '\n' < "$TOOL_VERSION_FILE"
    else
        echo "unknown"
    fi
}

get_metadata_field() {
    local file_path="$1"
    local key="$2"
    [ -f "$file_path" ] || return 1
    sed -n "s/^${key}=//p" "$file_path" | head -n 1
}

get_last_result_field() {
    local key="$1"
    get_metadata_field "$LAST_RESULT_FILE" "$key" || true
}

write_pending_metadata() {
    local reason="$1"
    local first_seen_at="$2"
    local last_attempt_at="$3"
    local retry_count="$4"
    local detected_version="$5"

    mkdir -p "$(dirname "$PENDING_FILE")"
    cat > "$PENDING_FILE" <<EOF
pending
reason=${reason}
first_seen_at=${first_seen_at}
last_attempt_at=${last_attempt_at}
retry_count=${retry_count}
detected_version=${detected_version}
platform=macos
EOF
}

get_pending_field() {
    local key="$1"
    get_metadata_field "$PENDING_FILE" "$key" || true
}

get_pending_retry_count() {
    local retry_count
    retry_count=$(get_pending_field "retry_count")
    if [[ "$retry_count" =~ ^[0-9]+$ ]]; then
        echo "$retry_count"
    else
        echo "0"
    fi
}

write_last_result() {
    local status="$1"
    local reason="$2"
    local chrome_version="$3"
    local hint="$4"

    mkdir -p "$(dirname "$LAST_RESULT_FILE")"
    cat > "$LAST_RESULT_FILE" <<EOF
status=${status}
reason=${reason}
timestamp=$(timestamp_now)
chrome_version=${chrome_version}
tool_version=$(get_tool_version)
hint=${hint}
EOF
}

is_chrome_running() {
    if [ -n "${GEMINI_CHROME_RUNNING:-}" ]; then
        [ "${GEMINI_CHROME_RUNNING}" = "1" ]
        return $?
    fi

    pgrep -x "Google Chrome" >/dev/null 2>&1
}

get_local_state_version() {
    if [ ! -f "$LOCAL_STATE_FILE" ]; then
        return 1
    fi

    grep -o '"last_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOCAL_STATE_FILE" 2>/dev/null \
        | head -n 1 \
        | sed -E 's/.*"([^"]*)".*/\1/'
}

acquire_active_lock() {
    if mkdir "$ACTIVE_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$ACTIVE_LOCK_DIR/pid"
        return 0
    fi

    # Check if the lock holder is still alive
    local stale=false
    local pid_file="$ACTIVE_LOCK_DIR/pid"
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
            stale=true
        fi
    else
        # Lock dir exists but no pid file — stale from old version
        stale=true
    fi

    if [ "$stale" = true ]; then
        log "Removing stale active lock (previous run did not clean up)."
        release_active_lock
        if mkdir "$ACTIVE_LOCK_DIR" 2>/dev/null; then
            echo $$ > "$ACTIVE_LOCK_DIR/pid"
            return 0
        fi
    fi

    log "Skipped: another run is already in progress."
    return 1
}

release_active_lock() {
    rm -f "$ACTIVE_LOCK_DIR/pid" 2>/dev/null
    rmdir "$ACTIVE_LOCK_DIR" 2>/dev/null || rm -rf "$ACTIVE_LOCK_DIR" 2>/dev/null || true
}

arm_active_lock_cleanup() {
    trap 'release_active_lock' INT TERM EXIT
}

disarm_active_lock_cleanup() {
    trap - INT TERM EXIT
}

run_core_install() {
    log "Chrome is closed. Running Gemini-in-Chrome install script..."
    if [ -n "$CORE_INSTALL_CMD" ]; then
        if sh -c "$CORE_INSTALL_CMD"; then
            log "Install completed successfully."
            return 0
        fi
        log "Install failed with exit code $?."
        return 1
    fi

    if curl -fsSL "$CORE_INSTALL_URL" | bash; then
        log "Install completed successfully."
    else
        log "Install failed with exit code $?."
        return 1
    fi
}

get_chrome_version() {
    if [ -n "${GEMINI_CHROME_VERSION:-}" ]; then
        printf '%s' "$GEMINI_CHROME_VERSION"
        return 0
    fi

    local chrome_ver=""
    chrome_ver=$(/usr/libexec/PlistBuddy -c "Print :KSVersion" \
        "/Applications/Google Chrome.app/Contents/Info.plist" 2>/dev/null || true)
    if [ -n "$chrome_ver" ]; then
        printf '%s' "$chrome_ver"
        return 0
    fi

    chrome_ver=$(get_local_state_version || true)
    if [ -n "$chrome_ver" ]; then
        printf '%s' "$chrome_ver"
    fi
}

get_local_state_health() {
    if [ ! -f "$LOCAL_STATE_FILE" ]; then
        echo "unknown"
        return 0
    fi

    if grep -q '"variations_country"[[:space:]]*:[[:space:]]*"us"' "$LOCAL_STATE_FILE" 2>/dev/null \
      && grep -q '"is_glic_eligible"[[:space:]]*:[[:space:]]*true' "$LOCAL_STATE_FILE" 2>/dev/null; then
        echo "healthy"
        return 0
    fi

    if grep -q '"is_glic_eligible"[[:space:]]*:[[:space:]]*false' "$LOCAL_STATE_FILE" 2>/dev/null \
      || grep -q '"variations_country"[[:space:]]*:[[:space:]]*"cn"' "$LOCAL_STATE_FILE" 2>/dev/null; then
        echo "drifted"
        return 0
    fi

    echo "unknown"
}

get_patched_version() {
    cat "$PATCHED_VERSION_FILE" 2>/dev/null || true
}

save_patched_version() {
    mkdir -p "$(dirname "$PATCHED_VERSION_FILE")"
    printf '%s' "$1" > "$PATCHED_VERSION_FILE"
}

needs_patch() {
    local chrome_ver
    chrome_ver=$(get_chrome_version)
    NEEDS_PATCH_CHROME_VERSION="$chrome_ver"
    if [ -z "$chrome_ver" ]; then
        log "Cannot read Chrome version. Skipping."
        NEEDS_PATCH_REASON="chrome_version_unavailable"
        return 1
    fi
    local patched_ver
    patched_ver=$(get_patched_version)
    if [ "$chrome_ver" = "$patched_ver" ]; then
        log "Already patched for Chrome $chrome_ver. Skipping."
        NEEDS_PATCH_REASON="already_patched"
        return 1
    fi
    NEEDS_PATCH_REASON="needs_patch"
    return 0
}

create_pending() {
    local now
    now=$(timestamp_now)
    local first_seen_at
    first_seen_at=$(get_pending_field "first_seen_at")
    if [ -z "$first_seen_at" ]; then
        first_seen_at="$now"
    fi
    local retry_count
    retry_count=$(( $(get_pending_retry_count) + 1 ))
    local detected_version
    detected_version="${NEEDS_PATCH_CHROME_VERSION:-$(get_chrome_version)}"
    write_pending_metadata "chrome_running" "$first_seen_at" "$now" "$retry_count" "$detected_version"
    log "Chrome is running. Created pending flag for deferred install."
}

remove_pending() {
    rm -f "$PENDING_FILE"
}

cmd_enable() {
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Unload existing agents first (idempotent re-install)
    launchctl unload "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" 2>/dev/null || true

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
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    cat > "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${RETRY_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${SCRIPT_DIR}/patch.sh</string>
		<string>retry</string>
	</array>
	<key>KeepAlive</key>
	<dict>
		<key>PathState</key>
		<dict>
			<key>${PENDING_FILE}</key>
			<true/>
		</dict>
	</dict>
	<key>ThrottleInterval</key>
	<integer>60</integer>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    launchctl load "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$RETRY_PLIST"

    log "Enabled: all LaunchAgents loaded."
    echo "Done. All LaunchAgents are now enabled."
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

    if [ -f "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$RETRY_PLIST"
    fi

    log "Disabled: all LaunchAgents unloaded and removed."
    echo "Done. All LaunchAgents are now disabled."
}

cmd_status() {
    echo "=== Gemini Chrome AutoInstall Status ==="

    local agent_list
    agent_list=$(launchctl list 2>/dev/null || true)

    local boot_loaded=false
    local watcher_loaded=false
    local retry_loaded=false

    if echo "$agent_list" | grep -q "$BOOT_LABEL"; then
        boot_loaded=true
    fi
    if echo "$agent_list" | grep -q "$WATCHER_LABEL"; then
        watcher_loaded=true
    fi
    if echo "$agent_list" | grep -q "$RETRY_LABEL"; then
        retry_loaded=true
    fi

    echo "  Boot agent:    $( $boot_loaded && echo LOADED || echo 'NOT LOADED' )"
    echo "  Watcher agent: $( $watcher_loaded && echo LOADED || echo 'NOT LOADED' )"
    echo "  Retry agent:   $( $retry_loaded && echo LOADED || echo 'NOT LOADED' )"

    local chrome_ver
    chrome_ver=$(get_chrome_version)
    local patched_ver
    patched_ver=$(get_patched_version)
    echo "  Chrome ver:    ${chrome_ver:-unknown}"
    echo "  Patched ver:   ${patched_ver:-never}"
    echo "  Tool version:  $(get_tool_version)"

    if [ -f "$PENDING_FILE" ]; then
        echo "  Pending:       YES (waiting for Chrome to close)"
    else
        echo "  Pending:       no"
    fi

    if [ -d "$ACTIVE_LOCK_DIR" ]; then
        echo "  Running:       YES (patch in progress)"
    else
        echo "  Running:       no"
    fi

    local last_status
    last_status=$(get_last_result_field "status")
    if [ -n "$last_status" ]; then
        echo "  Last result:   ${last_status}"
    fi

    return 0
}

cmd_uninstall() {
    cmd_disable
    rm -rf "$ACTIVE_LOCK_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Uninstalled: all files removed."
    echo "Done. gemini-chrome-autoinstall has been completely removed."
}

cmd_run() {
    log "Run triggered."

    if ! needs_patch; then
        local local_state_health
        local_state_health=$(get_local_state_health)
        write_last_result "$local_state_health" "$NEEDS_PATCH_REASON" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "no patch needed"
        return 0
    fi

    if ! acquire_active_lock; then
        write_last_result "unknown" "active_lock_busy" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "another run in progress"
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if is_chrome_running; then
        create_pending
        write_last_result "pending" "chrome_running" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "close Chrome and wait for retry"
    else
        if run_core_install; then
            save_patched_version "$(get_chrome_version)"
            remove_pending
            write_last_result "healthy" "patched" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "patched successfully"
        else
            status=1
            write_last_result "unknown" "core_install_failed" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "check core installer output"
        fi
    fi

    disarm_active_lock_cleanup
    release_active_lock
    return $status
}

cmd_retry() {
    if [ ! -f "$PENDING_FILE" ]; then
        return 0
    fi

    log "Retry: pending install found."

    if ! needs_patch; then
        log "Retry: no longer needs patching. Clearing pending."
        remove_pending
        write_last_result "healthy" "already_patched" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "pending cleared"
        return 0
    fi

    if is_chrome_running; then
        local now
        now=$(timestamp_now)
        local first_seen_at
        first_seen_at=$(get_pending_field "first_seen_at")
        if [ -z "$first_seen_at" ]; then
            first_seen_at="$now"
        fi
        local retry_count
        retry_count=$(( $(get_pending_retry_count) + 1 ))
        write_pending_metadata "chrome_running" "$first_seen_at" "$now" "$retry_count" "${NEEDS_PATCH_CHROME_VERSION:-$(get_chrome_version)}"
        log "Retry: Chrome still running. Will retry later."
        write_last_result "pending" "chrome_running" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "retry scheduled"
        return 0
    fi

    if ! acquire_active_lock; then
        write_last_result "unknown" "active_lock_busy" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "another run in progress"
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if run_core_install; then
        save_patched_version "$(get_chrome_version)"
        remove_pending
        log "Retry: install completed successfully."
        write_last_result "healthy" "patched" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "patched successfully"
    else
        status=1
        write_last_result "unknown" "core_install_failed" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "check core installer output"
    fi

    disarm_active_lock_cleanup
    release_active_lock
    return $status
}

cmd_manual() {
    log "Manual install triggered."

    if is_chrome_running; then
        printf "Chrome is running. Close it to continue? (Y/N): "
        read -r response < /dev/tty
        if [ "$response" = "Y" ] || [ "$response" = "y" ]; then
            log "Closing Chrome (user confirmed)..."
            killall "Google Chrome" 2>/dev/null
            local waited=0
            while pgrep -x "Google Chrome" >/dev/null 2>&1; do
                if [ "$waited" -ge 30 ]; then
                    echo "Chrome did not exit in time. Please close it manually and retry."
                    return 1
                fi
                sleep 2
                waited=$(( waited + 2 ))
            done
        else
            echo "Cancelled."
            return 0
        fi
    fi

    if ! acquire_active_lock; then
        write_last_result "unknown" "active_lock_busy" "$(get_chrome_version)" "another run in progress"
        return 0
    fi
    arm_active_lock_cleanup

    local status=0
    if run_core_install; then
        save_patched_version "$(get_chrome_version)"
        remove_pending
        write_last_result "healthy" "manual_patched" "$(get_chrome_version)" "patched successfully"
    else
        status=1
        write_last_result "unknown" "manual_install_failed" "$(get_chrome_version)" "check core installer output"
    fi

    disarm_active_lock_cleanup
    release_active_lock

    if [ "$status" -eq 0 ]; then
        log "Reopening Chrome..."
        open -a "Google Chrome"
    fi

    return $status
}

# Main
case "${1:-help}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    retry)     cmd_retry ;;
    manual)    cmd_manual ;;
    *)
        echo "Usage: $0 {enable|disable|uninstall|status|run|retry|manual}"
        echo ""
        echo "Commands:"
        echo "  enable      Install and load LaunchAgents"
        echo "  disable     Unload and remove LaunchAgents"
        echo "  uninstall   Disable and remove all installed files"
        echo "  status      Show current status"
        echo "  run         Execute the patch (creates pending if Chrome is running)"
        echo "  retry       Retry pending install (called by KeepAlive agent)"
        echo "  manual      Re-install immediately after you close Chrome"
        exit 1
        ;;
esac
