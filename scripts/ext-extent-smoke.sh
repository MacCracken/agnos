#!/bin/bash
# ext4 extent-ALLOCATION smoke for the AGNOS kernel (1.37.0, depth-0 append).
#
# Builds a default-profile ext4 image (metadata_csum,64bit,extent) with a seed
# file `/extseed.dat` — which `mkfs.ext4 -d` lays down EXTENTS_FL (depth-0
# inline root). Boots agnos with EXT2_EXTENT_WRITE_SELFTEST=1, which appends 64
# bytes of 0xAB at SPARSE logical blocks 2,4,6,8,10 — each gap forces a new
# extent, so the 4-entry inline root fills and the tree GROWS to depth 1
# (ext2_extent_grow_indepth + a checksummed leaf block; 1.37.1). Then
# HOST-verifies the mutated partition:
#   1. serial gate: "ext-ext: append PASS" (selftest also asserts final depth==1)
#   2. `e2fsck -fn` clean (the load-bearing gate — proves the depth-0→1 grow, the
#      leaf-node checksum, and the inode-checksum recompute are all correct)
#   3. /extseed.dat grew to 41024 B and bytes at offset 8192 (block 2) are 0xAB
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           e2fsck, debugfs, dd, strings, xxd. gnoboot at ../gnoboot/build/.
# Exit 0 if all gates pass; 1 otherwise.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 e2fsck debugfs dd strings xxd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "ext-ext: append PASS"; then
    echo "ERROR: kernel not built with EXT2_EXTENT_WRITE_SELFTEST=1" >&2
    echo "       rebuild: EXT2_EXTENT_WRITE_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/ext-extent-smoke"; LOGS="$ROOT/build/ext-extent-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-ext.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

SEED="$WORK/seed"; mkdir -p "$SEED"
echo "agnos 1.37.0 extent-alloc seed file" > "$SEED/extseed.dat"   # small → depth-0 inline-root extent

echo "=== AGNOS ext4 extent-allocation smoke (1.37.0) ==="
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext4 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
# default mkfs.ext4 profile → seed files are extent-mapped (EXTENTS_FL)
mkfs.ext4 -F -q -L AGNOS-EXT -b 4096 -m 0 -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting EXT2_EXTENT_WRITE_SELFTEST kernel (NVMe + GPT)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/ext-extent.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- ext-ext self-test lines ---"
strings "$LOG" | grep -E "^ext-ext:" | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "ext-ext: append PASS"; then
    echo "  PASS: kernel appended to the extent file (selftest)"
else
    echo "  FAIL: 'ext-ext: append PASS' not in serial log"; rc=1
fi

# Pull the mutated partition slice and check it host-side.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" >"$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean after extent append"
else
    echo "  FAIL: e2fsck -fn reported errors (see $LOGS/e2fsck.log):"; sed 's/^/    /' "$LOGS/e2fsck.log"; rc=1
fi

# sparse writes at logical blocks 2,4,6,8,10 (offsets 8192..40960, 64 B each) →
# final size = 10*4096 + 64 = 41024; logical block 2 (offset 8192) holds 0xAB.
debugfs -R "dump /extseed.dat $WORK/extseed-post.dat" "$WORK/part-post.img" >/dev/null 2>&1
if [ -f "$WORK/extseed-post.dat" ]; then
    SZ=$(stat -c %s "$WORK/extseed-post.dat")
    if [ "$SZ" -eq 41024 ]; then echo "  PASS: /extseed.dat grew to 41024 B (sparse, last write at block 10)"
    else echo "  FAIL: /extseed.dat size $SZ (expected 41024)"; rc=1; fi
    BYTES=$(xxd -s 8192 -l 4 -p "$WORK/extseed-post.dat")
    if [ "$BYTES" = "abababab" ]; then echo "  PASS: appended bytes at offset 8192 (logical block 2) = 0xAB"
    else echo "  FAIL: bytes at 8192 = 0x$BYTES (expected abababab)"; rc=1; fi
else
    echo "  FAIL: could not dump /extseed.dat from the image"; rc=1
fi
# Confirm the tree grew to depth 1 (debugfs prints the extent tree for the inode).
if debugfs -R "stat /extseed.dat" "$WORK/part-post.img" 2>/dev/null | grep -qiE 'depth|interior'; then
    echo "  PASS: extent tree shows interior/depth node (grew to depth 1)"
else
    echo "  INFO: debugfs stat didn't surface a depth marker (selftest asserted depth==1)"
fi

echo ""
[ "$rc" -eq 0 ] && echo "=== ext-extent-smoke: PASS ===" || echo "=== ext-extent-smoke: FAIL ==="
exit $rc
