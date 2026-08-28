#!/bin/bash
# Generate test OTA images for various scenarios
# Uses src/app/ota_image_tool.py from Matter SDK

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
SDK_ROOT="${MATTER_SDK_ROOT:-${HARNESS_ROOT}/connectedhomeip}"
IMAGE_DIR="${HARNESS_ROOT}/images"
OTA_TOOL="${SDK_ROOT}/src/app/ota_image_tool.py"

# Test configuration
VENDOR_ID="0xFFF1"      # Test vendor ID
PRODUCT_ID="0x8000"     # Test product ID
BASE_VERSION=10         # Current version on requestor
TARGET_VERSION=20       # Upgrade target version

echo "=================================================="
echo "Generating OTA Test Images"
echo "=================================================="
echo "Output directory: $IMAGE_DIR"
echo "Vendor ID: $VENDOR_ID"
echo "Product ID: $PRODUCT_ID"
echo ""

# Clean previous images
rm -f "$IMAGE_DIR"/*.ota "$IMAGE_DIR"/*.bin "$IMAGE_DIR"/*.txt

# Generate dummy firmware payloads
generate_payload() {
    local name=$1
    local size=$2
    local output="${IMAGE_DIR}/${name}.bin"

    echo "Generating ${name}.bin (${size} bytes)..."
    dd if=/dev/urandom of="$output" bs=1 count="$size" status=none
    echo "Generated test firmware v${TARGET_VERSION}" > "${IMAGE_DIR}/${name}.txt"
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

echo "=== 1. Small Image (fast iteration) ==="
generate_payload "small" 1024
create_ota_image "small" "test-small.ota" "$TARGET_VERSION" "2.0.0"
echo "✓ test-small.ota (1 KB payload)"
echo ""

echo "=== 2. Large Image (BDX windowing validation) ==="
generate_payload "large" $((5 * 1024 * 1024))  # 5 MB
create_ota_image "large" "test-large.ota" "$TARGET_VERSION" "2.0.0"
echo "✓ test-large.ota (5 MB payload, ~5000 BDX blocks @ 1024 bytes/block)"
echo ""

echo "=== 3. Normal Image (baseline happy path) ==="
generate_payload "normal" $((100 * 1024))  # 100 KB
create_ota_image "normal" "test-normal.ota" "$TARGET_VERSION" "2.0.0"
echo "✓ test-normal.ota (100 KB payload)"
echo ""

echo "=== 4. Corrupted Digest Image ==="
generate_payload "corrupted" 2048
create_ota_image "corrupted" "test-corrupted.ota" "$TARGET_VERSION" "2.0.0"
# Corrupt the payload AFTER OTA header (header is ~200 bytes, corrupt at offset 512)
echo "Corrupting payload at offset 512..."
printf '\xFF\xFF\xFF\xFF' | dd of="${IMAGE_DIR}/test-corrupted.ota" bs=1 seek=512 count=4 conv=notrunc status=none
echo "✓ test-corrupted.ota (digest mismatch will trigger download failure)"
echo ""

echo "=== 5. Wrong VID/PID Image ==="
generate_payload "wrong-vid" 2048
python3 "$OTA_TOOL" create \
    -v 0xFFF2 \
    -p 0x8001 \
    -vn "$TARGET_VERSION" \
    -vs "2.0.0" \
    -da sha256 \
    "${IMAGE_DIR}/wrong-vid.bin" \
    "${IMAGE_DIR}/test-wrong-vid.ota"
echo "✓ test-wrong-vid.ota (VID=0xFFF2, PID=0x8001, should be rejected by provider)"
echo ""

echo "=== 6. Min Applicable Version Rejection ==="
generate_payload "min-version" 2048
create_ota_image "min-version" "test-min-version.ota" "$TARGET_VERSION" "2.0.0" "$((BASE_VERSION + 5))"
echo "✓ test-min-version.ota (minApplicableVersion=$((BASE_VERSION + 5)) > current=$BASE_VERSION)"
echo "  Provider should return NotAvailable if requestor reports version < $((BASE_VERSION + 5))"
echo ""

echo "=== 7. Downgrade Image ==="
generate_payload "downgrade" 2048
create_ota_image "downgrade" "test-downgrade.ota" "$((BASE_VERSION - 1))" "0.9.0"
echo "✓ test-downgrade.ota (version $((BASE_VERSION - 1)) < current $BASE_VERSION)"
echo "  Requestor should reject with UpdateNotFound(UpToDate)"
echo ""

echo "=== 8. Max Applicable Version Test ==="
generate_payload "max-version" 2048
create_ota_image "max-version" "test-max-version.ota" "$TARGET_VERSION" "2.0.0" 0 "$((BASE_VERSION - 1))"
echo "✓ test-max-version.ota (maxApplicableVersion=$((BASE_VERSION - 1)) < current=$BASE_VERSION)"
echo "  Provider should return NotAvailable"
echo ""

# Generate image list JSON for reference provider
cat > "${IMAGE_DIR}/image-list.json" <<EOF
{
  "deviceSoftwareVersionModel": [
    {
      "vendorId": $(printf "%d" "$VENDOR_ID"),
      "productId": $(printf "%d" "$PRODUCT_ID"),
      "softwareVersion": $TARGET_VERSION,
      "softwareVersionString": "2.0.0",
      "cDVersionNumber": 18,
      "softwareVersionValid": true,
      "minApplicableSoftwareVersion": 0,
      "maxApplicableSoftwareVersion": 100,
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
echo "Usage summary:"
echo "  test-small.ota       → Fast iteration (1 KB)"
echo "  test-normal.ota      → Baseline happy path (100 KB)"
echo "  test-large.ota       → BDX stress test (5 MB)"
echo "  test-corrupted.ota   → Digest validation failure"
echo "  test-wrong-vid.ota   → VID/PID mismatch"
echo "  test-min-version.ota → Min version rejection"
echo "  test-downgrade.ota   → Downgrade attempt"
echo "  test-max-version.ota → Max version rejection"
