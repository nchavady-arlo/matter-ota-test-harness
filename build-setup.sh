#!/bin/bash
# OTA Test Harness Build Setup
# Matter SDK v1.5.1.0
# Platform: Linux x86_64

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${MATTER_SDK_ROOT:-/home/nchavady/workspace/github/connectedhomeip}"
BUILD_DIR="${SDK_ROOT}/out/linux_x64"

echo "=================================================="
echo "Matter OTA Test Harness - Build Setup"
echo "=================================================="
echo "SDK Location: $SDK_ROOT"
echo "Build Directory: $BUILD_DIR"
echo ""

# Check SDK exists
if [ ! -d "$SDK_ROOT" ]; then
    echo "ERROR: Matter SDK not found at: $SDK_ROOT"
    echo ""
    echo "Either:"
    echo "  1. Set MATTER_SDK_ROOT to your SDK location:"
    echo "     export MATTER_SDK_ROOT=/path/to/connectedhomeip"
    echo "  2. Clone the SDK:"
    echo "     git clone --depth 1 --branch v1.5.1.0 https://github.com/project-chip/connectedhomeip.git"
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
MISSING_DEPS=()

command -v python3 >/dev/null || MISSING_DEPS+=("python3")
command -v ninja >/dev/null || MISSING_DEPS+=("ninja-build")
command -v pkg-config >/dev/null || MISSING_DEPS+=("pkg-config")
command -v git >/dev/null || MISSING_DEPS+=("git")
command -v g++ >/dev/null || MISSING_DEPS+=("g++")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "ERROR: Missing dependencies: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt-get install ${MISSING_DEPS[*]}"
    exit 1
fi
echo "✓ All dependencies found"
echo ""

# Bootstrap SDK environment if needed
cd "$SDK_ROOT"
if [ ! -d ".environment" ]; then
    echo "Bootstrapping SDK environment (first time only, ~5 minutes)..."
    python3 scripts/checkout_submodules.py --shallow --platform linux
    bash scripts/build/gn_bootstrap.sh
    echo "✓ Bootstrap complete"
fi

# Activate environment
echo "Activating Matter environment..."
source scripts/activate.sh

# Build apps using SDK's build script
echo ""
echo "Building OTA requestor app..."
bash scripts/examples/gn_build_example.sh \
    examples/ota-requestor-app/linux \
    "$BUILD_DIR" \
    "is_debug=false"

echo ""
echo "Building OTA provider app..."
bash scripts/examples/gn_build_example.sh \
    examples/ota-provider-app/linux \
    "$BUILD_DIR" \
    "is_debug=false"

echo ""
echo "Building chip-tool..."
bash scripts/examples/gn_build_example.sh \
    examples/chip-tool \
    "$BUILD_DIR" \
    "is_debug=false"

# Verify binaries
echo ""
echo "Verifying binaries..."
ALL_OK=true
for bin in chip-ota-requestor-app chip-ota-provider-app chip-tool; do
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
    echo "Binaries: $BUILD_DIR"
    echo ""
    echo "Next steps:"
    echo "  ./scripts/make-images.sh"
    echo "  ./scripts/run-test.sh happy-path"
    exit 0
else
    echo ""
    echo "ERROR: Build failed - some binaries missing"
    exit 1
fi
