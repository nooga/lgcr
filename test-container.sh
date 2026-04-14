#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$ROOT/letgo-linux"
CONTAINER="$SCRIPT_DIR/container.lg"

echo "==> Building static linux/arm64 binary..."
cd "$ROOT"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$BIN" .
echo "    built: $BIN"
echo

LG="sudo $BIN $CONTAINER"

echo "--- pull alpine:3.21 from Docker Hub ---"
limactl shell letgo $LG pull alpine:3.21
ROOTFS="/tmp/letgo-rootfs/library_alpine-3.21"
echo

echo "--- run: echo hello ---"
limactl shell letgo $LG run "$ROOTFS" echo "hello from let-go container"
echo

echo "--- run: cat /etc/os-release ---"
limactl shell letgo $LG run "$ROOTFS" cat /etc/os-release
echo

echo "--- run: hostname ---"
limactl shell letgo $LG run "$ROOTFS" hostname
echo

echo "--- run: ls / ---"
limactl shell letgo $LG run "$ROOTFS" ls /

echo
echo "==> Cleaning up binary..."
rm -f "$BIN"
echo "    done."
