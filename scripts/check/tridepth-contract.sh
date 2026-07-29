#!/bin/sh
# tridepth-contract — mechanical checks on kernel/shaders/tri_depth.s that NOTHING ELSE CAN MAKE.
#
# ⛔⛔ THIS GATE EXISTS BECAUSE ITS FIRST CHECK COST A HARDWARE RUN (2026-07-29). The dispatch
# primitive emits USER_DATA as: mask_mc lo/hi, dst_mc lo/hi, **mask_pitch, dst_pitch**, width, color
# — so the worker's `n_tri` argument lands in s4 and the framebuffer pitch in s5. The shader read
# them the other way round. It assembled cleanly, matched its committed blob byte-for-byte, and every
# host oracle stayed green, because none of them can see across the kernarg boundary: the host model
# has no kernargs and the assembler has no idea what the caller passes.
#
# ⚠ THE FAILURE LOOKED LIKE A PASS ON EVERY AXIS THE RUNG WAS DESIGNED AROUND. The triangle loop ran
# `pitch` (3328) times off the end of the prep array into zeroed arena, where `area == 0` makes all
# three edge tests `0 <= 0` — inside on every lane — so it painted a uniform frame. Result: all 1024
# lane witnesses correct, all 1024 pixels written, and **both submission orders BYTE-IDENTICAL** —
# the rung's own oracle, green. Only the comparison against the CPU reference caught it, and only
# because the arm reads the render target back. A wave-uniform misread of a kernarg is deterministic
# by construction, so no order/determinism test can ever see one.
#
# CHECK 1 — the kernarg contract, as the two instructions that consume it.
# CHECK 2 — no instruction between L_TRI: and the loop's backward branch names v0/v1/v2/v3/v4 as a
#   destination, except the two named v_cndmask. Those five are live across an UNBOUNDED loop, so a
#   scratch write to any of them is rung 13's v19 clobber on every iteration — a defect that wrote
#   ZERO, read like a dead shader, and was invisible to llvm-mc, to shader-blob.sh AND to the host
#   model. This is the only mechanical check in the tree that can catch it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/kernel/shaders/tri_depth.s"
[ -f "$SRC" ] || { echo "tridepth-contract: no such source: $SRC"; exit 2; }

rc=0

# ---- CHECK 1: the kernarg contract -----------------------------------------------------------
# The triangle count bounds the loop; the pitch scales the row. Both are asserted as the exact
# instruction that reads them, because a comment cannot be wrong in a way the hardware notices.
if grep -qE '^[[:space:]]*s_cmp_lt_u32[[:space:]]+s12,[[:space:]]*s4[[:space:]]*$' "$SRC"; then
    n=$(grep -cE '^[[:space:]]*s_cmp_lt_u32[[:space:]]+s12,[[:space:]]*s4[[:space:]]*$' "$SRC")
    if [ "$n" -eq 2 ]; then
        echo "tridepth-contract: PASS -- the triangle loop is bounded by s4 (n_tri), both sites"
    else
        echo "tridepth-contract: FAIL -- expected 2 loop bounds on s4, found $n"; rc=1
    fi
else
    echo "tridepth-contract: FAIL -- the triangle loop is NOT bounded by s4."
    echo "  gpu_blend_cov_run puts n_tri in s4 and the framebuffer pitch in s5. Bounding the loop"
    echo "  on s5 runs it 'pitch' times off the end of the prep array. This cost a burn."
    rc=1
fi

if grep -qE '^[[:space:]]*v_mul_lo_u32[[:space:]]+v18,[[:space:]]*v17,[[:space:]]*s5[[:space:]]*$' "$SRC"; then
    echo "tridepth-contract: PASS -- the colour row stride is s5 (dst_pitch)"
else
    echo "tridepth-contract: FAIL -- the colour row stride is not s5 (dst_pitch)."
    echo "  Using s4 makes the stride the TRIANGLE COUNT. This cost a burn."
    rc=1
fi

# ---- CHECK 2: nothing clobbers the loop-carried registers ------------------------------------
BODY="$(awk '/^L_TRI:/{f=1;next} f&&/s_cbranch_scc1[[:space:]]+L_TRI/{exit} f' "$SRC")"
[ -n "$BODY" ] || { echo "tridepth-contract: FAIL -- could not isolate the L_TRI body"; exit 1; }

# destinations only: the first operand of a v_* instruction. The two sanctioned writes are the
# v_cndmask pair that IS the update.
BAD="$(printf '%s\n' "$BODY" \
    | sed 's://.*::' \
    | grep -E '^[[:space:]]*v_[a-z0-9_]+[[:space:]]+v(0|1|2|3|4)[[:space:]]*,' \
    | grep -vE '^[[:space:]]*v_cndmask_b32[[:space:]]+v(3|4)[[:space:]]*,')"
if [ -n "$BAD" ]; then
    echo "tridepth-contract: FAIL -- the loop body writes a loop-carried register:"
    printf '%s\n' "$BAD" | sed 's/^/    /'
    echo "  v0..v4 are live across every iteration. A scratch write here is rung 13's v19 clobber:"
    echo "  it writes ZERO, reads like a dead shader, and no assembler or host model can see it."
    rc=1
else
    echo "tridepth-contract: PASS -- the loop body writes v3/v4 only via the two named v_cndmask"
fi

exit $rc
