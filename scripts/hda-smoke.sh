#!/bin/bash
# hda-smoke — B0/B1/B2 acceptance for the 1.52.x audio arc. Boots a production
# AGNOS kernel in QEMU with a QEMU Intel HD-Audio controller (-device intel-hda)
# + an attached codec (hda-duplex) and asserts: (B0) the boot-time HDA probe
# finds the controller and reads a sane GCAP; (B1) the CRST reset handshake
# completes and STATESTS reports the codec present; (B2a) the CORB/RIRB verb
# ring round-trips consecutive verbs (VENDOR_ID + NODECOUNT); (B2b-1) the AFG
# widget walk classifies DAC/Pin and dumps each output pin's CONFIG_DEFAULT.
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
    -audiodev "none,id=snd0" \
    -device "intel-hda,id=hda0" \
    -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
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

# B1 — reset handshake + codec presence (STATESTS). Needs the hda-duplex codec
# attached above; without it STATESTS=0 and codecs=0x0000 (correct-but-empty).
RST_LINE="$(grep -a -m1 "hda: reset OK, codecs=0x" "$SER" 2>/dev/null)"
if [ -n "$RST_LINE" ]; then
    echo "  reset: $RST_LINE"
    CODECS="$(echo "$RST_LINE" | sed -n 's/.*codecs=0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')"
    if [ -n "$CODECS" ] && [ "$CODECS" != "0000" ]; then
        echo "  PASS: codec present, codecs=0x$CODECS — B1 gate met"
    else
        echo "  FAIL: reset ran but no codec present (codecs=0x$CODECS)"; rc=1
    fi
else
    echo "  FAIL: no 'hda: reset OK' line (reset handshake failed)"
    grep -a -m1 "hda: reset FAIL" "$SER" 2>/dev/null
    grep -a -m1 "hda: reset WARN" "$SER" 2>/dev/null
    rc=1
fi

# B2a — CORB/RIRB verb-ring transport (codec VENDOR_ID / NODECOUNT round-trip).
# ("hda: codec[0-9]" avoids matching the B1 "codecs=" reset line.)
CDC_LINE="$(grep -a -m1 "hda: codec[0-9]" "$SER" 2>/dev/null)"
if [ -n "$CDC_LINE" ]; then
    echo "  codec: $CDC_LINE"
    VID="$(echo "$CDC_LINE" | sed -n 's/.*vendor=0x\([0-9A-Fa-f]*\).*/\1/p')"
    NODES="$(echo "$CDC_LINE" | sed -n 's/.*nodes=\([0-9][0-9]*\).*/\1/p')"
    if [ -z "$VID" ] || [ "$VID" = "0" ] || [ "$VID" = "00000000" ]; then
        echo "  FAIL: codec line but bad vendor (0x$VID)"; rc=1
    elif [ -z "$NODES" ] || [ "$NODES" -lt 1 ] || [ "$NODES" -ge 100 ]; then
        # nodes==255 is the '2nd verb timed out (-1 & 0xFF)' signature — guards
        # the RINTCNT/RIRBSTS consecutive-verb fix from regressing.
        echo "  FAIL: 2nd verb bad (nodes=$NODES; 255 = timeout regression)"; rc=1
    else
        echo "  PASS: verb ring round-trip OK (consecutive verbs), vendor=0x$VID nodes=$NODES — B2a gate met"
    fi
else
    echo "  FAIL: no 'hda: codec' line (verb-ring round-trip failed)"
    grep -a -m1 "hda: WARN codec verb" "$SER" 2>/dev/null
    grep -a -m1 -E "hda: (CORB|RIRB) alloc" "$SER" 2>/dev/null
    rc=1
fi

# B2b-1 — widget enumeration + per-output-pin CONFIG_DEFAULT dump (the iron
# pre-flight probe). QEMU's trivial codec has 1 DAC + 1 output pin.
AFG_LINE="$(grep -a -m1 "hda: afg 0x" "$SER" 2>/dev/null)"
if [ -n "$AFG_LINE" ]; then
    echo "  enum: $AFG_LINE"
    DACS="$(echo "$AFG_LINE" | sed -n 's/.*dacs=\([0-9][0-9]*\).*/\1/p')"
    OUTPINS="$(echo "$AFG_LINE" | sed -n 's/.*outpins=\([0-9][0-9]*\).*/\1/p')"
    if [ -n "$DACS" ] && [ "$DACS" -ge 1 ] && [ -n "$OUTPINS" ] && [ "$OUTPINS" -ge 1 ]; then
        echo "  PASS: AFG walk OK, dacs=$DACS outpins=$OUTPINS — B2b-1 gate met"
    else
        echo "  FAIL: AFG walk but dacs=$DACS outpins=$OUTPINS (need >=1 each)"; rc=1
    fi
    grep -a "hda: pin 0x" "$SER" 2>/dev/null | sed 's/^/    pin-dump: /'
else
    echo "  FAIL: no 'hda: afg' line (widget walk failed)"
    grep -a -m1 "hda: no AFG found" "$SER" 2>/dev/null
    rc=1
fi

# B2b-2 — pin select + DAC trace + output-enable machinery (ALC897 amp/EAPD/COEF
# effects are iron-only; QEMU validates that select/trace/enable RUN without fault).
ROUTE_LINE="$(grep -a -m1 "hda: route pin=0x" "$SER" 2>/dev/null)"
if [ -n "$ROUTE_LINE" ] && grep -aq "hda: output path enabled" "$SER" 2>/dev/null; then
    echo "  route: $ROUTE_LINE"
    echo "  PASS: pin-select + DAC-trace + output-enable ran — B2b-2 gate met (ALC897 effects iron-only)"
else
    echo "  FAIL: output path not enabled"
    grep -a -m1 -E "hda: no output pin|hda: no DAC for pin" "$SER" 2>/dev/null
    rc=1
fi

echo "  --- hda lines from serial ---"
grep -a -iE "^hda:" "$SER" 2>/dev/null | sed 's/^/    /'
echo "  full serial: $SER"
exit $rc
