#!/bin/sh
# host-gpu-oracles — build and RUN the zero-burn host oracles that model GPU behaviour.
#
# ⛔ THE GAP THIS CLOSES: tests/gpu/*.cyr were run by hand and by nothing else. check-array-sizing.sh
# SCANS them, shader-blob.sh cites them, and no script has ever EXECUTED one. So an oracle could go
# red — or stop compiling — and the tree would stay green until somebody remembered to run it, which
# is the same class of defect as a gate wired with a bare `; rc=$?`: a check that exists on paper and
# cannot fail in practice.
#
# ⚠ SCOPE, STATED HONESTLY: this runs texlist, bigate, bimodel, texgate, rtaudit, depthgate, perspbits, perspdiv, perspgate, perspmodel,
# depthmodel, depthdiv, moderaster and — added 1.56.44 — edgeasm, asmagree, shaderasm and shaderexec. It
# does NOT run doomcol, doomwall, edgemodel or refraster — those are equally host-runnable and
# equally unwired, and adding them is a separate bite rather than something smuggled in beside a rung.
# ⚠ This line has gone stale twice as oracles were added; it is the drift the tree keeps finding in
# docs and scripts alike. If you add to the loop below, add here in the same edit.
#
# ⭐⭐ edgeasm + asmagree ADDED 1.56.44, AND THEY ARE THE HEADER'S OWN WARNING COME TRUE, TWICE OVER.
# These two files ARE agnos's sovereign-encoder evidence — cited by name at `shader-blob.sh:13` and
# `burn-prep.sh:377` as the proof that the tree can reproduce iron-proven shader bytes without llvm.
# Both included `../../mabda/src/gfx9_encode.cyr`, which from tests/gpu/ is `<agnos>/mabda` — absent.
# ⛔ So neither had EVER COMPILED, let alone run, on any machine, since the day it was written. The
# header above says an unrun oracle is "a check that exists on paper and cannot fail in practice";
# these were a rung further gone — not merely unrun but unbuildable, while two other scripts cited
# their results. Path fixed to `../../../mabda`, both now build under agnos's tree and exit 95, and
# `mabda-resolve.sh` runs first so a missing sibling reports as TOOLING and not as a red oracle.
#
# ⛔⛔ AND HERE IS *WHY NOBODY NOTICED*, WHICH IS THE PART WORTH KEEPING. `tests/gpu/build/edgeasm` is
# a COMMITTED BINARY (51 of them are tracked under tests/gpu/build/). Running it exits 95 and prints
# "B4 PASS -- the tool reproduces a shipped iron-proven shader byte-for-byte". It is 108,784 bytes;
# a build from the fixed source is 116,976. So the artifact in the tree PASSED while the source it
# claims to represent DID NOT COMPILE — anyone who checked the oracle by running it got a green light
# from a binary predating the breakage. A committed build artifact is not evidence about the source
# beside it; it is evidence about whatever source existed when someone last ran a compiler. ⚠ THIS
# LOOP REBUILDS BEFORE IT RUNS, which is the property that makes it a gate rather than a re-run of a
# fossil — do not "optimise" it into reusing an existing build/<t>.
# ⭐⭐ shaderexec ADDED 1.56.44 AND IT IS THE ONLY ONE HERE THAT EXECUTES ANYTHING. Every other gate in
# this tree — shaderasm, shader-crossasm, shader-derive, edgeasm — is about ENCODING: whether some
# stream of dwords equals another stream of dwords. None of them computes a pixel. For `blend_alpha`
# that meant 14 dwords changed and the number constrained SEMANTICALLY was ZERO.
# ⛔ The demonstration: deleting blend_alpha's whole 4-dword prologue and re-running the ARITHMETIC
# model at alpha=255 scores 0 mismatches over all 16,777,216 cases, because at alpha=255 the correct
# answer IS blend_rect's — "equals blend_rect" is satisfied by "the feature is absent". shaderexec
# refuses that shader at byte +112 on an uninitialised v13, because it actually runs the bytes.
# ⭐ Its calibration is the tree's first with independent provenance on BOTH sides: blend_rect's
# iron-burned hex, interpreted, against `blend_ref_px` — pure integer arithmetic written for the
# kernel's own self-test. Neither is derived from the other, so an interpreter bug fails there first.
# ⚠ Its corpus is STRIDED (39 values/axis, stride 8 + boundaries = 59,319 cases/gate, 0.4 s). The
# exhaustive 256^3 run was done once on 2026-08-13 — 0 mismatches on all three gates, 119 s — and is
# not what ships, because 119 s against this runner's 3 s makes a gate people skip. Set SX_STRIDE to 1
# to reproduce it. The count is printed at run time rather than implied.
#
# ⚠ Their pass is the first empirical answer to the mabda/agnos pin question: mabda pins cyrius
# 6.5.3, agnos's manifests pin 6.4.78, and `gfx9_encode.cyr` compiles inside agnos's test tree
# regardless. That was previously argued from the source's simplicity; it is now built.
#
# ⭐ depthgate ADDED AT RUNG 17. It proves the rung's OWN iron oracle before the shader exists:
# two interpenetrating triangles in both submission orders must be byte-identical. ⚠ It also proves
# the corpus is FAIR to that oracle — no z-ties (a tie is decided by submission order on ANY correct
# implementation, hardware included, so a tie in the corpus would fail a CORRECT shader), both
# triangles visible, and the image non-empty (two empty images are byte-identical). Its D2 mutation
# makes every overlap a tie and MUST go order-dependent, or D1 is measuring nothing.
#
# ⭐⭐ THREE MORE FRAMES ADDED 2026-07-29, BECAUSE THE SHIPPED CORPUS WAS A MEASURED NULL SET FOR THE
# TWO PROPERTIES THE RUNG IS ABOUT. On it, a divide one ULP short moves ZERO of 1024 pixels, and
# `dc_ties == 0` *is* order-invariance — so "walks the triangle list in submission order", the entire
# claim of tile serialisation, was tested by nothing at all. A shader walking the list backwards
# passed every gate in this tree.
#   • PRECISION (D0d) — z span 2, where a one-ULP error flips 42 px. ⚠ Sensitivity is NOT monotone in
#     the span: at span 1 EVERY shared pixel ties and the frame is blind again for the opposite
#     reason, so D0d re-measures both endpoints (span 1 and span 800 each flip 0) and asserts the
#     chosen span beats them. "Tighter is finer" lands on the second null set.
#   • QUAD (D5) — two triangles sharing a diagonal, 23 exact ties, the two orders differ in all 23,
#     and the FIRST-submitted must win every one. The only witness of submission order in the tree.
#     ⚠ Numbered D5, not the plan's "D3": D3 is already the determinism control.
#   • OFF-ORIGIN (D6, and depthmodel A7c/A8) — x=4000 AND z scaled 10x, which puts |KC| at 3.33e9,
#     past a signed 32-bit field, so the mod-2^32 residue the record stores is finally load-bearing.
#     ⚠ The plan's x=700 at the shipped z range gives |KC| = 5.8e7 — 26 bits, inside an i32, a frame
#     that names the residue and never exercises it. A8 asserts the overflow so it cannot regress.
# depthmodel also gained A5/A6 (lane fidelity and the derived-w2 identity) at the same time; its
# `zn`, `KX/KY/KC` and `area` were accumulated in unmasked i64 while the file claimed 32-bit lanes.
#
# ⭐⭐ AND THE TWO EXTERNAL GATES (D10/D11), ADDED 2026-07-29, WHICH ARE THE ONLY ONES HERE THAT DO
# NOT REST ON A SHARED PREMISE. Everything else in depthgate/depthmodel is an agreement between two
# artifacts written the same week from the same derivation — which is exactly the configuration that
# let rung 15 ship a half-texel offset with bicore, bimodel, texcore AND the shader all agreeing.
#   • D10 — a constant-z silhouette must match `tri_prep`, the rung-9/11 reference for the
#     INDEPENDENTLY BURNED `tri_rgba` / op 0x0A path. It keeps vertices in PIXELS and samples at
#     16.16 `(px<<16)+32768`; depthcore DOUBLES vertices and samples at `2*px+1`. Same geometric
#     point, two number systems that do not transform into each other by a shared constant.
#   • D11 — each triangle's depth plane fitted in 3-SPACE from its vertices by one cross product,
#     touching no edge function, no barycentric weight and no hoist. (a) the fit and the barycentric
#     interpolation are the same rational at every covered pixel, cross-multiplied exactly;
#     (b) every dual-covered pixel is on the correct side of the analytically derived
#     interpenetration line.
# ⛔ All three passed on their FIRST run, so all three are falsified in-file. M-D10 is the one that
# matters: moving the 2D path's sample from the pixel centre to its corner — a half-pixel error, the
# rung-15 class exactly — moves 92 px. A gate that has never failed is a claim, not a check.
#
# ⭐ texgate ADDED AT RUNG 15 because it stopped being only rung 13's gate. It now carries the four
# checks that decide whether a bilinear iron burn is interpretable: **gate 7** (the reciprocal
# reproduces an exact divide across the WHOLE 16.16 word — the 8 fraction bits ONLY bilinear reads,
# which rungs 13/14's 17/17 record never looked at), **gate 8** (that gate is connected: the
# correction step moves 3151 quotients), and **gates 9/10** (texcore's four-tap addressing vs
# bicore's, plus corner-exactness and a proof it actually filters).
#
# ⭐ bigate + bimodel ADDED AT RUNG 15 (1.56.29), AND THE REASON IS THE SAME ONE IN THE HEADER ABOVE.
# They were written this cut, run by hand, and cited in the blob's comments as the proof that the
# bilinear filter is exact — while NOTHING executed them. An oracle a shader's comments lean on, that
# no script runs, is a citation rather than a gate. bimodel in particular carries five mutations that
# must keep firing; if it silently stopped compiling, the tree would stay green and rung 15's whole
# attribution claim ("green model + red iron ⇒ blame the EMISSION") would be resting on a file nobody
# had run since the day it was written.
#
# What PASSES: exit 95 from each. texlist returns 86 if any grid case is inexact OR if fewer than all
# of its mutations go red; bigate returns 90 if any of its 7 exactness properties break; bimodel
# returns 90 if the 32-bit-lane model diverges from the reference OR if a mutation fails to go red.
# Every one of the three therefore covers both its model and its own falsification.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GPU="$ROOT/tests/gpu"

