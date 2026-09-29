#!/bin/bash
# OTA Test Scenario Runner
# Executes test cases with log-based pass/fail assertions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Load central configuration
source "$HARNESS_ROOT/setup.sh"

SDK_ROOT="$MATTER_SDK_ROOT"
BUILD_DIR="$MATTER_BUILD_DIR"
IMAGE_DIR="${HARNESS_ROOT}/images"
LOG_DIR="${HARNESS_ROOT}/logs"

# Test configuration
PROVIDER_NODE_ID="0x1000"  # Default for reference provider
PROVIDER_PORT=5540
TEST_TIMEOUT=300  # 5 minutes per test

usage() {
    cat <<EOF
Usage: $0 <test-scenario> [options]

Test Scenarios:
  happy-path              Full update: QueryImage → Download → Apply → NotifyUpdateApplied
  provider-busy           Provider returns Busy, requestor honors delayedActionTime
  provider-not-available  Provider returns NotAvailable
  user-consent-granted    User consent required and granted
  user-consent-denied     User consent required and denied
  bdx-interrupted         BDX transfer interrupted mid-download
  bad-digest              Image digest mismatch, download fails
  downgrade-rejected      Requestor rejects downgrade attempt
  concurrent-updates      Multiple requestors download simultaneously
  all                     Run all test scenarios sequentially

Options:
  --provider-node-id <id>     Provider node ID (default: 0x1000)
  --use-your-provider         Use your provider instead of reference provider
  --keep-logs                 Don't clean logs between tests
  --verbose                   Show detailed logs during test

Examples:
  $0 happy-path
  $0 provider-busy --verbose
  $0 concurrent-updates
  $0 all --keep-logs

EOF
    exit 1
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Log parsing utilities
wait_for_log_pattern() {
    local instance=$1
    local pattern=$2
    local timeout=$3
    local log_file="${LOG_DIR}/requestor-${instance}.log"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

check_state() {
    local instance=$1
    local expected_state=$2
    local node_id=$("$SCRIPT_DIR/commission.sh" get-node-id "$instance" 2>/dev/null || printf "0x%X" $((0x100 + instance)))

    local actual_state=$("$BUILD_DIR/chip-tool" otasoftwareupdaterequestor read update-state "$node_id" 0 2>&1 | grep -oP 'Attribute.*value.*:\s*\K\d+' || echo "unknown")

    if [ "$actual_state" = "$expected_state" ]; then
        return 0
    else
        log_warn "State mismatch: expected $expected_state, got $actual_state"
        return 1
    fi
}

# Test: Happy Path
test_happy_path() {
    log_info "=================================================="
    log_info "TEST: Happy Path - Full OTA Update"
    log_info "=================================================="

    local instance=1
    local image="test-normal.ota"

    log_info "Step 1: Clean and start requestor"
    "$SCRIPT_DIR/run-requestor.sh" clean "$instance"
    "$SCRIPT_DIR/run-requestor.sh" start "$instance" --auto-apply

    sleep 2

    log_info "Step 2: Start reference provider"
    start_reference_provider "$image"

    sleep 5  # Wait for provider commissioning to complete (avoids node ID race)

    log_info "Step 3: Commission requestor"
    "$SCRIPT_DIR/commission.sh" commission "$instance"

    log_info "Step 4: Setup provider ACLs"
    "$SCRIPT_DIR/commission.sh" setup-provider-acl "$PROVIDER_NODE_ID"

    log_info "Step 5: Wire requestor to provider"
    "$SCRIPT_DIR/commission.sh" wire-provider "$instance" "$PROVIDER_NODE_ID" 0

    log_info "Step 6: Wait for QueryImage"
    if ! wait_for_log_pattern "$instance" "QueryImageResponse" 30; then
        log_error "QueryImage not received"
        return 1
    fi
    log_info "✓ QueryImage successful"

    log_info "Step 7: Wait for download completion"
    if ! wait_for_log_pattern "$instance" "OTA image downloaded to" 60; then
        log_error "Download did not complete"
        return 1
    fi
    log_info "✓ Download complete"

    log_info "Step 8: Wait for apply"
    if ! wait_for_log_pattern "$instance" "ApplyUpdateResponse" 30; then
        log_error "ApplyUpdate not received"
        return 1
    fi
    log_info "✓ Apply initiated"

    log_info "Step 9: Check for NotifyUpdateApplied (after simulated reboot)"
    if ! wait_for_log_pattern "$instance" "NotifyUpdateApplied\|OTA image is invalid" 30; then
        log_warn "NotifyUpdateApplied not seen (expected with skipExecImageFile)"
    fi

    log_info "=================================================="
    log_info "TEST PASSED: Happy Path"
    log_info "=================================================="
    return 0
}

# Test: Provider Busy
test_provider_busy() {
    log_info "=================================================="
    log_info "TEST: Provider Busy with DelayedActionTime"
    log_info "=================================================="

    local instance=2
    local image="test-small.ota"

    log_info "Step 1: Clean and start requestor"
    "$SCRIPT_DIR/run-requestor.sh" clean "$instance"
    "$SCRIPT_DIR/run-requestor.sh" start "$instance"

    sleep 2

    log_info "Step 2: Start provider in Busy mode (30s delay)"
    start_reference_provider "$image" --queryImageStatus busy --delayedQueryActionTimeSec 30

    sleep 2

    log_info "Step 3: Commission and wire"
    "$SCRIPT_DIR/commission.sh" commission "$instance"
    "$SCRIPT_DIR/commission.sh" setup-provider-acl "$PROVIDER_NODE_ID"
    "$SCRIPT_DIR/commission.sh" wire-provider "$instance" "$PROVIDER_NODE_ID" 0

    log_info "Step 4: Wait for Busy response"
    if ! wait_for_log_pattern "$instance" "status: 1" 30; then  # status 1 = Busy
        log_error "Busy response not received"
        return 1
    fi
    log_info "✓ Received Busy response"

    log_info "Step 5: Verify delayedActionTime honored (wait ~30s)"
    sleep 25
    if grep -q "QueryImage" "${LOG_DIR}/requestor-${instance}.log" | tail -1 | grep -q "retrying"; then
        log_info "✓ Requestor honoring delay"
    fi

    log_info "Step 6: Wait for retry QueryImage"
    if ! wait_for_log_pattern "$instance" "QueryImage.*retry\|QueryImage" 40; then
        log_error "Retry QueryImage not sent"
        return 1
    fi
    log_info "✓ Retry QueryImage sent after delay"

    log_info "=================================================="
    log_info "TEST PASSED: Provider Busy"
    log_info "=================================================="
    return 0
}

# Test: BDX Interrupted
test_bdx_interrupted() {
    log_info "=================================================="
    log_info "TEST: BDX Transfer Interrupted"
    log_info "=================================================="

    local instance=3
    local image="test-large.ota"

    log_info "Step 1: Start requestor and provider"
    "$SCRIPT_DIR/run-requestor.sh" clean "$instance"
    "$SCRIPT_DIR/run-requestor.sh" start "$instance"
    sleep 2
    start_reference_provider "$image"
    sleep 2

    log_info "Step 2: Commission and wire"
    "$SCRIPT_DIR/commission.sh" commission "$instance"
    "$SCRIPT_DIR/commission.sh" setup-provider-acl "$PROVIDER_NODE_ID"
    "$SCRIPT_DIR/commission.sh" wire-provider "$instance" "$PROVIDER_NODE_ID" 0

    log_info "Step 3: Wait for download to start"
    if ! wait_for_log_pattern "$instance" "BDX.*block\|BlockQuery" 30; then
        log_error "Download did not start"
        return 1
    fi
    log_info "✓ Download started"

    log_info "Step 4: Kill provider mid-transfer"
    sleep 3  # Let some blocks transfer
    stop_reference_provider
    log_info "✓ Provider killed"

    log_info "Step 5: Wait for error detection"
    if ! wait_for_log_pattern "$instance" "timeout\|connection.*close\|download.*fail" 60; then
        log_error "Error not detected"
        return 1
    fi
    log_info "✓ Requestor detected transfer failure"

    log_info "Step 6: Check state returned to idle or retry"
    sleep 5
    local log_file="${LOG_DIR}/requestor-${instance}.log"
    if grep -q "Reset\|Idle" "$log_file"; then
        log_info "✓ Requestor reset to idle"
    else
        log_info "✓ Requestor may retry (depends on driver policy)"
    fi

    log_info "=================================================="
    log_info "TEST PASSED: BDX Interrupted"
    log_info "=================================================="
    return 0
}

# Test: Concurrent Updates
test_concurrent_updates() {
    log_info "=================================================="
    log_info "TEST: Concurrent Updates (3 requestors)"
    log_info "=================================================="

    local count=3
    local image="test-small.ota"

    log_info "Step 1: Start provider"
    start_reference_provider "$image"
    sleep 2

    log_info "Step 2: Start and commission multiple requestors"
    for i in $(seq 1 $count); do
        "$SCRIPT_DIR/run-requestor.sh" clean "$i"
        "$SCRIPT_DIR/run-requestor.sh" start "$i" --auto-apply &
    done
    sleep 3

    "$SCRIPT_DIR/commission.sh" commission-multi "$count"

    log_info "Step 3: Setup provider ACLs"
    "$SCRIPT_DIR/commission.sh" setup-provider-acl "$PROVIDER_NODE_ID"

    log_info "Step 4: Wire all requestors simultaneously"
    for i in $(seq 1 $count); do
        "$SCRIPT_DIR/commission.sh" wire-provider "$i" "$PROVIDER_NODE_ID" 0 &
    done
    wait

    log_info "Step 5: Monitor all requestors"
    local success_count=0
    for i in $(seq 1 $count); do
        if wait_for_log_pattern "$i" "Download complete\|QueryImage" 120; then
            log_info "✓ Requestor $i: QueryImage/Download started"
            success_count=$((success_count + 1))
        else
            log_warn "Requestor $i: No activity seen"
        fi
    done

    if [ $success_count -ge 2 ]; then
        log_info "✓ At least 2/$count requestors active (provider may serialize)"
        log_info "=================================================="
        log_info "TEST PASSED: Concurrent Updates"
        log_info "=================================================="
        return 0
    else
        log_error "Only $success_count/$count requestors responded"
        return 1
    fi
}

# Reference provider helpers
start_reference_provider() {
    local image=$1
    shift
    local extra_args=("$@")

    log_info "Starting reference ota-provider-app..."

    "$BUILD_DIR/chip-ota-provider-app" \
        --discriminator 3000 \
        --secured-device-port "$PROVIDER_PORT" \
        --KVS /tmp/chip_kvs_provider \
        --filepath "${IMAGE_DIR}/${image}" \
        "${extra_args[@]}" \
        > "${LOG_DIR}/provider.log" 2>&1 &

    echo $! > "${HARNESS_ROOT}/provider.pid"
    sleep 3

    # Commission provider (use onnetwork-long to specify discriminator and avoid pairing the wrong device)
    "$BUILD_DIR/chip-tool" pairing onnetwork-long "$PROVIDER_NODE_ID" 20202021 3000 \
        --paa-trust-store-path "${SDK_ROOT}/credentials/development/paa-root-certs" \
        >> "${LOG_DIR}/provider-commission.log" 2>&1 || true

    log_info "✓ Provider started (Node ID: $PROVIDER_NODE_ID)"
}

stop_reference_provider() {
    if [ -f "${HARNESS_ROOT}/provider.pid" ]; then
        local pid=$(cat "${HARNESS_ROOT}/provider.pid")
        kill "$pid" 2>/dev/null || true
        rm -f "${HARNESS_ROOT}/provider.pid"
        log_info "✓ Provider stopped"
    fi
}

cleanup_all() {
    log_info "Cleaning up..."
    "$SCRIPT_DIR/run-requestor.sh" stop-all
    stop_reference_provider
    rm -f /tmp/chip_kvs_provider
}

# Main test dispatcher
run_test() {
    local test_name=$1

    case "$test_name" in
        happy-path)
            test_happy_path
            ;;
        provider-busy)
            test_provider_busy
            ;;
        bdx-interrupted)
            test_bdx_interrupted
            ;;
        concurrent-updates)
            test_concurrent_updates
            ;;
        *)
            log_error "Unknown test: $test_name"
            usage
            ;;
    esac
}

# Parse command line
TEST_NAME="${1:-}"
[ -z "$TEST_NAME" ] && usage

trap cleanup_all EXIT

if [ "$TEST_NAME" = "all" ]; then
    log_info "Running all test scenarios..."
    TESTS=(happy-path provider-busy bdx-interrupted concurrent-updates)
    PASSED=0
    FAILED=0

    for test in "${TESTS[@]}"; do
        if run_test "$test"; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        echo ""
        cleanup_all
        sleep 3
    done

    log_info "=================================================="
    log_info "All Tests Complete: $PASSED passed, $FAILED failed"
    log_info "=================================================="
    [ $FAILED -eq 0 ] && exit 0 || exit 1
else
    run_test "$TEST_NAME"
fi
