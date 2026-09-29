#!/bin/bash
# Generate test OTA images for various scenarios
# Uses src/app/ota_image_tool.py from Matter SDK
#
# Payload is the real chip-ota-requestor-app built at OTA_VERSION (CURRENT_VERSION+1)
# by build-setup.sh, so an applied image actually exec()s into the new version.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"

# Load central configuration (also loads CURRENT_VERSION / OTA_VERSION)
source "$HARNESS_ROOT/setup.sh"

SDK_ROOT="$MATTER_SDK_ROOT"
IMAGE_DIR="${HARNESS_ROOT}/images"
OTA_TOOL="${SDK_ROOT}/src/app/ota_image_tool.py"
OTA_PAYLOAD_BIN="${MATTER_OTA_BUILD_DIR}/chip-ota-requestor-app"

# Test configuration
VENDOR_ID="0xFFF1"                  # Test vendor ID
PRODUCT_ID="0x8000"                 # Test product ID
BASE_VERSION=$CURRENT_VERSION       # Current version on requestor
TARGET_VERSION=$OTA_VERSION         # Upgrade target version
TARGET_VERSION_STR="${TARGET_VERSION}.0"

if [ ! -f "$OTA_PAYLOAD_BIN" ]; then
    echo "ERROR: OTA payload binary not found: $OTA_PAYLOAD_BIN"
    echo "Run ./build-setup.sh --version <N> first"
    exit 1
fi

echo "=================================================="
echo "Generating OTA Test Images"
echo "=================================================="
echo "Output directory: $IMAGE_DIR"
echo "Vendor ID: $VENDOR_ID"
echo "Product ID: $PRODUCT_ID"
echo "Current version: $BASE_VERSION"
echo "Target version: $TARGET_VERSION ($TARGET_VERSION_STR)"
echo "Payload: $OTA_PAYLOAD_BIN"
echo ""

mkdir -p "$IMAGE_DIR"

