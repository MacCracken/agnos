#!/bin/bash
# exFAT read smoke (agnos 1.34.1 bite 2 — mount + multi-cluster chain read).
#
# Boots the EXFAT_SELFTEST kernel against a GPT disk: p1 = a FAT32 ESP
# (gnoboot + agnos, the boot path), p2 = a Microsoft-Basic-Data partition
# formatted exFAT by mkfs.exfat -c 512. exFAT has no mtools-equivalent and
# this box has no non-interactive root / fuse, so we DON'T seed a file —
# instead we validate the read substrate against the structures mkfs.exfat
# itself writes into an empty volume:
#     exfat: mounted ...            (boot-region parse + MSFT-Basic probe)
#     exfatu: upcase-checksum OK    (read the up-case table back over its
#                                    FAT chain → reproduce the TableChecksum
#                                    mkfs.exfat baked into the 0x82 entry,
#                                    an INDEPENDENT multi-cluster-read oracle)
#
# Optional file readback: if you seed EXFTEST.BIN (3000 B, byte[i]=i&0xFF)
# into the exFAT volume (e.g. via `sudo mount -t exfat`), the kernel also
# prints `exfatr: file-read OK`. Not required for this smoke to PASS.
#
# Build first:  EXFAT_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools (mformat/mmd/
#           mcopy for the ESP), mkfs.exfat (exfatprogs), dd, strings.
#           gnoboot at ../gnoboot/build/.
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

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.exfat dd strings awk; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXFAT_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/exfat-smoke"
LOGS="$ROOT/build/exfat-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-exfat.img"

echo "Building GPT disk (FAT32 ESP + exFAT MSFT-Basic partition)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart exfatdata 33MiB 100MiB
# Force p2's type GUID to Microsoft Basic Data (EBD0A0A2-...) so AGNOS's
# exfat probe gate (ESP | MSFT-Basic) matches it regardless of parted's
# fs-type hint.
sgdisk -t 2:0700 "$IMG" >/dev/null

# ESP = FAT32, seeded with gnoboot + agnos (boot path).
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

# p2 = exFAT. mkfs.exfat can't format a partition-inside-a-file without a
# loop device (root), so format a standalone file of the partition's exact
# size, then dd it into the image at the partition offset (no root).
P2_FIRST=$(sgdisk -i 2 "$IMG" | awk '/First sector:/ {print $3}')
P2_SECTORS=$(sgdisk -i 2 "$IMG" | awk '/Partition size:/ {print $3}')
[ -n "$P2_FIRST" ] && [ -n "$P2_SECTORS" ] || { echo "ERROR: could not read p2 geometry"; exit 1; }
echo "  p2: first_lba=$P2_FIRST sectors=$P2_SECTORS"

EXPART="$WORK/exfat.part"
dd if=/dev/zero of="$EXPART" bs=512 count="$P2_SECTORS" status=none
# -c 512 → 512-byte clusters (1 sector/cluster): the up-case table (5836 B)
# then spans ~12 clusters, so reading it back exercises the multi-cluster
# FAT-chain read path the gate validates.
mkfs.exfat -c 512 "$EXPART" >/dev/null 2>&1 || { echo "ERROR: mkfs.exfat failed"; exit 1; }

# Optional file seed (EXFAT_SEED=1) — exFAT has no userspace file-injector
# (no mtools-equivalent), so seeding a file needs the in-kernel exfat driver
# + a privileged loop mount. This will prompt for your sudo password. When
# seeded, the smoke also gates on `exfatr: file-read OK` (the 0x85/0xC0/0xC1
# file-set read path). Without it the smoke validates mount + the upcase
# chain-read oracle only. The seed runs on the standalone exfat.part BEFORE
# it's dd'd into the image, so it survives.
SEEDED=0
if [ -n "${EXFAT_SEED:-}" ]; then
    echo "Seeding EXFTEST.BIN (3000 B, byte[i]=i%256) via in-kernel exfat mount (sudo)..."
    python3 - "$WORK/EXFTEST.BIN" <<'PY'
import sys
open(sys.argv[1], 'wb').write(bytes(i % 256 for i in range(3000)))
PY
    sudo modprobe exfat 2>/dev/null || true
    MNT="$WORK/mnt"; mkdir -p "$MNT"
    if sudo mount -t exfat -o loop "$EXPART" "$MNT"; then
        sudo cp "$WORK/EXFTEST.BIN" "$MNT"/EXFTEST.BIN && sync
        if sudo umount "$MNT"; then
            SEEDED=1
            echo "  seeded."
        else
            echo "ERROR: seed umount failed — $MNT still mounted (would leak a loop device). Aborting."
            exit 1
        fi
    else
        echo "  WARNING: seed mount failed — continuing without a seeded file."
    fi
fi

dd if="$EXPART" of="$IMG" bs=512 seek="$P2_FIRST" conv=notrunc status=none

echo "Booting EXFAT_SELFTEST kernel (NVMe + GPT, exFAT MSFT-Basic p2)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/exfat-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXFATTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

# A 0-byte log = QEMU never produced serial output (launch failure / host
# hiccup), NOT an exfat result. Report that honestly instead of emitting
# misleading per-gate FAILs. Common cause: a stale exfat loop-mount holding
# a loop device — check `losetup -a` / `mount | grep exfat`.
if [ ! -s "$LOG" ]; then
    echo "  ERROR: QEMU produced NO boot output (0-byte log) — launch failure, not an exFAT result."
    echo "         Check for stale loop mounts:  losetup -a ; mount | grep exfat"
    echo "         then re-run. Log: $LOG"
    exit 2
fi

echo ""
echo "  --- exfat lines from boot log ---"
strings "$LOG" | grep -E "^exfat:|^exfatr:|^exfatu:" | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "^exfat: mounted"; then
    echo "  PASS: exFAT mount (boot-region parse + MSFT-Basic probe)"
else
    echo "  FAIL: exFAT mount (no 'exfat: mounted' in log)"; rc=1
fi
if strings "$LOG" | grep -q "^exfatu: upcase-checksum OK"; then
    echo "  PASS: multi-cluster FAT-chain read (upcase TableChecksum reproduced)"
else
    echo "  FAIL: upcase-checksum (chain read) — see log"; rc=1
fi
# File readback: a hard gate when we seeded a file, informational otherwise.
if [ "$SEEDED" = "1" ]; then
    if strings "$LOG" | grep -q "^exfatr: file-read OK"; then
        echo "  PASS: seeded EXFTEST.BIN readback byte-exact (0x85/0xC0/0xC1 file-set read)"
    else
        echo "  FAIL: seeded file readback (no 'exfatr: file-read OK' in log)"; rc=1
    fi
elif strings "$LOG" | grep -q "^exfatr: file-read OK"; then
    echo "  PASS (bonus): seeded file readback byte-exact"
elif strings "$LOG" | grep -q "^exfatr: no seeded file"; then
    echo "  (info) no seeded file — file-set read path compiled, run EXFAT_SEED=1 to exercise it"
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "exFAT read smoke: PASS"; else echo "exFAT read smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
