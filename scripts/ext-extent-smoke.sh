#!/bin/bash
# ext4 extent-ALLOCATION smoke for the AGNOS kernel (1.37.0–1.37.3, depth 0→2).
#
# Builds a default-profile ext4 image (metadata_csum,64bit,extent) with NO seed
# file — the kernel SELF-SEEDS `/extseed.dat` as an empty EXTENTS_FL inode
# (`ext2_extent_seed_create`), so this smoke exercises the EXACT iron-burn path
# (flash-and-test, no host-side mount/seed). Boots agnos with
# EXT2_EXTENT_WRITE_SELFTEST=1, which appends 64 bytes of 0xAB at SPARSE logical
# blocks 2,4,6,… — each gap forces a new extent.
# The tree climbs the full ladder: inline root fills → depth-0→1 grow (1.37.1);
# the leaf fills (eh_max) → SIBLING leaf (1.37.2); all 4 inline-root index slots
# fill (4 full leaves ≈ 1360 extents at 4 KB) → depth-1→2 grow into an INDEX
# block (1.37.3). The selftest loops until depth==2 appears (adaptive, capped).
# Then HOST-verifies the mutated partition:
#   1. serial gate: "ext-ext: depth-2 PASS" + "ext-ext: append PASS"
#   2. `e2fsck -fn` clean (the load-bearing gate — proves both grows, the sibling
#      splits, the leaf AND index node checksums, all index entries, the inode csum)
#   3. /extseed.dat is large+sparse and bytes at offset 8192 (block 2) are 0xAB
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

# NO host-side seed: the kernel self-creates /extseed.dat as an empty extent
# file (ext2_extent_seed_create) — the exact iron-burn path.
echo "=== AGNOS ext4 extent-allocation smoke (1.37.0-1.37.3, self-seed) ==="
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext4 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
# default mkfs.ext4 profile (metadata_csum,64bit,extent); no -d seed — the kernel
# self-creates the extent file, so this validates the iron-burn self-seed path.
mkfs.ext4 -F -q -L AGNOS-EXT -b 4096 -m 0 -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting EXT2_EXTENT_WRITE_SELFTEST kernel (NVMe + GPT)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/ext-extent.log"
timeout "${QEMU_TIMEOUT:-240}" qemu-system-x86_64 \
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
if strings "$LOG" | grep -q "ext-ext: depth-2 PASS"; then
    echo "  PASS: extent tree grew to depth 2 (index block) in the kernel"
else
    echo "  FAIL: 'ext-ext: depth-2 PASS' not in serial log (depth-1→2 grow not reached)"; rc=1
fi

# Pull the mutated partition slice and check it host-side.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" >"$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean after extent append"
else
    echo "  FAIL: e2fsck -fn reported errors (see $LOGS/e2fsck.log):"; sed 's/^/    /' "$LOGS/e2fsck.log"; rc=1
fi

# Sparse writes (logical 2,4,6,…) climb the tree to depth 2 (≈ 1360 extents
# across 4 full leaves + a sibling under the new index block at a 4 KB FS). Size
# is adaptive; logical block 2 (offset 8192) always holds 0xAB.
debugfs -R "dump /extseed.dat $WORK/extseed-post.dat" "$WORK/part-post.img" >/dev/null 2>&1
if [ -f "$WORK/extseed-post.dat" ]; then
    SZ=$(stat -c %s "$WORK/extseed-post.dat")
    if [ "$SZ" -gt 200000 ]; then echo "  PASS: /extseed.dat grew large+sparse ($SZ B — many extents across a depth-2 tree)"
    else echo "  FAIL: /extseed.dat size $SZ too small (expected a deep multi-leaf file > 200 KB)"; rc=1; fi
    BYTES=$(xxd -s 8192 -l 4 -p "$WORK/extseed-post.dat")
    if [ "$BYTES" = "abababab" ]; then echo "  PASS: appended bytes at offset 8192 (logical block 2) = 0xAB"
    else echo "  FAIL: bytes at 8192 = 0x$BYTES (expected abababab)"; rc=1; fi
else
    echo "  FAIL: could not dump /extseed.dat from the image"; rc=1
fi
# The selftest's serial line reports the final tree shape — confirm depth 2
# (inline index → index block → leaves).
if strings "$LOG" | grep -qE 'ext-ext: final depth=2'; then
    echo "  PASS: depth-2 tree (inline index → index block → leaves)"
else
    echo "  FAIL: did not reach a depth-2 tree"; rc=1; fi

echo ""
[ "$rc" -eq 0 ] && echo "=== ext-extent-smoke: PASS ===" || echo "=== ext-extent-smoke: FAIL ==="
exit $rc
