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
# Usage:  sh scripts/burn/burn-prep.sh           (sweep + build iron kernel)
#         SKIP_SWEEP=1 sh scripts/burn/burn-prep.sh   (skip the sweep — build only)
#
# Exit 0 iff the sweep is green (or skipped) AND the iron kernel built.
# ⚠ TWO levels up: this script lives in scripts/burn/ since the 1.56.22 split. It was left at one
# level and so cd'd into scripts/, where `scripts/sweep.sh` does not exist — the sweep gate reported
# "the sweep is RED" and aborted every burn. This is category 2 from
# docs/development/planning/scripts-reorg.md ("paths computed INSIDE a script"), which that document
# warns is invisible to a grep for the script's own name; the 123-script fix pass missed this one,
# and it is the single script a burn cannot proceed without.
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"

set -u

echo ""
echo "=== AGNOS burn-prep — stage the current kernel for an archaemenid iron burn ==="
echo ""

# --- 0. INVALIDATE THE OLD ARTIFACT BEFORE ANYTHING CAN ABORT -----------------------------------------
# ⛔⛔ A BURN WAS LOST TO THIS ON 2026-08-02: the operator ran burn-prep, flashed, and booted a kernel
# that auto-ran DOOM. `build/agnos` was a DOOM_SELFTEST kernel from the PREVIOUS DAY. Every abort path
# in this script exits WITHOUT touching build/agnos, so a prep that stops early leaves yesterday's
# kernel sitting exactly where the flash step looks for it — and it is not obviously stale, because it
# is a working kernel that boots.
#
# ⛔ AND burn-verify.sh CANNOT CATCH THAT, BY CONSTRUCTION. It compares the binary against its OWN
# stamp, so yesterday's kernel next to yesterday's stamp reports "Safe to flash." It was built to catch
# check.sh/test.sh REBUILDING the artifact after prep — the opposite direction — and it does that well.
# A stale-but-self-consistent pair sails straight through it.
#
# ⭐ THE FIX IS TO MAKE ABSENCE THE FAILURE MODE. Delete the artifact and its stamp up front: if this
# script aborts for any reason, there is now NOTHING to flash, burn-verify says "no build/agnos", and
# the operator is stopped by a missing file instead of misled by a working one. A burn costs a reboot
# of the operator's only machine; a missing file costs a second.
rm -f "$ROOT/build/agnos" "$ROOT/build/agnos.burn-tag"

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
#
# --- THE PER-ARM REQUIRED-FLAG DECLARATION ------------------------------------------------------------
# ⛔⛔ READ THIS BEFORE ADDING AN ARM THAT TOUCHES DISPLAY AUDIO OR THE MODESET TRANSMIT OP.
#
# Every arm below may set BUILD_REQUIRE to the list of flags its experiment CANNOT RUN WITHOUT. The list
# is checked against that arm's own BUILD_ENV before anything builds, and a missing flag aborts the prep
# in a second instead of costing a flash, a boot and an adjudication.
#
# WHY IT IS A PER-ARM DECLARATION AND NOT A GLOBAL RULE: the required set genuinely differs per arm, and
# a blanket "every HDA_HDMI arm needs GPU_AUDIO_PROBE" would be wrong for BURN_HDMI_ATOM_HALT, which
# freezes the framebuffer BEFORE the audio enable is ever called. A rule that is wrong for one arm gets
# worked around, and then it protects none of them.
#
# ⇒ THE STANDING RULE, paid for three burns in a row on 2026-07-31 (HDMI_ATOM -> +HDA_HDMI ->
#   +GPU_AUDIO_PROBE, one flash each): an arm that touches the audio path DECLARES its required set. The
#   sentinel after the chain refuses to build an HDA_HDMI / HDMI_ATOM arm that declares nothing at all,
#   so "someone remembers" is no longer part of the mechanism.
BUILD_REQUIRE=""
# --- 1.56.x SHADER arc arms ---------------------------------------------------
# ⚠ These were MISSING until 1.56.4. Every 1.56.x shader burn (S1/D0, S2, grid, guard, coverage, glyph,
# gradient) was reproduced by hand-exporting a define straight to build.sh, which bypasses this script's
# banner + BUILD_TAG stamp — so the burn artifact carried no record of which arm produced it. That is
# exactly the failure the standing rule ("every #ifdef bite names its BURN_* flag in burn-prep.sh, and you
# verify by `cmp`-ing the two binaries, not by the burn tag") exists to prevent. Arms added retroactively.
if [ -n "${BURN_CRCCAL:-}" ]; then
    # 1.56.34 — the AFMT audio-CRC NULL calibration (`run /bin/modeset --crccal`).
    # ⛔⛔ THIS ARM EXISTS BECAUSE ITS ABSENCE COST A BURN ON 2026-07-31. The experiment was prepped as a
    # BARE kernel; `gpu_hdmi_audio_enable()` is only ever CALLED inside `#ifdef HDMI_ATOM` (main.cyr), so
    # the entire audio path was compiled out, `gpu_hdmi_audio_on` was 0, and the op refused before taking
    # a single measurement. The subject of the experiment was not in the build.
    # ⇒ This is the standing rule stated in this very file — *every #ifdef bite names its BURN_* flag in
    # burn-prep.sh* — and it was broken in the same cut whose CHANGELOG documents ATOM_RUN_PIXCLK being
    # referenced in three places and declared in none. Naming the flag HERE is what makes the arm real.
    # ⚠ HDMI_ATOM only. NOT MODESET_AUDIO (that suppresses the boot-time enable so the #93 op owns
    # staging/unmute — the calibration needs the audio path UP at boot, which is the default branch) and
    # NOT ATOM_RUN_TRANSMITTER/ATOM_TX_CYCLE (the calibration touches no PHY and must not).
    # Oracle: `run /bin/modeset --crccal` -> exit 95 and a VERDICT block in klug. Exit 96 now says WHICH
    # of "built without HDMI_ATOM" and "hardware refused" it hit; before this arm it could not.
    # ⛔⛔ AND THE FIRST VERSION OF THIS ARM WAS *STILL* WRONG — it set HDMI_ATOM alone, and burn 2 came
    # back "HDMI_ATOM is in this build, but the audio path did NOT come up on this hardware". The HDMI
    # controller is enumerated under a DIFFERENT flag: `HDA_HDMI` gates the instance-1 probe in main.cyr,
    # and without it there is no HDMI HDA controller, no codec, and nothing for the DCN side to bind to.
    # ⚠ ELEVEN existing audio arms in this file all set HDA_HDMI=1. Mine was the twelfth and the only one
    # without it — a pattern that was there to be read.
    # ⭐ HDA_TONE IS REQUIRED HERE AND IT IS NOT DECORATION: it fills the PCM ring with a ~375 Hz triangle
    # instead of SILENCE. Without it the calibration's FLOW phase carries zero samples, so `CRC=0` in F
    # would be indistinguishable from the null — the op would fail at precisely the ambiguity it exists to
    # resolve, and would report "not flow-gated" from an artifact of its own build.
    # ⛔ The "do NOT pair with HDA_TONE" warning on MODESET_AUDIO does NOT apply here. It exists because a
    # fixed kernel sine is exactly guessable and would void a BLINDED EAR oracle. This calibration has no
    # ear oracle at all — it is entirely source-side. Do not transplant that warning by pattern-match.
    # ⛔⛔⛔ AND A *FOURTH* FLAG, FOUND BY BURN 3: `GPU_AUDIO_PROBE`. It gates `gpu_audio_probe()`, which is
    # the only thing that sets `gpu_audio_dig` / `gpu_audio_dp`. Without it `gpu_audio_dig` stays -1 and
    # `gpu_hdmi_preflight()` refuses at a SILENT early return — the boot prints only "preflight refused"
    # with no reason, and the audio path never comes up however correct everything downstream is.
    # ⚠⚠ THIS IS NOT JUST MY ARM — IT SILENTLY BROKE EVERY AUDIO ARM IN THIS FILE. The probe ran on every
    # boot until it was gated at 1.56.25 (it was printing per-endpoint hex on production boots), and
    # NOTHING added the new flag to the arms that depend on it. The 0724 M9 capture shows `display audio
    # path is HDMI on dig 1` -> `hdmi flip preconditions met` because back then the probe was ungated.
    # ⇒ **Any HDMI-audio burn taken since 1.56.25 would have been void**, and the arc paused for the 3D
    # and modeset work immediately after, so nobody discovered it.
    # ✅ THAT AUDIT IS DONE (1.56.34): all 16 arms reviewed, 13 fixed, 2 deliberately left without the flag
    # (BURN_HDMI_ATOM_HALT, BURN_HDA_TONE — each says why in its own comment). ⭐ It also turned up three
    # arms with NO audio in them at all: the M-lane transmitter arms gate on gpu_audio_dig too, via
    # mdo_transmit_run(). Do not assume "audio arm" and "needs the probe" are the same set in either
    # direction — read the arm.
    #
    # ⭐ THE REQUIRED-FLAG ASSERTION EXISTS BECAUSE THREE BURNS WERE SPENT DISCOVERING THIS SET ONE FLAG AT
    # A TIME (HDMI_ATOM -> +HDA_HDMI -> +GPU_AUDIO_PROBE). Each burn refused for a real reason and each
    # reason was a MISSING BUILD FLAG, not the machine. The declared list is checked at PREP time, so the
    # next omission fails in a second instead of on iron.
    # ⇒ GENERALISED 1.56.34: this used to be a CRCCAL-only variable with its own inline loop, which meant
    # exactly one arm in the file was protected. It is now the shared BUILD_REQUIRE contract declared at the
    # top of this chain and enforced once after it, so every arm states its own required set.
    BUILD_REQUIRE="HDA_HDMI HDMI_ATOM HDA_TONE GPU_AUDIO_PROBE"
    echo "[2/2] Building the 1.56.34 CRCCAL kernel ($BUILD_REQUIRE; run /bin/modeset --crccal; capture klug > crccal.txt)."
    BUILD_ENV="HDA_HDMI=1 HDMI_ATOM=1 HDA_TONE=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="CRCCAL"
elif [ -n "${BURN_SHADER_OPS:-}" ]; then
    # 1.56.4 — FOUR proofs in ONE boot. Burns block the operator's machine, so this arm deliberately
    # bundles everything the realignment owes rather than spending four boots:
    #   A1  #92 gpu_shader_op descriptor seam (plan S8 / D-3)  -> run /bin/gpublend, /bin/gpucov
    #   A2  coverage RE-PROOF — mandatory: both cov call sites passed 11 args to a 12-parameter
    #       dispatcher until 1.56.4, so the RSRC1 the kernel ran with was whatever `gx` happened to be,
    #       and done_phys was undefined (a wild kernel store). The 1.56.3 proof is void.
    #   A3  glyph first iron        A4  gradient first iron  (both built at 1.56.3, never burned)
    # Boot selftests print and continue on failure, and every dispatch is watchdog-bounded, so one bad
    # arm should not cost the others.
    #
    # ⚠ WHAT THIS BOOT DOES *NOT* PROVE: the lazy-arm path for cov/glyph/grad. Their selftests write the
    # SAME arena slot their gpu_*_arm() uses, so a slot is already populated by the time #92 runs. It is
    # NOT a false pass — gpu_*_armed is never set by a selftest, so the arm still executes its own upload
    # and its own gates — but the bare-kernel case is untested here. blend_rect IS clean: its selftest
    # uses 0x14000 while #92 uses 0x50000, so /bin/gpublend exercises the real lazy arm.
    # Follow-up (cheap, no new code): one production-shape boot — BUILD_ENV="" — running the same two
    # binaries. Do it only after this burn is green.
    #
    # ⚠ NEEDS the tests/gpu binaries on the agnos-fs: scripts/burn/stage-tools.sh --build (wired 1.56.4).
    # Oracle: `run /bin/gpublend` and `run /bin/gpucov` -> `run: exit 95`. A #92 failure decodes as
    # 110 + reason (111 no-GPU · 113 bad-slot · 115 off-screen · 117 not-resident · 118 dispatch-timeout ·
    # 121 bad-descriptor · 122 reserved-field · 123 envelope-unproven). CAPTURE: klug > shader_ops.txt.
    # ⚠ SHADER_BLEND=1 IS LOAD-BEARING HERE, NOT DECORATION. gpu_shader_cov_test and gpu_shader_rect_test
    # both open with `if (gpu_blend_ok != 1) { "skipping ... (blend math unproven)"; return 0; }`, and
    # gpu_blend_ok is set ONLY by gpu_shader_blend_test under #ifdef SHADER_BLEND. So SHADER_COV=1 without
    # SHADER_BLEND=1 is a SILENT NO-OP — it prints "gpu: skipping coverage" and burns a boot. That is
    # exactly what happened on the first 1.56.4 burn (2026-07-22): glyph and gradient passed, coverage
    # never ran. The flag pair is a dependency; do not split it.
    echo "[2/2] Building the 1.56.4 SHADER-OPS kernel (#92 descriptor seam + cov re-proof + glyph/grad first iron; run /bin/gpublend + /bin/gpucov; capture klug > shader_ops.txt)."
    BUILD_ENV="SHADER_BLEND=1 SHADER_COV=1 SHADER_GLYPH=1 SHADER_GRAD=1"
    BUILD_TAG="SHADER_OPS"
elif [ -n "${BURN_SHADER_BATCH:-}" ]; then
    # plan-S12 — the ONE-SUBMISSION batched frame. The arc's stated CLOSING CONDITION, and the payoff
    # decision D-3 was made for: because #92 was specified as an ARRAY of ops from day one, batching is an
    # implementation change rather than an ABI break.
    #
    # Composites the same six-op mock frame twice from an identical underlay — op-by-op (six submissions)
    # then batched (one) — and compares the two PIXEL FOR PIXEL:
    #   'gpu: batch frame seq <N> us  batched <M> us'
    #   'gpu: batched frame pixel-identical to op-by-op (6 ops, 1 submission)'
    #
    # ⚠ READ THE RESULT THE WAY THE PLAN WROTE IT: "a batched frame that is NOT faster means the fence was
    # never the wall, and that finding is the deliverable." This path is MEMORY-bound by the arc's own
    # calibration (12 B/pixel, ~25 MB for a full-screen 1080p blend), so a large speedup is NOT the expected
    # outcome and would be worth distrusting. PIXEL-IDENTITY is the gate; the two timings are a measurement.
    # ⚠ The timings only mean anything because plan-S12a tightened the completion poll first — before that,
    # every dispatch was quantised to a 100 us sleep and a batch would have looked ~5x better for free.
    # CAPTURE: klug > shader_batch.txt. No photo needed; the oracle is a pixel count.
    echo "[2/2] Building the plan-S12 SHADER-BATCH kernel (one-submission frame vs op-by-op; capture klug > shader_batch.txt)."
    BUILD_ENV="SHADER_BATCH=1"
    BUILD_TAG="SHADER_BATCH"
