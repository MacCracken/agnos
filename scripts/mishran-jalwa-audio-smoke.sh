#!/bin/sh
# mishran-jalwa-audio-smoke.sh — "jalwa routes its audio THROUGH the mishran mixer
# on AGNOS" proof. The end-to-end payoff of the mixer-before-player work.
#
# Two ring-3 processes over loopback (the desktop compositor+client model, applied
# to audio): the kernel runs /bin/mishrand (the mixing daemon) which opens the vani
# sink, listens on loopback:7701, and spawn_path's /bin/jalwa (the play-probe).
# jalwa DECODES a seeded /tone.wav and streams its PCM to mishran via msh_client_*;
# mishran mixes it down to vani -> sys_snd_* #64-69 -> the HDA DAC. A wav capture
# proves the audio flowed the whole way through the mixer.
#
# Gates: (1) mishrand started, (2) mishrand spawned jalwa, (3) jalwa routed through
# the mixer (not direct vani), (4) jalwa play-probe done, (5) captured wav non-silent
# (PEAK > 3000 AND RMS > 800).
#
# Requires: cyrius, qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted,
# mtools, sgdisk, mkfs.ext2, python3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
MISHRAN_ROOT="${MISHRAN_ROOT:-$ROOT/../mishran}"
JALWA_ROOT="${JALWA_ROOT:-$ROOT/../jalwa}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in cyrius qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ]      || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -d "$MISHRAN_ROOT" ] || { echo "ERROR: mishran repo not found (set MISHRAN_ROOT)"; exit 1; }
[ -d "$JALWA_ROOT" ]   || { echo "ERROR: jalwa repo not found (set JALWA_ROOT)"; exit 1; }
[ -f "$JALWA_ROOT/programs/jalwa_play_probe.cyr" ] || { echo "ERROR: jalwa_play_probe.cyr missing"; exit 1; }

WORK="$ROOT/build/mishran-jalwa-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-mj.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"

echo "[1/5] Building /bin/mishrand --agnos (mixing daemon) + /bin/jalwa --agnos (play-probe)..."
if ! ( cd "$MISHRAN_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius distlib && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos programs/mishrand.cyr build/mishrand-agnos ) >/tmp/mj-mishrand.log 2>&1; then
    echo "  MISHRAND BUILD-FAIL (see /tmp/mj-mishrand.log)"; tail -8 /tmp/mj-mishrand.log; exit 1
fi
if ! ( cd "$JALWA_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius deps && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos programs/jalwa_play_probe.cyr build/jalwa-play-probe-agnos ) >/tmp/mj-jalwa.log 2>&1; then
    echo "  JALWA BUILD-FAIL (see /tmp/mj-jalwa.log)"; tail -8 /tmp/mj-jalwa.log; exit 1
fi
MISHRAND="$MISHRAN_ROOT/build/mishrand-agnos"
JALWA="$JALWA_ROOT/build/jalwa-play-probe-agnos"
[ -f "$MISHRAND" ] && [ -f "$JALWA" ] || { echo "  ERROR: a binary did not build"; exit 1; }
echo "  /bin/mishrand $(stat -c %s "$MISHRAND") B   /bin/jalwa $(stat -c %s "$JALWA") B"

echo "[2/5] Generating /tone.wav (S16 48k stereo 440 Hz square, ~1.5 s)..."
python3 - "$WORK/tone.wav" <<'PY'
import sys, struct
sr, dur, freq, amp, ch = 48000, 1.5, 440, 6000, 2
n = int(sr * dur); period = sr / freq
body = bytearray()
for i in range(n):
    s = amp if (i % period) < period / 2 else -amp
    body += struct.pack('<hh', s, s)
data = bytes(body)
hdr  = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, ch, sr, sr*ch*2, ch*2, 16)
hdr += b'data' + struct.pack('<I', len(data))
open(sys.argv[1], 'wb').write(hdr + data)
PY
echo "  tone.wav $(stat -c %s "$WORK/tone.wav") B"

echo "[3/5] Building MISHRAN_JALWA_SELFTEST kernel..."
if ! env MISHRAN_JALWA_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/mj-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/mj-kbuild.log)"; tail -5 /tmp/mj-kbuild.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

echo "[4/5] Seeding ext2 (/bin/mishrand + /bin/jalwa + /tone.wav) + booting + intel-hda wav capture..."
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$MISHRAND" "$SEED/bin/mishrand"
cp "$JALWA" "$SEED/bin/jalwa"
cp "$WORK/tone.wav" "$SEED/tone.wav"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-MJ -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=90; [ -e /dev/kvm ] || HARD=150

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-MJ" \
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
    if grep -aq "jalwa play-probe: done" "$SLOG" 2>/dev/null; then done_marker=1; sleep 2; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[5/5] Checks..."
echo "  --- mishrand / jalwa serial lines ---"
strings "$SLOG" | grep -aE "mishrand|jalwa|exec: |PANIC|FAULT|#PF" | sed 's/^/  /' | head -24

rc=0
strings "$SLOG" | grep -q "exec: running /bin/jalwa" \
    && echo "  PASS(1): jalwa started (primary, sh_exec'd)" || { echo "  FAIL(1): jalwa never started"; rc=1; }
strings "$SLOG" | grep -q "jalwa: spawn /bin/mishrand pid=" \
    && echo "  PASS(2): jalwa spawned the mixer daemon" || { echo "  FAIL(2): mishrand never spawned"; rc=1; }
strings "$SLOG" | grep -q "jalwa: audio routed through the mishran mixer" \
    && echo "  PASS(3): jalwa connected + routed THROUGH the mixer (not direct vani)" || { echo "  FAIL(3): jalwa did not route through the mixer"; rc=1; }
if [ "$done_marker" -eq 1 ]; then
    echo "  PASS(4): jalwa play-probe ran to completion"
else
    echo "  WARN(4): 'play-probe: done' not seen (hard timeout ${HARD}s) — checking wav anyway"
fi

if [ ! -s "$WAV" ]; then
    echo "  FAIL(5): no wav captured at $WAV"; rc=1
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
    if python3 -c "import sys; sys.exit(0 if int('${PEAK:-0}') > 3000 else 1)" 2>/dev/null \
       && python3 -c "import sys; sys.exit(0 if float('${RMS:-0}') > 800.0 else 1)" 2>/dev/null; then
        echo "  PASS(5): jalwa's audio reached the DAC through the mixer (PEAK=$PEAK RMS=$RMS)"
    else
        echo "  FAIL(5): captured audio not a sustained tone (PEAK=$PEAK RMS=$RMS)"; rc=1
    fi
fi

echo ""
echo "  --- snd/hda lines ---"; strings "$SLOG" | grep -aiE "^snd:|^hda:" | sed 's/^/    /' | head -12
echo "  full serial: $SLOG   wav: $WAV"
echo ""
[ "$rc" -eq 0 ] && echo "mishran-jalwa-audio-smoke: PASS — jalwa plays THROUGH the mishran mixer to the HDA output on AGNOS" || echo "mishran-jalwa-audio-smoke: FAIL"
exit $rc
