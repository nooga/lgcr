# lgcr roadmap

Where lgcr is going, loosely ordered. Each milestone is a coherent stopping
point — the tool is more useful after each one than before.

## Test suite

`./tests/run.sh` does the full bundle + unit + e2e loop.

- **Unit** (`tests/lib_test.lg`): covers pure helpers in `lib.lg` using let-go's
  `test` ns. 27 tests / 70+ assertions. Runs on the host with the host-built
  `lg`.
- **E2E** (`tests/e2e.sh`): exercises the real `lgcr` binary inside the Lima
  VM. Covers foreground run, detached shim, logs, ps (flags + combined short
  flags), stop/kill (signal forwarding + propagated status), rm (refusal +
  force), start (respawn), inspect, image-ref run with env/workdir, and
  prefix-id ambiguity.

New pure helpers go in `lib.lg` so they're testable in isolation —
`container.lg` only holds things that touch filesystem / processes / env.

## Current state

- `pull`: real OCI registry client (manifest list resolution, token auth, streaming layer download)
- `run`: overlay rootfs + namespaces (mnt/pid/uts/ipc) + cgroups v2 limits
- Namespace re-exec via `syscall/spawn-async` with cloneflags (no `unshare(1)` dependency)
- Cross-OS bundle from macOS host → single static Linux binary

Essentially: you can `pull` an image and `run` one foreground command. That's it.

## M1 — container lifecycle

The single biggest jump. Today `run` blocks the terminal and there's no way to
list, stop, or reattach. After M1, lgcr feels like a runtime instead of a demo.

**M1.1 — done** (commits `5b2061b` lgcr / `3054876` let-go):
- XDG-rooted state dir (`$XDG_STATE_HOME/lgcr/containers/<id>/`)
- `run -d [--rm]` with per-container shim (no daemon)
- `logs [-f] <id-prefix>` with min-2-char prefix match + ambiguity error
- state.json with full lifecycle: created → running → exited/killed
- let-go: `syscall/spawn-async` + `pipe` + `kill` + signal constants,
  `Setsid` on spawned children so they survive parent session teardown

**M1.2 — done**:
- `ps`, `stop`, `kill`, `rm`, `inspect`, `start`
- Prefix-id resolution (min 2 chars, ambiguity check)
- `effective-status` catches stale "running" entries (shim-died detection)

**M1.3 — done**:
- let-go: `syscall/signal-notify` delivers signals onto an `async/chan`
- let-go: `WaitResult` gains `:signal`; distinguishes clean exit from signal-death
- Container `init` is now PID 1 in the namespace: spawns user command as
  child, `waitpid(-1)` loop reaps orphans, `async/go` forwarder relays
  SIGTERM/INT/QUIT/HUP to the user process
- Shim propagates `:signal` into state.json; status is `killed` when signal-died
- Verified: SIGTERM forwarding (trap → clean exit), orphan reaping, SIGKILL
  semantics (signal=9, status=killed)

**M1.x polish — done**:
- Combined short flags (`-aq`) are split before flag parsing
- ps renders docker-style "Up 5 seconds" / "Exited (0) 1 minute ago" /
  "Killed (signal N) N ago"; CREATED column is relative
- Epoch timestamps recorded alongside ISO strings in state.json

## M2 — OCI image config — done

- `pull` fetches the manifest's config blob and writes a reduced
  `.lgcr-config.json` (entrypoint/cmd/env/workdir/user) into the rootfs dir
- `run` accepts an image ref (`alpine:3.21`) or an absolute rootfs path;
  image ref resolves to rootfs + config
- Command composition: user cmd overrides CMD but keeps ENTRYPOINT; with no
  user cmd, `ENTRYPOINT + CMD` is used
- ENV merges (image defaults, then user-provided `-e K=V`, then lgcr-supplied
  HOSTNAME/HOME/TERM); ensures a PATH default
- WORKDIR: `chdir` inside the namespace before spawn
- USER (M2.1): `user[:group]` parsed from image config; numeric uids used
  directly, names resolved via `/etc/passwd`/`/etc/group` inside the rootfs
  after pivot-root; `syscall/setgid`+`setuid` before spawning the user cmd
- `init` subcommand refactored: takes `<id>` and reads state.json (cleaner
  than passing 5 positionals)

## M3 — exec & TTY

- `exec <id> <cmd>` via `setns(2)` into the running container's existing
  namespaces
- Interactive `run -it` / `exec -it` — needs a pty primitive:
  - `syscall/open-pty` → `[master slave]` IOHandles
  - `syscall/ioctl-winsz` for resize
  - SIGWINCH forwarding handled lisp-side with `async/go`
- Without exec, debugging a running container means reading logs and guessing.

## M4 — security & isolation

Not optional long-term. A "container" that shares the host kernel without any
of the defense-in-depth layers is a namespace trick, not isolation.

- **Capabilities drop**: default to the Docker/containerd default set; expose
  `--cap-add` / `--cap-drop`. Needs `prctl(PR_CAPBSET_DROP)` + `capset(2)` on
  the init side — add to `syscall/`.
- **`no_new_privs`**: `prctl(PR_SET_NO_NEW_PRIVS)` before exec. Prevents the
  container command from gaining privileges via setuid binaries. Trivial to
  implement, big win.
- **Seccomp**: BPF-based syscall filtering. Default profile (the
  Docker/containerd default is ~40 syscalls blocked) loaded via
  `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)`. Needs a BPF program
  representation; simplest is a fixed compiled default + user-supplied JSON
  profile later.
- **Read-only rootfs**: `--read-only` flag; mount merged rootfs MS_RDONLY plus
  a tmpfs for `/tmp`. Helps both security and immutability semantics.
