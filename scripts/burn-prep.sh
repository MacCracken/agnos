#!/bin/bash
# burn-prep.sh — one command to stage the CURRENT kernel for an archaemenid
# iron burn (version-agnostic; the live burn target is whatever's open in
# state.md + the iron-nuc-zen-log tracker — read the NEWEST #tracker-*-cycle
# for the hypothesis + rubric, never a cycle name hardcoded here). It:
#   1. runs the full arc sweep (scripts/sweep.sh) — ALL gates must be green;
#      a red sweep aborts the prep (don't burn a broken tree);
#   2. builds build/agnos — the artifact you flash. DEFAULT is a BARE production
#      kernel (no compile-gated selftests). Set BURN_SELFTESTS=1 to bake the
#      EXEC_SELFTEST + EXT2_WRITE_SELFTEST validation suites back in;
#   3. prints freshness (size + mtime) and the flash command, pointing at the
#      OPEN cycle's tracker in agnosticos/docs/development/iron-nuc-zen-log.md
#      for the watch rubric (kept OUT of this script so it can't rot).
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
if [ -n "${BURN_HDMI_SWEEP:-}" ]; then
    # THE MATRIX BURN. The register-value class is exhausted (every DCN reg matches amdgpu, still silent),
    # so stop testing one hypothesis per reflash. This kernel, post-sti with the HDA tone already streaming
    # to the HDMI sink, cycles gpu_hdmi_audio_profile(0..N): each applies a candidate structural/sequencing/
    # clock fix to the LIVE encoder, prints "hdmi-sweep: profile N = <name>", and holds ~3s. The operator
    # WATCHES serial + LISTENS — one boot tests the whole matrix. Adds HDMI_AUDIO_DUMP so the register state
    # of the LAST-applied profile is on record. PASS IS STILL THE OPERATOR'S EARS.
    echo "[2/2] Building the HDMI-audio MATRIX kernel (HDA_HDMI + HDA_TONE + HDMI_AUDIO_SWEEP + HDMI_AUDIO_DUMP: cycle every candidate fix in one boot; watch serial + listen for which profile makes sound)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_AUDIO_SWEEP=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_AUDIO_SWEEP+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_DUMP:-}" ]; then
    # THE MEASUREMENT BURN. Use this one for the display-audio arc until the silence is explained.
    #
    # Adds HDMI_AUDIO_DUMP on top of BURN_HDMI: reads the whole display-audio block back AFTER every write
    # has landed, in the same register order and naming as agnosticos/scripts/dump-dcn-audio.py, so agnos
    # can be diffed against the known-good MECHANICALLY instead of by argument.
    #
    # Capture the result with `run /bin/klug > /f/dump.txt` at the agnsh prompt, then mount agnos-fs from
    # Linux to copy it out. The line that matters most is NOT in the dump: gpu_hdmi_audio_crc_probe prints
    # whether samples PHYSICALLY traverse the encoder, which is the one question the register block cannot
    # answer about itself.
    #
    # PASS IS STILL THE OPERATOR'S EARS. Twelve burns read green while mute; the log line is not the oracle.
    echo "[2/2] Building the HDMI-audio MEASUREMENT kernel (HDA_HDMI + HDA_TONE + HDMI_AUDIO_DUMP: sovereign DCN audio path + audible sweep + the full register read-back for diffing against amdgpu's known-good)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI:-}" ]; then
    # HDA_HDMI: probe/route/stream instance 1 (04:00.1, the HDMI/DP digital sink) + the sovereign DCN
    # display-audio path (DIG mode, Azalia endpoint, AVI InfoFrame, audio DTO, PME wake). HDA_TONE: audible
    # sweep. Analog instance 0 keeps playing out the front jack.
    #
    # Gated because this path writes the encoder carrying the operator's only console and NO register on it
    # reports sink health — an HDMI source is transmit-only. The default/MVP kernel therefore never touches
    # DIG_MODE and cannot black-screen loop.
    #
    # For the display-audio arc prefer BURN_HDMI_DUMP above — it adds the register read-back.
    echo "[2/2] Building the HDMI-audio kernel (HDA_HDMI: sovereign DCN display-audio path on 04:00.1; HDA_TONE: audible sweep). Analog instance 0 still plays out the front jack."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE"
elif [ -n "${BURN_HDA_TONE:-}" ]; then
    echo "[2/2] Building the HDA_TONE first-tone kernel (hda_stream_arm fills a ~375 Hz triangle -> audible out the codec)..."
    BUILD_ENV="HDA_TONE=1"
    BUILD_TAG="HDA_TONE"
