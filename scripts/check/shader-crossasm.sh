#!/bin/sh
# shader-crossasm.sh — for a shader with NO committed hex, assemble it TWICE through two independent
# assemblers and require the dword streams to be identical.
#
# ⛔⛔ WHY THIS EXISTS, AND WHY IT IS DIFFERENT FROM `shaderasm`.
# `tests/gpu/shaderasm.cyr` checks an emit list against the COMMITTED hex in `kernel/core/gpu.cyr`.
# That is powerful for `blend_rect` because those bytes were burned on archaemenid and produced correct
# pixels — the expectation is evidence about reality.
# ⚠ For a shader that has NOT been burned there is no such expectation, and reaching for shaderasm
# anyway would compare two host artifacts written the same week from the same story. `shader-blob.sh`
# already records the standard: an assembled-but-unrun blob "has not met the bar for a hardware run".
#
# ⭐ WHAT *IS* INDEPENDENT: the emit list is packed by **mabda's Cyrius gfx9 encoder**; the `.s` is
# assembled by **llvm-mc**. Two implementations, written by different people for different projects,
# neither derived from the other. If they agree on every dword, the encoding is very unlikely to be
# wrong in the same way twice — and if they disagree, exactly one of them is, which is a far better
# position than a single unchecked artifact.
#
# ⚠ WHAT THIS DOES NOT PROVE, STATED PLAINLY:
#   · NOT that the shader computes the right thing. Both sides encode the SAME instruction sequence;
#     if that sequence is semantically wrong, both agree and both are wrong. This gate is about
#     ENCODING, never about semantics.
#   · NOT that the register declaration is right — see the tracker's `ea_sgpr_exact`.
#   · NOT anything a burn would tell you. It reduces the burn's search space; it does not replace it.
#
# ⚠ REQUIRES llvm-mc, so it hangs off `check.sh` and NOT off `host-gpu-oracles.sh` — `ci.yml` runs the
# oracle runner and deliberately not check.sh, because check.sh hard-requires LLVM. A gate placed in
# the wrong runner is a gate that does not run in CI.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GPU="$ROOT/tests/gpu"
SHADERS="$ROOT/kernel/shaders"
WORK="${TMPDIR:-/tmp}/agnos-crossasm.$$"

command -v llvm-mc      >/dev/null 2>&1 || { echo "shader-crossasm: llvm-mc not found"; exit 2; }
command -v llvm-objcopy >/dev/null 2>&1 || { echo "shader-crossasm: llvm-objcopy not found"; exit 2; }
command -v cyrius       >/dev/null 2>&1 || { echo "shader-crossasm: cyrius not on PATH"; exit 2; }

mkdir -p "$WORK" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

# Shaders with an emit list but NO committed hex. ⚠ A shader gains committed hex only after a burn;
# when that happens MOVE it out of this list and into shaderasm, which is the stronger gate.
#
# ⭐⭐ EMPTY AS OF THE 1.56.44 BURN — `blend_alpha` graduated. Its 69 dwords dispatched on archaemenid
# and produced a translucent window, so `gpu.cyr`'s `blend_alpha_write` is now iron-proven hex and
# `shaderasm.cyr` gates it against the emit list, which is the stronger comparison.
UNBURNED=""

# ⛔⛔ AN EMPTY LIST WOULD OTHERWISE MAKE THIS GATE VACUOUS, and this tree has already shipped four of
# those. A `for` over nothing leaves `fail=0` and prints OK — indistinguishable from coverage, and
# exactly how a THIRD emit list added tomorrow and wired into neither gate would pass silently.
# ⇒ Assert the PARTITION instead: every `kernel/shaders/emit/*.emit.cyr` must be named either in
# `UNBURNED` above or in a `check_shader(..., "<name>")` call in `tests/gpu/shaderasm.cyr`. That is a
# claim with content whether or not this list has anything in it, and it is what makes "nothing to
# cross-assemble" mean *covered* rather than *forgotten*.
partition_fail=0
covered=$(grep -oE 'check_shader\([^)]*"[a-z0-9_]+"\)' "$GPU/shaderasm.cyr" 2>/dev/null \
          | sed -E 's/.*"([a-z0-9_]+)".*/\1/')
