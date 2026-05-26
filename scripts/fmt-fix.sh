#!/bin/sh
# Format every kernel/**/*.cyr in place (the actionable companion to
# scripts/fmt-check.sh). NOTE: in cyrius 6.0.x `cyrius fmt <f>` prints the
# formatted source to stdout and `--write` is a no-op, so we capture +
# atomically replace. Only rewrites files that actually need it.
#
# Run before committing/pushing; the pre-push hook only CHECKS.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
    tmp="$(mktemp)"
    if "$CYRIUS" fmt "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
        && "$CYRIUS" fmt "$tmp" --check >/dev/null 2>&1; then          # idempotency guard
        mv "$tmp" "$f"
        echo "  formatted: $f"
        n=$((n + 1))
    else
        rm -f "$tmp"
        echo "  ERROR: could not format $f (left unchanged)" >&2
    fi
done
echo "fmt-fix: $n file(s) reformatted"
exit 0