elif [ -n "${BURN_SELFTESTS:-}" ]; then
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

# --- PROVE THE FLAGS ACTUALLY LANDED IN THE ARTIFACT -------------------------
# A burn was wasted on 2026-07-15 because build/agnos was silently rebuilt WITHOUT these flags between
# burn-prep and the flash (scripts/check.sh line 24 runs build.sh with no BUILD_ENV, so ANY check.sh run
# after this point clobbers the burn artifact with a bare production kernel). The boot log looked normal —
# the HDMI-audio block simply was not there, and the tone went out the analog jack nobody has plugged in.
#
# So verify rather than trust. Each marker below is a string that exists ONLY inside the matching #ifdef
# block in main.cyr, so its presence proves the code is COMPILED AND REACHED.
#
# Do NOT verify with a string from an #ifdef'd FUNCTION BODY: gpu_hdmi_audio_crc_probe's own text is
# present in a bare production kernel too, because the function compiles and is simply never called. That
# is the exact trap this check exists to close — "a plain build compiles the code and never calls it".
verify_marker() {
    if ! grep -qa "$1" build/agnos; then
        echo ""
        echo "burn-prep: ARTIFACT-MISMATCH -- build/agnos does NOT contain '$1'"
        echo "  Expected it for BUILD_TAG=$BUILD_TAG. The flags did not land, or something rebuilt"
        echo "  build/agnos after the build (check.sh and test.sh both call build.sh with no BUILD_ENV)."
        echo "  DO NOT FLASH THIS. Re-run burn-prep and flash immediately, running nothing in between."
        exit 1
    fi
}
case "$BUILD_TAG" in *HDA_HDMI*)         verify_marker "ctl1 probing 2nd controller" ;; esac
case "$BUILD_TAG" in *HDA_TONE*)         verify_marker "sweep streaming" ;; esac
case "$BUILD_TAG" in *HDMI_AUDIO_DUMP*)  verify_marker "== agnos display-audio dump ==" ;; esac
case "$BUILD_TAG" in *HDMI_AUDIO_SWEEP*) verify_marker "hdmi-sweep: cycling" ;; esac

SZ="$(stat -c %s build/agnos 2>/dev/null)"
MT="$(stat -c %y build/agnos 2>/dev/null | cut -d. -f1)"
VER="$(cat VERSION 2>/dev/null)"
SUM="$(sha256sum build/agnos 2>/dev/null | cut -c1-16)"
echo "  build/agnos: $SZ bytes, built $MT  (AGNOS $VER, $BUILD_TAG)"
if [ "$BUILD_TAG" != "bare" ]; then
    echo "  markers verified: the $BUILD_TAG code is compiled AND reached (not merely present)."
fi

# Stamp the artifact so staleness is DETECTABLE rather than silent. `sh scripts/burn-verify.sh` re-checks
# this before a flash; a mismatch means something rebuilt build/agnos since burn-prep ran.
printf '%s\n%s\n%s\n%s\n' "$BUILD_TAG" "$SZ" "$VER" "$(sha256sum build/agnos | cut -d" " -f1)" > build/agnos.burn-tag
echo "  stamped build/agnos.burn-tag ($SUM...) -- re-check with: sh scripts/burn-verify.sh"
echo ""
echo "  !! Run NOTHING between here and the flash. check.sh / test.sh rebuild build/agnos"
echo "     WITHOUT these flags and will silently replace the burn artifact."
echo ""

# --- Flash + watch instructions ---------------------------------------------
echo "=========================================="
echo "  IRON KERNEL READY — AGNOS $VER ($BUILD_TAG)"
echo "=========================================="
echo ""
echo "  Flash (from agnosticos):  sudo ./scripts/install-media.sh --update"
echo "    (--update is ESP-only — the agnos-fs partition survives, per"
echo "     feedback_prefer_mount_modify_over_reflash)"
echo ""
echo "  The live burn rubric (hypothesis + falsification + watch-steps) lives in the"
echo "  OPEN cycle's tracker — read it before flashing, NOT a hardcoded list here (it"
echo "  would rot, per feedback_script_preambles_are_forward_looking). Source of truth:"
echo "    agnosticos/docs/development/iron-nuc-zen-log.md  (newest #tracker-*-cycle)"
echo ""
echo "  Baseline (cycle-agnostic): a clean boot to the agnsh '[ASSIST] >' prompt on real"
echo "  Zen, keyboard live, no hang / reset / canary bar. The OPEN cycle's tracker adds"
echo "  the dispositive FB line + falsification branches for THIS burn — read it (above)."
echo "=========================================="
exit 0
