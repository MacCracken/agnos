#!/bin/bash
# kstack-smoke (1.57.6, Path 2 step S3.3) — per-process kernel stacks, the deferred on_cpu release, CPL0
# preemption windows, preempt-disabling spinlocks, the sched_next fallback and the region-7 guard pages.
#
# Builds a KSTACK_SELFTEST kernel (kernel/core/main.cyr + sched.cyr KSTACK blocks) and boots it -smp 1 THEN
# -smp 4, BOTH GATED. The multi-CPU boot takes smoke_accel's accelerator (KVM `-cpu host` when /dev/kvm is
# writable, else multi-threaded TCG) and the log says which: the migration check and the M-A1/M-A3 races
# need vCPUs that really run in parallel.
# Every verdict is a named line; exit 0 only when every check of every boot passed:
#   kstack: guard pages OK (32/32)   dm_pd[7] is a 4 KB table with every region-7 slot bottom not present
#   kstack: frame OK                 4 probes, distinct RSP/sentinels/XMM, >= 20 clean probe syscalls each
#   kstack: cpl0 switch OK           >= 10 probe syscalls switched out MID-FLIGHT (a CS 0x08 frame)
#   kstack: migration OK             -smp 4: a window ended on another CPU  (-smp 1: "migration n/a (1 cpu)")
#   kstack: fence OK                 -smp 4 (S3-fix): a LIVE probe's departing CPU is HELD in its switch tail while the
#                                    other CPUs tick; they must find it READY-but-fenced (contested >= 1) and never
#                                    switch it in (overlap == 0), and the holder's canary survives (smashed == 0).
#                                    Coverage floor held >= 4. (-smp 1: "fence n/a (1 cpu)")
#   kstack: hw=0x... every probe under 32 KB   (paint high water, a lower bound)
#   kstack: lock-holder OK           kmain holds console_lock at IF=1 while W writes: both progress
#   kstack: storm OK                 retire-while-running + immediate respawn x24 (slot reuse vs the tail);
#                                    at -smp > 1 the departing CPU is HELD in its switch tail across each
#                                    spawn and must come out with its slot's epoch unchanged: held > 0, cmp >= held
#                                    (every held CPU came back), underfoot == 0; held < 4 is a coverage VOID
#   kstack: fallback OK              the nothing-ready fallback answers the idle, never kmain's stale slot
#   kstack: isr cannot block OK      every timer ISR body ran with preempt_count > 0
#   kstack: accel=... / kstack: done
# Denied anywhere: `kstack: FAIL`, `fault:`, `PANIC`, `#GP`, `#PF`, `Double Fault`, `sched: refused non-ready
# pick`, and sched_assert_oob's latched lines (`sched: exec_and_wait entered with ...`, `sched: kernel_resume with ...`),
# and (S3-fix) `syscall: kernel stack is not the caller's` (kstack_check_entry). A boot that never prints `kstack: done` within the dwell is RED (a hang is how a lock-holder
# deadlock or a lost wakeup shows), never "flaky".
# COVERAGE VOID (S3-fix): a boot whose storm or fence phase printed `... VOID` (too few holds to be evidence) and no
# FAIL line is re-booted (KSTACK_COVER_TRIES, default 3; each attempt's log kept as kstack-smpN.cover-voidK.log);
# still VOID after that, the boot counts as void (exit 2) — never as a pass.
# Env: KSTACK_SMP (default "1 4"), QEMU_TIMEOUT (default 240), QEMU_TRIES, KSTACK_COVER_TRIES.
# Exit: 0 PASS · 1 FAIL · 2 VOID (the firmware never handed off). Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found — this gate measured NOTHING"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool' — this gate measured NOTHING"; exit 1; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/kstack-smoke"; LOGS="$ROOT/build/kstack-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

echo "=== kstack smoke (per-process kernel stacks, CPL0 windows, lock holders, fallback, guard pages) ==="
echo "Building the KSTACK_SELFTEST=1 kernel..."
KSTACK_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build.log" 2>&1 || { echo "  ERROR: kernel build failed — this gate measured NOTHING (see $LOGS/build.log)"; exit 1; }
if ! strings "$ROOT/build/agnos" | grep -q "kstack: done"; then
    echo "  ERROR: build/agnos carries no KSTACK_SELFTEST block — this gate measured NOTHING"; exit 1
