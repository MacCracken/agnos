#!/bin/sh
# console-line-smoke.sh — sweep wrapper for scripts/harness/console-line-preserve-test.py.
#
# THE PROPERTY: an asynchronous kernel log must not alter the line the operator is typing. The harness
# types a partial command at the prompt, fires the mouse one-shot while it is on screen, and requires the
# last console row to be PIXEL-IDENTICAL before and after.
#
# ⛔⛔ THE VERDICT LINE IS THE DANGEROUS PART OF A WRAPPER, NOT THE TEST.
# `sweep.sh:run_gate` accepts a gate on `grep -qiE "smoke.*PASS"` against the WHOLE log. So any line
# containing both "smoke" and "PASS" — including a failure message that merely mentions the word — turns
# a red gate green. This tree has already shipped that defect once (`edge-abi-smoke.sh`, fixed 1.56.44).
# ⇒ The success line is the ONLY line here carrying the token, and the failure lines deliberately spell
# the outcome without it.
#
# ⚠ INCONCLUSIVE (harness exit 2) IS NOT A PASS. No image, no OVMF, no boot, or a one-shot that never
# fired all mean the property was never exercised. Those exit non-zero and print no PASS token, because
# "we could not test it" and "it works" must never be the same colour.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The harness needs the agnsh disk image. agnsh-smoke.sh builds it and boots once; reuse it rather than
# duplicating the parted/mformat/mkfs recipe (same move agnsh-hiram-smoke.sh makes).
if [ ! -f "$ROOT/build/agnsh-smoke/agnos-agnsh.img" ]; then
    echo "console-line: building the agnsh image first..."
    if ! sh "$ROOT/scripts/smoke/agnsh-smoke.sh" >/dev/null 2>&1; then
        echo "console-line: FAILED -- could not build the agnsh image"
        exit 1
    fi
fi

python3 "$ROOT/scripts/harness/console-line-preserve-test.py"
rc=$?

if [ "$rc" = "0" ]; then
    echo "console-line-smoke: PASS -- an async log left the operator's typed line pixel-identical"
    exit 0
fi
if [ "$rc" = "1" ]; then
    echo "console-line-smoke: FAILED -- a kernel log altered the line being typed at the prompt"
    exit 1
fi
echo "console-line-smoke: INCONCLUSIVE (rc=$rc) -- the property was never exercised; treating as failure"
exit 1
