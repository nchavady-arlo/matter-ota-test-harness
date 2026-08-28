#!/bin/bash
# Launch OTA requestor instances with unique identities
# Supports clean teardown and state reset

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
SDK_ROOT="/home/nchavady/workspace/github/connectedhomeip"
BUILD_DIR="${SDK_ROOT}/out/aarch64"
REQUESTOR_BIN="${BUILD_DIR}/chip-ota-requestor-app"

KVS_DIR="${HARNESS_ROOT}/kvs"
LOG_DIR="${HARNESS_ROOT}/logs"
IMAGE_DIR="${HARNESS_ROOT}/images"

# Configuration
BASE_DISCRIMINATOR=3840
BASE_PORT=5540
BASE_VERSION=10
VENDOR_ID="0xFFF1"
PRODUCT_ID="0x8000"

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  start <instance-id> [--auto-apply] [--user-consent <state>] [--periodic-query <sec>]
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
  --user-consent <state>   User consent state: granted|denied|deferred
  --periodic-query <sec>   Periodic query timeout in seconds
  --download-path <path>   Custom download path (default: auto-generated)

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
    echo "${IMAGE_DIR}/downloaded-${instance}.bin"
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
    local user_consent=""
    local periodic_query=""
    local custom_download=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto-apply)
                auto_apply="--autoApplyImage"
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
    echo "  Version: $BASE_VERSION"
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
    [ -n "$user_consent" ] && cmd+=($user_consent)
    [ -n "$periodic_query" ] && cmd+=($periodic_query)

    # Launch in background
    "${cmd[@]}" > "$log" 2>&1 &
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
    rm -f "$kvs" "$log" "$download"
    echo "✓ Removed KVS, log, and download files"
}

show_status() {
    echo "Running OTA Requestor Instances:"
    echo ""
    printf "%-8s %-8s %-6s %-14s %-8s\n" "INSTANCE" "PID" "PORT" "DISCRIMINATOR" "STATUS"
    echo "------------------------------------------------------------"

    local any_running=false
    for pid_file in "${HARNESS_ROOT}"/requestor-*.pid; do
        [ -f "$pid_file" ] || continue
        any_running=true

        local instance=$(basename "$pid_file" .pid | sed 's/requestor-//')
        local pid=$(cat "$pid_file")
        local port=$(get_port "$instance")
        local discriminator=$(get_discriminator "$instance")

        if kill -0 "$pid" 2>/dev/null; then
            printf "%-8s %-8s %-6s %-14s %-8s\n" "$instance" "$pid" "$port" "$discriminator" "RUNNING"
        else
            printf "%-8s %-8s %-6s %-14s %-8s\n" "$instance" "$pid" "$port" "$discriminator" "DEAD"
            rm -f "$pid_file"
        fi
    done

    if [ "$any_running" = false ]; then
        echo "No requestor instances running"
    fi
}

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
        rm -rf "$KVS_DIR"/* "$LOG_DIR"/* "${IMAGE_DIR}"/downloaded-*.bin
        echo "✓ Cleaned all KVS files, logs, and downloads"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
