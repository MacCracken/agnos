#!/bin/sh
# wait-ring3-smoke.sh — 1.57.7 (Path 2, S3c): the in-kernel blocking waits, from ring 3.
#   sleep_ms#41 blocks ONLY its caller · waitpid#4 WAIT_BLOCK (0x100|pid, 0x1FF = any; woken by exit#0 AND by a
#   ring-3 fault kill — phase waitpid-fault) · flock#59 waits without
#   LOCK_NB (-2 = the lock table is full; a blocking conversion drops the old lock) · sched_yield#44 donates ·
#   an execwait#37 child blocks like any process (P13 `ew37`, flipped by S3b-F2 from S3c's interim contract).
#
# Issues: docs/development/issues/2026-09-23-sleep-ms-holds-the-cpu.md,
#         docs/development/issues/2026-09-23-flock-never-waits-and-no-caller-spins.md.
#
# tests/waits/waitx.cyr is seeded as /bin/agnsh (the driver — kybernet runs it IF=1 time-sliced, so its #43
# children really run concurrently) AND /bin/waitx (every child role), with /wx/mode (the phase list), /wx/lock,
# /wx/f00../wx/f16 (P5c), /wx/ctr (8 zero bytes) and /wx/ctr.lock (P7). PLAIN kernel. Boots -smp 1 THEN -smp 4,
# BOTH GATED; the -smp 4 boot takes smoke_accel's accelerator (KVM when /dev/kvm is writable, else multi-threaded
# TCG — printed). The HDA devices are on the command line from the start so later steps only add phases.
# Per boot it REQUIRES every selected phase's `WAITX-OK <name>`, `WAITX-DONE ... fail=0`, `WAITX-EXIT 0` and
# `kybernet: shell exited`, and DENIES `WAITX-FAIL`, `fault: pid=`, `#GP`, `#PF`, `PANIC`, the shared
# SMOKE_INVARIANT_DENY (qemu-dwell.sh) and a second `kybernet: exec /bin/agnsh`. Every boot is banner-gated
# (a boot with no "AGNOS kernel v" is VOID, never scored).
# Env: WAIT_KERNEL=<prebuilt kernel> (the control run: a 1.57.6 kernel), WAIT_SMP (default "1 4"), WAIT_PHASES
# (default: every phase; names or P-ids, space-separated), QEMU_TIMEOUT (default 360).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID (a boot never handed off). Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== wait-ring3 smoke (sleep_ms / waitpid WAIT_BLOCK / flock / yield / #37 child blocks) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/wait-ring3"; LOGS="$ROOT/build/wait-ring3-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/waits/waitx (--agnos)..."
( cd "$ROOT/tests/waits" && cyrius build --agnos waitx.cyr build/waitx ) > "$LOGS/waitx-build.log" 2>&1 \
    || { echo "  ERROR: waitx build failed (see $LOGS/waitx-build.log)"; exit 1; }

ALL_PHASES="sleep-basic sleep-yields share-full yield-parks yield-donates snd-yields snd-drain sleep-reap sleep-child-runs waitpid-block flock-nb flock-wait flock-full flock-convert yield stress migrate storm waitpid-fault ew37 handoff handoff-parked pinned-sleep"
PHASES="${WAIT_PHASES:-$ALL_PHASES}"
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/wx"
cp "$ROOT/tests/waits/build/waitx" "$SEED/bin/agnsh"
cp "$ROOT/tests/waits/build/waitx" "$SEED/bin/waitx"
printf '%s\n' "$PHASES" > "$SEED/wx/mode"
printf 'lock\n' > "$SEED/wx/lock"
# 1.57.7 (S3d B5): the handoff phases' files (P12/P12b) and the multi-CPU boot's accelerator (their gate is KVM < 500 us)
printf 'lock\n' > "$SEED/wx/hand.lock"
dd if=/dev/zero of="$SEED/wx/hand.seq" bs=8 count=1 status=none
dd if=/dev/zero of="$SEED/wx/hand.w" bs=1024 count=1 status=none
dd if=/dev/zero of="$SEED/wx/hand.h" bs=1024 count=1 status=none
case "$(smoke_accel 4)" in *kvm*) printf 'kvm\n' > "$SEED/wx/accel" ;; *) printf 'tcg\n' > "$SEED/wx/accel" ;; esac
printf 'lock\n' > "$SEED/wx/ctr.lock"
dd if=/dev/zero of="$SEED/wx/ctr" bs=8 count=1 status=none
i=0
while [ "$i" -le 16 ]; do printf 'f%02d\n' "$i" > "$SEED/wx/f$(printf '%02d' "$i")"; i=$((i + 1)); done

