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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
# ⚠ Reported, not yet fatal. Extents for the remaining slots are being derived from their actual uses;
# a GUESSED extent is worse than a missing one, because it produces either a false overlap or a missed
# real one and both read as authoritative. Flip BARE_IS_FATAL=1 once every slot is annotated.
BARE_IS_FATAL="${BARE_IS_FATAL:-0}"
nbare=$(printf '%s\n' "$BARE" | grep -c . || true)
if [ "$nbare" -gt 0 ]; then
    echo "  $nbare arena slot(s) declare no extent (\`-> ends 0x…\`) and are therefore UNCHECKED:"
    printf '%s\n' "$BARE" | awk 'NF==3 { printf "    %s (gpu_regs.cyr:%s) at 0x%s\n", $2, $1, toupper($3) }'
    [ "$BARE_IS_FATAL" = "1" ] && fail=1
fi

nannot=$(printf '%s\n' "$ANNOT" | grep -c . || true)
echo "  checked $nannot slot(s) with declared extents, $nbare without"
exit $fail
