#!/bin/bash
# hda-tone-smoke — B4 acceptance for the 1.52.x audio arc. Builds the kernel with
# HDA_TONE=1 (hda_stream_arm fills the PCM ring with a ~375 Hz triangle instead of
# silence), boots it in QEMU with a wav-capture audiodev, and asserts the captured
# audio is non-silent (RMS > 0) — i.e. the tone actually flowed DMA -> stream ->
# codec DAC -> output. This is the automated half of "first sound from sovereign
# agnos"; the archaemenid front jack is the real (iron) half.
#
# QEMU's intel-hda + hda-duplex codec + -audiodev wav captures whatever the bound
# output stream plays into out.wav. On iron the same HDA_TONE kernel drives the
# ALC897 front jack (audible).
#
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools, python3.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk dd python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "=== building kernel with HDA_TONE=1 ==="
HDA_TONE=1 "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "ERROR: HDA_TONE build failed"; exit 1; }

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }

WORK="$ROOT/build/hda-tone-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-tone.img"; SER="$WORK/serial.log"; WAV="$WORK/out.wav"

echo "=== building ESP-only boot image ==="
dd if=/dev/zero of="$IMG" bs=1M count=48 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 47MiB set 1 esp on >/dev/null 2>&1
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SER"

KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"

DWELL=30; [ -e /dev/kvm ] || DWELL=60
echo "=== booting QEMU (-audiodev wav capture, ${DWELL}s dwell) ==="
timeout "$DWELL" qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-TONE" \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device "intel-hda,id=hda0" \
    -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
    -serial "file:$SER" -display none -no-reboot >/dev/null 2>&1 || true
sync

echo ""
echo "=== verdict ==="
rc=0
if grep -a -q "hda: tone 375Hz filled" "$SER" 2>/dev/null && grep -a -q "hda: stream running" "$SER" 2>/dev/null; then
    echo "  kernel: tone filled + stream running (LPIB advancing)"
else
    echo "  FAIL: kernel did not fill the tone / arm the stream"; rc=1
fi

if [ ! -s "$WAV" ]; then
    echo "  FAIL: no wav captured at $WAV (audiodev didn't record)"; rc=1
else
    RMS="$(python3 - "$WAV" <<'PY'
import sys, struct, math
raw = open(sys.argv[1], "rb").read()
# QEMU leaves the WAV header unfinalized when killed mid-capture, so don't trust
# the chunk sizes — locate the 'data' chunk (else skip the 44-byte header) and
# read the PCM as little-endian i16 directly.
off = 44
i = raw.find(b"data")
if 0 <= i and i + 8 <= len(raw):
    off = i + 8
pcm = raw[off:]
n = len(pcm) // 2
if n == 0:
    print("0.0"); sys.exit(0)
if n > 2000000:            # cap for speed
    n = 2000000
vals = struct.unpack("<%dh" % n, pcm[:n*2])
rms = math.sqrt(sum(v*v for v in vals) / len(vals))
print("%.1f" % rms)
PY
)"
    echo "  wav: $WAV ($(wc -c < "$WAV") B), RMS=$RMS"
    # A ~375 Hz triangle at amp 12000 has RMS ~6900; anything well above silence passes.
    if python3 -c "import sys; sys.exit(0 if float('$RMS' or 0) > 500 else 1)" 2>/dev/null; then
        echo "  PASS: captured audio is non-silent (RMS=$RMS > 500) — B4 gate met (first sound!)"
    else
        echo "  FAIL: captured audio is silent (RMS=$RMS) — tone did not reach output"; rc=1
    fi
fi
echo "  --- hda lines ---"; grep -a -iE "^hda:" "$SER" 2>/dev/null | sed 's/^/    /'
echo "  full serial: $SER"
exit $rc
