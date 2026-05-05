# lgcr

A small Linux container runtime written in [let-go](https://github.com/nooga/let-go)
(a Clojure-compatible language that compiles to Go bytecode).

Docker-shaped CLI — pull, run, logs, ps, stop, rm, start, inspect — with
proper namespace isolation, overlay rootfs, cgroups v2, and a PID-1 init that
forwards signals and reaps zombies. All driven by a couple of `.lg` files.

## Install

```bash
git clone https://github.com/nooga/lgcr
git clone https://github.com/nooga/let-go ../let-go      # sibling checkout
cd lgcr
./bundle.sh                                              # produces ./lgcr
```

On Linux, `bundle.sh` cross-compiles let-go and bakes `container.lg` into
a single static linux/arm64 binary (~14 MB).

On **macOS**, it builds two things:

- `./lgcr` — a tiny native darwin shim that transparently forwards every
  invocation into a [Lima](https://github.com/lima-vm/lima) VM named `letgo`
- `./lgcr.linux` — the real container runtime; sits next to the shim and is
  reached via Lima's virtiofs mount of `/Users`

You just run `./lgcr ...` on macOS and it works. The first time, bring up the VM:

```bash
brew install lima
limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2
```

If Lima isn't installed or the VM isn't running, the shim yells with the fix.

## Quickstart

```bash
# Pull an image (real OCI registry, multi-arch, token auth)
lgcr pull alpine:3.21

# Run a command
lgcr run alpine:3.21 echo hi

# Run detached; tail the logs
cid=$(lgcr run -d alpine:3.21 sh -c 'while :; do date; sleep 1; done')
lgcr logs -f "$cid"
```

## Commands

| Command | Description |
|---|---|
| `lgcr pull <image>` | Fetch an OCI image (Docker Hub or any v2 registry) |
| `lgcr images [-q]` | List pulled images (name, size, age); `-q` just refs |
| `lgcr rmi [-f] <image>...` | Remove an image; refuses if a container uses it unless `-f` |
| `lgcr run [-d\|-it] [--rm] [--read-only] [--net host\|none\|bridge] [-p HOSTPORT:CONTPORT] [--tmpfs DST[:opts]] [-e K=V] [-w DIR] [-h NAME] [-v SRC:DST[:ro]] [--mount type=bind,src=SRC,dst=DST[,ro]] <image\|rootfs> [cmd [args...]]` | Run a container; auto-pulls if the image is missing; supports host/none/bridge networking, bridge port publishing, read-only rootfs, tmpfs, and bind mounts; `-d` detach, `-it` interactive pty |
| `lgcr exec [-it] [-e K=V] [-u USER[:GROUP]] <id> <cmd> [args...]` | Run a command inside a running container; `-it` for a pty; `-u` changes uid/gid |
| `lgcr ps [-a] [-q]` | List containers; `-a` includes exited, `-q` just ids |
| `lgcr logs [-f] <id>` | Dump or tail captured stdout/stderr |
| `lgcr stop [-t SECS] <id>...` | SIGTERM, grace, SIGKILL |
| `lgcr kill [-s SIG] <id>...` | Send a signal by name (`KILL`, `TERM`, …) or number |
| `lgcr rm [-f] <id>...` | Remove; `-f` kills a running container first |
| `lgcr start <id>...` | Respawn a stopped container with the same config |
| `lgcr inspect <id>` | Dump the container's state as JSON |

Short id prefixes work everywhere — `lgcr stop a1b2` is fine if unambiguous.
Short flags combine: `lgcr ps -aq` = `lgcr ps -a -q`.

## Examples

```bash
# run -d + --rm: fire and forget
lgcr run -d --rm alpine:3.21 sh -c 'echo done > /tmp/marker; sleep 5'

# Pass env to the container (image env is preserved; your -e overrides)
lgcr run -e RUST_LOG=debug -e PORT=8080 alpine:3.21 env

# Bind-mount a host directory into the container
lgcr run -v "$PWD:/work" -w /work alpine:3.21 ls

# Read-only bind mounts work with either -v or --mount
lgcr run --mount type=bind,src="$PWD/config",dst=/config,ro alpine:3.21 cat /config/app.conf

# Make the image rootfs read-only while keeping /tmp and /run writable
lgcr run --read-only alpine:3.21 sh -c 'echo ok > /tmp/probe'

# Add an in-memory writable mount
lgcr run --tmpfs /cache:size=64m,mode=1777 alpine:3.21 sh -c 'echo ok > /cache/probe'

# Run without host network access
lgcr run --net=none alpine:3.21 ip addr

# Override hostname, or run an exec as a different user
lgcr run --hostname worker-1 alpine:3.21 hostname
lgcr exec -u 65534:65534 "$cid" id

# Stop with a custom grace period
lgcr stop -t 30 abc123

# docker-shaped ps output
lgcr ps -a
# ID            STATUS                          CREATED               COMMAND
# a1b2c3d4e5f6  Up 12 seconds                   12 seconds ago        sh -c ./app
# 9f8e7d6c5b4a  Exited (0) 2 minutes ago        3 minutes ago         echo hi

# Inspect the full lifecycle record
lgcr inspect a1b2 | jq .

# Interactive container — exit the shell to stop the container
lgcr run -it alpine:3.21 sh

# Or: long-lived primary + ad-hoc exec sessions
cid=$(lgcr run -d alpine:3.21 sleep infinity)
lgcr exec -it "$cid" sh

# Non-interactive exec: fire a command, get its exit code back
lgcr exec "$cid" sh -c 'ls /proc | head'
```

## What it does well

- **Real OCI pull** — registry client with token auth, manifest list
  resolution, streaming layer download. No `curl`, no shell-outs.
- **Image config applied** — ENTRYPOINT, CMD, ENV, WORKDIR, USER all picked up
  from the image (numeric uids or names resolved via `/etc/passwd` inside
  the rootfs).
- **Proper PID 1** — the container init process becomes PID 1 in its own PID
  namespace, reaps orphans, and forwards SIGTERM/INT/QUIT/HUP to the user
  process. No more "docker stop hangs for 10 seconds" papercut.
- **Per-container shim, no daemon** — `run -d` spawns a supervisor process
  per container. The CLI itself is stateless; you can kill your shell and
  containers keep running.
- **Exec + interactive pty** — each container's PID 1 exposes a unix control
  socket; `exec` sends requests with stdio fds via `SCM_RIGHTS`. `-it`
  allocates a pty on the host and wires in raw-mode input, output, and
  `SIGWINCH` resize.
- **Rootless-friendly state** — state lives in
  `$XDG_STATE_HOME/lgcr/containers/<id>/` so you don't need `/var/lib`
  root-owned directories.
- **Accurate exit info** — `state.json` distinguishes a 0 exit from a
  signal-killed 0 exit (yes, those are different): `:exit-code`, `:signal`,
  `:status`.

## What it doesn't do yet

See [ROADMAP.md](./ROADMAP.md) for the plan. Short version:

- Bridge port publishing is implemented for `--net bridge` via `-p HOSTPORT:CONTPORT`, including reachability via both the host address and `127.0.0.1` (M5)
- No rootless user namespaces (M4)
- No default AppArmor / SELinux labeling yet; `--apparmor PROFILE` is supported, but host-default labeling is still deferred (M4)
- No image build (M7 — a Lisp-macro DSL called `defcontainer` is planned)
- The image store is now content-addressable (`blobs/`, `refs/`, `images/`,
  `snapshots/`) with image GC and layer-chain-keyed snapshots, but it is
  still a pragmatic first cut: signature verification is still deferred,
  while partial blob download resume and local integrity checks now happen
  automatically on pull / image resolve (M8)

## Testing

```bash
./tests/run.sh         # bundle + unit + e2e (×2 on macOS) + shim-only checks
```

- **Unit** (`tests/lib_test.lg`) — pure helpers in `lib.lg` via let-go's
  built-in `test` ns.
- **E2E** (`tests/e2e.sh`) — drives the real lgcr binary against a real
  kernel: run/ps/logs/stop/kill/rm/start/inspect/exec, image-ref
  resolution, env overrides, prefix-id ambiguity, signal propagation,
  `-it` pty (winsize + interactive shell). On macOS the same suite runs
  twice — once inside Lima against `lgcr.linux`, once from the host
  against the darwin shim — proving both paths produce identical output.
- **Shim** (`tests/e2e-shim.sh`) — darwin-only: error messages when
  Lima/lgcr.linux are missing, output-parity vs direct linux invocation,
  exit-code and signal round-tripping through the shim.

## How it works, briefly

See **[IMPLEMENTATION.md](./IMPLEMENTATION.md)** for the full walkthrough. The
very-short version:

1. `pull` hits the registry, downloads + extracts layers, saves a reduced
   config alongside the rootfs.
2. `run -d` writes initial state, spawns `lgcr shim <id>` detached.
3. The shim sets up an overlay rootfs + cgroup, then spawns `lgcr init <id>`
   with `CLONE_NEW{NS,PID,UTS,IPC}` via `syscall/spawn-async`.
4. `init` is now PID 1 in the new PID ns. It pivot-roots into the overlay,
   drops to the image's USER, spawns the user command as a child, and runs
   forever as reaper + signal forwarder.
5. When the user process exits, init exits with `128 + signal` or the raw
   exit status; shim reaps, records the final state, and exits.
6. `lgcr stop` sends SIGTERM to init's pid; init forwards to the user
   process through an `async/chan` wired via `syscall/signal-notify`.

## License

MIT
