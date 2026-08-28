#!/bin/bash
# Test YOUR OTA Provider
# Workflow: Start simulated requestor → YOUR controller commissions it → Monitor OTA

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<EOF
Usage: $0 <command> [instance-id]

Commands:
  start <instance>     Start simulated requestor in pairing mode
  monitor <instance>   Monitor OTA progress (tail logs)
  status               Show all requestor instances
  clean <instance>     Clean up requestor instance

Workflow:
  1. Start requestor in pairing mode:
       $0 start 1

  2. Commission from YOUR controller:
       - Discriminator: 3841 (for instance 1)
       - Setup PIN: 20202020
       - Your controller should discover and commission the device

  3. Trigger OTA from YOUR controller:
       - Configure DefaultOTAProviders, OR
       - Send AnnounceOTAProvider command
       - Requestor will query YOUR provider

  4. Monitor progress:
       $0 monitor 1

Instance Details:
  Instance 1: Discriminator 3841, Port 5541
  Instance 2: Discriminator 3842, Port 5542
  Instance 3: Discriminator 3843, Port 5543
  (Each instance increments by 1)

Examples:
  # Start requestor 1, let YOUR controller commission it
  $0 start 1

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

start_requestor() {
    local instance=$1
    local discriminator=$(get_discriminator "$instance")
    local port=$(get_port "$instance")

    echo "=================================================="
    echo "Starting Simulated OTA Requestor"
    echo "=================================================="
    echo "Instance: $instance"
    echo "Discriminator: $discriminator"
    echo "Port: $port"
    echo "Setup PIN: 20202020"
    echo ""
    echo "The requestor is now in PAIRING MODE."
    echo ""
    echo "Next steps:"
    echo "  1. Use YOUR controller to commission this device"
    echo "  2. Configure YOUR controller to serve OTA updates"
    echo "  3. Monitor progress: $0 monitor $instance"
    echo ""

    # Start requestor with auto-apply
    "$SCRIPT_DIR/run-requestor.sh" start "$instance" --auto-apply

    echo "✓ Requestor started and waiting for commissioning"
    echo ""
    echo "To monitor logs:"
    echo "  tail -f logs/requestor-${instance}.log"
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

    # Tail logs with color highlighting for important events
    tail -f "$log_file" | grep --line-buffered -E "Commission|QueryImage|BDX|Download|Apply|Update|ERROR|WARN" || tail -f "$log_file"
}

show_status() {
    echo "=================================================="
    echo "OTA Requestor Status"
    echo "=================================================="
    "$SCRIPT_DIR/run-requestor.sh" status
}

clean_requestor() {
    local instance=$1
    echo "Cleaning requestor instance $instance..."
    "$SCRIPT_DIR/run-requestor.sh" stop "$instance"
    "$SCRIPT_DIR/run-requestor.sh" clean "$instance"
    echo "✓ Cleaned"
}

# Main command dispatch
case "${1:-}" in
    start)
        [ $# -lt 2 ] && usage
        start_requestor "$2"
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
