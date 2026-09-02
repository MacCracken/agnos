#!/bin/sh
# check-dup-symbols.sh — no two files in one tests/gpu translation unit may declare the same
# module-scope symbol.
#
# ⛔⛔ WHY THIS EXISTS, MEASURED. cycc's behaviour on a duplicate module-scope symbol is NOT uniform:
#   · duplicate `fn`  -> a warning on stderr
#   · duplicate `var` -> **NOTHING**. No warning, no error, no mention, even when the two
#     declarations are arrays of DIFFERENT SIZES (`var arr[64]` in an included file vs `var arr[8]`
#     in the includer). Probed directly on 2026-08-13 with cycc 6.5.20:
#     `cyrius build … 2>&1 | grep -ci duplicate` = 0, build reports OK.
# ⚠ HONEST LIMIT ON THE CLAIM: I could NOT demonstrate that this corrupts memory. Several probe
# shapes left the adjacent symbol intact, and an `&a - &b` reading of 0 looked like constant folding
# rather than real aliasing. So the justification here is **silent, undiagnosed duplication with a
# layout the source does not determine** — not "proven corruption". That is enough: a verification
# tool whose symbols may silently resolve to another file's definition cannot be trusted to report on
# anything else, and the compiler will never tell you.
#
# ⛔ THE TRIGGER. At 1.56.44 `tests/gpu/asmlib.cyr` was factored out of `tests/gpu/edgeasm.cyr`, and
# edgeasm is being converted to include it. The two files share **46 top-level symbols**, of which
# **13 are `var`** — EA_ISA_BYTES, EA_MAXLAB, EXEC_LO, F1, LIT, VCC, ea_fault, ea_vgpr_max, isa,
# lab_off, n_patch, patch_off, patch_tgt — and four of those are ARRAYS (isa, lab_off, patch_off,
# patch_tgt). Grepping the build log for "duplicate" is blind to all 13.
# ⚠ AND THE LOG IS SWALLOWED ANYWAY: `host-gpu-oracles.sh` captures build output into `$out` and
# prints it only when the build FAILS, so even the 33 `fn` warnings never reach a human on success.
#
# ⚠ SIBLING GATE, DIFFERENT SCOPE: `check-array-sizing.sh` inspects function-LOCAL arrays for
# overruns. It cannot see this class at all — these are module-scope declarations in two files.
#
# ⚠ VACUITY FLOOR, AND IT IS NOT HYPOTHETICAL — EVERY ENUMERATION BELOW WAS MEASURED SCORING PASS
# HAVING COMPARED NOTHING. Four separate shapes, all probed on copies of this script on 2026-09-02,
# every one of them printing `check-dup-symbols: OK — no shared-layer symbol collisions in tests/gpu`
# and exiting 0:
#   · THE SOURCE GLOB. Pointed at a tests/gpu holding one empty asmlib.cyr: both loops ran zero
#     times, `fail` was still 0 at the exit. tests/gpu being renamed, moved, or emptied does not make
#     this gate red — it makes it green.
#   · THE INCLUDER GREP `^include "asmlib.cyr"`. Anchored, and exact to the byte. Respelling the
#     include in all three real includers as `include  "asmlib.cyr"` (ONE extra space) took the
#     comparison set from 3 files to 0 and the gate still said OK. `include "./asmlib.cyr"` or the
#     layer moving into a subdirectory do the same thing just as quietly.
#   · THE `syms()` PARSE. One grep anchored on `^fn ` / `^var `. Indenting asmlib.cyr's declarations
#     by two spaces — a stand-in for any future change to declaration syntax — made syms() return the
#     empty set for the layer, so `comm -12` found no overlap with ANY includer and all 46 known
#     collisions reported clean. A rotted parse here does not error; it agrees with everything.
#   · THE ARRAY-SIZE HALF. `grep -hoE "^var name[N]"` over an input with no sized module-scope arrays
#     leaves the awk an empty file, and awk exits 0 over empty input.
# So each count is asserted AND PRINTED on success rather than implied: >= 2 source files, >= 1
# shared-layer row, >= 1 includer per row, >= 1 top-level symbol on the layer side, >= 1 sized
# module-scope array. A run that says "1 source file" or "0 includers" is reporting that its own
# enumeration broke, not that tests/gpu is clean. Same floor, same reason, as
# scripts/check/toolchain-pin-check.sh's manifest count.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GPU="$ROOT/tests/gpu"

