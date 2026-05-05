#!/usr/bin/env bash
# Darwin-shim-specific checks. Run from the macOS host (NOT inside Lima).
# Exercises error paths of the darwin wrapper that can't be reached by the
# regular Linux-side e2e suite.
#
# Prereqs: ./lgcr (darwin Mach-O shim) + ./lgcr.linux (linux ELF) present,
#          lima 'letgo' VM running.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/lgcr"
LBIN="$ROOT/lgcr.linux"
IMG="${IMG:-quay.io/libpod/alpine:latest}"

PASS=0
FAIL=0
CURRENT=""

section()         { echo; echo "=== $1 ==="; CURRENT="$1"; }
expect_eq() {
    local got="$1" want="$2" msg="${3:-}"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1)); echo "  ok  ${msg:-$got = $want}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL [${CURRENT}] ${msg}: want=$want got=$got"
    fi
}
expect_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1)); echo "  ok  ${msg:-contains '$needle'}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL [${CURRENT}] ${msg}: '$haystack' lacks '$needle'"
    fi
}

wait_for_shim_running_row() {
    local short_id="$1"
    local row=""
    for _ in $(seq 1 40); do
        row=$("$SHIM" ps | grep "^${short_id} " | head -1 || true)
        if [ -n "$row" ]; then
            printf '%s' "$row"
            return 0
        fi
        sleep 0.25
    done
    printf '%s' "$row"
    return 1
}

wait_for_linux_running_row() {
    local short_id="$1"
    local row=""
    for _ in $(seq 1 40); do
        row=$(limactl shell letgo sudo "$LBIN" ps | grep "^${short_id} " | head -1 || true)
        if [ -n "$row" ]; then
            printf '%s' "$row"
            return 0
        fi
        sleep 0.25
    done
    printf '%s' "$row"
    return 1
}

if [ "$(uname)" != "Darwin" ]; then
    echo "[skip] e2e-shim.sh is darwin-only"; exit 0
fi
if [ ! -x "$SHIM" ] || ! file "$SHIM" | grep -q 'Mach-O'; then
    echo "[skip] $SHIM is not a darwin Mach-O — rebuild via bundle.sh on macOS"; exit 0
fi
if [ ! -x "$LBIN" ]; then
    echo "[skip] $LBIN missing — rebuild via bundle.sh"; exit 0
fi

# ---------------------------------------------------------------------------
# error paths
# ---------------------------------------------------------------------------

section "missing lgcr.linux triggers a clear error"
STASH=$(mktemp -d)
mv "$LBIN" "$STASH/lgcr.linux"
set +e
OUT=$("$SHIM" ps 2>&1); EC=$?
set -e
mv "$STASH/lgcr.linux" "$LBIN"
rmdir "$STASH"
expect_eq "$EC" "1" "exit 1 when linux bin missing"
expect_contains "$OUT" "missing Linux binary" "error message"

section "missing limactl triggers a clear error"
set +e
OUT=$(PATH=/usr/bin:/bin "$SHIM" ps 2>&1); EC=$?
set -e
expect_eq "$EC" "1" "exit 1 when limactl not in PATH"
expect_contains "$OUT" "brew install lima" "suggests the fix"

# ---------------------------------------------------------------------------
# happy path: shim forwards and the result matches direct linux invocation
# ---------------------------------------------------------------------------

section "shim forwards ps output identically to direct linux call"
for id in $("$SHIM" ps -aq 2>/dev/null); do "$SHIM" rm -f "$id" > /dev/null || true; done
# Seed a known-good image through the Linux binary, then create the
# container through the Linux binary as well. This keeps the test focused on
# shim forwarding of ps/exec/inspect rather than detached-startup timing.
limactl shell letgo sudo "$LBIN" pull "$IMG" > /dev/null 2>&1
CID=$(limactl shell letgo sudo "$LBIN" run -d "$IMG" sleep 30 | tail -1)
SHORT_ID="${CID:0:12}"
SHIM_ROW=$(wait_for_shim_running_row "$SHORT_ID")
LINUX_ROW=$(wait_for_linux_running_row "$SHORT_ID")
SHIM_OUT=$("$SHIM" ps | head -3)
LINUX_OUT=$(limactl shell letgo sudo "$LBIN" ps | head -3)
SHIM_HDR=$(printf '%s\n' "$SHIM_OUT" | sed -n '1p')
LINUX_HDR=$(printf '%s\n' "$LINUX_OUT" | sed -n '1p')
expect_eq "$SHIM_HDR" "$LINUX_HDR" "ps header identical via both paths"
expect_contains "$SHIM_ROW" "$SHORT_ID" "shim ps row contains container id"
expect_contains "$LINUX_ROW" "$SHORT_ID" "linux ps row contains container id"
expect_contains "$SHIM_ROW" "Up " "shim ps row reports running status"
expect_contains "$LINUX_ROW" "Up " "linux ps row reports running status"
expect_contains "$SHIM_ROW" "sleep 30" "shim ps row contains command"
expect_contains "$LINUX_ROW" "sleep 30" "linux ps row contains command"

section "shim forwards stdout + exit code from a simple command"
set +e
OUT=$("$SHIM" exec "${CID:0:6}" /bin/sh -c "echo hi-from-shim; exit 5" 2>&1)
EC=$?
set -e
expect_eq "$EC" "5" "exit code 5 propagated through shim"
expect_contains "$OUT" "hi-from-shim" "stdout propagated"

section "shim forwards signal+status (kill -9)"
"$SHIM" kill -s KILL "${CID:0:6}" > /dev/null
sleep 0.3
STATUS=$("$SHIM" inspect "${CID:0:6}" | tr ',' '\n' | grep -o '"status":"[^"]*"' | head -1)
expect_eq "$STATUS" '"status":"killed"' "kill status roundtrips through shim"

"$SHIM" rm -f "${CID:0:6}" > /dev/null

echo
echo "==============================================="
if [ "$FAIL" -eq 0 ]; then
    echo "  shim suite: $PASS ok"
else
    echo "  shim suite: $PASS ok, $FAIL FAILED"
fi
echo "==============================================="

[ "$FAIL" -eq 0 ]
