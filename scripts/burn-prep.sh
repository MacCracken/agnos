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
# --- 1.56.x SHADER arc arms ---------------------------------------------------
# ⚠ These were MISSING until 1.56.4. Every 1.56.x shader burn (S1/D0, S2, grid, guard, coverage, glyph,
# gradient) was reproduced by hand-exporting a define straight to build.sh, which bypasses this script's
# banner + BUILD_TAG stamp — so the burn artifact carried no record of which arm produced it. That is
# exactly the failure the standing rule ("every #ifdef bite names its BURN_* flag in burn-prep.sh, and you
# verify by `cmp`-ing the two binaries, not by the burn tag") exists to prevent. Arms added retroactively.
if [ -n "${BURN_SHADER_OPS:-}" ]; then
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
    # ⚠ NEEDS the gpu-test binaries on the agnos-fs: scripts/stage-tools.sh --build (wired 1.56.4).
    # Oracle: `run /bin/gpublend` and `run /bin/gpucov` -> `run: exit 95`. A #92 failure decodes as
    # 110 + reason (111 no-GPU · 113 bad-slot · 115 off-screen · 117 not-resident · 118 dispatch-timeout ·
    # 121 bad-descriptor · 122 reserved-field · 123 envelope-unproven). CAPTURE: klug > shader_ops.txt.
    echo "[2/2] Building the 1.56.4 SHADER-OPS kernel (#92 descriptor seam + cov re-proof + glyph/grad first iron; run /bin/gpublend + /bin/gpucov; capture klug > shader_ops.txt)."
    BUILD_ENV="SHADER_COV=1 SHADER_GLYPH=1 SHADER_GRAD=1"
    BUILD_TAG="SHADER_OPS"
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
    echo "[2/2] Building the ACR-CTS kernel (HDA_HDMI + HDA_TONE + HDMI_ACR_CTS + HDMI_AUDIO_DUMP: program the ACR CTS registers to amdgpu's 241500; LISTEN for the tone)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ACR_CTS=1 HDMI_AUDIO_DUMP=1"
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
    echo "[2/2] Building the SYMCLK A/B kernel (HDA_HDMI + HDA_TONE + HDMI_SYMCLK_AB + HDMI_AUDIO_DUMP: two labelled listening windows in ONE boot, symclk OFF then ON; LISTEN for a difference)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_SYMCLK_AB=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_SYMCLK_AB+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_DCCG:-}" ]; then
    # THE DCCG SYMCLK BURN — the de-risked candidate. The amdgpu modeset capture proved agnos omits the DCCG
    # symbol-clock writes amdgpu makes for HDMI (abs 0x159 SYMCLKA-on for DIG1/UNIPHYA, confirmed by DIG1's AVI
    # landing at 0x564d + phyid=0). This applies exactly those writes in gpu_hdmi_audio_enable. NO ATOM
    # interpreter, NO transmitter, NO PHY power-cycle — host-visible DCCG only, so display-safe (worst case a
    # clock glitch, recoverable; not the transmitter's non-recoverable blank). If audio plays, the missing
    # symbol clock was the whole thing and we never touch the transmitter. PASS IS THE OPERATOR'S EARS.
    echo "[2/2] Building the DCCG-symclk kernel (HDA_HDMI + HDA_TONE + HDMI_DCCG + HDMI_AUDIO_DUMP: apply the DCCG symbol-clock re-prime amdgpu does for HDMI; host-visible, display-safe; LISTEN for the tone)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_DCCG=1 HDMI_AUDIO_DUMP=1"
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
    echo "[2/2] Building the A4 ISOLATION kernel (HDA_HDMI + HDMI_ATOM + ATOM_DRY + ATOM_HALT: run the ATOM path with zero PHY writes, then FREEZE the framebuffer before the DIG flip; photograph the FB to isolate ATOM-path vs DIG-flip)."
    BUILD_ENV="HDA_HDMI=1 HDMI_ATOM=1 ATOM_DRY=1 ATOM_HALT=1"
    BUILD_TAG="HDA_HDMI+HDMI_ATOM+ATOM_DRY+ATOM_HALT"
