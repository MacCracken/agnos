#!/bin/sh
# hid-reclaim-smoke — a HID Transfer Event eaten by an xHCI synchronous waiter must be handed back.
#
# ⛔ WHY THIS EXISTS AND WHY IT IS HERMETIC. The xHCI event ring is shared by every consumer in the
# driver, but only hid_poll knows that a Transfer Event on an interrupt-IN endpoint means "one armed TRB
# was consumed, arm another". The three synchronous waiters spin on that same ring and consume anything
# that is not their TRB — so before 1.56.52 every keystroke that landed during a USB bulk transfer cost
# the keyboard one of its 16 armed TRBs, permanently. Sixteen of them and input is dead for the boot,
# with no error printed anywhere.
#
# Reproducing that for real needs a HID device AND a USB disk AND an operator typing during the
# transfer, sixteen times — which is why it survived to 1.56.52. So the selftest brings its own event
# ring, transfer ring, doorbell page and synthetic HID row, and needs no USB hardware. Four arms: a
# foreign (slot,dci) is a silent miss, our event is claimed and DEFERRED rather than armed inline, the
# service pass arms exactly one IOC-bearing Normal TRB and rings the right doorbell, and — the arm that
# proves it is WIRED IN rather than merely present — a real waiter drives the whole path.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
[ -f "$GNOBOOT" ] || { echo "SKIP: gnoboot not built"; exit 0; }
[ -f "$OVMF_CODE" ] || { echo "SKIP: OVMF not found"; exit 0; }
LOGS="$ROOT/build/hid-reclaim-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
LOG="$LOGS/hidrcl.log"

echo "=== stolen HID event reclaim smoke ==="
HID_RECLAIM_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }

# ⚠ Retry ONLY on an absent kernel banner — OVMF intermittently never hands off and such a run measures
# NOTHING. Retrying a real assertion failure would retry a regression away.
a=1
while [ "$a" -le 3 ]; do
    W=$(mktemp -d); IMG="$W/d.img"
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
    mformat -i "$IMG"@@1048576 -F
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$IMG"@@1048576 "$ROOT/build/agnos" ::boot/agnos
    cp "$OVMF_VARS" "$W/vars.fd"; chmod +w "$W/vars.fd"
    # ⭐ qemu-xhci + usb-kbd on purpose. The selftest does not need them — it is hermetic — but a real
    # controller and a real registered HID row mean the swapped-globals teardown is exercised against a
    # NON-EMPTY registry, which is the only configuration where a botched restore could do damage.
    timeout "${QEMU_TIMEOUT:-45}" qemu-system-x86_64 -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" -device "nvme,drive=d0,serial=AGNOS-HIDRCL" \
        -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
        -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' > "$LOG"
    rm -rf "$W"
    grep -q 'AGNOS kernel v' "$LOG" && break
    echo "  (firmware never handed off — retry $a/3)"
    a=$((a+1))
done
if ! grep -q 'AGNOS kernel v' "$LOG"; then
    echo "  UEFI never handed off in 3 attempts — INFRASTRUCTURE, not the kernel. VOID, not a failure."
    exit 1
fi

rc=0
if grep -q 'hidrcl: stolen HID events are reclaimed and re-armed OK' "$LOG"; then
    echo "  PASS: foreign event ignored; our event deferred, serviced, doorbell rung; real waiter wired"
else
    echo "  FAIL: reclaim gate did not report OK — named arms above:"
    grep 'hidrcl:' "$LOG" || echo "        (no hidrcl: line at all — the selftest never ran)"
    rc=1
fi
# ⚠ The keyboard must still work after a test that swapped xhci_mmio_base out from under it.
if ! grep -q 'hid: keyboard configured' "$LOG"; then
    echo "  FAIL: no keyboard enumerated after the globals swap — teardown did not restore cleanly"
    rc=1
fi
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1   # leave a plain production build behind
[ "$rc" = "0" ] && echo "hid-reclaim-smoke: PASS" || echo "hid-reclaim-smoke: FAIL"
exit $rc
