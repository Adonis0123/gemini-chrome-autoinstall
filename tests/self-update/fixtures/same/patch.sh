#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
BOOT_LABEL="com.gemini-chrome-autoinstall.boot"
WATCHER_LABEL="com.gemini-chrome-autoinstall.watcher"
RETRY_LABEL="com.gemini-chrome-autoinstall.retry"
FALLBACK_LABEL="com.gemini-chrome-autoinstall.fallback"
BOOT_PLIST="$BOOT_LABEL.plist"
WATCHER_PLIST="$WATCHER_LABEL.plist"
RETRY_PLIST="$RETRY_LABEL.plist"
FALLBACK_PLIST="$FALLBACK_LABEL.plist"
INSTALL_DIR="${GEMINI_INSTALL_DIR:-$SCRIPT_DIR}"
PENDING_FILE="$INSTALL_DIR/pending"
PATCHED_VERSION_FILE="$INSTALL_DIR/patched-version.txt"
LAST_RESULT_FILE="$INSTALL_DIR/last-result"
ACTIVE_LOCK_DIR="/tmp/gemini-chrome-autoinstall.active.lock"
LOG_FILE="${GEMINI_LOG_FILE:-$HOME/Library/Logs/gemini-chrome-autoinstall.log}"
LOCAL_STATE_FILE="${GEMINI_LOCAL_STATE_PATH:-$HOME/Library/Application Support/Google/Chrome/Local State}"
TOOL_VERSION_FILE="${SCRIPT_DIR}/VERSION"
CORE_INSTALL_CMD="${GEMINI_CORE_INSTALL_CMD:-}"
CORE_INSTALL_URL="https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.sh"
PROCESS_NAME="gemini-chrome-autopatch"
LAUNCH_EXECUTABLE="${SCRIPT_DIR}/${PROCESS_NAME}"
NEEDS_PATCH_CHROME_VERSION=""
REPO="Adonis0123/gemini-chrome-autoinstall"
BRANCH="master"
RAW_BASE="${GEMINI_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"

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
    local patch_reason="$2"
    local first_seen_at="$3"
    local last_attempt_at="$4"
    local retry_count="$5"
    local detected_version="$6"

    mkdir -p "$(dirname "$PENDING_FILE")"
    cat > "$PENDING_FILE" <<EOF
pending
reason=${reason}
patch_reason=${patch_reason}
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

get_pending_patch_reason() {
    local patch_reason
    patch_reason=$(get_pending_field "patch_reason")
    if [ -n "$patch_reason" ]; then
        echo "$patch_reason"
        return 0
    fi

    local pending_reason
    pending_reason=$(get_pending_field "reason")
    echo "${pending_reason:-unknown}"
}