fi
cp "$ROOT/build/agnos" "$WORK/agnos-kstack"
grep -E "stub|unreachable" "$LOGS/build.log" | head -3 | sed 's/^/  /'

ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$WORK/agnos-kstack" ::boot/agnos

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp|Please select boot device}"
export QEMU_DWELL_VOID
for smp in ${KSTACK_SMP:-1 4}; do
    LOG="$LOGS/kstack-smp$smp.log"
    ACCEL="$(smoke_accel "$smp")"
    echo ""
    echo "Boot -smp $smp  accel: $ACCEL"
    ctry=1
    while :; do
        qemu_dwell_kernel "$LOG" "kstack: done" "${QEMU_TIMEOUT:-240}" "$WORK/vars.fd" "$OVMF_VARS" \
            qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$smp" \
            -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
            -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
            -drive "file=$ESP,format=raw,if=none,id=esp0" -device "nvme,drive=esp0,serial=AGNOS-KSTACK" \
            -serial stdio -display none -no-reboot
        # a coverage VOID (and no FAIL anywhere) is re-booted; a FAIL line always stands
        if strings "$LOG" | grep -qE "kstack: (storm|fence) VOID" && ! strings "$LOG" | grep -qF "kstack: FAIL"; then
            if [ "$ctry" -lt "${KSTACK_COVER_TRIES:-3}" ]; then
                cp "$LOG" "$LOGS/kstack-smp$smp.cover-void$ctry.log"
                echo "  (coverage VOID, attempt $ctry: $(strings "$LOG" | grep -E 'kstack: (storm|fence) (rounds|VOID)' | tr '\n' ' ') -- re-booting)"
                ctry=$((ctry + 1)); continue
            fi
        fi
        break
    done
    if ! qemu_assert_booted "$LOG"; then void=$((void + 1)); continue; fi
    if strings "$LOG" | grep -qE "kstack: (storm|fence) VOID" && ! strings "$LOG" | grep -qF "kstack: FAIL"; then
        echo "  -smp $smp: coverage VOID in all ${KSTACK_COVER_TRIES:-3} boots -- this boot measured too little to score"
        strings "$LOG" | grep -E "kstack: (storm|fence)" | sed 's/^/    /'
        void=$((void + 1)); continue
    fi
    strings "$LOG" | grep -E "kstack:|kstack-hw:|sched: refused|sched: exec_and_wait entered|sched: kernel_resume with|syscall: stub|syscall: ibrs|syscall: kernel stack|Double Fault|smp: cpus online" | grep -v "^\.*$" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    want "syscall: stub 280 bytes of 2048"  "[smp$smp] the SYSCALL stub is the S3.3 size (258 + 8 + 9 + 9 - 4; ibrs=0)"
    want "syscall: ibrs=0"                  "[smp$smp] ibrs_supported = 0 on this host (the stub-size oracle is keyed on it)"
    want "kstack: accel="                   "[smp$smp] the accelerator is named"
    want "kstack: guard pages OK (32/32)"   "[smp$smp] region 7 has 32 not-present slot-bottom guard pages"
    want "kstack: frame OK"                 "[smp$smp] every probe's SYSRET frame, sentinels, RSP and XMM survived (>= 20 each)"
    want "kstack: cpl0 switch OK"           "[smp$smp] syscalls were switched out mid-flight (CS 0x08 frames) and resumed"
    if [ "$smp" -gt 1 ]; then
        want "kstack: migration OK"         "[smp$smp] a switched-out syscall resumed on ANOTHER CPU"
    else
        want "kstack: migration n/a (1 cpu)" "[smp$smp] single CPU: migration not applicable"
    fi
    if [ "$smp" -gt 1 ]; then
        want "kstack: fence OK"             "[smp$smp] a READY process being left was contested but never resumed until its CPU was off its stack"
    else
        want "kstack: fence n/a (1 cpu)"    "[smp$smp] single CPU: fence phase not applicable"
    fi
    want "every probe under 32 KB"          "[smp$smp] kernel-stack high water under 32 KB"
    want "kstack: lock-holder OK"           "[smp$smp] a console_lock holder at IF=1 is not preempted into a same-CPU deadlock"
    want "kstack: storm OK"                 "[smp$smp] retire-while-running + immediate respawn: no slot handed out under a departing CPU"
    want "kstack: fallback OK"              "[smp$smp] nothing-ready fallback returns the idle; the parked child resumed 5 times"
    want "kstack: isr cannot block OK"      "[smp$smp] every timer ISR body ran with preemption disabled"
    want "kstack: done"                     "[smp$smp] the selftest ran to its end (no hang)"
    deny "kstack: FAIL"                     "[smp$smp] no kstack FAIL line"
    deny "sched: refused non-ready pick"    "[smp$smp] the scheduler never picked a non-READY proc"
    deny "sched: exec_and_wait entered with|sched: kernel_resume with" "[smp$smp] the out-of-band switch asserts stayed quiet (preempt_count 0, IF=0 at exec_and_wait)"
    deny "syscall: kernel stack is not the caller" "[smp$smp] every ring-3 syscall entered on its own kernel stack (kstack_check_entry)"
    deny "fault: pid=|PANIC|#GP|#PF|Double Fault|STUB OVERFLOWED" "[smp$smp] no fault, panic or stub overflow"
done

# Leave the tree on a PLAIN production kernel (this built a flag kernel).
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo ""
echo "=== kstack-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "kstack-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "kstack-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "kstack-smoke: PASS"
exit 0
