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
#   sh scripts/burn-prep.sh          # stamps build/agnos.burn-tag
#   sh scripts/burn-verify.sh        # <- run immediately before flashing
#
# Exit 0 = the artifact matches its stamp, safe to flash. Non-zero = DO NOT FLASH.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$ROOT/build/agnos.burn-tag"
BIN="$ROOT/build/agnos"

if [ ! -f "$BIN" ]; then
    echo "burn-verify: no build/agnos. Run scripts/burn-prep.sh first."
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
    echo "  DO NOT FLASH. Re-run: sh scripts/burn-prep.sh   (and run nothing after it)"
    exit 1
fi

echo "burn-verify: OK -- build/agnos matches its stamp."
echo "  $HAVE_SZ bytes, AGNOS $HAVE_VER, $TAG"
echo "  Safe to flash."
