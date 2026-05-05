# lgcr

`lgcr` is a small, daemonless Linux container runtime written in
[let-go](https://github.com/nooga/let-go), a Clojure dialect that compiles to
bytecode for a Go VM.

It has a Docker-shaped CLI, but it is not a Docker clone. On Linux it bundles
to one executable. On macOS, `./lgcr` is a tiny native forwarder into a Lima VM
named `letgo`, so the same command works without wrapping everything in
`limactl shell`.

The fun part is the size/shape of it: about 3k real LOC for the runtime,
content-addressable image store, networking, pure helper library, macOS
forwarder, and build script. In that space it does real OCI pulls, namespaces,
cgroups, overlay rootfs, PID 1 signal/reaper work, exec over a control socket,
interactive ptys, bind mounts, tmpfs, capabilities, seccomp, bridge NAT, port
publishing, image GC, and startup reconciliation.

So, yes, it is tiny and lispy. Most of the runtime state is just maps and
vectors, most parsing/formatting lives in pure tested helpers, and the nasty
bits stay at the syscall boundary.

## Current status

This is past toy-runtime territory, but it is not trying to be Docker.

What works:

- **OCI pull**: Docker Hub and v2 registries, token auth, manifest-list
  selection, config blobs, streaming layer downloads.
- **Content-addressable image store**: blobs, refs, manifests, snapshots,
  repeated-pull reuse, image GC, partial blob resume, and integrity repair.
- **Run lifecycle**: foreground, detached, `--rm`, restart stopped containers,
  short-id lookup with ambiguity checks.
- **Real init**: PID 1 inside the container namespace, signal forwarding,
  orphan reaping, signal-aware exit status.
- **Exec**: commands run through the container's existing init over a Unix
  control socket with fd passing; no CGO `setns` trickery.
- **Interactive ptys**: `run -it` and `exec -it`, raw-mode input, window-size
  propagation.
- **Filesystem controls**: overlay rootfs, bind mounts, read-only binds,
  tmpfs mounts, read-only rootfs with writable `/tmp` and `/run`.
- **Networking**: `--net host`, `--net none`, and bridge networking with NAT
  egress plus TCP port publishing via `-p HOSTPORT:CONTPORT`.
- **Security basics**: default capability set, `--cap-add`, `--cap-drop`,
  `no_new_privs`, default seccomp filter, optional unconfined seccomp, curated
  `/dev`, and explicit AppArmor profile support.
- **macOS workflow**: `./lgcr` is a native shim that forwards into a Lima VM,
  so the Linux runtime can be driven from macOS without typing `limactl`.

What is intentionally still open:

- rootless user namespaces
- image build
- signature verification
- daemonized lifecycle event API / restart policy
- broader Docker compatibility
- Kubernetes CRI integration, probably never

See [ROADMAP.md](./ROADMAP.md) for the messier truth.

## Install

`lgcr` expects a sibling checkout of let-go:

```bash
git clone https://github.com/nooga/let-go
git clone https://github.com/nooga/lgcr
cd lgcr
./bundle.sh
```

On Linux, `bundle.sh` produces `./lgcr`, a standalone linux/arm64 binary with
the let-go VM and compiled `cli.lg` bytecode embedded.

On macOS, `bundle.sh` produces two binaries:

- `./lgcr.linux` - the real Linux container runtime
- `./lgcr` - a native Darwin shim that forwards commands into a Lima VM named
  `letgo`

Bring up the VM once:

```bash
brew install lima
limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2
```

Then use `./lgcr ...` normally from macOS. The shim handles the Lima hop and
preserves output, exit codes, and signals.

## Quickstart

```bash
# Pull an image.
./lgcr pull alpine:3.21

# Run a foreground command.
./lgcr run alpine:3.21 echo "hello from a lisp container runtime"

# Run detached and follow logs.
cid=$(./lgcr run -d alpine:3.21 sh -c 'while :; do date; sleep 1; done')
./lgcr logs -f "$cid"

# Exec into the running container.
./lgcr exec -it "$cid" sh

# Stop and remove it.
./lgcr stop "$cid"
./lgcr rm "$cid"
```

## Commands

| Command | Description |
|---|---|
| `lgcr pull <image>` | Fetch an OCI image into the local CAS-backed image store |
| `lgcr images [-q] [--json]` | List pulled image refs, sizes, ages, digests, and snapshots |
| `lgcr rmi [-f] <image>...` | Remove image refs and GC unused blobs/snapshots |
| `lgcr run ...` | Run a container from an image ref or absolute rootfs path |
| `lgcr exec ...` | Run a process inside a running container |
| `lgcr ps [-a] [-q] [--json]` | List containers |
| `lgcr logs [-f] <id>` | Dump or follow captured detached logs |
| `lgcr stop [-t SECS] <id>...` | Send SIGTERM, wait, then SIGKILL |
| `lgcr kill [-s SIG] <id>...` | Send a signal by name or number |
| `lgcr rm [-f] <id>...` | Remove stopped containers, or kill first with `-f` |
| `lgcr start <id>...` | Restart stopped containers with their saved config |
| `lgcr inspect <id>` | Print the raw lifecycle state JSON |
| `lgcr df [--json]` | Show local CAS and container-state disk usage |
| `lgcr prune [--containers] [--images]` | Remove stopped containers and/or unused images |
| `lgcr help [command]` | Show help |

The big usage shapes:

```bash
lgcr run [-d|-it] [--rm] [--read-only] [--net host|none|bridge] \
  [-p HOSTPORT:CONTPORT]... [--tmpfs DST[:opts]] \
  [--seccomp default|unconfined] [--apparmor PROFILE|unconfined] \
  [--cap-add CAP] [--cap-drop CAP] [-e K=V]... [-w DIR] [-h NAME] \
  [-v SRC:DST[:ro]] [--mount type=bind,src=SRC,dst=DST[,ro]] \
  <image-or-rootfs> [command [args...]]

lgcr exec [-it] [--seccomp default|unconfined] \
  [--apparmor PROFILE|unconfined] [--cap-add CAP] [--cap-drop CAP] \
  [-e K=V]... [-u USER[:GROUP]] <id> <cmd> [args...]
```

Short id prefixes work wherever an id is accepted. The minimum prefix length
is two characters, and ambiguous prefixes are rejected.

Combined short flags work too:

```bash
./lgcr ps -aq
```

## Examples

```bash
# Run with image ENTRYPOINT/CMD and ENV applied.
./lgcr run alpine:3.21 env

# Override env and working directory.
./lgcr run -e RUST_LOG=debug -v "$PWD:/work" -w /work alpine:3.21 ls

# Make the image rootfs read-only, but keep /tmp and /run writable.
./lgcr run --read-only alpine:3.21 sh -c 'echo ok > /tmp/probe'

# Add a custom writable tmpfs.
./lgcr run --tmpfs /cache:size=64m,mode=1777 alpine:3.21 sh -c 'echo ok > /cache/probe'

# Bind a file read-only.
./lgcr run --mount type=bind,src="$PWD/config.toml",dst=/config.toml,ro alpine:3.21 cat /config.toml

# Use an isolated bridge network and publish a TCP port.
./lgcr run -d --net bridge -p 8080:80 alpine:3.21 \
  sh -c 'apk add --no-cache busybox-extras && httpd -f -p 80'

# Run with a tighter capability set.
./lgcr run --cap-drop NET_RAW alpine:3.21 sh -c 'grep CapEff /proc/self/status'

# Disable the default seccomp profile for one process.
./lgcr run --seccomp unconfined --cap-add SYS_ADMIN alpine:3.21 sh

# Start a long-lived primary, then run ad-hoc commands inside it.
cid=$(./lgcr run -d alpine:3.21 sleep infinity)
./lgcr exec "$cid" sh -c 'echo marker > /tmp/from-exec'
./lgcr exec -it "$cid" sh

# Clean local state.
./lgcr prune
./lgcr df
```

## How it works

The full tour is in [IMPLEMENTATION.md](./IMPLEMENTATION.md). Short version:

```text
macOS host, if you are on macOS
┌─────────────────────────────────────────────────────────────────────┐
│ ./lgcr                                                              │
│   tiny Darwin wrapper; forwards argv/stdin/stdout/stderr/signals    │
│   into the Lima VM named "letgo"                                     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
Linux host, or the Lima VM on macOS
┌─────────────────────────────────────────────────────────────────────┐
│ ./lgcr.linux / ./lgcr                                               │
│                                                                     │
│  CLI process                                                        │
│    pull, run, exec, ps, logs, stop, rm                              │
│    reads/writes state.json and the CAS image store                  │
│                                                                     │
│  per-container shim                                                 │
│    outside the container namespaces                                 │
│    owns overlay setup, cgroups, bridge/net cleanup, logs, state     │
│                                                                     │
│  $XDG_STATE_HOME/lgcr/containers/<id>/                              │
│    state.json, stdout.log, stderr.log, ctrl.sock                    │
│                                                                     │
│  $XDG_DATA_HOME/lgcr/images/                                        │
│    blobs, refs, manifests, snapshots                                │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ clone + namespaces
                                ▼
Inside the container
┌─────────────────────────────────────────────────────────────────────┐
│ lgcr init                                                           │
│   PID 1 in the container PID namespace                              │
│   pivot_root into the overlay rootfs                                │
│   listens on ctrl.sock for primary/exec requests                    │
│   forwards signals and reaps children                               │
│                                                                     │
│ user process / exec processes                                       │
│   run with requested env, cwd, uid/gid, caps, seccomp, stdio fds    │
└─────────────────────────────────────────────────────────────────────┘
```

1. `pull` resolves the image ref, fetches the manifest/config/layers, verifies
   digests, stores blobs by sha256, and materializes a rootfs snapshot.
2. `run` resolves image config, composes ENTRYPOINT/CMD/env/workdir/user,
   writes `state.json`, and either starts a foreground flow or spawns a
   detached per-container shim.
3. The shim stays outside the container namespaces. It owns the overlay mount,
   cgroup, logs, network cleanup, and final state update.
4. The shim starts `lgcr init <id>` with `CLONE_NEW{NS,PID,UTS,IPC}` and,
   for bridge/none modes, `CLONE_NEWNET`. That process becomes PID 1 in the
   container PID namespace.
5. Init prepares `/proc`, `/sys`, `/dev`, tmpfs, binds, read-only remounts,
   `pivot_root`s into the merged rootfs, opens a Unix control socket, then
   waits for a primary process request.
6. Foreground `run`, detached shim, and `exec` all send process requests to
   init over that socket, passing stdio fds with `SCM_RIGHTS`.
7. Init applies uid/gid, cwd, env, capabilities, AppArmor, `no_new_privs`, and
   seccomp at the exec boundary. It also reaps children and forwards signals.
8. When the primary exits, init exits. The shim records `exited` or `killed`
   with both `exit-code` and `signal`, then tears down runtime state.

The design keeps the CLI mostly stateless. Persistent truth lives on disk under
`$XDG_STATE_HOME/lgcr/containers`, while images live under
`$XDG_DATA_HOME/lgcr/images`.

## License

MIT
