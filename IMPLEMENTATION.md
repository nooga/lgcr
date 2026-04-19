# Implementation walkthrough

This is the long version of "how does lgcr actually work" for the curious.
It's not reference documentation; it's a tour. Skim the headings, dip into
the bits that interest you.

The code is in two files:

- `container.lg` — the runtime: CLI dispatcher, pull client, shim, init,
  state store, lifecycle commands
- `lib.lg` — pure helpers: parsing, formatting, env merging, signal-name
  tables. Exists so the unit tests can touch the logic without dragging in
  the filesystem.

Everything below is driven by let-go's `syscall` namespace, which lives in
the sibling [let-go repo](https://github.com/nooga/let-go). This project
shaped that namespace — several primitives (`spawn-async`, `pipe`, `kill`,
`signal-notify`) were added because lgcr needed them.

## Chapter 1 — What a container actually is

Strip away the marketing and a Linux container is a process with three pieces
of isolation layered on top of a regular `fork + exec`:

1. **Namespaces** — a private view of kernel-global resources. Each process
   lives in a set of namespaces: PID, mount, UTS (hostname), IPC, network,
   user. Inside a new PID namespace, the first process is PID 1; it can't
   see processes outside.
2. **Control groups (cgroups)** — accounting and limits. You put a process
   in a cgroup, write `memory.max` to a virtual file, and the kernel enforces
   it.
3. **An alternative filesystem root** — typically assembled from image
   layers via `overlay` and switched into via `pivot_root(2)`. The process
   is still yours, but its `/` is a different directory tree.

There's no "container" kernel object. A running container is just "a process
in particular namespaces, constrained by particular cgroup settings, that
pivoted into a particular rootfs."

The entire job of a container runtime is orchestration: pull the image,
prepare the rootfs, set up the cgroup, clone into the right namespaces,
pivot, drop privileges, exec the user command, then stick around long
enough to reap zombies and forward signals.

lgcr does all of that, and nothing else. No daemon, no networking, no
security sandbox — yet.

## Chapter 2 — The pull

`lgcr pull alpine:3.21` is a real OCI registry client. The flow:

1. **Parse the ref.** `alpine:3.21` expands to
   `registry-1.docker.io/library/alpine:3.21` (Docker Hub applies an
   implicit `library/` prefix for un-namespaced names).
2. **Get a token.** Docker Hub requires a pull-scope Bearer token from
   `auth.docker.io` before any registry call.
3. **Fetch the manifest.** For popular images this comes back as a
   *manifest list* (one manifest per architecture); we pick the entry
   matching the host arch and fetch its single-arch manifest in a second
   request.
4. **Stream each layer.** Layers are gzipped tarballs. We HTTP-GET each
   blob, pipe it to a temp file, then `tar xzf` into the rootfs. Layers
   are ordered, and tar replays any whiteouts the image uses to delete
   files from lower layers.
5. **Save the config.** The manifest references a *config blob* containing
   ENTRYPOINT, CMD, ENV, WORKDIR, USER and other metadata. We fetch it,
   pluck the fields we care about, and save a reduced version at
   `<rootfs>/.lgcr-config.json` — much smaller than the upstream config,
   and read by `run`.

What we're not doing: content-addressable storage (layers land in
`/tmp/letgo-rootfs/<repo>-<tag>/` as a single merged tree; if you pull two
tags of the same image, the second one re-downloads everything). That's
M8 territory.

## Chapter 3 — The `run` flow

This is where it gets interesting. There are two flavors:

### Foreground (`lgcr run image cmd...`)

Simple path. A single CLI process:

1. Generates a 32-char hex id, writes initial `state.json`.
2. Resolves the image ref → rootfs + saved config.
3. Composes the final argv: `ENTRYPOINT ++ (user cmd or CMD)`.
4. Sets up the overlay + cgroup.
5. Calls `syscall/spawn-async` with `CLONE_NEW{NS,PID,UTS,IPC}`, stdio
   inherited from the terminal, and argv
   `[self "init" container-id]`. The child is PID 1 in the new PID ns.
6. `waitpid`s for the child. Writes final status to `state.json`.
7. `os/exit` with the child's exit code.

### Detached (`lgcr run -d`)

Here's where the shim pattern shows up:

```
lgcr (cli)                lgcr shim                 lgcr init
─────────                 ─────────                 ─────────
write state.json
spawn-async shim detached
                          read state.json
                          setup rootfs, cgroup
                          open stdout.log, stderr.log
                          spawn-async init (cloneflags)
                                                    pivot_root
                                                    chdir workdir
                                                    setuid/setgid
                                                    spawn user-cmd as child
                                                    <runs as PID 1>
                          waitpid(init pid)
                          update state.json
                          close log files
exit 0
```

Three processes, three jobs:

