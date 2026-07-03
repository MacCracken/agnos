#!/bin/bash
# hda-smoke — B0 acceptance for the 1.52.x audio arc. Boots a production AGNOS
# kernel in QEMU with a QEMU Intel HD-Audio controller (-device intel-hda) and
# asserts the boot-time HDA probe finds it and reads a sane GCAP.
#
# B0 is a read-only probe wired unconditionally into device-init (kernel/core/
# hda.cyr → hda_probe() in main.cyr), so NO build flag is needed — a normal
# ./scripts/build.sh kernel already carries it. The probe prints during
# device-init, well before kybernet/agnsh, so this needs only an ESP with
# BOOTX64.EFI + the kernel (no ext2 rootfs / no /bin binary).
#
# QEMU's intel-hda is the Intel ICH6 model (PCI 8086:2668, GCAP=0x4401 →
# OSS=4 ISS=4 v1.0). On archaemenid the real controller is 1022:15e3 (AMD
# Ryzen HD Audio, codec ALC897) — that path is IRON-only (B2+). This smoke
# gates the controller-probe transport, not codec routing.
#
# Build first:  ./scripts/build.sh   (and gnoboot's BOOTX64.EFI)
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk dd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/hda-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-hda.img"; SER="$WORK/serial.log"

echo "=== building ESP-only boot image (BOOTX64.EFI + kernel) ==="
dd if=/dev/zero of="$IMG" bs=1M count=48 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 47MiB set 1 esp on
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SER"

KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"

# Dwell long enough to boot to device-init, then let `timeout` SIGTERM QEMU.
# Running synchronously under `timeout` (no background/poll/kill) avoids the
# serial-file flush race — the file is fully written once QEMU has exited.
DWELL=30; [ -e /dev/kvm ] || DWELL=60
echo "=== booting QEMU with -device intel-hda ($( [ -e /dev/kvm ] && echo KVM || echo TCG ), ${DWELL}s dwell) ==="
timeout "$DWELL" qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-HDA" \
    -device "intel-hda,id=hda0" \
    -serial "file:$SER" -display none -no-reboot >/dev/null 2>&1 || true
sync

echo ""
echo "=== verdict ==="
rc=0
# -a: the serial carries OVMF/fb-console ANSI control bytes, so grep treats it
# as binary and won't print matches without it.
HDA_LINE="$(grep -a -m1 "hda: found" "$SER" 2>/dev/null)"
if [ -n "$HDA_LINE" ]; then
    echo "  probe: $HDA_LINE"
    OSS="$(echo "$HDA_LINE" | sed -n 's/.*OSS=\([0-9][0-9]*\).*/\1/p')"
    if [ -n "$OSS" ] && [ "$OSS" -ge 1 ]; then
        echo "  PASS: HDA controller probed, OSS=$OSS (>=1) — B0 gate met"
    else
        echo "  FAIL: HDA found but OSS=<$OSS> (<1, no output streams)"; rc=1
    fi
else
    echo "  FAIL: no 'hda: found' line (probe did not bind the controller)"
    grep -a -m1 "hda: no controller found" "$SER" 2>/dev/null && echo "  (probe ran but found no controller — check -device intel-hda)"
    rc=1
fi
echo "  --- hda lines from serial ---"
grep -a -iE "^hda:" "$SER" 2>/dev/null | sed 's/^/    /'
echo "  full serial: $SER"
exit $rc
