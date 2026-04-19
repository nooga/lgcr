#!/usr/bin/env bash
# Top-level test runner: builds lgcr, runs unit tests on the host, runs e2e
# tests inside Lima. Single command to reproduce the whole suite.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cd "$ROOT"

echo "==> Bundling lgcr..."
./bundle.sh ./lgcr > /dev/null

echo
echo "==> Unit tests (host)..."
./.lg-host tests/lib_test.lg

echo
echo "==> E2E tests (Lima)..."
if ! limactl list letgo --format '{{.Status}}' 2>/dev/null | grep -q Running; then
    echo "starting lima letgo VM..."
    limactl start letgo > /dev/null
fi
limactl shell letgo sudo bash "$ROOT/tests/e2e.sh"
