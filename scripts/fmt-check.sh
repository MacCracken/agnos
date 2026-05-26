#!/bin/sh
# Local CI-parity format gate — mirrors the `Format` job in
# .github/workflows/ci.yml: run `cyrius fmt <f> --check` on every
# kernel/**/*.cyr (minus the SKIP list) so format drift is caught BEFORE
# push instead of in CI. Wired as the pre-push hook (see
# scripts/install-hooks.sh); also runnable by hand.
#
# Exit 0 if everything is formatted; 1 (listing the offenders + the fix
# command) otherwise. Fix with scripts/fmt-fix.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Hooks can run with a trimmed PATH; fall back to the standard install dir.
CYRIUS="$(command -v cyrius 2>/dev/null || echo "$HOME/.cyrius/bin/cyrius")"
if [ ! -x "$CYRIUS" ]; then
    echo "fmt-check: cyrius not found (PATH + ~/.cyrius/bin) — skipping gate" >&2
    exit 0   # don't block a push just because the toolchain isn't locatable
fi

# shell.cyr is SKIP-listed in ci.yml: `cyrius fmt --check` false-positives
# on it (a `cyrius` token at column 0 inside a string). Keep parity.
SKIP="kernel/user/shell.cyr"

FAIL=0
for f in $(find kernel -name '*.cyr'); do
    [ -f "$f" ] || continue
    if echo "$SKIP" | grep -q "$(basename "$f")"; then continue; fi
    if ! "$CYRIUS" fmt "$f" --check >/dev/null 2>&1; then
        echo "  NEEDS FORMAT: $f"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "" >&2
    echo "Format drift — CI will reject this. Fix in place with:" >&2
    echo "  scripts/fmt-fix.sh" >&2
    exit 1
fi
echo "fmt-check: all kernel files formatted"
exit 0