elif [ -n "${BURN_HDMI_ATOM_DRY:-}" ]; then
    # THE A4 DRY-VALIDATION BURN (safe fallback). Same as BURN_HDMI_ATOM but ATOM_DRY suppresses every MMIO
    # write and forces reads to 0 — the interpreter runs its full control flow WITHOUT touching the PHY, so
    # the console is guaranteed to survive and `run /bin/klug > /f/dump.txt` always works. The ATOM_TRACE
    # output is the deliverable: the exact write sequence agnos's interpreter produces, to diff against the
    # atom-interp.py oracle (transmitter: 21 reads / 17 writes / 5 delays, writes to UNIPHYA 0x55xx + RDPCS
    # 0x5Dxx-0x5Exx). Use this if a live BURN_HDMI_ATOM blacks/hangs the console before the shell.
    echo "[2/2] Building the A4 DRY-VALIDATION kernel (HDA_HDMI + HDMI_ATOM + ATOM_DRY + ATOM_TRACE: run the ATOM interpreter with writes SUPPRESSED; capture the trace and diff vs the oracle. No PHY drive, console safe, no audio)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_DRY=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_DRY+ATOM_TRACE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_ATOM_FULL:-}" ]; then
    # THE ENCODER+TRANSMITTER burn (ATOM_RUN_TRANSMITTER=1). ⚠ The transmitter ENABLE power-cycles the PHY and
    # BLANKS THE LIVE CONSOLE PIPE NON-RECOVERABLY on iron (proven 1.55.23) unless a full modeset (SetPixelClock
    # + OTG recommit) is also in place. DO NOT flash this until that modeset exists. Kept for that future work.
    echo "[2/2] Building the A4 FULL kernel (HDA_HDMI + HDA_TONE + HDMI_ATOM + ATOM_RUN_TRANSMITTER + ATOM_TRACE + HDMI_AUDIO_DUMP: encoder + transmitter. ⚠ BLANKS THE CONSOLE without a full modeset — do not flash yet)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_RUN_TRANSMITTER=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_RUN_TRANSMITTER+ATOM_TRACE+HDMI_AUDIO_DUMP"
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
    echo "[2/2] Building the A4 ENCODER-ONLY kernel (HDA_HDMI + HDA_TONE + HDMI_ATOM + ATOM_TRACE + HDMI_AUDIO_DUMP: run DIGxEncoderControl(HDMI) LIVE — PHY-safe front-end setup, transmitter SKIPPED — then the audio path. Recoverable flicker at worst; LISTEN for the tone)."
    BUILD_ENV="HDA_HDMI=1 HDA_TONE=1 HDMI_ATOM=1 ATOM_TRACE=1 HDMI_AUDIO_DUMP=1"
    BUILD_TAG="HDA_HDMI+HDA_TONE+HDMI_ATOM+ATOM_TRACE+HDMI_AUDIO_DUMP"
elif [ -n "${BURN_HDMI_SWEEP:-}" ]; then
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
# AMBIENT-ENV LEAK, closed 2026-07-19. `env $BUILD_ENV` ADDS to the inherited environment — it does not
# replace it. So an exported HDMI_ATOM=1 (or any other flag) lingering in the operator's shell from an earlier
# experiment reaches build.sh and gets #define'd REGARDLESS of the profile selected above, silently producing
# an artifact that is not the one the burn tag names. Same family as the ATOM_DRY no-op: the tag stops
# describing the binary. Clear every known build flag first, then apply only the profile's own.
if ! env -u HDA_HDMI -u HDA_TONE -u HDMI_DCCG -u HDMI_ATOM -u HDMI_AUDIO_DUMP -u HDMI_AUDIO_SWEEP \
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
case "$BUILD_TAG" in *HDA_HDMI*)         verify_marker "ctl1 probing 2nd controller" ;; esac
case "$BUILD_TAG" in *HDA_TONE*)         verify_marker "sweep streaming" ;; esac
case "$BUILD_TAG" in *HDMI_AUDIO_DUMP*)  verify_marker "== agnos display-audio dump ==" ;; esac
case "$BUILD_TAG" in *HDMI_AUDIO_SWEEP*) verify_marker "hdmi-sweep: cycling" ;; esac
# MARKER-COVERAGE GAP, closed 2026-07-19. The four arms above covered only the HDA_* / HDMI_AUDIO_* flags,
# yet the "markers verified" line below claims the WHOLE $BUILD_TAG is compiled AND reached. So every
# HDMI_DCCG and ATOM_* burn shipped unverified for the very flag under test — the 1.55.24 DCCG burn included
# (it happened to carry its kprintln, but that was luck, not process). This is the ATOM_DRY defect's family:
# a flag whose presence in the tag was never proven in the artifact. Each marker below is a kprintln inside
# the flag's own #ifdef, in a function called unconditionally, so it satisfies verify_marker's own rule.
case "$BUILD_TAG" in *HDMI_DCCG*)        verify_marker "hdmi DCCG symclk re-prime" ;; esac
case "$BUILD_TAG" in *HDMI_SYMCLK_AB*)   verify_marker "symclk-ab: in-boot A/B" ;; esac
case "$BUILD_TAG" in *HDMI_ACR_CTS*)     verify_marker "hdmi acr cts programmed" ;; esac
case "$BUILD_TAG" in *SCANOUT_PATTERN*)  verify_marker "scanout pattern probe armed" ;; esac
case "$BUILD_TAG" in *SCANOUT_REDIRECT*) verify_marker "console redirected to agnos scanout buffer" ;; esac
case "$BUILD_TAG" in *SCANOUT_REGDUMP*)  verify_marker "HUBP regdump begin" ;; esac
case "$BUILD_TAG" in *SCANOUT_MATCHGEOM*) verify_marker "scanout matchgeom armed" ;; esac
case "$BUILD_TAG" in *SDMA_PROBE*)       verify_marker "sdma probe armed" ;; esac
case "$BUILD_TAG" in *SDMA_RING*)        verify_marker "sdma ring bringup armed" ;; esac
case "$BUILD_TAG" in *SDMA_COPY*)        verify_marker "sdma ring bringup armed" ;; esac
case "$BUILD_TAG" in *ATOM_DRY*)         verify_marker "atom: DRY build (no MMIO)" ;; esac
case "$BUILD_TAG" in *HDMI_ATOM*)        verify_marker "atom: running DIGxEncoderControl" ;; esac

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
