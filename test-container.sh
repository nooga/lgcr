#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/letgo-linux"
CONTAINER="$SCRIPT_DIR/container.lg"

# Build a linux binary from the let-go source tree if available,
# otherwise try to bundle via the installed lg inside lima.
LETGO_SRC="$SCRIPT_DIR/../let-go"
if [ -d "$LETGO_SRC" ] && [ -f "$LETGO_SRC/go.mod" ]; then
    echo "==> Building static linux/arm64 binary from source..."
    (cd "$LETGO_SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$BIN" .)
else
    echo "==> Downloading let-go linux binary from GitHub release..."
    gh release download v1.4.0 --repo nooga/let-go --pattern "let-go_1.4.0_linux_arm64.tar.gz" --output /tmp/lg-linux.tar.gz
    tar xzf /tmp/lg-linux.tar.gz -C /tmp lg
    mv /tmp/lg "$BIN"
    rm /tmp/lg-linux.tar.gz
fi
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
