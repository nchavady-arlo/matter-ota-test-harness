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

# Was this instance's requestor started with --skip-exec? Read from the running
# process so `monitor` reports the real apply mode, not its own CLI flags.
requestor_skip_exec() {
    local instance=$1
    local pid_file="${HARNESS_ROOT}/requestor-${instance}.pid"
    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || return 0
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- '--skipExecImageFile'; then
        echo "--skip-exec"
    fi
}

# Tail the requestor log, filtered to OTA events, and announce each OTA stage:
# update offered → download progress → image received → applying → result.
follow_ota_log() {
    local log_file=$1
    local instance=$2
    local skip_exec=$3
    local extra_pattern=${4:-}
    local pid_file="${HARNESS_ROOT}/requestor-${instance}.pid"
    local pattern="QueryImage|ApplyUpdate|NotifyUpdate|software version|ota.update|Starting event loop"
    [ -n "$extra_pattern" ] && pattern="${extra_pattern}|${pattern}"

    # The SDK only logs the software version on a confirm *failure*. So:
    #   "Update available from version X to Y" → remember X/Y
    #   "Starting event loop" after that       → process re-exec'd into the new image
    #   no "Failed to confirm image" within 3s → image confirmed, now running Y
    # The log goes quiet after a successful confirm, so a once-a-second heartbeat
    # ("@@TICK <alive>") is merged into the stream to drive that 3s check and to
    # notice the requestor process exiting.
    {
        tail -n 0 -F "$log_file" 2>/dev/null | sed -u 's/\x1b\[[0-9;]*m//g' &
        while sleep 1; do
            if kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
                echo "@@TICK 1"
            else
                echo "@@TICK 0"
            fi
        done
    } | awk -v pat="$pattern" -v status="$SCRIPT_DIR/internal/ota-status.sh" \
            -v inst="$instance" -v skip="$skip_exec" '
        BEGIN {
            from = "?"; target = "?"; alive = -1
            qstatus[0] = "UpdateAvailable"; qstatus[1] = "Busy"
            qstatus[2] = "NotAvailable"; qstatus[3] = "DownloadProtocolNotSupported"
        }
        function ts(line) {
            if (match(line, /^\[[0-9]+\.[0-9]+\]/)) return substr(line, 2, RLENGTH - 2) + 0
            return 0
        }
        function banner(msg) {
            print ""
            print "=================================================="
            print msg
            print "=================================================="
            fflush()
        }
        function shq(str) {
            gsub(/\047/, "\047\\\047\047", str)
            return "\047" str "\047"
        }
        function run(what, path) {
            system(shq(status) " " what " " shq(inst) " " shq(path) " " skip)
            print ""
            fflush()
        }
        function confirmed() {
            done = 1
            banner("✓ OTA APPLIED — software version v" from " → v" target " (now running v" target ")")
        }
        /^@@TICK / {
            if (restarted && !done && t_wall > 0 && systime() > t_wall + 3) confirmed()
            if ($2 == 0 && alive != 0) {
                if (alive == 1) banner("✗ REQUESTOR PROCESS EXITED — check the log above; resume with: ./scripts/start-ota-end-node.sh resume " inst)
                else { print ">> Requestor " inst " is not running (waiting for it to start)"; fflush() }
            } else if ($2 == 1 && alive == 0) { print ">> Requestor " inst " is running"; fflush() }
            alive = $2
            next
        }
        # Per-message BDX chatter (one SendMessage per block) is summarized as progress
        /BDX::SendMessage/ {
            msgs++
            if (msgs == 1) { print ">> Download started (v" target ")"; fflush() }
            else if (msgs % 500 == 0) { printf "   ... downloading: %d BDX messages\n", msgs; fflush() }
            next
        }
        # Field lines ("  status: 1") that follow a QueryImageResponse:/ApplyUpdateResponse:
        # header. Any other line ends the block.
        fields != "" && !/\]   [A-Za-z]+: / { fields = "" }
        $0 ~ pat { print; fflush() }
        /QueryImageResponse:/ { fields = "query"; next }
        /ApplyUpdateResponse:/ { fields = "apply"; next }
        fields == "query" && /\]   status: [0-9]+/ {
            match($0, /status: [0-9]+/); q = substr($0, RSTART + 8, RLENGTH - 8) + 0
            if (q != 0) banner(">> Provider replied: " (q in qstatus ? qstatus[q] : "status " q))
            next
        }
        fields != "" && /delayedActionTime: [0-9]+ seconds/ {
            match($0, /delayedActionTime: [0-9]+/); d = substr($0, RSTART + 19, RLENGTH - 19) + 0
            if (fields == "query" && q != 0) print "   delayedActionTime: " d " s (requestor retries after this)"
            if (fields == "apply" && a == 1)
                print "   delayedActionTime: " d " s (the SDK waits at least 120 s before re-sending ApplyUpdate)"
            else if (fields == "apply" && d > 0)
                print "   delayedActionTime: " d " s"
            fflush()
            next
        }
        fields == "apply" && /\]   action: [0-9]+/ {
            match($0, /action: [0-9]+/); a = substr($0, RSTART + 8, RLENGTH - 8) + 0
            if (a == 0 && skip != "")
                banner(">> Provider says PROCEED — --skip-exec: not executing image, staying on v" from)
            else if (a == 0)
                banner(">> APPLYING IMAGE: v" from " → v" target " (restarting into new image...)")
            else if (a == 1)
                banner(">> Provider says AWAIT NEXT ACTION — apply delayed")
            else
                banner(">> Provider says DISCONTINUE — update cancelled")
            next
        }
        /Update available from version [0-9]+ to [0-9]+/ {
            match($0, /from version [0-9]+ to [0-9]+/)
            split(substr($0, RSTART, RLENGTH), f, " ")
            from = f[3]; target = f[5]
            # New attempt: forget any previous download/apply/confirm
            msgs = 0; restarted = 0; done = 0; t_restart = 0; t_wall = 0; download = ""
            banner(">> Update available: v" from " → v" target)
        }
        /BDX transfer timeout/ {
            banner("✗ DOWNLOAD TIMED OUT after " msgs " BDX messages — requestor will query again later")
            msgs = 0
        }
        # SDK errors that end an OTA attempt (log severity is only in ANSI color,
        # and most red lines are unrelated noise, so match the messages themselves)
        /Image does not contain a valid header|BDX StatusReport|TransferSession error|Transfer timed out|failed to prepare download|Cannot (set|copy) block data|Failed to start download|Failed to send ApplyUpdate|Failed to send QueryImage|Failed to connect to node|Received QueryImage failure response|QueryImageResponse contains invalid fields|Watchdog timer detects state stuck/ {
            print; fflush()
            m = $0; sub(/^(\[[^]]*\] *)+/, "", m)
            banner("✗ OTA ERROR: " m)
            msgs = 0
        }
        /OTA image downloaded to / {
            print; fflush()
            download = $0; sub(/.*OTA image downloaded to /, "", download)
            banner("✓ IMAGE RECEIVED: v" target " (" msgs " BDX messages)")
            run("received", download)
        }
        /The OTA image is invalid/ {
            banner("✗ APPLY FAILED: could not start v" target " image (execv failed)")
            run("apply-failed", download)
        }
        /Starting event loop/ && target != "?" && !restarted {
            restarted = 1; t_restart = ts($0); t_wall = systime()
            banner(">> Requestor re-exec\047d into downloaded image, confirming v" target "...")
            next
        }
        # Not gated on a seen restart: on resume/monitor the re-exec predates the tail
        /Current software version = [0-9]+, expected software version = [0-9]+/ && !done {
            done = 1
            match($0, /Current software version = [0-9]+/); v = substr($0, RSTART + 27, RLENGTH - 27)
            match($0, /expected software version = [0-9]+/); e = substr($0, RSTART + 28, RLENGTH - 28)
            banner("✗ OTA NOT CONFIRMED — running v" v ", expected v" e)
            next
        }
        /Failed to confirm image/ && !done {
            done = 1
            banner("✗ OTA NOT CONFIRMED — expected v" target)
            next
        }
        # Log timestamps also decide it, for replayed logs where no time passes
        restarted && !done && t_restart > 0 && ts($0) > t_restart + 3 { confirmed() }'
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

        follow_ota_log "$log_file" "$instance" "$skip_exec"
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

    follow_ota_log "$log_file" "$instance" "$(requestor_skip_exec "$instance")" "Commission"
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

    # Resume always launches the v$CURRENT_VERSION build. If the running process
    # already re-exec'd into an applied image, that is a silent downgrade.
    local pid exe
    pid=$(cat "${HARNESS_ROOT}/requestor-${instance}.pid" 2>/dev/null) || true
    exe=$(readlink "/proc/${pid:-0}/exe" 2>/dev/null) || true
    if [[ "$exe" == /tmp/ota.update* ]]; then
        echo "⚠ Requestor $instance is running an applied OTA image ($exe)."
        echo "  Resuming restarts it on the v$CURRENT_VERSION build, so it goes back to the old version"
        echo "  and will ask your provider for the update again."
        echo ""
    fi

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

    follow_ota_log "$log_file" "$instance" "$skip_exec"
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

# Instance ids become ports, discriminators and file names
if [ -n "${2:-}" ] && ! [[ "$2" =~ ^[0-9]+$ ]]; then
    echo "ERROR: instance must be a number (got: $2)"
    usage
fi

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
