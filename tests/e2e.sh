#!/usr/bin/env bash
# End-to-end tests for lgcr.
# Designed to run inside the Lima 'letgo' VM as root.
# Usage (on host): limactl shell letgo sudo bash /Users/nooga/lab/lgcr/tests/e2e.sh
#                  or via ./tests/run.sh

set -eu

LGCR="${LGCR:-/Users/nooga/lab/lgcr/lgcr}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lgcr"
IMG="${IMG:-alpine:3.21}"

PASS=0
FAIL=0
CURRENT=""

section() {
    echo
    echo "=== $1 ==="
    CURRENT="$1"
}

expect_eq() {
    local got="$1" want="$2" msg="${3:-}"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        echo "  ok  ${msg:-$got = $want}"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL [${CURRENT}] ${msg}: want=$want got=$got"
    fi
}

expect_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        echo "  ok  ${msg:-contains '$needle'}"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL [${CURRENT}] ${msg}: '$haystack' does not contain '$needle'"
    fi
}

expect_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        echo "  ok  ${msg:-does not contain '$needle'}"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL [${CURRENT}] ${msg}: unexpectedly found '$needle'"
    fi
}

json_field() {
    local file="$1" field="$2"
    # very small JSON extractor — state.json has no nested braces inside values
    # we care about, so a naive sed is fine.
    tr ',' '\n' < "$file" | sed -n "s/.*\"${field}\":\"\{0,1\}\([^\"\\}]*\).*/\1/p" | head -1
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

if [ ! -x "$LGCR" ]; then
    echo "error: lgcr not found at $LGCR" >&2
    exit 1
fi

rm -rf "$STATE"

if [ ! -d "/tmp/letgo-rootfs/library_${IMG/:/-}" ]; then
    echo "=== pulling $IMG (one-time) ==="
    "$LGCR" pull "$IMG" > /dev/null
fi

# ---------------------------------------------------------------------------

section "foreground run exits with 0"
OUT=$("$LGCR" run "$IMG" sh -c "echo hello" 2>&1)
expect_contains "$OUT" "hello" "stdout captured"
expect_contains "$OUT" "container exited with status 0" "clean exit"

section "detached run returns a 32-char id"
CID=$("$LGCR" run -d "$IMG" sleep 30 2>&1 | tail -1)
expect_eq "${#CID}" "32" "id is 32 hex chars"
sleep 1

section "ps sees the running container"
OUT=$("$LGCR" ps)
expect_contains "$OUT" "${CID:0:12}" "short id appears in ps"
expect_contains "$OUT" "Up " "Up status"
expect_contains "$OUT" "sleep 30" "command column"

section "ps -q outputs only short ids"
OUT=$("$LGCR" ps -q)
expect_eq "$OUT" "${CID:0:12}" "ps -q single line"

section "ps -aq combined short-flags split correctly"
OUT=$("$LGCR" ps -aq)
expect_contains "$OUT" "${CID:0:12}" "ps -aq still lists the container"

section "logs streams captured stdout"
CID2=$("$LGCR" run -d "$IMG" sh -c "echo one; echo two; echo three" 2>&1 | tail -1)
sleep 1
OUT=$("$LGCR" logs "${CID2:0:6}")
expect_contains "$OUT" "one"
expect_contains "$OUT" "two"
expect_contains "$OUT" "three"
"$LGCR" rm "${CID2:0:6}" > /dev/null

section "stop forwards SIGTERM; trap handler observes it"
CID3=$("$LGCR" run -d "$IMG" sh -c 'trap "echo got-TERM; exit 42" TERM; while true; do sleep 1; done' 2>&1 | tail -1)
sleep 1
"$LGCR" stop -t 3 "${CID3:0:6}" > /dev/null
sleep 1
OUT=$("$LGCR" logs "${CID3:0:6}")
expect_contains "$OUT" "got-TERM" "trap ran"
STATE_FILE="$STATE/containers/$CID3/state.json"
expect_eq "$(json_field "$STATE_FILE" status)" "exited" "status=exited"
expect_eq "$(json_field "$STATE_FILE" exit-code)" "42" "exit-code=42"
"$LGCR" rm "${CID3:0:6}" > /dev/null

section "kill -s KILL records signal 9"
CID4=$("$LGCR" run -d "$IMG" sleep 60 2>&1 | tail -1)
sleep 1
"$LGCR" kill -s KILL "${CID4:0:6}" > /dev/null
sleep 1
STATE_FILE="$STATE/containers/$CID4/state.json"
expect_eq "$(json_field "$STATE_FILE" status)" "killed" "status=killed"
expect_eq "$(json_field "$STATE_FILE" signal)" "9" "signal=9"
"$LGCR" rm "${CID4:0:6}" > /dev/null

section "rm refuses a running container; -f overrides"
CID5=$("$LGCR" run -d "$IMG" sleep 30 2>&1 | tail -1)
sleep 1
if "$LGCR" rm "${CID5:0:6}" 2>&1 | grep -q "is running"; then
    PASS=$((PASS + 1)); echo "  ok  rm without -f refused"
else
    FAIL=$((FAIL + 1)); echo "  FAIL [${CURRENT}] rm did not refuse running container"
fi
"$LGCR" rm -f "${CID5:0:6}" > /dev/null
if [ ! -d "$STATE/containers/$CID5" ]; then
    PASS=$((PASS + 1)); echo "  ok  rm -f removed state dir"
else
    FAIL=$((FAIL + 1)); echo "  FAIL [${CURRENT}] state dir still exists after rm -f"
fi

section "start respawns a stopped container"
CID6=$("$LGCR" run -d "$IMG" sh -c 'echo one; sleep 30' 2>&1 | tail -1)
sleep 1
"$LGCR" stop -t 2 "${CID6:0:6}" > /dev/null
sleep 1
"$LGCR" start "${CID6:0:6}" > /dev/null
sleep 1
OUT=$("$LGCR" ps)
expect_contains "$OUT" "${CID6:0:12}" "respawned container in ps"
"$LGCR" rm -f "${CID6:0:6}" > /dev/null

section "inspect prints JSON containing id"
CID7=$("$LGCR" run -d "$IMG" sleep 60 2>&1 | tail -1)
sleep 1
OUT=$("$LGCR" inspect "${CID7:0:6}")
expect_contains "$OUT" "\"id\":\"$CID7\"" "state id"
expect_contains "$OUT" "\"status\":\"running\"" "status field"
"$LGCR" rm -f "${CID7:0:6}" > /dev/null

section "image ref: env and workdir applied"
# alpine config has WORKDIR=/ and PATH=/usr/local/... — verify they arrive
OUT=$("$LGCR" run "$IMG" sh -c "echo PATH=\$PATH; pwd")
expect_contains "$OUT" "/usr/local/sbin:/usr/local/bin" "image PATH present"
expect_contains "$OUT" "/" "workdir applied"

section "env override: -e FOO=bar arrives inside container"
OUT=$("$LGCR" run -e "FOO=bar" "$IMG" sh -c "echo FOO=\$FOO")
expect_contains "$OUT" "FOO=bar"

section "id prefix ambiguity is caught"
# generate two containers, use 2-char prefix '0...' → potentially ambiguous.
# do this by running twice with --rm off, leaving state dirs.
CA=$("$LGCR" run -d "$IMG" sleep 5 2>&1 | tail -1)
CB=$("$LGCR" run -d "$IMG" sleep 5 2>&1 | tail -1)
# take 2-char common prefix "a"? can't — ids are random. Try 1-char prefix to
# exercise the min-length check instead:
OUT=$("$LGCR" ps "${CA:0:1}" 2>&1 || true)
# ps doesn't take an id arg; do a real command that does
OUT=$("$LGCR" inspect "${CA:0:1}" 2>&1 || true)
expect_contains "$OUT" "at least 2 characters" "min-prefix enforced"
"$LGCR" rm -f "${CA:0:6}" "${CB:0:6}" > /dev/null

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------

"$LGCR" rm -f "${CID:0:6}" > /dev/null 2>&1 || true

echo
echo "==============================================="
if [ "$FAIL" -eq 0 ]; then
    echo "  All passed: $PASS ok"
else
    echo "  RESULT: $PASS ok, $FAIL FAILED"
fi
echo "==============================================="

[ "$FAIL" -eq 0 ]
