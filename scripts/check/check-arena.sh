#!/bin/sh
# check-arena — GPU arena slot overlap gate.
#
# ⛔ WHY THIS REPLACED A VALUE-ONLY CHECK. Every *_SUBOFF in kernel/core/gpu_regs.cyr is a byte offset
# into the ONE compute arena. The previous gate compared offset VALUES for equality
# (`sort | uniq -d`) and its own comment claimed that was "value-only by design: it needs no knowledge
# of each slot's extent, so it cannot rot." That reasoning is exactly backwards — it cannot rot only
# because it was never checking the thing that matters. Two slots do not have to share a START to
# collide; they only have to share a BYTE.
#
# It hid a real one: the batched-frame snapshot at 0xC0000 is 256*128*4 = 0x20000 bytes and spans
# [0xC0000, 0xE0000), while the rung-9 per-edge prep table was allocated at 0xD0000 — wholly inside
# it, and shipped that way. Different values, so `uniq -d` saw nothing.
#
# ⚠ THE STAKES ARE NOT A UNIT-TEST FAILURE. VM_CONTEXT0 is DISABLED on this part: there are no page
# tables, so an out-of-bounds GPU store lands somewhere REAL — the console framebuffer at arena
# offset 0, or the PSP TMR. A collision surfaces as corrupted screen or a wedged box, days later,
# with no pointer back to the constant that caused it.
#
# CONTRACT: every `var <NAME>_SUBOFF = 0x…;` line MUST carry a machine-readable extent on the same
# line, written `-> ends 0x…`. A slot with no declared extent cannot be checked, so an undeclared
# extent is itself reported — silence is not evidence of disjointness.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/kernel/core/gpu_regs.cyr"
[ -f "$SRC" ] || { echo "check-arena: cannot read $SRC"; exit 2; }

# name<TAB>start<TAB>end for every annotated slot; unannotated ones land in the second list.
ANNOT=$(grep -nE "^var [A-Z0-9_]+_SUBOFF *= *0x[0-9A-Fa-f]+" "$SRC" \
    | sed -nE 's/^([0-9]+):var ([A-Z0-9_]+_SUBOFF) *= *0x([0-9A-Fa-f]+).*-> *ends *0x([0-9A-Fa-f]+).*/\1 \2 \3 \4/p')
BARE=$(grep -nE "^var [A-Z0-9_]+_SUBOFF *= *0x[0-9A-Fa-f]+" "$SRC" \
    | grep -viE -- "-> *ends *0x" \
    | sed -nE 's/^([0-9]+):var ([A-Z0-9_]+_SUBOFF) *= *0x([0-9A-Fa-f]+).*/\1 \2 \3/p')

fail=0

