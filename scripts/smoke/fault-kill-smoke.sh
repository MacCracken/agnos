#!/bin/bash
# fault-kill-smoke.sh (1.47.x — proc-teardown-on-fault arc). Validates that a RING-3
# (CPL3) CPU fault KILLS the faulting process and returns to the kernel/shell, instead
# of painting the 1.45.16 fault-canary bar and HALTING the box.
#
# Builds its own kernel (1.57.7 HAR): FAULT_SELFTEST=1 EXT2_WRITE_SELFTEST=1 scripts/build.sh, refuses to boot
#   anything else (smoke_require_image), and leaves a PLAIN production build/agnos behind on every exit. Until
#   1.57.7 it booted whatever build/agnos was on disk and, after a plain build, reported "FAIL: faulter never
#   dispatched (FAULT_SELFTEST build?)" — a wrong-kernel run scored as a kernel red (S7). Gated by sweep.sh since 1.57.7.
#   The FAULT_SELFTEST kernel (main.cyr fault_disk_selftest) hand-builds a minimal static
#   ELF64 whose entry reads an unmapped 5 GB address (movabs rdi,0x140000000; mov rax,[rdi])
#   → a ring-3 #PF, writes it to /bin/faulter, and `run`s it via exec_and_wait.
#
# PASS (exit 0): the box SURVIVES — both markers appear:
#   run: exit 142                      (128 + 14 = the #PF kill code; kernel_resume carried it)
#   fault: SURVIVED back in kernel     (exec_and_wait resumed after the ring-3 fault)
# FAIL (exit 1): no SURVIVED marker — the box halted on the ring-3 fault (canary path).
# VOID (exit 2, 1.57.6 S3-fix): the firmware never handed off in QEMU_TRIES attempts (qemu_dwell_kernel's
#   banner-gated retry). Until S3-fix this smoke booted ONCE through the bare qemu_dwell, so the ~1-in-4 OVMF
#   hand-off failure printed "FAIL: faulter never dispatched" — the S3-finish matrix scored exactly that as a
#   kernel red before a re-run passed.
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # qemu_dwell_kernel, qemu_assert_booted, smoke_require_image
echo "Building FAULT_SELFTEST + EXT2_WRITE_SELFTEST kernel..."
if ! env FAULT_SELFTEST=1 EXT2_WRITE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/fault-kill-smoke-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/fault-kill-smoke-build.log)"; tail -5 /tmp/fault-kill-smoke-build.log
    sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || true
    exit 1
fi
# Leave a PLAIN production build behind on every exit from here on (the disk image below carries the flag kernel).
fault_restore_plain() { sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || echo "  WARN: could not restore the plain build (sh scripts/build.sh)"; }
trap fault_restore_plain EXIT
smoke_require_image "$AGNOS" "FAULT_SELFTEST EXT2_WRITE_SELFTEST"

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

LOG="$WORK/fault.log"
echo "Booting FAULT_SELFTEST kernel (ring-3 #PF → expect kill + survive)..."
QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp|Please select boot device}"
export QEMU_DWELL_VOID
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-40}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FAULT" \
    -serial stdio -display none -no-reboot

qemu_assert_booted "$LOG" || { echo "fault-kill-smoke: VOID"; exit 2; }
echo ""
echo "  --- fault / run lines ---"
strings "$LOG" | grep -E "^(\[[^]]*\] )?fault:|^run:" | sed 's/^/  /'
echo "  -------------------------"
rc=0
strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}fault: running /bin/faulter" || { echo "  FAIL: faulter never dispatched (FAULT_SELFTEST build?)"; exit 1; }
if strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}run: exit 142"; then
    echo "  PASS: ring-3 #PF killed the proc with exit 142 (128+vector 14)"
else
    echo "  FAIL: no 'run: exit 142' — fault kill-code not attributed"; rc=1
fi
if strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}fault: SURVIVED back in kernel"; then
    echo "  PASS: box SURVIVED — exec_and_wait resumed after a ring-3 fault (no canary halt)"
else
    echo "  FAIL: no SURVIVED marker — the box halted on the ring-3 fault"; rc=1
fi
[ $rc -eq 0 ] && echo "fault-kill-smoke: PASS" || echo "fault-kill-smoke: FAIL"
exit $rc
