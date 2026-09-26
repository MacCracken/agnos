#!/bin/bash
# ahci-late-smoke.sh — AHCI timed-out-command fault injection (AHCI_SELFTEST=1), 1.57.9.
# Issue: docs/development/issues/2026-09-25-ahci-timeout-abandons-an-in-flight-command.md
#
# ahci_late_selftest (core/ahci.cyr) forces a TIMED-OUT command — a READ polled with a ZERO budget, so the poll gives
# up before looking while the command is still running — and then checks, on a fresh 16 MB SATA scratch disk (the arms
# WRITE sectors at capacity/2):
#   "ahcist: stamp PASS"  8 LBAs stamped with a per-LBA, per-word pattern (setup).
#   "ahcist: reuse PASS"  8x a late read into page B, then at once the caller stamps B: 50 ms later B still holds the
#                         stamp, and a normal read of the LBA into B is exact. RED on the pre-1.57.9 abandon (the late
#                         DMA lands on the caller's stamp).
#   "ahcist: shift PASS"  after a late read, 16 reads of known LBAs byte-exact and a FLUSH succeed (slot 0 / CT reuse).
#   "ahcist: tfes PASS"   a read past capacity fails with a PxIS error, and the next read succeeds exact with the port
#                         idle. RED on the pre-1.57.9 poll (stale PxTFD.ERR failed the next command).
#   "ahcist: lost PASS"   an engine that will not stop: COMRESET, GHC.HR, every port offline, the next I/O fails at
#                         once and B is not written after the return.
# plus "ahci: port N timeout - recovered" (the §6.2.2.1 recovery ran) and no "hba-reset-stuck" line.
#
# ⛔ The SATA disk is THROTTLED (QEMU block throttling, ${AHCI_IOPS:-100} IOPS => ~10 ms per command) and the
# selftest fills the throttle bucket before each injection, so the injected read is still running when the poll gives
# up. Unthrottled, QEMU can finish the read before the caller stamps B and the reuse arm cannot tell the fix from the
# abandon (the 1.57.8 nvme-late lesson). The boot ESP is on an unthrottled NVMe disk (the recipe that hands off).
#
# Banner-gated retry (qemu_dwell_kernel; exit 2 on a firmware VOID), PASS/FAIL per check, the shared latched-invariant
# deny ($SMOKE_INVARIANT_DENY), two boots: -smp 1 (TCG) and a GATED -smp 4 (smoke_accel). AHCI_SMP overrides ("1 4").
# Gated by scripts/sweep.sh (AHCI_SELFTEST=1). Requires: a kernel built with AHCI_SELFTEST=1, qemu, OVMF, mtools,
# parted, gnoboot.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"     # qemu_dwell_kernel, qemu_assert_booted, smoke_accel, SMOKE_INVARIANT_DENY
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found — this gate measured NOTHING" >&2
    exit 1
fi
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="${SMOKE_KERNEL:-$ROOT/build/agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
[ -n "${SMOKE_KERNEL:-}" ] || smoke_require_image "$AGNOS" "AHCI_SELFTEST"

WORK="$ROOT/build/ahci-late-smoke"
LOGS="$ROOT/build/ahci-late-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"

echo "=== AGNOS AHCI timed-out-command smoke ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
AHCI_IOPS="${AHCI_IOPS:-100}"
pass=0
fail=0
void=0
check() {
    if grep -qa "$1" "$LOG"; then echo "PASS: [$SMP] $2"; pass=$((pass + 1));
    else echo "FAIL: [$SMP] '$1' not found — $3"; fail=$((fail + 1)); fi
}
deny() {
    if grep -qaE "$1" "$LOG"; then echo "FAIL: [$SMP] $2"; grep -aE "$1" "$LOG" | head -3 | sed 's/^/        /'; fail=$((fail + 1));
    else echo "PASS: [$SMP] $3"; pass=$((pass + 1)); fi
}
for SMP in ${AHCI_SMP:-1 4}; do
    # FRESH disks per boot. ⛔⛔ 1.56.51 — the ESP recipe that hands off: a 128 MB disk, ESP at 1-33 MiB, on NVMe (see
    # edge-abi-smoke.sh). The SATA disk is a blank 16 MB scratch the selftest writes at capacity/2.
    dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
    parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
    mformat -i "$ESP"@@1048576 -F
    mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
    dd if=/dev/zero of="$WORK/sata.img" bs=1M count=16 status=none
    LOG="$LOGS/ahci-late-smp$SMP.log"
    ACCEL="$(smoke_accel "$SMP")"
    echo ""
    echo "--- boot: -smp $SMP  accel: $ACCEL ---"
    qemu_dwell_kernel "$LOG" "ahcist: done" "${QEMU_TIMEOUT:-150}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "nvme,drive=esp0,serial=AGNOS-AHST" \
        -drive "file=$WORK/sata.img,format=raw,if=none,id=sd0,throttling.iops-total=$AHCI_IOPS" \
        -device "ich9-ahci,id=ahci0" \
        -device "ide-hd,drive=sd0,bus=ahci0.0" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    echo "--- serial log (ahci/ahcist lines) ---"
    grep -aE "ahcist:|ahci: port [0-9]+ (timeout|error|not-idle|completed-late|comreset|hba-reset)" "$LOG" | head -30 || echo "(no ahcist lines captured)"
    echo "--------------------------------------"
    check "ahcist: stamp PASS"   "8 LBAs stamped (setup)"                                                        "a stamp write failed"
    check "ahcist: reuse PASS"   "a timed-out read's buffer is not written after the issue path returns"         "late DMA landed in the caller's reused buffer"
    check "ahcist: shift PASS"   "after a timed-out read, 16 reads exact + FLUSH: slot 0 / CT reused cleanly"   "slot 0 / CT reuse after a timeout"
    check "ahcist: tfes PASS"    "a PxIS error recovers the port; the next read is exact with the port idle"    "an error wedged the port / stale PxTFD.ERR"
    check "ahcist: lost PASS"    "an engine that will not stop: GHC.HR, ports offline, next I/O fails fast"     "lost-command escalation"
    check "timeout - recovered"  "the §6.2.2.1 recovery ran on a timed-out command"                              "no recovery line"
    check "ahcist: done"         "the selftest ran to its last line"                                             "the selftest did not finish"
    deny "ahcist: [a-z]+ FAIL|ahcist: SKIP|ahcist: inject FAIL" "an arm printed FAIL or SKIP" "no arm printed FAIL or SKIP"
    deny "hba-reset-stuck"       "GHC.HR did not clear" "no stuck HBA reset"
    deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant"
done

echo ""
echo "=== ahci-late-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
