#!/bin/bash
# burn-prep.sh — one command to stage the CURRENT kernel for an archaemenid
# iron burn (version-agnostic; the live burn target is whatever's open in
# state.md + the iron-nuc-zen-log tracker — currently the 1.44.x preemptive-
# scheduling arc, SMP-AP wake the riskiest item). It:
#   1. runs the full arc sweep (scripts/sweep.sh) — ALL gates must be green;
#      a red sweep aborts the prep (don't burn a broken tree);
#   2. builds build/agnos — the artifact you flash. DEFAULT is a BARE production
#      kernel (no compile-gated selftests). Set BURN_SELFTESTS=1 to bake the
#      EXEC_SELFTEST + EXT2_WRITE_SELFTEST validation suites back in;
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
echo "=== AGNOS burn-prep — stage the current kernel for an archaemenid iron burn ==="
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

# --- 2. Build the kernel -----------------------------------------------------
# Default is a BARE production kernel — no compile-gated selftests baked in. The
# selftest code stays in-tree (still #ifdef-gated in build.sh); it's just not
# ENABLED for the burn artifact now that the exec/EXT2 arc is iron-validated.
# Opt back in for a validation burn with BURN_SELFTESTS=1 (EXEC + EXT2 write).
if [ -n "${BURN_SELFTESTS:-}" ]; then
    echo "[2/2] Building the iron EXEC selftest kernel (BURN_SELFTESTS: EXEC_SELFTEST + EXT2_WRITE_SELFTEST)..."
    BUILD_ENV="EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1"
    BUILD_TAG="EXEC_SELFTEST"
else
    echo "[2/2] Building the BARE production kernel (no selftests — set BURN_SELFTESTS=1 to re-enable)..."
    BUILD_ENV=""
    BUILD_TAG="bare"
fi
if ! env $BUILD_ENV sh scripts/build.sh >/tmp/burn-prep-build.log 2>&1; then
    echo "burn-prep: BUILD-FAIL (see /tmp/burn-prep-build.log)"
    exit 1
fi

SZ="$(stat -c %s build/agnos 2>/dev/null)"
MT="$(stat -c %y build/agnos 2>/dev/null | cut -d. -f1)"
VER="$(cat VERSION 2>/dev/null)"
echo "  build/agnos: $SZ bytes, built $MT  (AGNOS $VER, $BUILD_TAG)"
echo ""

# --- Flash + watch instructions ---------------------------------------------
echo "=========================================="
echo "  IRON KERNEL READY — bare production AGNOS"
echo "=========================================="
echo ""
echo "  Flash (from agnosticos):  sh scripts/install-usb.sh --update"
echo "    (--update is ESP-only — the agnos-fs partition survives, per"
echo "     feedback_prefer_mount_modify_over_reflash)"
echo ""
echo "  The live burn rubric (hypothesis + falsification + watch-steps) lives in the"
echo "  OPEN cycle's tracker — read it before flashing, NOT a hardcoded list here (it"
echo "  would rot, per feedback_script_preambles_are_forward_looking). Source of truth:"
echo "    agnosticos/docs/development/iron-nuc-zen-log.md  (newest #tracker-*-cycle)"
echo ""
echo "  Current open cycle (1.44.x preemptive-scheduling) — watch the FB console for:"
echo "    smp: cpus online: N     (BSP + woken APs — the SMP-AP wake, the RISKIEST item)"
echo "    -> clean boot through 'Activating scheduler' to the agnsh '[ASSIST] >' prompt"
echo "  Dispositive: APs counted in + a typeable agnsh prompt on real Zen (no hang/reset)."
echo "    (1.44.21 made the wake fail-safe — a stuck IPI bounds-out instead of hanging.)"
echo "  Re-gate fallback if the wake hangs INSIDE the trampoline: comment the INIT-SIPI"
echo "  loop in smp_start_aps (one line; everything else is inert without it)."
echo "=========================================="
exit 0
