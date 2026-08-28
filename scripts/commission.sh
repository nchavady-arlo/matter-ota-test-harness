#!/bin/bash
# Commission OTA requestor instances and wire to provider
# Handles fabric setup, ACL installation, and provider configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
SDK_ROOT="/home/nchavady/workspace/github/connectedhomeip"
BUILD_DIR="${SDK_ROOT}/out/aarch64"
CHIP_TOOL="${BUILD_DIR}/chip-tool"

# Configuration
FABRIC_ID=1
COMMISSIONER_NODE_ID=112233
BASE_DISCRIMINATOR=3840
BASE_PORT=5540
SETUP_PIN=20202020

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  commission <instance-id>
      Commission a single requestor instance

  commission-multi <count>
      Commission N requestor instances (IDs 1..N)

  wire-provider <instance-id> <provider-node-id> <provider-endpoint>
      Wire a requestor to a provider via AnnounceOTAProvider

  wire-provider-attribute <instance-id> <provider-node-id> <provider-endpoint>
      Wire a requestor to a provider via DefaultOTAProviders attribute

  setup-provider-acl <provider-node-id>
      Install ACLs on provider to allow OTA operations

  trigger-query <instance-id>
      Manually trigger QueryImage on a commissioned requestor

Examples:
  # Commission requestor 1
  $0 commission 1

  # Commission 3 requestors
  $0 commission-multi 3

  # Set up provider ACLs (must run ONCE per provider)
  $0 setup-provider-acl 0x1234

  # Wire requestor 1 to provider 0x1234 endpoint 0
  $0 wire-provider 1 0x1234 0

  # Complete flow:
  $0 commission-multi 3
  $0 setup-provider-acl 0x1234
  $0 wire-provider 1 0x1234 0
  $0 wire-provider 2 0x1234 0
  $0 wire-provider 3 0x1234 0

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

get_node_id() {
    local instance=$1
    # Node IDs: 0x100 + instance (256, 257, 258, ...)
    printf "0x%X" $((0x100 + instance))
}

commission_requestor() {
    local instance=$1
    local discriminator=$(get_discriminator "$instance")
    local port=$(get_port "$instance")
    local node_id=$(get_node_id "$instance")

    echo "=================================================="
    echo "Commissioning Requestor Instance $instance"
    echo "=================================================="
    echo "  Discriminator: $discriminator"
    echo "  Port: $port"
    echo "  Node ID: $node_id"
    echo "  Setup PIN: $SETUP_PIN"
    echo ""

    # Commission via PASE
    echo "Running chip-tool pairing onnetwork..."
    "$CHIP_TOOL" pairing onnetwork "$node_id" "$SETUP_PIN" \
        --paa-trust-store-path "${SDK_ROOT}/credentials/development/paa-root-certs" \
        || {
            echo "ERROR: Commission failed for requestor $instance"
            echo "Check that requestor is running: ./scripts/run-requestor.sh status"
            return 1
        }

    echo ""
    echo "✓ Requestor $instance commissioned successfully"
    echo "  Node ID: $node_id"
    echo ""
}

setup_provider_acl() {
    local provider_node_id=$1

    echo "=================================================="
    echo "Setting up Provider ACLs"
    echo "=================================================="
    echo "Provider Node ID: $provider_node_id"
    echo ""

    echo "Installing ACL entries:"
    echo "  1. Commissioner retains admin access (privilege 5)"
    echo "  2. All nodes get Operate access to OTA Provider cluster (privilege 3)"
    echo ""

    # Write ACL attribute
    # Entry 0: Commissioner admin access
    # Entry 1: All nodes can invoke commands on OTA Provider cluster (0x0029)
    "$CHIP_TOOL" accesscontrol write acl \
        '[
            {
                "fabricIndex": 1,
                "privilege": 5,
                "authMode": 2,
                "subjects": ['"$COMMISSIONER_NODE_ID"'],
                "targets": null
            },
            {
                "fabricIndex": 1,
                "privilege": 3,
                "authMode": 2,
                "subjects": null,
                "targets": [{"cluster": 41, "endpoint": null, "deviceType": null}]
            }
        ]' \
        "$provider_node_id" 0 \
        || {
            echo "ERROR: Failed to set ACLs on provider $provider_node_id"
            echo "Is the provider commissioned and running?"
            return 1
        }

    echo ""
    echo "✓ Provider ACLs configured"
    echo ""
    echo "IMPORTANT: Without this ACL, requestors will get UnsupportedAccess"
    echo "           when trying to invoke QueryImage command"
    echo ""
}

