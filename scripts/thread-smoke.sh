#!/bin/bash
# thread-smoke (1.44.0) — boots the agnos kernel under qemu + OVMF + gnoboot with
# THREAD_SELFTEST=1 and asserts the multi-threading opening bite:
#   "thr: preempt OK"  — two kernel threads created via kthread_create tight-loop
#                        bumping their own counters (they NEVER yield), and BOTH
#                        advance → the TIMER preempted + round-robined them, i.e.
#                        preemptive ring-3-class time-slicing on the shared kernel AS.
#   "thr: gate held"   — under preempt_disable() the counters FREEZE → the preempt
#                        gate (do_context_switch no-ops while preempt_count>0) holds,
#                        the "reentrant-or-gated" foundation for the cooperative→
#                        preemptive transition.
#
# Build first:  THREAD_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — THREAD_SELFTEST=1 ./scripts/build.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "thr: preempt OK"; then
    echo "ERROR: kernel was not built with THREAD_SELFTEST=1" >&2
    echo "       rebuild: THREAD_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/thread-smoke"; LOGS="$ROOT/build/thread-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS 1.44.x multi-threading opening smoke ==="
LOG="$LOGS/thread.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial (thread lines) ---"; strings "$LOG" | grep "thr:" | sed 's/^/  /'
rc=0
if strings "$LOG" | grep -q "thr: preempt OK"; then echo "PASS: preemptive kernel-thread time-slicing (kthread_create + timer preemption)"; else echo "FAIL: 'thr: preempt OK' not found — preemption/round-robin regression"; rc=1; fi
if strings "$LOG" | grep -q "thr: gate held"; then echo "PASS: preempt gate (preempt_disable freezes the scheduler)"; else echo "FAIL: 'thr: gate held' not found — preempt-gate regression"; rc=1; fi
exit $rc
