#!/bin/bash
# OTA Test Harness Build Setup
# Matter SDK v1.5.1.0 (commit abcc720b48)
# Platform: Linux aarch64, Ubuntu Server 24.04

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="/home/nchavady/workspace/github/connectedhomeip"
BUILD_DIR="${SDK_ROOT}/out/aarch64"

echo "=================================================="
echo "Matter OTA Test Harness - Build Setup"
echo "=================================================="

# Verify SDK version
cd "$SDK_ROOT"
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
CURRENT_COMMIT=$(git rev-parse --short HEAD)

echo "SDK Location: $SDK_ROOT"
echo "Current commit: $CURRENT_COMMIT"
echo "Current tag: ${CURRENT_TAG:-<not on a tag>}"

if [ "$CURRENT_TAG" != "v1.5.1.0" ]; then
    echo "WARNING: Expected v1.5.1.0, found $CURRENT_TAG"
    echo "This harness is validated against v1.5.1.0"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check dependencies
echo ""
echo "Checking dependencies..."
MISSING_DEPS=()

command -v python3 >/dev/null || MISSING_DEPS+=("python3")
command -v ninja >/dev/null || MISSING_DEPS+=("ninja-build")
command -v pkg-config >/dev/null || MISSING_DEPS+=("pkg-config")
command -v git >/dev/null || MISSING_DEPS+=("git")

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
    bash "$SDK_ROOT/scripts/checkout_submodules.py" --shallow --platform linux
    bash "$SDK_ROOT/scripts/build/gn_bootstrap.sh"
fi

# Activate environment
echo "Activating Matter environment..."
source "$SDK_ROOT/scripts/activate.sh"

# Configure build for aarch64
echo ""
echo "Configuring build for aarch64..."
echo "Build directory: $BUILD_DIR"

gn gen "$BUILD_DIR" --args='
target_cpu="arm64"
is_debug=false
chip_config_network_layer_ble=false
'

# Build OTA requestor app
echo ""
echo "Building chip-ota-requestor-app..."
ninja -C "$BUILD_DIR" chip-ota-requestor-app

# Build OTA provider app (reference control)
echo ""
echo "Building chip-ota-provider-app (reference)..."
ninja -C "$BUILD_DIR" chip-ota-provider-app

# Build chip-tool
echo ""
echo "Building chip-tool..."
ninja -C "$BUILD_DIR" chip-tool

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
    echo "Binaries location: $BUILD_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Generate test images: ./scripts/make-images.sh"
    echo "  2. Launch test: ./scripts/run-test.sh happy-path"
    exit 0
else
    echo ""
    echo "Build FAILED - some binaries missing"
    exit 1
fi
