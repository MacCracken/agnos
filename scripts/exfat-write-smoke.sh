#!/bin/bash
# exFAT write smoke (agnos 1.34.1 bite 3 — dir-set create / content / delete).
#
# Boots the EXFAT_WRITE_SELFTEST kernel against a GPT disk (FAT32 ESP boot
# path + a `mkfs.exfat -c 512` Microsoft-Basic-Data p2). AGNOS mutates the
# exFAT volume (3a: creates EXWRITE.BIN by writing its 0x85/0xC0/0xC1
# dir-set with SetChecksum + NameHash). No seeding needed — AGNOS is the
# writer. After boot we extract the (now-mutated) exFAT partition back out
# of the image and run **`fsck.exfat -n`** — the independent structure +
# checksum oracle (the exFAT analogue of `fsck.fat -n` / `e2fsck -fn`).
# Gates:
#     exfatw: create EXWRITE.BIN rc=0   (AGNOS wrote the dir-set)
#     exfatw: create find-back OK       (AGNOS re-reads its own set)
#     fsck.exfat -n  -> clean, files >= 1   (host blesses the structure)
#
# Build first:  EXFAT_WRITE_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.exfat,
#           fsck.exfat (exfatprogs), dd, strings, awk. gnoboot at ../gnoboot/build/.
# Exit 0 if all gates pass; 1 otherwise.

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

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.exfat fsck.exfat dd strings awk; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXFAT_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/exfat-write-smoke"
LOGS="$ROOT/build/exfat-write-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-exfat.img"

echo "Building GPT disk (FAT32 ESP + exFAT MSFT-Basic partition)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart exfatdata 33MiB 100MiB
sgdisk -t 2:0700 "$IMG" >/dev/null

mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

P2_FIRST=$(sgdisk -i 2 "$IMG" | awk '/First sector:/ {print $3}')
P2_SECTORS=$(sgdisk -i 2 "$IMG" | awk '/Partition size:/ {print $3}')
[ -n "$P2_FIRST" ] && [ -n "$P2_SECTORS" ] || { echo "ERROR: could not read p2 geometry"; exit 1; }
echo "  p2: first_lba=$P2_FIRST sectors=$P2_SECTORS"

EXPART="$WORK/exfat.part"
dd if=/dev/zero of="$EXPART" bs=512 count="$P2_SECTORS" status=none
mkfs.exfat -c 512 "$EXPART" >/dev/null 2>&1 || { echo "ERROR: mkfs.exfat failed"; exit 1; }
dd if="$EXPART" of="$IMG" bs=512 seek="$P2_FIRST" conv=notrunc status=none

echo "Booting EXFAT_WRITE_SELFTEST kernel (AGNOS mutates the exFAT volume)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/exfat-write-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXFATWR" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

if [ ! -s "$LOG" ]; then
    echo "  ERROR: QEMU produced NO boot output (0-byte log) — launch failure, not an exFAT result."
    echo "         Check stale loop mounts: losetup -a ; mount | grep exfat — then re-run. Log: $LOG"
    exit 2
fi

echo ""
echo "  --- exfat write lines from boot log ---"
strings "$LOG" | grep -E "^exfat:|^exfatw:" | sed 's/^/  /'
echo ""

# Extract the mutated exFAT partition back out of the image and fsck it.
EXAFTER="$WORK/exfat-after.part"
dd if="$IMG" of="$EXAFTER" bs=512 skip="$P2_FIRST" count="$P2_SECTORS" status=none
echo "  --- fsck.exfat -n (post-boot partition) ---"
FSCK_OUT="$(fsck.exfat -n "$EXAFTER" 2>&1)"
echo "$FSCK_OUT" | sed 's/^/  /'
echo ""

rc=0
# 3a — empty-file create (dir-set + SetChecksum + NameHash)
strings "$LOG" | grep -q "^exfatw: create EXWRITE.BIN rc=0" \
    && echo "  PASS: 3a AGNOS wrote the dir-set (create rc=0)" \
    || { echo "  FAIL: 3a create rc != 0"; rc=1; }
strings "$LOG" | grep -q "^exfatw: create find-back OK" \
    && echo "  PASS: 3a AGNOS re-read its own dir-set (find-back)" \
    || { echo "  FAIL: 3a find-back"; rc=1; }
# 3b — content write (bitmap alloc + contiguous clusters + round-trip read)
strings "$LOG" | grep -q "^exfatw: write EXDATA.BIN rc=0" \
    && echo "  PASS: 3b AGNOS wrote content (write rc=0)" \
    || { echo "  FAIL: 3b write rc != 0"; rc=1; }
strings "$LOG" | grep -q "^exfatw: write round-trip OK" \
    && echo "  PASS: 3b multi-cluster content round-trip byte-exact" \
    || { echo "  FAIL: 3b round-trip"; rc=1; }
# 3c — delete + truncate-to-zero (clusters freed; fsck-clean is the gate)
strings "$LOG" | grep -q "^exfatw: delete EXDELME.BIN wrc=0 drc=0" \
    && echo "  PASS: 3c delete (write rc=0, delete rc=0)" \
    || { echo "  FAIL: 3c delete"; rc=1; }
strings "$LOG" | grep -q "^exfatw: trunc EXTRUNC.BIN wrc=0 trc=0" \
    && echo "  PASS: 3c truncate-to-zero (write rc=0, trunc rc=0)" \
    || { echo "  FAIL: 3c truncate"; rc=1; }
# fsck must report clean AND see at least the one created file.
if echo "$FSCK_OUT" | grep -qi "clean"; then
    if echo "$FSCK_OUT" | grep -qiE "files? (1|[1-9][0-9]*)"; then
        echo "  PASS: fsck.exfat -n clean, file present (structure + SetChecksum/NameHash valid)"
    else
        echo "  FAIL: fsck clean but no file counted (set not recognized)"; rc=1
    fi
else
    echo "  FAIL: fsck.exfat flagged the volume (see output above)"; rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "exFAT write smoke: PASS"; else echo "exFAT write smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
