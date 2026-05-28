#!/bin/bash
# jbd2-writepath-smoke.sh — verify the 1.38.5 journal write path end-to-end.
#
# Builds the kernel with JBD2_WP_SELFTEST=1, boots agnos against a clean
# default-`mkfs.ext4` image, and gates:
#
#   1. `jbd2-wp: write-path selftest begin` — selftest reached the API
#   2. `jbd2: commit_tx: COMMITTED seq=1 n_blocks=1`
#   3. `checkpoint applied + journal clean`
#   4. `jbd2-wp: write-path selftest PASS`
#   5. shell came up at v1.38.5
#   6. **host `e2fsck -fn` clean on the post-commit partition** — the
#      dispositive gate: proves the descriptor + data + commit + checkpoint
#      sequence kept the FS structurally consistent.
#   7. **journal SB on disk reads s_start=0, s_sequence=2** — proves the
#      sync-checkpoint cleaned the journal correctly.
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           e2fsck, dd, strings, python3. gnoboot at ../gnoboot/build/.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 e2fsck dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "jbd2-wp:"; then
    echo "ERROR: kernel not built with JBD2_WP_SELFTEST=1" >&2
    echo "       rebuild: JBD2_WP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/jbd2-writepath-smoke"; LOGS="$ROOT/build/jbd2-writepath-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-jbd2-wp.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

echo "=== AGNOS JBD2 write-path smoke (1.38.5, real commit on clean journal) ==="
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext4 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext4 -F -q -L AGNOS-EXT -b 4096 -m 0 -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS
# Match iron: stamp the journal CSUM_V3 + 64BIT (what Linux does on first RW mount).
python3 "$ROOT/scripts/mk-dirty-journal-img.py" "$IMG" "$PART_OFFSET" --csum-v3

echo "Booting agnos (JBD2_WP_SELFTEST kernel, CSUM_V3 journal at boot)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/jbd2-writepath.log"
timeout "${QEMU_TIMEOUT:-90}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- jbd2 + selftest trace ---"
strings "$LOG" | grep -E "^jbd2(:|-wp:)|^AGNOS shell" | sed 's/^/  /'
echo ""

rc=0
check_line() {
    if strings "$LOG" | grep -qF "$2"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1 -- missing '$2'"; rc=1
    fi
}
check_line "selftest reached the API"            "jbd2-wp: write-path selftest begin"
check_line "commit emitted COMMITTED line"       "jbd2: commit_tx: COMMITTED seq=1 n_blocks=1"
check_line "checkpoint + journal-clean reported" "checkpoint applied + journal clean"
check_line "selftest PASS"                       "jbd2-wp: write-path selftest PASS"
if strings "$LOG" | grep -q "^AGNOS shell"; then
    echo "  PASS: shell came up at v1.38.5"
else
    echo "  FAIL: shell prompt never reached"; rc=1
fi

# === Dispositive gate: host e2fsck -fn ===
echo ""
echo "  --- host e2fsck -fn on the post-commit partition ---"
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" >"$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean post-commit"
    sed 's/^/    /' "$LOGS/e2fsck.log"
else
    echo "  FAIL: e2fsck -fn reported errors:"
    sed 's/^/    /' "$LOGS/e2fsck.log"
    rc=1
fi

# === Journal-SB on-disk inspection: s_start should be 0, s_sequence > 1 ===
echo ""
echo "  --- post-commit journal SB on disk ---"
python3 - "$IMG" "$PART_OFFSET" <<'PY' > "$LOGS/jsb-inspect.log" 2>&1 || rc=1
import struct, sys
img = sys.argv[1]; part_off = int(sys.argv[2])
with open(img, 'rb') as f:
    f.seek(part_off + 1024); sb = f.read(1024)
    bs = 1024 << struct.unpack_from('<I', sb, 24)[0]
    blocks_per_group = struct.unpack_from('<I', sb, 32)[0]
    inodes_per_group = struct.unpack_from('<I', sb, 40)[0]
    inode_size = struct.unpack_from('<H', sb, 88)[0] or 128
    j_inum = struct.unpack_from('<I', sb, 224)[0]
    feature_incompat = struct.unpack_from('<I', sb, 96)[0]
    desc_size = struct.unpack_from('<H', sb, 254)[0] or 32
    is_64bit = bool(feature_incompat & 0x80)
    first_data_block = struct.unpack_from('<I', sb, 20)[0]

    j_index = j_inum - 1
    j_group = j_index // inodes_per_group
    bgdt_off = part_off + (first_data_block + 1) * bs + j_group * desc_size
    f.seek(bgdt_off); bgdt = f.read(desc_size)
    inode_table_lo = struct.unpack_from('<I', bgdt, 8)[0]
    inode_table_hi = struct.unpack_from('<I', bgdt, 32)[0] if (is_64bit and desc_size >= 64) else 0
    itab_block = (inode_table_hi << 32) | inode_table_lo
    inode_off = part_off + itab_block * bs + (j_index % inodes_per_group) * inode_size
    f.seek(inode_off); inode = f.read(inode_size)
    flags = struct.unpack_from('<I', inode, 32)[0]
    if flags & 0x80000:
        ee_start_hi = struct.unpack_from('<H', inode, 58)[0]
        ee_start_lo = struct.unpack_from('<I', inode, 60)[0]
        first_phys = (ee_start_hi << 32) | ee_start_lo
    else:
        first_phys = struct.unpack_from('<I', inode, 40)[0]
    f.seek(part_off + first_phys * bs); jsb = f.read(1024)
    magic = struct.unpack_from('>I', jsb, 0)[0]
    s_sequence = struct.unpack_from('>I', jsb, 24)[0]
    s_start    = struct.unpack_from('>I', jsb, 28)[0]
    print(f"journal_SB: magic=0x{magic:08x} s_start={s_start} s_sequence={s_sequence}")
    rc = 0
    if magic != 0xC03B3998:    print("FAIL: bad magic"); rc = 1
    if s_start != 0:           print(f"FAIL: s_start={s_start} (expected 0)"); rc = 1
    if s_sequence < 2:         print(f"FAIL: s_sequence={s_sequence} (expected >= 2 after a commit)"); rc = 1
    if rc == 0: print("PASS: journal SB shows clean post-commit (s_start=0, s_sequence advanced)")
    sys.exit(rc)
PY
sed 's/^/    /' "$LOGS/jsb-inspect.log"

echo ""
[ "$rc" -eq 0 ] && echo "=== jbd2-writepath-smoke: PASS ===" || echo "=== jbd2-writepath-smoke: FAIL ==="
exit $rc
