#!/usr/bin/env bash
set -euo pipefail

# Bundle container.lg into a standalone linux/arm64 binary using lg -b.
#
# On a macOS host we additionally compile a thin Go "forwarder" that
# invokes the Linux binary inside a Lima VM — so `./lgcr` just works
# as a command on macOS and the user never has to type `limactl shell`.
#
# Layout on macOS:   ./lgcr (darwin native)  +  ./lgcr.linux (the real one)
# Layout on Linux:   ./lgcr (the real one)
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

HOST_OS="$(uname)"
if [ "$HOST_OS" = "Darwin" ]; then
    LINUX_OUT="${OUTPUT}.linux"
    echo "==> Cross-bundling container.lg → $LINUX_OUT..."
    "$LG_HOST" -b "$LINUX_OUT" -bundle-base "$LG_LINUX" "$SCRIPT_DIR/container.lg"
    chmod +x "$LINUX_OUT"

    echo "==> Building macOS forwarder → $OUTPUT..."
    (cd "$SCRIPT_DIR" && go build -o "$OUTPUT" darwin_wrapper.go)
    chmod +x "$OUTPUT"

    LSIZE=$(ls -lh "$LINUX_OUT" | awk '{print $5}')
    DSIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "==> Done: $OUTPUT ($DSIZE, macOS shim) + $LINUX_OUT ($LSIZE)"
    echo
    echo "Run directly on macOS — no limactl wrapper needed:"
    echo "  $OUTPUT pull alpine:3.21"
    echo "  $OUTPUT run alpine:3.21 echo hello"
else
    echo "==> Cross-bundling container.lg → $OUTPUT..."
    "$LG_HOST" -b "$OUTPUT" -bundle-base "$LG_LINUX" "$SCRIPT_DIR/container.lg"
    chmod +x "$OUTPUT"
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "==> Done: $OUTPUT ($SIZE)"
fi
