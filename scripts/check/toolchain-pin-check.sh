#!/bin/sh
# toolchain-pin-check — every cyrius.cyml in the tree must pin the SAME toolchain as the ROOT manifest.
#
# ⛔⛔ WHY THIS EXISTS, MEASURED. CI installs EXACTLY ONE cyrius, and it reads the version from the
# ROOT manifest only (.github/workflows/ci.yml:37, and release.yml:44, verbatim):
#     export CYRIUS_VERSION="$(grep -oP '(?<=^cyrius = ")[^"]+' cyrius.cyml)"
# Every nested manifest is therefore a CLAIM ON A TOOLCHAIN NOBODY INSTALLS. The wrapper resolves the
# manifest at the compile cwd, so `cd tests/gpu && cyrius build ...` (host-gpu-oracles.sh:179) resolves
# tests/gpu/cyrius.cyml, not the root — and if that pin is not present under ~/.cyrius/versions/ it is
# a HARD ERROR, not a warning:
#     error: cyrius.cyml pins version 6.5.27 but cyrius binary is not installed at
#            /home/runner/.cyrius/versions/6.5.27/bin/cyrius
#
# ⛔ AND HERE IS THE PART THAT MAKES IT A GATE RATHER THAN A LINT: THE BUG IS INVISIBLE ON THE DEV BOX.
# Both behaviours were probed directly (2026-08-24, wrapper 6.5.35):
#   · pin 6.5.99 (NOT installed) -> `error: ... is not installed`, build ABORTS.
#   · pin 6.5.27 (IS installed)  -> `warning: cyrius.cyml pins 6.5.27 but cycc is 6.5.35 —
#                                    toolchain drift (snapshot may be stale)`, build OK, rc=0.
# The dev box has all ~480 versions cached, so the identical tree that hard-errors in CI merely warns
# here. ⚠ WORSE, THE WARNING CARRIES NO SIGNAL: it compares the pin against the INSTALLED cycc
# (6.5.35), not against the root pin — so the root manifest at 6.5.28 warns in exactly the same words
# as the seven drifted ones at 6.5.27. The broken manifests are indistinguishable from the correct one.
# ⚠ AND NOBODY EVER SEES EVEN THAT: host-gpu-oracles.sh:179 captures the build into `$out` and prints
# it only on FAILURE, so on the dev box the warning is emitted into a variable and discarded.
#
# ⭐ THE DESIGN CONSEQUENCE, AND IT IS THE WHOLE POINT: THIS GATE NEVER INVOKES cyrius. It is a pure
# text comparison of pin strings. Any gate that tried to *build* something to test the pin would have
# its verdict decided by the contents of ~/.cyrius/versions/ — green on the machine with every version
# cached, red on the runner with one. That asymmetry IS the bug being fixed; a gate that reproduced it
# would be worthless. This one returns the same answer on both machines, from the files alone.
#
# ⚠ EXCLUSIONS ARE DERIVED, NOT INVENTED. A raw `find . -name cyrius.cyml` sees 11 manifests here; 3
# are not source: build/vani-tone-smoke/consumer/ (a build artifact), .claude/worktrees/kashi/ (a
# sibling worktree), and the vendored `lib/` stdlib snapshots `cyrius deps` writes into each tests/*
# project. The first two are already declared non-source by .gitignore (lines 2 and 27 — confirmed
# with `git check-ignore -v`), so `git ls-files` excludes them BY CONSTRUCTION rather than by a
# hand-kept list that would rot. `--others --exclude-standard` is included deliberately so a
# brand-new manifest that has not been `git add`-ed yet is gated the moment it is written, not the
# day it is committed.
# ⚠ THE `lib/` PRUNE BELOW IS STILL LOAD-BEARING, FOR A CHANGED REASON. Until 2026-08-24 those
# snapshots were TRACKED (88 files; .gitignore's `/lib/` is root-anchored and never covered
# tests/*/lib/), so `git ls-files` listed them and the prune was the only thing dropping them. They
# are now untracked AND ignored — but `--others --exclude-standard` is not what excludes them, it is
# the ignore rule, and an ignore rule is one edit away from being narrowed. Keep the prune: it costs
# nothing and it is what stops this gate reading a vendored snapshot's manifest if that rule moves.
#
# ⚠ VACUITY FLOOR. This tree's check.sh has found four gates that could not fail. A gate that
# enumerates files and compares them to a constant fails the same way — silently, by enumerating
# nothing. So the manifest count is asserted (>= 2) and PRINTED on success rather than implied: a run
# that says "1 manifest" is reporting that its own enumeration broke, not that the tree is clean.
#
# Exit 0 if every manifest agrees with the root; 1 (listing each offender) otherwise.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

