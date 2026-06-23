#!/bin/bash
# winsize-smoke (1.46.x — winsize#60) — boots agnos with WINSIZE_SELFTEST=1 under
# qemu + OVMF + gnoboot (real GOP framebuffer) and asserts the console window-size
# syscall:
#   "winsize: ALL PASS" — fb_winsize() packs (cols<<16 | rows) and the unpacked
#   grid matches fb_putc's own cell math (cols = w/(8*s), rows = (h-Y0)/(16*s))
#   against the LIVE framebuffer geometry. The "winsize: cols=N rows=M" line is
#   printed too so the grid can be eyeballed against the booted resolution.
#
# Build first:  WINSIZE_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — WINSIZE_SELFTEST=1 ./scripts/build.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "winsize: ALL PASS"; then
    echo "ERROR: kernel was not built with WINSIZE_SELFTEST=1" >&2
    echo "       rebuild: WINSIZE_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/winsize-smoke"; LOGS="$ROOT/build/winsize-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS winsize#60 console-grid smoke ==="
LOG="$LOGS/winsize.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial (winsize lines) ---"; strings "$LOG" | grep "winsize:" | sed 's/^/  /'
rc=0
if strings "$LOG" | grep -q "winsize: ALL PASS"; then echo "PASS: winsize#60 — packed (cols<<16|rows) matches fb_putc cell math on the live FB"; else echo "FAIL: 'winsize: ALL PASS' not found (see winsize lines above)"; rc=1; fi
exit $rc