# Clean previous images
rm -f "$IMAGE_DIR"/*.ota "$IMAGE_DIR"/*.bin "$IMAGE_DIR"/*.txt

# Stage the v(N+1) requestor binary as the payload
stage_payload() {
    local name=$1
    local output="${IMAGE_DIR}/${name}.bin"

    cp "$OTA_PAYLOAD_BIN" "$output"
    echo "chip-ota-requestor-app v${TARGET_VERSION}" > "${IMAGE_DIR}/${name}.txt"
}

# Create OTA image wrapper
create_ota_image() {
    local payload=$1
    local output=$2
    local version=$3
    local version_str=$4
    local min_version=${5:-""}
    local max_version=${6:-""}

    local args=(
        "$OTA_TOOL" create
        -v "$VENDOR_ID"
        -p "$PRODUCT_ID"
        -vn "$version"
        -vs "$version_str"
        -da sha256
    )

    [ -n "$min_version" ] && args+=(-mi "$min_version")
    [ -n "$max_version" ] && args+=(-ma "$max_version")

    args+=("${IMAGE_DIR}/${payload}.bin" "${IMAGE_DIR}/${output}")

    python3 "${args[@]}"
}

stage_payload "requestor"
PAYLOAD_SIZE=$(du -h "${IMAGE_DIR}/requestor.bin" | cut -f1)

echo "=== 1. Normal Image (baseline happy path) ==="
create_ota_image "requestor" "test-normal.ota" "$TARGET_VERSION" "$TARGET_VERSION_STR"
echo "✓ test-normal.ota (v$TARGET_VERSION requestor, $PAYLOAD_SIZE)"
# Kept for run-test.sh compatibility; same real payload
cp "${IMAGE_DIR}/test-normal.ota" "${IMAGE_DIR}/test-small.ota"
cp "${IMAGE_DIR}/test-normal.ota" "${IMAGE_DIR}/test-large.ota"
echo "✓ test-small.ota / test-large.ota (copies of test-normal.ota)"
echo ""

echo "=== 2. Corrupted Digest Image ==="
create_ota_image "requestor" "test-corrupted.ota" "$TARGET_VERSION" "$TARGET_VERSION_STR"
# Corrupt the payload AFTER OTA header (header is ~200 bytes, corrupt at offset 512)
echo "Corrupting payload at offset 512..."
printf '\xFF\xFF\xFF\xFF' | dd of="${IMAGE_DIR}/test-corrupted.ota" bs=1 seek=512 count=4 conv=notrunc status=none
echo "✓ test-corrupted.ota (digest mismatch will trigger download failure)"
echo ""

echo "=== 3. Wrong VID/PID Image ==="
python3 "$OTA_TOOL" create \
    -v 0xFFF2 \
    -p 0x8001 \
    -vn "$TARGET_VERSION" \
    -vs "$TARGET_VERSION_STR" \
    -da sha256 \
    "${IMAGE_DIR}/requestor.bin" \
    "${IMAGE_DIR}/test-wrong-vid.ota"
echo "✓ test-wrong-vid.ota (VID=0xFFF2, PID=0x8001, should be rejected by provider)"
echo ""

echo "=== 4. Min Applicable Version Rejection ==="
create_ota_image "requestor" "test-min-version.ota" "$TARGET_VERSION" "$TARGET_VERSION_STR" "$((BASE_VERSION + 5))"
echo "✓ test-min-version.ota (minApplicableVersion=$((BASE_VERSION + 5)) > current=$BASE_VERSION)"
echo "  Provider should return NotAvailable if requestor reports version < $((BASE_VERSION + 5))"
echo ""

if [ "$BASE_VERSION" -gt 0 ]; then
    echo "=== 5. Downgrade Image ==="
    create_ota_image "requestor" "test-downgrade.ota" "$((BASE_VERSION - 1))" "$((BASE_VERSION - 1)).0"
    echo "✓ test-downgrade.ota (version $((BASE_VERSION - 1)) < current $BASE_VERSION)"
    echo "  Requestor should reject with UpdateNotFound(UpToDate)"
    echo ""

    echo "=== 6. Max Applicable Version Test ==="
    create_ota_image "requestor" "test-max-version.ota" "$TARGET_VERSION" "$TARGET_VERSION_STR" 0 "$((BASE_VERSION - 1))"
    echo "✓ test-max-version.ota (maxApplicableVersion=$((BASE_VERSION - 1)) < current=$BASE_VERSION)"
    echo "  Provider should return NotAvailable"
    echo ""
else
    echo "=== 5-6. Downgrade / Max Version: skipped (current version is 0) ==="
    echo ""
fi

# Generate image list JSON for reference provider
cat > "${IMAGE_DIR}/image-list.json" <<EOF
{
  "deviceSoftwareVersionModel": [
    {
      "vendorId": $(printf "%d" "$VENDOR_ID"),
      "productId": $(printf "%d" "$PRODUCT_ID"),
      "softwareVersion": $TARGET_VERSION,
      "softwareVersionString": "$TARGET_VERSION_STR",
      "cDVersionNumber": 18,
      "softwareVersionValid": true,
      "minApplicableSoftwareVersion": 0,
      "maxApplicableSoftwareVersion": $BASE_VERSION,
      "otaURL": "${IMAGE_DIR}/test-normal.ota"
    }
  ]
}
EOF

echo ""
echo "=================================================="
echo "Image Generation Complete"
echo "=================================================="
echo ""
echo "Generated images:"
ls -lh "$IMAGE_DIR"/*.ota
echo ""
echo "Image manifest: ${IMAGE_DIR}/image-list.json"
echo ""
echo "Usage summary (all payloads = requestor v$TARGET_VERSION):"
echo "  test-normal.ota      → Happy path: v$BASE_VERSION → v$TARGET_VERSION"
echo "  test-small/large.ota → Same as test-normal.ota (legacy names)"
echo "  test-corrupted.ota   → Digest validation failure"
echo "  test-wrong-vid.ota   → VID/PID mismatch"
echo "  test-min-version.ota → Min version rejection"
[ "$BASE_VERSION" -gt 0 ] && echo "  test-downgrade.ota   → Downgrade attempt"
[ "$BASE_VERSION" -gt 0 ] && echo "  test-max-version.ota → Max version rejection"
exit 0
