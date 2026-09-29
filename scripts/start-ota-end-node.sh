#!/bin/bash
# Test YOUR OTA Provider
# Workflow: Start simulated requestor → YOUR controller commissions it → Monitor OTA

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"

# Load central configuration (CURRENT_VERSION / OTA_VERSION from build-version.env)
source "$HARNESS_ROOT/setup.sh"

usage() {
    cat <<EOF
Usage: $0 <command> [instance-id] [--skip-exec]

Commands:
  start <instance>     Start simulated requestor in pairing mode
  resume <instance>    Resume a stopped requestor (keeps commissioned fabric)
  monitor <instance>   Monitor OTA progress (tail logs)
  status               Show all requestor instances
  clean <instance>     Clean up requestor instance

Options (start/resume):
  --skip-exec          Don't apply (exec) the downloaded image; just send
                       NotifyUpdateApplied and keep running the old version.
                       Use this if YOUR provider serves a dummy/non-runnable payload.

Default behavior:
  The requestor runs the version built by build-setup.sh (currently v$CURRENT_VERSION).
  After download it applies the image: the process re-execs into the downloaded
  binary (v$OTA_VERSION when served images/test-normal.ota), keeping its fabric,
  and the monitor reports the new software version.

Workflow:
  1. Start requestor in pairing mode:
       $0 start 1

  2. Commission from YOUR controller:
       - Discriminator: 3841 (for instance 1)
       - Setup PIN: 20202021
       - Your controller should discover and commission the device

  3. Trigger OTA from YOUR controller:
       - Configure DefaultOTAProviders, OR
       - Send AnnounceOTAProvider command
       - Requestor will query YOUR provider

  4. Monitor progress:
       $0 monitor 1

Resume Workflow (after crash/reboot):
  If the requestor process died but was previously commissioned:
       $0 resume 1

  This will:
    - Restart the requestor process
    - Preserve commissioned fabric credentials (KVS)
    - Reconnect to your controller's fabric
    - Monitor OTA progress automatically

Instance Details:
  Instance 1: Discriminator 3841, Port 5541
  Instance 2: Discriminator 3842, Port 5542
  Instance 3: Discriminator 3843, Port 5543
  (Each instance increments by 1)

Examples:
  # Start requestor 1, let YOUR controller commission it
  $0 start 1

  # Resume requestor 1 after it crashed (keeps commissioned state)
  $0 resume 1

  # In another terminal, monitor OTA progress
  $0 monitor 1

  # Clean up when done
  $0 clean 1

EOF
    exit 1
}

get_discriminator() {
    local instance=$1
    echo $((3840 + instance))
}

get_port() {
    local instance=$1
    echo $((5540 + instance))
}

get_node_id() {
    local instance=$1
    printf "0x%X" $((0x100 + instance))
}