wire_provider_announce() {
    local instance=$1
    local provider_node_id=$2
    local provider_endpoint=$3
    local node_id=$(get_node_id "$instance")

    echo "=================================================="
    echo "Wiring Requestor to Provider (AnnounceOTAProvider)"
    echo "=================================================="
    echo "  Requestor: $node_id (instance $instance)"
    echo "  Provider: $provider_node_id endpoint $provider_endpoint"
    echo ""

    # Send AnnounceOTAProvider command
    # AnnouncementReason: 0 = SimpleAnnouncement
    "$CHIP_TOOL" otasoftwareupdaterequestor announce-otaprovider \
        "$provider_node_id" 0xFFF1 0 "$provider_endpoint" \
        "$node_id" 0 \
        || {
            echo "ERROR: Failed to send AnnounceOTAProvider to requestor $instance"
            return 1
        }

    echo ""
    echo "✓ Provider announced to requestor $instance"
    echo "  Requestor should query the provider after configured delay"
    echo ""
}

wire_provider_attribute() {
    local instance=$1
    local provider_node_id=$2
    local provider_endpoint=$3
    local node_id=$(get_node_id "$instance")

    echo "=================================================="
    echo "Wiring Requestor to Provider (DefaultOTAProviders)"
    echo "=================================================="
    echo "  Requestor: $node_id (instance $instance)"
    echo "  Provider: $provider_node_id endpoint $provider_endpoint"
    echo ""

    # Write DefaultOTAProviders attribute
    "$CHIP_TOOL" otasoftwareupdaterequestor write default-otaproviders \
        '[{"providerNodeID": '"$provider_node_id"', "endpoint": '"$provider_endpoint"', "fabricIndex": 1}]' \
        "$node_id" 0 \
        || {
            echo "ERROR: Failed to write DefaultOTAProviders on requestor $instance"
            return 1
        }

    echo ""
    echo "✓ DefaultOTAProviders attribute set on requestor $instance"
    echo "  Requestor will query this provider on periodic timer"
    echo ""
}

trigger_query() {
    local instance=$1
    local node_id=$(get_node_id "$instance")

    echo "=================================================="
    echo "Triggering Immediate QueryImage"
    echo "=================================================="
    echo "  Requestor: $node_id (instance $instance)"
    echo ""

    # Read current update state
    echo "Current UpdateState:"
    "$CHIP_TOOL" otasoftwareupdaterequestor read update-state "$node_id" 0 || true
    echo ""

    # Note: There's no direct "trigger query" command in the cluster
    # The requestor queries automatically based on:
    #   - AnnounceOTAProvider command (immediate after delay)
    #   - Periodic timer when DefaultOTAProviders is set
    # Or can be triggered by:
    #   - Restarting the requestor app
    #   - Sending another AnnounceOTAProvider command

    echo "To trigger immediate query:"
    echo "  1. Send AnnounceOTAProvider command again, or"
    echo "  2. Restart the requestor app"
    echo ""
}

# Main command dispatch
case "${1:-}" in
    commission)
        [ $# -lt 2 ] && usage
        commission_requestor "$2"
        ;;
    commission-multi)
        [ $# -lt 2 ] && usage
        count=$2
        for i in $(seq 1 "$count"); do
            echo "Commissioning requestor $i..."
            commission_requestor "$i" || true
            echo ""
            sleep 2
        done
        echo "=================================================="
        echo "Commissioning Complete"
        echo "=================================================="
        echo "Commissioned $count requestor instances"
        echo ""
        echo "Next steps:"
        echo "  1. Setup provider ACLs: $0 setup-provider-acl <provider-node-id>"
        echo "  2. Wire requestors: $0 wire-provider <instance> <provider-node-id> 0"
        ;;
    setup-provider-acl)
        [ $# -lt 2 ] && usage
        setup_provider_acl "$2"
        ;;
    wire-provider)
        [ $# -lt 4 ] && usage
        wire_provider_announce "$2" "$3" "$4"
        ;;
    wire-provider-attribute)
        [ $# -lt 4 ] && usage
        wire_provider_attribute "$2" "$3" "$4"
        ;;
    trigger-query)
        [ $# -lt 2 ] && usage
        trigger_query "$2"
        ;;
    *)
        usage
        ;;
esac
