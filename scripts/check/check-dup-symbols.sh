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
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GPU="$ROOT/tests/gpu"

fail=0

# Top-level declarations only: `fn name(` / `var name` anchored at column 0. Indented declarations are
# function-local and out of scope.
syms() {
    grep -oE "^(fn [a-zA-Z_][a-zA-Z0-9_]*|var [a-zA-Z_][a-zA-Z0-9_]*)" "$1" 2>/dev/null \
        | sed -E 's/^(fn|var) //' | sort -u
}

# Every oracle that includes a shared layer, paired with the layer it includes. Add a row when a new
# shared file appears; a shared file with no row here is ungated.
#
# ⚠ Only files that ACTUALLY include the layer are listed. Listing a file that does not include it
# would report a phantom collision — the two never share a translation unit.
for pair in "asmlib.cyr"; do
    lib="$GPU/$pair"
    [ -f "$lib" ] || { echo "check-dup-symbols: $pair not found"; exit 1; }
    for f in "$GPU"/*.cyr; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [ "$base" = "$pair" ] && continue
        grep -qE "^include \"$pair\"" "$f" || continue

        dups=$(comm -12 <(syms "$lib") <(syms "$f"))
        if [ -n "$dups" ]; then
            echo "  FAIL: $base and $pair both declare:"
            echo "$dups" | sed 's/^/          /'
            n=$(echo "$dups" | grep -c .)
            nvar=$(echo "$dups" | while read -r s; do grep -qE "^var $s( |\[|=)" "$f" && echo x; done | grep -c .)
            echo "        ($n symbols; $nvar are 'var' and cycc reports NONE of those)"
            fail=1
        fi
    done
done

# A module-scope array declared at two different sizes anywhere under tests/gpu is the worst shape of
# the above, so it is called out separately even when the files never share a unit — a future include
# would activate it silently.
tmp=$(mktemp)
grep -hoE "^var [a-zA-Z_][a-zA-Z0-9_]*\[[0-9]+\]" "$GPU"/*.cyr 2>/dev/null \
    | sed -E 's/^var //; s/\[/ /; s/\]//' | sort -u > "$tmp"
awk '{ if ($1 in seen && seen[$1] != $2) { printf("  FAIL: array %s declared at BOTH %s and %s\n", $1, seen[$1], $2); bad=1 } else seen[$1]=$2 }
     END { exit bad ? 1 : 0 }' "$tmp" || fail=1
rm -f "$tmp"

if [ "$fail" != "0" ]; then
    echo "check-dup-symbols: FAILED"
    exit 1
fi
echo "check-dup-symbols: OK — no shared-layer symbol collisions in tests/gpu"
