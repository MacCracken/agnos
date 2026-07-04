#!/bin/bash
# snd-smoke — Gate 2 (B6) acceptance for the ring-3 snd_* syscall band (#64-69).
# Builds the kernel with SND_SELFTEST=1 (hda_snd_selftest drives the #64-69 HANDLERS
# via ksyscall — open/config/avail/close + ownership/counter logic — and fills the
# ring with a 375 Hz square via snd_copy_frames), boots it in QEMU with a wav-capture
# audiodev, and asserts: (1) the serial "snd: selftest PASS" marker (the handler +
# counter logic is correct), and (2) the captured audio is non-silent (the band's
# ring bytes actually reached DMA -> stream -> codec DAC).
#
# The snd_write#66 user-buffer path (is_user_range + a4 + sti-window) follows the
# proven net-band template and gets its real ring-3 exercise from cyrius-doom (B7).
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

echo "=== building kernel with SND_SELFTEST=1 ==="
SND_SELFTEST=1 "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "ERROR: SND_SELFTEST build failed"; exit 1; }

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }

WORK="$ROOT/build/snd-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-snd.img"; SER="$WORK/serial.log"; WAV="$WORK/out.wav"

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
if grep -a -q "snd: selftest PASS" "$SER" 2>/dev/null; then
    grep -a "snd: avail" "$SER" 2>/dev/null | head -1 | sed 's/^/  band: /'
    echo "  PASS: snd_* handler + counter logic OK (open/config/avail/close, ownership, wrap-copy)"
else
    echo "  FAIL: 'snd: selftest PASS' marker absent — a #64-69 handler / counter check failed"; rc=1
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
    # The selftest fills the ring with a 375 Hz square (amp 10000) the DMA loops.
    if python3 -c "import sys; sys.exit(0 if float('$RMS' or 0) > 500 else 1)" 2>/dev/null; then
        echo "  PASS: captured audio non-silent (RMS=$RMS > 500) — the band's ring bytes reached the DAC"
    else
        echo "  FAIL: captured audio silent (RMS=$RMS) — ring tone did not reach output"; rc=1
    fi
fi

echo "  --- snd/hda lines ---"; grep -a -iE "^snd:|^hda:" "$SER" 2>/dev/null | sed 's/^/    /'
echo "  full serial: $SER"
exit $rc
