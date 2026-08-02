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
NEWER="$(find "$ROOT/kernel" -name '*.cyr' -newer "$BIN" -print -quit 2>/dev/null || true)"
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
echo "  built $(date -r "$BIN" '+%Y-%m-%d %H:%M:%S'), newer than every kernel/*.cyr"
# ⭐ PRINT THE ARM, LOUDLY. "$TAG" is the difference between a kernel that boots to a prompt and one
# that auto-execs a game; it was previously one word on a crowded line. If this does not say what you
# expect this burn to be, stop.
echo ""
echo "  ARM: $TAG"
echo "  Safe to flash."
