#!/bin/bash
# Inspect a requestor's downloaded OTA image and explain apply results.
# Called by start-ota-end-node.sh's log monitor at key OTA stages.
#
# Usage: ota-status.sh received <instance> [download-path] [--skip-exec]
#        ota-status.sh apply-failed <instance> [download-path]
#
# download-path comes from the requestor's "OTA image downloaded to <path>" log
# line; without it, the run-requestor.sh default is assumed.

EXEC_PATH="/tmp/ota.update"   # kImageExecPath in the SDK's Linux OTAImageProcessorImpl

cmd=$1
instance=$2
download=${3:-"/tmp/ota-requestor-${instance}.bin"}   # get_download_path in run-requestor.sh
skip_exec=${4:-}

if ! [[ "$instance" =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 received|apply-failed <instance> [download-path]" >&2
    exit 1
fi

human_size() {
    numfmt --to=iec --suffix=B "$(stat -c %s "$1")" 2>/dev/null || stat -c '%s bytes' "$1"
}

is_elf() {
    [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

describe() {
    local f=$1
    if is_elf "$f"; then
        echo "Linux executable ($(file -b "$f" 2>/dev/null | cut -d, -f1-2))"
    else
        echo "NOT a Linux executable ($(file -b "$f" 2>/dev/null | cut -c1-60))"
    fi
}

case "$cmd" in
    received)
        if [ -f "$download" ]; then
            echo "   File: $download ($(human_size "$download"))"
            echo "   Type: $(describe "$download")"
            if [ -n "$skip_exec" ]; then
                echo "   (--skip-exec: the image will not be executed)"
            elif ! is_elf "$download"; then
                echo "   ⚠ Applying this will fail: the Linux requestor exec()s the image."
                echo "     Resume with --skip-exec to test a provider serving device firmware."
            elif findmnt -no OPTIONS -T /tmp 2>/dev/null | grep -qw noexec; then
                echo "   ⚠ Applying this will fail: /tmp is mounted noexec, so $EXEC_PATH"
                echo "     cannot be executed. Resume with --skip-exec, or remount /tmp."
            fi
        else
            echo "   (download file not found: $download)"
        fi
        ;;
    apply-failed)
        echo "Reason:"
        if [ -f "$EXEC_PATH" ] && [ -f "$download" ] && ! cmp -s "$EXEC_PATH" "$download"; then
            # rename() moves the download, so both existing and differing means
            # $EXEC_PATH is left over from an earlier (or another instance's) apply
            echo "  $EXEC_PATH is stale: it is not this download ($download)."
            echo "  The image was never moved there. /tmp/ota.update is shared by all"
            echo "  instances, so only one can apply at a time."
            echo "  Image type: $(describe "$download")"
        elif [ -f "$EXEC_PATH" ]; then
            if ! is_elf "$EXEC_PATH"; then
                echo "  $EXEC_PATH is $(describe "$EXEC_PATH")."
                echo "  The provider served an image the Linux requestor cannot run"
                echo "  (e.g. real device firmware)."
            elif [ ! -x "$EXEC_PATH" ]; then
                echo "  $EXEC_PATH is not executable."
            elif findmnt -no OPTIONS -T "$EXEC_PATH" 2>/dev/null | grep -qw noexec; then
                echo "  $(findmnt -no TARGET -T "$EXEC_PATH") is mounted noexec, so $EXEC_PATH cannot run."
            else
                echo "  $EXEC_PATH is a Linux executable but exec failed"
                echo "  (wrong architecture or missing shared libraries?):"
                echo "    $(file -b "$EXEC_PATH" | cut -c1-100)"
            fi
        elif [ -f "$download" ]; then
            echo "  The image was never moved to $EXEC_PATH."
            if [ "$(stat -c %d "$(dirname "$download")")" != "$(stat -c %d /tmp)" ]; then
                echo "  The SDK uses rename(), which fails across filesystems:"
                echo "    download: $(df --output=target "$download" | tail -1) ($download)"
                echo "    exec:     $(df --output=target /tmp | tail -1) ($EXEC_PATH)"
            else
                echo "  Download and $EXEC_PATH share a filesystem, so the apply step"
                echo "  likely never ran (check the log above for the first error)."
            fi
            echo "  Image type: $(describe "$download")"
        else
            echo "  Neither $EXEC_PATH nor $download exists."
        fi
        echo ""
        echo "The requestor process has exited. Its fabric is preserved; resume with:"
        echo "  ./scripts/start-ota-end-node.sh resume $instance --skip-exec"
        ;;
    *)
        echo "Usage: $0 received|apply-failed <instance> [download-path]" >&2
        exit 1
        ;;
esac
