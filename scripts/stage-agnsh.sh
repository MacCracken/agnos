#!/bin/bash
# stage-agnsh.sh — build + stage the agnoshi shell binary for inclusion on the
# agnos-fs as /bin/agnsh (1.41.x shell-separation arc).
#
# agnoshi is an OS-AGNOSTIC shell: the SAME source builds for whatever target the
# Cyrius toolchain provides. For agnos we build the CYRIUS_TARGET_AGNOS profile
# (agnos's sovereign syscall numbers + struct layouts), which landed at cyrius
# 6.0.55/56 — so this stages a binary that REALLY RUNS on the agnos kernel in
# ring 3.
#
# IMPORTANT: this stages ../agnoshi/build/agnsh_agnos (the --agnos build), NOT
# ../agnoshi/build/agnsh (the host CYRIUS_TARGET_LINUX build). The host binary is
# a perfectly good x86-64 static ELF but speaks the LINUX syscall ABI — deploying
# it to the agnos-fs makes /bin/agnsh crash on its first syscall in ring 3. The
# two are distinguishable by size (agnos ≈ 283 KB, host ≈ 297 KB) but the only
# reliable thing is to build the right one, which is what --build does here.
#
# Output: build/rootfs/bin/agnsh — the agnos-fs staging tree. fs-population
# consumes it three ways:
#   - QEMU smoke/sweep   : mke2fs -d build/rootfs ... (or e2cp/debugfs into the image)
#   - iron (--update-fs) : install-media.sh copies build/rootfs/* onto the agnos-fs by label
#   - iron (mount-modify): mount the agnos-fs from Linux, cp build/rootfs/bin/agnsh /bin/
#     (per feedback_prefer_mount_modify_over_reflash)
#
# Usage: scripts/stage-agnsh.sh [--build]
#   (default) stage the existing ../agnoshi/build/agnsh_agnos
#   --build   rebuild it first: cyrius build --agnos src/agnsh.cyr build/agnsh_agnos
#             (needs the lib/ snapshot; run `cyrius deps`/`cyrius update` in ../agnoshi if absent)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"
SRC="$AGNOSHI/build/agnsh_agnos"     # CYRIUS_TARGET_AGNOS build — NOT build/agnsh (host/Linux ABI)
DEST_DIR="$ROOT/build/rootfs/bin"
DEST="$DEST_DIR/agnsh"

[ -d "$AGNOSHI" ] || { echo "ERROR: agnoshi repo not found at $AGNOSHI (set AGNOSHI_ROOT)"; exit 1; }

if [ "${1:-}" = "--build" ]; then
    echo "Building agnsh (agnos target) in $AGNOSHI ..."
    [ -d "$AGNOSHI/lib" ] || { echo "ERROR: $AGNOSHI/lib snapshot missing — run 'cyrius deps' in agnoshi first"; exit 1; }
    ( cd "$AGNOSHI" && cyrius build --agnos src/agnsh.cyr build/agnsh_agnos ) \
        || { echo "ERROR: agnsh (agnos) build failed"; exit 1; }
fi

[ -f "$SRC" ] || { echo "ERROR: $SRC not present — run with --build (or 'cyrius build --agnos src/agnsh.cyr build/agnsh_agnos' in agnoshi)"; exit 1; }

# Sanity: must be a static x86_64 ELF (agnos exec-from-disk loads static ELF64 only).
DESC="$(file -b "$SRC" 2>/dev/null)"
case "$DESC" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $SRC is not a static x86-64 ELF64 ($DESC)"; exit 1 ;;
esac

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
SZ="$(stat -c%s "$DEST")"
echo "staged: $DEST ($SZ bytes)"
echo "  source: $SRC  (CYRIUS_TARGET_AGNOS — agnos-runnable)"
echo "  next:   fs-population copies build/rootfs/* onto the agnos-fs (smoke / install-media --update-fs / mount-modify)"