fail=0

# ⚠ THE ENUMERATED LISTS MOVE THROUGH FILES AND EVERY LOOP READS THEM WITH `while read` FED BY A
# REDIRECT — never `for x in $LIST` (zsh does not word-split unquoted variables, so the list would
# collapse into one bogus path) and never `... | while read` (a pipe runs the body in a subshell, so
# `fail=1` would be discarded and this gate would report OK regardless of what it found). Both
# mistakes are recorded in toolchain-pin-check.sh, measured on a clean tree.
TMPD="$(mktemp -d)" || { echo "check-dup-symbols: FAILED — mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT INT TERM

# Top-level declarations only: `fn name(` / `var name` anchored at column 0. Indented declarations are
# function-local and out of scope.
syms() {
    grep -oE "^(fn [a-zA-Z_][a-zA-Z0-9_]*|var [a-zA-Z_][a-zA-Z0-9_]*)" "$1" 2>/dev/null \
        | sed -E 's/^(fn|var) //' | sort -u
}

# ── ENUMERATION 1: the source files this gate compares ────────────────────────────────────────────
# `find`, not a glob: an unmatched glob stays literal and would be handed to the loop as a filename
# that does not exist, which reads identically to "nothing to do".
find "$GPU" -maxdepth 1 -type f -name '*.cyr' 2>/dev/null | sort > "$TMPD/sources"
NSRC=$(grep -c . "$TMPD/sources" || true)
if [ "$NSRC" -lt 2 ]; then
    echo "check-dup-symbols: FAILED — found $NSRC .cyr file(s) under $GPU; this gate is vacuous below 2." >&2
    echo "  What it compares is a shared layer against the files that include it, so it needs at" >&2
    echo "  least two. Finding fewer means the enumeration broke — tests/gpu renamed, moved, or this" >&2
    echo "  script relocated relative to it — not that the tree is clean." >&2
    exit 1
fi

# ── ENUMERATION 2: the shared layers ──────────────────────────────────────────────────────────────
# Every oracle that includes a shared layer, paired with the layer it includes. Add a row when a new
# shared file appears; a shared file with no row here is ungated.
#
# ⚠ Only files that ACTUALLY include the layer are listed. Listing a file that does not include it
# would report a phantom collision — the two never share a translation unit.
cat > "$TMPD/pairs" <<'PAIRS'
asmlib.cyr
PAIRS
NPAIRS=$(grep -c . "$TMPD/pairs" || true)
if [ "$NPAIRS" -lt 1 ]; then
    echo "check-dup-symbols: FAILED — 0 shared-layer rows; this gate compares nothing without one." >&2
    exit 1
fi

while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    lib="$GPU/$pair"
    [ -f "$lib" ] || { echo "check-dup-symbols: FAILED — $pair not found under $GPU" >&2; exit 1; }

    # ── FLOOR: the parse itself. This is the canary for syms() rotting. The same regex runs over
    # every file, so if the declaration syntax moves out from under it, the layer side goes to zero
    # first — and a zero-symbol layer silently "agrees" with every includer in the tree.
    syms "$lib" > "$TMPD/lib.syms"
    nlib=$(grep -c . "$TMPD/lib.syms" || true)
    if [ "$nlib" -lt 1 ]; then
        echo "check-dup-symbols: FAILED — $pair yields 0 top-level symbols" >&2
        echo "  syms() matches \`fn name\` / \`var name\` anchored at column 0. A shared layer with no" >&2
        echo "  module-scope declaration at all is not a shared layer; far likelier is that the" >&2
        echo "  declaration syntax changed and this gate now compares two empty sets, which agree." >&2
        exit 1
    fi

    nincl=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        base=$(basename "$f")
        [ "$base" = "$pair" ] && continue
        grep -qE "^include \"$pair\"" "$f" || continue
        nincl=$((nincl + 1))

        syms "$f" > "$TMPD/f.syms"
        comm -12 "$TMPD/lib.syms" "$TMPD/f.syms" > "$TMPD/dups"
        if [ -s "$TMPD/dups" ]; then
            echo "  FAIL: $base and $pair both declare:"
            sed 's/^/          /' "$TMPD/dups"
            n=$(grep -c . "$TMPD/dups" || true)
            nvar=$(while read -r s; do grep -qE "^var $s( |\[|=)" "$f" && echo x; done < "$TMPD/dups" \
                   | grep -c . || true)
            echo "        ($n symbols; $nvar are 'var' and cycc reports NONE of those)"
            fail=1
        fi
    done < "$TMPD/sources"

    # ── FLOOR: the includer grep. A row exists BECAUSE files include that layer; zero includers means
    # either the include spelling drifted past this anchored, exact-match grep (`include  "x.cyr"`,
    # `include "./x.cyr"`, a subdirectory) or the row is stale and belongs deleted. Both are edits a
    # human must make. Neither is "clean".
    if [ "$nincl" -lt 1 ]; then
        echo "  FAIL: 0 of $NSRC files under tests/gpu match ^include \"$pair\" — nothing was compared."
        echo "        Either the include spelling drifted (this grep is anchored and exact: one extra"
        echo "        space, a ./ prefix, or a subdirectory all match zero files), or $pair is no"
        echo "        longer shared and its row above should be removed."
        fail=1
    else
        echo "  $pair: $nincl includer(s) compared against its $nlib top-level symbols"
    fi
done < "$TMPD/pairs"

# ── ENUMERATION 3: module-scope sized arrays ──────────────────────────────────────────────────────
# A module-scope array declared at two different sizes anywhere under tests/gpu is the worst shape of
# the above, so it is called out separately even when the files never share a unit — a future include
# would activate it silently.
grep -hoE "^var [a-zA-Z_][a-zA-Z0-9_]*\[[0-9]+\]" "$GPU"/*.cyr 2>/dev/null \
    | sed -E 's/^var //; s/\[/ /; s/\]//' | sort -u > "$TMPD/arrays"
NARR=$(grep -c . "$TMPD/arrays" || true)
if [ "$NARR" -lt 1 ]; then
    # ⚠ awk exits 0 over an empty file, so without this the size-conflict half is a no-op that reads
    # as a pass. tests/gpu carried 138 such declarations when this floor was written; zero means the
    # `^var name[N]` grep stopped matching, not that the oracles stopped declaring arrays.
    echo "  FAIL: 0 module-scope sized arrays found across $NSRC file(s) under tests/gpu."
    echo "        The size-conflict check below runs awk over that list; an empty list makes it a"
    echo "        no-op that exits 0. Either the \`^var name[N]\` declaration syntax moved or the"
    echo "        enumeration broke."
    fail=1
else
    awk '{ if ($1 in seen && seen[$1] != $2) { printf("  FAIL: array %s declared at BOTH %s and %s\n", $1, seen[$1], $2); bad=1 } else seen[$1]=$2 }
         END { exit bad ? 1 : 0 }' "$TMPD/arrays" || fail=1
fi

if [ "$fail" != "0" ]; then
    echo "check-dup-symbols: FAILED"
    exit 1
fi
echo "check-dup-symbols: OK — no shared-layer symbol collisions in tests/gpu"
echo "  ($NSRC source files, $NPAIRS shared layer(s), $NARR sized module-scope arrays compared)"
