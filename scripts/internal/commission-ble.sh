#!/bin/bash
# Commission an OTA requestor instance over BLE (PASE via Bluetooth LE)
# instead of the on-network path used by commission.sh.
#
# Requires binaries built with BLE support compiled in:
#   chip_config_network_layer_ble=true
# (see build-setup.sh / README-BLE.md for the rebuild command)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
SDK_ROOT="${MATTER_SDK_ROOT:-${HARNESS_ROOT}/connectedhomeip}"
BUILD_DIR="${SDK_ROOT}/out/linux_x64"
CHIP_TOOL="${BUILD_DIR}/chip-tool"

# Configuration - keep in sync with commission.sh / run-requestor.sh
BASE_DISCRIMINATOR=3840
SETUP_PIN=20202021

# Dummy Wi-Fi credentials used to satisfy the ble-wifi commissioning flow.
# The Linux example apps report success on AddOrUpdateWiFiNetwork/ConnectNetwork
# even without a real Wi-Fi radio (they're already IP-reachable over Ethernet),
# so these values are never actually used to join a network - they just need
# to be present to complete the BLE->NetworkCommissioning handshake.
DUMMY_SSID="TestSSID"
DUMMY_PASSWORD="TestPassword123"

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  commission <instance-id>
      Commission a single requestor instance over BLE (ble-wifi flow)

  commission-thread <instance-id>
      Commission a single requestor instance over BLE (ble-thread flow)

  scan
      List commissionable BLE devices currently advertising

Examples:
  # Commission requestor instance 1 over BLE
  $0 commission 1

  # See what's advertising before you commission
  $0 scan

Notes:
  - The requestor app (run-requestor.sh) must be running and built with
    chip_config_network_layer_ble=true, and BlueZ must see a usable adapter
    (check with: hciconfig, bluetoothctl list).
  - This performs BLE discovery + PASE + NOC provisioning; once complete the
    device operates over the existing IP network like any onnetwork-paired
    node (same as commission.sh's requestors).
  - If ble-wifi fails (e.g. NetworkCommissioning feature not present on this
    build), fall back to: $0 commission-thread <instance>, or to plain
    onnetwork commissioning via commission.sh once BLE PASE is confirmed
    working via 'scan'.
EOF
    exit 1
}

get_discriminator() {
    local instance=$1
    echo $((BASE_DISCRIMINATOR + instance))
}

get_node_id() {
    local instance=$1
    printf "0x%X" $((0x100 + instance))
}

scan_ble() {
    echo "=================================================="
    echo "Scanning for commissionable BLE devices (10s)"
    echo "=================================================="
    if ! command -v bluetoothctl >/dev/null; then
        echo "ERROR: bluetoothctl not found (install bluez)"
        return 1
    fi
    timeout 10 bluetoothctl scan on 2>&1 | grep -i --line-buffered "MATTER\|Discriminator\|NEW\|CHG" || true
    echo ""
    echo "Look for a device advertising the Matter service; the commissioner"
    echo "matches it by discriminator, not by name."
}

commission_requestor_ble() {
    local instance=$1
    local mode=$2  # "wifi" or "thread"
    local discriminator=$(get_discriminator "$instance")
    local node_id=$(get_node_id "$instance")

    echo "=================================================="
    echo "Commissioning Requestor Instance $instance over BLE ($mode)"
    echo "=================================================="
    echo "  Discriminator: $discriminator"
    echo "  Node ID: $node_id"
    echo "  Setup PIN: $SETUP_PIN"
    echo ""

    if [ "$mode" = "thread" ]; then
        echo "Running chip-tool pairing ble-thread..."
        # Empty operational dataset hex string - accepted the same way dummy
        # wifi creds are for ble-wifi (no real Thread radio on this host).
        "$CHIP_TOOL" pairing ble-thread "$node_id" \
            hex:0e080000000000010000000300000c351a00000000000000000000000000 \
            "$SETUP_PIN" "$discriminator" \
            --paa-trust-store-path "${SDK_ROOT}/credentials/development/paa-root-certs" \
            || {
                echo "ERROR: BLE-thread commission failed for requestor $instance"
                return 1
            }
    else
        echo "Running chip-tool pairing ble-wifi..."
        "$CHIP_TOOL" pairing ble-wifi "$node_id" \
            "$DUMMY_SSID" "$DUMMY_PASSWORD" \
            "$SETUP_PIN" "$discriminator" \
            --paa-trust-store-path "${SDK_ROOT}/credentials/development/paa-root-certs" \
            || {
                echo "ERROR: BLE-wifi commission failed for requestor $instance"
                echo "Check that:"
                echo "  1. Requestor $instance is running: ./scripts/run-requestor.sh status"
                echo "  2. Binaries were rebuilt with chip_config_network_layer_ble=true"
                echo "  3. Bluetooth adapter is up: hciconfig"
                return 1
            }
    fi

    echo ""
    echo "✓ Requestor $instance commissioned over BLE"
    echo "  Node ID: $node_id"
    echo ""
}

# Main command dispatch
case "${1:-}" in
    commission)
        [ $# -lt 2 ] && usage
        commission_requestor_ble "$2" "wifi"
        ;;
    commission-thread)
        [ $# -lt 2 ] && usage
        commission_requestor_ble "$2" "thread"
        ;;
    scan)
        scan_ble
        ;;
    *)
        usage
        ;;
esac
