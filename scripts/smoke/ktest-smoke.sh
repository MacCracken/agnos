#!/bin/sh
# ktest-smoke (1.57.12) — the sweep's row for `KTEST=1 sh scripts/ktest.sh`, at -smp 1 THEN -smp 4, both gated.
#
# Nothing in sweep.sh, check.sh, test.sh or CI ran scripts/ktest.sh at all, and a KTEST build is the only one that runs
# core/main.cyr's KTEST boot self-tests: the syscall, context-switch (two pool kthreads that retire), VFS/initrd and
# userland-exec (a ring-3 child that exits 42) tests and the NVMe write round-trips (which must write OUTSIDE the
# boot disk's GPT and put back what they wrote). ktest.sh scores them since 1.57.12 (its header) as well as the
# in-kernel suite's TOTAL, the disk's first MiB before vs after the boot, and the kernel's own GPT summary line.
# The plain `sh scripts/ktest.sh` is NOT a row: it exits 1 by design (the three [initrd] checks need the test initrd,
# which only a KTEST build creates) — the KTEST run executes the same suite plus those three and the two
# test_initrd adds: 372 checks, at -smp 1 and at -smp 4 (measured 2026-10-10).
# -smp 4 takes smoke_accel's accelerator (KVM, else multi-threaded TCG) and ktest.sh prints it (`accel:`).
# Env: KTEST_SMOKE_SMP (default "1 4"), QEMU_TIMEOUT (passed through to ktest.sh; default 90 there).
# Exit: 0 PASS · 1 FAIL · 2 VOID (a boot's firmware never handed off). ktest.sh leaves a PLAIN build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGS="$ROOT/build/ktest-smoke-logs"
rm -rf "$LOGS"; mkdir -p "$LOGS"
echo "=== ktest smoke (KTEST boot self-tests + the in-kernel suite) ==="
pass=0; fail=0; void=0
for smp in ${KTEST_SMOKE_SMP:-1 4}; do
    echo "--- KTEST=1 KTEST_SMP=$smp sh scripts/ktest.sh ---"
    KTEST=1 KTEST_SMP="$smp" sh "$ROOT/scripts/ktest.sh" > "$LOGS/ktest-smp$smp.out" 2>&1 && rc=0 || rc=$?
    cp "$ROOT/build/ktest-logs/ktest.log" "$LOGS/ktest-smp$smp.log" 2>/dev/null || true
    grep -E "^  accel:|^KTEST boot self-tests:|^ERROR|^RESULT" "$LOGS/ktest-smp$smp.out" | sed 's/^/  /'
    case "$rc" in
        0) echo "  PASS: -smp $smp"; pass=$((pass + 1)) ;;
        2) echo "  VOID: -smp $smp — the firmware never handed off (log: $LOGS/ktest-smp$smp.out)"; void=$((void + 1)) ;;
        *) echo "  FAIL: -smp $smp — ktest.sh rc=$rc (log: $LOGS/ktest-smp$smp.out)"; fail=$((fail + 1)) ;;
    esac
done
echo "=== ktest-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
