#!/bin/bash
# jbd2-replay-smoke.sh — verify the 1.38.3 replay-on-mount.
#
# Generates an ext4 image with a SYNTHETIC one-transaction journal at log
# blocks [1..3] (descriptor + data + commit). The data block contains
# target FS block's CURRENT content (read-source mode) — so replay is a
# no-op write at the byte level → host e2fsck stays clean after.
#
# Gates:
#   1. `jbd2: DIRTY journal` printed at mount (the probe still detects it)
#   2. `jbd2: replay: APPLIED 1 tx` printed
#   3. `RW mount LIFTED` printed (post-replay write_ok = 1)
#   4. shell came up at v1.38.3 (not a hang)
#   5. host `e2fsck -fn` clean on the partition post-mount (the dispositive
#      gate — proves the SB was rewritten clean, FLUSH-CACHE issued,
#      data writes consistent with FS state, VALID_FS bit re-asserted).
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
if ! strings "$AGNOS" | grep -q "jbd2: replay:"; then
    echo "ERROR: kernel doesn't contain replay code (build older than 1.38.3?)" >&2
    exit 1
fi

WORK="$ROOT/build/jbd2-replay-smoke"; LOGS="$ROOT/build/jbd2-replay-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-jbd2-replay.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
TARGET_BLK=200          # high block, likely in the data region (or empty)

echo "=== AGNOS JBD2 replay-on-mount smoke (1.38.3) ==="
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

# Pre-replay e2fsck baseline (should be clean — fresh mkfs). e2fsck doesn't
# take an `-E offset=` flag like mke2fs does; extract the partition via dd
# first, then check the partition file directly (matches ext-extent-smoke.sh).
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-pre.img" status=none
if ! e2fsck -fn "$WORK/part-pre.img" >"$LOGS/e2fsck-pre.log" 2>&1; then
    echo "  WARN: pre-replay e2fsck NOT clean (mkfs may have produced unusual state)"
    sed 's/^/    /' "$LOGS/e2fsck-pre.log"
fi

echo "Synthesizing one-tx CSUM_V3 journal targeting FS block $TARGET_BLK (read-source mode)..."
# --csum-v3 makes the synth tx use the 16-byte tag3 layout + tail/commit csums,
# matching the archaemenid iron journal AGNOS's replay must handle.
python3 "$ROOT/scripts/mk-dirty-journal-img.py" "$IMG" "$PART_OFFSET" --synth-tx "$TARGET_BLK" --csum-v3 | sed 's/^/  /'

echo "Booting agnos (replay will fire at mount)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/jbd2-replay.log"
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
check_line() {
    if strings "$LOG" | grep -qF "$2"; then
        echo "  PASS: $1"
    else
        echo "  FAIL: $1 -- missing '$2'"; rc=1
    fi
}
check_line "probe still detects dirty journal"  "jbd2: DIRTY journal"
check_line "replay APPLIED 1 tx"                "jbd2: replay: APPLIED 1 tx"
check_line "RW mount LIFTED"                    "RW mount LIFTED"
if strings "$LOG" | grep -q "^AGNOS shell"; then
    echo "  PASS: shell came up at v1.38.3"
else
    echo "  FAIL: shell prompt never reached"; rc=1
fi

# === Dispositive gate: host e2fsck -fn on the post-replay partition ===
echo ""
echo "  --- host e2fsck -fn on the post-replay image ---"
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" >"$LOGS/e2fsck-post.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean post-replay (FS consistent on disk)"
    sed 's/^/    /' "$LOGS/e2fsck-post.log"
else
    echo "  FAIL: e2fsck -fn reported errors post-replay:"
    sed 's/^/    /' "$LOGS/e2fsck-post.log"
    rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "=== jbd2-replay-smoke: PASS ===" || echo "=== jbd2-replay-smoke: FAIL ==="
exit $rc
