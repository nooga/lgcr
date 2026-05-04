#!/usr/bin/env bash
# End-to-end tests for lgcr.
# Designed to run inside the Lima 'letgo' VM as root.
# Usage (on host): limactl shell letgo sudo bash /Users/nooga/lab/lgcr/tests/e2e.sh
#                  or via ./tests/run.sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP_BASE="$ROOT"
if [ ! -w "$ROOT" ]; then
    TMP_BASE="/tmp"
fi
HOST_BIND_RW_EXPECTED=1
if [ "$(uname)" != "Linux" ]; then
    HOST_BIND_RW_EXPECTED=0
fi

# Prefer the lima-side (Linux) binary — when bundle.sh runs on macOS it
# emits lgcr.linux alongside the darwin shim; on a Linux host there's just
# the single lgcr binary.
if [ -z "${LGCR:-}" ]; then
    if [ -x /Users/nooga/lab/lgcr/lgcr.linux ]; then
        LGCR=/Users/nooga/lab/lgcr/lgcr.linux
    else
        LGCR=/Users/nooga/lab/lgcr/lgcr
    fi
fi
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

pty_run() {
    # Run a shell command under a pty. `script`'s args differ between
    # BSD (macOS) and util-linux — detect and dispatch. We deliberately
    # swallow the inner exit status: callers assert on the captured
    # output, not the rc, and `set -e` would otherwise abort the whole
    # suite when the simulated shell exits non-zero.
    if [ "$(uname)" = "Darwin" ]; then
        script -q /dev/null sh -c "$*" || true
    else
        script -qc "$*" /dev/null || true
    fi
}

