#!/bin/bash
# jbd2-refusal-smoke.sh — verify the 1.38.0/.1 mount-refusal stop-gap.
#
# Builds a default-profile ext4 image (metadata_csum,64bit,extent + has_journal),
# uses scripts/mk-dirty-journal-img.py to set s_start != 0 in the journal SB
# (re-stamping the SB CSUM if CSUM_V2/V3 is enabled), boots agnos, and gates:
#   1. serial gate: `jbd2: DIRTY journal` line emitted at mount
#   2. shell still comes up (RO mount is allowed — not a hang/panic)
#
# When 1.38.3 lands, this smoke flips to expect successful replay + clean SB.
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           dd, strings, python3. gnoboot at ../gnoboot/build/.
# Exit 0 if both gates pass; 1 otherwise.

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

WORK="$ROOT/build/jbd2-refusal-smoke"; LOGS="$ROOT/build/jbd2-refusal-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-jbd2-dirty.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

echo "=== AGNOS JBD2 dirty-journal refusal smoke (1.38.1) ==="
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

echo "Corrupting journal SB to s_start = 1..."
python3 "$ROOT/scripts/mk-dirty-journal-img.py" "$IMG" "$PART_OFFSET" 1 | sed 's/^/  /'

echo "Booting agnos against dirty-journal image (NVMe + GPT)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/jbd2-refusal.log"
timeout "${QEMU_TIMEOUT:-90}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- jbd2 + shell-prompt lines from boot log ---"
strings "$LOG" | grep -E "^jbd2:|^AGNOS shell" | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "jbd2: DIRTY journal"; then
    echo "  PASS: 'jbd2: DIRTY journal' diagnostic emitted at mount"
else
    echo "  FAIL: 'jbd2: DIRTY journal' line not in boot log"; rc=1
fi
if strings "$LOG" | grep -q "refusing RW mount"; then
    echo "  PASS: refusal reason printed"
else
    echo "  FAIL: refusal-reason text missing"; rc=1
fi
if strings "$LOG" | grep -q "^AGNOS shell"; then
    echo "  PASS: shell came up (RO mount allowed -- not a hang)"
else
    echo "  FAIL: shell prompt never reached"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "=== jbd2-refusal-smoke: PASS ===" || echo "=== jbd2-refusal-smoke: FAIL ==="
exit $rc
