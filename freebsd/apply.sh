#!/bin/sh
# Apply FreeBSD build patches to this niri checkout.
#
# Run once after cloning, and again after any `git pull`. The post-merge
# hook in .git/hooks/ runs this automatically.
#
# This script does three things:
#   1. Applies patches to niri source files that live in the niri repo.
#   2. Copies the cargo-registry source of a few upstream crates into
#      freebsd/crates/ and patches them for FreeBSD. Cargo is pointed
#      at these via [patch.crates-io] in the workspace Cargo.toml.
#   3. Ensures [patch.crates-io] is present in Cargo.toml (it may get
#      dropped on a rebase).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CRATES_DIR="$SCRIPT_DIR/crates"
PATCHES_DIR="$SCRIPT_DIR/patches"

cd "$PROJECT_DIR"

echo "=== Applying FreeBSD patches for niri ==="

# 1. niri source patches.
#
# We deliberately do not apply patch-udev. That patch is in the FreeBSD
# ports tree to work around a broken DRM node type detection, but our
# patch-drm fixes the detection properly. With the ports udev patch
# still applied on top, niri processes the render node as if it were a
# primary node, which triggers an NVIDIA kernel driver bug and panics
# the kernel. See freebsd/GUIDE.md for the full story.
for patch in patch-no-systemd.patch; do
    if patch -p1 -N --dry-run < "$PATCHES_DIR/$patch" >/dev/null 2>&1; then
        echo "Applying $patch"
        patch -p1 -N --no-backup-if-mismatch < "$PATCHES_DIR/$patch"
    elif patch -p1 -R --dry-run < "$PATCHES_DIR/$patch" >/dev/null 2>&1; then
        echo "$patch already applied, skipping"
    else
        echo "WARNING: $patch did not apply cleanly. Upstream may have touched the same lines; update the patch file."
    fi
done

# 2. Patched crates. We copy the pristine source out of the cargo
# registry cache and patch it in place. Cargo later picks these up via
# [patch.crates-io].
REGISTRY_SRC="$(find ~/.cargo/registry/src -maxdepth 1 -name 'index.crates.io-*' 2>/dev/null | head -1)"

setup_crate() {
    crate="$1"
    patchfile="$2"

    if [ -d "$CRATES_DIR/$crate" ]; then
        echo "$crate already set up, skipping"
        return
    fi

    if [ -z "$REGISTRY_SRC" ] || [ ! -d "$REGISTRY_SRC/$crate" ]; then
        echo "Cargo registry cache missing, running cargo fetch"
        cargo fetch
        REGISTRY_SRC="$(find ~/.cargo/registry/src -maxdepth 1 -name 'index.crates.io-*' | head -1)"
    fi

    echo "Setting up patched $crate"
    mkdir -p "$CRATES_DIR"
    cp -R "$REGISTRY_SRC/$crate" "$CRATES_DIR/$crate"
    ( cd "$CRATES_DIR/$crate" && patch -p1 --no-backup-if-mismatch < "$PATCHES_DIR/$patchfile" )
}

setup_crate "drm-0.14.1"         "patch-drm.patch"
setup_crate "pipewire-0.9.2"     "patch-pipewire.patch"
setup_crate "pipewire-sys-0.9.2" "patch-pipewire-sys.patch"
setup_crate "polling-3.11.0"     "patch-polling.patch"

# 3. Make sure Cargo.toml points cargo at the patched crates.
if ! grep -q '\[patch.crates-io\]' Cargo.toml; then
    echo "Adding [patch.crates-io] to Cargo.toml"
    cat >> Cargo.toml << 'EOF'

# FreeBSD: use locally patched crates, set up by freebsd/apply.sh.
[patch.crates-io]
drm = { path = "freebsd/crates/drm-0.14.1" }
pipewire = { path = "freebsd/crates/pipewire-0.9.2" }
pipewire-sys = { path = "freebsd/crates/pipewire-sys-0.9.2" }
polling = { path = "freebsd/crates/polling-3.11.0" }
EOF
elif ! grep -q 'polling.*freebsd/crates' Cargo.toml; then
    sed -i '' '/\[patch.crates-io\]/a\
polling = { path = "freebsd/crates/polling-3.11.0" }' Cargo.toml
    echo "Added polling to existing [patch.crates-io]"
fi

echo "=== Done ==="
echo "Build with:  cargo build --release --no-default-features --features dbus,xdp-gnome-screencast"
