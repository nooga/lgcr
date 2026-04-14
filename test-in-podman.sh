#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$ROOT/letgo-linux"

echo "==> Building static linux/amd64 binary..."
cd "$ROOT"
CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH:-$(go env GOARCH)}" go build -o "$BIN" .
echo "    built: $BIN"
echo

echo "==> Running syscall test in privileged podman container..."
podman run --rm --privileged \
    -v "$BIN:/usr/local/bin/let-go:ro" \
    -v "$SCRIPT_DIR/test-syscall.lg:/test-syscall.lg:ro" \
    alpine:latest \
    /usr/local/bin/let-go /test-syscall.lg

echo
echo "==> Cleaning up binary..."
rm -f "$BIN"
echo "    done."
