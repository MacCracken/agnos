#!/bin/sh
# burn-verify.sh — is build/agnos still the artifact burn-prep.sh produced?
#
# WHY THIS EXISTS
#   An iron burn was wasted on 2026-07-15: burn-prep.sh built the HDMI-audio measurement kernel, then
#   scripts/check.sh was run before the flash. check.sh line 24 calls build.sh with NO BUILD_ENV, so it
#   rebuilt build/agnos as a BARE production kernel and silently replaced the burn artifact. The kernel
#   booted fine and looked normal — the entire HDMI-audio block simply was not compiled in, and the test
#   tone went out the analog jack nobody has plugged in. The boot log said nothing was wrong because
#   nothing WAS wrong; the code just was not there.
#
#   Every burn costs the operator a reboot of their only machine. This makes that failure loud.
#
# USAGE
#   sh scripts/burn/burn-prep.sh          # stamps build/agnos.burn-tag
#   sh scripts/burn/burn-verify.sh        # <- run immediately before flashing
#
# Exit 0 = the artifact matches its stamp, safe to flash. Non-zero = DO NOT FLASH.
set -eu

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$ROOT/build/agnos.burn-tag"
BIN="$ROOT/build/agnos"

if [ ! -f "$BIN" ]; then
    echo "burn-verify: no build/agnos. Run scripts/burn/burn-prep.sh first."
    exit 1
fi
if [ ! -f "$STAMP" ]; then
    echo "burn-verify: NO STAMP -- build/agnos was not produced by burn-prep.sh (or was rebuilt since)."
    echo "  Re-run burn-prep.sh and flash immediately."
    exit 1
fi

TAG="$(sed -n 1p "$STAMP")"
WANT_SZ="$(sed -n 2p "$STAMP")"
WANT_VER="$(sed -n 3p "$STAMP")"
WANT_SUM="$(sed -n 4p "$STAMP")"

# ⛔ VACUITY FLOOR ON THE PARSE ITSELF. Four `sed -n Np` reads that find nothing yield four EMPTY
# strings, and only one of the four is ever compared against anything — so a stamp that is truncated,
# blank-first-lined, or written by some future burn-prep with a different field order sails through
# every check below and prints the final verdict with the ARM field EMPTY:
#     ARM:
#     Safe to flash.
# That is the exact failure the ⭐ block at the bottom of this file was written to prevent ("$TAG is
# the difference between a kernel that boots to a prompt and one that auto-execs a game"), reintroduced
# one level up: the loud field is still printed, it just says nothing, and a blank line reads as
# "nothing unusual" rather than as "this parse failed". A stamp whose fields cannot be read is not a
# stamp — it cannot certify anything, so it must not be allowed to certify this.
STAMP_MISSING=""
[ -n "$TAG" ]      || STAMP_MISSING="$STAMP_MISSING line-1-BUILD_TAG"
[ -n "$WANT_SZ" ]  || STAMP_MISSING="$STAMP_MISSING line-2-size"
[ -n "$WANT_VER" ] || STAMP_MISSING="$STAMP_MISSING line-3-VERSION"
[ -n "$WANT_SUM" ] || STAMP_MISSING="$STAMP_MISSING line-4-sha256"
if [ -n "$STAMP_MISSING" ]; then
    echo "burn-verify: UNREADABLE STAMP -- empty field(s):$STAMP_MISSING  (in $STAMP)"
    echo "  The stamp is 4 lines: BUILD_TAG / size / VERSION / sha256. This one is short, blank-lined,"
    echo "  or written in a layout this script does not know. It cannot certify the artifact, and a"
    echo "  blank ARM line at the end would read as an ordinary pass."
    echo "  DO NOT FLASH. Re-run: sh scripts/burn/burn-prep.sh   (and run nothing after it)"
    exit 1
fi

HAVE_SZ="$(stat -c %s "$BIN")"
HAVE_VER="$(cat "$ROOT/VERSION" 2>/dev/null || echo '?')"
HAVE_SUM="$(sha256sum "$BIN" | cut -d' ' -f1)"

if [ "$HAVE_SUM" != "$WANT_SUM" ]; then
    echo "burn-verify: STALE ARTIFACT -- build/agnos has been REBUILT since burn-prep.sh ran."
    echo "  stamped: $WANT_SZ bytes ($TAG, AGNOS $WANT_VER)"
    echo "  on disk: $HAVE_SZ bytes (AGNOS $HAVE_VER)"
    echo ""
    echo "  Almost certainly check.sh or test.sh ran in between -- both call build.sh with no BUILD_ENV,"
    echo "  which rebuilds a BARE production kernel with none of the burn's compile-gated code."
    echo "  DO NOT FLASH. Re-run: sh scripts/burn/burn-prep.sh   (and run nothing after it)"
    exit 1
fi