elif [ -n "${BURN_SHADER_PERM:-}" ]; then
    # plan-S4 — the v_perm_b32 BYTE CROSSBAR + the VOP3P PACKED blend. The last un-started ladder item: the
    # tree had zero v_perm_b32 and zero v_pk_* through eleven bites while the arc's own scope list called
    # the RGBX<->BGRX channel swap "an unhandled case, not just a slow one".
    # Carries SHADER_BLEND because the f32 kernel is the packed blend's ORACLE, not merely its gate.
    #
    # Three sub-proofs, all bit-exact, all in one boot:
    #   perm control run (identity selector)  -> 'gpu: perm lanes stored 64 of 64'
    #   perm swap run    (0x03000102)         -> 'gpu: perm byte crossbar online (identity and channel swap, 64 px)'
    #   packed blend vs f32, SAME data        -> 'gpu: packed blend bit-identical to float blend (64 px)'
    #                                            + 'gpu: packed blend valu per pixel 27 float 31'
    #
    # ⚠ Two silent-wrong-VALUE failure modes to read for, neither of which faults:
    #   'green or alpha wrong, check the packed shift lane select' = the op_sel_hi:[0,1] modifier was lost;
    #      it corrupts 98.2% of pixels but ONLY the high u16 lane (G and A), and renders as a plausible
    #      image with a colour cast.
    #   'perm unpack repack wrong' on the CONTROL run = v_perm_b32's byte pool is reversed from the written
    #      operand order (S1 is the LOW dword); a swapped pair permutes a stale VGPR and reads as "the
    #      shader is broken" rather than "the operands are backwards".
    # The bit-identity claim is exhaustively established off-iron (0 mismatches over all 8,421,376
    # premultiplied triples), so ANY deviation here is a real hardware or encoding fault, not rounding.
    # CAPTURE: klug > shader_perm.txt. No photo needed — every oracle is numeric.
    echo "[2/2] Building the plan-S4 SHADER-PERM kernel (v_perm_b32 crossbar + VOP3P packed blend; capture klug > shader_perm.txt)."
    BUILD_ENV="SHADER_BLEND=1 SHADER_PERM=1"
    BUILD_TAG="SHADER_PERM"
elif [ -n "${BURN_SHADER_COHERE:-}" ]; then
    # plan-S3 — the four-arm GL2/scanout/CP-DMA coherence characterisation, in ONE boot. The bite the arc
    # plan made a gate and execution never ran. Needs NO other shader flag: it drives the RUNTIME arm
    # (gpu_blend_arm), not a boot selftest, so it is unaffected by the SHADER_BLEND dependency.
    #
    # Reads as a table in klug, six rows:
    #   S3-A shader->fb  WB=on   S3-B shader->fb  WB=off      (CPU readback; PANEL scored from the photo)
    #   S3-C shader->cpdma WB=on / WB=off                     (does an MC-direct read see GL2 stores?)
    #   S3-D cpdma->shader INV=on / INV=off                   (does a GL2 read see MC-direct writes?)
    # Plan's expectation: A pass · B FAIL · C needs the write-back · D needs the invalidate. ⚠ ANY deviation
    # is a hardware fact worth more than the bite — do not "fix" a surprising row, record it.
    # ⚠ A passing B does NOT prove the write-back is useless; it proves GL2 drained inside the measurement
    # window. Absence of a flush is not a guarantee of staleness.
    # PHOTO IS DISPOSITIVE for the panel half: two 64x64 tiles side by side at (96,380) and (240,380) over a
    # near-black underlay — left = write-back ON, right = OFF. A dark right tile beside a white left tile is
    # the display-visibility answer the CPU readback cannot give.
    # CAPTURE: klug > shader_cohere.txt, and one photo of the two tiles.
    echo "[2/2] Building the plan-S3 SHADER-COHERE kernel (four-arm GL2/scanout/CP-DMA coherence; capture klug > shader_cohere.txt + ONE photo of the two tiles)."
    BUILD_ENV="SHADER_COHERE=1"
    BUILD_TAG="SHADER_COHERE"
elif [ -n "${BURN_SHADER_GRAD:-}" ]; then
    # plan-S11 — vertical linear gradient, no source buffer. Oracle: 'gpu: shader gradient online'.
    echo "[2/2] Building the plan-S11 SHADER-GRAD kernel (linear gradient; capture klug > shader_grad.txt)."
    BUILD_ENV="SHADER_GRAD=1"
    BUILD_TAG="SHADER_GRAD"
elif [ -n "${BURN_SHADER_GLYPH:-}" ]; then
    # plan-S9 — 1bpp -> 32bpp glyph expansion, transparent background. Highest call-count site in the
    # desktop tree. Oracle: 'gpu: shader glyph expand online'. CAPTURE: klug > shader_glyph.txt.
    echo "[2/2] Building the plan-S9 SHADER-GLYPH kernel (1bpp glyph expand; capture klug > shader_glyph.txt)."
    BUILD_ENV="SHADER_GLYPH=1"
    BUILD_TAG="SHADER_GLYPH"
# ⛔ REMOVED 1.56.25 — the BURN_EDGE_PROBE / EDGE_CAP_PROBE profile. IT WAS A TRAP THAT COULD COST A BURN.
# It advertised "raises GPU_EDGE_CAP 64 -> 256 for the above-cap sweep", but NO kernel source has ever
# carried an `#ifdef EDGE_CAP_PROBE` — `GPU_EDGE_CAP = 256` is an unconditional constant (gpu.cyr). So
# `EDGE_CAP_PROBE=1` produced a kernel BYTE-IDENTICAL to the default while the profile told the operator
# it was something else, and its own note conceded `strings` could not tell them apart.
# ⭐ It is also OBSOLETE, not merely dead: the measurement it existed to enable ALREADY RAN (B10). The
# shipped cap IS 256, and the real bound is no longer a cap at all — it is the measured work product
# GPU_EDGE_WORK_MAX (w*h*n_edges, 28.8 us + 0.0005953*(w*h)*ne, linear in E to ~2.6% across 4..256).
# The cap moved on measurement exactly as intended; nobody removed the scaffolding afterwards.
elif [ -n "${BURN_TEX_RGBA:-}" ]; then
    # ============================================================================================
    # 3D ARC RUNG 13 — TEXTURING'S FIRST CONTACT WITH SILICON.
    # ============================================================================================
    # ⚠ NO COMPILE FLAG. gpu_tex_arm / gpu_tri_tex are UNCONDITIONAL. This mode carries the BRIEF.
    #
    # ⭐ WHAT IS ALREADY PROVEN AT ZERO BURNS, so a red does NOT re-open it:
    #   * the ABI — 57 of 57 cases in QEMU, both formats, the bidirectional LUT rule, every reject
    #   * the algorithm — texmodel byte-diffs it against texcore at register widths: 0 differing
    #     bytes over 7 frames x 32x32 px x 3 coverages, in BOTH formats, with four falsification
    #     gates including the signed-high-dword slip that cost rung 11 four burns
    #   * the blob — shader-blob.sh reports 426 dwords matching the assembled source
    #   * the arena — 53 slots with declared extents, 0 overlaps
    #   * RSRC2 = 0x00000190, byte-identical to the coverage kernel's, so the shipped dispatcher
    #     issues this blob with no PM4 change
    #
    # ⛔ WHAT IS *NOT* PROVEN AND IS THE POINT OF THIS FLASH: that the EMISSION does what the model
    # does. Two assemblers agree on rung 11's blob; here only llvm-mc has been run, so a red is
    # genuinely open between encoding and the instruction sequence.
    # ⛔ THE INSTRUMENT IS NOT ABOVE SUSPICION. Four of this arc's reds were gputri's own defects.
    #
    # RUN IN THIS ORDER:
    #   1. run /bin/gputri --cov     rung 9b regression: the rasteriser must STILL be 20/20.
    #   2. run /bin/gputex           rung 13. Its FIRST case is the absolute test.
    #   3. run /bin/klug > /tex1.txt
    #
    # PRE-REGISTERED OUTCOME TABLE:
    #   95  every rendered pixel byte-identical to texcore in BOTH formats. Rung 13 closes.
    #   85  pixels differ. ⭐ READ THE LOCATED `diff case ... x= y= cov= want= got=` LINES.
    #         case 0 (1:1) differing        -> addressing or the texel-centre convention; the
    #                                          absolute test failing means the fetch is wrong, not
    #                                          the interpolation
    #         case 0 exact, case 1 differing-> the fractional path: texel-centre +0.5, or the
    #                                          quotient/correction
    #         RGBA8 exact, IDX8 differing   -> the LUT indirection only; the UV path is fine
    #         cov=0 but got != 0xFF101010   -> the shader wrote OUTSIDE the coverage mask
    #   87  the comparison could not be made honestly (capture, allocation or #90 refused).
    #   96  gpu_tex_arm refused -- an ARMING fault, not a shader fault. Check the boot log.
    #   Any GPO_E_* reason: the ABI refused that record; 25/26/27 are tex slot / tex dim / LUT.
    echo "[2/2] Building the 3D-arc RUNG 13 kernel (texturing; no compile flag needed)."
    echo "      Run: gputri --cov (must STILL be 20/20) THEN gputex THEN klug > /tex1.txt"
    BUILD_ENV=""
    BUILD_TAG="TEX_RGBA"

elif [ -n "${BURN_TRI_RGBA:-}" ]; then
    # ============================================================================================
    # 3D ARC RUNG 11 — BURN 1. ATTRIBUTE INTERPOLATION'S FIRST CONTACT WITH SILICON.
    # ============================================================================================
    # ⚠ NO COMPILE FLAG. gpu_tri_arm / gpu_tri_rgba are UNCONDITIONAL — a default kernel already
    # carries them. This mode carries the BRIEF, not a #define. A burn whose instructions live only
    # in a chat log gets run wrong once and wasted.
    #
    # ⛔ WHAT THIS BURN CAN AND CANNOT SETTLE, STATED BEFORE IT RUNS. #90 reads the back buffer
    # back, so this IS a byte comparison: every rendered rect is diffed against the CPU reference
    # pixel for pixel. It settles per-pixel correctness of op 0x09 and op 0x0A. What it does NOT
    # settle is anything about a case the ABI refused — a REJECTED line is not a pass.
    #
    # ⛔ BURNS 3 AND 4 BOTH EXITED 85 AND BOTH WERE THIS TOOL'S FAULT, NOT THE SHADER'S. Burn 3:
    # the reference assumed full coverage while the GPU applied the real antialiased mask. Burn 4:
    # the fix captured coverage for `tc_get(i,...)` where `i` was the PREVIOUS loop's variable,
    # parked one row past the end of the corpus — the same garbage triangle for all 15 cases, while
    # the digests printed above it used `i` correctly and looked entirely plausible. Both times the
    # verdict text named the emission and both times that was wrong. THE INSTRUMENT IS NOT ABOVE
    # SUSPICION; the located per-pixel diffs added for this burn exist so the next red names a
    # pixel instead of a suspect.
    #
    # RUN IN THIS ORDER. The order makes a red localise.
    #   1. run /bin/triref                    (host build) -- note its N16 corpus digest FIRST.
    #      ⛔ Actually run the HOST triref before the flash and write the digest down; step 3
    #      compares against it. If they differ, this build's reference is not the host's and
    #      nothing else on the flash means anything. Current host value: 0x8aed72de.
    #   2. run /bin/gputri --cov              rung 9b regression: the rasteriser must STILL be
    #      20/20. Attribute interpolation dispatches the coverage kernel unmodified, so a red here
    #      indicts the arena move (the prep table went 0xD0000 -> 0xA8000), not the new shader.
    #   3. run /bin/gputri --tri              the corpus + all eight controls N9-N16.
    #   4. run /bin/gputri --list             rung 12: 6 overlapping triangles, ONE record.
    #   5. run /bin/klug > /tri.txt           capture, then mount the FS from Linux to copy out.
    #
    # PRE-REGISTERED OUTCOME TABLE — written before the flash:
    #   95  every record accepted, every dispatch retired, all controls fired, AND every rendered
    #       rect is byte-identical to the reference. Rung 11 and rung 12 are both settled.
    #   85  pixels differ. ⭐ READ THE `diff ... x= y= cov= want= got=` LINES — up to four are
    #       printed per run and they are the whole point of this flash. How to read them:
    #         cov=0 but got != 0xFF101010      -> the shader wrote OUTSIDE the coverage mask
    #         alpha agrees, RGB does not       -> the interpolator, not the src-over blend
    #         want/got equal a NEIGHBOURING px -> addressing (row or column offset), not arithmetic
    #         every covered px off by a ramp   -> the prep record's scale (2A or the reciprocal)
    #       ⛔ Do NOT conclude "the emission" from the exit code alone. That was written into this
    #       table for burns 3 and 4 and it was wrong both times.
    #   87  the comparison could not be made honestly — #90 refused, or (new this burn) the
    #       reference SKIPPED a triangle the kernel accepted, which is a validator disagreement
    #       and makes every pixel number below it meaningless.
    #  100  no GPU carveout — wrong machine, or the GPU never came up. Not a rung-11 result.
    #   96  the shader is not resident: gpu_tri_arm's gates refused. An ARMING fault, not a shader
    #       fault. Check the boot log's arena/ring/matmul lines.
    #   86  a negative control did not fire. The run proves NOTHING either way — fix and re-burn.
    #       ⭐ N12 is the one that matters most: it is the only thing standing between an
    #       x-term-wired-to-zero shader and a green run, because every gradient case is a function
    #       of y alone and reproduces perfectly with a dead x coefficient.
    #   90  a slot write/read syscall failed — infrastructure, not the shader.
    #   Any GPO_E_* reason printed per case: the ABI refused that record. The reason code names the
    #       field; 22 = frame area, 23 = frame skew, 20 = coordinate out of range.
    #
    # ⭐ WHAT IS ALREADY PROVEN AT ZERO BURNS, so a red here does NOT re-open it:
    #   * the algorithm — trimodel byte-diffs the whole thing against the exact reference at
    #     register widths, with four falsification gates including the x-term kill.
    #   * the machine code — two independent assemblers (llvm-mc and the sovereign edgeasm) agree
    #     on all 269 dwords.
    #   * the CPU prologue — the kernel's 128-byte prep record is field-identical to the host's.
    #   * the register budget — the emit list's high-water is v31 against a declared 32.
    #   ⚠ THIS LIST NARROWS THE SEARCH, IT DOES NOT EMPTY IT — and reading it as "so the fault must
    #   be dispatch or coherence" is exactly what wasted burns 3 and 4. Nothing above covers THE
    #   INSTRUMENT: the corpus loop, the coverage capture, the reference's inputs. Two reds in a row
    #   lived there. Suspect the tool first; it is the only part of the chain with no oracle.
    echo "[2/2] Building the 3D-arc RUNG 11 kernel (attribute interpolation; no compile flag needed)."
    echo "      Run: gputri --cov (must STILL be 20/20) THEN gputri --tri THEN klug > /tri.txt"
    BUILD_ENV=""
    BUILD_TAG="TRI_RGBA"

