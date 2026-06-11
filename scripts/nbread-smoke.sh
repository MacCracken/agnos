#!/bin/bash
# nbread-smoke (1.44.x — schedulable agnsh, sub-bite 2) — boots agnos under qemu + OVMF +
# gnoboot with NBREAD_SELFTEST=1 and asserts the NON-BLOCKING cooked-line read (kbd_read_nonblock,
# the kernel half schedulable agnsh polls). The selftest injects scancodes straight into kb_buf
# (no real keyboard) and checks:
#   "nbread: no-input WOULD_BLOCK OK" — an empty ring returns -2 (WOULD_BLOCK), NOT 0 (EOF).
#   "nbread: partial accumulate OK"  — 'h''i' with no Enter still returns -2 + accumulates 2 bytes.
#   "nbread: enter line OK"          — Enter flushes the 3-byte line "hi\n" + resets the accumulator.
#   "nbread: ALL PASS"               — all three green.
#
# Build first:  NBREAD_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — NBREAD_SELFTEST=1 ./scripts/build.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "nbread: ALL PASS"; then
    echo "ERROR: kernel was not built with NBREAD_SELFTEST=1" >&2
    echo "       rebuild: NBREAD_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/nbread-smoke"; LOGS="$ROOT/build/nbread-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS 1.44.x non-blocking cooked-line read smoke ==="
LOG="$LOGS/nbread.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial (nbread lines) ---"; strings "$LOG" | grep "nbread:" | sed 's/^/  /'
rc=0
if strings "$LOG" | grep -q "nbread: no-input WOULD_BLOCK OK"; then echo "PASS: an empty kb_buf returns -2/WOULD_BLOCK (distinct from Ctrl-D EOF=0) — the poll sentinel agnsh special-cases before its EOF check"; else echo "FAIL: 'nbread: no-input WOULD_BLOCK OK' not found — non-blocking read returned the wrong no-input value"; rc=1; fi
if strings "$LOG" | grep -q "nbread: partial accumulate OK"; then echo "PASS: 'h''i' with no Enter returns -2 + accumulates across the call (kernel partial-line accumulator persists)"; else echo "FAIL: 'nbread: partial accumulate OK' not found — partial line not buffered, or returned a complete line early"; rc=1; fi
if strings "$LOG" | grep -q "nbread: enter line OK"; then echo "PASS: Enter flushes the accumulated line 'hi\\n' (104,105,10) to the user buffer + resets the accumulator"; else echo "FAIL: 'nbread: enter line OK' not found — Enter flush / byte content / reset regression"; rc=1; fi
if strings "$LOG" | grep -q "nbread: ALL PASS"; then echo "PASS: kbd_read_nonblock end-to-end — the kernel half of schedulable agnsh"; else echo "FAIL: 'nbread: ALL PASS' not found"; rc=1; fi
exit $rc