# Use the EXACT extraction CI uses, so this gate and CI can never disagree about what "the root pin"
# is. That expression needs PCRE; probe for it rather than letting an unsupported -P return empty and
# turn this gate into a comparison of "" against "" that passes on every tree.
# ⚠ The probe must MATCH, not merely run: `printf '' | grep -qP ''` returns 1 on empty input even
# where -P works perfectly, so that shape reports every host as PCRE-less. Probe a real lookbehind
# against input it matches — the same construct the extraction below depends on.
echo 'cyrius = "0"' | grep -qoP '(?<=^cyrius = ")[^"]+' 2>/dev/null || {
    echo "toolchain-pin-check: FAILED — needs grep -P (PCRE), to match .github/workflows/ci.yml:37" >&2
    exit 1
}

ROOT_PIN="$(grep -oP '(?<=^cyrius = ")[^"]+' "$ROOT/cyrius.cyml" 2>/dev/null || true)"
if [ -z "$ROOT_PIN" ]; then
    echo "toolchain-pin-check: FAILED — could not read the root pin from cyrius.cyml" >&2
    echo "  Expected a line of the exact form: cyrius = \"X.Y.Z\"" >&2
    echo "  CI reads it with the same expression; if this cannot see it, CI installs nothing." >&2
    exit 1
fi

if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    # Tracked + untracked-but-not-ignored, so .gitignore owns the build/ and .claude/ exclusions.
    # Then drop the vendored `cyrius deps` stdlib snapshots, which are tracked and so survive git.
    MANIFESTS="$(git -C "$ROOT" ls-files --cached --others --exclude-standard -- '*cyrius.cyml' \
                 | grep -vE '(^|/)lib/' || true)"
    SRC="git ls-files (build/ + .claude/ via .gitignore) minus vendored */lib/ snapshots"
else
    # Tarball / no-git fallback. Prunes the same four directory names by hand; kept SECOND so the
    # hand-kept list is never the thing that normally runs.
    MANIFESTS="$(find . \( -name .git -o -name .claude -o -name build -o -name lib \) -prune -o \
                 -name cyrius.cyml -print | sed 's|^\./||' | sort || true)"
    SRC="find with pruned .git/.claude/build/lib (git unavailable)"
fi

N="$(printf '%s\n' "$MANIFESTS" | grep -c . || true)"
if [ "$N" -lt 2 ]; then
    echo "toolchain-pin-check: FAILED — found $N manifest(s); this gate is vacuous below 2." >&2
    echo "  enumerated via: $SRC" >&2
    echo "  The tree has a root manifest plus one per tests/* project. Finding fewer means the" >&2
    echo "  enumeration broke, not that the tree is clean." >&2
    exit 1
fi

DRIFT=""
for m in $MANIFESTS; do
    [ "$m" = "cyrius.cyml" ] && continue
    pin="$(grep -oP '(?<=^cyrius = ")[^"]+' "$ROOT/$m" 2>/dev/null || true)"
    if [ -z "$pin" ]; then
        DRIFT="$DRIFT    $m: NO cyrius pin at all (root pins $ROOT_PIN)\n"
    elif [ "$pin" != "$ROOT_PIN" ]; then
        DRIFT="$DRIFT    $m: pins $pin  (root pins $ROOT_PIN)\n"
    fi
done

if [ -n "$DRIFT" ]; then
    echo "toolchain-pin-check: FAILED — nested cyrius.cyml pins disagree with the ROOT pin ($ROOT_PIN)"
    printf "$DRIFT"
    echo ""
    echo "  CI installs ONLY $ROOT_PIN (ci.yml:37 reads the ROOT manifest). Any build that runs with"
    echo "  one of the above as its compile cwd resolves that manifest instead and hard-errors with"
    echo "  'pins version X but cyrius binary is not installed'. This is GREEN on a dev box with every"
    echo "  version cached, which is why it needs a gate and not a warning."
    echo "  Fix: set every manifest listed above to  cyrius = \"$ROOT_PIN\"  in the SAME edit as the root."
    exit 1
fi

echo "toolchain-pin-check: OK — $N manifests, all pin $ROOT_PIN"
exit 0
