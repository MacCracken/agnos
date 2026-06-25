#!/bin/bash
# smp-smoke (1.44.18 — SMP-AP wake + park) — boots the PRODUCTION agnos under qemu + OVMF +
# gnoboot with -smp 4 and asserts:
#   "smp: cpus online: 4" — the BSP's INIT-SIPI-SIPI (real tick-timed SDM delays) woke APs
#                           1-3; each ran ap_entry (LAPIC enable, APIC-ID read, per-CPU TSS,
#                           spinlock'd count-in) and PARKED (IF=0 hlt — the single-core
#                           scheduler invariant is untouched).
#   "Activating scheduler" + "kybernet:" — boot PROCEEDS normally past the wake (the parked
#                           APs never interfere with the BSP's scheduler or shell launch).
# The default-(-smp 1) harmlessness is covered by the existing battery: every other smoke
# boots single-CPU through the same un-gated wake path (absent APs never respond; the BSP
# loses ~120 ms of bounded waits and reports "smp: cpus online: 1").
#
# Build first:  ./scripts/build.sh   (production — the wake is not selftest-gated)
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — ./scripts/build.sh"; exit 1; }

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/smp-smoke"; LOGS="$ROOT/build/smp-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS 1.44.18 SMP-AP wake+park smoke (-smp 4) ==="
LOG="$LOGS/smp.log"
timeout "${QEMU_TIMEOUT:-60}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial (smp lines) ---"; strings "$LOG" | grep -iE "smp|cpus" | sed 's/^/  /'
rc=0
# 1.46.x: the AP wake is GATED off (smp_wake_enabled=0, since 1.44.25) until the sub-bite-7 flip —
# so the expected count-in is 1 (BSP only) + a "AP wake gated" line, NOT 4. Accept BOTH states:
# gated (current, MVP single-core) and un-gated (post-flip "cpus online: 4").
if strings "$LOG" | grep -q "smp: cpus online: 4"; then echo "PASS: INIT-SIPI-SIPI woke APs 1-3 (tick-timed SDM protocol) — all 4 CPUs counted in via the spinlock'd ap_entry"; elif strings "$LOG" | grep -qi "AP wake gated"; then echo "PASS: AP wake correctly GATED (smp_wake_enabled=0, MVP single-core) — un-gates at the sub-bite-7 flip; boot stays single-core"; else echo "FAIL: neither 'cpus online: 4' (un-gated wake) nor 'AP wake gated' found — the AP path is broken"; rc=1; fi
if strings "$LOG" | grep -q "Activating scheduler"; then echo "PASS: boot proceeded past the wake — parked APs (IF=0 hlt) don't disturb the BSP"; else echo "FAIL: scheduler activation never reached after the AP wake"; rc=1; fi
if strings "$LOG" | grep -q "kybernet:"; then echo "PASS: kybernet launched — full boot continuity with 4 CPUs online"; else echo "FAIL: kybernet never launched post-wake"; rc=1; fi
exit $rc