if [ -n "${WAIT_KERNEL:-}" ]; then
    KERNEL="$WAIT_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (a control run)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
ring3_seed_image "$WORK/W.img" "$KERNEL" "$SEED" "AGNOS-WAITX" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for smp in ${WAIT_SMP:-1 4}; do
    LOG="$LOGS/waitx-smp$smp.log"
    if [ "$smp" -gt 1 ]; then R3_ACCEL="$(smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
    export R3_ACCEL
    echo ""
    echo "Boot -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/W.img" "$WORK/W-$smp.img"
    ring3_seed_boot "$WORK/W-$smp.img" "$LOG" "WAITX-EXIT 0" "${QEMU_TIMEOUT:-360}" "$WORK" -smp "$smp" \
        -audiodev none,id=snd0 -device intel-hda,id=hda0 -device hda-duplex,bus=hda0.0,audiodev=snd0
    if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
    # the program's lines and the kernel lines this gate reads, for the log
    strings "$LOG" | grep -E "WAITX-|kybernet: (exec|shell|emergency)" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    for ph in $PHASES; do
        case "$ph" in
            migrate)  if [ "$smp" -gt 1 ]; then want "WAITX-OK migrate " "[smp$smp] migrate: a blocked wait resumed on another CPU (klug witness)"
                      else want "WAITX-OK migrate n/a (1 cpu)" "[smp$smp] migrate: n/a at one CPU"; fi ;;
            ew37)     want "WAITX-OK ew37 block" "[smp$smp] ew37 (flipped by S3b-F2): a #37 child's sleep_ms blocks (spinner share) and its flock waits" ;;
            handoff|handoff-parked)
                      if [ "$smp" -gt 1 ]; then want "WAITX-OK $ph " "[smp$smp] $ph: a flock waiter woken for another CPU runs within the latency gate (the 0xE1 kick)"
                      else want "WAITX-OK $ph n/a (1 cpu)" "[smp$smp] $ph: n/a at one CPU"; fi ;;
            pinned-sleep) want "WAITX-OK pinned-sleep " "[smp$smp] pinned-sleep (report-only: the median overshoot is printed)" ;;
            *)        want "WAITX-OK $ph " "[smp$smp] $ph" ;;
        esac
    done
    if strings "$LOG" | grep -qE "WAITX-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] WAITX-DONE with fail=0"; else bad "[smp$smp] WAITX-DONE with fail=0 (missing or fail > 0)"; fi
    want "WAITX-EXIT 0"                     "[smp$smp] the driver ran to its end and exits 0"
    want "kybernet: shell exited"           "[smp$smp] kybernet saw /bin/agnsh (the driver) exit"
    deny "WAITX-FAIL"                       "[smp$smp] no WAITX-FAIL line"
    deny "fault: pid=|#GP|#PF|PANIC"        "[smp$smp] no fault, #GP/#PF or PANIC line"
    deny "$SMOKE_INVARIANT_DENY"            "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
    nexec=$(strings "$LOG" | grep -c "kybernet: exec /bin/agnsh")
    if [ "$nexec" -le 1 ]; then ok "[smp$smp] /bin/agnsh was launched once (no emergency re-exec)"; else bad "[smp$smp] /bin/agnsh was launched $nexec times"; fi
done

# Leave the tree on a PLAIN production kernel.
[ -z "${WAIT_KERNEL:-}" ] || sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo ""
echo "=== wait-ring3-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "wait-ring3-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "wait-ring3-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "wait-ring3-smoke: PASS"
exit 0