elif [ -n "${BURN_EDGE_COV:-}" ]; then
    # ============================================================================================
    # 3D ARC RUNG 9b — BURN 1. THE EDGE RASTERISER'S FIRST CONTACT WITH SILICON.
    # ============================================================================================
    # ⚠ NO COMPILE FLAG. gpu_edge_arm/gpu_edge_cov are UNCONDITIONAL — a default kernel already
    # carries them. This mode exists to carry the BRIEF, not a #define: what to run, in what
    # order, and what each outcome indicts. A burn whose instructions live only in a chat log is
    # a burn that gets run wrong once and wasted.
    #
    # RUN IN THIS ORDER. The order is the whole point — it makes a red localise.
    #   1. run /bin/gputri --digest > /tmp/d.txt   then compare against the HOST `cpuref` output.
    #      ⛔ DO THIS FIRST. If the digests differ, this build's reference is not the host's, and
    #      every byte-comparison below is against the wrong answer. Nothing else on the flash
    #      means anything until they match.
    #   2. run /bin/gputri --cov                   the 20-case corpus + negative controls N1-N8.
    #   3. run /bin/klug > /edge.txt               capture, then mount the FS from Linux to copy out.
    #
    # PRE-REGISTERED OUTCOME TABLE — written before the flash, per the arc's own discipline:
    #   95  every case byte-identical AND every control fired. Rung 9b is DONE, and because B2
    #       already proved the algorithm exhaustively at zero burns, this also retires
    #       v_mul_hi_u32 and global_store_byte as suspects in one shot.
    #  100  no GPU carveout — wrong machine, or the GPU never came up. Not a 9b result.
    #   96  the shader is not resident: gpu_edge_arm's gates refused. Check the boot log for the
    #       arena/ring/matmul lines; this is an ARMING fault, not a rasteriser fault.
    #   88  UNTOUCHED — the dispatch retired and wrote NOTHING. Missing post-dispatch coherence,
    #       or the EXEC guard rejected every lane. ⛔ NOT an edge-setup bug; do not look there.
    #   87  wrote but covered nothing — write-back works, the winding evaluated to zero: FILL RULE.
    #   92  shape right, edge pixels differ by <= 2 — rounding / sub-scanline placement.
    #   91  wrong shape, large deltas — edge setup or the crossing solve.
    #   89  PARTIAL, some bytes still sentinel — TGID MAPPING; whole workgroups never dispatched.
    #   86  a negative control did not fire. The run proves nothing either way; fix and re-burn.
    #   85  digest mismatch (see step 1).
    #
    # ⭐ BURN 2. Burn 1 (2026-07-25) returned 14 of 20 byte-exact with all 20 digests matching.
    # That RETIRED v_mul_hi_u32 and global_store_byte as suspects — a 64-gon at the edge cap
    # cannot be byte-exact if either were wrong — so the `--valu` oracle named as a gap before
    # burn 1 is no longer needed. It was never built, and the ordering call that skipped it paid.
    #
    # Two faults fixed since:
    #   1. Five GPO_E_EDGEBUF rejects were MINE: refraster dropped horizontal edges at ingest, so
    #      a flat-topped triangle submitted 2 edges against an ABI minimum of 3 — and the CPU and
    #      GPU were not being given the same geometry. Horizontals are kept now; all 20 digests
    #      are UNCHANGED, which is the proof the oracle did not move.
    #   2. ⭐ Case 14 (the OPEN path) was a REAL shader bug: a per-lane `break` rendered as a
    #      WAVE-level s_cbranch_vccz, so a lane with no crossing to its right filled to the end
    #      of its pixel. Reproduced exactly in edgemodel.cyr (631 bytes, delta 255, case 14
    #      alone) before being fixed, and re-verified 135/135 byte-identical after.
    #
    # ⇒ Burn 2 returned **20 of 20, exit 95**. RUNG 9b IS COMPLETE — agnos has a GPU triangle
    # rasteriser, byte-identical to the CPU reference across the whole corpus.
    #
    # ============================================================================================
    # BURN 3 (1.56.18) — RUNG 10, THE KILL GATE. `run /bin/gputri --bench`
    # ============================================================================================
    # ⛔ THIS MEASUREMENT CAN KILL RUNGS 11-12, AND THAT IS A LEGITIMATE OUTCOME.
    #
    # PRE-REGISTERED, published in the tracker BEFORE this flash (gpu.md rung 10):
    #     unbatched crossover ~ 12,000 covered px (~110x110)
    #     batched   crossover ~ 50,000 covered px/frame (~80 glyphs)
    #
    # OUTCOME TABLE, also pre-registered:
    #   · batched crossover WELL BELOW a real frame's coverage ⇒ ★ tier-1 confirmed, rungs 11-12 open
    #   · batched crossover NEAR a real frame's coverage       ⇒ ship opt-in per surface, not default
    #   · batched crossover ABOVE a real frame's coverage      ⇒ ⛔ TIER-1 COVERAGE IS DEAD. Rungs
    #     11-12 do NOT open on it; the arc re-bases on rung 14 (DOOM), which does not depend on
    #     this measurement at all. REPORT IMMEDIATELY. **This is a result, not a null.**
    #   · GPU faster but the desktop looks worse ⇒ latency/pacing, not throughput.
    #
    # RUN ORDER: `gputri --cov` FIRST (it must still be 20/20 — a regression there invalidates the
    # bench, since a wrong rasteriser's timing means nothing), THEN `gputri --bench`, THEN klug.
    #
    # ⚠ Timed with uptime_ms#40 at 100 Hz, so each point repeats to >= 200 ms and divides. That
    # measures the FULL ring-3 round trip (submit + fence + wait) — the cost a compositor actually
    # pays — rather than a kernel-internal timer that would flatter the GPU by hiding the wait.
    # Both sides are timed the same way, same boot, same geometry, same edge list.
    #
    # ⚠ NOT MEASURED: n_edges above the shipped EDGE_CAP of 64, and masks above 256x256. Raising
    # the cap needs those points and is its own bite — the cap moves on MEASUREMENT, never on the
    # arithmetic model that set it.
    #
    # ============================================================================================
    # BURN 4 (1.56.18) — RUNG 10 RETRY. The kill gate still has NO NUMBER.
    # ============================================================================================
    # Burn 3 froze at the FIRST bench point. Two separate faults, both now fixed:
    #
    #   1. ⭐⭐ THE KERNEL ONE, and it is not about the GPU at all. Vector 0 (#DE) was in idt.cyr's
    #      "deliberately NOT installed" list, so a ring-3 divide by zero returned to the faulting
    #      idiv forever — ANY userland program that divided by zero froze agnos. Vector 0 now
    #      joins the curated set AND the {6,13,14} ring-3 kill set. Proven in QEMU by
    #      scripts/smoke/de-smoke.sh (3/3) and mutation-calibrated: reverting it reproduces the freeze
    #      exactly. ⇒ Even an unguarded division in ANY tool can no longer take the box down.
    #
    #   2. `gputri --bench` FABRICATED a timing instead of refusing: it assigned el = TARGET and
    #      divided by an already-quadrupled reps, yielding 0 us, and the next line divided by it.
    #      It now returns a negative sentinel on refusal, prints raw ms/reps evidence beside every
    #      derived figure, guards all four divisions with named NO VERDICT paths, sanity-checks
    #      the clock first, and runs its CPU half with no GPU so the harness is QEMU-testable.
    #
    # RUN ORDER IS UNCHANGED and still matters:
    #   1. run /bin/gputri --cov     must still be 20/20. Timing a wrong rasteriser means nothing.
    #   2. run /bin/gputri --bench   the kill gate. Expect a [cpu-only] block FIRST -- that is the
    #      harness validating itself before any GPU number is printed.
    #   3. run /bin/klug > /bench.txt
    #
    # ⚠ A "NO VERDICT" line is a legitimate, honest outcome for a point that could not be timed.
    # It is NOT a failure of the burn. A crossover derived from a partial sweep is simply not the
    # pre-registered number, and the tool says so rather than quietly averaging over the gap.
    #
    # ============================================================================================
    # BURN 5 (1.56.18) — RUNG 10, THIRD ATTEMPT. THE INSTRUMENT IS NOW PROVEN.
    # ============================================================================================
    # ⛔ ROOT CAUSE OF BOTH PREVIOUS FAILURES, and it was ONE thing: `uptime_ms`#40 reads
    # timer_ticks, and a FOREGROUND `run` program starts with IF CLEARED (ring3.cyr: "a
    # foreground program is not meant to be preempted" — only /bin/agnsh gets IF=1). The timer
    # ISR never fires, so #40 is FROZEN for the program's whole duration and anything timing
    # itself with it measures zero.
    #   burn 3: el always 0 -> reps exploded -> the bench FABRICATED a timing -> divide by zero.
    #   burn 4: bench_clock_ok spun waiting for a clock that could not advance.
    # Both read as bench bugs. The bench had bugs, but the INSTRUMENT was wrong.
    #
    # ⭐ FIXED AND PROVEN AT ZERO BURNS: `uptime_us`#95 — rdtsc-backed (needs no interrupts),
    # calibrated at boot against 50 ms of live ticks, returns -1 rather than a plausible 0 when
    # calibration is refused. scripts/smoke/tsc-smoke.sh is a DIFFERENTIAL proof: a ring-3 probe samples
    # #95 around a busy loop with interrupts off and it ADVANCES (3/3, `run: exit 1`) — exactly
    # where #40 cannot. Calibration on archaemenid measured 3194 cycles/us, so the long-assumed
    # GPU_TSC_PER_US = 3000 is 6.5% low (not retuned here — that is its own bite).
    #
    # Also live since burn 3: a ring-3 divide by zero now KILLS THE PROC instead of freezing the
    # machine (vector 0 installed + routed to the ring3-kill path; de-smoke 3/3).
    #
    # ⇒ THE BAR FOR THIS BURN IS A NUMBER. `--bench` must print a measured crossover, or an
    # explicit NO VERDICT naming which points could not be timed. Both are readable results.
    # A hang is not, and is the one outcome the last two burns produced.
    #
    # RUN ORDER: gputri --cov (must be 20/20) THEN gputri --bench THEN klug > /bench.txt
    echo "[2/2] Building the 3D-arc RUNG 9b kernel (edge rasteriser; no compile flag needed)."
    echo "      Run: gputri --cov (must be 20/20) THEN gputri --bench (RUNG 10 KILL GATE) THEN klug > /bench.txt"
    BUILD_ENV=""
    BUILD_TAG="EDGE_COV"
elif [ -n "${BURN_SHADER_COV:-}" ]; then
    # plan-S10 — coverage (anti-aliased) blend: uniform colour x 8bpp mask. ⚠ Re-proof required at 1.56.4:
    # both coverage call sites passed 11 args to a 12-parameter dispatcher until this cut, so the RSRC1 the
    # kernel ran with was whatever `gx` happened to be. Oracle: 'gpu: shader coverage blend online'.
    echo "[2/2] Building the plan-S10 SHADER-COV kernel (coverage blend, RSRC1 arity FIXED; capture klug > shader_cov.txt)."
    BUILD_ENV="SHADER_COV=1"
    BUILD_TAG="SHADER_COV"
elif [ -n "${BURN_SHADER_RECT:-}" ]; then
    # plan-S5 + first half of plan-S7 — the blend over a 2-D grid, into the scanout back buffer, presented.
    # Builds SHADER_BLEND alongside on purpose: S2 stays the regression net, so if the grid arm fails while
    # the 64-px arm passes, the fault is isolated to grid/addressing/scanout and cannot be the blend math.
    echo "[2/2] Building the plan-S5 SHADER-RECT kernel (grid blend to back buffer + S2 net; capture klug > shader_rect.txt)."
    BUILD_ENV="SHADER_BLEND=1 SHADER_RECT=1"
    BUILD_TAG="SHADER_RECT"
elif [ -n "${BURN_SHADER_BLEND:-}" ]; then
    # plan-S2 — the FIRST per-pixel alpha blend on the CUs (premultiplied f32), 64 px into a fresh arena
    # slot. Oracle: 'gpu: shader blend lanes stored 64 of 64' THEN 'gpu: shader alpha blend online'. The
    # lane count is separate on purpose — a dispatch can retire having written nothing if every lane is
    # EXEC-masked, which is exactly what happened at 1.54.17-19.
    echo "[2/2] Building the plan-S2 SHADER-BLEND kernel (first alpha blend on the CUs; capture klug > shader_blend.txt)."
    BUILD_ENV="SHADER_BLEND=1"
    BUILD_TAG="SHADER_BLEND"
elif [ -n "${BURN_SHADER_PROBE:-}" ]; then
    # plan-S1 + D0 — read-only compute-state + DCN MPC probes. No writes, no ring traffic.
    echo "[2/2] Building the plan-S1+D0 SHADER-PROBE kernel (read-only probes; capture klug > shader_probe.txt)."
    BUILD_ENV="SHADER_PROBE=1"
    BUILD_TAG="SHADER_PROBE"
elif [ -n "${BURN_SDMA_COPY:-}" ]; then
    # P9.2 — FIRST SDMA PACKET (first hardware 2D on agnos). Rings up SDMA (P9.1) then submits ONE COPY_LINEAR
    # (4KB carveout→carveout) + a FENCE, kicks via RB_WPTR (register, wptr in BYTES), gates completion on the
    # FENCE SENTINEL (coherence-honest — rptr alone could false-GREEN on the GL2 strand), and verifies dst==src.
    # Builds SDMA_RING + SDMA_COPY together. ⚠ NEEDS /fw/sdma.bin on the agnos-fs → flash --update-all. Oracle:
    # 'gpu: sdma HARDWARE COPY verified'. CAPTURE: klug > sdma_copy.txt.
    echo "[2/2] Building the P9.2 SDMA-COPY kernel (first hardware copy; FLASH WITH --update-all; capture klug > sdma_copy.txt)."
    BUILD_ENV="SDMA_RING=1 SDMA_COPY=1"
    BUILD_TAG="SDMA_COPY"
elif [ -n "${BURN_SDMA_RING:-}" ]; then
    # P9.1 — SDMA0 GFX-ring bring-up. PSP-loads the SDMA ucode (F32 halted at boot; agnos loads only CP/MEC),
    # un-halts the F32, and programs the ring registers (regdump-anchored). NO packet/kick — verifies the engine
    # un-halts + goes idle (the analogue of the MEC 'queue ready'). ⚠ NEEDS /fw/sdma.bin ON THE agnos-fs → flash
    # with --update-all (not --update). Oracle: 'gpu: sdma ring ready' in klug. CAPTURE: klug > sdma_ring.txt.
    echo "[2/2] Building the P9.1 SDMA-ring kernel (SDMA_RING: PSP-load + un-halt + ring config; FLASH WITH --update-all; capture klug > sdma_ring.txt)."
    BUILD_ENV="SDMA_RING=1"
    BUILD_TAG="SDMA_RING"
elif [ -n "${BURN_SDMA_PROBE:-}" ]; then
    # P9.0 — READ-ONLY SDMA0 register-discovery dump. SDMA is the engine P9 rings up for hardware 2D. Only its
    # IP base (0x1260) is known; this dumps the SDMA0 block to klug so the real ring/status/ucode offsets can be
    # anchored against known values (ucode version, idle bit) BEFORE any SDMA write — and reports whether SDMA
    # ucode is resident. Read-only. ⚠ small hang risk if SDMA's clock is gated (reboot recovers; that's the
    # finding). CAPTURE: klug > sdma.txt from the shell, send the file.
    echo "[2/2] Building the P9.0 SDMA-probe kernel (SDMA_PROBE: read-only SDMA0 register dump; capture klug > sdma.txt)."
    BUILD_ENV="SDMA_PROBE=1"
    BUILD_TAG="SDMA_PROBE"
elif [ -n "${BURN_SCANOUT_MATCHGEOM:-}" ]; then
    # P4 — THE FIX (regdump-confirmed). The firmware scans an 800x600 surface upscaled to 2560x1440; boot_info
    # reports the 2560x1440 output, so fb_console writes 2560-wide and bands. This reads the REAL viewport+pitch
    # (0x5EA/0x607) and overrides fb_console to render 800x600, then redraws. NO register writes — pure reads +
    # a software geometry switch — cannot hang/black. ⚠ ORACLE = the CONSOLE: legible (blocky but CLEAN, no
    # bands)? Yes ⟹ P4 closed. Needs BIOS quiet-boot ON (the banded/scaled condition).
    echo "[2/2] Building the P4 MATCHGEOM kernel (SCANOUT_MATCHGEOM: render at the real 800x600 surface; LOOK at legibility; quiet-boot ON)."
    BUILD_ENV="SCANOUT_MATCHGEOM=1"
    BUILD_TAG="SCANOUT_MATCHGEOM"
elif [ -n "${BURN_SCANOUT_REGDUMP:-}" ]; then
    # P4 — READ-ONLY HUBP register dump. The surface is scaled (~800x600 → 2560x1440); the derived HUBP offsets
    # are unreliable, so dump the live-pipe HUBP block to klug to re-anchor the real pitch/viewport offsets.
    # Pure reads — cannot hang, cannot black. ⚠ CAPTURE: klug > regdump.txt from the shell, send the file.
    echo "[2/2] Building the P4 HUBP REGDUMP kernel (SCANOUT_REGDUMP: read-only register dump to klug; capture klug > regdump.txt)."
    BUILD_ENV="SCANOUT_REGDUMP=1"
    BUILD_TAG="SCANOUT_REGDUMP"
