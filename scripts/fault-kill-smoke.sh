#!/bin/bash
# fault-kill-smoke.sh (1.47.x — proc-teardown-on-fault arc). Validates that a RING-3
# (CPL3) CPU fault KILLS the faulting process and returns to the kernel/shell, instead
# of painting the 1.45.16 fault-canary bar and HALTING the box.
#
# Build first:  FAULT_SELFTEST=1 EXT2_WRITE_SELFTEST=1 ./scripts/build.sh
#   The FAULT_SELFTEST kernel (main.cyr fault_disk_selftest) hand-builds a minimal static
#   ELF64 whose entry reads an unmapped 5 GB address (movabs rdi,0x140000000; mov rax,[rdi])
#   → a ring-3 #PF, writes it to /bin/faulter, and `run`s it via exec_and_wait.
#
# PASS (exit 0): the box SURVIVES — both markers appear:
#   run: exit 142                      (128 + 14 = the #PF kill code; kernel_resume carried it)
#   fault: SURVIVED back in kernel     (exec_and_wait resumed after the ring-3 fault)
# FAIL (exit 1): no SURVIVED marker — the box halted on the ring-3 fault (canary path).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run FAULT_SELFTEST=1 EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/fault-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-fault.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BLOCKS=$(( (67 * 1048576) / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
SEED="$WORK/seed"; mkdir -p "$SEED"; echo "fault seed" > "$SEED/hello.txt"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-FAULT -b 4096 -m 0 -O "$EXT2_SMOKE_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$WORK/fault.log"
echo "Booting FAULT_SELFTEST kernel (ring-3 #PF → expect kill + survive)..."
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FAULT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- fault / run lines ---"
strings "$LOG" | grep -E "^fault:|^run:" | sed 's/^/  /'
echo "  -------------------------"
rc=0
strings "$LOG" | grep -q "^fault: running /bin/faulter" || { echo "  FAIL: faulter never dispatched (FAULT_SELFTEST build?)"; exit 1; }
if strings "$LOG" | grep -q "^run: exit 142"; then
    echo "  PASS: ring-3 #PF killed the proc with exit 142 (128+vector 14)"
else
    echo "  FAIL: no 'run: exit 142' — fault kill-code not attributed"; rc=1
fi
if strings "$LOG" | grep -q "^fault: SURVIVED back in kernel"; then
    echo "  PASS: box SURVIVED — exec_and_wait resumed after a ring-3 fault (no canary halt)"
else
    echo "  FAIL: no SURVIVED marker — the box halted on the ring-3 fault"; rc=1
fi
[ $rc -eq 0 ] && echo "fault-kill-smoke: PASS" || echo "fault-kill-smoke: FAIL"
exit $rc
