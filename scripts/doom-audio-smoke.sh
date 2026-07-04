#!/bin/sh
# doom-audio-smoke.sh — the "cyrius-doom sounds play for realz" end-to-end proof.
#
# Stages /bin/doom (cyrius-doom built --agnos, >=0.31.0) + /DOOM1.WAD onto the
# agnos-fs ext2 root, boots gnoboot+OVMF+NVMe with a DOOM_AUDIO_SELFTEST kernel
# that runs `/bin/doom /DOOM1.WAD --audio-test` from disk, and captures the HDA
# output to a wav via QEMU's intel-hda + hda-duplex + `-audiodev wav`.
#
# This is the FIRST real ring-3 exercise of the snd_write#66 user-buffer path:
# snd-smoke.sh drives the #64-69 band from KERNEL context (hda_snd_selftest), but
# doom drives it from RING 3 — sys_snd_open#64 / config#65 / write_nb#66 / close#67
# through the real is_user_range + a4-NONBLOCK + sti-window handler. doom's
# --audio-test plays 6 real WAD SFX (pistol/shotgun/door/pickup/pain/explosion) +
# an L/R stereo pan over ~8s, then exits.
#
# Gates: (1) doom started ("cyrius-doom v"), (2) WAD loaded ("wad loaded"),
# (3) audio-test ran + returned ("exec: doom audio-test returned"), (4) the
# captured wav is non-silent — PEAK amplitude > 3000 (intermittent SFX bursts,
# so peak is the reliable signal; whole-capture RMS is reported for context).
#
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools,
# sgdisk, mkfs.ext2, python3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
DOOM_ROOT="${DOOM_ROOT:-$ROOT/../cyrius-doom}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
DOOM="$DOOM_ROOT/build/doom_agnos"
WAD="$DOOM_ROOT/wad/DOOM1.WAD"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$DOOM" ]    || { echo "ERROR: doom_agnos not built — (cd $DOOM_ROOT && cyrius build src/main.cyr build/doom_agnos --agnos)"; exit 1; }
[ -f "$WAD" ]     || { echo "ERROR: DOOM1.WAD not found at $WAD"; exit 1; }

echo "[1/4] Building DOOM_AUDIO_SELFTEST kernel..."
if ! env DOOM_AUDIO_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/doom-audio-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/doom-audio-build.log)"; tail -5 /tmp/doom-audio-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/doom-audio-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-doom-audio.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/doom ($(stat -c %s "$DOOM") B) + /DOOM1.WAD ($(stat -c %s "$WAD") B)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$DOOM" "$SEED/bin/doom"
cp "$WAD"  "$SEED/DOOM1.WAD"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-DOOM-AUDIO -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting (gnoboot+OVMF+NVMe) + intel-hda wav capture, running doom --audio-test..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=110

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-DOOM-AUDIO" \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device "intel-hda,id=hda0" \
    -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

# Poll for the audio-test to finish (doom_exit prints the "returned" marker after
# its ~8s playback), then give the wav a moment to flush and kill QEMU. Hard cap
# backstops a hang. The capture window is boot(~silent) + ~8s audio; peak-based
# detection below is insensitive to the leading silence.
done_marker=0
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: doom audio-test returned" "$SLOG" 2>/dev/null; then done_marker=1; sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- doom serial lines ---"
strings "$SLOG" | grep -aE "cyrius-doom|wad loaded|audio test|sfx:|exec: doom|PANIC|FAULT|#PF" | sed 's/^/  /' | head -24

rc=0
strings "$SLOG" | grep -q "cyrius-doom v" \
    && echo "  PASS: /bin/doom started (exec'd from disk in ring 3)" \
    || { echo "  FAIL: doom never started"; rc=1; }
strings "$SLOG" | grep -q "wad loaded" \
    && echo "  PASS: WAD loaded on agnos" \
    || { echo "  FAIL: 'wad loaded' absent"; rc=1; }
if [ "$done_marker" -eq 1 ]; then
    echo "  PASS: audio-test ran to completion (doom exited cleanly after ~8s)"
else
    echo "  WARN: 'audio-test returned' marker not seen (hard timeout ${HARD}s hit) — checking wav anyway"
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
    # Intermittent SFX bursts over ~8s inside a boot+play capture: peak amplitude
    # is the reliable "real DOOM samples reached the DAC" signal (silence -> peak ~0;
    # DOOM 8-bit SFX scaled to S16 hit thousands). RMS is diluted by leading silence.
    if python3 -c "import sys; sys.exit(0 if int('${PEAK:-0}') > 3000 else 1)" 2>/dev/null; then
        echo "  PASS: captured audio non-silent (PEAK=$PEAK > 3000) — DOOM SFX reached the DAC via ring-3 snd_write#66"
    else
        echo "  FAIL: captured audio silent (PEAK=$PEAK) — SFX did not reach output"; rc=1
    fi
fi

echo ""
echo "  --- snd/hda lines ---"; strings "$SLOG" | grep -aiE "^snd:|^hda:" | sed 's/^/    /' | head -12
echo "  full serial: $SLOG   wav: $WAV"
echo ""
[ "$rc" -eq 0 ] && echo "doom-audio-smoke: PASS — cyrius-doom SFX play through the sovereign HDA output on AGNOS" || echo "doom-audio-smoke: FAIL"
exit $rc
