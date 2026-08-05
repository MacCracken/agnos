#!/bin/sh
# Channel-band semantic proof — HOST-side, no QEMU, no kernel.
#
# Builds and runs tests/chan/chantest.cyr, which asserts the RECORD / BATCH / LIVENESS contract from
# docs/development/planning/ipc.md §9 against Linux `socketpair(SOCK_SEQPACKET)`.
#
# ⭐ WHY IT IS A CHECK RATHER THAN A SMOKE. It needs no kernel, no image and no QEMU — it runs in
# milliseconds — so it belongs in check.sh where it gates every build, not in the sweep. Bite 3 of the
# migration exists precisely so the contract is executable BEFORE the kernel band is written: §9.8
# records that every claim in the design is "read-only static analysis", and a kernel written against
# a specification nobody ran gets measured against itself.
#
# ⛔ WHAT IT DOES NOT COVER. The authority model — an inherited handle being INERT by construction —
# has no Linux analogue (SEQPACKET fds inherit and work normally). That is bite 5's selftest and its
# kill criterion. Do not cite this check as evidence for it.
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/tests/chan"

command -v cyrius >/dev/null 2>&1 || { echo "  SKIP: cyrius not on PATH"; exit 0; }

cyrius build chantest.cyr build/chantest > /tmp/chan-semantics-build.log 2>&1 || {
    echo "  FAIL: chantest did not build"
    tail -12 /tmp/chan-semantics-build.log
    exit 1
}

./build/chantest