elif [ -n "${BURN_SCANOUT_REDIRECT:-}" ]; then
    # P4 — THE FIX. The pattern burn proved an agnos-owned buffer scans BAND-FREE while the GOP console surface
    # bands (surface-specific, not scan-geometry). This redirects fb_console onto that buffer via the P0-verified
    # address flip ONLY (zero hang risk). ⚠ ORACLE = the CONSOLE ITSELF: is the boot log + shell prompt LEGIBLE
    # (bands gone)? Yes ⟹ P4 closed. Needs BIOS quiet-boot ON (the banded condition).
    echo "[2/2] Building the P4 console-REDIRECT kernel (SCANOUT_REDIRECT: fb_console onto the clean agnos buffer; LOOK at first-paint legibility; quiet-boot ON)."
    BUILD_ENV="SCANOUT_REDIRECT=1"
    BUILD_TAG="SCANOUT_REDIRECT"
elif [ -n "${BURN_SCANOUT_PATTERN:-}" ]; then
    # P4 — SCANOUT BISECTOR (register-truth 2026-07-20). Flips scanout to an agnos-owned buffer painted with
    # a bars/stripes/checker pattern via the P0-verified address flip ONLY (byte-identical to gpu_blit_present
    # → ZERO hang risk; the retired SCANOUT_LINEAR path blacked the box by writing the WRONG register 0x607).
    # ⚠ ORACLE = A PHOTO of the panel: crisp full-width bars + clean fine stripes + clean checker ⟹ the HUBP
    # scans an agnos linear buffer perfectly ⟹ banding is surface-content (redirect is the fix). Sheared /
    # garbled fine detail ⟹ a real scan-geometry fault (fix the VERIFIED 0x603). Also reads the corrected
    # 0x603 pitch to klug during boot (before the flip). Needs BIOS quiet-boot ON to match the banded case.
    echo "[2/2] Building the P4 scanout-PATTERN kernel (SCANOUT_PATTERN: address-flip bisector; PHOTO the bars/stripes/checker; quiet-boot ON)."
    BUILD_ENV="SCANOUT_PATTERN=1"
    BUILD_TAG="SCANOUT_PATTERN"
elif [ -n "${BURN_HDMI_ACR_CTS:-}" ]; then
    # THE ACR CTS BURN — the one real register-value delta left after the whole register class was exhausted
    # (PHY included, 2026-07-20). agnos left HDMI_ACR_CTS_48/44/32_0 at 0; the amdgpu-playing capture writes
    # 0x3AF5C000 (241500) to all three. The CTS/N ratio is what the sink uses to regenerate its audio clock —
    # the exact mechanism between "amp armed + receiving our stream" and "decodes as CLEAN silence". agnos was
    # deliberately NOT writing them ("inert under SOURCE=0"); but amdgpu writes them WITH SOURCE=0, and this
    # register was never tested on this silicon. Display-safe (audio only, no PHY/PLL/OTG). Single variable.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). The three CTS stores live inside
    # gpu_hdmi_program_infoframes(), and this build carries NO HDMI_ATOM — so the boot-time
    # gpu_hdmi_audio_enable() is the only thing that reaches them. That call refuses at gpu_hdmi_preflight()
    # for as long as gpu_audio_dig is -1, and gpu_audio_probe() is the only thing that ever sets it. Without
    # the flag the register under test is NEVER WRITTEN and the burn listens to a kernel that did nothing.
    echo "[2/2] Building the ACR-CTS kernel (HDA_HDMI + HDA_TONE + HDMI_ACR_CTS + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: program the ACR CTS registers to amdgpu's 241500; LISTEN for the tone)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_ACR_CTS HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ACR_CTS=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ACR_CTS+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_SYMCLK_AB:-}" ]; then
    # THE ATTRIBUTION CONTROL BURN. 1.55.24 wrote the five DCCG symbol-clock stores blind and the burn was
    # written up as "SYMCLKA ARMED THE SINK". The re-audit killed that read: the symbol clock is ALREADY ON in
    # every silent burn (DIG_SYMCLK_FE_ON/BE_ON both ack SET, identical across all eight logs), the shutdown
    # pop predates the write by five burns, the operator reports the noise floor recurred on several burns in
    # the cycle, and not one dumped register differs between the silent burn 8 and the "armed" burn 10.
    # Cross-boot comparison cannot settle it — sink amp/mute/mode state is SINK-latched and every agnos
    # instrument is source-side. So do the A/B INSIDE one boot: two labelled ~6 s listening windows, symclk
    # off then on, twice, each bracketed by a five-register readout, then the ACR N-scale discriminator.
    # NOTE: deliberately does NOT set HDMI_DCCG — that would apply the write at boot and leave window A
    # already-on. PASS IS THE OPERATOR'S EARS, and the question is whether A and B DIFFER.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). The whole A/B sits inside `if (gpu_hdmi_audio_on == 1)`
    # in main.cyr, and that flag is set only by a gpu_hdmi_audio_enable() that got past preflight — which
    # needs gpu_audio_dig, which only gpu_audio_probe() sets. Without the flag the boot prints
    # "symclk-ab: no HDMI audio path -- skipping" and the burn produces neither window.
    echo "[2/2] Building the SYMCLK A/B kernel (HDA_HDMI + HDA_TONE + HDMI_SYMCLK_AB + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: two labelled listening windows in ONE boot, symclk OFF then ON; LISTEN for a difference)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_SYMCLK_AB HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_SYMCLK_AB=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_SYMCLK_AB+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_DCCG:-}" ]; then
    # THE DCCG SYMCLK BURN — the de-risked candidate. The amdgpu modeset capture proved agnos omits the DCCG
    # symbol-clock writes amdgpu makes for HDMI (abs 0x159 SYMCLKA-on for DIG1/UNIPHYA, confirmed by DIG1's AVI
    # landing at 0x564d + phyid=0). This applies exactly those writes in gpu_hdmi_audio_enable. NO ATOM
    # interpreter, NO transmitter, NO PHY power-cycle — host-visible DCCG only, so display-safe (worst case a
    # clock glitch, recoverable; not the transmitter's non-recoverable blank). If audio plays, the missing
    # symbol clock was the whole thing and we never touch the transmitter. PASS IS THE OPERATOR'S EARS.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). The five DCCG stores are inside gpu_hdmi_audio_enable()
    # itself, which refuses at preflight while gpu_audio_dig is -1 — so the flag under test would never be
    # applied at all, and the burn would read as "the symbol clock changed nothing".
    echo "[2/2] Building the DCCG-symclk kernel (HDA_HDMI + HDA_TONE + HDMI_DCCG + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: apply the DCCG symbol-clock re-prime amdgpu does for HDMI; host-visible, display-safe; LISTEN for the tone)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_DCCG HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_DCCG=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_DCCG+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_ATOM_HALT:-}" ]; then
    # THE A4 ISOLATION BURN. Both the live and dry ATOM kernels blacked the iron display before the shell,
    # with no log — and DRY writes NOTHING to the PHY, so the interpreter's HW writes are not the cause. This
    # kernel runs the full ATOM DRY path (gpu_vbios_acquire + the interpreter, zero PHY writes), prints its
    # step markers, then HALTS — freezing the framebuffer BEFORE gpu_hdmi_audio_enable()'s DIG_MODE flip. The
    # operator photographs the FB (13NN_*.jpg). READ:
    #   * clean 'gpu: vbios ... acquired OK' + 'atom: ... bringup OK' summary, screen intact
    #       => the ATOM path is display-safe; the black screen is gpu_hdmi_audio_enable's DIG flip (investigate
    #          there — prior HDA_HDMI burns kept video, so something in the new path changed its behaviour).
    #   * black or garbled FB at the halt, or the markers stop partway
    #       => the ATOM path itself broke the display (gpu_vbios_acquire's pmm_alloc_2mb landing in the APU UMA
    #          carveout + the 1 MB VBIOS copy is the prime suspect); the last visible marker localizes it.
    # No ATOM_TRACE (keep the summary on one screen). No PHY drive. No audio.
    # ⛔ GPU_AUDIO_PROBE IS **DELIBERATELY ABSENT**, AND THIS IS THE ARM THAT PROVES THE 1.56.34 AUDIT WAS AN
    # AUDIT AND NOT A SED. Every other HDA_HDMI arm in this file gained the flag; this one must not.
    #   * The halt spins forever at main.cyr's `#ifdef ATOM_HALT`, which is INSIDE `#ifdef HDMI_ATOM` and
    #     therefore BEFORE the `gpu_hdmi_audio_enable()` call site. The audio path is not merely unused here
    #     — it is unreachable by construction. Nothing in this arm consults gpu_audio_dig.
    #   * atom_hdmi_transmitter_bringup() aims itself with gpu_phy_discover() (the BACK end, scanned live),
    #     NOT with gpu_audio_dig (the FRONT end). Conflating those two is the error that once pointed #76 at
    #     a dead PHY; do not re-introduce it here by assuming the probe is a prerequisite for ATOM.
    #   * The oracle is a PHOTOGRAPH of the frozen framebuffer. gpu_audio_probe() prints ~6 lines of
    #     labelled hex, which under ATOM_HALT means six lines of noise scrolling the ATOM step markers the
    #     photo exists to capture — it would actively degrade the only instrument this arm has.
    # BUILD_REQUIRE is still declared, because the sentinel after this chain refuses an undeclared audio arm.
    echo "[2/2] Building the A4 ISOLATION kernel (HDA_HDMI + HDMI_ATOM + ATOM_DRY + ATOM_HALT: run the ATOM path with zero PHY writes, then FREEZE the framebuffer before the DIG flip; photograph the FB to isolate ATOM-path vs DIG-flip). NO GPU_AUDIO_PROBE -- the halt precedes the audio enable."
    BUILD_REQUIRE="HDA_HDMI HDMI_ATOM ATOM_DRY ATOM_HALT"
    BUILD_ENV="HDA_HDMI=1 HDMI_ATOM=1 ATOM_DRY=1 ATOM_HALT=1"
    BUILD_TAG="HDA_HDMI+HDMI_ATOM+ATOM_DRY+ATOM_HALT"
elif [ -n "${BURN_HDMI_ATOM_DRY:-}" ]; then
    # THE A4 DRY-VALIDATION BURN (safe fallback). Same as BURN_HDMI_ATOM but ATOM_DRY suppresses every MMIO
    # write and forces reads to 0 — the interpreter runs its full control flow WITHOUT touching the PHY, so
    # the console is guaranteed to survive and `run /bin/klug > /f/dump.txt` always works. The ATOM_TRACE
    # output is the deliverable: the exact write sequence agnos's interpreter produces, to diff against the
    # atom-interp.py oracle (transmitter: 21 reads / 17 writes / 5 delays, writes to UNIPHYA 0x55xx + RDPCS
    # 0x5Dxx-0x5Exx). Use this if a live BURN_HDMI_ATOM blacks/hangs the console before the shell.
    # ⚠ GPU_AUDIO_PROBE IS REQUIRED, AND THE REASONING SPLITS — say which half needs it rather than waving at
    # the arm (1.56.34 audit). The ATOM-TRACE half does NOT: ATOM_DRY suppresses the MMIO and the interpreter
    # aims itself by gpu_phy_discover(), so the write list this arm exists to produce is unaffected. But the
    # arm ALSO declares HDA_TONE and HDMI_AUDIO_DUMP, and BOTH of those halves are dead without the probe:
    # the sink-select + bind_single block and gpu_audio_dump() both sit behind `if (audio_sink_ok == 1)`,
    # which in a non-MODESET_AUDIO build means gpu_hdmi_audio_on == 1 — unreachable while gpu_audio_dig is
    # -1. So without it the tone stays on the analog jack nobody has plugged in and the register read-back
    # never prints. Shipping a flag that cannot do anything is the ATOM_DRY defect exactly; either the flag
    # is required or it should not be in BUILD_ENV, and here it is required.
    echo "[2/2] Building the A4 DRY-VALIDATION kernel (HDA_HDMI + HDA_TONE + HDMI_ATOM + ATOM_DRY + ATOM_TRACE + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: run the ATOM interpreter with writes SUPPRESSED; capture the trace and diff vs the oracle. No PHY drive, console safe)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_ATOM ATOM_DRY ATOM_TRACE HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_DRY=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_DRY+ATOM_TRACE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_ATOM_FULL:-}" ]; then
    # THE ENCODER+TRANSMITTER burn (ATOM_RUN_TRANSMITTER=1). ⚠ The transmitter ENABLE power-cycles the PHY and
    # BLANKS THE LIVE CONSOLE PIPE NON-RECOVERABLY on iron (proven 1.55.23) unless a full modeset (SetPixelClock
    # + OTG recommit) is also in place. DO NOT flash this until that modeset exists. Kept for that future work.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). The point of running the transmitter at boot is that
    # gpu_hdmi_audio_enable() then follows it on a re-primed PHY; that call refuses at preflight while
    # gpu_audio_dig is -1, so without the flag this arm would spend its PHY edge — the whole risk it carries
    # — and then not attempt the thing the edge was for.
    echo "[2/2] Building the A4 FULL kernel (HDA_HDMI + HDA_TONE + HDMI_ATOM + ATOM_RUN_TRANSMITTER + ATOM_TRACE + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: encoder + transmitter. ⚠ BLANKS THE CONSOLE without a full modeset — do not flash yet)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_ATOM ATOM_RUN_TRANSMITTER ATOM_TRACE HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_RUN_TRANSMITTER=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_RUN_TRANSMITTER+ATOM_TRACE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_GPU_RECOVER:-}" ]; then
    # ⛔⛔ 3D ARC RUNG 5 — THE GPU HANG/RECOVERY BATTERY. One boot, five arms.
    #
    # WHY IT EARNS ITSELF EVEN IF 3D NEVER SHIPS: agnos has NO GPU hang detection today, and that
    # is already true for #82, #83 and #92, which SHIP. A runaway tentib matmul or a malformed
    # #92 batch kills the box with no log. Every safety property agnos has bounds how long the
    # CPU WAITS, never what the GPU DOES.
    #
    # ⛔ ARM A DELIBERATELY HANGS THE GPU. The panel may go dark. That IS the experiment.
    # ⭐ Arm A's ORACLE IS THE FORENSIC BRACKET IN THE LOG, not whether recovery then works:
    # "we can SEE the hang" and "we can CLEAR the hang" are different claims, and collapsing them
    # would let a failed recovery hide a working instrument every later rung depends on.
    #
    # ⛔ NO GRBM_SOFT_RESET anywhere in the ladder — gpu.cyr's own note says it would wipe
    # PSP-loaded ucode, which agnos re-loads only at boot: a recoverable hang would become a dead
    # GPU until reboot.
    #
    # ⚠ The RECOVERY LADDER is in EVERY build; only the deliberate WEDGE is behind GPU_RECOVER.
    echo "[2/2] Building the RUNG 5 kernel (GPU_RECOVER: hang forensics + the R-2/R-3/R-4 recovery ladder + the controlled-wedge arm. ⛔ ARM A HANGS THE GPU ON PURPOSE and the panel may go dark; the log's forensic bracket is the oracle, not the screen)."
    BUILD_ENV="GPU_RECOVER=1"
    BUILD_TAG="GPU_RECOVER"