- **The CLI** is stateless. Its only duty is "write the initial state and
  spawn a shim." After `os/exit`, you can close your shell; the shim survives
  because `syscall/spawn-async` starts children with `Setsid: true`, so they
  don't get SIGHUP'd when the parent session ends.
- **The shim** owns the container's lifecycle. It's the process you'd see in
  `ps auxf` sitting between init and the user command. It's what waits for
  the container to exit and writes the final `:status`/`:exit-code`/`:signal`
  to disk.
- **The init** is the container's PID 1. It's a let-go process too (the same
  `lgcr` binary re-invoked with `init <id>`). Its job is detailed next.

Why a shim instead of just detaching the init? Because init is *inside* the
new namespaces and with a pivoted root — it can't write to the host
filesystem anymore, so it can't update the state file sitting under
`$XDG_STATE_HOME/lgcr/`. The shim stays outside, so it can.

## Chapter 4 — Init as PID 1

A process running as PID 1 in a PID namespace has special kernel duties:

- **It reaps orphans.** When any process in the namespace exits and its
  parent is gone, it becomes init's child. Init *must* `waitpid` for it or
  the kernel keeps a zombie around indefinitely.
- **It doesn't get default signal handlers.** Normally the kernel provides a
  default action for most signals (SIGTERM → die). For PID 1, signals are
  ignored unless it explicitly installs a handler. That's why many naive
  Docker images don't respond to `docker stop` — they exec a process that
  was never designed to be PID 1.

lgcr's init handles both:

```clojure
(let [sig-ch   (async/chan 8)
      _        (syscall/signal-notify sig-ch
                                      syscall/SIGTERM syscall/SIGINT
                                      syscall/SIGQUIT syscall/SIGHUP)
      res      (syscall/spawn-async bin argv env 0 *in* *out* *err*)
      user-pid (:pid res)]

  ;; signal forwarder: everything we catch gets relayed to the user proc
  (async/go* (fn []
               (loop []
                 (let [sig (async/<! sig-ch)]
                   (when sig
                     (try (syscall/kill user-pid sig) (catch e nil))
                     (recur))))))

  ;; reap zombies and wait for user-pid to exit
  (loop []
    (let [wr (syscall/waitpid -1 0)]
      (if (= (:pid wr) user-pid)
        (os/exit ...)
        (recur)))))
```

Two concurrent loops:

- The **signal forwarder** is a let-go go-block (real Go goroutine) that
  takes from an `async/chan`. `syscall/signal-notify` wires Go's
  `signal.Notify` into that chan: every SIGTERM the kernel delivers to
  init shows up as an int in the channel. The go-block relays it with
  `syscall/kill`.
- The main thread blocks on `waitpid(-1, 0)` — "any child, blocking."
  Every time it returns, we check whether the reaped pid is the user's
  main process. If yes, we exit with its status (or `128 + signal`); if
  no, it was an orphan grandchild and we loop back to reap the next one.

This is exactly what tools like [tini](https://github.com/krallin/tini) do,
and what Docker gives you when you pass `--init`. In lgcr it's just baked in.

### The cloneflags dance

There's a subtlety about PID namespaces: the process that *creates* the
namespace (via `unshare` or `clone`) doesn't itself live in it — only its
children do. So if we just unshared in the shim and then spawned init, init
would be PID 2 (or whatever), not PID 1.

Go's `SysProcAttr.Cloneflags` handles this correctly. When you pass
`CLONE_NEWPID` as a clone flag at fork time, the child is born directly in
the new namespace as PID 1. That's how our `syscall/spawn-async` works —
one `clone()` call with the flags baked in, no `unshare(2)` needed.

## Chapter 5 — Rootfs: overlay and pivot_root

Container rootfs setup happens in two layers (pun intended):

### Layer 1: overlay mount (shim-side)

We want containers to be isolated — writes inside one container shouldn't
affect the base image or other containers. Linux's `overlayfs` gives us
exactly that: three directories (lower, upper, work) combine into a single
merged view, with writes going to `upper` as a copy-on-write operation.

```
lowerdir=/tmp/letgo-rootfs/library_alpine-3.21   <- the image, read-only
upperdir=/tmp/letgo-containers/<id>/upper         <- the container's writes
workdir=/tmp/letgo-containers/<id>/work           <- overlayfs bookkeeping
merged=/tmp/letgo-containers/<id>/merged          <- what the container sees
```

We mount all that before spawning init. If overlay isn't available (nested
containers, weird kernels), we fall back to `cp -a` — a full copy of the
rootfs. Slower and wasteful, but it works.

### Layer 2: pivot_root (init-side)

Now init is inside the mount namespace with the overlay visible at
`/tmp/letgo-containers/<id>/merged` — but init's `/` is still the host's
filesystem. We need to swap it.

`pivot_root(new_root, put_old)` is the syscall for this. It:

1. Moves the root mount to `put_old` (an empty directory inside `new_root`).
2. Makes `new_root` the new root mount.

After pivot, we `umount -l /.pivot_old` and `rm -rf` it. The old host
filesystem is unreachable from inside the container.

Before pivoting, we also:
- Make the mount tree private (`MS_REC | MS_PRIVATE`) so propagation
  doesn't leak our mounts back out to the host.
- Mount `proc`, `sys`, `dev` inside the new root — without these, the
  container would be surprised that `/proc/self/exe` doesn't exist.
- Bind-mount the host `/dev` for now (M4 will replace this with a curated
  tmpfs — bind-mounting the full host `/dev` is a security hole).

## Chapter 6 — State store

Every container has a directory at
`$XDG_STATE_HOME/lgcr/containers/<full-id>/` with:

```
state.json       # single source of truth, updated by both shim and CLI
stdout.log       # captured via -d; just raw bytes
stderr.log
shim.log         # internal shim stderr, useful when debugging shim crashes
```

`state.json` is the whole per-container record: command, args, env,
workdir, limits, pid, rootfs paths, cgroup path, and a full lifecycle
timeline (`:created`, `:started`, `:finished` as both ISO strings and
epoch timestamps). ps, inspect, logs, stop, kill, rm, start all just
read-and-update this.

Short-id prefix lookup is a tiny helper: `(resolve-id prefix)` scans the
containers dir, collects matches, and errors if more than one container
starts with the prefix. Minimum two characters, so `lgcr rm a` can't
accidentally take everything down.

There is **no daemon**. Nothing is continuously running outside of the
shim processes that belong to each container. The CLI reads `state.json`
fresh every time. If the shim gets killed, the container entry becomes
`dead` (we detect this via `kill -0` on the stored pid). Some edge cases
in this model become harder if we ever want HA — that's a tradeoff called
out in the roadmap's M6 section.

## Chapter 7 — let-go side: the syscall surface

Some of what lgcr does wasn't possible with stock let-go. Along the way
we added these primitives to let-go's `syscall` namespace:

- **`syscall/spawn-async`** — non-blocking fork+exec. Takes IOHandle stdio
  slots (nil → /dev/null, IOHandle → that fd, `*out*`/`*err*` → inherit),
  cloneflags, and env. Returns `{:pid}`. Always sets `Setsid` so detached
  children survive parent teardown. The workhorse.
- **`syscall/pipe`** — `os.Pipe()` wrapped as a pair of IOHandles, so you
  can wire stdout of one process to a reader in another. Enables `logs -f`
  and (future) `exec -it`.
- **`syscall/kill`** — signal a pid. Also used as `kill -0` liveness
  probes for the stale-state detector.
- **`syscall/signal-notify`** — `signal.Notify` that delivers to a let-go
  `async/chan` instead of a Go channel. The whole PID-1 signal-forwarder
  pattern hangs off this.
- **`WaitResult.signal`** — `waitpid` used to flatten "exit 137" and
  "SIGKILL'd" into a single `:status -1`. Now it reports both, so we can
  tell them apart and record `:signal` in state.json.

The `lg` tool itself also grew two features:

- **Script mode** stopped eating extra positional args. Previously
  `let-go container.lg pull alpine:3.21` tried to run `pull` and
  `alpine:3.21` as additional scripts ("open X: no such file"). Now only
  the first positional is the script; the rest pass through as `os/args`.
- **`-bundle-base PATH`** on `lg -b` lets you cross-bundle: run the bundle
  command on macOS, using a cross-compiled linux/arm64 `lg` as the
  "template" binary. What we ship is the linux binary with the compiled
  `container.lg` appended after an `LGBX` footer. `bundle.sh` automates
  this.

## Chapter 8 — Testing

Everything pure lives in `lib.lg` and is unit-tested in
`tests/lib_test.lg` using let-go's built-in `test` namespace
(`deftest`/`is`/`testing`, same shape as `clojure.test`). That covers
parse-image-ref, compose-command, env merging, short-flag splitting,
signal parsing, time formatting, status rendering — the bits that are
easy to get wrong and have no filesystem/process side effects.

Everything that touches the runtime is exercised in `tests/e2e.sh`,
which runs against the real `./lgcr` binary inside Lima. Each scenario:
reset state, run some commands, assert exit codes and state.json fields
and `lgcr ps` output shape.

`./tests/run.sh` does the whole thing: bundle, unit, e2e. Under two
minutes end-to-end.

## Further reading

- [ROADMAP.md](./ROADMAP.md) — what's done, what's next, what's explicitly
  not a goal
- [`container.lg`](./container.lg) — the runtime; probably 700 lines you
  can read in a sitting
- [`lib.lg`](./lib.lg) — pure helpers; small, pleasant
- [nooga/let-go](https://github.com/nooga/let-go) — the host language