# ⛔ A SELF-CONSISTENT PAIR IS NOT A FRESH ONE, and that gap cost a burn on 2026-08-02.
# Everything above proves the binary matches the stamp beside it. Yesterday's kernel next to
# yesterday's stamp passes every one of those checks — which is exactly what happened: a DOOM_SELFTEST
# kernel from the previous day was flashed, booted, and auto-ran DOOM, because burn-prep had left it in
# place and this script said "Safe to flash".
#
# So also ask the question the stamp cannot answer: is this artifact NEWER than the sources it claims
# to be built from? Anything under kernel/ that is newer than build/agnos means the binary predates the
# tree and no stamp comparison will ever notice.
#
# ⛔⛔ AND THAT QUESTION IS ASKED BY AN ENUMERATION, SO THE ENUMERATION HAS TO BE FLOORED.
# The line below used to read:
#     NEWER="$(find "$ROOT/kernel" -name '*.cyr' -newer "$BIN" -print -quit 2>/dev/null || true)"
# `-n "$NEWER"` is a NEGATIVE assertion over a producer whose success was never checked, and the
# producer was silenced twice over — `2>/dev/null` ate its complaint and `|| true` laundered its exit
# status. So EVERY way of enumerating zero files scored "newer than every kernel/*.cyr":
#   · $ROOT/kernel absent or renamed (this script computes ROOT from its own path — one wrong `..`,
#     which is a bug this very file carries a ⚠ about at :21, and find has nothing to walk);
#   · a kernel/ that holds no `*.cyr` at all (sources moved, or a partial checkout);
#   · find missing, or refusing on a permission error.
# In all three the script printed "Safe to flash" having compared the artifact against NOTHING —
# which is precisely the DOOM_SELFTEST hole this block was added to close, reopened one level up.
# ⇒ Count the sources FIRST, print the count, and refuse to certify on a set too small to be the
# kernel tree. 92 `*.cyr` live under kernel/ today; the floor is 20 so that a real refactor does not
# redden the last gate before a flash, while a tree that has ceased to exist cannot pass it.
CYR_RC=0
CYR_LIST="$(find "$ROOT/kernel" -name '*.cyr' -print)" || CYR_RC=$?
CYR_N=0
if [ -n "$CYR_LIST" ]; then CYR_N="$(printf '%s\n' "$CYR_LIST" | grep -c .)"; fi
if [ "$CYR_RC" != 0 ] || [ "$CYR_N" -lt 20 ]; then
    echo "burn-verify: FRESHNESS ORACLE IS EMPTY -- enumerated $CYR_N kernel/*.cyr (find rc=$CYR_RC)."
    echo "  Looked under: $ROOT/kernel"
    echo "  The staleness check below asks 'is any source newer than the binary?'. Over an empty set"
    echo "  the answer is always no, so this script would print 'newer than every kernel/*.cyr' and"
    echo "  'Safe to flash' having compared the artifact against nothing at all."
    echo "  DO NOT FLASH. Fix the tree (or this script's ROOT) before certifying anything."
    exit 1
fi

# ⚠ Keep the `-newer` walk separate from the count above: `-print -quit` stops at the FIRST offender,
# which is what makes it cheap, and a walk that stops early cannot also be counted. Its exit status is
# now captured instead of discarded — a find that dies mid-walk must not read as "found nothing".
NEWER_RC=0
NEWER="$(find "$ROOT/kernel" -name '*.cyr' -newer "$BIN" -print -quit)" || NEWER_RC=$?
if [ "$NEWER_RC" != 0 ]; then
    echo "burn-verify: FRESHNESS CHECK FAILED TO RUN -- find exited $NEWER_RC over $ROOT/kernel."
    echo "  An empty result from a find that DIED is not evidence that nothing is newer."
    echo "  DO NOT FLASH."
    exit 1
fi
if [ -n "$NEWER" ]; then
    echo "burn-verify: STALE ARTIFACT -- build/agnos PREDATES the kernel sources."
    echo "  newer than the binary: $NEWER"
    echo ""
    echo "  The stamp matches, so this binary IS what some burn-prep produced -- just not one that saw"
    echo "  the current tree. A kernel from an earlier arm boots perfectly well and runs that arm's"
    echo "  selftest, which is how a DOOM_SELFTEST kernel reached iron on 2026-08-02."
    echo "  DO NOT FLASH. Re-run: sh scripts/burn/burn-prep.sh   (and run nothing after it)"
    exit 1
fi

echo "burn-verify: OK -- build/agnos matches its stamp."
echo "  $HAVE_SZ bytes, AGNOS $HAVE_VER, $TAG"
echo "  built $(date -r "$BIN" '+%Y-%m-%d %H:%M:%S'), newer than all $CYR_N of kernel/*.cyr"
# ⭐ PRINT THE ARM, LOUDLY. "$TAG" is the difference between a kernel that boots to a prompt and one
# that auto-execs a game; it was previously one word on a crowded line. If this does not say what you
# expect this burn to be, stop.
echo ""
echo "  ARM: $TAG"
echo "  Safe to flash."