json_field() {
    # (json_field <id> <field>) — reads state via `lgcr inspect` so this
    # works whether we're running inside Lima or driving the darwin shim
    # from the host (where the state dir lives on the VM side).
    local id="$1" field="$2"
    "$LGCR" inspect "$id" | tr ',' '\n' \
        | sed -n "s/.*\"${field}\":\"\{0,1\}\([^\"\\}]*\).*/\1/p" | head -1
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

if [ ! -x "$LGCR" ]; then
    echo "error: lgcr not found at $LGCR" >&2
    exit 1
fi

# Wipe any leftover containers from a previous run via the tool itself —
# works whether we're inside Lima or driving the darwin shim from the host,
# since either way the state lives where $LGCR points at.
for _id in $("$LGCR" ps -aq 2>/dev/null); do
    "$LGCR" rm -f "$_id" > /dev/null 2>&1 || true
done

if ! "$LGCR" images -q 2>/dev/null | grep -qF "library/${IMG/:/:}"; then
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
expect_eq "$(json_field "${CID3:0:6}" status)" "exited" "status=exited"
expect_eq "$(json_field "${CID3:0:6}" exit-code)" "42" "exit-code=42"
"$LGCR" rm "${CID3:0:6}" > /dev/null

section "kill -s KILL records signal 9"
CID4=$("$LGCR" run -d "$IMG" sleep 60 2>&1 | tail -1)
sleep 1
"$LGCR" kill -s KILL "${CID4:0:6}" > /dev/null
sleep 1
expect_eq "$(json_field "${CID4:0:6}" status)" "killed" "status=killed"
expect_eq "$(json_field "${CID4:0:6}" signal)" "9" "signal=9"
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
if "$LGCR" ps -aq 2>/dev/null | grep -q "${CID5:0:12}"; then
    FAIL=$((FAIL + 1)); echo "  FAIL [${CURRENT}] container still listed after rm -f"
else
    PASS=$((PASS + 1)); echo "  ok  rm -f removed the container"
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

section "run --hostname sets container hostname"
OUT=$("$LGCR" run --hostname lgcr-test-host "$IMG" hostname 2>&1)
expect_contains "$OUT" "lgcr-test-host" "hostname applied"

section "run sets no_new_privs on the primary process"
OUT=$("$LGCR" run "$IMG" sh -c "awk '/^NoNewPrivs:/ { print \$2 }' /proc/self/status" 2>&1)
expect_contains "$OUT" "1" "NoNewPrivs=1 for run"

section "run applies the default capability set"
OUT=$("$LGCR" run "$IMG" sh -c 'v=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [ $((0x$v & 0x2000)) -ne 0 ] && echo HAS_NET_RAW; [ $((0x$v & 0x1000)) -eq 0 ] && echo NO_NET_ADMIN' 2>&1)
expect_contains "$OUT" "HAS_NET_RAW" "default keep-set includes NET_RAW"
expect_contains "$OUT" "NO_NET_ADMIN" "default keep-set excludes NET_ADMIN"

section "run --cap-drop removes a default capability"
OUT=$("$LGCR" run --cap-drop NET_RAW "$IMG" sh -c 'v=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [ $((0x$v & 0x2000)) -eq 0 ] && echo NO_NET_RAW' 2>&1)
expect_contains "$OUT" "NO_NET_RAW" "NET_RAW dropped"

section "run --cap-add adds an extra capability"
OUT=$("$LGCR" run --cap-add NET_ADMIN "$IMG" sh -c 'v=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [ $((0x$v & 0x1000)) -ne 0 ] && echo HAS_NET_ADMIN' 2>&1)
expect_contains "$OUT" "HAS_NET_ADMIN" "NET_ADMIN added"

section "run installs the default seccomp filter"
OUT=$("$LGCR" run --cap-add SYS_ADMIN "$IMG" sh -c 'echo SECCOMP=$(awk "/^Seccomp:/ { print \$2 }" /proc/self/status); mkdir -p /tmp/seccomp-mount; if mount -t tmpfs tmpfs /tmp/seccomp-mount 2>/dev/null; then echo MOUNT_OK; umount /tmp/seccomp-mount >/dev/null 2>&1; else echo MOUNT_BLOCKED; fi' 2>&1)
expect_contains "$OUT" "SECCOMP=2" "seccomp filter active"
expect_contains "$OUT" "MOUNT_BLOCKED" "default seccomp blocks mount even with SYS_ADMIN"

section "run --seccomp unconfined disables seccomp filtering"
OUT=$("$LGCR" run --cap-add SYS_ADMIN --seccomp unconfined "$IMG" sh -c 'echo SECCOMP=$(awk "/^Seccomp:/ { print \$2 }" /proc/self/status); mkdir -p /tmp/seccomp-mount; if mount -t tmpfs tmpfs /tmp/seccomp-mount 2>/dev/null; then echo MOUNT_OK; umount /tmp/seccomp-mount >/dev/null 2>&1; else echo MOUNT_BLOCKED; fi' 2>&1)
expect_contains "$OUT" "SECCOMP=0" "seccomp disabled"
expect_contains "$OUT" "MOUNT_OK" "mount allowed without seccomp when SYS_ADMIN is present"

section "run --apparmor surfaces AppArmor setup failures clearly"
set +e
OUT=$("$LGCR" run --apparmor test-profile "$IMG" sh -c 'true' 2>&1)
EC=$?
set -e
expect_eq "$EC" "1" "apparmor setup rc"
expect_contains "$OUT" "AppArmor" "apparmor setup error"

section "run provisions a curated /dev"
OUT=$("$LGCR" run "$IMG" sh -c 'for p in /dev/null /dev/zero /dev/full /dev/random /dev/urandom /dev/tty /dev/ptmx /dev/fd /dev/stdin /dev/stdout /dev/stderr /dev/shm; do [ -e "$p" ] && echo HAS:$p; done; [ -c /dev/null ] && echo NULL_CHAR; [ -c /dev/tty ] && echo TTY_CHAR; [ "$(readlink /dev/ptmx)" = "pts/ptmx" ] && echo PTMX_LINK; [ "$(readlink /dev/fd)" = "/proc/self/fd" ] && echo FD_LINK; awk '\''$2 == "/dev/pts" && $3 == "devpts" { print "DEVPTS_MOUNT" } $2 == "/dev/shm" && $3 == "tmpfs" { print "SHM_MOUNT" }'\'' /proc/mounts; printf x >/dev/null && echo NULL_WRITE_OK; echo shm-ok > /dev/shm/probe && cat /dev/shm/probe; zero=$(dd if=/dev/zero bs=4 count=1 2>/dev/null | wc -c | tr -d " "); echo ZERO_BYTES=$zero; rand=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | wc -c | tr -d " "); echo URANDOM_BYTES=$rand; [ ! -e /dev/kmsg ] && echo NO_KMSG' 2>&1)
expect_contains "$OUT" "HAS:/dev/null" "/dev/null present"
expect_contains "$OUT" "HAS:/dev/urandom" "/dev/urandom present"
expect_contains "$OUT" "HAS:/dev/ptmx" "/dev/ptmx present"
expect_contains "$OUT" "HAS:/dev/shm" "/dev/shm present"
expect_contains "$OUT" "NULL_CHAR" "/dev/null is a char device"
expect_contains "$OUT" "TTY_CHAR" "/dev/tty is a char device"
expect_contains "$OUT" "PTMX_LINK" "/dev/ptmx points at devpts"
expect_contains "$OUT" "FD_LINK" "/dev/fd points at proc fd"
expect_contains "$OUT" "DEVPTS_MOUNT" "/dev/pts mounted as devpts"
expect_contains "$OUT" "SHM_MOUNT" "/dev/shm mounted as tmpfs"
expect_contains "$OUT" "NULL_WRITE_OK" "/dev/null is writable"
expect_contains "$OUT" "shm-ok" "/dev/shm is writable"
expect_contains "$OUT" "ZERO_BYTES=4" "/dev/zero read works"
expect_contains "$OUT" "URANDOM_BYTES=4" "/dev/urandom read works"
expect_contains "$OUT" "NO_KMSG" "host /dev is not leaked wholesale"

section "run --net host keeps default network namespace"
OUT=$("$LGCR" run "$IMG" readlink /proc/self/ns/net 2>&1)
DEFAULT_NETNS=$(echo "$OUT" | grep -E 'net:\[[0-9]+\]' | tail -1)
OUT=$("$LGCR" run --net=host "$IMG" readlink /proc/self/ns/net 2>&1)
HOST_NETNS=$(echo "$OUT" | grep -E 'net:\[[0-9]+\]' | tail -1)
expect_eq "$HOST_NETNS" "$DEFAULT_NETNS" "host network matches default"

section "run --network none creates a separate network namespace"
OUT=$("$LGCR" run --network none "$IMG" readlink /proc/self/ns/net 2>&1)
NONE_NETNS=$(echo "$OUT" | grep -E 'net:\[[0-9]+\]' | tail -1)
if [ "$NONE_NETNS" != "$DEFAULT_NETNS" ] && [ -n "$NONE_NETNS" ]; then
    PASS=$((PASS + 1))
    echo "  ok  none network namespace differs"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL [${CURRENT}] none network namespace did not differ: default=$DEFAULT_NETNS none=$NONE_NETNS"
fi

section "run --net bridge configures eth0, a default route, and gateway reachability"
OUT=$("$LGCR" run --net=bridge "$IMG" sh -c "readlink /proc/self/ns/net; cat /sys/class/net/eth0/operstate; if awk '\$2 == \"00000000\" { found=1 } END { exit(found ? 0 : 1) }' /proc/net/route; then echo DEFAULT_ROUTE; fi; if ping -c 1 -W 2 10.231.0.1 >/dev/null 2>&1; then echo GATEWAY_OK; fi" 2>&1)
BRIDGE_NETNS=$(echo "$OUT" | grep -E 'net:\[[0-9]+\]' | tail -1)
if [ "$BRIDGE_NETNS" != "$DEFAULT_NETNS" ] && [ -n "$BRIDGE_NETNS" ]; then
    PASS=$((PASS + 1))
    echo "  ok  bridge network namespace differs"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL [${CURRENT}] bridge network namespace did not differ: default=$DEFAULT_NETNS bridge=$BRIDGE_NETNS"
fi
expect_contains "$OUT" "up" "bridge eth0 is up"
expect_contains "$OUT" "DEFAULT_ROUTE" "bridge default route present"
expect_contains "$OUT" "GATEWAY_OK" "bridge gateway reachable"

section "run --net bridge can reach the internet through NAT"
OUT=$("$LGCR" run --net bridge "$IMG" sh -c "wget -qO- http://example.com | grep -qi example && echo OUTBOUND_OK" 2>&1)
expect_contains "$OUT" "OUTBOUND_OK" "bridge outbound connectivity"

section "run --net bridge cleans up host veth on rm -f"
BCID=$("$LGCR" run -d --net bridge "$IMG" sleep 30 2>&1 | tail -1)
sleep 1
BHOST_IF="lgv${BCID:0:8}"
if [ "$(uname)" = "Linux" ]; then
    if ip link show "$BHOST_IF" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  ok  bridge host veth exists while container runs"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL [${CURRENT}] bridge host veth missing while container runs: $BHOST_IF"
    fi
    "$LGCR" rm -f "${BCID:0:6}" > /dev/null
    sleep 1
    if ip link show "$BHOST_IF" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "  FAIL [${CURRENT}] bridge host veth still exists after cleanup: $BHOST_IF"
    else
        PASS=$((PASS + 1))
        echo "  ok  bridge host veth removed on cleanup"
    fi
else
    "$LGCR" rm -f "${BCID:0:6}" > /dev/null
    PASS=$((PASS + 2))
    echo "  ok  skipped host veth visibility checks outside Linux"
fi

section "run --net rejects unsupported network drivers"
set +e
OUT=$("$LGCR" run --net=weird "$IMG" true 2>&1)
RC=$?
set -e
expect_eq "$RC" "1" "invalid network rc"
expect_contains "$OUT" "unsupported network: weird" "invalid network error"

section "bind mount -v exposes host directory read-write"
BIND_DIR="$TMP_BASE/.tmp-lgcr-bind-$$"
rm -rf "$BIND_DIR"
mkdir -p "$BIND_DIR"
printf "host-input\n" > "$BIND_DIR/input.txt"

section "run -w sets working directory"
OUT=$("$LGCR" run -v "$BIND_DIR:/work" -w /work "$IMG" pwd 2>&1)
expect_contains "$OUT" "/work" "workdir override applied"

if [ "$HOST_BIND_RW_EXPECTED" = "1" ]; then
    OUT=$("$LGCR" run -v "$BIND_DIR:/mnt/host" "$IMG" sh -c "cat /mnt/host/input.txt; echo container-output > /mnt/host/output.txt" 2>&1)
    expect_contains "$OUT" "host-input" "container read host file"
    expect_eq "$(cat "$BIND_DIR/output.txt")" "container-output" "container wrote host file"
else
    OUT=$("$LGCR" run -v "$BIND_DIR:/mnt/host" "$IMG" cat /mnt/host/input.txt 2>&1)
    expect_contains "$OUT" "host-input" "container read host file"
    PASS=$((PASS + 1))
    echo "  ok  skipped host bind-write assertion outside Linux"
fi

section "bind mount -v :ro rejects writes"
OUT=$("$LGCR" run -v "$BIND_DIR:/mnt/ro:ro" "$IMG" sh -c "cat /mnt/ro/input.txt; if sh -c 'echo nope > /mnt/ro/blocked.txt' 2>/dev/null; then echo WRITE_OK; else echo WRITE_FAIL; fi" 2>&1)
expect_contains "$OUT" "host-input" "readonly mount readable"
expect_contains "$OUT" "WRITE_FAIL" "readonly mount blocked write"
if [ -e "$BIND_DIR/blocked.txt" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL [${CURRENT}] readonly mount created blocked.txt"
else
    PASS=$((PASS + 1))
    echo "  ok  readonly mount did not create file"
fi

section "--mount binds a single host file"
OUT=$("$LGCR" run --mount "type=bind,src=$BIND_DIR/input.txt,dst=/mounted-file,ro" "$IMG" cat /mounted-file 2>&1)
expect_contains "$OUT" "host-input" "file bind content visible"

section "exec shares bind mount namespace"
MNTID=$("$LGCR" run -d -v "$BIND_DIR:/mnt/host" "$IMG" sleep 30 2>&1 | tail -1)
sleep 1
OUT=$("$LGCR" exec "${MNTID:0:6}" cat /mnt/host/input.txt 2>&1)
expect_contains "$OUT" "host-input" "exec read bind mount"
if [ "$HOST_BIND_RW_EXPECTED" = "1" ]; then
    "$LGCR" exec "${MNTID:0:6}" sh -c "echo exec-output > /mnt/host/exec.txt" > /dev/null
    expect_eq "$(cat "$BIND_DIR/exec.txt")" "exec-output" "exec wrote through bind mount"
else
    PASS=$((PASS + 1))
    echo "  ok  skipped exec bind-write assertion outside Linux"
fi
"$LGCR" rm -f "${MNTID:0:6}" > /dev/null

section "--read-only makes rootfs immutable but keeps tmpfs writable"
OUT=$("$LGCR" run --read-only "$IMG" sh -c "if sh -c 'echo nope > /root-blocked' 2>/dev/null; then echo ROOT_WRITE_OK; else echo ROOT_WRITE_FAIL; fi; echo tmp-ok > /tmp/t; cat /tmp/t; echo run-ok > /run/r; cat /run/r" 2>&1)
expect_contains "$OUT" "ROOT_WRITE_FAIL" "rootfs write rejected"
expect_contains "$OUT" "tmp-ok" "/tmp tmpfs writable"
expect_contains "$OUT" "run-ok" "/run tmpfs writable"

section "--read-only still allows writable bind mounts"
if [ "$HOST_BIND_RW_EXPECTED" = "1" ]; then
    OUT=$("$LGCR" run --read-only -v "$BIND_DIR:/mnt/host" "$IMG" sh -c "echo ro-root-bind > /mnt/host/readonly-root-bind.txt; cat /mnt/host/readonly-root-bind.txt" 2>&1)
    expect_contains "$OUT" "ro-root-bind" "bind mount writable under read-only rootfs"
    expect_eq "$(cat "$BIND_DIR/readonly-root-bind.txt")" "ro-root-bind" "host saw read-only-root bind write"
else
    PASS=$((PASS + 2))
    echo "  ok  skipped writable-bind assertion outside Linux"
fi

section "--tmpfs mounts writable tmpfs"
OUT=$("$LGCR" run --tmpfs /cache:size=1m,mode=1777 "$IMG" sh -c "echo cache-ok > /cache/probe; cat /cache/probe; awk '\$2 == \"/cache\" { print \$3 }' /proc/mounts" 2>&1)
expect_contains "$OUT" "cache-ok" "tmpfs writable"
expect_contains "$OUT" "tmpfs" "tmpfs appears in mount table"

section "--tmpfs composes with --read-only"
OUT=$("$LGCR" run --read-only --tmpfs /cache "$IMG" sh -c "if sh -c 'echo nope > /root-blocked-2' 2>/dev/null; then echo ROOT_WRITE_OK; else echo ROOT_WRITE_FAIL; fi; echo cache-ro-ok > /cache/probe; cat /cache/probe" 2>&1)
expect_contains "$OUT" "ROOT_WRITE_FAIL" "read-only rootfs still enforced"
expect_contains "$OUT" "cache-ro-ok" "custom tmpfs writable under read-only rootfs"

section "--tmpfs rejects unsafe destinations"
set +e
OUT=$("$LGCR" run --tmpfs relative "$IMG" true 2>&1)
RC=$?
set -e
expect_eq "$RC" "1" "invalid tmpfs rc"
expect_contains "$OUT" "tmpfs destination must be an absolute container path" "invalid tmpfs error"

rm -rf "$BIND_DIR"

section "exec runs a command inside a running container"
EXID=$("$LGCR" run -d "$IMG" sleep 120 2>&1 | tail -1)
sleep 0.5
OUT=$("$LGCR" exec "${EXID:0:6}" echo hello-exec 2>&1)
expect_contains "$OUT" "hello-exec" "exec stdout captured"

section "exec propagates non-zero exit code"
set +e
"$LGCR" exec "${EXID:0:6}" /bin/sh -c "exit 42" > /dev/null 2>&1
EC=$?
set -e
expect_eq "$EC" "42" "exec exit code"

section "exec reports signal as 128+signal"
set +e
"$LGCR" exec "${EXID:0:6}" /bin/sh -c 'kill -TERM $$' > /dev/null 2>&1
EC=$?
set -e
expect_eq "$EC" "143" "TERM = 128+15"

section "exec -e sets env inside the container"
OUT=$("$LGCR" exec -e FOO=exec-me "${EXID:0:6}" env 2>&1)
expect_contains "$OUT" "FOO=exec-me" "custom env"

section "exec --user runs as requested uid/gid"
OUT=$("$LGCR" exec --user 65534:65534 "${EXID:0:6}" sh -c 'echo uid=$(id -u) gid=$(id -g)' 2>&1)
expect_contains "$OUT" "uid=65534" "exec uid"
expect_contains "$OUT" "gid=65534" "exec gid"

section "exec sets no_new_privs on exec sessions"
OUT=$("$LGCR" exec "${EXID:0:6}" sh -c "awk '/^NoNewPrivs:/ { print \$2 }' /proc/self/status" 2>&1)
expect_contains "$OUT" "1" "NoNewPrivs=1 for exec"

section "exec honors --cap-drop"
OUT=$("$LGCR" exec --cap-drop NET_RAW "${EXID:0:6}" sh -c 'v=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [ $((0x$v & 0x2000)) -eq 0 ] && echo NO_NET_RAW' 2>&1)
expect_contains "$OUT" "NO_NET_RAW" "exec dropped NET_RAW"

section "exec honors --cap-add"
OUT=$("$LGCR" exec --cap-add NET_ADMIN "${EXID:0:6}" sh -c 'v=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [ $((0x$v & 0x1000)) -ne 0 ] && echo HAS_NET_ADMIN' 2>&1)
expect_contains "$OUT" "HAS_NET_ADMIN" "exec added NET_ADMIN"

section "exec uses seccomp by default and can opt out"
OUT=$("$LGCR" exec --cap-add SYS_ADMIN "${EXID:0:6}" sh -c 'echo SECCOMP=$(awk "/^Seccomp:/ { print \$2 }" /proc/self/status); mkdir -p /tmp/seccomp-exec; if mount -t tmpfs tmpfs /tmp/seccomp-exec 2>/dev/null; then echo MOUNT_OK; umount /tmp/seccomp-exec >/dev/null 2>&1; else echo MOUNT_BLOCKED; fi' 2>&1)
expect_contains "$OUT" "SECCOMP=2" "exec seccomp filter active"
expect_contains "$OUT" "MOUNT_BLOCKED" "exec seccomp blocks mount"
OUT=$("$LGCR" exec --cap-add SYS_ADMIN --seccomp unconfined "${EXID:0:6}" sh -c 'echo SECCOMP=$(awk "/^Seccomp:/ { print \$2 }" /proc/self/status); mkdir -p /tmp/seccomp-exec; if mount -t tmpfs tmpfs /tmp/seccomp-exec 2>/dev/null; then echo MOUNT_OK; umount /tmp/seccomp-exec >/dev/null 2>&1; else echo MOUNT_BLOCKED; fi' 2>&1)
expect_contains "$OUT" "SECCOMP=0" "exec seccomp disabled"
expect_contains "$OUT" "MOUNT_OK" "exec mount allowed without seccomp"

section "exec shares mount ns — can see primary's fs effects"
"$LGCR" exec "${EXID:0:6}" /bin/sh -c "echo marker > /tmp/from-exec" > /dev/null 2>&1
OUT=$("$LGCR" exec "${EXID:0:6}" cat /tmp/from-exec 2>&1)
expect_contains "$OUT" "marker" "second exec sees first exec's file"

section "exec -it allocates a pty (stdin is-a-tty, /dev/pts/N)"
OUT=$(pty_run "$LGCR exec -it ${EXID:0:6} /bin/sh -c \"tty; [ -t 0 ] && echo is-tty || echo not-tty\"" 2>&1)
expect_contains "$OUT" "/dev/pts/" "pty allocated"
expect_contains "$OUT" "is-tty" "stdin is a tty"

section "exec -it propagates initial winsize"
OUT=$(pty_run "stty cols 133 rows 42 2>/dev/null; $LGCR exec -it ${EXID:0:6} stty size" 2>&1)
expect_contains "$OUT" "42 133" "stty size inside container"

section "exec -it interactive shell accepts input"
OUT=$(printf "echo hello-from-pty\nexit\n" | pty_run "$LGCR exec -it ${EXID:0:6} /bin/sh" 2>&1)
expect_contains "$OUT" "hello-from-pty" "command output via stdin"

"$LGCR" rm -f "${EXID:0:6}" > /dev/null

section "run -it: interactive shell, pty, winsize"
OUT=$(printf "echo hello-run-it\nexit 7\n" | pty_run "$LGCR run -it $IMG /bin/sh" 2>&1)
expect_contains "$OUT" "hello-run-it" "shell saw stdin + produced output"

section "run -it rejects -d"
set +e
OUT=$("$LGCR" run -d -it "$IMG" /bin/sh 2>&1)
EC=$?
set -e
expect_eq "$EC" "1" "rc=1 on -d -it combo"
expect_contains "$OUT" "cannot be combined" "error mentions the combination"

section "exec on a stopped container errors"
STOPID=$("$LGCR" run -d "$IMG" true 2>&1 | tail -1)
sleep 0.5
set +e
OUT=$("$LGCR" exec "${STOPID:0:6}" echo hi 2>&1)
EC=$?
set -e
expect_eq "$EC" "1" "exec rc=1 on stopped"
expect_contains "$OUT" "not running" "error mentions not running"
"$LGCR" rm -f "${STOPID:0:6}" > /dev/null

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

section "container /etc/resolv.conf comes from the host"
HOST_RC=$(head -1 /etc/resolv.conf 2>/dev/null || echo "")
if [ -n "$HOST_RC" ]; then
    OUT=$("$LGCR" run --rm "$IMG" head -1 /etc/resolv.conf 2>&1)
    expect_contains "$OUT" "$HOST_RC" "container sees host's first resolv.conf line"
fi

section "run auto-pulls a missing image"
# Wipe hello-world from the image store via the tool (works through the
# darwin shim too, since it forwards into Lima).
"$LGCR" rmi -f hello-world > /dev/null 2>&1 || true
OUT=$("$LGCR" run --rm hello-world 2>&1)
expect_contains "$OUT" "Hello from Docker!" "scratch-image binary ran to completion"
expect_contains "$OUT" "[pull]" "pull progress emitted on cold cache"

section "scratch rootfs (no /bin/rm) does not kill init"
# Regression: sh! on /.pivot_old used to fail on scratch images and leave a
# dangling ctrl.sock. Running twice in a row exercises the post-pivot cleanup.
OUT=$("$LGCR" run --rm hello-world 2>&1)
expect_contains "$OUT" "Hello from Docker!" "second run also succeeds"
expect_not_contains "$OUT" "control socket never ready" "no stale-socket error"

section "images lists pulled images"
OUT=$("$LGCR" images 2>&1)
expect_contains "$OUT" "IMAGE" "header printed"
expect_contains "$OUT" "hello-world" "hello-world appears"
OUT=$("$LGCR" images -q 2>&1)
expect_contains "$OUT" "hello-world" "-q shows refs"
expect_not_contains "$OUT" "IMAGE" "-q omits header"

section "rmi refuses to remove an image used by a container"
CID=$("$LGCR" run -d "$IMG" sleep 30 2>&1 | tail -1)
sleep 1
OUT=$("$LGCR" rmi "$IMG" 2>&1 || true)
expect_contains "$OUT" "used by" "refuses while a container references it"
"$LGCR" rm -f "${CID:0:6}" > /dev/null

section "prune --containers removes stopped containers only"
# Start from a clean container slate — earlier tests in this file leave the
# original `CID` running (sleep 30) and its lifecycle is timing-dependent
# by the time we get here. A full rm -f'up-front makes this deterministic.
for _id in $("$LGCR" ps -aq 2>/dev/null); do
    "$LGCR" rm -f "$_id" > /dev/null 2>&1 || true
done
# Make one stopped container (run a quick command) and one running.
"$LGCR" run "$IMG" sh -c 'true' > /dev/null 2>&1
RUN_CID=$("$LGCR" run -d "$IMG" sleep 30 2>&1 | tail -1)
sleep 1
BEFORE_ALL=$("$LGCR" ps -aq | wc -l | tr -d ' ')
BEFORE_RUNNING=$("$LGCR" ps -q | wc -l | tr -d ' ')
OUT=$("$LGCR" prune --containers 2>&1)
expect_contains "$OUT" "pruned" "prune summary printed"
expect_contains "$OUT" "reclaimed" "reports reclaimed space"
AFTER_ALL=$("$LGCR" ps -aq | wc -l | tr -d ' ')
AFTER_RUNNING=$("$LGCR" ps -q | wc -l | tr -d ' ')
expect_eq "$AFTER_RUNNING" "$BEFORE_RUNNING" "running containers untouched"
# At least one stopped container was removed
if [ "$AFTER_ALL" -lt "$BEFORE_ALL" ]; then
    PASS=$((PASS + 1)); echo "  ok  stopped container count dropped"
else
    FAIL=$((FAIL + 1)); echo "  FAIL stopped not pruned: $BEFORE_ALL -> $AFTER_ALL"
fi
"$LGCR" rm -f "${RUN_CID:0:6}" > /dev/null

section "prune --images removes unused images only"
"$LGCR" pull hello-world > /dev/null 2>&1
OUT=$("$LGCR" prune --images 2>&1)
expect_contains "$OUT" "removed image" "reports each removed image"
OUT=$("$LGCR" images -q 2>&1 || true)
expect_not_contains "$OUT" "hello-world" "hello-world pruned"
# IMG is still present because we just used it above (and may be referenced
# by still-stopped containers). We don't assert on its presence — the prune
# above cleared containers, so it may or may not survive; both are fine.

section "prune (no flags) wipes both"
"$LGCR" run "$IMG" sh -c 'true' > /dev/null 2>&1
sleep 1
OUT=$("$LGCR" prune 2>&1)
expect_contains "$OUT" "pruned" "default prunes both"
sleep 1
expect_eq "$("$LGCR" ps -aq | wc -l | tr -d ' ')" "0" "no containers left"
OUT=$("$LGCR" images -q 2>&1 || true)
expect_not_contains "$OUT" "library/alpine:3.21" "prune removed alpine from image listing"
expect_not_contains "$OUT" "hello-world" "prune removed hello-world from image listing"

section "rmi removes an unused image"
"$LGCR" pull hello-world > /dev/null 2>&1
OUT=$("$LGCR" rmi hello-world 2>&1)
expect_contains "$OUT" "removed hello-world" "rmi reports success"
OUT=$("$LGCR" images -q 2>&1 || true)
expect_not_contains "$OUT" "hello-world" "image gone from listing"

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
