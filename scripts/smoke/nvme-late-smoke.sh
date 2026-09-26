#!/bin/bash
# nvme-late-smoke.sh — NVMe late-completion fault injection (NVME_SELFTEST=1), 1.57.8.
# Issue: docs/development/issues/archived/2026-09-25-nvme-poll-timeout-leaves-the-cq-one-behind.md
#
# nvme_late_selftest (core/nvme.cyr) forces a LATE completion — a read polled with a ZERO budget, so the poll gives
# up before looking — and then checks, on a fresh scratch NVMe disk (the arms WRITE LBAs at nsze/2):
#   "nvmest: stamp PASS"  8 LBAs stamped with a per-LBA, per-word pattern (setup).
#   "nvmest: shift PASS"  after the late read, 16 reads of known LBAs return exactly their pattern and no CQ entry is
#                         left over 50 ms after the last one. RED on the pre-1.57.8 poll (a CID mismatch returned the
#                         STALE entry's status): wrong data, "CID mismatch" lines, the CQ one entry behind.
#   "nvmest: reuse PASS"  8x a late read into the bounce scratch, then at once a write of a different pattern through
#                         the SAME scratch: the read-back is the written pattern (the late one is reaped before the copy).
#   "nvmest: admin PASS"  (1.57.9) two admin IDENTIFYs polled out of order: the stray is discarded by CID (one
#                         "nvme: admin stray CID" line) and no admin CQE is left over. RED on the pre-1.57.9 admin poll.
#   "nvmest: lost PASS"   a completion that never comes: the next I/O fails, CSTS.RDY=0, nvme_io_ready=0.
# plus "nvme: late completion reaped" (settle consumed the late CID by its own CID) and no stray/mismatch line.
#
# Banner-gated retry (qemu_dwell_kernel; exit 2 on a firmware VOID), PASS/FAIL per check, the shared latched-invariant
# deny ($SMOKE_INVARIANT_DENY), two boots: -smp 1 (TCG) and a GATED -smp 4 (smoke_accel). NVME_SMP overrides ("1 4").
# Gated by scripts/sweep.sh (NVME_SELFTEST=1). Requires: a kernel built with NVME_SELFTEST=1, qemu, OVMF, mtools,
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
[ -n "${SMOKE_KERNEL:-}" ] || smoke_require_image "$AGNOS" "NVME_SELFTEST"

WORK="$ROOT/build/nvme-late-smoke"
LOGS="$ROOT/build/nvme-late-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"

echo "=== AGNOS NVMe late-completion smoke ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
NVME_IOPS="${NVME_IOPS:-100}"
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
for SMP in ${NVME_SMP:-1 4}; do
    # A FRESH disk per boot: the selftest writes LBAs at nsze/2 (the unpartitioned half of a 128 MB disk).
    # ⛔⛔ 1.56.51 — the ESP recipe that hands off: a 128 MB disk, ESP at 1-33 MiB, on NVMe (see edge-abi-smoke.sh).
    dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
    parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
    mformat -i "$ESP"@@1048576 -F
    mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
    # ⛔ THE DISK IS THROTTLED (QEMU block throttling, ${NVME_IOPS} IOPS => ~10 ms per command), ON PURPOSE. It makes
    # the device SLOW, which is the failure being modelled (1.57.7 S8: a loaded host), and it is what makes the reuse
    # arm discriminate: unthrottled, QEMU finishes the late read's DMA while the kernel is still printing the timeout
    # line, so the pre-copy settle can be deleted and the arm still passes (measured 1.57.8, TCG -smp 1). At ~10 ms
    # the late DMA lands after the bounce copy unless settle reaps it first.
    LOG="$LOGS/nvme-late-smp$SMP.log"
    ACCEL="$(smoke_accel "$SMP")"
    echo ""
    echo "--- boot: -smp $SMP  accel: $ACCEL ---"
    qemu_dwell_kernel "$LOG" "nvmest: done" "${QEMU_TIMEOUT:-120}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0,throttling.iops-total=$NVME_IOPS" \
        -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    echo "--- serial log (nvme/nvmest lines) ---"
    grep -aE "nvmest:|nvme: (late|I/O|admin|controller disabled)|CID mismatch" "$LOG" | head -30 || echo "(no nvmest lines captured)"
    echo "--------------------------------------"
    check "nvmest: stamp PASS"            "8 LBAs stamped (setup)"                                               "a stamp write failed"
    check "nvmest: shift PASS"            "a late completion does not shift the CQ: 16 reads exact, no leftover" "CID shift (stale status / wrong data / CQ one behind)"
    check "nvmest: reuse PASS"            "a late read's buffer is not reused before its completion is reaped"   "late DMA landed in reused scratch"
    check "nvmest: admin PASS"            "admin CQ consumed by CID: the stray discarded, nothing left over"     "admin CID shift (pre-1.57.9 poll returned the first CQE)"
    check "nvmest: lost PASS"             "a lost completion disables the controller; the I/O fails"             "lost completion handling"
    check "nvme: late completion reaped"  "settle consumed the late CID by its own CID"                          "late CID never reaped"
    check "nvmest: done"                  "the selftest ran to its last line"                                    "the selftest did not finish"
    deny "nvmest: [a-z]+ FAIL|nvmest: SKIP" "an arm printed FAIL or SKIP" "no arm printed FAIL or SKIP"
    # 1.57.9: the admin arm submits two IDENTIFYs and polls the second first, so ONE "nvme: admin stray CID" line is
    # expected (the discard is the behaviour under test). An I/O stray or a CID mismatch is still a failure.
    check "nvme: admin stray CID"         "the admin poll discarded the out-of-order CQE by CID"                  "admin stray never seen"
    deny "CID mismatch|I/O stray CID"     "a completion was matched to the wrong command" "no CID mismatch / I/O stray CID"
    deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant"
done

echo ""
echo "=== nvme-late-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
