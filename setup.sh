#!/bin/bash
# Central configuration for Matter OTA Test Harness
# Source this file from other scripts to get common paths and settings

MATTER_HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Matter SDK location
export MATTER_SDK_ROOT="${MATTER_SDK_ROOT:-/home/nchavady/workspace/github/connectedhomeip}"
export MATTER_BUILD_DIR="${MATTER_BUILD_DIR:-${MATTER_SDK_ROOT}/out/linux_x64}"
# Requestor built at CURRENT_VERSION+1; used as the OTA image payload
export MATTER_OTA_BUILD_DIR="${MATTER_OTA_BUILD_DIR:-${MATTER_SDK_ROOT}/out/linux_x64_ota}"

# Versions recorded by build-setup.sh (CURRENT_VERSION, OTA_VERSION)
BUILD_VERSION_FILE="${MATTER_HARNESS_ROOT}/build-version.env"
if [ -f "$BUILD_VERSION_FILE" ]; then
    source "$BUILD_VERSION_FILE"
fi
export CURRENT_VERSION="${CURRENT_VERSION:-10}"
export OTA_VERSION="${OTA_VERSION:-$((CURRENT_VERSION + 1))}"

# Validate SDK exists
if [ ! -d "$MATTER_SDK_ROOT" ]; then
    echo "ERROR: Matter SDK not found at: $MATTER_SDK_ROOT" >&2
    echo "Set MATTER_SDK_ROOT environment variable to your SDK location" >&2
    return 1 2>/dev/null || exit 1
fi

# Validate build directory exists
if [ ! -d "$MATTER_BUILD_DIR" ]; then
    echo "WARNING: Build directory not found at: $MATTER_BUILD_DIR" >&2
    echo "Run ./build-setup.sh to build SDK components" >&2
fi
