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
# ⛔ 1.57.1 — REBUILD WHEN THE KERNEL IS NEWER, NOT ONLY WHEN THE IMAGE IS ABSENT. This is a SCORED
# sweep gate (scripts/sweep.sh), and run_gate rebuilds build/agnos before running it — so with an
# absent-only test the sweep built a kernel and then scored an image made from a DIFFERENT one.
# Measured live at 1.57.1: build/agnos was 09-08, the image 09-07 02:09 — a fossil inside release
# evidence, which is the exact shape the harness-staleness issue was filed about.
# ⭐ 1.57.10 (HAR2 — issue 2026-09-26-harness-backlog-after-1-57-9, item 5): SAY WHY THE REFRESH FAILED. Run
# standalone after a FLAG build (e.g. ap-stack-smoke's SMP_STACK_SELFTEST rebuild), the refresh ran agnsh-smoke.sh,
# which correctly REFUSED the flagged kernel, and this wrapper printed only "could not build the agnsh image". The
# cause sat behind `>/dev/null`. Two changes:
# (1) The provenance check runs HERE, first. This gate is about the PLAIN production kernel. A fresh image is
#     build/agnos itself: agnsh-smoke copies build/agnos into it, and a newer build/agnos forces a refresh. So a
#     flagged build/agnos is refused up front with the flags and the fix named (smoke_require_image). The refusal
#     also no longer runs agnsh-smoke, whose first act is to delete the old image.
# (2) The refresh is logged to build/console-line-logs/agnsh-image.log. A failure prints its REFUSED / ERROR /
#     VOID lines and the log path.
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # smoke_require_image
echo "console-line: kernel provenance (this gate boots the PLAIN production kernel):"
smoke_require_image "$ROOT/build/agnos" ""
if [ ! -f "$ROOT/build/agnsh-smoke/agnos-agnsh.img" ] || [ "$ROOT/build/agnos" -nt "$ROOT/build/agnsh-smoke/agnos-agnsh.img" ]; then
    echo "console-line: building the agnsh image first (absent or older than build/agnos)..."
    CL_LOGS="$ROOT/build/console-line-logs"; mkdir -p "$CL_LOGS"
    sh "$ROOT/scripts/smoke/agnsh-smoke.sh" > "$CL_LOGS/agnsh-image.log" 2>&1 && img_rc=0 || img_rc=$?
    if [ "$img_rc" != 0 ]; then
        echo "console-line: FAILED -- could not build the agnsh image (agnsh-smoke.sh exited $img_rc; log $CL_LOGS/agnsh-image.log):"
        grep -E "REFUSED|ERROR|VOID|FAIL" "$CL_LOGS/agnsh-image.log" | head -8 | sed 's/^/    /'
        [ "$img_rc" = 2 ] && echo "    (exit 2 = the firmware never handed off in agnsh-smoke's tries — a VOID, re-run; not a kernel verdict)"
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
