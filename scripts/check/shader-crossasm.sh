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
# ⛔⛔ VACUITY FLOOR ON THE PARTITION'S OWN ENUMERATION. The partition IS the gate now that UNBURNED is
# empty — and until 1.56.58 it was measured over an unfloored glob, so it had the exact shape it was
# written to prevent, one level up. `for f in "$SHADERS"/emit/*.emit.cyr` with `[ -f "$f" ] || continue`
# iterates ZERO times when the glob matches nothing: partition_fail stays 0, the empty UNBURNED loop
# below adds nothing, and the script prints "OK — every emit list is gated by shaderasm" having read no
# emit list at all. MEASURED (2026-09-02), on a copy of this script over a tree whose emit/ was empty:
# that exact OK line, exit 0 — byte-identical to the run over the real two-list tree.
# ⇒ The ways it goes empty are all edits somebody makes on purpose: emit/ renamed in a refactor, the
# `.emit.cyr` suffix changed, or this script moved a directory so ROOT loses a level.
# ⭐ WHY THE FLOOR IS 2 AND NOT 1: emit lists are never DELETED, they GRADUATE. A shader gets one when
# it is first encoded and KEEPS it after the burn, because shaderasm gates the committed hex AGAINST
# the emit list — burning makes the list load-bearing, not obsolete. That is precisely what blend_alpha
# did at 1.56.44 when it left UNBURNED. The population is monotonic: blend_rect + blend_alpha today,
# more later, fewer never. A count under 2 is this gate's enumeration breaking, not the tree changing.
# ⚠ Counted INSIDE the loop rather than by a second glob, so the floor measures the iterations that
# ACTUALLY RAN. A separate `ls "$SHADERS"/emit | wc -l` can report 2 while the loop above saw 0.
n_emit=0
for f in "$SHADERS"/emit/*.emit.cyr; do
    [ -f "$f" ] || continue
    n_emit=$((n_emit + 1))
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
if [ "$n_emit" -lt 2 ]; then
    echo "shader-crossasm: FAILED — enumerated $n_emit emit list(s); this gate is vacuous below 2."
    echo "  looked for: $SHADERS/emit/*.emit.cyr"
    echo "  The partition assertion is the ONLY thing this gate proves while UNBURNED is empty, and it"
    echo "  proves nothing over an empty glob. Emit lists graduate, they are never deleted, so finding"
    echo "  fewer than two means the enumeration broke (emit/ renamed, suffix changed, ROOT wrong) —"
    echo "  not that the tree is clean."
    exit 1
fi
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
# ⚠ AND SAY HOW MANY IT COUNTED, not just that it looked. Both greens below carried the same words
# whether the enumeration found two emit lists or none — a run that prints "1 emit list" is reporting
# that its own enumeration broke, and a run that prints nothing at all reports it too late.
if [ -z "$UNBURNED" ]; then
    echo "shader-crossasm: OK — $n_emit emit lists, none lacking iron-proven hex; each gated by shaderasm"
    exit 0
fi
echo "shader-crossasm: OK — $n_emit emit lists gated exactly once; every unburned shader encodes identically under two independent assemblers"
