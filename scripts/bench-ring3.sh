#!/bin/sh
# bench-ring3.sh — the RING-3 SYSCALL round trip (1.57.6, Path-2 step S3): the before/after numbers for
# the per-process kernel stacks, the preempt-disabling spinlocks and the rewritten SYSCALL stub.
#
# ⭐ WHY NOT scripts/bench.sh. That harness times `ksyscall(N)` from KERNEL context (core/bench.cyr), so
# it never runs the entry stub, the kernel-stack switch, the CR3 pair or SYSRET — the exact code S3
# rewrites. This boots tests/scbench as /bin/agnsh on the kernel in build/agnos (or BENCH_KERNEL=<path>)
# through scripts/smoke/lib/ring3-seed.sh and prints its SCBENCH rows: getpid#2, sched_yield#44 with
# nothing else ready, and an 8-byte pipe write+read pair — each a full ring-3 round trip.
# ⚠ A MEASUREMENT, NOT A GATE: no threshold, no sweep row. Numbers are only comparable between runs on
# the SAME host with the SAME accelerator, which is printed. KVM (`-enable-kvm -cpu host`) is used when
# /dev/kvm is writable, at every -smp (the bench.sh precedent: TCG's rdtsc swings ~5x run to run);
# BENCH_KVM=0 forces TCG.
# Env: BENCH_KERNEL (default build/agnos, which must already be built), BENCH_SMP (default "1 4").
# Exit: 0 every boot printed SCBENCH-DONE · 1 a boot ran and did not · 2 VOID (firmware never handed off).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — measured NOTHING"; exit 1; }
KERNEL="${BENCH_KERNEL:-$ROOT/build/agnos}"
[ -f "$KERNEL" ] || { echo "  ERROR: $KERNEL not built — run sh scripts/build.sh first"; exit 1; }

WORK="$ROOT/build/bench-ring3"; LOGS="$ROOT/build/bench-ring3-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
( cd "$ROOT/tests/scbench" && cyrius build --agnos scbench.cyr build/scbench ) > "$LOGS/scbench-build.log" 2>&1 \
    || { echo "  ERROR: scbench build failed (see $LOGS/scbench-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/scbench/build/scbench" "$SEED/bin/agnsh"
ring3_seed_image "$WORK/B.img" "$KERNEL" "$SEED" "AGNOS-SCBENCH" || { echo "  ERROR: image"; exit 1; }

if [ -w /dev/kvm ] && [ "${BENCH_KVM:-1}" = "1" ]; then R3_ACCEL="-enable-kvm -cpu host"; else R3_ACCEL="$(smoke_accel 4)"; fi
export R3_ACCEL
rc=0
for smp in ${BENCH_SMP:-1 4}; do
    LOG="$LOGS/scbench-smp$smp.log"
    cp "$WORK/B.img" "$WORK/B-$smp.img"
    echo "bench-ring3: -smp $smp  accel: $R3_ACCEL  kernel: $KERNEL"
    ring3_seed_boot "$WORK/B-$smp.img" "$LOG" "SCBENCH-DONE" "${QEMU_TIMEOUT:-120}" "$WORK" -smp "$smp"
    brc=$?
    if [ "$brc" -eq 2 ]; then [ "$rc" -eq 0 ] && rc=2; continue; fi
    strings "$LOG" | grep -E "syscall: stub|SCBENCH" | sed 's/^/    /'
    if ! strings "$LOG" | grep -q "SCBENCH-DONE"; then echo "  bench-ring3: -smp $smp never reached SCBENCH-DONE"; rc=1; fi
done
exit $rc
