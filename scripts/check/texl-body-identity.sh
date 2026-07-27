#!/bin/sh
# texl-body-identity — prove kernel/shaders/tex_list.s carries rung 13's texturing body VERBATIM.
#
# ⛔ THE RISK THIS CLOSES IS DRIFT BETWEEN TWO COPIES OF PROVEN CODE. tex_list.s (rung 14, op 0x0C)
# is a 16-instruction prologue bolted onto tex_rgba.s's body (rung 13, op 0x0B). That body is the
# expensive artifact: signed 64-bit edge multiplies, the min-bias, both texture formats, WRAP, the
# exact /255 — iron-proven at 17/17 across nine burns, and byte-diffed against texcore.cyr by
# texmodel/texgate on the host.
#
# A copy is only as good as the guarantee that it IS a copy. Without this gate, a fix applied to one
# file and not the other produces two shaders that agree on every test anyone bothers to run and
# disagree on the one nobody does. That is the ATOM_DRY defect class the tree already names: two
# artifacts differing in name but not in intent, where the only real defence is that there is
# exactly one implementation — or, failing that, a mechanical proof that the second is identical.
#
# WHAT IS COMPARED: everything from the format-branch comment through `s_endpgm`, character for
# character, including comments. Comments are IN SCOPE on purpose — a comment that drifts is a lie
# told to the next reader about code they are about to trust, and this body's comments carry the
# reasoning that cost rung 11 four burns to learn.
#
# WHAT IS NOT COMPARED: the header, the prologue, and the .amdhsa block. Those are exactly what
# rung 14 is allowed to differ in.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/kernel/shaders/tex_rgba.s"
B="$ROOT/kernel/shaders/tex_list.s"
for f in "$A" "$B"; do
    [ -f "$f" ] || { echo "texl-body-identity: missing $f"; exit 2; }
done

MARK='WAVE-UNIFORM BRANCH ON THE FORMAT WORD'

extract() {
    # from the marker line to the FIRST s_endpgm, inclusive
    awk -v mark="$MARK" '
        index($0, mark) { on = 1 }
        on { print }
        on && $1 == "s_endpgm" { exit }
    ' "$1"
}

TA="$(mktemp)"; TB="$(mktemp)"
trap 'rm -f "$TA" "$TB"' EXIT
extract "$A" > "$TA"
extract "$B" > "$TB"

LA=$(wc -l < "$TA"); LB=$(wc -l < "$TB")
# ⚠ A zero-length extraction would make `diff` succeed and this gate report PASS while proving
# nothing — the same vacuous-pass class that let a 4-arg call with 3 args ride for four burns.
if [ "$LA" -lt 300 ]; then
    echo "texl-body-identity: FAIL -- extracted only $LA lines from tex_rgba.s; the marker moved"
    echo "  marker: $MARK"
    exit 1
fi

if diff -u "$TA" "$TB" > /dev/null 2>&1; then
    echo "texl-body-identity: PASS -- $LA lines of rung 13's body are character-identical in both shaders"

    # ⭐⭐ STAGE 2: THE SHIPPED DWORDS, not just the source text. Identical source assembled by the
    # same tool SHOULD produce identical code — but "should" is what the blob-drift gate exists
    # because of. This compares the two .text sections tail-aligned and proves the differing dwords
    # are confined to the prologue, which means rung 14 ships rung 13's iron-proven MACHINE CODE
    # byte for byte, branch offsets included.
    #
    # ⚠ Tail-aligned on purpose: both bodies are a contiguous SUFFIX ending at s_endpgm, so aligning
    # on the end makes the body indices line up regardless of how long each prologue is.
    if command -v llvm-mc >/dev/null 2>&1 && command -v llvm-objcopy >/dev/null 2>&1; then
        WD="$(mktemp -d)"
        ok=1
        for n in tex_rgba tex_list; do
            llvm-mc -triple=amdgcn-amd-amdhsa -mcpu=gfx90c -filetype=obj \
                "$ROOT/kernel/shaders/$n.s" -o "$WD/$n.o" 2>/dev/null || ok=0
            llvm-objcopy -O binary --only-section=.text "$WD/$n.o" "$WD/$n.bin" 2>/dev/null || ok=0
        done
        if [ "$ok" -eq 1 ]; then
            python3 - "$WD" <<'PYEOF'
import sys, struct
W = sys.argv[1]
def dw(p):
    b = open(p, 'rb').read()
    return [struct.unpack_from('<I', b, i)[0] for i in range(0, len(b), 4)]
a = dw(W + '/tex_rgba.bin'); b = dw(W + '/tex_list.bin')
n = len(a)
if len(b) < n:
    print("texl-body-identity: FAIL -- tex_list is SHORTER than tex_rgba; it cannot contain the body")
    sys.exit(1)
diff = [i for i in range(n) if a[i] != b[len(b) - n + i]]
if not diff:
    print(f"texl-body-identity: PASS -- all {n} dwords identical (no prologue?) -- check the sources")
    sys.exit(0)
hi = max(diff)
body = n - 1 - hi
# The prologue is the only place they may differ. If a differing dword appears AFTER the prologue
# region, the shared body assembled differently and the copy is not a copy.
if len(diff) != hi + 1:
    print(f"texl-body-identity: FAIL -- {len(diff)} differing dwords are NOT confined to the")
    print(f"  prologue: they run up to tail index {hi} with gaps. The shared body assembled")
    print(f"  DIFFERENTLY in the two shaders.")
    sys.exit(1)
if body < 300:
    print(f"texl-body-identity: FAIL -- only {body} shared dwords; the prologue cannot be that long")
    sys.exit(1)
print(f"texl-body-identity: PASS -- {body} SHIPPED DWORDS bit-identical "
      f"(tex_rgba prologue {hi+1}, tex_list prologue {hi+1+len(b)-n})")
PYEOF
            rc2=$?
            rm -rf "$WD"
            [ $rc2 -eq 0 ] || exit 1
        else
            rm -rf "$WD"
            echo "texl-body-identity: (dword stage skipped -- assembly failed)"
        fi
    else
        echo "texl-body-identity: (dword stage skipped -- llvm-mc/llvm-objcopy absent)"
    fi
    exit 0
fi

echo "texl-body-identity: FAIL -- the shared body has DIVERGED ($LA lines vs $LB)"
echo "  A fix belongs in BOTH files. Re-copy the body rather than hand-editing the second:"
echo "    tex_rgba.s  = op 0x0B  (rung 13, iron-proven 17/17)"
echo "    tex_list.s = op 0x0C  (rung 14, prologue + THIS body)"
echo "----------------------------------------------------------------"
diff -u "$TA" "$TB" | head -60
exit 1