- **Rootless mode**: user namespaces with uid_map/gid_map. Lets non-root users
  run containers. Requires significant work: subuid/subgid parsing, userns
  cloneflag, newuidmap/newgidmap helpers (or direct `/proc/.../uid_map` writes).
- **AppArmor / SELinux labels**: apply a default profile when the host has one
  loaded. Probably deferred until real deployment demand.
- Minor but worth it: `/dev` should be a curated tmpfs with only
  null/zero/full/random/urandom/tty/ptmx (currently we bind-mount host /dev,
  which leaks device access).

## M5 — networking

The biggest optional chunk. Order of increasing cost:

- `--net=host`: skip CLONE_NEWNET. Trivial.
- `--net=none`: CLONE_NEWNET + don't configure anything. Cheap, useful for
  build/isolation workloads.
- Bridge networking: veth pair, host-side bridge, NAT, basic DHCP or static
  IPAM, `-p` port forwarding via iptables/nftables rules. Real work.
- Defer until actual use cases drive the direction — "every container needs
  its own IP" and "containers just need the internet" want different designs.

## M6 — agent / control plane (the thing you mentioned)

lgcr as a supervisable runtime, not just a CLI. The design idea:

- **Long-running lgcr daemon** exposing an API (Unix socket; HTTP+JSON or a
  simple length-prefixed binary protocol). The same binary serves as both CLI
  (that talks to the daemon) and the daemon itself — `lgcr daemon` starts it.
- **Lifecycle events**: subscribe to a stream of
  `{:kind :container.started|exited|oom-killed|stopped, :id ..., :ts ...}`
  events. Implemented by the daemon watching waitpid + cgroup events
  (`cgroup.events` pressure/oom notifications via inotify).
- **Stats subscriptions**: periodic `{:id :cpu :mem :pids :io}` samples from
  cgroup v2 files (`cpu.stat`, `memory.current`, `pids.current`, `io.stat`).
  Client picks poll interval; daemon does the coalescing.
- **Crashloop detection**: declarative restart policy (`--restart on-failure`,
  `--restart always`, `--restart unless-stopped`, with backoff). Daemon owns
  the restart logic and emits `:container.crashloop` when backoff saturates.
- **Health checks**: periodic exec-based probes with threshold; emit
  `:container.unhealthy` events.
- **Event log**: ring buffer on disk per-container so reconnecting clients
  can replay recent history (`--since=5m`).
- Natural tie-in with M3: the daemon holds the pty master for interactive
  sessions and multiplexes attaches.

Open question to answer before coding: does the daemon supervise existing
containers across restarts (requires reattaching to PIDs and their cgroups on
startup), or does a daemon restart mean all containers restart? The first is
doable (we already have state dirs from M1) but adds edge cases; the second is
simpler but limits HA stories.

## M7 — image build DSL (`defcontainer`)

We have a Lisp. Dockerfile is a bad DSL trapped inside a worse language. The
plan: a `defcontainer` macro that produces OCI images, composable the way any
Lisp is composable.

```clojure
(defcontainer my-app
  (from "alpine:3.21")
  (run "apk add --no-cache curl ca-certificates")
  (copy "./app" "/app")
  (workdir "/app")
  (env "PORT" "8080")
  (expose 8080)
  (cmd "./run.sh"))
```

Key differentiators from Dockerfile:

- **Real abstraction.** Users define their own combinators:
  `(defn rust-app [name] (from "rust:alpine") (workdir "/src") (copy "." ".") (run "cargo build --release") ...)`
  and compose them. No `ONBUILD` workarounds, no Bash heredoc tricks.
- **Same runtime.** Each `run` layer actually executes inside an lgcr container
  against the current rootfs, then the diff is captured as a layer. The build
  and the run use the same code paths.
- **Macro-time validation.** Type-check paths, env keys, port numbers at
  compile time instead of layer N in a 20-minute build.
- **Deterministic layer IDs** derived from the AST + file hashes, so caching
  is precise (Dockerfile's line-based cache is a source of subtle bugs).

Needs: tar+gzip layer writer (let-go has `zip` ns — extend if needed),
OCI manifest/config writer (just JSON), layer diff via overlay upperdir,
a build context (current rootfs + env + workdir + user).

Arrives after the runtime is solid, because the build reuses the runtime.

## M8 — storage, images, polish

- Content-addressable layer store instead of `/tmp/letgo-rootfs/<name>`
- Image garbage collection
- `pull` resume on partial layers
- Signature verification (cosign / sigstore) — optional
- Robust cleanup on crash (state dir reconciliation on startup)
- Better error messages with actionable suggestions

## Cross-cutting / infrastructure

- let-go additions driven by each milestone:
  - M1: `WaitResult.signal`, log-capture ergonomics
  - M3: `open-pty`, `ioctl-winsz`, `setns`
  - M4: `prctl`, `capset`, seccomp BPF loader
  - M6: unix socket server (or lean on existing `http/serve`)
- Testing: Lima VM is fine for dev; add a CI path that runs the suite in a
  real Linux VM (GitHub Actions Linux runners work for most things, nested
  userns/overlay may not)

## Explicit non-goals (for now)

- Not trying to be a drop-in Docker/Podman CLI clone
- No Windows/WSL support
- No Kubernetes CRI shim — the event/agent model from M6 is for lighter-weight
  supervision, not kubelet integration

## Next concrete slice

The smallest coherent start on M1: `run -d` + state dir + `logs`. ~150 LOC of
lisp, zero or one new let-go primitive, unblocks every demo. `ps`/`stop`/`rm`
follow in a second sitting; zombie reaper + signal-forwarding init is the
third.
