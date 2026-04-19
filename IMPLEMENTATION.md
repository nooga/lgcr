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

lgcr's init runs four concurrent loops, all backed by real goroutines
via let-go's `go`:

- **signal forwarder** — `signal.Notify` for SIGTERM/INT/QUIT/HUP is wired
  into an `async/chan`; every delivery is `syscall/kill`'d to the primary
  user pid so `lgcr stop` behaves.
- **reaper** — `SIGCHLD` is wired into a separate channel. On each
  notification, `waitpid(-1, WNOHANG)` is drained until empty; reaped
  children go to the state-mgr. This catches orphans (the PID 1 duty) as
  well as exec children.
- **state-mgr** — a single goroutine owns the pid→waiter map plus a
  pending-exits buffer, serving two message types: `:register` (a waiter
  wants the result for pid N) and `:reap` (the reaper produced a result
  for pid N). The pending buffer resolves the race where a child exits
  before its waiter registers.
- **accept loop** — the control socket (see Chapter 7a) accepts
  connections and dispatches each to a `handle-exec-conn` goroutine.

The main init thread is the primary user pid's "waiter": it registers
with the state-mgr and blocks on its reply channel. When that fires, we
close the listener, unlink the socket, and exit with the primary's
status. This is tini's job — in lgcr it's just baked in.

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

## Chapter 6a — Exec and the control socket

The obvious "just call `setns(2)` from `lgcr exec`" approach does not work.
Go's runtime creates threads with `CLONE_FS`, which means mount-namespace
`setns` reliably returns `EINVAL` — the kernel refuses to change mnt-ns
while any thread shares FS state. Runc works around this with a CGO
constructor (`nsexec.c`) that runs before the Go runtime. We'd like to
stay CGO-free.

**Solution**: the container's init already lives in every namespace. So
we let init be the launcher.

Each container gets a Unix socket at `$STATE_DIR/<id>/ctrl.sock`, created
by init **before** `pivot_root` so the path lives on the host mnt and
the listener fd outlives the mnt-ns switch. Init's accept loop waits for
connections; each one is a request to fork a command.

The protocol is stupidly simple — JSON with `SCM_RIGHTS` fds:

```
→ client: {"argv":["/bin/sh","-c","echo hi"],"env":[...],"tty":false}
   ancillary: 3 fds (client's stdin/stdout/stderr, or pty slave × 3)
← init:   {"pid":42}
← init:   {"exit":0,"signal":0}
```

The client's stdio fds arrive on init's side as new fds in its table —
dropped straight into `spawn-async`'s stdio slots. The child inherits
them via Go's `os.StartProcess` dup, and init's copies are closed. The
child runs in all of init's namespaces (mnt/pid/uts/ipc) without any
`setns` call — it's just a normal fork from a process that's already
where we need to be.

The same substrate is meant to grow into stats subscriptions, lifecycle
events, and attach (see ROADMAP M6) — same socket, same framing, more
ops.

### `-it`: pty wiring

For `exec -it`, the client allocates a pty pair on the host:

- `term/open-pty` → `{:master :slave :slave-path "/dev/pts/N"}`
- Put client's stdin into raw mode (`term/raw-mode! *in*` returns an
  opaque saved termios — restored on every exit path)
- Send the *slave* three times as the request's fds; tag the request
  with `:tty true`
- Init's handle-exec-conn sees `:tty`, passes `{:setctty? true}` to
  `spawn-async`. That sets `SysProcAttr.Setctty = true, Ctty = 0` — the
  kernel makes fd 0 (the pty slave) the child's controlling terminal,
  which is required for Ctrl-C, job control, and `ioctl(TIOCGWINSZ)`
  from inside the container.

Three client-side goroutines then shuttle bytes:

- stdin → pty master (raw passthrough; Ctrl-C is just a byte)
- pty master → stdout (terminates on EOF when the child + init's slave
  dup are both closed)
- SIGWINCH handler → `term/set-size master` so `stty size` inside the
  container always matches the host terminal

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
- **`syscall/spawn-async` opts** — an 8th optional map arg. Currently
  understands `{:setctty? true}`, which sets `SysProcAttr.Setctty` so a
  pty-slave stdin becomes the child's controlling terminal.

Two new namespaces landed for M3:

- **`unix/`** — AF_UNIX stream sockets with `SCM_RIGHTS` fd passing. Six
  primitives: `listen`, `accept`, `connect`, `send`, `recv`, `close`,
  plus `fd` to coerce an IOHandle to a raw int. Generic enough that M6's
  event stream will reuse them.
- **`term/`** gained pty-side primitives on top of xsofy's existing
  raw-mode / size / ANSI helpers: `open-pty`, `set-size` (TIOCSWINSZ),
  `tty?`, and fd-parameterized variants of `raw-mode!` / `restore-mode!`
  / `size` so you can drive an arbitrary fd, not just the process's own
  stdin/stdout.

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
