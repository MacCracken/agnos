#!/bin/sh
# vendored-artifact-check — nothing under tests/*/lib/ or tests/*/build/ may be TRACKED, and both
# must be IGNORED. Two halves of one property; a fix that does only the first leaves the churn.
#
# ⛔⛔ WHY THIS EXISTS, MEASURED. Both directories hold files a build REGENERATES, and a committed
# copy of a regenerated file is not evidence about the source beside it — it is evidence about
# whatever source existed when someone last ran a compiler. Unlike a stale doc, it does not fail; it
# AGREES. This repo has now been bitten by that three times, and the third is what added this gate:
#
#   1. 1.56.44 — 51 committed binaries under tests/gpu/build/. `edgeasm` ran, exited 95 and printed
#      "B4 PASS -- the tool reproduces a shipped iron-proven shader byte-for-byte" while `edgeasm.cyr`
#      beside it COULD NOT COMPILE AT ALL. Purged, and tests/gpu/build/ gitignored.
#   2. 2026-08-24 — that purge swept ONE of seven directories. TWELVE fossils survived in the other
#      six (audio 2, blk 3, chan 4, fault 1, fp 1, symlink 1), and unlike the gpu tools they were NOT
#      byte-identical to a rebuild: symtest 13,856 B committed vs 18,552 B built, gptwr 93,368 vs
#      97,880, blkprobe/blkwr 17,920 vs 18,328. They carried WRONG information, from a toolchain
#      nobody can now name. ⚠ And one of them defeated the 1.56.44 repair itself: stage_one's
#      build-if-absent fires on `[ -f "$bin" ] || _autobuild=1`, so a TRACKED fossil is always present
#      and `faulter_agnos` / `tonegen_agnos` could never take that path.
#   3. 2026-08-24 — 88 vendored stdlib files under tests/*/lib/. tests/symlink/ and tests/blk/ held 7
#      syscalls*.cyr each matching NO installed snapshot: not the 6.5.28 pin, not the 6.5.27 they had
#      just moved off, not the 6.5.35 on the dev box. Both predate v6.4.51 (no `signal_ignore`). The
#      other FIVE dirs matched 6.5.28 exactly — which is the trap. Staleness there is silent and
#      PER-DIRECTORY, so the drifted two were indistinguishable from the clean five without diffing
#      all 88 files against ~/.cyrius/versions/. Nothing in the tree did that. Now nothing has to:
#      `cyrius deps` runs on every `cyrius build` (no flag) and rewrites lib/ from the pin regardless.
#
# ⭐ THE DESIGN CONSEQUENCE: THIS GATE NEVER INVOKES cyrius. Its verdict comes from the git index and
# the ignore rules — files, not builds — so it answers identically on the dev box (every toolchain
# cached) and on a runner (one). Same argument as toolchain-pin-check.sh, and for the same reason: a
# gate whose answer depends on ~/.cyrius/versions/ reproduces the asymmetry it is meant to catch.
#
# ⚠ THE IGNORE HALF IS NOT DECORATION. `git rm --cached` without a matching ignore turns 100 tracked
# files into 100 UNTRACKED ones, and every build that rewrites them leaves the tree dirty in
# `git status` — the same churn in a different column. So both halves are asserted.
#
# ⚠ VACUITY FLOOR. This tree's check.sh has found FIVE gates that could not fail, and a gate that
# enumerates files and asserts a NEGATIVE fails the same way: silently, by enumerating nothing. An
# empty `git ls-files` (wrong cwd, broken pathspec, detached index) would report a clean tree. So the
# tracked-file count under tests/ is asserted (>= 20) and PRINTED on success — a run that says
# "3 files" is reporting that its own enumeration broke, not that the tree is clean.
#
# Exit 0 if clean; 1 (listing each offender) otherwise.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    # A tarball has no index, and "tracked" is a statement ABOUT an index. There is no weaker
    # version of this check to run here — say so rather than printing a PASS that asserts nothing.
    echo "vendored-artifact-check: SKIP — not a git checkout; this gate is about the index."
    exit 0
fi

# ── Half 1: nothing tracked ──
TRACKED="$(git -C "$ROOT" ls-files -- 'tests/*' | grep -E '^tests/[^/]+/(lib|build)/' || true)"

# ── Vacuity floor, BEFORE the verdict. ──
ALL="$(git -C "$ROOT" ls-files -- 'tests/*' | grep -c . || true)"
if [ "$ALL" -lt 20 ]; then
    echo "vendored-artifact-check: FAILED — 'git ls-files tests/' returned $ALL file(s); this gate is vacuous below 20." >&2
    echo "  The tests/ tree carries a manifest plus sources for seven projects. Finding fewer means" >&2
    echo "  the enumeration broke, not that the tree is clean." >&2
    exit 1
fi

# ── Half 2: both patterns actually ignored. ──
# Probe a path INSIDE each real tests/* project rather than a synthetic one, so a rule that
# accidentally anchors to a single directory (which is exactly how the 1.56.44 rule read) is caught.
# git check-ignore does not require the file to exist.
UNIGNORED=""
NPROBE=0
for d in "$ROOT"/tests/*/; do
    [ -d "$d" ] || continue
    t="tests/$(basename "$d")"
    for sub in lib build; do
        NPROBE=$((NPROBE + 1))
        git -C "$ROOT" check-ignore -q "$t/$sub/probe" 2>/dev/null \
            || UNIGNORED="$UNIGNORED    $t/$sub/ is NOT ignored\n"
    done
done
if [ "$NPROBE" -lt 2 ]; then
    echo "vendored-artifact-check: FAILED — probed $NPROBE path(s); the tests/*/ glob matched nothing." >&2
    exit 1
fi

rc=0
if [ -n "$TRACKED" ]; then
    N="$(printf '%s\n' "$TRACKED" | grep -c . || true)"
    echo "vendored-artifact-check: FAILED — $N regenerated file(s) are TRACKED under tests/*/{lib,build}/"
    printf '%s\n' "$TRACKED" | sed 's/^/    /'
    echo ""
    echo "  lib/   is rewritten from the pinned toolchain by 'cyrius deps', which 'cyrius build' runs"
    echo "         BY DEFAULT — a committed copy is overwritten before it is ever read."
    echo "  build/ is a compiled artifact. A committed one does not fail when it goes stale; it agrees."
    echo "  Fix:  git rm -r --cached tests/*/lib tests/*/build   (the files stay on disk)"
    rc=1
fi
if [ -n "$UNIGNORED" ]; then
    echo "vendored-artifact-check: FAILED — untracked-but-not-ignored artifact paths:"
    printf "$UNIGNORED"
    echo ""
    echo "  Untracking without ignoring just moves the churn from 'modified' to 'untracked':"
    echo "  every build rewrites these, so 'git status' is dirty on a tree nobody edited."
    echo "  Fix:  .gitignore needs  tests/*/lib/  and  tests/*/build/"
    rc=1
fi
[ "$rc" = "0" ] || exit 1

echo "vendored-artifact-check: OK — 0 tracked under tests/*/{lib,build}/, $NPROBE paths ignored, $ALL tests/ files enumerated"
exit 0
