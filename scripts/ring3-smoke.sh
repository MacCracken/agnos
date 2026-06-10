#!/bin/bash
# ring3-smoke (1.44.4 one proc / 1.44.5 two procs) — boots agnos under qemu + OVMF +
# gnoboot with RING3_SELFTEST=1 and asserts preemptive ring-3 time-slicing:
#   "ring3: preempt OK" — TWO ring-3 procs, each its OWN per-process CR3 + IF=1, each
#                         running a loop that makes a getpid SYSCALL (1.44.6) then
#                         increments user VA 0x2000000. BOTH counters advance while kmain
#                         hlt-waits => the scheduler round-robins ring-3 <-> ring-3 across
#                         two DIFFERENT CR3s (iretq into ring 3, CS=0x23), the same VA maps
#                         to distinct per-proc memory (AS isolation), AND a preemptible
#                         ring-3 proc syscalls safely (handler IF=0, shared kstack serial).
#   "ring3: gate held"  — under preempt_disable() BOTH counters FREEZE => the
#                         1.44.0 preempt gate covers ring-3 too.
#
# Build first:  RING3_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — RING3_SELFTEST=1 ./scripts/build.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "ring3: preempt OK"; then
    echo "ERROR: kernel was not built with RING3_SELFTEST=1" >&2
    echo "       rebuild: RING3_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/ring3-smoke"; LOGS="$ROOT/build/ring3-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS 1.44.x preemptive ring-3 smoke ==="
LOG="$LOGS/ring3.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial (ring3 lines) ---"; strings "$LOG" | grep "ring3:" | sed 's/^/  /'
rc=0
if strings "$LOG" | grep -q "ring3: preempt OK"; then echo "PASS: two ring-3 procs (distinct CR3s) time-sliced ring-3<->ring-3 while making syscalls"; else echo "FAIL: 'ring3: preempt OK' not found — a ring-3 proc never advanced (or triple-faulted)"; rc=1; fi
if strings "$LOG" | grep -q "ring3: gate held"; then echo "PASS: the preempt gate freezes ring-3 procs too"; else echo "FAIL: 'ring3: gate held' not found — preempt gate regression for ring-3"; rc=1; fi
exit $rc
