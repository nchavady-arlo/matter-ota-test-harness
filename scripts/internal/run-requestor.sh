#!/bin/bash
# Launch OTA requestor instances with unique identities
# Supports clean teardown and state reset

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Load central configuration
source "$HARNESS_ROOT/setup.sh"

SDK_ROOT="$MATTER_SDK_ROOT"
BUILD_DIR="$MATTER_BUILD_DIR"
REQUESTOR_BIN="${BUILD_DIR}/chip-ota-requestor-app"

KVS_DIR="${HARNESS_ROOT}/kvs"
LOG_DIR="${HARNESS_ROOT}/logs"
# Downloads go in /tmp: on apply the SDK rename()s the image to /tmp/ota.update,
# and rename() fails across filesystems.
# The exec path is shared by all instances (only one can apply at a time), and
# /tmp is usually cleared on reboot, so downloads don't survive one.
DOWNLOAD_DIR="/tmp"
EXEC_PATH="/tmp/ota.update"   # kImageExecPath in the SDK; left behind after apply

# Configuration
BASE_DISCRIMINATOR=3840
BASE_PORT=5540
BASE_VERSION="$CURRENT_VERSION"   # Compiled-in version of REQUESTOR_BIN (build-version.env)
VENDOR_ID="0xFFF1"
PRODUCT_ID="0x8000"

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  start <instance-id> [--auto-apply] [--skip-exec] [--user-consent <state>] [--periodic-query <sec>]
      Start a single requestor instance

  start-multi <count>
      Start N requestor instances (IDs 1..N)

  stop <instance-id>
      Stop a specific requestor instance

  stop-all
      Stop all running requestor instances

  clean <instance-id>
      Remove KVS and logs for a specific instance

  clean-all
      Remove all KVS and logs

  status
      Show running requestor instances

Options:
  --auto-apply             Apply image immediately after download
  --skip-exec              Don't exec the downloaded image on apply; stay running and
                           send NotifyUpdateApplied instead
  --user-consent <state>   User consent state: granted|denied|deferred
  --periodic-query <sec>   Periodic query timeout in seconds
  --download-path <path>   Custom download path (default: /tmp/ota-requestor-<instance>.bin)

Examples:
  $0 start 1                                    # Start requestor 1
  $0 start 2 --auto-apply                       # Auto-apply on requestor 2
  $0 start 3 --user-consent denied              # Deny consent on requestor 3
  $0 start-multi 5                              # Start 5 requestors
  $0 stop 1                                     # Stop requestor 1
  $0 stop-all                                   # Stop all requestors
  $0 clean-all && $0 start-multi 3              # Full reset + start 3

EOF
    exit 1
}

get_discriminator() {
    local instance=$1
    echo $((BASE_DISCRIMINATOR + instance))
}

get_port() {
    local instance=$1
    echo $((BASE_PORT + instance))
}

get_pid_file() {
    local instance=$1
    echo "${HARNESS_ROOT}/requestor-${instance}.pid"
}

get_log_file() {
    local instance=$1
    echo "${LOG_DIR}/requestor-${instance}.log"
}

get_kvs_file() {
    local instance=$1
    echo "${KVS_DIR}/requestor-${instance}.kvs"
}

get_download_path() {
    local instance=$1
    echo "${DOWNLOAD_DIR}/ota-requestor-${instance}.bin"
}

start_requestor() {
    local instance=$1
    shift

    local discriminator=$(get_discriminator "$instance")
    local port=$(get_port "$instance")
    local kvs=$(get_kvs_file "$instance")
    local log=$(get_log_file "$instance")
    local pid_file=$(get_pid_file "$instance")
    local download_path=$(get_download_path "$instance")

    # Parse options
    local auto_apply=""
    local skip_exec=""
    local user_consent=""
    local periodic_query=""
    local custom_download=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto-apply)
                auto_apply="--autoApplyImage"
                shift
                ;;
            --skip-exec)
                skip_exec="--skipExecImageFile"
                shift
                ;;
            --user-consent)
                user_consent="--userConsentState $2"
                shift 2
                ;;
            --periodic-query)
                periodic_query="--periodicQueryTimeout $2"
                shift 2
                ;;
            --download-path)
                custom_download="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    [ -n "$custom_download" ] && download_path="$custom_download"

    # Check if already running
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "ERROR: Requestor $instance already running (PID $(cat "$pid_file"))"
        return 1
    fi

    mkdir -p "$KVS_DIR" "$LOG_DIR"

    echo "Starting requestor instance $instance:"
    echo "  Discriminator: $discriminator"
    echo "  Port: $port"
    echo "  Software version: $BASE_VERSION (OTA target: $OTA_VERSION)"
    echo "  KVS: $kvs"
    echo "  Download: $download_path"
    echo "  Log: $log"

    # Build command
    local cmd=(
        "$REQUESTOR_BIN"
        --discriminator "$discriminator"
        --secured-device-port "$port"
        --KVS "$kvs"
        --version "$BASE_VERSION"
        --vendor-id "$VENDOR_ID"
        --product-id "$PRODUCT_ID"
        --otaDownloadPath "$download_path"
    )

    [ -n "$auto_apply" ] && cmd+=($auto_apply)
    [ -n "$skip_exec" ] && cmd+=($skip_exec)
    [ -n "$user_consent" ] && cmd+=($user_consent)
    [ -n "$periodic_query" ] && cmd+=($periodic_query)

    # Launch in background. Append, so a resume keeps the previous run's log
    # (`clean` removes it); the marker separates runs.
    echo "===== run-requestor.sh: starting instance $instance at $(date '+%F %T') =====" >> "$log"
    "${cmd[@]}" >> "$log" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    # Wait briefly and check if still running
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: Requestor $instance failed to start. Check $log"
        rm -f "$pid_file"
        return 1
    fi

    echo "✓ Requestor $instance started (PID $pid)"
    echo "  Monitor: tail -f $log"
}

