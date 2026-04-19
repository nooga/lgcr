# lgcr Development Guide

## Overview

lgcr is a container runtime written in let-go (Clojure dialect → Go bytecode).

- `container.lg` — runtime (pull, run, shim, init, ps, logs, stop, kill, rm, start, inspect)
- `lib.lg` — pure helpers (no filesystem / syscall / env access) used by container.lg and unit tests
- Depends on let-go's `syscall` namespace (`../let-go/pkg/rt/syscall_linux.go`)

## Build

```bash
./bundle.sh              # builds host + linux lg, cross-bundles to ./lgcr
```

`bundle.sh` produces `./lgcr`, a standalone Linux arm64 binary with the let-go
VM + compiled container.lg bytecode embedded. `.lg-host` (host build) and
`.lg-linux` (target) are side artifacts used for bundling and unit tests.

## Testing — **required for every new feature**

Any new feature, subcommand, or helper **must** come with test coverage in the
same patch. No exceptions. Two suites:

### Unit tests — `tests/lib_test.lg`

Pure helpers in `lib.lg` are tested here using let-go's built-in `test` ns
(`deftest`, `is`, `testing`). Add new tests next to the existing ones — one
`deftest` per function, covering the happy path and edge cases.

```clojure
(deftest new-function-description
  (is (= expected (lib/new-function input))))
```

Run them standalone on the host (fast, no Lima):
```bash
./.lg-host tests/lib_test.lg
```

### E2E tests — `tests/e2e.sh`

New subcommands and behaviors that touch the real runtime go here. The script
runs inside Lima against the actual `./lgcr` binary. Use the provided helpers:

```bash
section "my-new-feature behaves correctly"
OUT=$("$LGCR" my-new-command "$IMG" args 2>&1)
expect_contains "$OUT" "expected string" "description"
expect_eq "$(json_field "$STATE_FILE" some-field)" "some-value"
```

### Running the whole suite

```bash
./tests/run.sh           # bundle + unit tests on host + e2e in Lima
```

This is the gate — run it before committing anything non-trivial. All tests
must pass.

### When to put something in lib.lg vs container.lg

- **lib.lg**: string/collection manipulation, parsing, formatting, anything
  that takes values in and returns values out. No `os/*`, `syscall/*`, `slurp`,
  `spit`, `sh!`, or state reads.
- **container.lg**: everything that touches the filesystem, spawns processes,
  reads env, or manipulates the state store.

If a function in container.lg starts growing a lot of pure logic, extract the
pure part into lib.lg and add a unit test.

## Lima VM

The test VM is named `letgo`. If not present:
```bash
limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2
```

Mounts the macOS filesystem read-write. Run commands via:
```bash
limactl shell letgo sudo <command>
```

## Project Structure

- `container.lg` — runtime
- `lib.lg` — pure helpers
- `bundle.sh` — cross-bundle host → linux/arm64
- `tests/lib_test.lg` — unit tests (pure helpers)
- `tests/e2e.sh` — e2e tests (real binary in Lima)
- `tests/run.sh` — top-level runner
- `ROADMAP.md` — milestones + completion status

## Key Design Decisions

- **Two-phase run**: host side prepares overlay + cgroups, then spawns
  `lgcr init <id>` with CLONE_NEW{NS,PID,UTS,IPC} via `syscall/spawn-async`.
  The init becomes PID 1 in the new PID namespace; it spawns the user
  command and stays alive as reaper + signal forwarder.
- **Per-container shim**: `run -d` spawns `lgcr shim <id>` detached
  (Setsid'd). Shim owns the container's lifecycle: does rootfs + cgroup
  setup, launches init, waitpids it, writes final state. No daemon.
- **Overlay with cp fallback**: overlay mount fails in nested containers
  (podman), so we fall back to `cp -a`. On bare Linux (Lima) overlay works.
- **OCI pull**: real registry client with token auth, manifest list
  resolution, streaming layer download. Saves reduced image config to
  `.lgcr-config.json` next to the rootfs.
- **State dir**: `$XDG_STATE_HOME/lgcr` (rootless-friendly). 32-char hex ids;
  min-2-char prefix match; ambiguity detection.

## Known Issues / Gotchas

- `os/args` parsing: bundled = `[binary subcmd ...]`, script = `[binary script.lg subcmd ...]`.
- `bit-or` only takes 2 args — nest calls for multiple flags.
- `try/catch` syntax is `(catch e ...)` not `(catch Exception e ...)`.
- No `clojure.string` — use `string` namespace (`string/split`, `string/trim`).
- No `Integer/parseInt` — use `parse-int`.
- let-go's `async` ns refers its publics unqualified: its `map`/`into`/
  `reduce`/`take`/`merge` shadow core. Don't `(:require [async])` in a ns
  that uses those names unqualified. Prefer `loop`/`recur` or `reduce` with
  explicit seeds for collection work in container.lg.
- `read-bytes` returns a `vm.String` of raw bytes — iterating with `map int`
  will decode UTF-8 and eat high-bit bytes. Use byte-level ops only when
  needed, otherwise pick a safer primitive (`rand-int` etc).

## let-go Syscall Namespace

Lives in `../let-go/pkg/rt/`:
- `syscall_linux.go` — real Linux implementations
- `syscall_other.go` — cross-platform impls or error stubs
- `types.go` — WaitResult, UnameResult, SpawnResult struct mappings

**Cross-platform** (any OS): `getpid`, `getuid`, `getgid`, `read-file`,
`write-file`, `mkdir-p`, `rm-rf`, `rm`, `symlink`, `chmod`.

**Linux-only**: `clone`, `unshare`, `mount`, `umount`, `pivot-root`, `chroot`,
`chdir`, `mkdir`, `rmdir`, `sethostname`, `exec`, `spawn`, `spawn-async`,
`pipe`, `kill`, `signal-notify`, `uname`, `setuid`, `setgid`, `waitpid`.

**Signal constants**: `SIGHUP SIGINT SIGQUIT SIGKILL SIGTERM SIGCHLD SIGWINCH`.

**Clone flags**: `CLONE_NEWNS NEWUTS NEWIPC NEWPID NEWNET NEWUSER`.

**`spawn-async`** is the modern primitive: non-blocking, takes IOHandle stdio
slots (nil → /dev/null, IOHandle → that fd, `*out*`/`*err*` → inherit), plus
cloneflags. Returns `{:pid}`. Always Setsid's the child so it survives the
parent's session teardown.

**`WaitResult` has `:signal`** — the terminating signal number when the child
was signal-killed (0 otherwise). Distinguishes exit 137 from SIGKILL.