# --- 1. overlap among slots that declared an extent -------------------------------------------------
OVER=$(printf '%s\n' "$ANNOT" | awk '
    # ⚠ n MUST be initialised. An uninitialised awk variable used as a subscript is the empty STRING,
    # so the first record lands in key "" while n++ then yields 1 — leaving index 0 unassigned and the
    # END loop reporting a phantom slot with an empty name and a 0x0..0x0 range. That phantom failed
    # this gate on its first run, against a tree that was actually clean.
    BEGIN { n = 0 }
    NF == 4 {
        line[n] = $1; name[n] = $2; s[n] = strtonum("0x" $3); e[n] = strtonum("0x" $4); n++
    }
    END {
        for (i = 0; i < n; i++) {
            if (e[i] <= s[i]) {
                printf "    %s (gpu_regs.cyr:%s): declared end 0x%X is not above start 0x%X\n", name[i], line[i], e[i], s[i]
                bad = 1
                continue
            }
            for (j = i + 1; j < n; j++) {
                if (s[i] < e[j] && s[j] < e[i]) {
                    printf "    %s [0x%X,0x%X) overlaps %s [0x%X,0x%X)  (gpu_regs.cyr:%s and :%s)\n", \
                           name[i], s[i], e[i], name[j], s[j], e[j], line[i], line[j]
                    bad = 1
                }
            }
        }
        exit 0
    }')
if [ -n "$OVER" ]; then
    echo "  OVERLAPPING ARENA SLOTS — two subsystems own the same bytes:"
    printf '%s\n' "$OVER"
    fail=1
fi

# --- 2. exact duplicate starts, including slots with no declared extent ------------------------------
DUPS=$(grep -oE "_SUBOFF *= *0x[0-9A-Fa-f]+" "$SRC" | awk -F'0x' '{print toupper($2)}' | sort | uniq -d)
if [ -n "$DUPS" ]; then
    echo "  DUPLICATE ARENA OFFSETS — two constants name the same address:"
    for d in $DUPS; do
        echo "    0x$d:"
        grep -nE "_SUBOFF *= *0[xX]0*$d\b" "$SRC" | sed 's/^/      /'
    done
    fail=1
fi

# --- 3. slots with no declared extent ---------------------------------------------------------------
# ⛔ FATAL. All 47 slots were derived from their actual uses (widest legal write, cap constants where a
# caller can demand one, hardware-declared sizes where the HW encodes them) and annotated, so a slot
# with no extent now means a NEW slot was added without declaring one — and an unmeasurable slot is
# exactly how the 0xD0000-inside-0xC0000 collision shipped. There is no longer a legitimate bare slot.
# ⚠ If you are adding one: derive the extent from the WIDEST legal use, not the typical one. Two
# specific traps are already recorded in gpu_regs.cyr — a comment describing the free GAP around a
# slot rather than the slot itself (the sentinel is 4 BYTES, not the 4 KB its comment implies), and a
# slot whose writers take the destination as a PARAMETER, so the biggest blob in the tree sets the
# bound, not the one that happens to be pointed there today.
BARE_IS_FATAL="${BARE_IS_FATAL:-1}"
nbare=$(printf '%s\n' "$BARE" | grep -c . || true)
if [ "$nbare" -gt 0 ]; then
    echo "  $nbare arena slot(s) declare no extent (\`-> ends 0x…\`) and are therefore UNCHECKED:"
    printf '%s\n' "$BARE" | awk 'NF==3 { printf "    %s (gpu_regs.cyr:%s) at 0x%s\n", $2, $1, toupper($3) }'
    [ "$BARE_IS_FATAL" = "1" ] && fail=1
fi

nannot=$(printf '%s\n' "$ANNOT" | grep -c . || true)

# --- 4. vacuity floor -------------------------------------------------------------------------------
# ⚠ EVERYTHING ABOVE IS A COUNT-OF-FAILURES == 0 OVER AN ENUMERATION THIS SCRIPT DOES ITSELF.
# Sections 1-3 only report what they FOUND, so an enumeration that finds nothing reports nothing and
# the gate exits 0 having compared no slots. That is not hypothetical — the two parses at the top of
# this file hang on three exact literals: a COLUMN-0 `var` with a single space after it, an
# ALL-CAPS `_SUBOFF` name, and the annotation spelled `-> ends 0x`. Re-indent the block by one space
# (a formatter pass does exactly that), tab-align the `var`, lowercase one name, or re-spell the
# annotation, and both ANNOT and BARE come back empty. The old form then printed
# `checked 0 slot(s) with declared extents, 0 without` and exited 0 — proven, not argued: run against
# a gpu_regs.cyr with every declaration indented one space it scored a clean PASS over an arena it
# had not looked at. In a region set where VM_CONTEXT0 is disabled that green tick is worth nothing:
# the collision it would have caught still lands on the console framebuffer or the PSP TMR.
#
# So the enumeration is ASSERTED, not implied, and the counts PRINT on success. Two axes, because
# there are two ways for it to come back short:
#   (a) FLOOR — how many slots exist at all, counted by a LOOSE grep that deliberately shares none of
#       the anchoring the parses above depend on (leading whitespace allowed, any case, any spacing).
#       The extent sweep annotated 47 and this file has only grown since (62 today), so a run that
#       reports fewer than 40 is reporting that its own enumeration broke, not that the arena shrank.
#   (b) RECONCILIATION — every declaration the loose grep sees must land in ANNOT or BARE. A parse
#       that silently drops SOME rows is the same vacuous pass as one that drops all of them, only
#       quieter: an unparsed slot is an unchecked slot, and section 3 cannot report it as bare
#       because section 3's own grep missed it too.
# ⛔ Neither axis is env-overridable. BARE_IS_FATAL above exists so a tree mid-annotation can still
# run; there is no tree in which comparing zero slots is a pass.
ARENA_SLOT_FLOOR=40
ndecl=$(grep -cE "^[[:space:]]*(var|const|let)[[:space:]]+[A-Za-z0-9_]*_SUBOFF[[:space:]]*=[[:space:]]*0[xX][0-9A-Fa-f]+" "$SRC" || true)
if [ "$ndecl" -lt "$ARENA_SLOT_FLOOR" ]; then
    echo "  check-arena: FAILED — found $ndecl arena slot declaration(s) in $SRC;"
    echo "  this gate is vacuous below $ARENA_SLOT_FLOOR. The extent sweep annotated 47 and the file has only"
    echo "  grown since. Finding fewer means the enumeration broke, not that the arena is clean."
    fail=1
elif [ "$((nannot + nbare))" -ne "$ndecl" ]; then
    echo "  check-arena: FAILED — $ndecl slot declaration(s) present, but only $((nannot + nbare))"
    echo "  ($nannot annotated + $nbare bare) survived the parse; $((ndecl - nannot - nbare)) row(s) were dropped by the"
    echo "  anchored greps at the top of this script (column-0 \`var \`, ALL-CAPS name, \`-> ends 0x\`)."
    echo "  A dropped row is an UNCHECKED slot — it is not reported as bare either, because the same"
    echo "  grep missed it. Fix the parse or the declaration; do not let the count disagree."
    fail=1
fi

echo "  checked $nannot slot(s) with declared extents, $nbare without, of $ndecl declared"
exit $fail
