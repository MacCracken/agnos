#!/bin/bash
# FAT-family read smoke (1.34.x FAT-family arc — bite 2: FAT32 + chain
# traversal + partition-aware multi-backend mount).
#
# Boots the FATFS_SELFTEST kernel against a GPT disk whose ESP is a
# FAT32 filesystem (mformat -F) seeded with a multi-cluster FATTEST.BIN
# (3000 bytes, byte[i] = i & 0xFF). fatfs_init's partition-aware probe
# mounts the ESP on the NVMe backend; the self-test reads FATTEST.BIN
# back via the cluster chain and byte-verifies past the first 512-byte
# cluster (which the pre-bite-2 reader truncated at). Gates on:
#     fat: mounted FAT32 ...        (partition-aware FAT32 mount)
#     fatr: chain-read OK           (multi-cluster chain read byte-exact)
#
# Build first:  FATFS_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools (mformat/mmd/mcopy),
#           sgdisk, dd, strings. gnoboot at ../gnoboot/build/.
# Exit 0 if both gates pass; 1 otherwise.

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

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run FATFS_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/fat-smoke"
LOGS="$ROOT/build/fat-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-fat.img"

# 3000-byte pattern file: byte[i] = i & 0xFF. Reading it back byte-exact
# proves the chain-follow reads PAST the first 512-byte cluster (the old
# reader capped there) — 3000 B spans ~6 clusters on a 512 B/clus FAT32.
echo "Generating FATTEST.BIN (3000 B, byte[i]=i&0xFF)..."
{ for i in $(seq 0 2999); do printf "\\$(printf '%03o' $((i % 256)))"; done; } > "$WORK/FATTEST.BIN"
GEN=$(wc -c < "$WORK/FATTEST.BIN")
[ "$GEN" = "3000" ] || { echo "ERROR: pattern gen produced $GEN bytes (want 3000)"; exit 1; }

echo "Building GPT disk (FAT32 ESP + ext2 data partition)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
# ESP = FAT32 (mformat -F), seeded with gnoboot + agnos + the test file.
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mcopy -i "$IMG"@@1048576 "$WORK/FATTEST.BIN" ::FATTEST.BIN
# 1.39.1 VFS-lift bite 1: a small text file the FATFS_SELFTEST drives the
# shell `cat` verb against (via sh_exec → sh_cmd_cat → vfs_open_secondary →
# fatfs_open). Proves the shell read verb reaches a FAT volume end-to-end.
printf 'VFS-CAT-FAT-OK\n' > "$WORK/CATTEST.TXT"
mcopy -i "$IMG"@@1048576 "$WORK/CATTEST.TXT" ::CATTEST.TXT

echo "Booting FATFS_SELFTEST kernel (NVMe + GPT, FAT32 ESP)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/fat-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FATTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- fat lines from boot log ---"
strings "$LOG" | grep -E "^fat: mounted|^fatr:" | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "fat: mounted FAT32"; then
    echo "  PASS: partition-aware FAT32 mount"
else
    echo "  FAIL: FAT32 mount (no 'fat: mounted FAT32' in log)"; rc=1
fi
if strings "$LOG" | grep -q "fatr: chain-read OK"; then
    echo "  PASS: multi-cluster chain read byte-exact (read past first cluster)"
else
    echo "  FAIL: chain read (no 'fatr: chain-read OK' in log)"; rc=1
fi
# 1.39.1 VFS-lift bite 1: the shell `cat` verb reaches FAT (sh_cmd_cat →
# vfs_open_secondary → fatfs_open). The kernel ran `cat CATTEST.TXT`; its
# content must appear in the log.
if strings "$LOG" | grep -q "VFS-CAT-FAT-OK"; then
    echo "  PASS: shell 'cat' reaches FAT volume (vfs_open_secondary dispatch)"
else
    echo "  FAIL: shell cat over FAT (no 'VFS-CAT-FAT-OK' in log)"; rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "FAT read smoke: PASS"; else echo "FAT read smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
