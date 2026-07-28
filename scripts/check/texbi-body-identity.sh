#!/bin/sh
# texbi-body-identity — prove kernel/shaders/tex_bilin.s (rung 15) carries rung 13's proven code
# VERBATIM everywhere it claims to, and prove the places it does NOT match differ for a stated reason.
#
# ⛔ THE RISK THIS CLOSES IS DRIFT BETWEEN TWO COPIES OF PROVEN CODE — the same risk
# texl-body-identity.sh closes for rung 14, and the same ATOM_DRY defect class: two artifacts
# differing in name but not in intent, where the only real defence is that there is exactly one
# implementation, or failing that a MECHANICAL proof that the second is identical.
#
# ⚠ tex_bilin IS A HARDER CASE THAN tex_list, AND THE DIFFERENCE MATTERS.
# tex_list is a new prologue bolted onto rung 13's body — ONE contiguous shared suffix. tex_bilin
# instead shares rung 13's code at BOTH ENDS and diverges in the MIDDLE (the two axis blocks capture
# a fraction and emit two indices instead of one; the fetch pulls four texels; a blend collapses
# them). So there are two spans to prove, not one, and a gate that checked only the suffix would
# leave the entire prologue — the bounds guard, the coverage read, the signed 64-bit edge setup that
# cost rung 11 four burns — completely unguarded.
#
# WHAT IS PROVEN, in three stages:
#   S1  SOURCE, HEAD SPAN: the format-branch comment through `v[12:13] = E_A`, character for
#       character, comments included.
#   S2  SOURCE, TAIL SPAN: `L_HAVE_TEXEL:` through `s_endpgm`, character for character.
#   S3  SHIPPED DWORDS, TAIL SPAN: the assembled .text sections agree on their last N dwords,
#       tail-aligned. Identical source assembled by the same tool SHOULD produce identical machine
#       code — but "should" is precisely what the blob-drift gate exists because of.
#
# ⚠⚠ WHY THERE IS NO DWORD STAGE FOR THE HEAD SPAN, AND WHY THAT IS NOT A HOLE.
# The head span cannot be dword-identical and it would be WRONG to assert that it is: it contains
# `s_cbranch_execz L_END` and `s_branch L_HAVE_COV`, whose encoded offsets are RELATIVE. tex_bilin
# is 580 dwords to tex_rgba's 442, so L_END is further away and the offset field legitimately
# differs — measured, not assumed: the first differing dword is tex_rgba 0xBF8801A0 vs tex_bilin
# 0xBF88022A, identical SOPP opcode (0xBF88), different simm16.
# ⇒ Rather than shrug at the difference, S4 ASSERTS ITS SHAPE: every differing dword inside the head
# span must be a branch whose HIGH HALF (opcode) still matches. A real code change would alter the
# opcode half and be caught. Comments are in scope in S1/S2 on purpose — a comment that drifts is a
# lie told to the next reader about code they are about to trust, and this body's comments carry the
# reasoning that cost rung 11 four iron burns to learn.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/kernel/shaders/tex_rgba.s"
B="$ROOT/kernel/shaders/tex_bilin.s"
for f in "$A" "$B"; do
    [ -f "$f" ] || { echo "texbi-body-identity: missing $f"; exit 2; }
done

HEAD_MARK='WAVE-UNIFORM BRANCH ON THE FORMAT WORD'
HEAD_END='v[12:13] = E_A'

extract_head() {
    awk -v mark="$HEAD_MARK" -v fin="$HEAD_END" '
        index($0, mark) { on = 1 }
        on { print }
        on && index($0, fin) { exit }
    ' "$1"
}
extract_tail() {
    awk '/^L_HAVE_TEXEL:/ { on = 1 } on { print } on && $1 == "s_endpgm" { exit }' "$1"
}

T1="$(mktemp)"; T2="$(mktemp)"; T3="$(mktemp)"; T4="$(mktemp)"
trap 'rm -f "$T1" "$T2" "$T3" "$T4"' EXIT
extract_head "$A" > "$T1"; extract_head "$B" > "$T2"
extract_tail "$A" > "$T3"; extract_tail "$B" > "$T4"

LH=$(wc -l < "$T1"); LT=$(wc -l < "$T3")
# ⚠ A zero-length or truncated extraction would make `diff` succeed and this gate report PASS while
# proving NOTHING — the vacuous-pass class that let a 4-arg call with 3 args ride for four burns.
# Both floors are set well under the real spans (99 and 75) and well over zero.
[ "$LH" -ge 80 ] || { echo "texbi-body-identity: FAIL -- head span extracted only $LH lines; a marker moved"; exit 1; }
[ "$LT" -ge 60 ] || { echo "texbi-body-identity: FAIL -- tail span extracted only $LT lines; a marker moved"; exit 1; }

