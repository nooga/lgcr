# lgcr Development Guide

## Overview

lgcr is a container runtime written in let-go (Clojure dialect → Go bytecode).
The main source is `container.lg`. It depends on let-go's `syscall` namespace
(added in the let-go repo at `pkg/rt/syscall_linux.go` / `syscall_other.go`).

## Build & Test

```bash
# Build let-go with syscall support (from the let-go repo)
cd ../let-go
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o ../lgcr/letgo-linux .

# Test in Lima VM (must be running: limactl start letgo)
limactl shell letgo sudo /path/to/letgo-linux /path/to/container.lg pull alpine:3.21
limactl shell letgo sudo /path/to/letgo-linux /path/to/container.lg run /tmp/letgo-rootfs/library_alpine-3.21 echo hello
```

## Lima VM

The test VM is named `letgo`, created with:
```bash
limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2
```

It mounts the macOS filesystem read-write, so no file copying needed. Run commands via:
```bash
limactl shell letgo sudo <command>
```

## Project Structure

- `container.lg` — the container runtime (pull, run, init)
- `test-container.sh` — end-to-end test script (uses Lima)
- `test-syscall.lg` — syscall namespace smoke test
- `test-in-podman.sh` — alternative test via podman (overlay won't work, uses cp fallback)

## Key Design Decisions

- **Two-phase run**: host side prepares overlay + cgroups, then re-execs itself inside
  new namespaces via `unshare(1)`. The `init` subcommand runs inside the namespaces.
  Future: replace `unshare(1)` shell-out with `syscall/spawn` + clone flags.
- **Overlay with cp fallback**: overlay mount fails in nested containers (podman),
  so we fall back to `cp -a`. On bare Linux (Lima) overlay works.
- **OCI pull**: real registry client with token auth, manifest list resolution,
  streaming layer download. No `wget` or `curl` — pure let-go `http/get` + `json/read-json`.

## Known Issues

- The let-go reader tries to interpret remaining CLI args as files after the script
  finishes, causing harmless "open X: no such file" errors.
- `os/args` parsing: `(drop 2 os/args)` skips the binary and script path.
- `bit-or` only takes 2 args — nest calls for multiple flags.
- `try/catch` syntax is `(catch e ...)` not `(catch Exception e ...)`.
- No `clojure.string` — use `string` namespace (e.g., `string/split`, `string/trim`).
- No `Integer/parseInt` — use `parse-int`.

## let-go Syscall Namespace

The syscall ns lives in the let-go repo:
- `pkg/rt/syscall_linux.go` — real Linux implementations
- `pkg/rt/syscall_other.go` — stubs for non-Linux (errors or cross-platform impls)
- `pkg/rt/types.go` — WaitResult, UnameResult, SpawnResult struct mappings

Cross-platform functions (work on all OS): `getpid`, `getuid`, `getgid`,
`read-file`, `write-file`, `mkdir-p`, `rm-rf`, `rm`, `symlink`, `chmod`.

Linux-only: `clone`, `unshare`, `mount`, `umount`, `pivot-root`, `chroot`,
`chdir`, `mkdir`, `rmdir`, `sethostname`, `exec`, `spawn`, `uname`,
`setuid`, `setgid`, `waitpid`.