elif [ -n "${BURN_MODESET_AUDIO:-}" ]; then
    # ⛔⛔ M9 — THE SEQUENCING BURN. The whole arc's A4 question, reduced to ONE variable.
    #
    # THE EXPERIMENT: /bin/modeset --audio-pre and --audio-post run the SAME kernel code path
    # (mdo_transmit_run(arm)) with provably IDENTICAL staging. The ONLY difference is where the
    # unmute lands relative to the ATOM #76 transmitter edge:
    #     --audio-pre   unmute BEFORE the edge   = what agnos has always done   = CONTROL
    #     --audio-post  unmute AFTER  the edge   = what amdgpu does (+22.2 ms)  = TREATMENT
    #
    # ⛔ RUN BOTH IN ONE BOOT. A cross-boot comparison cannot control the sink's latched state
    # ([[feedback_ear_oracle_needs_negative_control]]). One sink state, one cable, one volume.
    #
    # ⛔⛔⛔ HDA_TONE IS REQUIRED, AND ITS ABSENCE IS WHAT VOIDED THIS BURN ON 2026-07-24.
    # This arm used to omit HDA_TONE on purpose, reasoning that "a fixed kernel sine is exactly
    # guessable and would void the ear oracle -- the tone comes from the ring-3 feed." The reasoning
    # about guessability is CORRECT. The conclusion was not: without HDA_TONE, hda.cyr's #else branch
    # zero-fills the 64 KB PCM ring ("zero 64 KB = silence"), AND no ring-3 feed was ever launched --
    # the entire operator transcript of the 07-24 capture is `modeset --audio-pre`, `modeset
    # --audio-post`, `rm`, `klug`. BOTH ARMS STREAMED EXACT ZEROS, so "silent, silent" was structurally
    # guaranteed and the arc recorded it as the falsification of the sequencing candidate.
    #
    # ⭐ A build-flag omission and a STIMULUS omission are the same defect: the subject of the
    # experiment was not present. BUILD_REQUIRE catches the first class and is blind to the second,
    # because nothing anywhere refuses when the tone is missing. An arm whose oracle is the operator's
    # EAR must declare its stimulus the way it declares its flags -- so HDA_TONE is now in BUILD_REQUIRE.
    #
    # ⭐ The blinding is preserved by a better means: the two arms run the kernel tone at DIFFERENT
    # frequencies (--audio-pre LOW, --audio-post HIGH), so the operator reports which one he heard
    # rather than yes/no. A listener hearing nothing cannot produce that answer.
    # ⛔ BURN_AUDIO_TEARDOWN STAYS OFF. The shutdown release pop is the arc's only sink-side
    # instrument; tearing down on exit destroys it.
    #
    # ⚠ L1 (the zero-burn Linux discriminator) could NOT pre-answer this: its positive control
    # was silent because agnos's bracket is not replayable from userspace — both OTG_MASTER_EN=0
    # and the FE_SOURCE_SELECT teardown hard-wedge the APU there. See prior-art/l1-verdict-0724.md.
    # So this burn carries the question undiminished; L1 neither supports nor refutes it.
    #
    # ⚠ PREREQUISITE, and it is not optional: the M9d-fix (gpu_hdmi_audio_enable takes the
    # caller's phy). Without it gpu_phy_discover() re-runs AFTER the BE<->FE disconnect has
    # cleared FE_SOURCE_SELECT, staging REFUSES, and BOTH arms unmute over a register file that
    # was never programmed — two identical non-experiments wearing the names of a control and a
    # treatment. Landed 1.56.14; the H8 arm below proves it is in the artifact.
    #
    # ⛔⛔ SECOND PREREQUISITE, AND IT IS THE ONE THAT WOULD HAVE VOIDED THIS BURN SILENTLY (1.56.34 audit):
    # **GPU_AUDIO_PROBE**. `mdo_transmit_run()` refuses at its fifth gate — "transmit refused -- no live DIG
    # encoder found" — whenever gpu_audio_dig < 0, and that gate sits ABOVE the `#ifdef HDMI_ATOM`, so it
    # applies no matter what else is set. Both --audio-pre and --audio-post would return MDO_E_NOGPU without
    # touching a register: a control and a treatment that are byte-identical non-experiments, which is the
    # exact failure the M9 prerequisite note above already describes from the other direction.
    # ⚠ The 2026-07-24 M9 capture reads `display audio path is HDMI on dig 1` -> `hdmi flip preconditions
    # met` ONLY because gpu_audio_probe() was still ungated then. Setting the flag RESTORES the build M9 was
    # designed against; it does not change the experiment.
    echo "[2/2] Building the M9 SEQUENCING kernel (HDA_HDMI + HDMI_ATOM + ATOM_TX_CYCLE + MODESET_AUDIO + ATOM_TRACE + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: staged-muted audio around a REAL #76 PHY edge; two arms differing ONLY in unmute position. ⛔ THE PANEL GOES DARK MID-SEQUENCE and must relight. EAR-CHECK the sink, EYE-CHECK the screen)."
    BUILD_REQUIRE="HDA_HDMI HDMI_ATOM ATOM_TX_CYCLE MODESET_AUDIO ATOM_TRACE HDMI_AUDIO_DUMP GPU_AUDIO_PROBE HDA_TONE"
    BUILD_ENV="HDA_HDMI=1 HDMI_ATOM=1 ATOM_TX_CYCLE=1 MODESET_AUDIO=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1 HDA_TONE=1"
    BUILD_TAG="HDA_HDMI+HDMI_ATOM+ATOM_TX_CYCLE+MODESET_AUDIO+ATOM_TRACE+HDMI_AUDIO_DUMP+HDA_TONE"
elif [ -n "${BURN_MODESET_TX_CYCLE:-}" ]; then
    # ⛔⛔ M8e (re-scoped 1.56.14) — THE REAL TRANSMITTER EDGE. #76 DISABLE then ENABLE, inside M6's
    # iron-proven OTG envelope, aimed by gpu_phy_discover() at the LIVE transmitter (phyid=1, measured).
    #
    # WHY A CYCLE AND NOT JUST ENABLE: on an already-enabled transmitter, #76 ENABLE is a proven NO-OP
    # (snapshot DRY: 4 reads / 2 writes / 0 delays, zero PHY registers written). The only way to produce a
    # genuine edge is DISABLE -> ENABLE. Predicted from the seeded DRY: DISABLE = 4 writes (clears
    # DIG_ENABLE, drives RDPCSTX1); ENABLE = 20 writes across DIG1 / UNIPHYB / RDPCSTX1 — the full bring-up.
    #
    # ⛔ THE PANEL GOES DARK between the two halves, BY DESIGN. That is the edge, not a failure. It must
    # relight when the ENABLE's bring-up completes. If it does not: the in-kernel watchdog re-runs the
    # inherited-mode program, then power_reset(); and H2's latch makes that reboot clean and self-disabling.
    # Worst case is ONE bad boot plus `rm /.modeset-armed` — never a reflash.
    #
    # Burn the NEGATIVE CONTROL first if in any doubt: BURN_MODESET_TRANSMITTER_LIVE runs the same code
    # path with ENABLE-only (no edge), so anything it changes did NOT come from the transmitter.
    #
    # ⛔⛔ GPU_AUDIO_PROBE IS REQUIRED **AND THIS ARM CARRIES NO AUDIO AT ALL** — the surprise of the 1.56.34
    # audit, and the reason it did not stop at the HDA_HDMI arms. `mdo_transmit_run()`'s fifth gate is
    # `if (gpu_audio_dig < 0) { "transmit refused -- no live DIG encoder found"; return MDO_E_NOGPU; }`, and
    # it sits ABOVE the `#ifdef HDMI_ATOM`, so it fires in every build. gpu_audio_dig is the FRONT-end stream
    # encoder index the op uses for `d` — nothing to do with sound — and gpu_audio_probe() is the only thing
    # that sets it. Unset ⇒ `run /bin/modeset --transmitter` refuses before the envelope opens, the panel
    # never blinks, and a burn whose oracle is "the panel went dark and came back" reads as a clean pass
    # while proving nothing. ⚠ M8e burned green with the probe UNGATED (pre-1.56.25); this restores that
    # build rather than changing it. The probe writes only the Azalia index window — no DIG, PHY or OTG.
    echo "[2/2] Building the M8e TRANSMITTER-CYCLE kernel (HDMI_ATOM + ATOM_TX_CYCLE + ATOM_TRACE + GPU_AUDIO_PROBE: #76 DISABLE then ENABLE — a REAL PHY edge on the live link. ⛔ THE PANEL WILL GO DARK MID-SEQUENCE and must relight; H2 recovers in one boot. EYE-CHECK the screen)."
    BUILD_REQUIRE="HDMI_ATOM ATOM_TX_CYCLE ATOM_TRACE GPU_AUDIO_PROBE"
    BUILD_ENV="HDMI_ATOM=1 ATOM_TX_CYCLE=1 ATOM_TRACE=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDMI_ATOM+ATOM_TX_CYCLE+ATOM_TRACE"
elif [ -n "${BURN_MODESET_TRANSMITTER_LIVE:-}" ]; then
    # ⛔⛔ M8e — THE DANGEROUS RUNG. ATOM #76 DIG1TransmitterControl(ENABLE) runs LIVE, inside M6's
    # iron-proven OTG envelope, driven from ring 3 by `run /bin/modeset --transmitter`. #76 power-cycles the
    # PHY (556F power + 5E03 lane reset + 5DF0/5DE9 RDPCS among 17 writes) and has blanked this display
    # TWICE. The envelope makes it SURVIVABLE, not safe.
    # Do NOT flash this until M8d (the #76-off rung below) has burned green, because M8d retires every other
    # risk in the sequence and leaves this one edge as the only variable.
    # Recovery, in order: the in-kernel watchdog re-runs the inherited-mode program; if that fails it calls
    # power_reset(); and H2's latch makes that reboot clean and self-disabling (next boot SKIPS the modeset).
    # Worst case is ONE bad boot and `rm /.modeset-armed` — never a reflash.
    # ⛔ GPU_AUDIO_PROBE IS REQUIRED, for the DIG INDEX and not for audio — see the full reasoning on
    # BURN_MODESET_TX_CYCLE above. `mdo_transmit_run()` refuses on gpu_audio_dig < 0 before the `#ifdef
    # HDMI_ATOM`, so without it this op returns MDO_E_NOGPU and the negative control it exists to be is not
    # a control at all: it would run nothing and change nothing, which is indistinguishable from "the edge
    # is a no-op" — the exact conclusion this rung is supposed to establish honestly.
    echo "[2/2] Building the M8e LIVE-TRANSMITTER kernel (HDMI_ATOM + ATOM_RUN_TRANSMITTER + ATOM_TRACE + GPU_AUDIO_PROBE: ATOM #4 AND the LIVE #76 PHY edge inside the OTG envelope. ⛔ THE PANEL MAY GO DARK — H2 recovers in one boot. EYE-CHECK the screen)."
    BUILD_REQUIRE="HDMI_ATOM ATOM_RUN_TRANSMITTER ATOM_TRACE GPU_AUDIO_PROBE"
    BUILD_ENV="HDMI_ATOM=1 ATOM_RUN_TRANSMITTER=1 ATOM_TRACE=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDMI_ATOM+ATOM_RUN_TRANSMITTER+ATOM_TRACE"
elif [ -n "${BURN_MODESET_TRANSMITTER:-}" ]; then
    # M8d — the SAFE transmitter rung, and the one to burn FIRST. `run /bin/modeset --transmitter` runs the
    # whole sequence inside M6's envelope — BE<->FE disconnect, ATOM #4 DIGxEncoderControl (the DIG digital
    # front end at 0x56xx, DISJOINT from the PHY at 0x5Dxx), the infoframe programming, BE<->FE reconnect,
    # OTG re-commit — with ATOM #76 COMPILED OUT. It therefore CANNOT blank the panel the way #76 does, and
    # it retires every risk in the sequence except that one edge.
    # H8 proves the artifact matches this claim in BOTH directions before you flash (verify_marker on the
    # SKIPPED string, verify_absent on the live-edge string).
    # ⛔ GPU_AUDIO_PROBE IS REQUIRED, for the DIG INDEX and not for audio — see BURN_MODESET_TX_CYCLE above.
    # This is the rung the file tells you to burn FIRST, so it is the one whose silent refusal would be
    # costliest: `mdo_transmit_run()` bails on gpu_audio_dig < 0 before any of the sequence runs, and an
    # M8d that refused would retire NONE of the risks the M8e rungs are told it retired.
    echo "[2/2] Building the M8d SAFE-TRANSMITTER kernel (HDMI_ATOM + ATOM_TRACE + GPU_AUDIO_PROBE: ATOM #4 encoder + the full enveloped sequence, #76 COMPILED OUT — cannot blank via the PHY edge)."
    BUILD_REQUIRE="HDMI_ATOM ATOM_TRACE GPU_AUDIO_PROBE"
    BUILD_ENV="HDMI_ATOM=1 ATOM_TRACE=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDMI_ATOM+ATOM_TRACE"
