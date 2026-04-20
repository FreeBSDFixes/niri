# Building and running niri on FreeBSD 15 + NVIDIA

This document explains every change that sits on top of upstream niri
in this repository. `freebsd/apply.sh` automates most of it; this file
exists so that the intent behind each patch is recorded somewhere
permanent.

## What this fork changes

| # | What                                       | Type               | Origin                                        |
|---|--------------------------------------------|--------------------|-----------------------------------------------|
| 1 | `RUST_LIBC_UNSTABLE_FREEBSD_VERSION=15`    | env var            | FreeBSD 15 requirement                        |
| 2 | `patch-no-systemd`                         | niri source patch  | Adapted from FreeBSD ports                    |
| 3 | `patch-pipewire` / `patch-pipewire-sys`    | crate patch        | Adapted from FreeBSD ports                    |
| 4 | `patch-drm` (from_dev_id + has_render)     | crate patch        | Our fix (ports version is incomplete)         |
| 5 | `patch-polling` (kqueue FD bookkeeping)    | crate patch        | Our fix (smol-rs/polling#262)                 |
| 6 | Ports `patch-udev` is deliberately dropped | omission           | Our decision (ports version panics on NVIDIA) |
| 7 | `disable-cursor-plane` in niri config      | runtime config     | NVIDIA driver workaround                      |
| 8 | `start_niri_nvidia` launcher script        | script             | Ours                                          |

## 1. RUST_LIBC_UNSTABLE_FREEBSD_VERSION=15

File: `.cargo/config.toml`

```toml
[env]
RUST_LIBC_UNSTABLE_FREEBSD_VERSION = "15"
```

### Background on the FreeBSD libc ABI

FreeBSD's libc has used ELF symbol versioning since 7.0. Every major
release adds a new `FBSD_1.N` namespace and keeps the older ones:
`FBSD_1.5` for 12, `FBSD_1.6` for 13, `FBSD_1.7` for 14, `FBSD_1.8`
for 15. New symbols added in a release go into the new namespace;
the old ones do not move. That makes the ABI forward compatible: a
binary linked on 13 still resolves its `FBSD_1.6` symbols on 14 and
15. The reverse direction does not work, because an older libc does
not have the newer namespace.

The one notable type-layout break in recent history was the "ino64"
project for FreeBSD 12.0, which widened `ino_t`, `nlink_t`, and
`dev_t` from 32-bit to 64-bit. This is where the infamous i32/i64
mismatches come from. After 12, the changes between majors are much
smaller: individual struct fields (`tcp_info` padding, `kvm_page`
field names), new constants, new syscalls. No wholesale type widening.

So it is accurate to think of FreeBSD's ABI as "12 and later are one
thing; pre-12 is different," not "every major release breaks."

### What `RUST_LIBC_UNSTABLE_FREEBSD_VERSION` actually controls

This env var is read by the `libc` crate's `build.rs`. It is a
compile-time feature selection, not an ABI compatibility shim. The
crate ships per-version cfg blocks (`freebsd12`, `freebsd13`,
`freebsd14`, `freebsd15`) that gate:

- Constants defined only on newer releases (for example `P_IDLEPROC`
  on 15 where 14 had `P_UNUSED3`).
- Struct layouts that differ between releases. `CPU_SETSIZE` is 256
  on 12/13 and 1024 on 14/15. `tcp_info` has different padding and
  field names per release.
- Field renames in structs like `kvm_page`.

The default when the env var is unset depends on which libc release
you pull in. Older libc defaulted to freebsd11; starting from libc
0.2.176 the default was bumped to freebsd12. niri currently pulls
libc 0.2.182, which defaults to freebsd12. Either way, the default
is a conservative lower bound chosen by the crate maintainers, not
an autodetect of the build host.

On FreeBSD 15 that default is wrong. Structs like `tcp_info` will be
laid out for FreeBSD 12 headers, not 15, so any code reading those
fields at runtime will read the wrong bytes. Setting the env var to
15 tells the crate to generate the FreeBSD 15 layouts. On older libc
releases (before the default bump), pre-12 types like `ino_t` as 32
bits vs 64 bits are what would bite you instead.

Source: https://github.com/rust-lang/libc/blob/main/build.rs
Discussion of the default: https://github.com/rust-lang/libc/issues/2061

### What breaks without it

Depends on which dependency touches which struct. Typical symptoms are
runtime struct-field misreads (values that should be non-zero come out
zero, or vice versa, because the Rust-side field offset does not match
the real FreeBSD 15 kernel layout) and occasional compile errors for
code that references a constant only defined on newer releases.

### Why it lives in `.cargo/config.toml`

Cargo reads `[env]` from `.cargo/config.toml` and exports each entry
into the build environment. Putting it in the repo has three
advantages over exporting from a shell profile:

1. Scoped to this checkout. No risk of carrying the override into an
   unrelated Rust project.
2. Applied to every `cargo` invocation in this tree automatically, so
   IDE builds and rust-analyzer see the same definitions as the CLI.
3. Committed, so anyone cloning the fork picks it up without having
   to remember a shell export.

### The rule of thumb: match the number to your host

Set the number to the major version from `uname -r` on the machine
the binary will run on. On 13, set `13`. On 14, set `14`. On 15,
leave it at `15`. On 16 once that ships, set `16` if the libc crate
you are pulling has a matching cfg yet (watch the build.rs in
[rust-lang/libc](https://github.com/rust-lang/libc/blob/main/build.rs)).

Matching is the right default because the number selects which
FreeBSD release's struct layouts and constants the Rust `libc` crate
models. Two failure modes are possible when it does not match:

- **Too low.** The crate uses an old struct layout against a newer
  kernel. Fields land at the wrong offsets; you read garbage (often
  zeros) where real values should be, with no compile-time hint
  anything is wrong. This is what happens to anyone on FreeBSD 15
  who leaves the env var at the crate default of 12.
- **Too high.** You may compile fine but fail at dynamic link time
  on the host because libc symbols from a newer `FBSD_1.N` namespace
  are not exported by the older host libc. You may also end up
  referencing constants the crate only exposes for newer releases,
  without having the matching kernel support.

Cross-compiling is the one case where the value is not "your host."
Set it to whichever FreeBSD you are building *for*, not building on.

### When to revisit

If the `libc` crate ever stabilises the flag, the env var will be
renamed (the `UNSTABLE_` prefix will go away). Watch for that and
update `.cargo/config.toml` accordingly.

## 2. patch-no-systemd

Modifies `resources/niri.desktop` and `src/niri.rs`.

`niri.desktop`: `Exec=niri-session` becomes `Exec=niri --session`. The
`niri-session` wrapper is a shell script that expects systemd user
units, which FreeBSD does not have.

`niri.rs`: the power-key `Inhibit` D-Bus call is retargeted from
`org.freedesktop.login1` (systemd-logind) to
`org.freedesktop.ConsoleKit` (ConsoleKit2, which is what FreeBSD uses
here). Only this one manual call needs to change; the logind-zbus
session calls elsewhere in the file are fine.

Taken from `/usr/ports/x11-wm/niri/files/patch-no-systemd`.

## 3. patch-pipewire and patch-pipewire-sys

Patched crates live in `freebsd/crates/pipewire-0.9.2/` and
`freebsd/crates/pipewire-sys-0.9.2/`.

The FreeBSD pipewire port exports `pipewire_init` / `pipewire_deinit`
instead of `pw_init` / `pw_deinit`. These patches update the rust
bindings to call the correct symbols and extend the bindgen allowlist
so the generated bindings pick them up.

Taken from `/usr/ports/x11-wm/niri/files/patch-pipewire_init`.

## 4. patch-drm: from_dev_id on FreeBSD

Patched crate lives in `freebsd/crates/drm-0.14.1/`.

### What goes wrong

The drm crate derives the DRM node type (primary, control, render)
from `minor(st_rdev) >> 6`. That works on Linux because the st_rdev
minor number is the DRM device number. On FreeBSD the two are
unrelated:

| device                  | devname   | st_rdev minor | minor>>6 | expected | what drm decides |
|-------------------------|-----------|---------------|----------|----------|------------------|
| `/dev/dri/card0`        | `drm/0`   | 192           | 3        | Primary  | NotDrmNode       |
| `/dev/dri/renderD128`   | `drm/128` | 64            | 1        | Render   | Control          |

niri would fail during startup with "the provided file descriptor does
not refer to a DRM node" because it could not even identify its own
primary GPU.

### The fix

Split the `minor(dev) >> 6` lookup into a Linux path and a FreeBSD
path. The FreeBSD path uses `devname()` to read the kernel's name for
the device and parses the trailing integer out of strings like
`drm/0` or `drm/128`. The result is then shifted by 6 as on Linux to
determine the node type. The `devname()` helper and `is_device_drm()`
that it depends on are already present upstream on FreeBSD, so we are
just wiring them through the one spot that still relied on the minor
number.

Also fix `has_render` which was hardcoded to `false` on FreeBSD. With
node type detection actually working, it can now use the same
`node_path(...).is_ok()` check as Linux.

### Relationship to the ports' patch-drm

The FreeBSD ports tree carries its own `patch-drm` for drm 0.14.1
that restructures the code similarly to upstream PR #210 (extracts
the node-type logic out of `DrmNode::from_dev_id` into its own
helper). That restructuring alone does not fix the minor-vs-device
mismatch; our patch actually replaces the lookup.

niri briefly pinned drm 0.14.2 and then dropped back to 0.14.1 in
niri commit `5dc4e83b` ("Upgrade dependencies"). This patch targets
0.14.1, where the node type code lives inline in `DrmNode::from_dev_id`
rather than on `NodeType` as it would in 0.14.2.

### If the drm crate version changes

`freebsd/apply.sh` is pinned to `drm-0.14.1`. When niri bumps the drm
dep, delete `freebsd/crates/drm-X.Y.Z/`, update the `setup_crate`
call in `apply.sh`, update the path in `[patch.crates-io]` in
`Cargo.toml`, and adjust the patch if the surrounding code shifted.
Sanity check before shipping: grep the new source for `fn from_dev_id`
and make sure the FreeBSD branch uses devname().

## 5. patch-polling: drop kqueue FD bookkeeping

Patched crate lives in `freebsd/crates/polling-3.11.0/`.

### What goes wrong

polling 3.11 keeps a HashSet of registered source IDs and rejects
duplicate registrations with AlreadyExists, so that kqueue behaves like
epoll. Unfortunately kqueue silently drops its own registration when an
FD is closed, while the HashSet is only updated on an explicit delete
call. After a close/reopen cycle the kernel hands the FD number back
out for a new socket, and `add()` rejects it even though kqueue itself
would have accepted it happily.

Inside niri this shows up as a flood of `error making IPC stream async`
warnings and as a crash at `src/utils/transaction.rs:119`. It is
trivial to trigger with any bar that opens short-lived IPC connections,
such as waybar or eww.

Upstream issue: https://github.com/smol-rs/polling/issues/262

### The fix

Make `add_source`, `has_source`, and `remove_source` no-ops in the
kqueue backend. kqueue's native duplicate rejection is sufficient for
our needs.

### If the polling crate version changes

Check whether smol-rs/polling#262 has been fixed upstream. If so, drop
this patch. Otherwise port the no-op change to the new version.

## 6. Why we drop the ports' patch-udev

`/usr/ports/x11-wm/niri/files/patch-udev` wraps three
`if node.ty() != NodeType::Primary` checks in `src/backend/tty.rs` with
`#[cfg(not(target_os = "freebsd"))]`. Its intent was to let render
nodes through `device_added` on FreeBSD, because `from_dev_id` could
not identify card0 as the primary node anyway.

With our `patch-drm` the detection works correctly, and the upstream
filter does the right thing on FreeBSD too. If we also applied the
ports' udev patch, niri would open both card0 and renderD128 and run
primary-node operations against the render node. On NVIDIA that hits a
bug in `__nv_drm_gem_nvkms_handle_vma_fault` and panics the kernel.

We keep `freebsd/patches/patch-udev.patch` as a documentation stub so
that future readers can find this explanation; `apply.sh` does not
apply it.

## 7. disable-cursor-plane

Add this to `~/.config/niri/config.kdl`:

```kdl
debug {
    disable-cursor-plane
}
```

Smithay allocates cursor plane buffers through GBM with
`CURSOR | WRITE` and then calls `gbm_bo_map()` to write cursor pixels.
On NVIDIA FreeBSD that mmap path ends up in
`__nv_drm_gem_nvkms_handle_vma_fault`, which has a bug in its
LinuxKPI VMA handling and panics the kernel.

The stream of reports is the same everywhere: niri issue #2625,
Hyprland's earlier occurrence at amshafer/nvidia-driver#24, and several
others. wlroots stopped triggering it in 0.42.0 by GPU-rendering cursor
planes and importing via DMA-BUF; Smithay does not do this yet.

`disable-cursor-plane` tells niri to composite the cursor onto the
primary plane instead of using a dedicated hardware cursor plane. GPU
usage goes up very slightly. In return niri stops panicking the
kernel.

Leave this in place until NVIDIA fixes their VMA fault handler.

## 8. start_niri_nvidia

Script lives at `freebsd/start_niri_nvidia`. Copy it somewhere on
`$PATH` (e.g. `~/.local/bin/`) and run it from a bare TTY.

Highlights:

- `XDG_RUNTIME_DIR=/var/run/xdg/$(id -un)`. pam_xdg on FreeBSD 14+
  creates `/var/run/xdg/$USER`, not the Linux `/var/run/user/$uid`
  convention.
- `LIBSEAT_BACKEND=seatd`. Matches the running seatd.
- `GBM_BACKEND=nvidia-drm`. Without this, Smithay may pick Mesa's GBM
  implementation on systems with both installed.
- `RUST_LIB_BACKTRACE=0`. Backtrace capture in anyhow/std is extremely
  slow on FreeBSD because `dl_iterate_phdr` takes a global write lock
  on every unwind.
- Logs go under `~/.local/state/niri/niri_<n>.log` on the real
  filesystem. A header is written out and `sync`'d before niri starts,
  so the log survives a kernel panic.
- Launch chain is `dbus-launch --exit-with-session`,
  `ck-launch-session`, `niri --session`. `ck-launch-session` is what
  makes the patched power-key Inhibit call (see patch-no-systemd) find
  a ConsoleKit session to talk to.

## Automation: freebsd/apply.sh

The script does three things:

1. Applies `patch-no-systemd.patch` in place. Idempotent.
2. Copies `drm`, `pipewire`, `pipewire-sys`, and `polling` out of the
   cargo registry cache and patches them into `freebsd/crates/`.
3. Ensures `[patch.crates-io]` in `Cargo.toml` points at those copies.

Not automated: steps 1, 7, 8. The env var lives in `.cargo/config.toml`
and gets committed directly. The niri config is user-owned. The
launcher script is user-installed.

`.git/hooks/post-merge` runs `apply.sh` after every `git pull`.

## After a git pull

1. `post-merge` runs `apply.sh`.
2. If a patch fails to apply because upstream touched the same lines,
   update the patch file in `freebsd/patches/`.
3. If a pinned crate version changes upstream, delete the matching
   directory in `freebsd/crates/`, update `apply.sh`, re-run it.
4. Rebuild:

```
cargo build --release --no-default-features --features dbus,xdp-gnome-screencast
```

## Gitignored paths

`.git/info/exclude` keeps a few local-only paths out of git:

```
/freebsd/crates/
*.orig
```

`freebsd/crates/` is derived data. It's copied out of the cargo
registry and patched every time `apply.sh` runs, so there is no point
in tracking it and plenty of reason not to (size, licensing).
