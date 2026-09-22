#!/bin/sh
# pp-balance-check — every `#ifdef` / `#ifndef` under kernel/ must be closed by exactly one `#endif`,
# per file, and no `#endif` may appear at depth 0.
#
# ⛔ WHY (1.57.5). kernel/core/main.cyr carried ONE MORE `#endif` than it had openers — the tail of a
# removed `#ifdef TSC_SELFTEST … tsc_selftest(); #endif` whose explanatory comment stayed behind — and
# NOTHING noticed for months: cycc's PP_IFDEF_PASS (cyrius src/frontend/lex_pp.cyr) decrements its depth
# only when it is above zero, so a depth-0 `#endif` is DROPPED WITHOUT A DIAGNOSTIC on every cyrius
# from 6.6.4 through 6.6.6. Harmless today; the day upstream adds an "unbalanced #endif" refusal, the
# whole kernel build stops at that line, on a release that changed nothing near it. It was found by a
# preprocessor MODEL built for the 6.6.6 pin audit, which had to special-case the line to flatten the
# include set at all. A gate that cannot fail today and will fail loudly tomorrow is the right shape
# for this: it costs a text walk.
#
# ⭐ THIS GATE NEVER INVOKES cyrius. It is a pure text walk, for the same reason toolchain-pin-check.sh
# gives: a gate whose verdict depends on the installed compiler's tolerance would be green exactly as
# long as the defect is invisible, which is the failure being closed.
#
# What counts: a line whose first non-blank characters are `#ifdef`, `#ifndef`, `#else` or `#endif`.
# cyrius's preprocessor honours leading whitespace (PP_SKIP_WS), so the walk does too — kernel/user/
# shell.cyr carries directives INSIDE function bodies, indented, and they are real. `#else` is checked
# for depth > 0 as well (an orphan `#else` is the same class). Nothing else on a `#` line is a
# directive: `# comment` is a comment, and `#endif` inside a string literal cannot occur at line start.
#
# Exit 0 if every file balances; 1 (naming file:line and the depth) otherwise. The file count is
# PRINTED on success so an enumeration that silently found nothing is visible (the vacuity floor every
# gate in this tree has learned to assert).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

TMPD="$(mktemp -d)" || { echo "pp-balance-check: FAILED — mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT INT TERM

find kernel -name '*.cyr' -type f | sort > "$TMPD/files"
N="$(grep -c . "$TMPD/files" || true)"
if [ "$N" -lt 10 ]; then
    echo "pp-balance-check: FAILED — found $N .cyr files under kernel/; this gate is vacuous below 10." >&2
    exit 1
fi

: > "$TMPD/bad"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    # awk does the walk; one output line per offence. `sub` strips leading blanks the way PP_SKIP_WS does.
    awk -v F="$f" '
        { s = $0; sub(/^[ \t]+/, "", s) }
        s ~ /^#ifdef[ \t]/ || s ~ /^#ifndef[ \t]/ { d++; next }
        s ~ /^#else([ \t]|$)/ { if (d <= 0) printf "    %s:%d: #else at depth 0 (no open #ifdef)\n", F, NR; next }
        s ~ /^#endif([ \t]|$)/ {
            if (d <= 0) { printf "    %s:%d: #endif at depth 0 (no open #ifdef)\n", F, NR; next }
            d--; next
        }
        END { if (d > 0) printf "    %s: %d #ifdef/#ifndef left open at end of file\n", F, d }
    ' "$f" >> "$TMPD/bad"
done < "$TMPD/files"

if [ -s "$TMPD/bad" ]; then
    echo "pp-balance-check: FAILED — unbalanced preprocessor directives under kernel/:"
    cat "$TMPD/bad"
    echo ""
    echo "  cycc drops a depth-0 #endif silently today; an upstream 'unbalanced #endif' diagnostic would"
    echo "  refuse the whole kernel build at that line. Delete the stray directive (or close the open one)."
    exit 1
fi

echo "pp-balance-check: OK — $N kernel .cyr files, every #ifdef/#ifndef closed exactly once"
exit 0
