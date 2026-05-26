#!/bin/bash
# Interactive-lockup reproduction harness (1.33.4 cycle).
#
# Boots the PRODUCTION agnos kernel via gnoboot + OVMF in QEMU with a real
# USB keyboard (qemu-xhci + usb-kbd) and drives the interactive shell with
# automated keystrokes (QEMU `send-key` over QMP), hammering the same input
# loop (shell.cyr:864 `kb_has_key()`→`hid_poll()` + `arch_wait()`) that froze
# mid-`echo hell` on iron at 1.33.3 (photo 1333_issue_shown).
#
# Lockup detector: every command is an `uptime`, which prints the live
# `timer_ticks`. As long as the count keeps RISING across sends, the timer
# ISR + hlt-wake loop is alive. A freeze = the serial log stops growing while
# we keep sending keys. The driver records the last tick value + serial tail.
#
# This is a DIAGNOSTIC harness, not a pass/fail CI gate — it runs for a
# configurable wall-clock budget and reports whether it reproduced the hang.
#
# Usage:   sh scripts/lockup-repro.sh [DURATION_SECONDS]   (default 120)
# Requires: qemu-system-x86_64, OVMF, python3, parted, mtools, sgdisk,
#           mkfs.ext2. gnoboot at ../gnoboot/build/BOOTX64.EFI. agnos built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
DURATION="${1:-120}"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
    [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }
done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 python3 parted mformat mmd mcopy sgdisk mkfs.ext2; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/lockup-repro"
rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Real default-mkfs.ext4 profile (matches iron agnos-fs), so the boot FS
# mount path mirrors the iron sequence in the 1333 photo.
FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,metadata_csum,64bit,extent,^uninit_bg}"
echo "Building boot image (mkfs -O $FEATURES)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "agnos 1.33.4 lockup repro" > "$SEED/hello.txt"
echo "welcome to agnos"        > "$SEED/welcome.txt"
mkdir -p "$SEED/agnos"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L agnos-fs -b 4096 -m 0 \
    -O "$FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "Launching QEMU + driving keystrokes for ${DURATION}s..."
exec python3 "$ROOT/scripts/lockup-driver.py" \
    --image "$IMG" --ovmf-code "$OVMF_CODE" --ovmf-vars "$WORK/vars.fd" \
    --serial "$WORK/serial.log" --qmp "$WORK/qmp.sock" --duration "$DURATION"