elif [ -n "${BURN_HDMI_ATOM:-}" ]; then
    # THE A4 ENCODER-ONLY BURN (the audio attempt). Iron 1.55.23 proved: the interpreter is bit-correct, but
    # DIG1TransmitterControl(ENABLE) power-cycles the PHY and blanks the live pipe. So this runs
    # DIGxEncoderControl(#4, STREAM_SETUP, HDMI) ONLY — 5 writes in the DIG1 digital front-end (0x56xx),
    # DISJOINT from the PHY (0x5Dxx) — putting DIG1 in true HDMI mode with proper data-island setup, which the
    # raw DIG_MODE bit-flip only half-does. The transmitter (#76) is gated OFF (ATOM_RUN_TRANSMITTER unset).
    # Display risk: at worst a transient, self-recovering front-end flicker (the DIG_START strobe) — the same
    # survivable class as the DIG_MODE flip, NOT the transmitter's non-recoverable blank. Then the proven audio
    # path (gpu_hdmi_audio_enable) runs. LIVE (no ATOM_DRY): the encoder writes are actually applied, RMW'd
    # against the real running registers. ATOM_TRACE logs the 5 writes; HDMI_AUDIO_DUMP keeps the read-back.
    # Recovery if it misbehaves: flash without HDMI_ATOM. PASS IS THE OPERATOR'S EARS: a tone from the XB323U.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). "Then the proven audio path (gpu_hdmi_audio_enable)
    # runs" is this arm's whole second half, and it does not run: preflight refuses while gpu_audio_dig is
    # -1. The burn would apply the five encoder writes, print a healthy ATOM summary, and then go silent at
    # a SILENT early return — a boot that looks like a clean encoder success and a hardware audio refusal.
    echo "[2/2] Building the A4 ENCODER-ONLY kernel (HDA_HDMI + HDA_TONE + HDMI_ATOM + ATOM_TRACE + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: run DIGxEncoderControl(HDMI) LIVE — PHY-safe front-end setup, transmitter SKIPPED — then the audio path. Recoverable flicker at worst; LISTEN for the tone)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_ATOM ATOM_TRACE HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_TRACE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_SWEEP:-}" ]; then
    # THE MATRIX BURN. The register-value class is exhausted (every DCN reg matches amdgpu, still silent),
    # so stop testing one hypothesis per reflash. This kernel, post-sti with the HDA tone already streaming
    # to the HDMI sink, cycles gpu_hdmi_audio_profile(0..N): each applies a candidate structural/sequencing/
    # clock fix to the LIVE encoder, prints "hdmi-sweep: profile N = <name>", and holds ~3s. The operator
    # WATCHES serial + LISTENS — one boot tests the whole matrix. Adds HDMI_AUDIO_DUMP so the register state
    # of the LAST-applied profile is on record. PASS IS STILL THE OPERATOR'S EARS.
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit), and this arm is the most expensive one to lose: the
    # sweep is wrapped in `if (gpu_hdmi_audio_on == 1)` and its else-branch prints "hdmi-sweep: no HDMI audio
    # path -- skipping sweep". Without the flag the operator sits through a boot waiting to hear which of N
    # profiles works and NOT ONE of them is ever applied — a whole matrix, unrun, on one burn.
    echo "[2/2] Building the HDMI-audio MATRIX kernel (HDA_HDMI + HDA_TONE + HDMI_AUDIO_SWEEP + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: cycle every candidate fix in one boot; watch serial + listen for which profile makes sound)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_AUDIO_SWEEP HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_AUDIO_SWEEP=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
    # ⛔ THE TAG MUST NAME EVERY FLAG IN BUILD_ENV. It omitted GPU_AUDIO_PROBE until 2026-08-10, so
    # `burn-verify` printed an ARM that under-reported the build — and GPU_AUDIO_PROBE is the exact flag
    # whose silent absence VOIDED every HDMI-audio burn from 1.56.25 onward. A reader checking the tag to
    # confirm the required set would have concluded it was missing and either re-prepped or, worse, believed
    # a void burn. The tag is a burn artifact's only self-description; an incomplete one is a lie.
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_AUDIO_SWEEP+HDMI_AUDIO_DUMP+GPU_AUDIO_PROBE"
elif [ -n "${BURN_HDMI_QUIET:-}" ]; then
    # ⭐⭐⭐ THE QUIET HOLD — the one condition this sink has never been offered.
    #
    # ⛔ WHY IT EXISTS. Every experiment in this arc re-bounces the link: the --audio-pre/--audio-post arms
    # flip DIG_MODE and restore it, and the 16-profile sweep re-runs gpu_hdmi_audio_enable() as each
    # profile's baseline reset. The 2026-08-10 sweep capture contains `display link switched to HDMI
    # signalling` **34 times in 5.5 minutes**, and the operator listening to it reported "the sound of
    # speaker power and reset" — that WAS the bounce, the amp cycling. ⇒ The sink has never had a stable,
    # untouched link with audio armed for more than ~12 s, so "this sink needs longer than that to lock and
    # then unmute" is UNTESTED and would present as exactly the silence recorded ~24 times.
    #
    # ⛔ THE EXPERIMENT IS THE ABSENCE OF ACTION — no HDMI/DCN/AFMT/ATOM register is written after the
    # boot-time bring-up. ⚠ Do NOT add a "helpful" re-enable, probe or CRC arm to this arm; arming a tap
    # WRITES AFMT_AUDIO_CRC_CONTROL and destroys the only variable. AFMT_STATUS is read (a pure load) every
    # 15 s, which is itself new data: every prior reading was within ~12 s of a bounce.
    #
    # ⭐ The oracle is a PITCH CHANGE across two 45 s phases, not a yes/no — the ring content is the only
    # thing that changes, and a listener reporting the DIRECTION of the change has authenticated the audio
    # as ours. ⚠ Do not tell the operator which phase is which band before the burn.
    #
    # ⛔ MODESET_AUDIO MUST NOT BE SET — it suppresses the boot-time enable, gpu_hdmi_audio_on stays 0, and
    # the hold has no link to hold. The arm prints BURN VOID and names that cause if it happens.
    echo "[2/2] Building the QUIET-HOLD kernel (HDA_HDMI + HDA_TONE + HDMI_QUIET_HOLD + GPU_AUDIO_PROBE: bring the link up ONCE, then touch nothing for 90 s across two tone phases; LISTEN for any sound and for a pitch change)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_QUIET_HOLD GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_QUIET_HOLD=1 GPU_AUDIO_PROBE=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_QUIET_HOLD+GPU_AUDIO_PROBE"
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
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit). The dump is the deliverable and it is doubly gated:
    # gpu_audio_dump()'s call site sits inside `if (audio_sink_ok == 1)`, and the function itself opens with
    # `if (gpu_audio_dig < 0) { return 0; }`. Without the flag the burn produces NO dump — and a missing
    # dump would most likely be read as "the capture went wrong", not "the kernel never programmed anything".
    echo "[2/2] Building the HDMI-audio MEASUREMENT kernel (HDA_HDMI + HDA_TONE + HDMI_AUDIO_DUMP + GPU_AUDIO_PROBE: sovereign DCN audio path + audible sweep + the full register read-back for diffing against amdgpu's known-good)."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE HDMI_AUDIO_DUMP GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_AUDIO_DUMP=1 GPU_AUDIO_PROBE=1"
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
    # ⭐ GPU_AUDIO_PROBE IS REQUIRED (1.56.34 audit) — and on THIS arm the omission is hardest to see, because
    # HDA_HDMI's own instance-1 probe still runs and still prints a healthy `hda: found 1002:1637` / codec /
    # route / bound sequence. Only the DISPLAY half is missing: gpu_hdmi_audio_enable() refuses at preflight
    # while gpu_audio_dig is -1, so DIG_MODE is never flipped, the sink-select never fires, and the tone this
    # arm advertises goes out the analog jack. The boot log reads like a success. It is not one.
    echo "[2/2] Building the HDMI-audio kernel (HDA_HDMI: sovereign DCN display-audio path on 04:00.1; HDA_TONE: audible sweep; GPU_AUDIO_PROBE: finds the live encoder the path is bound to). Analog instance 0 still plays out the front jack."
    BUILD_REQUIRE="HDA_HDMI HDA_TONE GPU_AUDIO_PROBE"
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 GPU_AUDIO_PROBE=1"
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

# --- THE REQUIRED-FLAG GATE — checked ONCE, for every arm ---------------------------------------------
# ⭐ THIS EXISTS BECAUSE THREE CONSECUTIVE BURNS ON 2026-07-31 EACH DISCOVERED ONE MISSING FLAG
# (HDMI_ATOM -> +HDA_HDMI -> +GPU_AUDIO_PROBE). Every one refused for a real reason and every reason was a
# BUILD fact, not the machine. Discovering a required set one iron burn at a time is the failure; a
# declared set checked at PREP time turns each of those three flashes into a one-second abort.
for _f in $BUILD_REQUIRE; do
    case " $BUILD_ENV " in
        *" $_f=1 "*) ;;
        *) echo "burn-prep: ABORT -- this arm declares $_f as required and BUILD_ENV does not set it." >&2
           echo "           BUILD_TAG=$BUILD_TAG" >&2
           echo "           BUILD_ENV=$BUILD_ENV" >&2
           echo "           BUILD_REQUIRE=$BUILD_REQUIRE" >&2
           echo "           Three burns were lost to exactly this; no arm ships past this check." >&2
           exit 1 ;;
    esac
done

# ⛔ THE SENTINEL: AN AUDIO / TRANSMIT ARM THAT DECLARES NOTHING DOES NOT BUILD.
#
# The check above only protects arms that remembered to declare — which is the same "someone remembers"
# mechanism that let gpu_audio_probe() get gated at 1.56.25 with no arm updated, silently voiding EVERY
# HDMI-audio burn for nine cuts. So the requirement to declare is itself enforced: any arm whose BUILD_ENV
# names HDA_HDMI or HDMI_ATOM is, by construction, either an audio arm or a modeset-transmit arm, and both
# families run through gates on gpu_audio_dig. Such an arm must state its required set — including the case
# where GPU_AUDIO_PROBE is deliberately NOT in it (BURN_HDMI_ATOM_HALT freezes the framebuffer before the
# audio enable is reached, so it declares four flags and none of them is the probe).
# ⇒ A NEW ARM CANNOT INHERIT THIS BUG BY OMISSION. It fails here, at prep, in a second.
case " $BUILD_ENV " in
    *" HDA_HDMI=1 "*|*" HDMI_ATOM=1 "*)
        if [ -z "$BUILD_REQUIRE" ]; then
            echo "burn-prep: ABORT -- BUILD_TAG=$BUILD_TAG sets HDA_HDMI or HDMI_ATOM and declares no BUILD_REQUIRE." >&2
            echo "           Both families gate on gpu_audio_dig, which ONLY gpu_audio_probe() sets, which is" >&2
            echo "           #ifdef GPU_AUDIO_PROBE. An undeclared arm here is how every audio burn taken" >&2
            echo "           between 1.56.25 and 1.56.34 would have been void. Declare the arm's required" >&2
            echo "           flags -- including deliberately OMITTING GPU_AUDIO_PROBE, with the reason." >&2
            exit 1
        fi
        ;;
esac

# ⛔⛔ THE STIMULUS SENTINEL: AN EAR-ORACLE ARM WITHOUT A STIMULUS DOES NOT BUILD.
#
# The sentinel above enforces "declare your flags". This one enforces the omission that class does NOT
# cover, and it cost the arc its single most consequential wrong conclusion. M9 (2026-07-24) declared
# every flag correctly, passed every gate that existed, produced a clean log — and measured nothing,
# because MODESET_AUDIO's arms are adjudicated by the OPERATOR'S EAR and the ring they fed the encoder
# was zero-filled. "Silent, silent" was structurally guaranteed, and it was recorded as the falsification
# of the sequencing candidate, narrowing the arc to two candidates on the strength of a null experiment.
#
# ⭐ A MISSING STIMULUS IS WORSE THAN A MISSING BUILD FLAG. Every flag omission this file has suffered at
# least produced a refusal line naming a precondition. A silent ring produces a complete, healthy,
# entirely believable log. Nothing downstream can tell it from a hardware answer.
#
# MODESET_AUDIO is exactly the ear-adjudicated family, so it must carry HDA_TONE. (Arms whose oracle is a
# PHOTOGRAPH or a register read are not covered and must not be — BURN_HDMI_ATOM_HALT's frozen framebuffer
# would be actively degraded by a running feed.)
case " $BUILD_ENV " in
    *" MODESET_AUDIO=1 "*)
        case " $BUILD_REQUIRE " in
            *" HDA_TONE "*) ;;
            *) echo "burn-prep: ABORT -- BUILD_TAG=$BUILD_TAG sets MODESET_AUDIO and does not require HDA_TONE." >&2
               echo "           MODESET_AUDIO arms are adjudicated by the operator's EAR. Without HDA_TONE," >&2
               echo "           hda_stream_arm zero-fills the 64 KB PCM ring and BOTH arms stream exact" >&2
               echo "           silence -- a control and a treatment that are byte-identical non-experiments." >&2
               echo "           That is what voided M9 on 2026-07-24 and produced the false 'sequencing is a" >&2
               echo "           dead lead' finding. If two arms must stay blinded, vary the tone FREQUENCY" >&2
               echo "           between them; do not remove the tone." >&2
               exit 1 ;;
        esac
        ;;
esac

# AMBIENT-ENV LEAK, closed 2026-07-19. `env $BUILD_ENV` ADDS to the inherited environment — it does not
# replace it. So an exported HDMI_ATOM=1 (or any other flag) lingering in the operator's shell from an earlier
# experiment reaches build.sh and gets #define'd REGARDLESS of the profile selected above, silently producing
# an artifact that is not the one the burn tag names. Same family as the ATOM_DRY no-op: the tag stops
# describing the binary. Clear every known build flag first, then apply only the profile's own.
# ⚠ WIDENED 1.56.34. The list named ten flags while the audio arms above use fifteen, so five could still
# leak — and two of them are not cosmetic: an exported ATOM_TX_CYCLE would add a LIVE #76 PHY edge to an arm
# whose tag promises none, and an exported GPU_AUDIO_PROBE would silently supply the very flag the
# required-flag gate above exists to make explicit, so a build could pass the gate for the wrong reason.
if ! env -u HDA_HDMI -u HDA_TONE -u HDMI_DCCG -u HDMI_ATOM -u HDMI_AUDIO_DUMP -u HDMI_AUDIO_SWEEP \
        -u HDMI_ACR_CTS -u HDMI_SYMCLK_AB -u GPU_AUDIO_PROBE -u MODESET_AUDIO -u ATOM_TX_CYCLE \
        -u ATOM_DRY -u ATOM_TRACE -u ATOM_HALT -u ATOM_RUN_TRANSMITTER \
        -u EXT2_WRITE_SELFTEST -u EXEC_SELFTEST -u THREAD_SELFTEST \
        $BUILD_ENV sh scripts/build.sh >/tmp/burn-prep-build.log 2>&1; then
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
# verify_absent — THE OTHER HALF OF THE GATE, and M8 is why it exists.
#
# verify_marker proves a flag's code IS in the artifact. For a DESTRUCTIVE flag you need the opposite proof
# just as badly: that the build you are about to flash does NOT carry the dangerous path. ATOM #76
# (DIG1TransmitterControl) power-cycles the PHY and has blanked this display twice — once because ATOM_DRY
# was a flag build.sh never emitted, so "dry" and "live" compiled BYTE-IDENTICAL and nothing could tell them
# apart. A presence-only check cannot catch that class: it fails open in the destructive direction.
#
# So for the transmitter burns the marker pair is checked BOTH ways — the live-edge string must be present
# in the live build and ABSENT in the safe one — which makes the two builds provably distinguishable before
# the flash rather than after the panel goes dark.
verify_absent() {
    if grep -qa "$1" build/agnos; then
        echo ""
        echo "burn-prep: ARTIFACT-MISMATCH -- build/agnos DOES contain '$1' and must not"
        echo "  BUILD_TAG=$BUILD_TAG is the SAFE variant, but the artifact carries the destructive path."
        echo "  Flashing this could drive the PHY when you expected it not to. DO NOT FLASH THIS."
        exit 1
    fi
}
case "$BUILD_TAG" in *HDA_HDMI*)         verify_marker "ctl1 probing 2nd controller" ;; esac
# ⭐ GPU_AUDIO_PROBE — the flag whose absence would have voided every HDMI-audio burn taken between 1.56.25
# and 1.56.34, and the only one keyed on BUILD_REQUIRE rather than BUILD_TAG. That is deliberate and it is
# what closes the loop end to end: the arm DECLARES the flag (BUILD_REQUIRE) -> the gate above proves it is
# in BUILD_ENV -> this proves it survived into the artifact. Keying on the tag would miss it entirely,
# because several arms that need it (CRCCAL, the three M-lane transmitter arms) do not name it in their tag.
# ⚠ The marker is main.cyr's banner INSIDE the #ifdef, never a string from gpu_audio_probe() itself: that
# function's body is not gated, so its own text is present in a bare kernel and would verify nothing.
case " $BUILD_REQUIRE " in
    *" GPU_AUDIO_PROBE "*) verify_marker "gpu: display audio probe armed" ;;
esac
# ⭐⭐ HDA_TONE — THE STIMULUS, and it gets the same end-to-end treatment as GPU_AUDIO_PROBE, keyed on
# BUILD_REQUIRE as well as BUILD_TAG. Its absence is what voided M9 on 2026-07-24: both arms of the
# sequencing A/B streamed a zero-filled ring, so "silent, silent" was structurally guaranteed and got
# written down as the falsification of the sequencing candidate. Nothing anywhere REFUSES when the tone
# is missing -- a stimulus omission is silent all the way down, which makes it strictly worse than a
# missing build flag, every one of which at least produced a refusal line. So an arm whose oracle is the
# operator's EAR declares its stimulus, and the declaration is proven into the artifact here.
case " $BUILD_REQUIRE " in
    *" HDA_TONE "*) verify_marker "sweep streaming" ;;
    *) case "$BUILD_TAG" in *HDA_TONE*) verify_marker "sweep streaming" ;; esac ;;
esac
case "$BUILD_TAG" in *HDMI_AUDIO_DUMP*)  verify_marker "== agnos display-audio dump ==" ;; esac
case "$BUILD_TAG" in *HDMI_AUDIO_SWEEP*) verify_marker "hdmi-sweep: cycling" ;; esac
# MARKER-COVERAGE GAP, closed 2026-07-19. The four arms above covered only the HDA_* / HDMI_AUDIO_* flags,
# yet the "markers verified" line below claims the WHOLE $BUILD_TAG is compiled AND reached. So every
# HDMI_DCCG and ATOM_* burn shipped unverified for the very flag under test — the 1.55.24 DCCG burn included
# (it happened to carry its kprintln, but that was luck, not process). This is the ATOM_DRY defect's family:
# a flag whose presence in the tag was never proven in the artifact. Each marker below is a kprintln inside
# the flag's own #ifdef, in a function called unconditionally, so it satisfies verify_marker's own rule.
# ── M9 (MODESET_AUDIO). FOUR arms, and they are bidirectional: the audio arms must be PRESENT in
# ── RUNG 5. Bidirectional: the wedge arm must be PRESENT in a GPU_RECOVER build and ABSENT from
# every other one. The first GPU_RECOVER build DID silently lose the flag (build.sh had no such
# flag yet) and compiled byte-identical to bare — the ATOM_DRY class, caught by comparing sizes.
# This arm makes that impossible to ship.
case "$BUILD_TAG" in
    *GPU_RECOVER*)
        verify_marker "ARM A -- controlled wedge"
        verify_marker "submitting a WAIT_REG_MEM that can never be satisfied"
        # The ladder is compiled into EVERY build, so it must be here too — without it arm A
        # would hang the box with no way back.
        verify_marker "RECOVERY LADDER"
        ;;
    *)
        verify_absent "submitting a WAIT_REG_MEM that can never be satisfied"
        ;;
