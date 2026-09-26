#!/bin/sh
# ipc-wait-smoke.sh — 1.57.8: BLOCKING pipe and channel reads, and the #44 directed park kick, from ring 3.
# Issue: docs/development/issues/2026-09-25-cross-cpu-poll-and-yield-loops-are-tick-bound.md (its Gate section).
#
# tests/ipcw/ipcw.cyr is seeded as /bin/agnsh (the driver AND every child role, spawned by #43). Phases (the program's
# header has the details): pipe-pp and chan-pp — a ping-pong through two pipes / one channel with BLOCKING read#5
# (a4 = 0), gated < 1 ms per round · yield-peer — #44 against a yielding child, gated < 1 ms per yield · chan-eof — a
# blocking channel read after the peer's death is EOF (0) · pause-pair / mixed-pair (ENDFIX PIPE-R1) — a #14 park,
# and a #44 park beside a #14 pauser, sleep >= 1 ms per call at -smp > 1 (no directed-kick ping-pong between unrelated
# parkers) · nb — a4 = 1 keeps -2 at once · eof-close / eof-death —
# the close wake and the death wake end a blocked read with EOF inside their gates (the 100 ms backstop alone misses
# them) · kill — a reader BLOCKED in a pipe wait (#99 state 6) is ended by SIGKILL, WAIT_BLOCK 265 < 50 ms.
# PLAIN kernel. Boots -smp 1 THEN -smp 4, BOTH GATED; the -smp 4 boot takes smoke_accel's accelerator (KVM when
# /dev/kvm is writable, else multi-threaded TCG — printed). Per boot it REQUIRES every phase's `IPCW-OK <phase>`,
# `IPCW-DONE ... fail=0`, `IPCW-EXIT 0` and `kybernet: shell exited`, and DENIES `IPCW-FAIL`, `fault: pid=`,
# `#GP`, `#PF`, `PANIC` and the shared SMOKE_INVARIANT_DENY. Every boot is banner-gated (no "AGNOS kernel v" = VOID,
# re-run by ring3_seed_boot's retry, never scored).
# Env: IPCW_KERNEL=<prebuilt kernel> (a control / mutation run), IPCW_SMP (default "1 4"), QEMU_TIMEOUT (default 180).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== ipc-wait smoke (blocking pipe / channel reads, EOF + kill wakes, the #44 directed kick) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/ipc-wait"; LOGS="$ROOT/build/ipc-wait-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/ipcw/ipcw (--agnos)..."
( cd "$ROOT/tests/ipcw" && cyrius build --agnos ipcw.cyr build/ipcw ) > "$LOGS/ipcw-build.log" 2>&1 \
    || { echo "  ERROR: ipcw build failed (see $LOGS/ipcw-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/ipcw/build/ipcw" "$SEED/bin/agnsh"

if [ -n "${IPCW_KERNEL:-}" ]; then
    KERNEL="$IPCW_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (a control run)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
ring3_seed_image "$WORK/I.img" "$KERNEL" "$SEED" "AGNOS-IPCW" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for smp in ${IPCW_SMP:-1 4}; do
    LOG="$LOGS/ipcw-smp$smp.log"
    if [ "$smp" -gt 1 ]; then R3_ACCEL="$(smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
    export R3_ACCEL
    echo ""
    echo "Boot -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/I.img" "$WORK/I-$smp.img"
    ring3_seed_boot "$WORK/I-$smp.img" "$LOG" "IPCW-EXIT 0" "${QEMU_TIMEOUT:-180}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "IPCW|kybernet: (exec|shell|emergency)" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    want "IPCW-OK pipe-pp "    "[smp$smp] pipe-pp: a blocking pipe ping-pong < 1 ms per round"
    want "IPCW-OK chan-pp "    "[smp$smp] chan-pp: a blocking channel ping-pong < 1 ms per round"
    want "IPCW-OK chan-eof "   "[smp$smp] chan-eof: a blocking channel read after the peer's death is EOF"
    want "IPCW-OK yield-peer " "[smp$smp] yield-peer: #44 against a yielding peer < 1 ms per yield (the directed kick)"
    want "IPCW-OK pause-pair " "[smp$smp] pause-pair: #14 beside an unrelated #14 pauser sleeps >= 1 ms per pause at -smp > 1 (no directed kick)"
    want "IPCW-OK mixed-pair " "[smp$smp] mixed-pair: #44 beside a #14 pauser sleeps >= 1 ms per yield at -smp > 1 (#44 kicks only #44 parkers)"
    want "IPCW-OK nb "         "[smp$smp] nb: a4 != 0 keeps -2 on a pipe and a channel"
    want "IPCW-OK eof-close "  "[smp$smp] eof-close: the last writer's close wakes a blocked reader (EOF)"
    want "IPCW-OK eof-death "  "[smp$smp] eof-death: the last writer's death wakes a blocked reader (EOF)"
    want "IPCW-OK kill "       "[smp$smp] kill: SIGKILL ends a reader blocked in a pipe wait (state 6 -> 265)"
    if strings "$LOG" | grep -qE "IPCW-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] IPCW-DONE with fail=0"; else bad "[smp$smp] IPCW-DONE with fail=0 (missing or fail > 0)"; fi
    want "IPCW-EXIT 0"                      "[smp$smp] the driver ran to its end and exits 0"
    want "kybernet: shell exited"           "[smp$smp] kybernet saw /bin/agnsh (the driver) exit"
    deny "IPCW-FAIL"                        "[smp$smp] no IPCW-FAIL line"
    deny "fault: pid=|#GP|#PF|PANIC"        "[smp$smp] no fault, #GP/#PF or PANIC line"
    deny "$SMOKE_INVARIANT_DENY"            "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
done

[ -z "${IPCW_KERNEL:-}" ] || sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo ""
echo "=== ipc-wait-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "ipc-wait-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "ipc-wait-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "ipc-wait-smoke: PASS"
exit 0