fail=0
if diff -u "$T1" "$T2" > /dev/null 2>&1; then
    echo "texbi-body-identity: PASS S1 -- $LH lines of rung 13's HEAD are character-identical"
else
    echo "texbi-body-identity: FAIL S1 -- the head span DRIFTED:"; diff -u "$T1" "$T2" | head -40; fail=1
fi
if diff -u "$T3" "$T4" > /dev/null 2>&1; then
    echo "texbi-body-identity: PASS S2 -- $LT lines of rung 13's TAIL are character-identical"
else
    echo "texbi-body-identity: FAIL S2 -- the tail span DRIFTED:"; diff -u "$T3" "$T4" | head -40; fail=1
fi

command -v llvm-mc >/dev/null 2>&1 && command -v llvm-objcopy >/dev/null 2>&1 || {
    echo "texbi-body-identity: SKIP S3/S4 (no llvm-mc) -- source stages above still ran"
    exit "$fail"; }

WD="$(mktemp -d)"
trap 'rm -f "$T1" "$T2" "$T3" "$T4"; rm -rf "$WD"' EXIT
for n in tex_rgba tex_bilin; do
    llvm-mc -triple=amdgcn-amd-amdhsa -mcpu=gfx90c -filetype=obj "$ROOT/kernel/shaders/$n.s" \
        -o "$WD/$n.o" 2>/dev/null || { echo "texbi-body-identity: FAIL -- $n.s did not assemble"; exit 1; }
    llvm-objcopy -O binary --only-section=.text "$WD/$n.o" "$WD/$n.bin" 2>/dev/null || exit 1
done

python3 - "$WD" "$LT" <<'PYEOF' || fail=1
import sys, struct
W = sys.argv[1]
def dw(p):
    b = open(p, 'rb').read()
    return [struct.unpack_from('<I', b, i)[0] for i in range(0, len(b), 4)]
a = dw(W + '/tex_rgba.bin'); b = dw(W + '/tex_bilin.bin')
rc = 0

if len(b) <= len(a):
    print(f"texbi-body-identity: FAIL -- tex_bilin ({len(b)}) is not LONGER than tex_rgba ({len(a)});")
    print("  bilinear strictly adds a fetch and a blend, so a shorter or equal blob is a truncation.")
    sys.exit(1)

# ---- S3: the tail, dword-identical, tail-aligned --------------------------------------------
suf = 0
while suf < min(len(a), len(b)) and a[len(a)-1-suf] == b[len(b)-1-suf]:
    suf += 1
# The tail span is 56 instructions / 73 dwords as shipped. Assert a floor, not the exact number:
# an exact match would have to be edited every time a comment moves, and a gate people edit to keep
# green is a gate that stops meaning anything.
if suf < 70:
    print(f"texbi-body-identity: FAIL S3 -- only {suf} trailing dwords match; rung 13's tail is 73.")
    print("  The shared tail assembled DIFFERENTLY in the two shaders -- the copy is not a copy.")
    rc = 1
else:
    print(f"texbi-body-identity: PASS S3 -- the last {suf} dwords are identical; rung 15 ships rung 13's")
    print("             iron-proven src-over MACHINE CODE byte for byte, branch offsets included.")

# ---- S4: the head diverges ONLY in branch offsets ---------------------------------------------
# Walk the common head region and require every mismatch to be a SOPP branch (0xBF8x) whose opcode
# half still agrees. Anything else is a real code change wearing a branch's clothes.
HEAD_DWORDS = 110          # comfortably covers the 99-line head span
bad = []
for i in range(min(HEAD_DWORDS, len(a), len(b))):
    if a[i] == b[i]:
        continue
    hi_a, hi_b = a[i] >> 16, b[i] >> 16
    # SOPP: 0xBF8_ ; opcode lives in the high half, simm16 (the relative offset) in the low half.
    if hi_a == hi_b and (hi_a & 0xFFF0) == 0xBF80:
        continue
    bad.append((i, a[i], b[i]))
if bad:
    print(f"texbi-body-identity: FAIL S4 -- {len(bad)} head dword(s) differ in something OTHER than a")
    print("  branch offset. The head span is supposed to be rung 13's code verbatim:")
    for i, x, y in bad[:8]:
        print(f"    dword {i}: tex_rgba 0x{x:08X}  tex_bilin 0x{y:08X}")
    rc = 1
else:
    print(f"texbi-body-identity: PASS S4 -- every difference in the first {HEAD_DWORDS} dwords is a")
    print("             branch OFFSET (same SOPP opcode); no head instruction changed.")
sys.exit(rc)
PYEOF

exit "$fail"