calculate_pending_age() {
    if [ ! -f "$PENDING_FILE" ]; then
        echo "n/a"
        return 0
    fi

    local first_seen_at
    first_seen_at=$(get_pending_field "first_seen_at")
    if [ -z "$first_seen_at" ]; then
        echo "unknown"
        return 0
    fi

    local first_seen_epoch
    first_seen_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen_at" "+%s" 2>/dev/null || true)
    if [ -z "$first_seen_epoch" ]; then
        echo "unknown"
        return 0
    fi

    local now_epoch
    now_epoch=$(date -u "+%s")
    if [ "$now_epoch" -lt "$first_seen_epoch" ]; then
        echo "0s"
        return 0
    fi

    echo "$((now_epoch - first_seen_epoch))s"
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

get_chrome_version_or_unknown() {
    local chrome_ver
    chrome_ver=$(get_chrome_version)
    if [ -z "$chrome_ver" ]; then
        chrome_ver="unknown"
    fi
    printf '%s' "$chrome_ver"
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
        if [ ! -f "$CORE_INSTALL_CMD" ]; then
            log "Install failed: GEMINI_CORE_INSTALL_CMD target '$CORE_INSTALL_CMD' does not exist."
            return 1
        fi

        if [ ! -x "$CORE_INSTALL_CMD" ]; then
            log "Install failed: GEMINI_CORE_INSTALL_CMD target '$CORE_INSTALL_CMD' is not executable."
            return 1
        fi

        "$CORE_INSTALL_CMD"
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            log "Install completed successfully."
            return 0
        fi
        log "Install failed with exit code $rc."
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

detect_patch_state() {
    if [ ! -f "$LOCAL_STATE_FILE" ]; then
        echo "unknown|local_state_missing"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "unknown|python3_not_found"
        return 0
    fi

    if ! plutil -lint "$LOCAL_STATE_FILE" >/dev/null 2>&1; then
        if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], "r", encoding="utf-8"))' "$LOCAL_STATE_FILE" >/dev/null 2>&1; then
            echo "unknown|invalid_json"
            return 0
        fi
    fi

    local parsed_fields
    parsed_fields=$(python3 - "$LOCAL_STATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

variations_country = data.get("variations_country") or ""
permanent_values = data.get("variations_permanent_consistency_country") or []
permanent_country = permanent_values[-1] if isinstance(permanent_values, list) and permanent_values else ""

has_true = False
has_false = False
info_cache = ((data.get("profile") or {}).get("info_cache") or {})
if isinstance(info_cache, dict):
    for profile_value in info_cache.values():
        if isinstance(profile_value, dict) and "is_glic_eligible" in profile_value:
            if profile_value["is_glic_eligible"] is True:
                has_true = True
            elif profile_value["is_glic_eligible"] is False:
                has_false = True

print(variations_country)
print(permanent_country)
print("1" if has_true else "0")
print("1" if has_false else "0")
PY
)

    local variations_country
    variations_country=$(printf '%s\n' "$parsed_fields" | sed -n '1p')

    local permanent_country
    permanent_country=$(printf '%s\n' "$parsed_fields" | sed -n '2p')

    local has_glic_true
    has_glic_true=$(printf '%s\n' "$parsed_fields" | sed -n '3p')

    local has_glic_false
    has_glic_false=$(printf '%s\n' "$parsed_fields" | sed -n '4p')

    if [ -z "$variations_country" ] || [ -z "$permanent_country" ] || { [ "$has_glic_true" = "0" ] && [ "$has_glic_false" = "0" ]; }; then
        echo "unknown|missing_required_fields"
    elif [ "$variations_country" != "us" ]; then
        echo "drifted|variations_country=$variations_country"
    elif [ "$permanent_country" != "us" ]; then
        echo "drifted|variations_permanent_consistency_country=$permanent_country"
    elif [ "$has_glic_false" = "1" ]; then
        echo "drifted|glic_not_eligible"
    else
        echo "healthy|ok"
    fi
}

resolve_state_mapping() {
    local detect_state="$1"
    local has_pending="$2"

    local result_status
    case "$detect_state" in
        healthy) result_status="healthy" ;;
        drifted) result_status="drifted" ;;
        *) result_status="detect_error" ;;
    esac

    local current_state
    if [ "$has_pending" = "1" ]; then
        current_state="pending"
    elif [ "$detect_state" = "healthy" ]; then
        current_state="healthy"
    elif [ "$detect_state" = "drifted" ]; then
        current_state="drifted"
    else
        current_state="unknown"
    fi

    echo "${result_status}|${current_state}"
}

get_patched_version() {
    cat "$PATCHED_VERSION_FILE" 2>/dev/null || true
}

save_patched_version() {
    mkdir -p "$(dirname "$PATCHED_VERSION_FILE")"
    printf '%s' "$1" > "$PATCHED_VERSION_FILE"
}

upsert_pending_record() {
    local reason="$1"
    local patch_reason="$2"
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
    if [ -z "$detected_version" ]; then
        detected_version="unknown"
    fi
    write_pending_metadata "$reason" "$patch_reason" "$first_seen_at" "$now" "$retry_count" "$detected_version"
}

should_attempt_retry_now() {
    local retry_count="$1"
    if [ "$retry_count" -lt 10 ]; then
        return 0
    fi
    [ $(( retry_count % 5 )) -eq 0 ]
}

