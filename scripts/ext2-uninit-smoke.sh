#!/bin/bash
# ext2/ext4 uninit-group materialization smoke (1.33.4 bite 3).
#
# The fast ext2-write-smoke runs on a 67 MiB partition = a SINGLE block group
# (group 0, always initialized), so it never exercises INODE_UNINIT /
# BLOCK_UNINIT groups. The real iron agnos-fs partition (25 GiB, default
# mkfs.ext4 + flex_bg) has many. This smoke builds a ~1.1 GiB flex_bg image —
# journal-free so AGNOS mounts it write-enabled — which carries both flag
# kinds, and gates on:
#
#   1. ext2w: Wuninit materialize OK   (the self-test forced a goal-directed
#      block alloc into a BLOCK_UNINIT group → materialize + alloc + flag
#      cleared, and materialized an INODE_UNINIT group's bitmap)
#   2. e2fsck -fn clean on the POST-BOOT partition (the materialized bitmaps +
#      cleared flags + recomputed metadata_csum are all consistent)
#
# Build the kernel first:  EXT2_WRITE_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext4,
#           e2fsck, dumpe2fs, dd. gnoboot at ../gnoboot/build/.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
                       /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd \
                           /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
    [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext4 e2fsck dumpe2fs dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/ext2-uninit-smoke"; LOGS="$ROOT/build/ext2-uninit-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-uninit.img"
ESP_MIB=33
PART_MIB=1100
PART_OFFSET=$(( ESP_MIB * 1048576 ))
PART_BLOCKS=$(( PART_MIB * 1048576 / 4096 ))
DISK_MIB=$(( ESP_MIB + PART_MIB + 4 ))

echo "Building ${PART_MIB} MiB flex_bg ext4 image (default layout, journal-free)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "agnos 1.33.4 uninit materialization" > "$SEED/hello.txt"

dd if=/dev/zero of="$IMG" bs=1M count=$DISK_MIB status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB ${ESP_MIB}MiB set 1 esp on \
    mkpart agnos-fs ext2 ${ESP_MIB}MiB $(( ESP_MIB + PART_MIB ))MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
# Default mkfs.ext4 layout (flex_bg + metadata_csum + 64bit + extent) minus
# the journal/orphan_file/resize_inode/dir_index extras AGNOS doesn't write —
# this is the iron-faithful uninit-group layout that mounts write-enabled.
mkfs.ext4 -F -q -b 4096 -m 0 -L agnos-fs \
    -O '^has_journal,^orphan_file,^resize_inode,^dir_index' \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "  host dumpe2fs uninit summary:"
dd if="$IMG" bs=1M skip=$ESP_MIB count=$PART_MIB of="$WORK/part-pre.img" status=none
echo "    groups=$(dumpe2fs "$WORK/part-pre.img" 2>/dev/null | grep -c 'Group [0-9]')" \
     "INODE_UNINIT=$(dumpe2fs "$WORK/part-pre.img" 2>/dev/null | grep -c INODE_UNINIT)" \
     "BLOCK_UNINIT=$(dumpe2fs "$WORK/part-pre.img" 2>/dev/null | grep -c BLOCK_UNINIT)"

echo "Booting EXT2_WRITE_SELFTEST kernel on the uninit image..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/uninit-selftest.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-UNINIT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- Wuninit self-test line ---"
strings "$LOG" | grep -E "^ext2w: Wuninit" | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "ext2w: Wuninit materialize OK"; then
    echo "  PASS: Wuninit materialize (BLOCK_UNINIT alloc-path + INODE_UNINIT materialize)"
elif strings "$LOG" | grep -q "ext2w: Wuninit SKIP"; then
    echo "  FAIL: image had no uninit groups (expected on a >1 GiB flex_bg image)"; rc=1
else
    echo "  FAIL: Wuninit self-test absent (kernel crashed? check $LOG)"; rc=1
fi

# Gate: post-boot e2fsck clean (materialized bitmaps + cleared flags + csums).
dd if="$IMG" bs=1M skip=$ESP_MIB count=$PART_MIB of="$WORK/part-post.img" status=none
echo ""
echo "  --- e2fsck -fn on POST-BOOT partition ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (exit 0)"
else
    echo "  FAIL: e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

echo ""
echo "=========================================="
[ $rc -eq 0 ] && echo "ext2 uninit-materialization smoke: PASS" || echo "ext2 uninit-materialization smoke: FAIL"
echo "Logs: $LOGS"
echo "=========================================="
exit $rc
