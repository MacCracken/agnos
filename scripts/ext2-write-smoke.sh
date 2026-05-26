#!/bin/bash
# ext2 WRITE-path W1 smoke (1.33.x WRITE arc).
#
# Boots the EXT2_WRITE_SELFTEST kernel against a deliberately write-
# friendly ext2 partition (no metadata_csum / 64bit / dir_index — the
# profile the 1.33.x write path targets per the prior-art doc § 8/§10),
# and gates on TWO things:
#
#   1. The self-test's identity write-back checks pass on the serial log:
#        ext2w: block id write-back OK
#        ext2w: inode id put OK
#      (read a metadata block + inode 2, write each back UNCHANGED, re-read,
#       byte-compare — exercises ext2_write_block + ext2_put_inode).
#   2. `e2fsck -fn` on the POST-BOOT image is clean (exit 0, no FIXED) —
#      proving the write primitives didn't corrupt the FS.
#
# Bonus: cross-checks the self-test's reported superblock free-block count
# against `debugfs -R stats` on the pristine image.
#
# Build the kernel first:  EXT2_WRITE_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2,
#           debugfs, e2fsck, dd, strings. gnoboot at ../gnoboot/build/.
#
# Exit 0 if the W1 gate passes; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/ext2-write-smoke"
LOGS="$ROOT/build/ext2-write-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-write.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 67 * 1048576 ))             # 67 MiB ext2 partition
PART_BLOCKS=$(( PART_BYTES / 4096 ))

echo "Building write-friendly ext2 image (no metadata_csum/64bit/dir_index)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "agnos write arc W1 seed" > "$SEED/hello.txt"
mkdir -p "$SEED/etc"; echo "archaemenid" > "$SEED/etc/hostname"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null         # Linux-FS GUID 0FC63DAF-…
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-WTEST -b 4096 -m 0 \
    -O ^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

# --- pristine baseline (debugfs stats on the partition slice) ---
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-pre.img" status=none
BASE_FREE=$(debugfs -R stats "$WORK/part-pre.img" 2>/dev/null | grep -m1 "Free blocks:" | grep -oE "[0-9]+")
echo "  host debugfs baseline: Free blocks = ${BASE_FREE:-?}"

# --- boot the self-test kernel ---
echo "Booting EXT2_WRITE_SELFTEST kernel (NVMe + GPT partition)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/write-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-WTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- ext2w self-test lines from boot log ---"
strings "$LOG" | grep -E "^ext2w:" | sed 's/^/  /'
echo ""

rc=0

# Gate 1: identity write-back checks passed.
if strings "$LOG" | grep -q "ext2w: block id write-back OK"; then
    echo "  PASS: block identity write-back (ext2_write_block)"
else
    echo "  FAIL: block identity write-back"; rc=1
fi
if strings "$LOG" | grep -q "ext2w: inode id put OK"; then
    echo "  PASS: inode identity put (ext2_put_inode)"
else
    echo "  FAIL: inode identity put"; rc=1
fi

# Bonus: free-block count cross-check (self-test sb total vs host debugfs).
ST_FREE=$(strings "$LOG" | sed -nE 's/.*sb free_blk=([0-9]+).*/\1/p' | head -1)
if [ -n "$ST_FREE" ] && [ -n "${BASE_FREE:-}" ] && [ "$ST_FREE" = "$BASE_FREE" ]; then
    echo "  PASS: free-block count matches host ($ST_FREE)"
else
    echo "  WARN: free-block count self-test=$ST_FREE host=${BASE_FREE:-?} (compare manually)"
fi

# Gate 2: post-boot e2fsck clean (the identity writes must not corrupt).
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
echo ""
echo "  --- e2fsck -fn on POST-BOOT partition ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (exit 0)"
else
    echo "  FAIL: e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

echo ""
echo "=========================================="
[ $rc -eq 0 ] && echo "ext2 WRITE W1 smoke: PASS" || echo "ext2 WRITE W1 smoke: FAIL"
echo "Logs: $LOGS"
echo "=========================================="
exit $rc
