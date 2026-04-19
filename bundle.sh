#!/usr/bin/env bash
set -euo pipefail

# Bundle container.lg into a standalone linux binary using lg -b.
# Runs entirely on the host (no Lima needed) using lg -bundle-base to
# cross-bundle for linux/arm64 from macOS.
#
# Produces a single static executable containing:
#   - the let-go VM + stdlib
#   - the compiled container.lg bytecode
#
# Usage: ./bundle.sh [output-name]
#   default output: ./lgcr

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/lgcr}"

LETGO_SRC="$SCRIPT_DIR/../let-go"
LG_HOST="$SCRIPT_DIR/.lg-host"
LG_LINUX="$SCRIPT_DIR/.lg-linux"

if [ ! -d "$LETGO_SRC" ] || [ ! -f "$LETGO_SRC/go.mod" ]; then
    echo "error: expected let-go checkout at $LETGO_SRC" >&2
    exit 1
fi

echo "==> Building host let-go binary..."
(cd "$LETGO_SRC" && go build -o "$LG_HOST" .)

echo "==> Building linux/arm64 let-go binary..."
(cd "$LETGO_SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$LG_LINUX" .)

echo "==> Cross-bundling container.lg → $OUTPUT..."
"$LG_HOST" -b "$OUTPUT" -bundle-base "$LG_LINUX" "$SCRIPT_DIR/container.lg"

chmod +x "$OUTPUT"
SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "==> Done: $OUTPUT ($SIZE)"
echo
echo "Usage:"
echo "  limactl shell letgo sudo $OUTPUT pull alpine:3.21"
echo "  limactl shell letgo sudo $OUTPUT run /tmp/letgo-rootfs/library_alpine-3.21 echo hello"
