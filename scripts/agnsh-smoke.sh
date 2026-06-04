#!/bin/bash
# agnsh-smoke (1.41.4) — boots a PRODUCTION kernel against an ext2 rootfs that
# contains /bin/agnsh (the agnos-ABI build of the agnoshi shell). kybernet
# (PID 1) execs /bin/agnsh in ring 3 — the "first boot-to-agnsh-on-disk".
#
# PASS = kybernet reaches "exec /bin/agnsh" AND does NOT print "emergency
# shell" (i.e. agnsh launched, no fallback). Prints the boot tail for eyeball.
#
# Build first:  ./scripts/build.sh                       (plain production kernel)
# agnsh:        ../agnoshi/build/agnsh_agnos              (cyrius build --agnos ...)
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, strings.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built ($AGNSH) — 'cyrius build --agnos src/agnsh.cyr build/agnsh_agnos' in agnoshi"; exit 1; }

WORK="$ROOT/build/agnsh-smoke"; LOGS="$ROOT/build/agnsh-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-agnsh.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AGNSH" "$SEED/bin/agnsh"
echo "seeded /bin/agnsh ($(stat -c%s "$SEED/bin/agnsh") bytes)"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AGNSH -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/agnsh.log"
echo "Booting production kernel (NVMe + ext2 with /bin/agnsh)..."
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "kybernet: exec /bin/agnsh"; then
    echo "  PASS: kybernet attempted exec /bin/agnsh"
else
    echo "  FAIL: kybernet did not reach the agnsh exec"; rc=1
fi
if strings "$LOG" | grep -q "kybernet: emergency shell"; then
    echo "  FAIL: fell back to the in-kernel emergency shell (agnsh did not launch)"; rc=1
else
    echo "  PASS: did NOT fall back to the emergency shell"
fi
echo ""
if [ "$rc" -eq 0 ]; then echo "agnsh-smoke: PASS"; else echo "agnsh-smoke: FAIL"; fi
exit $rc