# Tail the requestor log, filtered to OTA events. Announces the running software
# version whenever the (re-exec'd) requestor confirms its image.
follow_ota_log() {
    local log_file=$1
    local extra_pattern=${2:-}
    local pattern="QueryImage|BDX|Download|Apply|Update|software version|ota.update|Starting event loop|ERROR|WARN"
    [ -n "$extra_pattern" ] && pattern="${extra_pattern}|${pattern}"

    # The SDK only logs the software version on a confirm *failure*. So:
    #   "Update available from version X to Y" → remember X/Y
    #   "Starting event loop" after that       → process re-exec'd into the new image
    #   no "Failed to confirm image" within 3s → image confirmed, now running Y
    tail -n 0 -F "$log_file" 2>/dev/null | sed -u 's/\x1b\[[0-9;]*m//g' | \
        awk -v pat="$pattern" '
        function ts(line) {
            if (match(line, /^\[[0-9]+\.[0-9]+\]/)) return substr(line, 2, RLENGTH - 2) + 0
            return 0
        }
        function banner(msg) {
            print ""
            print "=================================================="
            print msg
            print "=================================================="
            print ""
            fflush()
        }
        $0 ~ pat { print; fflush() }
        /Update available from version [0-9]+ to [0-9]+/ {
            match($0, /from version [0-9]+ to [0-9]+/)
            split(substr($0, RSTART, RLENGTH), f, " ")
            from = f[3]; target = f[5]
            banner(">> Update available: v" from " → v" target)
        }
        /Starting event loop/ && target != "" && !restarted {
            restarted = 1; t_restart = ts($0)
            banner(">> Requestor re-exec'"'"'d into downloaded image, confirming v" target "...")
            next
        }
        /Failed to confirm image|Current software version = / && restarted && !done {
            done = 1
            v = "?"
            if (match($0, /Current software version = [0-9]+/)) v = substr($0, RSTART + 27, RLENGTH - 27)
            banner("✗ OTA NOT CONFIRMED — running v" v ", expected v" target)
            next
        }
        restarted && !done && t_restart > 0 && ts($0) > t_restart + 3 {
            done = 1
            banner("✓ OTA APPLIED — software version v" from " → v" target " (now running v" target ")")
        }'
}

print_version_info() {
    local skip_exec=$1
    echo "Software version (running): $CURRENT_VERSION"
    if [ -n "$skip_exec" ]; then
        echo "Apply mode: --skip-exec (image downloaded but NOT executed; version stays $CURRENT_VERSION)"
    else
        echo "Apply mode: apply + re-exec (serve images/test-normal.ota → expect version $OTA_VERSION)"
    fi
}

print_verify_hint() {
    local instance=$1
    echo "Verify from YOUR controller after apply, e.g.:"
    echo "  chip-tool basicinformation read software-version <node-id> 0"
    echo ""
}

wait_for_commissioning() {
    local instance=$1
    local timeout=${2:-600}
    local log_file="${HARNESS_ROOT}/logs/requestor-${instance}.log"
    local pattern="Commissioning completed successfully"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            echo "  ... still waiting for commissioning (${elapsed}s elapsed)"
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

start_requestor() {
    local instance=$1
    local skip_exec=${2:-}
    local discriminator=$(get_discriminator "$instance")
    local port=$(get_port "$instance")

    echo "=================================================="
    echo "Starting Simulated OTA Requestor"
    echo "=================================================="
    echo "Instance: $instance"
    echo "Discriminator: $discriminator"
    echo "Port: $port"
    echo "Setup PIN: 20202021"
    print_version_info "$skip_exec"
    echo ""
    echo "The requestor is now in PAIRING MODE."
    echo ""
    echo "Next steps:"
    echo "  1. Use YOUR controller to commission this device"
    echo "  2. Configure YOUR controller to serve OTA updates"
    echo "  3. Monitor progress: $0 monitor $instance"
    echo ""

    # Clean any previous state to ensure fresh pairing mode
    echo "Cleaning any previous state..."
    "$SCRIPT_DIR/internal/run-requestor.sh" stop "$instance" 2>/dev/null || true
    "$SCRIPT_DIR/internal/run-requestor.sh" clean "$instance"

    # Start requestor with auto-apply. On apply, the Linux requestor execv()s the
    # downloaded image (/tmp/ota.update) with the same args/KVS, so it comes back on
    # the same fabric running the new version. --skip-exec disables that.
    "$SCRIPT_DIR/internal/run-requestor.sh" start "$instance" --auto-apply $skip_exec

    # Wait for log file to contain pairing info
    local log_file="${HARNESS_ROOT}/logs/requestor-${instance}.log"
    sleep 2

    # Extract and display pairing codes (strip ANSI color codes)
    local qr_code=$(grep -oP 'SetupQRCode: \K\[.*?\]' "$log_file" 2>/dev/null | head -1 | sed 's/\x1b\[[0-9;]*m//g')
    local qr_url=$(grep -oP 'https://project-chip.github.io/connectedhomeip/qrcode.html\?data=\S+' "$log_file" 2>/dev/null | head -1 | sed 's/\x1b\[[0-9;]*m//g')
    local manual_code=$(grep -oP 'Manual pairing code: \K\[\d+\]' "$log_file" 2>/dev/null | head -1 | tr -d '[]' | sed 's/\x1b\[[0-9;]*m//g')

    if [ -n "$manual_code" ]; then
        echo "=================================================="
        echo "Pairing Information:"
        echo "=================================================="
        echo "Manual Pairing Code: $manual_code"
        if [ -n "$qr_code" ]; then
            echo "QR Code: $qr_code"
        fi
        if [ -n "$qr_url" ]; then
            echo ""
            echo "View QR Code in browser:"
            echo "$qr_url"
        fi
        echo "=================================================="
        echo ""
    fi

    echo "Waiting for YOUR controller to commission this device..."
    echo "(Ctrl+C to stop waiting; the requestor keeps running)"
    echo ""

    if wait_for_commissioning "$instance" 600; then
        echo "✓ Commissioning completed"
        echo ""
        echo "Device is now on your fabric. Continue the OTA flow from YOUR"
        echo "controller/provider."
        echo ""
        echo "=================================================="
        echo "Monitoring OTA Progress (Ctrl+C to exit)"
        echo "=================================================="
        echo "Watching for:"
        echo "  - QueryImage sent/received"
        echo "  - BDX download progress"
        echo "  - ApplyUpdate"
        echo "  - Re-exec into new image + software version confirmation"
        echo "  - NotifyUpdateApplied"
        echo ""
        print_verify_hint "$instance"

        follow_ota_log "$log_file"
    else
        echo "⚠ Timed out after 600s waiting for commissioning"
        echo "  Requestor is still running — check status/logs and retry commissioning"
        echo ""
        echo "To monitor OTA progress:"
        echo "  $0 monitor $instance"
    fi
}

monitor_requestor() {
    local instance=$1
    local log_file="${HARNESS_ROOT}/logs/requestor-${instance}.log"

    if [ ! -f "$log_file" ]; then
        echo "ERROR: Requestor $instance not running or no log file"
        exit 1
    fi

    echo "=================================================="
    echo "Monitoring OTA Requestor Instance $instance"
    echo "=================================================="
    echo "Log file: $log_file"
    echo ""
    echo "Watching for:"
    echo "  - Commissioning complete"
    echo "  - QueryImage sent/received"
    echo "  - BDX download progress"
    echo "  - ApplyUpdate"
    echo "  - NotifyUpdateApplied"
    echo ""
    echo "Press Ctrl+C to stop monitoring"
    echo ""

    follow_ota_log "$log_file" "Commission"
}

show_status() {
    echo "=================================================="
    echo "OTA Requestor Status"
    echo "=================================================="
    "$SCRIPT_DIR/internal/run-requestor.sh" status
}

resume_requestor() {
    local instance=$1
    local skip_exec=${2:-}
    local kvs_file="${HARNESS_ROOT}/kvs/requestor-${instance}.kvs"
    local log_file="${HARNESS_ROOT}/logs/requestor-${instance}.log"

    echo "=================================================="
    echo "Resuming OTA Requestor Instance $instance"
    echo "=================================================="

    # Check if KVS exists (was previously commissioned)
    if [ ! -f "$kvs_file" ]; then
        echo "ERROR: No commissioned state found for instance $instance"
        echo "       KVS file does not exist: $kvs_file"
        echo ""
        echo "This instance was never commissioned. Use:"
        echo "  $0 start $instance"
        exit 1
    fi

    echo "✓ Found existing KVS file (commissioned state preserved)"
    print_version_info "$skip_exec"
    echo ""

    # Stop if currently running
    "$SCRIPT_DIR/internal/run-requestor.sh" stop "$instance" 2>/dev/null || true

    # Restart with auto-apply (see start_requestor for exec behavior)
    "$SCRIPT_DIR/internal/run-requestor.sh" start "$instance" --auto-apply $skip_exec

    echo ""
    echo "✓ Requestor resumed on existing fabric"
    echo ""
    echo "The device is already commissioned to your controller's fabric."
    echo "Your controller can now:"
    echo "  - Send AnnounceOTAProvider to trigger immediate QueryImage"
    echo "  - Wait for periodic QueryImage (if DefaultOTAProviders set)"
    echo ""
    echo "=================================================="
    echo "Monitoring OTA Progress (Ctrl+C to exit)"
    echo "=================================================="
    echo "Watching for:"
    echo "  - QueryImage sent/received"
    echo "  - BDX download progress"
    echo "  - ApplyUpdate"
    echo "  - Re-exec into new image + software version confirmation"
    echo "  - NotifyUpdateApplied"
    echo ""
    print_verify_hint "$instance"

    follow_ota_log "$log_file"
}

clean_requestor() {
    local instance=$1
    echo "Cleaning requestor instance $instance..."
    "$SCRIPT_DIR/internal/run-requestor.sh" stop "$instance"
    "$SCRIPT_DIR/internal/run-requestor.sh" clean "$instance"
    echo "✓ Cleaned"
}

# Parse trailing options for start/resume
SKIP_EXEC=""
for arg in "${@:3}"; do
    case $arg in
        --skip-exec) SKIP_EXEC="--skip-exec" ;;
        *) echo "Unknown option: $arg"; usage ;;
    esac
done

# Main command dispatch
case "${1:-}" in
    start)
        [ $# -lt 2 ] && usage
        start_requestor "$2" "$SKIP_EXEC"
        ;;
    resume)
        [ $# -lt 2 ] && usage
        resume_requestor "$2" "$SKIP_EXEC"
        ;;
    monitor)
        [ $# -lt 2 ] && usage
        monitor_requestor "$2"
        ;;
    status)
        show_status
        ;;
    clean)
        [ $# -lt 2 ] && usage
        clean_requestor "$2"
        ;;
    *)
        usage
        ;;
esac
