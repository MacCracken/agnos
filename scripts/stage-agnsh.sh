#!/bin/bash
# stage-agnsh.sh — build + stage the agnoshi shell binary for inclusion on the
# agnos-fs as /bin/agnsh (1.41.x shell-separation arc).
#
# agnoshi is an OS-AGNOSTIC shell (zsh/bash-class portability): the same source
# builds for whatever target the Cyrius toolchain provides. Today that's
# CYRIUS_TARGET_LINUX (and _WIN) — Linux was simply the host target available to
# build against — so the binary this stages currently speaks the LINUX syscall
# ABI and will NOT execute on AGNOS's sovereign 28-syscall surface yet.
#
# >>> PREREQUISITE (cyrius-side, hands-off): a CYRIUS_TARGET_AGNOS stdlib syscall
# >>> profile (lib/syscalls_*_agnos.cyr emitting agnos syscall numbers + agnos
# >>> struct layouts) so `agnsh` can be rebuilt for the agnos ABI. Until that
# >>> lands, this script validates the STAGING MECHANISM (build → place on the
# >>> rootfs tree the fs-population steps consume); it does not produce a binary
# >>> that runs on agnos. See agnosticos docs/development/shell-separation-prior-art.md § ABI.
#
# Output: build/rootfs/bin/agnsh — the agnos-fs staging tree. fs-population
# consumes it three ways:
#   - QEMU smoke/sweep : mke2fs -d build/rootfs ... (or e2cp/debugfs into the image)
#   - iron (--update)  : install-usb.sh copies build/rootfs/* onto the ESP-adjacent fs
#   - iron (mount-modify): mount the agnos-fs from Linux, cp build/rootfs/bin/agnsh /bin/
#     (the preferred iron iteration path — feedback_prefer_mount_modify_over_reflash)
#
# Usage: scripts/stage-agnsh.sh [--build]
#   (default) stage the existing ../agnoshi/build/agnsh
#   --build   rebuild agnsh first via `cyrius build` (needs the lib/ snapshot;
#             run `cyrius deps` in ../agnoshi once if lib/ is absent)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"
SRC="$AGNOSHI/build/agnsh"
DEST_DIR="$ROOT/build/rootfs/bin"
DEST="$DEST_DIR/agnsh"

[ -d "$AGNOSHI" ] || { echo "ERROR: agnoshi repo not found at $AGNOSHI (set AGNOSHI_ROOT)"; exit 1; }

if [ "${1:-}" = "--build" ]; then
    echo "Building agnsh in $AGNOSHI ..."
    [ -d "$AGNOSHI/lib" ] || { echo "ERROR: $AGNOSHI/lib snapshot missing — run 'cyrius deps' in agnoshi first"; exit 1; }
    ( cd "$AGNOSHI" && cyrius build src/agnsh.cyr build/agnsh ) || { echo "ERROR: agnsh build failed"; exit 1; }
fi

[ -f "$SRC" ] || { echo "ERROR: $SRC not present — run with --build (or build agnsh in agnoshi)"; exit 1; }

# Sanity: must be a static x86_64 ELF (the agnos primary arch; exec-from-disk
# loads static ELF64 only — no dynamic linker exists).
DESC="$(file -b "$SRC" 2>/dev/null)"
case "$DESC" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $SRC is not a static x86-64 ELF64 ($DESC)"; exit 1 ;;
esac

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
SZ="$(stat -c%s "$DEST")"
echo "staged: $DEST ($SZ bytes)"
echo "  source: $SRC"
echo "  ABI:    LINUX (CYRIUS_TARGET_LINUX) — NOT yet agnos-runnable; pending CYRIUS_TARGET_AGNOS"
echo "  next:   fs-population copies build/rootfs/* onto the agnos-fs (smoke / install-usb / mount-modify)"