remove_pending() {
    rm -f "$PENDING_FILE"
}

perform_patch_and_verify() {
    local patch_reason="$1"
    local chrome_ver
    chrome_ver=$(get_chrome_version_or_unknown)

    if ! acquire_active_lock; then
        upsert_pending_record "active_lock_busy" "$patch_reason"
        write_last_result "blocked" "active_lock_busy" "$chrome_ver" "another run in progress"
        return 0
    fi
    arm_active_lock_cleanup

    if ! run_core_install; then
        upsert_pending_record "patch_failed" "$patch_reason"
        write_last_result "patch_failed" "$patch_reason" "$chrome_ver" "Run $INSTALL_DIR/patch.sh manual"
        disarm_active_lock_cleanup
        release_active_lock
        return 1
    fi

    local verify_result
    verify_result=$(detect_patch_state)
    local verify_state="${verify_result%%|*}"
    local verify_reason="${verify_result#*|}"

    if [ "$verify_state" != "healthy" ]; then
        upsert_pending_record "verify_failed" "$verify_reason"
        write_last_result "verify_failed" "$verify_reason" "$chrome_ver" "Run $INSTALL_DIR/patch.sh manual"
        disarm_active_lock_cleanup
        release_active_lock
        return 1
    fi

    local installed_chrome_ver
    installed_chrome_ver=$(get_chrome_version_or_unknown)
    if [ "$installed_chrome_ver" != "unknown" ]; then
        save_patched_version "$installed_chrome_ver"
    fi
    remove_pending
    write_last_result "healthy" "$verify_reason" "$installed_chrome_ver" ""

    disarm_active_lock_cleanup
    release_active_lock
    return 0
}

reconcile_patch_state() {
    local trigger="$1"
    local patch_state patch_reason
    IFS='|' read -r patch_state patch_reason <<< "$(detect_patch_state)"

    local chrome_ver
    chrome_ver=$(get_chrome_version_or_unknown)
    NEEDS_PATCH_CHROME_VERSION="$chrome_ver"

    case "$patch_state" in
        healthy)
            if [ "$chrome_ver" != "unknown" ]; then
                save_patched_version "$chrome_ver"
            fi
            remove_pending
            write_last_result "healthy" "$patch_reason" "$chrome_ver" ""
            return 0
            ;;
        unknown)
            if [ "$trigger" = "manual" ]; then
                perform_patch_and_verify "$patch_reason"
                return $?
            fi
            if [ "$trigger" = "retry" ] && [ -f "$PENDING_FILE" ]; then
                local pending_patch_reason
                pending_patch_reason=$(get_pending_patch_reason)
                perform_patch_and_verify "$pending_patch_reason"
                return $?
            fi
            write_last_result "detect_error" "$patch_reason" "$chrome_ver" "Run $INSTALL_DIR/patch.sh manual"
            return 1
            ;;
        drifted)
            if is_chrome_running; then
                upsert_pending_record "blocked" "$patch_reason"
                write_last_result "blocked" "$patch_reason" "$chrome_ver" "Will auto-fix after Chrome closes"
                return 0
            fi
            perform_patch_and_verify "$patch_reason"
            return $?
            ;;
        *)
            write_last_result "detect_error" "unknown_patch_state:$patch_state" "$chrome_ver" "Run $INSTALL_DIR/patch.sh manual"
            return 1
            ;;
    esac
}

