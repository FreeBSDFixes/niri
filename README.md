# niri on FreeBSD

This is a FreeBSD fork of [niri](https://github.com/niri-wm/niri). It
carries a handful of patches that are needed to build and run niri on
FreeBSD 15, plus a setup script, a launcher, and a long-form guide
explaining why each change exists.

Upstream niri's README follows below unchanged. Read that for what
niri *is*; read this section for how to get it running on FreeBSD.

## Why this fork exists

FreeBSD ships a ports entry for niri at `x11-wm/niri`. That port works
for a lot of people, but three things are wrong with it for a NVIDIA
user who wants to build from a current git checkout:

1. The drm crate patch in ports targets drm 0.14.1. niri has moved to
   drm 0.14.2, which contains the upstream PR that the ports patch
   was based on, but that PR did not actually fix the underlying bug:
   DRM node type detection still produces wrong results on FreeBSD.
2. The ports tree carries a udev patch that removes the `NodeType::Primary`
   filter in niri's TTY backend. That patch existed as a workaround
   for the broken DRM node detection. Once node detection is fixed,
   keeping the filter removed causes niri to run primary-node DRM
   operations against the render node, which panics the kernel on
   NVIDIA.
3. There is no workaround in ports for the stale-FD bug in the
   `polling` crate's kqueue backend. That bug takes down niri within
   seconds if you run waybar or eww against it.

This fork fixes node detection properly, keeps the upstream Primary
filter in place, patches the polling crate, and documents the whole
chain in [freebsd/GUIDE.md](freebsd/GUIDE.md).

## Objectives

1. Build niri from a current git checkout on FreeBSD 15 without
   having to patch anything by hand.
2. Run niri on NVIDIA without panicking the kernel.
3. Run niri with a bar (waybar, eww) without the IPC crash.
4. Keep the diff against upstream niri minimal and legible so that
   rebasing onto future niri releases stays manageable.

## Prerequisites

This guide assumes you already have a working Wayland + NVIDIA setup
on FreeBSD: `nvidia-drm` loaded with `hw.nvidiadrm.modeset=1`, seatd
running, your user in the `video` group, and some other Wayland
compositor (Hyprland, Sway, etc.) that you have successfully run on
this machine. If any of that is new to you, get it working with
another compositor first; there is nothing niri-specific in any of
it, and the FreeBSD wiki and Hyprland-on-FreeBSD write-ups cover it
better than this README could.

What this repo adds on top of that baseline is what you need to
build niri from a git checkout: the patches, the setup script, the
launcher.

## Installing Rust

niri tracks a recent stable Rust. The official rustup installer from
https://rustup.rs works fine on FreeBSD, just copy-paste the one-liner
from their homepage:

```
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
```

That gives you `cargo`, `rustc`, and the toolchain updater in one go.
If you would rather use the ports Rust (`lang/rust`), make sure it is
at least the `rust-version` listed in `Cargo.toml` under
`[workspace.package]`.

### A note on the libc ABI knob

The Rust `libc` crate picks a FreeBSD major version at build time to
decide which struct layouts and constants to expose. It does this
because FreeBSD's own headers have evolved across releases: the big
one was the "ino64" project in FreeBSD 12.0, which widened `ino_t`,
`nlink_t`, and `dev_t` from 32-bit to 64-bit, and smaller adjustments
to specific structs (`tcp_info`, `kvm_page`, `CPU_SETSIZE`) in
subsequent releases.

The crate's default depends on which libc version is in your lockfile.
Recent libc (0.2.176 and later, which niri uses) defaults to FreeBSD
12; older libc defaulted to FreeBSD 11. Neither default matches
FreeBSD 15, so on a 15 host you get wrong struct layouts in any
dependency that reads newer kernel interfaces. This repo sets the
knob to `15` in [`.cargo/config.toml`](.cargo/config.toml), so as
long as you use `cargo` in this checkout you do not have to think
about it.

**Match the number to the FreeBSD version your binary will run on.**
If you are on 13, set it to `13`. On 14, set `14`. On 15, leave it at
`15` (the committed default in this repo). On 16 once that ships,
set `16` if the libc crate you are pulling supports that cfg yet.

The reason matching is the right default: the number tells the `libc`
crate which kernel headers to model. Setting it lower than your host
(say `12` on a FreeBSD 15 machine) means dependencies that read
kernel structs like `tcp_info` will use a FreeBSD 12 field layout
against a FreeBSD 15 kernel, so fields line up at the wrong offsets
and you silently read wrong values. Setting it higher than your host
is the other direction of the same problem, plus you may hit
dynamic-link errors for symbols in a libc namespace your host does
not export (e.g. a binary compiled as 15 expects `FBSD_1.8` symbols
that a FreeBSD 14 libc does not have).

The practical recipe: match the env var to `uname -r`'s major number
and forget about it. Typical symptoms of the wrong value are i32/i64
type mismatches at compile time on pre-12 hosts, and runtime
struct-field misreads on 13+ hosts (values that should be non-zero
come out zero because the Rust-side field offset does not match the
host kernel layout).

See [freebsd/GUIDE.md](freebsd/GUIDE.md) section 1 for the background
on FreeBSD's symbol versioning and what the crate actually gates on
this flag.

## Building

Clone this fork and its patched crates in one go:

```
git clone https://github.com/FreeBSDFixes/niri.git
cd niri
./freebsd/apply.sh
```

`apply.sh` copies a few upstream crates (`drm`, `pipewire`,
`pipewire-sys`, `polling`) out of the cargo registry cache into
`freebsd/crates/`, patches them, and wires them up in `Cargo.toml`.
It is idempotent.

Build a release binary:

```
cargo build --release --no-default-features --features dbus,xdp-gnome-screencast
```

The release binary lands at `target/release/niri`. First-time builds
take a while; subsequent builds are incremental.

If you plan to pull from upstream niri over time, install the
post-merge hook so the patches are re-applied automatically after
every `git pull`:

```
ln -s ../../freebsd/apply.sh .git/hooks/post-merge
chmod +x .git/hooks/post-merge
```

## Running

Copy the launcher somewhere on your PATH:

```
install -m 0755 freebsd/start_niri_nvidia ~/.local/bin/
```

Add the NVIDIA cursor-plane workaround to `~/.config/niri/config.kdl`
(see [freebsd/GUIDE.md](freebsd/GUIDE.md) section 7 for the reason):

```kdl
debug {
    disable-cursor-plane
}
```

Log in on a plain TTY (Ctrl+Alt+F2, etc.), then:

```
start_niri_nvidia
```

Logs go to `~/.local/state/niri/niri_<n>.log`. A header is written
out and `sync`'d before niri launches, so the log survives a kernel
panic.

## Running on non-NVIDIA hardware

The launcher script is named `start_niri_nvidia` on purpose: the
three NVIDIA-specific environment variables in it will cause problems
on AMD or Intel. If you are on Mesa, copy the script to a new name
and change these lines:

```
# Remove or leave unset.
# export GBM_BACKEND=nvidia-drm
# export __GLX_VENDOR_LIBRARY_NAME=nvidia

# AMD:
# export LIBVA_DRIVER_NAME=radeonsi
# Intel:
# export LIBVA_DRIVER_NAME=iHD
```

You can also drop `disable-cursor-plane` from your niri config on
AMD/Intel. The kernel panic it works around is NVIDIA-specific; on
other drivers the hardware cursor plane works correctly and saves a
tiny amount of GPU time.

Everything else in this fork (the drm fix, the polling fix, the
ConsoleKit call, the pipewire symbol rename) is not GPU-specific and
benefits every FreeBSD user regardless of hardware.

## Keeping up with upstream

We aim to rebase this fork onto upstream niri every few weeks. That
should be often enough to pick up new releases and bug fixes without
drowning in rebase churn. Just `git pull` from this repo and you get
whatever the latest rebased state is.

If that cadence is too slow for you and you want the very latest
niri right now, you can do the rebase yourself:

```
git remote add upstream https://github.com/niri-wm/niri.git
git fetch upstream
git rebase upstream/main
```

Expected conflict points on a rebase are `Cargo.toml`, `Cargo.lock`,
`resources/niri.desktop`, and `src/niri.rs`. Those are the four
tracked files this fork modifies in place. If the in-tree source
patch (`freebsd/patches/patch-no-systemd.patch`) stops applying
cleanly after a rebase because upstream shifted the surrounding
context, update the patch file to match.

When a pinned crate version moves upstream (e.g. niri bumps from
drm 0.14.2 to 0.15), delete the stale directory under
`freebsd/crates/`, update the matching `setup_crate` line in
`freebsd/apply.sh`, and port the patch over to the new version.
Full details and the sanity checks to run are in
[freebsd/GUIDE.md](freebsd/GUIDE.md).

If you get something working that is not on this repo yet, PRs are
welcome. If you hit a problem and cannot figure out what to update,
open an issue.

### About the rebase workflow and force-pushes

This fork uses rebase, not merge, to stay in sync with upstream niri.
Every few weeks we run `git rebase upstream/main` locally, which
replays our two FreeBSD commits on top of the new upstream tip. Each
replayed commit gets a new SHA because its parent has changed. The
result is a clean linear history with our two commits always sitting
right on top of a recent upstream, and no merge bubbles polluting
`git log`.

The cost is that `git push` cannot fast-forward after a rebase,
because `origin/main` still points at the old SHAs. So every rebase
is followed by `git push --force-with-lease origin main`. That is
expected, not an emergency.

What this means for people pulling from this repo:

- A plain `git pull` on a stale clone may produce "diverged" errors
  after a rebase. The safe fix is:
  ```
  git fetch origin
  git reset --hard origin/main
  ```
  This throws away your local `main` and replaces it with the
  freshly rebased one. Only do this if you have no local commits
  you care about on the branch.
- If you carry local changes on top of this fork, work on a branch
  other than `main` and rebase that branch onto `main` after each
  upstream sync: `git rebase main your-branch`. That keeps your work
  attached to whichever rebase is current.
- CI systems and mirrors pointed at this fork will see a
  non-fast-forward update after each sync. Configure them to accept
  that, or point them at specific tags instead of the branch tip.

If you would rather avoid rebases entirely, fork from an upstream
release tag and carry the patches in your own tree. This repo
prioritises a clean diff against upstream niri over a stable history.

## Full documentation

[`freebsd/GUIDE.md`](freebsd/GUIDE.md) has the long-form explanation
of every change, what upstream it came from, what goes wrong without
it, and what to do when each pinned version moves.

---

<h1 align="center"><img alt="niri" src="https://github.com/user-attachments/assets/07d05cd0-d5dc-4a28-9a35-51bae8f119a0"></h1>
<p align="center">A scrollable-tiling Wayland compositor.</p>
<p align="center">
    <a href="https://matrix.to/#/#niri:matrix.org"><img alt="Matrix" src="https://img.shields.io/badge/matrix-%23niri-blue?logo=matrix"></a>
    <a href="https://github.com/niri-wm/niri/blob/main/LICENSE"><img alt="GitHub License" src="https://img.shields.io/github/license/niri-wm/niri"></a>
    <a href="https://github.com/niri-wm/niri/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/niri-wm/niri?logo=github"></a>
</p>

<p align="center">
    <a href="https://niri-wm.github.io/niri/Getting-Started.html">Getting Started</a> | <a href="https://niri-wm.github.io/niri/Configuration%3A-Introduction.html">Configuration</a> | <a href="https://github.com/niri-wm/niri/discussions/325">Setup&nbsp;Showcase</a>
</p>

![niri with a few windows open](https://github.com/user-attachments/assets/535e6530-2f44-4b84-a883-1240a3eee6e9)

## About

Windows are arranged in columns on an infinite strip going to the right.
Opening a new window never causes existing windows to resize.

Every monitor has its own separate window strip.
Windows can never "overflow" onto an adjacent monitor.

Workspaces are dynamic and arranged vertically.
Every monitor has an independent set of workspaces, and there's always one empty workspace present all the way down.

The workspace arrangement is preserved across disconnecting and connecting monitors where it makes sense.
When a monitor disconnects, its workspaces will move to another monitor, but upon reconnection they will move back to the original monitor.

## Features

- Built from the ground up for scrollable tiling
- [Dynamic workspaces](https://niri-wm.github.io/niri/Workspaces.html) like in GNOME
- An [Overview](https://github.com/user-attachments/assets/379a5d1f-acdb-4c11-b36c-e85fd91f0995) that zooms out workspaces and windows
- Built-in screenshot UI
- Monitor and window screencasting through xdg-desktop-portal-gnome
    - You can [block out](https://niri-wm.github.io/niri/Configuration%3A-Window-Rules.html#block-out-from) sensitive windows from screencasts
    - [Dynamic cast target](https://niri-wm.github.io/niri/Screencasting.html#dynamic-screencast-target) that can change what it shows on the go
- [Touchpad](https://github.com/niri-wm/niri/assets/1794388/946a910e-9bec-4cd1-a923-4a9421707515) and [mouse](https://github.com/niri-wm/niri/assets/1794388/8464e65d-4bf2-44fa-8c8e-5883355bd000) gestures
- Group windows into [tabs](https://niri-wm.github.io/niri/Tabs.html)
- Configurable layout: gaps, borders, struts, window sizes
- [Gradient borders](https://niri-wm.github.io/niri/Configuration%3A-Layout.html#gradients) with Oklab and Oklch support
- [Animations](https://github.com/niri-wm/niri/assets/1794388/ce178da2-af9e-4c51-876f-8709c241d95e) with support for [custom shaders](https://github.com/niri-wm/niri/assets/1794388/27a238d6-0a22-4692-b794-30dc7a626fad)
- Live-reloading config
- Works with [screen readers](https://niri-wm.github.io/niri/Accessibility.html)

## Video Demo

https://github.com/niri-wm/niri/assets/1794388/bce834b0-f205-434e-a027-b373495f9729

Also check out this video from Brodie Robertson that showcases a lot of the niri functionality: [Niri Is My New Favorite Wayland Compositor](https://youtu.be/DeYx2exm04M)

## Status

Niri is stable for day-to-day use and does most things expected of a Wayland compositor.
Many people are daily-driving niri, and are happy to help in our [Matrix channel].

Give it a try!
Follow the instructions on the [Getting Started](https://niri-wm.github.io/niri/Getting-Started.html) page.
Have your [waybar]s and [fuzzel]s ready: niri is not a complete desktop environment.
Also check out [awesome-niri], a list of niri-related links and projects.

Here are some points you may have questions about:

- **Multi-monitor**: yes, a core part of the design from the very start. Mixed DPI works.
- **Fractional scaling**: yes, plus all niri UI stays pixel-perfect.
- **NVIDIA**: seems to work fine.
- **Floating windows**: yes, starting from niri 25.01.
- **Input devices**: niri supports tablets, touchpads, and touchscreens.
You can map the tablet to a specific monitor, or use [OpenTabletDriver].
We have touchpad gestures, but no touchscreen gestures yet.
- **Wlr protocols**: yes, we have most of the important ones like layer-shell, gamma-control, screencopy.
You can check on [wayland.app](https://wayland.app) at the bottom of each protocol's page.
- **Performance**: while I run niri on beefy machines, I try to stay conscious of performance.
I've seen someone use it fine on an Eee PC 900 from 2008, of all things.
- **Xwayland**: [integrated](https://niri-wm.github.io/niri/Xwayland.html#using-xwayland-satellite) via xwayland-satellite starting from niri 25.08.

## Media

[niri: Making a Wayland compositor in Rust](https://youtu.be/Kmz8ODolnDg?list=PLRdS-n5seLRqrmWDQY4KDqtRMfIwU0U3T) · *December 2024*

My talk from the 2024 Moscow RustCon about niri, and how I do randomized property testing and profiling, and measure input latency.
The talk is in Russian, but I prepared full English subtitles that you can find in YouTube's subtitle language selector.

[An interview with Ivan, the developer behind Niri](https://www.trommelspeicher.de/podcast/special_the_developer_behind_niri) · *June 2025*

An interview by a German tech podcast Das Triumvirat (in English).
We talk about niri development and history, and my experience building and maintaining niri.

[A tour of the niri scrolling-tiling Wayland compositor](https://lwn.net/Articles/1025866/) · *July 2025*

An LWN article with a nice overview and introduction to niri.

## Contributing

If you'd like to help with niri, there are plenty of both coding- and non-coding-related ways to do so.
See [CONTRIBUTING.md](https://github.com/niri-wm/niri/blob/main/CONTRIBUTING.md) for an overview.

## Inspiration

Niri is heavily inspired by [PaperWM] which implements scrollable tiling on top of GNOME Shell.

One of the reasons that prompted me to try writing my own compositor is being able to properly separate the monitors.
Being a GNOME Shell extension, PaperWM has to work against Shell's global window coordinate space to prevent windows from overflowing.

## Tile Scrollably Elsewhere

Here are some other projects which implement a similar workflow:

- [PaperWM]: scrollable tiling on top of GNOME Shell.
- [karousel]: scrollable tiling on top of KDE.
- [scroll](https://github.com/dawsers/scroll) and [papersway]: scrollable tiling on top of sway/i3.
- [hyprscrolling] and [hyprslidr]: scrollable tiling on top of Hyprland.
- [PaperWM.spoon]: scrollable tiling on top of macOS.

## Contact

Our main communication channel is a Matrix chat, feel free to join and ask a question: https://matrix.to/#/#niri:matrix.org

We also have a community Discord server: https://discord.gg/vT8Sfjy7sx

[PaperWM]: https://github.com/paperwm/PaperWM
[waybar]: https://github.com/Alexays/Waybar
[fuzzel]: https://codeberg.org/dnkl/fuzzel
[awesome-niri]: https://github.com/niri-wm/awesome-niri
[karousel]: https://github.com/peterfajdiga/karousel
[papersway]: https://spwhitton.name/tech/code/papersway/
[hyprscrolling]: https://github.com/hyprwm/hyprland-plugins/tree/main/hyprscrolling
[hyprslidr]: https://gitlab.com/magus/hyprslidr
[PaperWM.spoon]: https://github.com/mogenson/PaperWM.spoon
[Matrix channel]: https://matrix.to/#/#niri:matrix.org
[OpenTabletDriver]: https://opentabletdriver.net/
