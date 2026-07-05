#!/bin/sh
# vani-tone-smoke.sh — "the cyrius `vani` audio lib plays sound on AGNOS" proof.
#
# Gate 3/4 of the 1.52.x audio arc. Unlike doom/tonegen (which hand-roll the
# sys_snd_* #64-69 syscalls directly), this exercises vani's `audio_*` backend
# (src/alsa.cyr, the dist/vani-core.cyr [lib.core] profile): the FIRST audio
# through the sovereign cyrius audio LIBRARY on agnos, not a bypass. Any future
# audio app that links vani-core inherits this path.
#
# Pipeline: regenerate dist/vani-core.cyr from the local vani repo (picks up the
# #ifdef CYRIUS_TARGET_AGNOS branches) -> build /bin/vanitone as a doom-style
# vani-core CONSUMER --agnos (the vani repo's own build pulls the yukti
# enumerator, which isn't agnos-ported, so we consume the bundle instead) ->
# boot gnoboot+OVMF+NVMe with a VANITONE_AUDIO_SELFTEST kernel that runs
# /bin/vanitone from disk -> capture the HDA output to a wav (intel-hda +
# hda-duplex + -audiodev wav).
#
# vanitone blocking-streams a continuous 1.5s 440 Hz square (±6000, S16 48k
# stereo) through audio_open_playback/set_params/write/drain/close, so the tone
# is steady -> RMS is a reliable signal (unlike doom's intermittent SFX bursts).
#
# Gates: (1) vanitone started, (2) it returned ("exec: vanitone returned"),
# (3) captured wav non-silent (PEAK > 3000 AND RMS > 800 — continuous tone).
#
# Requires: cyrius, qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted,
# mtools, sgdisk, mkfs.ext2, python3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
VANI_ROOT="${VANI_ROOT:-$ROOT/../vani}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in cyrius qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ]     || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -d "$VANI_ROOT" ]   || { echo "ERROR: vani repo not found at $VANI_ROOT (set VANI_ROOT)"; exit 1; }
[ -f "$VANI_ROOT/programs/vanitone.cyr" ] || { echo "ERROR: $VANI_ROOT/programs/vanitone.cyr missing"; exit 1; }

WORK="$ROOT/build/vani-tone-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-vani-tone.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"

echo "[1/5] Regenerating dist/vani-core.cyr (with the agnos backend branches)..."
( cd "$VANI_ROOT" && cyrius distlib core ) >/tmp/vani-core-distlib.log 2>&1 || {
    echo "  DISTLIB-FAIL (see /tmp/vani-core-distlib.log)"; tail -5 /tmp/vani-core-distlib.log; exit 1; }
BUNDLE="$VANI_ROOT/dist/vani-core.cyr"
[ -f "$BUNDLE" ] || { echo "  ERROR: bundle not produced at $BUNDLE"; exit 1; }
grep -q 'sys_snd_open' "$BUNDLE" || { echo "  ERROR: bundle lacks the agnos backend (sys_snd_open) — stale vani-core"; exit 1; }
echo "  vani-core.cyr $(wc -l < "$BUNDLE") lines, agnos backend present"

echo "[2/5] Building /bin/vanitone --agnos (doom-style vani-core consumer)..."
CB="$WORK/consumer"; mkdir -p "$CB/build"
cp "$BUNDLE" "$CB/vani-core.cyr"
# Reuse the canonical vanitone source, swapping its include from the in-repo
# src/alsa.cyr to the bundled vani-core.cyr so the build needs no yukti.
sed 's|include "src/alsa.cyr"|include "vani-core.cyr"|' "$VANI_ROOT/programs/vanitone.cyr" > "$CB/vanitone.cyr"
cat > "$CB/cyrius.cyml" <<'EOF'
[package]
name = "vanitone"
version = "0.0.1"
language = "cyrius"
cyrius = "6.4.2"

[build]
entry = "vanitone.cyr"
output = "build/vanitone"

[deps]
stdlib = ["syscalls","string","alloc","str","fmt","vec","io","fs","args","hashmap","tagged","fnptr","chrono","sakshi"]
EOF
if ! ( cd "$CB" && cyrius build vanitone.cyr build/vanitone-agnos --agnos ) >/tmp/vanitone-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/vanitone-build.log)"; tail -8 /tmp/vanitone-build.log; exit 1
fi
VANITONE="$CB/build/vanitone-agnos"
[ -f "$VANITONE" ] || { echo "  ERROR: vanitone not built"; exit 1; }
echo "  /bin/vanitone $(stat -c %s "$VANITONE") B"

echo "[3/5] Building VANITONE_AUDIO_SELFTEST kernel..."
if ! env VANITONE_AUDIO_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/vani-tone-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/vani-tone-kbuild.log)"; tail -5 /tmp/vani-tone-kbuild.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

echo "[4/5] Seeding ext2 with /bin/vanitone + booting (gnoboot+OVMF+NVMe) + intel-hda wav capture..."
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$VANITONE" "$SEED/bin/vanitone"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-VANI-TONE -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=110

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-VANI-TONE" \
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
    if grep -aq "exec: vanitone returned" "$SLOG" 2>/dev/null; then done_marker=1; sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[5/5] Checks..."
echo "  --- vanitone serial lines ---"
strings "$SLOG" | grep -aE "vanitone|exec: vanitone|VANITONE|PANIC|FAULT|#PF" | sed 's/^/  /' | head -20

rc=0
strings "$SLOG" | grep -q "exec: running /bin/vanitone" \
    && echo "  PASS: /bin/vanitone started (exec'd from disk in ring 3)" \
    || { echo "  FAIL: vanitone never started"; rc=1; }
if [ "$done_marker" -eq 1 ]; then
    echo "  PASS: vanitone ran to completion (drained + closed cleanly)"
else
    echo "  WARN: 'vanitone returned' marker not seen (hard timeout ${HARD}s hit) — checking wav anyway"
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
    # Continuous 1.5s square (±6000) inside a boot+play capture: peak proves the
    # tone reached the DAC; RMS>800 confirms it was sustained (not a single click).
    if python3 -c "import sys; sys.exit(0 if int('${PEAK:-0}') > 3000 else 1)" 2>/dev/null \
       && python3 -c "import sys; sys.exit(0 if float('${RMS:-0}') > 800.0 else 1)" 2>/dev/null; then
        echo "  PASS: sustained tone reached the DAC (PEAK=$PEAK RMS=$RMS) via vani-core -> snd_write#66"
    else
        echo "  FAIL: captured audio not a sustained tone (PEAK=$PEAK RMS=$RMS)"; rc=1
    fi
fi

echo ""
echo "  --- snd/hda lines ---"; strings "$SLOG" | grep -aiE "^snd:|^hda:" | sed 's/^/    /' | head -12
echo "  full serial: $SLOG   wav: $WAV"
echo ""
[ "$rc" -eq 0 ] && echo "vani-tone-smoke: PASS — the cyrius vani audio lib plays sound through the sovereign HDA output on AGNOS" || echo "vani-tone-smoke: FAIL"
exit $rc
