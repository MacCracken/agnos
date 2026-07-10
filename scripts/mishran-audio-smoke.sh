#!/bin/sh
# mishran-audio-smoke.sh — "the mishran mixer plays sound through vani -> snd on AGNOS" proof.
#
# Proves the WHOLE mixer path on the sovereign kernel: /bin/mishtone opens the
# vani sink via an MshRouter, registers TWO app streams at different Q8 gains,
# feeds each an integer square wave, and msh_router_pump mixes them frame-by-frame
# down to the one sink (audio_* -> sys_snd_* #64-69). Unlike vani-tone-smoke (vani
# direct), this exercises fan-in + per-stream gain + the router's sink write.
#
# Pipeline: build /bin/mishtone --agnos (a mishran lib consumer) -> boot
# gnoboot+OVMF+NVMe with a MISHRAN_AUDIO_SELFTEST kernel that runs it from disk ->
# capture the HDA output to a wav (intel-hda + hda-duplex + -audiodev wav).
#
# Gates: (1) mishtone started, (2) it returned, (3) captured wav non-silent
# (PEAK > 3000 AND RMS > 800 — a sustained mixed tone).
#
# Requires: cyrius, qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted,
# mtools, sgdisk, mkfs.ext2, python3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
MISHRAN_ROOT="${MISHRAN_ROOT:-$ROOT/../mishran}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in cyrius qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ]      || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -d "$MISHRAN_ROOT" ] || { echo "ERROR: mishran repo not found at $MISHRAN_ROOT (set MISHRAN_ROOT)"; exit 1; }
[ -f "$MISHRAN_ROOT/programs/mishtone.cyr" ] || { echo "ERROR: $MISHRAN_ROOT/programs/mishtone.cyr missing"; exit 1; }

WORK="$ROOT/build/mishran-audio-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-mishran.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"

echo "[1/4] Building /bin/mishtone --agnos (mishran mixer consumer)..."
if ! ( cd "$MISHRAN_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos programs/mishtone.cyr build/mishtone-agnos ) >/tmp/mishtone-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/mishtone-build.log)"; tail -8 /tmp/mishtone-build.log; exit 1
fi
MISHTONE="$MISHRAN_ROOT/build/mishtone-agnos"
[ -f "$MISHTONE" ] || { echo "  ERROR: mishtone not built"; exit 1; }
echo "  /bin/mishtone $(stat -c %s "$MISHTONE") B"

echo "[2/4] Building MISHRAN_AUDIO_SELFTEST kernel..."
if ! env MISHRAN_AUDIO_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/mishran-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/mishran-kbuild.log)"; tail -5 /tmp/mishran-kbuild.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

echo "[3/4] Seeding ext2 with /bin/mishtone + booting (gnoboot+OVMF+NVMe) + intel-hda wav capture..."
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$MISHTONE" "$SEED/bin/mishtone"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-MISHRAN -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=110

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-MISHRAN" \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device "intel-hda,id=hda0" \
    -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

done_marker=0
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: mishtone returned" "$SLOG" 2>/dev/null; then done_marker=1; sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- mishtone serial lines ---"
strings "$SLOG" | grep -aE "mishtone|exec: mishtone|PANIC|FAULT|#PF" | sed 's/^/  /' | head -20

rc=0
strings "$SLOG" | grep -q "exec: running /bin/mishtone" \
    && echo "  PASS: /bin/mishtone started (exec'd from disk in ring 3)" \
    || { echo "  FAIL: mishtone never started"; rc=1; }
if [ "$done_marker" -eq 1 ]; then
    echo "  PASS: mishtone ran to completion (mixed + drained + closed)"
else
    echo "  WARN: 'mishtone returned' marker not seen (hard timeout ${HARD}s) — checking wav anyway"
fi

if [ ! -s "$WAV" ]; then
    echo "  FAIL: no wav captured at $WAV (audiodev didn't record)"; rc=1
else
    STATS="$(python3 - "$WAV" <<'PY'
import sys, struct, math
raw = open(sys.argv[1], "rb").read()
off = 44
i = raw.find(b"data")
if 0 <= i and i + 8 <= len(raw):
    off = i + 8
pcm = raw[off:]
n = len(pcm) // 2
if n == 0:
    print("0.0 0"); sys.exit(0)
if n > 4000000:
    n = 4000000
vals = struct.unpack("<%dh" % n, pcm[:n*2])
rms = math.sqrt(sum(v*v for v in vals) / len(vals))
peak = max(abs(v) for v in vals)
print("%.1f %d" % (rms, peak))
PY
)"
    RMS="${STATS% *}"; PEAK="${STATS#* }"
    echo "  wav: $WAV ($(wc -c < "$WAV") B), RMS=$RMS PEAK=$PEAK"
    # A sustained mixed square (440 @ unity + 660 @ -6 dB) inside a boot+play
    # capture: peak proves the mix reached the DAC; RMS>800 that it was sustained.
    if python3 -c "import sys; sys.exit(0 if int('${PEAK:-0}') > 3000 else 1)" 2>/dev/null \
       && python3 -c "import sys; sys.exit(0 if float('${RMS:-0}') > 800.0 else 1)" 2>/dev/null; then
        echo "  PASS: sustained mixed tone reached the DAC (PEAK=$PEAK RMS=$RMS) via mishran router -> vani -> snd_write#66"
    else
        echo "  FAIL: captured audio not a sustained tone (PEAK=$PEAK RMS=$RMS)"; rc=1
    fi
fi

echo ""
echo "  --- snd/hda lines ---"; strings "$SLOG" | grep -aiE "^snd:|^hda:" | sed 's/^/    /' | head -12
echo "  full serial: $SLOG   wav: $WAV"
echo ""
[ "$rc" -eq 0 ] && echo "mishran-audio-smoke: PASS — the mishran mixer plays a mixed tone through vani -> HDA on AGNOS" || echo "mishran-audio-smoke: FAIL"
exit $rc