for f in "$SHADERS"/emit/*.emit.cyr; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .emit.cyr)
    in_unburned=0; in_shaderasm=0
    for u in $UNBURNED;  do [ "$u" = "$base" ] && in_unburned=1; done
    for c in $covered;   do [ "$c" = "$base" ] && in_shaderasm=1; done
    if [ "$in_unburned" = "1" ] && [ "$in_shaderasm" = "1" ]; then
        echo "  FAIL: $base is in BOTH lists — a burned shader must leave UNBURNED when it enters shaderasm"
        partition_fail=1
    fi
    if [ "$in_unburned" = "0" ] && [ "$in_shaderasm" = "0" ]; then
        echo "  FAIL: $base has an emit list and NO gate — add it to UNBURNED here, or to shaderasm.cyr"
        partition_fail=1
    fi
done
if [ "$partition_fail" != "0" ]; then
    echo "shader-crossasm: FAILED — every emit list must be gated exactly once"
    exit 1
fi

fail=0
for name in $UNBURNED; do
    s="$SHADERS/$name.s"
    emit="$SHADERS/emit/$name.emit.cyr"
    [ -f "$s" ]    || { echo "  FAIL: $name.s not found";          fail=1; continue; }
    [ -f "$emit" ] || { echo "  FAIL: $name.emit.cyr not found";   fail=1; continue; }

    # --- side A: llvm-mc from the .s ---
    if ! llvm-mc -triple=amdgcn-amd-amdhsa -mcpu=gfx90c -filetype=obj "$s" -o "$WORK/a.o" 2>"$WORK/a.err"; then
        echo "  FAIL: $name.s does not assemble under llvm-mc"; sed 's/^/        /' "$WORK/a.err" | head -5; fail=1; continue
    fi
    llvm-objcopy -O binary --only-section=.text "$WORK/a.o" "$WORK/a.bin" 2>/dev/null
    od -An -tx4 -v "$WORK/a.bin" | tr -s ' ' '\n' | grep -E '^[0-9a-f]{8}$' > "$WORK/a.hex"

    # --- side B: the emit list through mabda's encoder ---
    # ⚠ Built inside tests/gpu so the relative includes resolve exactly as the oracles' do.
    cat > "$GPU/_crossasm_probe.cyr" <<PROBE
include "lib/io.cyr"
include "../../../mabda/src/gfx9_encode.cyr"
include "asmlib.cyr"
include "../../kernel/shaders/emit/$name.emit.cyr"
fn main(): i64 {
    ea_labels_reset(); ea_vgpr_reset(); ea_sgpr_reset();
    var bytes = ${name}_emit();
    var n = bytes / 4;
    var i = 0;
    while (i < n) { phex(load32(&isa + i * 4) & 0xFFFFFFFF); nl(); i = i + 1; }
    if (ea_fault != 0) { ps("FAULT"); nl(); }
    return 0;
}
fn _entry(): i64 { var r = main(); syscall(SYS_EXIT, r); return 0; }
_entry();
PROBE
    ( cd "$GPU" && CYRIUS_ALLOW_PARENT_INCLUDES=1 cyrius build _crossasm_probe.cyr "$WORK/probe" ) >"$WORK/b.err" 2>&1
    if [ ! -x "$WORK/probe" ]; then
        echo "  FAIL: $name.emit.cyr does not build"; grep -E '^error' "$WORK/b.err" | head -5 | sed 's/^/        /'
        rm -f "$GPU/_crossasm_probe.cyr"; fail=1; continue
    fi
    rm -f "$GPU/_crossasm_probe.cyr"
    "$WORK/probe" > "$WORK/b.out" 2>&1
    if grep -q '^FAULT' "$WORK/b.out"; then
        echo "  FAIL: $name — an asmlib wrapper REFUSED an encoding while emitting"; fail=1; continue
    fi
    sed -n 's/^0x\([0-9a-f]\{8\}\)$/\1/p' "$WORK/b.out" > "$WORK/b.hex"

    na=$(grep -c . "$WORK/a.hex"); nb=$(grep -c . "$WORK/b.hex")
    # ⛔ Refuse an empty side. Two empty files diff clean, and that is the shape of a gate that passes
    # because nothing ran — the exact failure this tree keeps finding.
    if [ "$na" = "0" ] || [ "$nb" = "0" ]; then
        echo "  FAIL: $name — an assembler produced NOTHING (llvm-mc $na, mabda $nb)"; fail=1; continue
    fi
    if [ "$na" != "$nb" ]; then
        echo "  FAIL: $name — llvm-mc emitted $na dwords, mabda emitted $nb"; fail=1; continue
    fi
    if ! diff -q "$WORK/a.hex" "$WORK/b.hex" >/dev/null; then
        echo "  FAIL: $name — the two assemblers DISAGREE:"
        diff "$WORK/a.hex" "$WORK/b.hex" | head -8 | sed 's/^/        /'
        fail=1; continue
    fi
    echo "  $name: $na dwords identical across llvm-mc and mabda"
done

if [ "$fail" != "0" ]; then
    echo "shader-crossasm: FAILED"
    exit 1
fi
# ⚠ SAY WHICH OF THE TWO GREENS THIS IS. "OK — every unburned shader encodes identically" over an
# empty list is a true sentence that reads as coverage; the partition assertion above is what was
# actually proven, and the message has to name it.
if [ -z "$UNBURNED" ]; then
    echo "shader-crossasm: OK — no shader currently lacks iron-proven hex; every emit list is gated by shaderasm"
    exit 0
fi
echo "shader-crossasm: OK — every unburned shader encodes identically under two independent assemblers"
