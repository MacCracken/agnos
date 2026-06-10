#!/bin/bash
# ring3-smoke (1.44.4 one proc / .5 two procs / .6 syscalls / .7 concurrent exec+exit) —
# boots agnos under qemu + OVMF + gnoboot with RING3_SELFTEST=1 and asserts:
#   "ring3: child exited"— proc B (1.44.8: a real in-memory ELF64 loaded by elf_load, the
#                          spawn-#3 loader; own CR3, IF=1) runs a FINITE program (count to
#                          N then `exit` #0) to completion and is cleanly retired (state=0,
#                          NOT resurrected), WHILE proc A (a second ring-3 proc making
#                          getpid syscalls) keeps running. The "a program runs to completion
#                          while another stays live" core, from an actual ELF binary.
#   "ring3: preempt OK" — proc A stayed live + preemptible through B's exit (counter > 0).
#   "ring3: gate held"  — under preempt_disable() proc A's counter FREEZES => the
#                          1.44.0 preempt gate covers ring-3 too.
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
if strings "$LOG" | grep -q "ring3: child exited"; then echo "PASS: a scheduled ring-3 proc (real ELF via elf_load) ran to completion + exit()ed cleanly while another stayed live"; else echo "FAIL: 'ring3: child exited' not found — concurrent exec / exit() regression"; rc=1; fi
if strings "$LOG" | grep -q "ring3: preempt OK"; then echo "PASS: the surviving ring-3 proc stayed live + preemptible through the child's exit"; else echo "FAIL: 'ring3: preempt OK' not found — the live proc never advanced (or triple-faulted)"; rc=1; fi
if strings "$LOG" | grep -q "ring3: gate held"; then echo "PASS: the preempt gate freezes ring-3 procs too"; else echo "FAIL: 'ring3: gate held' not found — preempt gate regression for ring-3"; rc=1; fi
if strings "$LOG" | grep -q "ring3: parent spawn+wait OK"; then echo "PASS: a ring-3 PARENT spawn(#3)ed a child ELF + poll-waitpid(#4)ed it to exit — entirely from ring 3 (spawn#3 kernel-CR3 fix end-to-end)"; else echo "FAIL: 'ring3: parent spawn+wait OK' not found — ring-3 spawn+waitpid regression (child #UD / mis-wired tables under parent CR3)"; rc=1; fi
exit $rc
