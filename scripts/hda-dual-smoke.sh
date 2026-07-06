#!/bin/bash
# hda-dual-smoke — HDMI-audio arc bite 2b acceptance. Boots an AGNOS kernel built
# with HDA_HDMI=1 in QEMU with TWO -device intel-hda controllers (each with an
# attached hda-duplex codec) and asserts the multi-instance probe/enum machinery:
#   (instance 0) the analog controller still binds + its codec is present (no
#                regression from the single-instance driver);
#   (instance 1) the HDA_HDMI boot block probes the SECOND controller (skipping
#                instance 0's bound function), resets it, and enumerates its codec
#                — i.e. `hda: ctl1 bound codecs=0xNNNN afg=0xNN` with a present codec.
#
# QEMU's intel-hda is the Intel ICH6 model (8086:2668). On archaemenid instance 1
# is the AMD HDMI/DP function (04:00.1); both are class 04:03:00, so the driver
# distinguishes instance 1 as "the HDA-class controller that isn't instance 0's
# bound index". This smoke validates that machinery in QEMU; the real HDMI codec
# route (bite 3) is iron-only.
#
# Self-building: HDA_HDMI is a non-default flag, so this smoke rebuilds the kernel
# with it before booting (the ./scripts/build.sh default kernel does NOT carry it).
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

echo "=== building kernel with HDA_HDMI=1 (instance-1 probe/enum) ==="
HDA_HDMI=1 "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "ERROR: HDA_HDMI build failed"; exit 1; }
[ -f "$AGNOS" ] || { echo "ERROR: agnos not built"; exit 1; }

WORK="$ROOT/build/hda-dual-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
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

DWELL=30; [ -e /dev/kvm ] || DWELL=60
echo "=== booting QEMU with TWO -device intel-hda ($( [ -e /dev/kvm ] && echo KVM || echo TCG ), ${DWELL}s dwell) ==="
timeout "$DWELL" qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-HDA" \
    -audiodev "none,id=snd0" \
    -device "intel-hda,id=hda0" \
    -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
    -device "intel-hda,id=hda1" \
    -device "hda-duplex,bus=hda1.0,audiodev=snd0" \
    -serial "file:$SER" -display none -no-reboot >/dev/null 2>&1 || true
sync

echo ""
echo "=== verdict ==="
rc=0

# Instance 0 — the analog controller still binds + codec present (no regression).
HDA_LINE="$(grep -a -m1 "hda: found" "$SER" 2>/dev/null)"
RST_LINE="$(grep -a -m1 "hda: reset OK, codecs=0x" "$SER" 2>/dev/null)"
if [ -n "$HDA_LINE" ] && [ -n "$RST_LINE" ]; then
    CODECS0="$(echo "$RST_LINE" | sed -n 's/.*codecs=0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')"
    if [ -n "$CODECS0" ] && [ "$CODECS0" != "0000" ]; then
        echo "  instance0: $HDA_LINE / codecs=0x$CODECS0"
        echo "  PASS: instance 0 (analog) bound + codec present — no regression"
    else
        echo "  FAIL: instance 0 reset but no codec (codecs=0x$CODECS0)"; rc=1
    fi
else
    echo "  FAIL: instance 0 did not bind (no 'hda: found' / 'hda: reset OK')"; rc=1
fi

# The HDA_HDMI boot block ran (proves the gated instance-1 path is compiled + reached).
if grep -aq "hda: ctl1 probing 2nd controller" "$SER" 2>/dev/null; then
    echo "  PASS: HDA_HDMI instance-1 probe block ran"
else
    echo "  FAIL: no 'hda: ctl1 probing' line (HDA_HDMI block not reached — wrong build?)"; rc=1
fi

# Instance 1 — the SECOND controller was found, reset, and its codec enumerated.
CTL1_LINE="$(grep -a -m1 "hda: ctl1 bound codecs=0x" "$SER" 2>/dev/null)"
if [ -n "$CTL1_LINE" ]; then
    echo "  instance1: $CTL1_LINE"
    CODECS1="$(echo "$CTL1_LINE" | sed -n 's/.*codecs=0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')"
    AFG1="$(echo "$CTL1_LINE" | sed -n 's/.*afg=0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')"
    if [ -n "$CODECS1" ] && [ "$CODECS1" != "0000" ] && [ -n "$AFG1" ] && [ "$AFG1" != "00" ]; then
        echo "  PASS: instance 1 (2nd controller) probed + reset + codec enumerated (codecs=0x$CODECS1 afg=0x$AFG1)"
    else
        echo "  FAIL: instance 1 bound but codec/afg empty (codecs=0x$CODECS1 afg=0x$AFG1)"; rc=1
    fi
else
    if grep -aq "hda: ctl1 no 2nd controller" "$SER" 2>/dev/null; then
        echo "  FAIL: instance-1 probe found NO 2nd controller (both -device intel-hda should be present)"
    else
        echo "  FAIL: no 'hda: ctl1 bound' line (instance-1 probe/enum failed)"
    fi
    rc=1
fi

echo "  --- hda lines from serial ---"
grep -a -iE "^hda:" "$SER" 2>/dev/null | sed 's/^/    /'
echo "  full serial: $SER"
[ "$rc" -eq 0 ] && echo "hda-dual-smoke: PASS" || echo "hda-dual-smoke: FAIL"
exit $rc
