#!/bin/bash
# OTA Test Harness Build Setup
# Matter SDK v1.5.1.0 (commit abcc720b48)
# Platform: Linux aarch64, Ubuntu Server 24.04

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${MATTER_SDK_ROOT:-${SCRIPT_DIR}/connectedhomeip}"
BUILD_DIR="${SDK_ROOT}/out/aarch64"
SDK_TAG="v1.5.1.0"
SDK_REPO="https://github.com/project-chip/connectedhomeip.git"

echo "=================================================="
echo "Matter OTA Test Harness - Build Setup"
echo "=================================================="

# Clone SDK if it doesn't exist
if [ ! -d "$SDK_ROOT" ]; then
    echo "Matter SDK not found at: $SDK_ROOT"
    echo "Cloning Matter SDK (this will take a few minutes)..."
    git clone --depth 1 --branch "$SDK_TAG" "$SDK_REPO" "$SDK_ROOT"
    echo "✓ SDK cloned"
fi

# Verify SDK version
cd "$SDK_ROOT"

# Fetch tags if needed
if ! git describe --tags --exact-match 2>/dev/null; then
    git fetch --tags --depth=1 2>/dev/null || true
fi

CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

echo "SDK Location: $SDK_ROOT"
echo "Current commit: $CURRENT_COMMIT"
echo "Current tag: ${CURRENT_TAG:-<not on a tag>}"

# Checkout correct tag if not already on it
if [ "$CURRENT_TAG" != "$SDK_TAG" ]; then
    echo "Checking out $SDK_TAG..."
    git fetch --tags --depth=1 || true
    git checkout "$SDK_TAG" || {
        echo "ERROR: Failed to checkout $SDK_TAG"
        echo "You can manually set MATTER_SDK_ROOT to an existing SDK checkout:"
        echo "  export MATTER_SDK_ROOT=/path/to/connectedhomeip"
        exit 1
    }
fi

# Check dependencies
echo ""
echo "Checking dependencies..."
MISSING_DEPS=()

command -v python3 >/dev/null || MISSING_DEPS+=("python3")
command -v ninja >/dev/null || MISSING_DEPS+=("ninja-build")
command -v pkg-config >/dev/null || MISSING_DEPS+=("pkg-config")
command -v git >/dev/null || MISSING_DEPS+=("git")
command -v aarch64-linux-gnu-g++ >/dev/null || MISSING_DEPS+=("g++-aarch64-linux-gnu")
command -v aarch64-linux-gnu-gcc >/dev/null || MISSING_DEPS+=("gcc-aarch64-linux-gnu")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "Missing dependencies: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt-get install ${MISSING_DEPS[*]}"
    exit 1
fi

# Bootstrap SDK environment
echo ""
echo "Bootstrapping SDK environment..."
if [ ! -d "$SDK_ROOT/.environment" ]; then
    echo "Running bootstrap (this may take several minutes)..."
    # Use Matter SDK's own bootstrap which handles submodules efficiently
    cd "$SDK_ROOT"
    python3 scripts/checkout_submodules.py --shallow --platform linux
    bash scripts/build/gn_bootstrap.sh
fi

# Activate environment
echo "Activating Matter environment..."
source "$SDK_ROOT/scripts/activate.sh"

# Build OTA requestor app
echo ""
echo "Building OTA requestor app..."
bash "$SDK_ROOT/scripts/examples/gn_build_example.sh" \
    "$SDK_ROOT/examples/ota-requestor-app/linux" \
    "$BUILD_DIR" \
    "target_cpu=\"arm64\"" \
    "is_debug=false" \
    "chip_config_network_layer_ble=false"

# Build OTA provider app (reference control)
echo ""
echo "Building OTA provider app (reference)..."
bash "$SDK_ROOT/scripts/examples/gn_build_example.sh" \
    "$SDK_ROOT/examples/ota-provider-app/linux" \
    "$BUILD_DIR" \
    "target_cpu=\"arm64\"" \
    "is_debug=false" \
    "chip_config_network_layer_ble=false"

# Build chip-tool
echo ""
echo "Building chip-tool..."
bash "$SDK_ROOT/scripts/examples/gn_build_example.sh" \
    "$SDK_ROOT/examples/chip-tool" \
    "$BUILD_DIR" \
    "target_cpu=\"arm64\"" \
    "is_debug=false" \
    "chip_config_network_layer_ble=false"

# Verify binaries
echo ""
echo "Verifying binaries..."
BINARIES=(
    "chip-ota-requestor-app"
    "chip-ota-provider-app"
    "chip-tool"
)

ALL_OK=true
for bin in "${BINARIES[@]}"; do
    if [ -f "$BUILD_DIR/$bin" ]; then
        echo "  ✓ $bin"
    else
        echo "  ✗ $bin - MISSING"
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = true ]; then
    echo ""
    echo "=================================================="
    echo "Build complete!"
    echo "=================================================="
    echo "SDK Location: $SDK_ROOT"
    echo "Binaries location: $BUILD_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Generate test images: ./scripts/make-images.sh"
    echo "  2. Launch test: ./scripts/run-test.sh happy-path"
    echo ""
    echo "To use a different SDK location:"
    echo "  export MATTER_SDK_ROOT=/path/to/connectedhomeip"
    echo "  ./build-setup.sh"
    exit 0
else
    echo ""
    echo "Build FAILED - some binaries missing"
    exit 1
fi