cmd_enable() {
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Unload existing agents first (idempotent re-install)
    launchctl unload "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$RETRY_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" 2>/dev/null || true

    cat > "$LAUNCH_AGENTS_DIR/$BOOT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${BOOT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${LAUNCH_EXECUTABLE}</string>
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
		<string>${LAUNCH_EXECUTABLE}</string>
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
		<string>${LAUNCH_EXECUTABLE}</string>
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

    cat > "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${FALLBACK_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${LAUNCH_EXECUTABLE}</string>
		<string>run</string>
	</array>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
EOF

    launchctl load "$LAUNCH_AGENTS_DIR/$BOOT_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$WATCHER_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$RETRY_PLIST"
    launchctl load "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST"

    log "Enabled: boot/watcher/retry/fallback LaunchAgents loaded."
    echo "Done. Boot/Watcher/Retry/Fallback LaunchAgents are now enabled."
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

    if [ -f "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" 2>/dev/null || true
        rm -f "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST"
    fi

    log "Disabled: boot/watcher/retry/fallback LaunchAgents unloaded and removed."
    echo "Done. Boot/Watcher/Retry/Fallback LaunchAgents are now disabled."
}

cmd_status() {
    local chrome_ver
    chrome_ver=$(get_chrome_version_or_unknown)

    local patched_ver
    patched_ver=$(get_patched_version)
    if [ -z "$patched_ver" ]; then
        patched_ver="never"
    fi

    local detect_result
    detect_result=$(detect_patch_state)
    local detect_state="${detect_result%%|*}"

    local has_pending="0"
    if [ -f "$PENDING_FILE" ]; then
        has_pending="1"
    fi

    local chrome_running="0"
    if is_chrome_running; then
        chrome_running="1"
    fi

    local state_mapping
    state_mapping=$(resolve_state_mapping "$detect_state" "$has_pending")
    local current_state="${state_mapping#*|}"

    local pending_reason
    pending_reason=$(get_pending_field "reason")
    if [ -z "$pending_reason" ]; then
        pending_reason="none"
    fi

    local pending_patch_reason
    pending_patch_reason=$(get_pending_field "patch_reason")
    if [ -z "$pending_patch_reason" ]; then
        pending_patch_reason="none"
    fi

    local pending_age
    pending_age=$(calculate_pending_age)

    local pending_retry_count
    pending_retry_count=$(get_pending_retry_count)

    local last_attempt
    last_attempt=$(get_pending_field "last_attempt_at")
    if [ -z "$last_attempt" ]; then
        last_attempt=$(get_last_result_field "timestamp")
    fi
    if [ -z "$last_attempt" ]; then
        last_attempt="never"
    fi

    local fallback_agent_state="disabled"
    if [ -f "$LAUNCH_AGENTS_DIR/$FALLBACK_PLIST" ]; then
        fallback_agent_state="enabled"
    fi

    echo "Tool version: $(get_tool_version)"
    echo "Chrome version: ${chrome_ver}"
    echo "Last healthy version: ${patched_ver}"
    echo "Current state: ${current_state}"
    echo "Pending reason: ${pending_reason}"
    echo "Pending patch reason: ${pending_patch_reason}"
    echo "Pending retry count: ${pending_retry_count}"
    echo "Pending age: ${pending_age}"
    echo "Last attempt: ${last_attempt}"
    echo "Chrome running: $( [ "$chrome_running" = "1" ] && echo yes || echo no )"
    echo "Fallback agent: ${fallback_agent_state} (30m interval)"
}

cmd_uninstall() {
    cmd_disable
    rm -rf "$ACTIVE_LOCK_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Uninstalled: all files removed."
    echo "Done. gemini-chrome-autoinstall has been completely removed."
}

check_self_update() {
    local check_file="$INSTALL_DIR/last-update-check"
    local now=$(date +%s)

    # 24h cooldown
    if [ -f "$check_file" ]; then
        local last=$(cat "$check_file")
        if [ $((now - last)) -lt 86400 ]; then
            return 0
        fi
    fi

    # Fetch remote version
    local remote_ver
    remote_ver=$(curl -fsSL --max-time 5 "$RAW_BASE/VERSION" 2>/dev/null) || {
        log "Self-update check failed: network error"
        return 0
    }
    remote_ver=$(echo "$remote_ver" | tr -d '\n')
    local local_ver=$(get_tool_version)

    # Update timestamp before download — intentional: if download fails,
    # we still wait 24h before retrying to avoid hammering the network.
    # Natural retry happens on the next day's trigger cycle.
    echo "$now" > "$check_file"

    [ "$remote_ver" = "$local_ver" ] && return 0

    # Download to temp, then move
    local tmp=$(mktemp -d)
    curl -fsSL --max-time 10 "$RAW_BASE/patch.sh" -o "$tmp/patch.sh" &&
    curl -fsSL --max-time 5  "$RAW_BASE/VERSION" -o "$tmp/VERSION" || {
        log "Self-update download failed"
        rm -rf "$tmp"
        return 0
    }
    chmod +x "$tmp/patch.sh"
    mv "$tmp/patch.sh" "$INSTALL_DIR/patch.sh"
    mv "$tmp/VERSION"  "$INSTALL_DIR/VERSION"
    rm -rf "$tmp"
    log "Self-updated from $local_ver to $remote_ver"
}

cmd_run() {
    check_self_update
    log "Run triggered."
    reconcile_patch_state "run" || true

    return 0
}

cmd_retry() {
    if [ ! -f "$PENDING_FILE" ]; then
        return 0
    fi

    log "Retry: pending install found."
    NEEDS_PATCH_CHROME_VERSION="$(get_chrome_version_or_unknown)"

    local pending_patch_reason
    pending_patch_reason=$(get_pending_patch_reason)

    if is_chrome_running; then
        upsert_pending_record "blocked" "$pending_patch_reason"
        log "Retry: Chrome still running. Will retry later."
        write_last_result "blocked" "$pending_patch_reason" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "Will auto-fix after Chrome closes"
        return 0
    fi

    local retry_count
    retry_count=$(get_pending_retry_count)
    if ! should_attempt_retry_now "$retry_count"; then
        upsert_pending_record "backoff_wait" "$pending_patch_reason"
        write_last_result "blocked" "retry_backoff" "${NEEDS_PATCH_CHROME_VERSION:-unknown}" "Waiting for next automatic retry window"
        log "Retry throttled by internal backoff (retry_count=${retry_count})."
        return 0
    fi

    reconcile_patch_state "retry" || true
    return 0
}

cmd_manual() {
    log "Manual install triggered."
    local reopen_chrome=false

    if is_chrome_running; then
        printf "Chrome is running. Close it to continue? (Y/N): "
        read -r response < /dev/tty
        if [ "$response" = "Y" ] || [ "$response" = "y" ]; then
            log "Closing Chrome (user confirmed)..."
            # Stage 1: graceful AppleScript quit (like Cmd+Q)
            osascript -e 'quit app "Google Chrome"' 2>/dev/null || true
            reopen_chrome=true
            local waited=0
            while is_chrome_running; do
                if [ "$waited" -ge 30 ]; then
                    echo "Chrome did not exit in time. Please close it manually and retry."
                    return 1
                fi
                # Stage 2: SIGTERM after 10s
                if [ "$waited" -eq 10 ]; then
                    log "Chrome still running after graceful quit, sending SIGTERM..."
                    killall "Google Chrome" 2>/dev/null || true
                fi
                # Stage 3: SIGKILL after 20s
                if [ "$waited" -eq 20 ]; then
                    log "Chrome still running after SIGTERM, sending SIGKILL..."
                    killall -9 "Google Chrome" 2>/dev/null || true
                fi
                sleep 2
                waited=$(( waited + 2 ))
            done
        else
            echo "Cancelled."
            return 0
        fi
    fi

    # Wait for filesystem to flush after Chrome exit
    sleep 2

    reconcile_patch_state "manual"
    local rc=$?

    if [ "$rc" -eq 0 ] && [ "$reopen_chrome" = true ]; then
        sleep 2
        log "Reopening Chrome..."
        open -a "Google Chrome"
    fi

    return $rc
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
        echo "  enable      Install and load boot/watcher/retry/fallback LaunchAgents"
        echo "  disable     Unload and remove all LaunchAgents"
        echo "  uninstall   Disable and remove all installed files"
        echo "  status      Show current status"
        echo "  run         Reconcile local state (creates/updates pending if blocked)"
        echo "  retry       Retry pending reconcile (called by KeepAlive agent)"
        echo "  manual      Re-install immediately after you close Chrome"
        exit 1
        ;;
esac
