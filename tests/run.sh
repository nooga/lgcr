#!/usr/bin/env bash
# Top-level test runner.
#
# Always:
#   1. bundle lgcr
#   2. unit tests on the host
#   3. e2e inside Lima driving the linux binary directly (LGCR=lgcr.linux)
#
# On macOS additionally:
#   4. e2e from the host, driving ./lgcr (darwin shim) — proves the shim
#      forwards behavior identically to the direct linux invocation
#   5. e2e-shim.sh — shim-only paths (missing binary / missing limactl /
#      output-parity checks)

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cd "$ROOT"

echo "==> Bundling lgcr..."
./bundle.sh ./lgcr > /dev/null

echo
echo "==> Unit tests (host)..."
./.lg-host tests/lib_test.lg

ensure_lima() {
    if ! limactl list letgo --format '{{.Status}}' 2>/dev/null | grep -q Running; then
        echo "starting lima letgo VM..."
        limactl start letgo > /dev/null
    fi
}

echo
echo "==> E2E tests (Lima, direct linux binary)..."
ensure_lima
limactl shell letgo sudo bash "$ROOT/tests/e2e.sh"

if [ "$(uname)" = "Darwin" ] && [ -x "$ROOT/lgcr.linux" ]; then
    echo
    echo "==> E2E tests (macOS host, via darwin shim → Lima)..."
    LGCR="$ROOT/lgcr" bash "$ROOT/tests/e2e.sh"

    echo
    echo "==> Shim-specific tests..."
    bash "$ROOT/tests/e2e-shim.sh"
fi
