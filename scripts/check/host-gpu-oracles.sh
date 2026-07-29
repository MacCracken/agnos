#!/bin/sh
# host-gpu-oracles — build and RUN the zero-burn host oracles that model GPU behaviour.
#
# ⛔ THE GAP THIS CLOSES: tests/gpu/*.cyr were run by hand and by nothing else. check-array-sizing.sh
# SCANS them, shader-blob.sh cites them, and no script has ever EXECUTED one. So an oracle could go
# red — or stop compiling — and the tree would stay green until somebody remembered to run it, which
# is the same class of defect as a gate wired with a bare `; rc=$?`: a check that exists on paper and
# cannot fail in practice.
#
# ⚠ SCOPE, STATED HONESTLY: this runs texlist, bigate, bimodel, texgate, rtaudit, depthgate, perspbits, perspdiv, perspgate,
# depthmodel and depthdiv. It
# does NOT run doomcol, doomwall, edgemodel or refraster — those are equally host-runnable and
# equally unwired, and adding them is a separate bite rather than something smuggled in beside a rung.
# ⚠ This line has gone stale twice as oracles were added; it is the drift the tree keeps finding in
# docs and scripts alike. If you add to the loop below, add here in the same edit.
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

rc=0
for t in texlist bigate bimodel texgate rtaudit depthgate depthmodel depthdiv perspbits perspdiv perspgate; do
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
