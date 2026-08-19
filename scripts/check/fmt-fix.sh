#!/bin/sh
# Format every kernel/**/*.cyr in place (the actionable companion to
# scripts/check/fmt-check.sh). Only rewrites files that actually need it.
#
# ⚠ CONTRACT CHANGED IN cyrius 6.5.28 (BREAKING). `cyrius fmt <f>` now REWRITES
# THE FILE and prints NOTHING; `--dry` is the old stdout-only form. The previous
# body here did `cyrius fmt "$f" > "$tmp"`, which under 6.5.28 rewrites $f as a
# side effect and leaves $tmp EMPTY — so the `[ -s "$tmp" ]` guard fails and the
# script reports "could not format" for a file it already changed. Reading the
# error at face value would send you hunting a formatter bug that isn't there.
# Formatting is version-dependent, so this must run under the SAME toolchain CI
# uses: the `cyrius` pin in cyrius.cyml (6.5.28), not whatever is newest.
#
# Run before committing/pushing; the pre-push hook only CHECKS.

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

CYRIUS="$(command -v cyrius 2>/dev/null || echo "$HOME/.cyrius/bin/cyrius")"
[ -x "$CYRIUS" ] || { echo "fmt-fix: cyrius not found (PATH + ~/.cyrius/bin)" >&2; exit 1; }

# Match fmt-check's skip — shell.cyr false-positives the formatter.
SKIP="kernel/user/shell.cyr"

n=0
for f in $(find kernel -name '*.cyr'); do
    [ -f "$f" ] || continue
    if echo "$SKIP" | grep -q "$(basename "$f")"; then continue; fi
    if "$CYRIUS" fmt "$f" --check >/dev/null 2>&1; then continue; fi   # already clean
    # Keep the original so a formatter that produces un-checkable output can be
    # ROLLED BACK — an in-place rewrite has no natural undo.
    orig="$(mktemp)"
    cp "$f" "$orig" || { echo "  ERROR: could not back up $f" >&2; rm -f "$orig"; continue; }
    if "$CYRIUS" fmt "$f" >/dev/null 2>&1 \
        && "$CYRIUS" fmt "$f" --check >/dev/null 2>&1; then             # idempotency guard
        rm -f "$orig"
        echo "  formatted: $f"
        n=$((n + 1))
    else
        cp "$orig" "$f"; rm -f "$orig"
        echo "  ERROR: could not format $f (rolled back, left unchanged)" >&2
    fi
done
echo "fmt-fix: $n file(s) reformatted"
exit 0