command -v cyrius >/dev/null 2>&1 || { echo "host-gpu-oracles: cyrius not on PATH"; exit 2; }

# ⚠ tests/gpu includes from the parent tree (lib/io.cyr, tricore.cyr), which the wrapper refuses by
# default. Without this the build fails and the gate would report a TOOLING failure as an oracle
# failure — two very different things to be told at 2am.
CYRIUS_ALLOW_PARENT_INCLUDES=1
export CYRIUS_ALLOW_PARENT_INCLUDES

mkdir -p "$GPU/build"

# edgeasm and asmagree include mabda's encoder from the sibling checkout. Resolve it BEFORE the loop
# so an absent sibling is reported as a tooling failure with a clone attempt, rather than surfacing
# as "edgeasm.cyr does not BUILD" — the two-very-different-things-at-2am distinction the parent-
# includes note above already draws.
sh "$ROOT/scripts/check/mabda-resolve.sh" || exit 2

# shaderasm's EXPECTED side is generated from kernel/core/gpu.cyr, never committed and never typed.
# Regenerating here — rather than trusting a file on disk — is what makes the oracle compare against
# the hex that is in the tree RIGHT NOW. A stale gen/ would compare a new emit list against last
# week's shader and pass, which is the committed-binary failure in a different costume.
sh "$ROOT/scripts/check/shader-tables.sh" >/dev/null || {
    echo "host-gpu-oracles: FAIL -- shader-tables.sh could not extract the expected dwords"
    sh "$ROOT/scripts/check/shader-tables.sh" >/dev/null
    exit 1
}
# Register declarations, likewise extracted rather than typed. ⚠ A TYPED budget is a second copy of
# the .s file and it drifts: edgeasm asserted edge_setup against 56 VGPRs while the shader declared
# 32, for the whole life of the file, because both sides of that comparison were written by hand.
sh "$ROOT/scripts/check/shader-decls.sh" >/dev/null 2>&1 || {
    echo "host-gpu-oracles: FAIL -- shader-decls.sh could not extract the register declarations"
    sh "$ROOT/scripts/check/shader-decls.sh" >/dev/null
    exit 1
}

