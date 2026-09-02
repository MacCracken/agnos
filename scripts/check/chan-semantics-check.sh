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

# ⛔ NO SKIP PATH, AND IT USED TO HAVE ONE. Until 1.56.58 this line read
#     command -v cyrius >/dev/null 2>&1 || { echo "  SKIP: cyrius not on PATH"; exit 0; }
# and that `exit 0` was a false green, measured 2026-09-02:
#     $ env -i PATH=/usr/bin:/bin sh scripts/check/chan-semantics-check.sh
#       SKIP: cyrius not on PATH          <- exit 0
# check.sh's check() (scripts/check.sh:27-35) keys ONLY on `[ "$2" = "0" ]`, so a SKIP is
# INDISTINGUISHABLE from a proof: gate 6 printed "PASS: channel-band semantics (host socketpair
# proof)" having built nothing and run nothing. ⚠ And the machine most likely to hit it is the one
# whose green we actually read — CI installs cyrius under ~/.cyrius/versions/<pin>/bin and exports it
# onto PATH in one step (ci.yml), so a change to that step retires this whole gate silently while the
# run stays green. Same policy as syscall-abi-check.sh:46-47 for this same tree ("A check that
# quietly passes when it could not find one of its three inputs is a false green, and this tree has
# paid for those"), and same verdict as host-gpu-oracles.sh:134, which already exits non-zero here.
command -v cyrius >/dev/null 2>&1 || {
    echo "  FAIL: cyrius not on PATH — the socketpair proof was neither built nor run"
    exit 1
}

cyrius build chantest.cyr build/chantest > /tmp/chan-semantics-build.log 2>&1 || {
    echo "  FAIL: chantest did not build"
    tail -12 /tmp/chan-semantics-build.log
    exit 1
}

rc=0
./build/chantest > /tmp/chan-semantics-run.log 2>&1 || rc=$?
cat /tmp/chan-semantics-run.log
[ "$rc" = "0" ] || exit "$rc"

# ⚠ VACUITY FLOOR ON THE ASSERTION COUNT — the same shape as the SKIP above, one level down.
# chantest's own verdict (chantest.cyr:221) is `if (fail_n == 0) { ... PASS; return 0; }`: a count of
# FAILURES compared to zero, with NOTHING under the number of assertions that ran. A binary whose body
# stopped executing — a family edited out, `ok()` stubbed to a no-op, an early `return 0` — prints
#     passed 0  failed 0
#     chan semantic proof: PASS
# and exits 0, and this gate would forward that to check.sh as the RECORD/BATCH/LIVENESS proof. The
# exit code cannot see the difference; only the count can. So the count is read back, ASSERTED and
# PRINTED rather than implied: a run that says "6 assertions" is reporting that the suite shrank, not
# that the contract holds.
# ⚠ THE FLOOR IS DERIVED, NOT INVENTED. The negative control recorded at check.sh:113 — "building it
# over SOCK_STREAM instead fails exactly the 6 framing assertions and passes the rest" — counts 6
# framing assertions in the RECORD family alone, so a run reporting fewer than 6 passes cannot have
# executed even the first family. The suite runs 18 today, so the floor has 12 of headroom and does
# NOT need bumping when assertions are added; it is a floor under emptiness, not a pinned total.
PASSED=$(grep -oE 'passed +[0-9]+' /tmp/chan-semantics-run.log | grep -oE '[0-9]+' | head -1)
case "$PASSED" in
    ''|*[!0-9]*)
        echo "  FAIL: could not read the assertion count out of chantest's output — the parse above"
        echo "        rotted (chantest.cyr:218 prints '  passed <n>'), so the floor is gone and this"
        echo "        gate's verdict would rest on an exit code that cannot see an empty run"
        exit 1
        ;;
esac
[ "$PASSED" -ge 6 ] || {
    echo "  FAIL: only $PASSED assertion(s) ran (floor 6) — the proof enumerated (almost) nothing and"
    echo "        chantest still exited 0 because its verdict is fail_n == 0, not pass_n > 0"
    exit 1
}
echo "  chan semantic proof: $PASSED assertions executed, 0 failed"
