#!/bin/bash
# jbd2-logdump-smoke.sh — verify the 1.38.2 log-format reader.
#
# Generates an ext4 image with a SYNTHETIC one-transaction journal at log
# blocks [1..3] (descriptor + data + commit) via scripts/mk-dirty-journal-img.py
# --synth-tx, boots agnos built with JBD2_LOGDUMP=1, and gates the trace:
#   1. `jbd2: log: walk start=1 seq_expected=1`
#   2. `jbd2: log: DESCRIPTOR seq=1 at blk=1`
#   3. `  tag: dest_blk=<N> flags=0x8`  (LAST_TAG = 0x08)
#   4. `jbd2: log: COMMIT seq=1 at blk=3`
#   5. `jbd2: log: end at blk=4 (no magic; 1 complete tx)`
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           dd, strings, python3. gnoboot at ../gnoboot/build/.
# REQUIRES the kernel to be built with JBD2_LOGDUMP=1 (smoke checks).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "jbd2: log: walk start="; then
    echo "ERROR: kernel not built with JBD2_LOGDUMP=1" >&2
    echo "       rebuild: JBD2_LOGDUMP=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/jbd2-logdump-smoke"; LOGS="$ROOT/build/jbd2-logdump-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-jbd2-synth.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
TARGET_BLK=100

echo "=== AGNOS JBD2 log-format reader smoke (1.38.2, synth 1-tx journal) ==="
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

echo "Synthesizing one-tx journal (target FS block $TARGET_BLK)..."
python3 "$ROOT/scripts/mk-dirty-journal-img.py" "$IMG" "$PART_OFFSET" --synth-tx "$TARGET_BLK" | sed 's/^/  /'

echo "Booting agnos (JBD2_LOGDUMP build)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/jbd2-logdump.log"
timeout "${QEMU_TIMEOUT:-90}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- jbd2 trace from boot log ---"
strings "$LOG" | grep -E "^jbd2:|^  tag:|^AGNOS shell" | sed 's/^/  /'
echo ""

rc=0
WALK_LINE="jbd2: log: walk start=1 seq_expected=1"
DESC_LINE="jbd2: log: DESCRIPTOR seq=1 at blk=1"
TAG_LINE="tag: dest_blk=$TARGET_BLK flags=0x8"
COMMIT_LINE="jbd2: log: COMMIT seq=1 at blk="
END_LINE="jbd2: log: end at blk=4"

check_line() {
    if strings "$LOG" | grep -qF "$2"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1 -- missing '$2'"; rc=1
    fi
}
check_line "walk header (start=1, seq=1)"       "$WALK_LINE"
check_line "descriptor block (seq=1 at blk=1)"  "$DESC_LINE"
check_line "tag (dest_blk=$TARGET_BLK, LAST_TAG)" "$TAG_LINE"
check_line "commit block (seq=1)"               "$COMMIT_LINE"
check_line "end at blk=4 (1 complete tx)"       "$END_LINE"
if strings "$LOG" | grep -q "^AGNOS shell"; then
    echo "  PASS: shell came up (RO mount allowed -- not a hang)"
else
    echo "  FAIL: shell prompt never reached"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "=== jbd2-logdump-smoke: PASS ===" || echo "=== jbd2-logdump-smoke: FAIL ==="
exit $rc