stop_requestor() {
    local instance=$1
    local pid_file=$(get_pid_file "$instance")

    if [ ! -f "$pid_file" ]; then
        echo "Requestor $instance not running"
        return 0
    fi

    local pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping requestor $instance (PID $pid)..."
        kill "$pid"

        # Wait for graceful shutdown
        local timeout=5
        while kill -0 "$pid" 2>/dev/null && [ $timeout -gt 0 ]; do
            sleep 1
            timeout=$((timeout - 1))
        done

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing requestor $instance..."
            kill -9 "$pid" 2>/dev/null || true
        fi

        echo "✓ Requestor $instance stopped"
    fi

    rm -f "$pid_file"
}

clean_requestor() {
    local instance=$1
    local kvs=$(get_kvs_file "$instance")
    local log=$(get_log_file "$instance")
    local download=$(get_download_path "$instance")

    echo "Cleaning requestor $instance:"
    # A running re-exec'd requestor keeps its inode, so removing EXEC_PATH is safe
    rm -f "$kvs" "$log" "$download" "$EXEC_PATH"
    echo "✓ Removed KVS, log, and download files"
}

show_status() {
    echo "OTA Requestor Instances:"
    echo ""
    printf "%-8s %-8s %-6s %-14s %-12s %-20s\n" "INSTANCE" "PID" "PORT" "DISCRIMINATOR" "STATUS" "FABRIC STATE"
    echo "--------------------------------------------------------------------------------"

    local any_found=false

    # Check for instances with PID files (currently or recently running)
    for pid_file in "${HARNESS_ROOT}"/requestor-*.pid; do
        [ -f "$pid_file" ] || continue
        any_found=true

        local instance=$(basename "$pid_file" .pid | sed 's/requestor-//')
        local pid=$(cat "$pid_file")
        local port=$(get_port "$instance")
        local discriminator=$(get_discriminator "$instance")
        local kvs=$(get_kvs_file "$instance")
        local status=""
        local fabric_state=""

        if kill -0 "$pid" 2>/dev/null; then
            status="RUNNING"
        else
            status="DEAD"
            rm -f "$pid_file"
        fi

        # Check if commissioned (KVS exists)
        if [ -f "$kvs" ]; then
            fabric_state="Commissioned"
        else
            fabric_state="Not commissioned"
        fi

        printf "%-8s %-8s %-6s %-14s %-12s %-20s\n" "$instance" "$pid" "$port" "$discriminator" "$status" "$fabric_state"
    done

    # Check for instances that have KVS but no PID file (stopped but commissioned)
    for kvs_file in "${KVS_DIR}"/requestor-*.kvs; do
        [ -f "$kvs_file" ] || continue

        local instance=$(basename "$kvs_file" .kvs | sed 's/requestor-//')
        local pid_file=$(get_pid_file "$instance")

        # Skip if already shown above
        [ -f "$pid_file" ] && continue

        any_found=true
        local port=$(get_port "$instance")
        local discriminator=$(get_discriminator "$instance")

        printf "%-8s %-8s %-6s %-14s %-12s %-20s\n" "$instance" "-" "$port" "$discriminator" "STOPPED" "Commissioned"
    done

    if [ "$any_found" = false ]; then
        echo "No requestor instances found"
        echo ""
        echo "To start a new instance:"
        echo "  ./scripts/start-ota-end-node.sh start <instance-id>"
    fi
}

# Instance ids become ports, discriminators and file names
case "${1:-}" in
    start|stop|clean|start-multi)
        if [ -n "${2:-}" ] && ! [[ "$2" =~ ^[0-9]+$ ]]; then
            echo "ERROR: instance must be a number (got: $2)"
            exit 1
        fi
        ;;
esac

# Main command dispatch
case "${1:-}" in
    start)
        [ $# -lt 2 ] && usage
        start_requestor "$2" "${@:3}"
        ;;
    start-multi)
        [ $# -lt 2 ] && usage
        count=$2
        for i in $(seq 1 "$count"); do
            start_requestor "$i" || true
            sleep 1
        done
        echo ""
        show_status
        ;;
    stop)
        [ $# -lt 2 ] && usage
        stop_requestor "$2"
        ;;
    stop-all)
        for pid_file in "${HARNESS_ROOT}"/requestor-*.pid; do
            [ -f "$pid_file" ] || continue
            instance=$(basename "$pid_file" .pid | sed 's/requestor-//')
            stop_requestor "$instance"
        done
        ;;
    clean)
        [ $# -lt 2 ] && usage
        clean_requestor "$2"
        ;;
    clean-all)
        # Guard the globs: an empty dir var would expand to /*
        [ -n "$KVS_DIR" ] && [ -n "$LOG_DIR" ] && [ -n "$DOWNLOAD_DIR" ] || { echo "ERROR: empty path config"; exit 1; }
        rm -rf "${KVS_DIR:?}"/* "${LOG_DIR:?}"/* "${DOWNLOAD_DIR:?}"/ota-requestor-*.bin "$EXEC_PATH"
        echo "✓ Cleaned all KVS files, logs, and downloads"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