esac
# an M9 build and ABSENT from every other one. Without the negative half, a build that silently
# lost the flag would still pass — which is the ATOM_DRY defect exactly (two artifacts that differ
# in name and not in behaviour).
case "$BUILD_TAG" in
    *MODESET_AUDIO*)
        verify_marker "ARM 1 CONTROL: unmute BEFORE the edge"
        verify_marker "ARM 2 TREATMENT: unmute AFTER the edge"
        # The DIG_MODE fold — proves the audio arms flip signalling to HDMI. Arm 0 must not.
        verify_marker "DIG_MODE 2 -> 3 (HDMI signalling live; audio arm)"
        # M9c: boot must NOT perform the bring-up, or a boot-time unmute latches the sink before
        # the op ever runs and both arms measure the same pre-latched state.
        verify_marker "boot-time hdmi audio SUPPRESSED"
        # ⚠ HONEST CAVEAT on the *HDMI_AUDIO_DUMP* arm above: under MODESET_AUDIO the BOOT call to
        # gpu_audio_dump() is suppressed (M9c), so that marker proves the string is COMPILED but no
        # longer that it is REACHED at boot. It is still reached via `run /bin/dump`. Do not read
        # that one as a reachability proof in an M9 build.
        ;;
    *)
        # ⛔ NEGATIVE HALF: no other build may carry the audio arms.
        verify_absent "ARM 1 CONTROL: unmute BEFORE the edge"
        verify_absent "ARM 2 TREATMENT: unmute AFTER the edge"
        ;;
esac
# ⛔⛔ THE STAGED TOOL MUST MATCH THE ONE JUST BUILT.
# install-media.sh flashes /bin/* from build/rootfs/bin/, NOT from each tool's own build dir.
# On 2026-07-24 the M9 burn shipped a correct kernel (opmask=511, both arms advertised) paired
# with a modeset tool from SIX HOURS EARLIER that had no --audio-pre at all. Both arms fell
# through to the caps probe, which returns 95 on a lit panel — indistinguishable from success.
# The operator ran the experiment twice, heard silence twice, and none of it was data.
# burn-prep verified the KERNEL artifact and never looked at the tools it would be flashed with.
# ⛔⛔ AND THE LIST MUST CONTAIN THE BURN'S ORACLE. 1.56.23 nearly repeated M9 exactly: the kernel
# gained op 0x0C, but /bin/gputex — the ONLY tool that exercises it — was absent from this list, and
# the staged copy was 90 minutes stale (213672 B vs 255424 B, different md5). It had no rung-14 code
# at all. The run would have printed rung 13's 17 cases, exited 95, and produced ZERO rung-14 data
# while reading as a clean success. The gate existed, verified four tools, and did not verify the
# one the burn was for.
# ⇒ WHEN A CYCLE'S ORACLE IS A NEW OR CHANGED TOOL, ADD IT HERE IN THE SAME BITE. A tool absent from
# this loop is a tool that can be silently stale, and a stale oracle does not fail — it agrees.
# ⛔⛔ agnsh ADDED 2026-08-07 AFTER THE BURN THAT NEEDED IT RAN TWO VERSIONS STALE. The 1.56.41 desktop
# burn's whole claim was "the hosted SHELL answers", and `/bin/agnsh` in the rootfs was **1.8.6** against
# agnoshi's `VERSION` of **1.8.8** — because this loop did not cover it. The shell did answer, so nothing
# was invalidated, but the answer came from a build nobody meant to test. That is the third instance of the
# failure this loop's own comment names: a tool absent from here is a tool that can be silently stale, and
# a stale oracle does not fail, it AGREES. ⚠ agnsh is staged by `stage-agnsh.sh`, not `stage-tools.sh`, and
# living in a different script is exactly why it was missed.
for _t in modeset gpuwedge gputri gputex gpucov gpublend gpublit gpufill gpucopy gpudepth klug aethersafha puka crab agnsh; do
    _src=""
    _puka_alt=""
    case "$_t" in
        modeset)  _src="tests/gpu/build/modeset_agnos" ;;
        gpuwedge) _src="tests/gpu/build/gpuwedge_agnos" ;;
        gputri)   _src="tests/gpu/build/gputri_agnos" ;;
        gputex)   _src="tests/gpu/build/gputex_agnos" ;;    # rungs 13 + 14 oracle
        gpudepth) _src="tests/gpu/build/gpudepth_agnos" ;;  # rung 17 op 0x0D oracle
        gpucov)   _src="tests/gpu/build/gpucov_agnos" ;;
        gpublend) _src="tests/gpu/build/gpublend_agnos" ;;
        gpublit)  _src="tests/gpu/build/gpublit_agnos" ;;
        gpufill)  _src="tests/gpu/build/gpufill_agnos" ;;
        gpucopy)  _src="tests/gpu/build/gpucopy_agnos" ;;
        klug)    _src="" ;;   # klug is staged from its own repo; size-compare only
        # ⛔ ADDED 2026-08-02 AFTER THIS GATE MISSED IT. The desktop burn staged an aethersafha
        # NINE HOURS OLD -- no geometry fix, none of the new diagnostics -- and every check passed,
        # because the only aethersafha check was a grep for "--selftest" and the OLD binary had that
        # string too. Exactly the gputex failure one cycle earlier: the gate existed, verified the
        # tools it knew about, and did not know about the one the burn was for.
        # ⚠ Unlike klug, this one CAN be compared: aethersafha builds a real --agnos artifact at a
        # known path, so compare bytes rather than settling for size-only.
        aethersafha) _src="../aethersafha/build/aethersafha_agnos" ;;
        # ⛔ RETIRED TRANSPORT — STAGED, NOT A BURN OBJECTIVE. These two are aethersafha's setu
        # clients, which connect back over loopback:7700. Operator ruling 2026-08-03: TCP-on-
        # loopback is the WRONG PRIMITIVE for local display IPC and is being removed in favour of
        # the agnos socket (naadi — docs/development/planning/ipc.md §9, removal inventory §10).
        # They stay in this loop only so the staleness gate keeps matching what stage-tools.sh
        # actually stages; DO NOT plan a burn around whether they present, and do not read a
        # no-present as a defect in the clients, in crab, in spawn_path, or in the compositor —
        # it indicts a path that is being deleted. The desktop's iron oracle is
        # `run /bin/aethersafha --selftest` (single process, no network state), gated below.
        # ⭐ /bin/puka may legitimately be EITHER of two binaries, so this row is resolved below
        # rather than here — see the `_puka_alt` block. Default is setu's slim present_probe (the
        # compositor's first-resident slot); `PUKA_TERMINAL=1 sh scripts/burn/stage-tools.sh` puts the
        # real terminal there, which is what an iron burn of `AE-T2` requires.
        puka)        _src="../setu/build/puka_agnos" ; _puka_alt="../puka/build/puka_agnos" ;;
        crab)        _src="../crab/build/crab_agnos" ;;
        agnsh)       _src="../agnoshi/build/agnsh_agnos" ;;
    esac
    _staged="build/rootfs/bin/$_t"
    if [ ! -f "$_staged" ]; then
        echo "burn-prep: STAGING GAP -- $_staged is MISSING. install-media would flash no $_t."
        echo "  Fix:  sh scripts/burn/stage-tools.sh"
        exit 1
    fi
    # ⭐ A SLOT WITH TWO LEGITIMATE OCCUPANTS IS RESOLVED BY MATCHING, AND THE ANSWER IS PRINTED.
    # /bin/puka is either setu's present_probe (default) or the real puka terminal
    # (`PUKA_TERMINAL=1 stage-tools.sh`, which an iron `AE-T2` burn needs). ⛔ Accepting either must NOT
    # weaken the gate into "anything goes": a binary matching NEITHER source is still stale and still
    # aborts. What this buys is that the prep SAYS which one the operator is about to flash — the slot
    # has misled every reader of stage-tools.sh since it was created, and a burn card that assumes the
    # wrong occupant asks the operator to look for a terminal that was never staged.
    if [ -n "$_puka_alt" ] && [ -f "$_puka_alt" ] && cmp -s "$_puka_alt" "$_staged"; then
        echo "burn-prep: /bin/puka is the REAL TERMINAL ($(stat -c%s "$_staged") bytes) -- AE-T2 is burnable"
        _src=""
    elif [ -n "$_src" ] && [ -f "$_src" ] && cmp -s "$_src" "$_staged"; then
        if [ -n "$_puka_alt" ]; then
            echo "burn-prep: /bin/puka is setu's present_probe ($(stat -c%s "$_staged") bytes) -- NOT the terminal."
            echo "           An AE-T2 burn needs:  PUKA_TERMINAL=1 sh scripts/burn/stage-tools.sh"
        fi
        _src=""
    fi
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        if ! cmp -s "$_src" "$_staged"; then
            echo "burn-prep: STALE STAGED TOOL -- build/rootfs/bin/$_t differs from $_src"
            echo "  staged: $(stat -c%s "$_staged") bytes, $(stat -c%y "$_staged" | cut -d. -f1)"
            echo "  built:  $(stat -c%s "$_src") bytes, $(stat -c%y "$_src" | cut -d. -f1)"
            echo "  install-media.sh flashes the STAGED one, so the burn would carry the old tool."
            echo "  Fix:  sh scripts/burn/stage-tools.sh"
            exit 1
        fi
    fi
done

# ⛔⛔ AND THE BUILD ITSELF MUST BE NEWER THAN ITS SOURCE. Found 2026-07-27, one level deeper than
# the gap above and by the same route — a rung whose oracle read as a clean success on stale code.
#
# `stage-tools.sh` only COMPILES when passed --build; without it, stage_one copies whatever
# build/<name>_agnos already exists and prints "staged: ... bytes", which reads exactly like a fresh
# stage. The cmp loop above then compares that staged copy against the SAME stale artifact and
# reports MATCH. ⇒ The gate could confirm "staged == built" while both were older than the source.
#
# On the rung-14b prep, /bin/gputex was 313448 B with NO col-major code in it (the real build is
# 331232 B). It would have run rungs 13 and 14, exited 95, and produced ZERO rung-14b evidence.
# The previous cycle's lesson recurring verbatim: A STALE ORACLE DOES NOT FAIL, IT AGREES.
#
# ⛔⛔⛔ AND THE LIST ITSELF WAS THE NEXT INSTANCE OF THE SAME BUG (2026-07-31). It was hardcoded as
# eight names — gpuwedge gputri gputex gpucov gpublend gpublit gpufill gpucopy — and **`modeset` was not
# among them**, while the comment four lines above congratulated itself for DERIVING the summary message
# rather than hardcoding it. So the gate printed "every --agnos build is newer than its source" over a
# `/bin/modeset` that was **twelve hours older than the source it was supposedly built from**, on a burn
# whose entire oracle is `/bin/modeset`. The operator caught it by hand, from an md5 line, after flashing.
# ⇒ **DERIVE THE LIST FROM stage-tools.sh.** A tool that is staged is a tool that can go stale; the two
# lists must be the same list, or the gate silently stops covering whatever was added most recently —
# which is always the thing the current burn is about.
_srcstale=0
_tools=$(sed -n 's/^[[:space:]]*stage_one[[:space:]]\+agnos\/tests\/gpu[[:space:]]\+[^[:space:]]\+\.cyr[[:space:]]\+\([^[:space:]|]*\).*/\1/p' scripts/burn/stage-tools.sh)
if [ -z "$_tools" ]; then
    echo "burn-prep: ABORT -- could not derive the staged-tool list from stage-tools.sh."
    echo "           The staleness gate would silently cover NOTHING. Fix the parse, do not bypass it."
    exit 1
fi
for _t in $_tools; do
    _cyr="tests/gpu/$_t.cyr"
    _bin="tests/gpu/build/${_t}_agnos"
    [ -f "$_cyr" ] || continue
    if [ ! -f "$_bin" ]; then
        echo "burn-prep: NO --agnos BUILD for $_t -- the cmp above SKIPS it, so staleness is invisible."
        echo "  Fix:  sh scripts/burn/stage-tools.sh --build"
        _srcstale=1
        continue
    fi
    if [ "$_cyr" -nt "$_bin" ]; then
        echo "burn-prep: SOURCE NEWER THAN BUILD -- $_cyr is newer than $_bin"
        echo "  source: $(stat -c%y "$_cyr" | cut -d. -f1)"
        echo "  build:  $(stat -c%y "$_bin" | cut -d. -f1)"
        echo "  The staged tool would carry code this burn is NOT for, and would still exit 95."
        echo "  Fix:  sh scripts/burn/stage-tools.sh --build     (plain stage-tools does NOT compile)"
        _srcstale=1
    fi
done
[ "$_srcstale" -eq 0 ] || exit 1
# ⚠ DERIVED, NOT HARDCODED. This line used to name four tools while the loop checked ten — a message
# that could disagree with the thing it reports on, which is how the gate read as covering gputex
# when the reader had no way to tell.
echo "  staged tools match their builds, and every --agnos build is newer than its source"
case "$BUILD_TAG" in
    *GPU_RECOVER*)
        # ⛔ The staged tool must be able to invoke the arms, or the burn's own oracle is
        # unreachable — exactly what wasted the first M9 flash.
        for _m in "--wedge" "--recover" "--baseline" "--verify" "--console"; do
            if ! grep -qa -- "$_m" build/rootfs/bin/gpuwedge 2>/dev/null; then
                echo "burn-prep: STAGED /bin/gpuwedge LACKS '$_m' -- the burn's oracle cannot be invoked."
                exit 1
            fi
        done
        echo "  staged /bin/gpuwedge carries all five arms"
        ;;
esac
# ⛔ RUNG 9b: the oracle must be INVOKABLE from the staged binary, not merely present. Same gate
# as GPU_RECOVER above and for the same reason -- on 2026-07-24 a burn shipped a correct kernel
# with a tool six hours old that lacked the arm under test; both arms fell through to a probe
# that returns 95, and two runs of the experiment produced no data at all.
for _m in "--cov" "--digest" "--bench"; do
    if ! grep -qa -- "$_m" build/rootfs/bin/gputri 2>/dev/null; then
        echo "burn-prep: STAGED /bin/gputri LACKS '$_m' -- rung 9b's oracle cannot be invoked."
        echo "  Fix:  sh scripts/burn/stage-tools.sh"
        exit 1
    fi
done
# ⛔ RUNG 14b: gputex must carry the COL-MAJOR arm, not merely be fresh. Same doctrine as gputri's
# --cov/--digest/--bench and gpuwedge's five arms: presence of the tool is not presence of the
# experiment. A gputex without these strings runs rungs 13 and 14, prints its cases, and exits 95 —
# a clean green that contains no rung-14b data at all.
for _m in "COL-MAJOR did not reproduce" "waves: row-major" "1 x 0x0C CM"; do
    if ! grep -qa -- "$_m" build/rootfs/bin/gputex 2>/dev/null; then
        echo "burn-prep: STAGED /bin/gputex LACKS '$_m' -- rung 14b's oracle cannot be invoked."
        echo "  It would still exit 95 on rungs 13+14. Fix:  sh scripts/burn/stage-tools.sh --build"
        exit 1
    fi
done
echo "  staged /bin/gputex carries the rung-14b col-major arm"
# ⛔ RUNG 15: the same doctrine again, and it is NOT redundant with the block above. A gputex staged
# from before 1.56.29 carries every col-major string, passes that check, runs rungs 13/14/14b and
# exits 95 — a clean green with ZERO bilinear data in it, on a burn whose whole purpose is bilinear.
# ⚠ The third string is the DISCRIMINATION gate specifically. Byte-identity against the bilinear
# reference is necessary and not sufficient: if the kernel silently dispatched the NEAREST blob, the
# arm goes green on any frame where the two filters agree. Staging a gputex whose bilinear arm lacks
# that check would make the burn unfalsifiable in exactly the way gputri's missing negative controls
# would — which is the defect the block below this one exists to prevent.
for _m in "BILINEAR -- 4-tap integer filter" "vs NEAREST: " "IDENTICAL to nearest on every frame" \
          "BILINEAR at 1:1 differs from NEAREST in"; do
    if ! grep -qa -- "$_m" build/rootfs/bin/gputex 2>/dev/null; then
        echo "burn-prep: STAGED /bin/gputex LACKS '$_m' -- rung 15's oracle cannot be invoked."
        echo "  It would still exit 95 on rungs 13+14+14b. Fix:  sh scripts/burn/stage-tools.sh --build"
        exit 1
    fi