rc=0
# ⭐ moderaster ADDED AT 1.56.33 BITE 4, and it is the only oracle here with NO shared premise to
# design around: it INCLUDES `kernel/core/mode_raster.cyr` rather than mirroring it, so there is one
# implementation; its input is the published CVT-RB 2560x1440 timing; and its expected output is the
# register set archaemenid's firmware left in the pipe, captured read-only on 2026-07-30. VESA on one
# side, this board's GOP on the other, our arithmetic in the middle having authored neither.
# ⚠ Its M1 mutation FAILED on its first run and the BUILDER was right — `blank_end = h_total -
# h_front - h_active` cancels the front porch exactly, so h_front reaches H_TOTAL and never H_BLANK.
# Both directions are now pinned (M1/M1c assert the cancellation, M1b asserts the register still
# moves), because a change folding h_front into the blank formula would otherwise be invisible.
for t in texlist bigate bimodel texgate rtaudit depthgate depthmodel depthdiv perspbits perspdiv perspgate perspmodel moderaster edgeasm asmagree shaderasm shaderexec; do
    out="$(cd "$GPU" && cyrius build "$t.cyr" "build/$t" 2>&1)" || {
        echo "host-gpu-oracles: FAIL -- $t.cyr does not BUILD"
        echo "$out" | tail -20
        exit 1
    }
    "$GPU/build/$t" > "/tmp/host-gpu-$t.log" 2>&1
    got=$?
    if [ "$got" -ne 95 ]; then
        echo "host-gpu-oracles: FAIL -- $t exited $got, want 95"
        tail -30 "/tmp/host-gpu-$t.log"
        rc=1
    else
        echo "host-gpu-oracles: PASS -- $t exit 95"
    fi
done
exit $rc
