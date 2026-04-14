# lgcr — let-go container runtime

A minimal Linux container runtime written in [let-go](https://github.com/nooga/let-go) (a Clojure-compatible language that compiles to Go bytecode).

## What it does

- **Pulls OCI images** from Docker Hub and other registries (token auth, manifest list resolution, multi-arch)
- **Runs containers** with proper Linux namespace isolation (PID, mount, UTS, IPC)
- **Overlay filesystem** with pivot_root for copy-on-write container layers
- **Cgroups v2** resource limits (memory, CPU, PIDs)

All in ~300 lines of Clojure.

## Requirements

- [let-go](https://github.com/nooga/let-go) v1.4.0+ (needs the `syscall` namespace)
- Linux (runs in a VM on macOS — see Testing below)
- Root privileges (for namespace and mount operations)

## Usage

```bash
# Pull an image from Docker Hub
let-go container.lg pull alpine:3.21

# Run a command in a container
let-go container.lg run /tmp/letgo-rootfs/library_alpine-3.21 echo "hello"

# Run with any command
let-go container.lg run /tmp/letgo-rootfs/library_alpine-3.21 cat /etc/os-release
let-go container.lg run /tmp/letgo-rootfs/library_alpine-3.21 ls /
```

## How it works

### Pull

1. Parses image reference (e.g., `alpine:3.21` -> `registry-1.docker.io/library/alpine:3.21`)
2. Gets a Bearer token from Docker Hub's auth endpoint
3. Fetches the manifest list, picks the platform-specific manifest (arm64/amd64)
4. Downloads each layer blob via streaming HTTP
5. Extracts layers in order to build the rootfs

### Run

Two-phase execution:

**Phase 1 (host):** Prepares overlay filesystem over the base rootfs, sets up cgroups if configured, then re-executes itself inside new namespaces using `syscall/spawn` with clone flags.

**Phase 2 (container init):** Makes the mount tree private, bind-mounts the rootfs, mounts `/proc`, `/sys`, `/dev`, calls `pivot_root` to switch the root filesystem, sets the hostname, then `exec`s the target command.

### What let-go brings

- **Data literals as container specs** — images and configs are just maps
- **Macros for DSLs** — Dockerfile-like syntax that compiles to layer operations
- **Persistent data structures** — HAMT maps for layer management
- **REPL** — debug containers interactively
- **AOT compilation** — compile to a single static binary (~10MB, boots in 7ms)

## Testing

### With Lima (recommended)

```bash
# Install lima
brew install lima

# Create a VM
limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2

# Build and test
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o letgo-linux github.com/nooga/let-go
limactl shell letgo sudo ./letgo-linux container.lg pull alpine:3.21
limactl shell letgo sudo ./letgo-linux container.lg run /tmp/letgo-rootfs/library_alpine-3.21 echo hello
```

### With Podman

```bash
./test-in-podman.sh
```

Overlay mounts won't work inside podman (falls back to cp), but namespace isolation works with `--privileged`.

## Architecture

```
container.lg
  |
  |-- pull: OCI registry client (http/get + json/read-json)
  |     |-- auth token negotiation
  |     |-- manifest list / platform resolution
  |     |-- streaming layer download (io/copy)
  |     '-- layer extraction (tar)
  |
  |-- run (host side):
  |     |-- overlay mount (lowerdir=rootfs, upperdir=fresh)
  |     |-- cgroups v2 setup (memory.max, cpu.max, pids.max)
  |     '-- spawn child with CLONE_NEW{PID,NS,UTS,IPC}
  |
  '-- init (container side):
        |-- make mount tree private
        |-- mount /proc, /sys, /dev
        |-- pivot_root + unmount old root
        |-- sethostname
        '-- exec target command
```

## Syscall namespace

The container runtime uses let-go's `syscall` namespace which provides:

| Function | Description |
|---|---|
| `clone`, `unshare` | Linux namespace creation |
| `spawn` | Fork+exec with clone flags (captures stdout/stderr) |
| `mount`, `umount` | Filesystem mounting |
| `pivot-root` | Switch root filesystem |
| `chroot`, `chdir` | Directory operations |
| `mkdir`, `mkdir-p` | Create directories |
| `rm`, `rm-rf`, `rmdir` | Remove files/directories |
| `symlink`, `chmod` | Filesystem operations |
| `sethostname` | UTS namespace hostname |
| `exec` | Replace current process |
| `getpid`, `getuid`, `getgid` | Process info |
| `setuid`, `setgid` | Change credentials |
| `waitpid` | Wait for child process |
| `uname` | System information |
| `read-file`, `write-file` | File I/O (for /proc, /sys/fs/cgroup) |

Plus constants: `CLONE_NEW{NS,UTS,IPC,PID,NET,USER}`, `MS_{BIND,REC,PRIVATE,RDONLY,...}`, `WNOHANG`.

## Roadmap

- [ ] **Replace remaining shell-outs** — use `syscall/spawn` instead of `unshare(1)`, native tar extraction
- [ ] **Image build DSL** — Dockerfile-like macros that compile to layer operations
- [ ] **Networking** — veth pairs, bridge, NAT via iptables
- [ ] **Port mapping** — `-p 8080:80` style port forwarding
- [ ] **Layer caching** — store layers by sha256 digest, skip re-downloads
- [ ] **Seccomp** — BPF syscall filter, compiled from Clojure DSL
- [ ] **Volume mounts** — bind-mount host directories into containers
- [ ] **Detach mode** — run containers in the background
- [ ] **OCI image export** — produce standard OCI tarballs importable by docker/podman

## License

MIT
