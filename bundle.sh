#!/usr/bin/env bash
set -euo pipefail

# Bundle container.lg into a standalone linux binary using lg -b inside lima.
#
# This produces a single static executable that contains:
#   - the let-go VM + stdlib
#   - the compiled container.lg bytecode
#
# Usage: ./bundle.sh [output-name]
#   default output: ./lgcr

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/lgcr}"

# We need a linux lg binary to use as the bundle base.
# Try the GitHub release first, fall back to building from source.
LG_LINUX="$SCRIPT_DIR/.lg-linux"

if [ ! -f "$LG_LINUX" ]; then
    LETGO_SRC="$SCRIPT_DIR/../let-go"
    if [ -d "$LETGO_SRC" ] && [ -f "$LETGO_SRC/go.mod" ]; then
        echo "==> Building let-go linux binary from source..."
        (cd "$LETGO_SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$LG_LINUX" .)
    else
        echo "==> Downloading let-go linux binary..."
        gh release download v1.4.0 --repo nooga/let-go --pattern "let-go_1.4.0_linux_arm64.tar.gz" --output /tmp/lg-linux.tar.gz
        tar xzf /tmp/lg-linux.tar.gz -C /tmp lg
        mv /tmp/lg "$LG_LINUX"
        rm /tmp/lg-linux.tar.gz
    fi
fi
echo "    base binary: $LG_LINUX"

# Bundle inside lima (lg -b needs to run on the same platform as the output)
echo "==> Bundling container.lg into standalone binary..."
limactl shell letgo "$LG_LINUX" -b "$OUTPUT" "$SCRIPT_DIR/container.lg"

chmod +x "$OUTPUT"
SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "==> Done: $OUTPUT ($SIZE)"
echo
echo "Usage:"
echo "  limactl shell letgo sudo $OUTPUT pull alpine:3.21"
echo "  limactl shell letgo sudo $OUTPUT run /tmp/letgo-rootfs/library_alpine-3.21 echo hello"
