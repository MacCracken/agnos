#!/bin/bash
# jbd2-tx-smoke.sh — verify the 1.38.4 in-memory transaction lifecycle.
#
# Builds the kernel with JBD2_TX_SELFTEST=1, boots agnos against a default
# mkfs.ext4 image (clean journal — the lifecycle test runs on a healthy
# FS), and gates the trace produced by ext2_jbd2_tx_selftest():
#
#   1. `jbd2-tx: selftest begin` — the self-test reached the API
#   2. `jbd2: commit_tx (trace-only at 1.38.4): seq=1 n_blocks=3`
#   3. `log: target_blk=100`, `log: target_blk=101`, `log: target_blk=102`
#   4. `jbd2-tx: selftest PASS` — all positive + negative paths succeeded
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           dd, strings. gnoboot at ../gnoboot/build/.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "jbd2-tx: selftest"; then
    echo "ERROR: kernel not built with JBD2_TX_SELFTEST=1" >&2
    echo "       rebuild: JBD2_TX_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/jbd2-tx-smoke"; LOGS="$ROOT/build/jbd2-tx-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-jbd2-tx.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

echo "=== AGNOS JBD2 in-memory transaction lifecycle smoke (1.38.4) ==="
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

echo "Booting agnos (JBD2_TX_SELFTEST kernel, clean journal)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/jbd2-tx.log"
timeout "${QEMU_TIMEOUT:-90}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXT" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- jbd2-tx + lifecycle trace ---"
strings "$LOG" | grep -E "^jbd2(:|-tx:)|^  log:|^AGNOS shell" | sed 's/^/  /'
echo ""

rc=0
check_line() {
    if strings "$LOG" | grep -qF "$2"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1 -- missing '$2'"; rc=1
    fi
}
check_line "selftest begin"                          "jbd2-tx: selftest begin"
check_line "commit trace (seq=1 n_blocks=3)"         "jbd2: commit_tx (trace-only at 1.38.4): seq=1 n_blocks=3"
check_line "log entry blk=100"                       "log: target_blk=100"
check_line "log entry blk=101"                       "log: target_blk=101"
check_line "log entry blk=102"                       "log: target_blk=102"
check_line "selftest PASS"                           "jbd2-tx: selftest PASS"
if strings "$LOG" | grep -q "^AGNOS shell"; then
    echo "  PASS: shell came up after selftest"
else
    echo "  FAIL: shell prompt never reached"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "=== jbd2-tx-smoke: PASS ===" || echo "=== jbd2-tx-smoke: FAIL ==="
exit $rc
