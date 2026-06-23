#!/bin/bash
# ext2 MULTI-CHUNK BGDT smoke (1.45.15) — the regression gate for the Phase-1
# single-BGDT-chunk lift. The existing ext2 smokes all use <64-group images
# (one BGDT block), so NONE of them exercise the new code. This builds a
# genuine multi-chunk image — ngroups > blocksize/desc_size (small per-group
# sizing via `-g`), default `mkfs.ext4` profile (metadata_csum + 64bit + extent,
# desc_size=64 → 64 groups per BGDT block) matching the real 25 GiB agnos-fs —
# and boots the MULTICHUNK_SELFTEST kernel, which:
#   READ     — ext2_get_inode for an inode whose block_group is in chunk >= 1
#              (the exact iron failure: /bin/yo, /bin/whirl placed in high groups)
#   NEGATIVE — an inode past s_inodes_count is rejected
#   WRITE    — goal-directed ext2_alloc_block lands in a high (chunk >= 1) group,
#              then frees it (allocator chunk-load + write_bgdt + recsum on a high chunk)
# Then `e2fsck -fn` on the post-boot image must be clean.
#
# Build first:  MULTICHUNK_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext4,
#           dumpe2fs, e2fsck, dd, strings. gnoboot at ../gnoboot/build/.
#
# Exit 0 if every mc: gate + e2fsck pass; 1 otherwise; 2 if the selftest is absent.

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

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext4 dumpe2fs e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run MULTICHUNK_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/ext2-multichunk-smoke"
LOGS="$ROOT/build/ext2-multichunk-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-mc.img"
ESP_END_MIB=33
PART_END_MIB=230                            # 197 MiB ext4 partition
DISK_MIB=256
PART_OFFSET=$(( ESP_END_MIB * 1048576 ))
PART_BYTES=$(( (PART_END_MIB - ESP_END_MIB) * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Per-group sizing that forces MANY groups in a small image while keeping the
# default 4K/desc64 profile (64 groups per BGDT chunk):
#   -g 256  → 256 blocks/group = 1 MiB/group → 197 groups → 4 BGDT chunks
#   -i 131072 → 16 inodes/group → group 66's first inode = 1057 (chunk 1)
# ^resize_inode drops the online-resize GDT reservation (irrelevant here, and
# awkward with tiny groups); metadata_csum/64bit/extent/flex_bg stay (defaults),
# so this is the real agnos-fs feature profile.
BPG=256
BYTES_PER_INODE=131072
NFILES=1200                                 # ensures inode 1057 (group 66, chunk 1) is an allocated file

echo "Building ${PART_BYTES} B ext4 image (-g $BPG -i $BYTES_PER_INODE, default mkfs.ext4 features)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
# Generate NFILES small files so inodes fill past the first BGDT chunk (group 64).
i=0
while [ "$i" -lt "$NFILES" ]; do
    printf 'mc%04d\n' "$i" > "$SEED/$(printf 'f%04d.txt' "$i")"
    i=$(( i + 1 ))
done

dd if=/dev/zero of="$IMG" bs=1M count=$DISK_MIB status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB ${ESP_END_MIB}MiB set 1 esp on \
    mkpart agnos-fs ext2 ${ESP_END_MIB}MiB ${PART_END_MIB}MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext4 -F -q -L AGNOS-MC -b 4096 -m 0 -g "$BPG" -i "$BYTES_PER_INODE" \
    -O ^resize_inode \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

# --- host baseline: confirm the image is genuinely multi-chunk + inode 529 high ---
dd if="$IMG" bs=1M skip=$ESP_END_MIB count=$(( PART_END_MIB - ESP_END_MIB )) of="$WORK/part-pre.img" status=none
H_GROUPS=$(dumpe2fs -h "$WORK/part-pre.img" 2>/dev/null | sed -nE 's/.*Group descriptor size:[[:space:]]+([0-9]+).*/\1/p')
H_IPG=$(dumpe2fs -h "$WORK/part-pre.img" 2>/dev/null | sed -nE 's/.*Inodes per group:[[:space:]]+([0-9]+).*/\1/p')
H_NG=$(dumpe2fs "$WORK/part-pre.img" 2>/dev/null | grep -cE "^Group [0-9]+:")
H_DESC=${H_GROUPS:-?}
GPB=$(( 4096 / ${H_GROUPS:-64} ))
echo "  host fs: desc_size=$H_DESC  inodes/group=$H_IPG  groups=$H_NG  groups_per_bgdt_block=$GPB"
if [ "${H_NG:-0}" -le "$GPB" ]; then
    echo "  ERROR: host image has $H_NG groups <= $GPB/chunk — NOT multi-chunk. Increase the partition size."
    exit 1
fi
# Which group does the kernel's target inode (gpb+2)*ipg+1 fall in?
HINO=$(( (GPB + 2) * ${H_IPG:-8} + 1 ))
HGRP=$(( (HINO - 1) / ${H_IPG:-8} ))
echo "  kernel will read inode $HINO (group $HGRP, chunk $(( HGRP / GPB ))); $NFILES files seeded"

# --- boot the selftest kernel ---
echo "Booting MULTICHUNK_SELFTEST kernel (NVMe + GPT partition)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/multichunk-selftest.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-MC" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- mc: self-test lines from boot log ---"
strings "$LOG" | grep -E "^mc:" | sed 's/^/  /'
echo ""

if ! strings "$LOG" | grep -q "^mc:"; then
    echo "  ERROR: kernel booted but produced NO 'mc:' lines — this build does NOT"
    echo "         contain the multi-chunk self-test. Rebuild:  MULTICHUNK_SELFTEST=1 ./scripts/build.sh"
    echo "         Log: $LOG"
    exit 2
fi

rc=0

# Guard: the image must actually be multi-chunk (else the test proves nothing).
if strings "$LOG" | grep -q "mc: NOT MULTICHUNK"; then
    echo "  FAIL: kernel saw a single-chunk FS (bgdt_blocks<2) — image sizing wrong"; rc=1
fi

# READ gate — the iron failure mode: a high-group inode read.
if strings "$LOG" | grep -q "mc: high-inode read OK"; then
    echo "  PASS: high-group inode READ (ext2_get_inode across BGDT chunk >= 1)"
else
    echo "  FAIL: high-group inode read"; strings "$LOG" | grep -E "mc: high-inode" | sed 's/^/        /'; rc=1
fi

# NEGATIVE gate — inode past s_inodes_count rejected.
if strings "$LOG" | grep -q "mc: oob-inode reject OK"; then
    echo "  PASS: out-of-range inode rejected (s_inodes_count bound)"
else
    echo "  FAIL: out-of-range inode not rejected"; rc=1
fi

# WRITE gate — alloc lands in a high chunk, then freed.
if strings "$LOG" | grep -q "mc: high-alloc OK"; then
    echo "  PASS: high-group block ALLOC/FREE (allocator + write_bgdt + recsum on chunk >= 1)"
elif strings "$LOG" | grep -q "mc: write gated"; then
    echo "  SKIP: high-group alloc (FS mounted read-only for write)"
else
    echo "  FAIL: high-group alloc"; strings "$LOG" | grep -E "mc: high-alloc" | sed 's/^/        /'; rc=1
fi

# Selftest completed (didn't hang/panic mid-way).
if strings "$LOG" | grep -q "mc: selftest done"; then
    echo "  PASS: selftest ran to completion"
else
    echo "  FAIL: selftest did not complete (hang/panic?)"; rc=1
fi

# Gate: post-boot e2fsck clean (the high-group alloc/free must not corrupt).
dd if="$IMG" bs=1M skip=$ESP_END_MIB count=$(( PART_END_MIB - ESP_END_MIB )) of="$WORK/part-post.img" status=none
echo ""
echo "  --- e2fsck -fn on POST-BOOT partition ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (exit 0)"
else
    echo "  FAIL: e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

echo ""
echo "=========================================="
[ $rc -eq 0 ] && echo "ext2 multi-chunk BGDT smoke: PASS" || echo "ext2 multi-chunk BGDT smoke: FAIL"
echo "Logs: $LOGS"
echo "=========================================="
exit $rc