done
echo "  staged /bin/gputex carries the rung-15 bilinear arm, its discrimination gate AND the 1:1 identity gate"

# ⭐ And it must carry the NEGATIVE CONTROLS. A gputri without N1-N8 can still print "20 of 20",
# and TWO of the twenty corpus cases have an ALL-ZERO correct answer -- so a shader that writes
# nothing reproduces them byte-exactly. Staging a control-less build makes the burn unfalsifiable.
if ! grep -qa -- "NEGATIVE CONTROL N" build/rootfs/bin/gputri 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gputri has NO negative controls -- its 20/20 would be"
    echo "  satisfiable by a shader that writes nothing. Rebuild and re-stage."
    exit 1
fi
echo "  staged /bin/gputri carries --cov, --digest, --bench and the N1-N8 controls"

# ⭐ THE DEPTH ARM, AND ITS Z READBACK SPECIFICALLY. A gputri staged without --depth pairs a NEW
# kernel with a tool that cannot ask it anything — the silent-stale-tool failure this whole block
# exists to prevent, and the same shape as the gputex bilinear-arm check above.
# ⛔ The z readback is checked SEPARATELY and is not a nicety: measured on the host, a divide with
# its correction dropped moves order-independence by ZERO pixels, and a uniform z bias of any size
# moves it by zero while corrupting all 507. Colour-only, this burn CANNOT FAIL on a broken divide
# — which is the only thing the depth rung adds.
if ! grep -qa -- "RUNG 17 -- depth-tested triangles" build/rootfs/bin/gputri 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gputri has NO --depth arm -- a new kernel would be paired with a"
    echo "  tool that cannot exercise it. Rebuild and re-stage."
    exit 1
fi
if ! grep -qa -- "z read back via op 0x10" build/rootfs/bin/gputri 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gputri --depth does NOT read z back. Order-independence alone is"
    echo "  measurably blind to a broken divide (0 px), so the burn could not fail on it."
    exit 1
fi
echo "  staged /bin/gputri carries the rung-17 --depth arm AND its z readback via op 0x10"

# ⭐ RUNG 18's ARM, AND ITS DISCRIMINATOR SPECIFICALLY. A gputri without --persp pairs a new kernel with
# a tool that cannot exercise it. ⛔ And the discriminator is checked SEPARATELY because matching the
# perspective reference is NECESSARY BUT NOT SUFFICIENT: measured on this figure, affine texturing is
# wrong at 1540 of 1541 covered pixels, so without the affine comparison a green result is consistent
# with the divide never happening -- the shape of both burns this arc has already lost.
if ! grep -qa -- "RUNG 18 -- perspective-correct textured triangles" build/rootfs/bin/gputri 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gputri has NO --persp arm -- a new kernel would be paired with a"
    echo "  tool that cannot exercise it. Rebuild and re-stage."
    exit 1
fi
if ! grep -qa -- "vs AFFINE" build/rootfs/bin/gputri 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gputri --persp does NOT compare against the AFFINE reference."
    echo "  Matching perspective alone cannot distinguish a working divide from no divide at all."
    exit 1
fi
echo "  staged /bin/gputri carries the rung-18 --persp arm AND its affine discriminator"
# ⛔ RUNG 17: gpudepth must carry its WARM-UP, not merely exist. Its first burn measured its own
# instrument -- gpu_rt_arm() runs the rung-6 audit on the first call of a boot, and that audit ends in
# a 64 KB klug_spill() to NVMe, which landed INSIDE the timed loop and outweighed the measurement
# ~500x. A pre-warm-up gpudepth still runs, still prints totals, and still exits 94 against a worker
# that is fine -- a green-looking red with a wrong diagnosis. Presence of the tool is not presence of
# the correction.
if ! grep -qa -- "armed (the rung-6 audit ran OUTSIDE" build/rootfs/bin/gpudepth 2>/dev/null; then
    echo "burn-prep: STAGED /bin/gpudepth LACKS its warm-up -- it would time the rung-6 audit."
    echo "  Fix:  sh scripts/burn/stage-tools.sh --build"
    exit 1
fi
echo "  staged /bin/gpudepth warms up outside the timed region"
# ⭐ THE DESKTOP: /bin/aethersafha must be present AND must carry its oracle flag.
# ⛔ This binary has two completely different behaviours off one argument. Bare, it starts the real
# compositor, takes the screen and never returns. With --selftest it composites a sentinel surface,
# reads the frame back through #90 before the #84 flip, and exits with a verdict. A build that
# somehow lost the flag would not error -- `run /bin/aethersafha --selftest` would silently fall
# through to the DESKTOP, the operator would see a desktop appear, and "the desktop came up" reads
# like success while the oracle never ran and no exit code was ever produced. That is the same shape
# as the argv bug that made `bnrmr agnos` print help instead of rendering, and it is why presence of
# the tool is not presence of the test.
# ⚠ Absence is a WARNING, not an abort: most burns do not drive the desktop, and this file is not
# the place to decide that for the operator. A burn whose oracle IS the desktop needs both lines.
if [ ! -x "$ROOT/build/rootfs/bin/aethersafha" ]; then
    echo "  ⚠ /bin/aethersafha is NOT staged — if this burn drives the desktop, run:  sh scripts/burn/stage-tools.sh --build"
else
    if ! grep -qa -- "--selftest" "$ROOT/build/rootfs/bin/aethersafha" 2>/dev/null; then
        echo "burn-prep: STAGED /bin/aethersafha LACKS --selftest — it would silently start the DESKTOP instead."
        echo "  Fix:  sh scripts/burn/stage-tools.sh --build"
        exit 1
    fi
    echo "  staged /bin/aethersafha carries its --selftest oracle"
fi
case "$BUILD_TAG" in
    *MODESET_AUDIO*)
        # The flags the operator is told to type MUST exist in the binary that gets flashed.
        for _m in "--audio-pre" "--audio-post" "ARM 1 CONTROL" "ARM 2 TREATMENT"; do
            if ! grep -qa -- "$_m" build/rootfs/bin/modeset; then
                echo "burn-prep: STAGED TOOL LACKS '$_m' -- the burn's own oracle cannot be invoked."
                exit 1
            fi
        done
        echo "  staged /bin/modeset carries both M9 arms"
        ;;
esac
case "$BUILD_TAG" in *HDMI_DCCG*)        verify_marker "hdmi DCCG symclk re-prime" ;; esac
case "$BUILD_TAG" in *HDMI_SYMCLK_AB*)   verify_marker "symclk-ab: in-boot A/B" ;; esac
case "$BUILD_TAG" in *HDMI_ACR_CTS*)     verify_marker "hdmi acr cts programmed" ;; esac
case "$BUILD_TAG" in *SCANOUT_PATTERN*)  verify_marker "scanout pattern probe armed" ;; esac
case "$BUILD_TAG" in *SCANOUT_REDIRECT*) verify_marker "console redirected to agnos scanout buffer" ;; esac
# ⚠ NOT "HUBP regdump begin" — that string lives INSIDE gpu_scanout_regdump(), an always-compiled function,
# and this tree does not run DCE by default, so it is present in EVERY binary and verified nothing. The
# marker must be a kprintln inside the flag's own #ifdef; this one is the boot call site's banner.
case "$BUILD_TAG" in *SCANOUT_REGDUMP*)  verify_marker "hubp regdump build armed" ;; esac
# --- H8, the M8 transmitter gate: the marker pair, checked in BOTH directions ---------------------------
# HDMI_ATOM alone is the SAFE transmitter build (envelope + ATOM #4 encoder; #76 compiled OUT). It must
# carry the SKIPPED marker and must NOT carry the live-edge string.
case "$BUILD_TAG" in
    *ATOM_RUN_TRANSMITTER*) ;;                                   # enable-only rung — its own arm below
    *ATOM_TX_CYCLE*) ;;                                          # the real-edge rung — its own arm below
    *HDMI_ATOM*)
        # Plain HDMI_ATOM = the SAFE transmitter build: #4 runs, no form of #76 does.
        verify_marker "ATOM #76 SKIPPED"
        verify_absent "ENABLE only (negative control"
        verify_absent "CYCLE: DISABLE then ENABLE"
        ;;
esac
# ATOM_RUN_TRANSMITTER is the DESTRUCTIVE build: the live-edge string must be present and the SKIPPED
# string absent. Both halves matter — a build carrying neither would mean mdo_transmit did not compile at all.
case "$BUILD_TAG" in *ATOM_RUN_TRANSMITTER*)
        verify_marker "ATOM #76 ENABLE only (negative control"
        verify_absent "ATOM #76 SKIPPED"
        verify_absent "CYCLE: DISABLE then ENABLE"
        ;;
esac
# ⛔ M8e — the REAL transmitter edge (DISABLE then ENABLE). The most destructive build in the arc, so the
# marker pair is checked BOTH ways, exactly like the enable-only rung.
# ⚠ KEY ON THE mdo_transmit STRINGS, NEVER on atom.cyr's "76 DISABLE phyid": that text lives in
# atom_run_transmitter_disable_hdmi(), which COMPILES under plain HDMI_ATOM whether or not anything calls
# it — so it is present in all three transmitter builds and discriminates nothing. Same false-assuring
# trap as the old "atom: running DIGxEncoderControl" marker.
case "$BUILD_TAG" in *ATOM_TX_CYCLE*)
        verify_marker "CYCLE: DISABLE then ENABLE"
        verify_absent "ATOM #76 SKIPPED"
        verify_absent "ENABLE only (negative control"
        ;;
esac
case "$BUILD_TAG" in *SCANOUT_MATCHGEOM*) verify_marker "scanout matchgeom armed" ;; esac
case "$BUILD_TAG" in *SDMA_PROBE*)       verify_marker "sdma probe armed" ;; esac
case "$BUILD_TAG" in *SDMA_RING*)        verify_marker "sdma ring bringup armed" ;; esac
case "$BUILD_TAG" in *SDMA_COPY*)        verify_marker "sdma ring bringup armed" ;; esac
case "$BUILD_TAG" in *ATOM_DRY*)         verify_marker "atom: DRY build (no MMIO)" ;; esac
# ⚠ FALSE-ASSURING MARKER, FIXED. This used to verify "atom: running DIGxEncoderControl", which lives in
# atom_hdmi_transmitter_bringup() — whose ONLY caller is main.cyr's #ifdef HDA_HDMI block. In an
# HDMI_ATOM-without-HDA_HDMI build (exactly the M8d/M8e transmitter burns) that string is present in the
# artifact and NEVER EXECUTES, while the summary below claims "compiled AND reached". That is the same
# class of defect verify_marker's own header warns about. The M-lane transmitter burns are driven from
# mdo_transmit, so verify a string from THERE; keep the old marker only for the HDA_HDMI audio builds.
case "$BUILD_TAG" in
    *HDMI_ATOM*)
        case "$BUILD_TAG" in
            *HDA_HDMI*) verify_marker "atom: running DIGxEncoderControl" ;;
            *)          verify_marker "modeset: transmit -- ATOM #4 DIGxEncoderControl" ;;
        esac
        ;;
esac
# ATOM_TRACE is the transmitter burns' ONLY non-eye instrument (it logs each ATOM MMIO write), and it had
# no marker at all — a silently-dropped ATOM_TRACE would cost the burn its write list.
case "$BUILD_TAG" in *ATOM_TRACE*)       verify_marker "atom w=" ;; esac

SZ="$(stat -c %s build/agnos 2>/dev/null)"
MT="$(stat -c %y build/agnos 2>/dev/null | cut -d. -f1)"
VER="$(cat VERSION 2>/dev/null)"
SUM="$(sha256sum build/agnos 2>/dev/null | cut -c1-16)"
echo "  build/agnos: $SZ bytes, built $MT  (AGNOS $VER, $BUILD_TAG)"
if [ "$BUILD_TAG" != "bare" ]; then
    echo "  markers verified: the $BUILD_TAG code is compiled AND reached (not merely present)."
fi

# Stamp the artifact so staleness is DETECTABLE rather than silent. `sh scripts/burn/burn-verify.sh` re-checks
# this before a flash; a mismatch means something rebuilt build/agnos since burn-prep ran.
printf '%s\n%s\n%s\n%s\n' "$BUILD_TAG" "$SZ" "$VER" "$(sha256sum build/agnos | cut -d" " -f1)" > build/agnos.burn-tag
echo "  stamped build/agnos.burn-tag ($SUM...) -- re-check with: sh scripts/burn/burn-verify.sh"
echo ""
echo "  !! Run NOTHING between here and the flash. check.sh / test.sh rebuild build/agnos"
echo "     WITHOUT these flags and will silently replace the burn artifact."
echo ""

# --- Flash + watch instructions ---------------------------------------------
echo "=========================================="
echo "  IRON KERNEL READY — AGNOS $VER ($BUILD_TAG)"
echo "=========================================="
echo ""
# ⚠ WHICH FLASH COMMAND depends on whether the burn is driven by a RING-3 TOOL. `--update` is ESP-only
# (kernel + gnoboot); it never touches the agnos-fs partition where /bin/* lives. A burn whose oracle is
# `run /bin/<tool>` therefore needs `--update-all`, or the operator flashes a new kernel against a STALE
# tool — and a stale /bin/modeset simply falls through to its default arg and exits 96, which is
# indistinguishable from "no GPU". That is a wasted flash on a rig whose burns block the operator's work.
# ⚠ THE DEFAULT IS `--update-all`, DELIBERATELY, BECAUSE THE ERROR COSTS ARE ASYMMETRIC.
# `--update` is ESP-only (kernel + gnoboot) and never touches the agnos-fs where /bin/* lives. Most burns
# in this tree are now driven by a RING-3 TOOL (`run /bin/modeset ...`), and flashing `--update` for one of
# those ships a new kernel against a STALE tool — which fails SILENTLY: an old /bin/modeset just falls
# through to its default arg and exits 96, indistinguishable from "no GPU". That is a wasted flash on a rig
# whose burns block the operator's work.
# Flashing `--update-all` when `--update` would have done costs nothing but a few seconds of copying.
# A first cut of this gated on BUILD_TAG, which missed exactly the case that surfaced it: a BARE production
# kernel whose oracle is still `run /bin/modeset --dump`. The tag cannot tell you what drives the burn, so
# do not ask it — recommend the safe one and let the tracker say when ESP-only is enough.
if [ -x "$ROOT/build/rootfs/bin/modeset" ] || [ -d "$ROOT/build/rootfs/bin" ]; then
    echo "  Flash (from agnosticos):  sudo ./scripts/install-media.sh --update-all"
    echo "    (--update-all refreshes the ESP *and* the agnos-fs. Use it whenever the burn's oracle is"
    echo "     'run /bin/<tool>' — an ESP-only --update would pair a new kernel with a STALE tool, which"
    echo "     fails silently. For a kernel-only burn, --update is enough and leaves agnos-fs untouched.)"
    if [ ! -x "$ROOT/build/rootfs/bin/modeset" ]; then
        echo "  ⚠ /bin/modeset is NOT staged — if this burn uses it, run:  sh scripts/burn/stage-tools.sh --build"
    fi
else
    echo "  Flash (from agnosticos):  sudo ./scripts/install-media.sh --update"
    echo "    (--update is ESP-only — the agnos-fs partition survives, per"
    echo "     feedback_prefer_mount_modify_over_reflash; no staged tools present)"
fi
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
