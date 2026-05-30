#!/bin/bash
# burn-prep.sh — one command to get archaemenid-ready for the combined
# 1.39.x VFS + 1.40.x exec iron burn. It:
#   1. runs the full arc sweep (scripts/sweep.sh) — ALL gates must be green;
#      a red sweep aborts the prep (don't burn a broken tree);
#   2. builds the iron EXEC selftest kernel (EXEC_SELFTEST + EXT2_WRITE_SELFTEST)
#      as build/agnos — the artifact you flash for track A (exec-from-disk);
#   3. prints freshness (size + mtime) and the exact flash + watch steps,
#      pointing at docs/development/exec-iron-manual-tests.md (in agnosticos).
#
# Track B (FAT/exFAT verb burn) uses SEPARATE selftest kernels — this script
# prints the build lines for them but leaves build/agnos as the track-A kernel
# (the dispositive burn). Build freshness is Claude's ([[feedback_build_freshness_is_mine]]).
#
# Usage:  sh scripts/burn-prep.sh           (sweep + build iron kernel)
#         SKIP_SWEEP=1 sh scripts/burn-prep.sh   (skip the sweep — build only)
#
# Exit 0 iff the sweep is green (or skipped) AND the iron kernel built.
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

set -u

echo ""
echo "=== AGNOS burn-prep — 1.39.x VFS + 1.40.x exec iron burn ==="
echo ""

# --- 1. Sweep gate -----------------------------------------------------------
if [ -z "${SKIP_SWEEP:-}" ]; then
    echo "[1/2] Running the arc sweep (must be all-green before a burn)..."
    if ! sh scripts/sweep.sh; then
        echo ""
        echo "burn-prep: ABORT — the sweep is RED. Fix it before flashing iron."
        echo "           (per [[feedback_iron_burns_block_other_work]] a burn is expensive — don't waste it on a known-broken tree)"
        exit 1
    fi
    echo ""
else
    echo "[1/2] Sweep SKIPPED (SKIP_SWEEP set)."
    echo ""
fi

# --- 2. Build the iron EXEC selftest kernel (the track-A artifact) -----------
echo "[2/2] Building the iron EXEC selftest kernel (EXEC_SELFTEST + EXT2_WRITE_SELFTEST)..."
if ! env EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1 sh scripts/build.sh >/tmp/burn-prep-build.log 2>&1; then
    echo "burn-prep: BUILD-FAIL (see /tmp/burn-prep-build.log)"
    exit 1
fi

SZ="$(stat -c %s build/agnos 2>/dev/null)"
MT="$(stat -c %y build/agnos 2>/dev/null | cut -d. -f1)"
VER="$(cat VERSION 2>/dev/null)"
echo "  build/agnos: $SZ bytes, built $MT  (AGNOS $VER, EXEC_SELFTEST)"
echo ""

# --- Flash + watch instructions ---------------------------------------------
echo "=========================================="
echo "  IRON KERNEL READY — track A (exec-from-disk)"
echo "=========================================="
echo ""
echo "  Flash (from agnosticos):  sh scripts/install-usb.sh --update"
echo "    (--update is ESP-only — the agnos-fs partition survives, per"
echo "     [[feedback_prefer_mount_modify_over_reflash]])"
echo ""
echo "  On boot, watch the FB console for (track A):"
echo "    exec: running /notelf        -> run: not an executable   (ENOEXEC)"
echo "    exec: running /bin/prog2     -> EXEC-DISK-OK / run: exit 42"
echo "    exec: running /bin/argv Z    -> run: exit 90              (argv[1] deref)"
echo "    exec: selftest done"
echo "  Dispositive bar: EXEC-DISK-OK + run: exit 42 on real Zen."
echo "  (2 real execs/boot — a 3rd exhausts the 2 MB-page pool; teardown is a follow-on.)"
echo ""
echo "  Track B (FAT/exFAT verbs) — SEPARATE flashes, non-ESP USB data stick:"
echo "    FATFS_WRITE_SELFTEST=1 sh scripts/build.sh   # FAT32 stick"
echo "    EXFAT_WRITE_SELFTEST=1 sh scripts/build.sh   # exFAT stick"
echo ""
echo "  Full checklist: agnosticos/docs/development/exec-iron-manual-tests.md"
echo "=========================================="
exit 0
