#!/bin/sh
# tonegen-smoke.sh — the agnos audio-PATH isolation test.
#
# Stages /bin/tonegen (agnos/audio-test, built --agnos) onto the agnos-fs ext2 root,
# boots gnoboot+OVMF+NVMe with a TONEGEN_SELFTEST kernel that runs `/bin/tonegen`
# from disk, and captures the HDA output to a wav via QEMU's intel-hda + hda-duplex.
#
# tonegen BLOCKING-streams clean generated waveforms (sine/square/saw/triangle + a
# sweep) through the snd_* band. Blocking writes are kernel-paced, so this exercises
# the ring/DAC PATH decoupled from any producer's timing — the missing rung between
# the kernel HDA_TONE (no ring 3) and cyrius-doom (non-blocking, mixer, WAD, game loop).
#
# Gates: tonegen started + returned, the wav is non-silent (PEAK), and the first
# sustained tone reads ~440 Hz (pitch correct) with no long silence gap (continuous).
#
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools, sgdisk,
# mkfs.ext2, python3, + cyrius (to build tonegen).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
TG_ROOT="$ROOT/audio-test"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3 cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building tonegen (--agnos) + the TONEGEN_SELFTEST kernel..."
( cd "$TG_ROOT" && cyrius build tonegen.cyr build/tonegen --agnos ) >/tmp/tonegen-build.log 2>&1 || { echo "  BUILD-FAIL (tonegen)"; tail -5 /tmp/tonegen-build.log; exit 1; }
if ! env TONEGEN_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/tonegen-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/tonegen-kbuild.log)"; tail -5 /tmp/tonegen-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
TG="$TG_ROOT/build/tonegen"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$TG" ]      || { echo "ERROR: tonegen not built at $TG"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/tonegen $(stat -c %s "$TG") B"

WORK="$ROOT/build/tonegen-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-tonegen.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/tonegen..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$TG" "$SEED/bin/tonegen"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-TONEGEN -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting + intel-hda wav capture, running /bin/tonegen..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=75; [ -e /dev/kvm ] || HARD=140
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-TONEGEN" \
    -audiodev "wav,id=snd0,path=$WAV" -device "intel-hda,id=hda0" -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
done_marker=0; i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: tonegen returned" "$SLOG" 2>/dev/null; then done_marker=1; sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- tonegen serial lines ---"
strings "$SLOG" | grep -aE "tonegen:|exec: tonegen|snd_open|PANIC|FAULT|#PF" | sed 's/^/  /' | head -16
rc=0
strings "$SLOG" | grep -q "tonegen: audio-path test" \
    && echo "  PASS: /bin/tonegen started (exec'd from disk in ring 3)" \
    || { echo "  FAIL: tonegen never started"; rc=1; }
[ "$done_marker" -eq 1 ] && echo "  PASS: tonegen ran to completion" || echo "  WARN: 'tonegen returned' marker not seen (hard timeout ${HARD}s)"

if [ ! -s "$WAV" ]; then
    echo "  FAIL: no wav captured at $WAV"; rc=1
else
    RES="$(python3 - "$WAV" <<'PY'
import sys, struct, math
raw = open(sys.argv[1], "rb").read()
i = raw.find(b"data"); off = i+8 if 0 <= i and i+8 <= len(raw) else 44
pcm = raw[off:]; n = len(pcm)//4
if n == 0: print("SILENT peak=0 freq=0 gap=1"); sys.exit(0)
if n > 6000000: n = 6000000
S = struct.unpack("<%dh" % (n*2), pcm[:n*4])
SR = 48000
mono = [(S[2*j]+S[2*j+1])//2 for j in range(n)]
peak = max(abs(v) for v in mono)
# locate the first sustained tone: first 1s window whose RMS is high
W = SR//100  # 10ms
env = [math.sqrt(sum(mono[k+j]*mono[k+j] for j in range(W))/W) for k in range(0, n-W, W)]
mx = max(env) if env else 0
# first index where energy is sustained (>= 0.4*peak-RMS for >= 30 windows)
thr = mx*0.4
start = 0
for idx in range(len(env)-30):
    if all(env[idx+q] > thr for q in range(30)): start = idx*W; break
# frequency of a 0.2s slice inside that tone via zero-crossings (of the AC-coupled signal)
seg = mono[start:start+SR//5]
if seg:
    m = sum(seg)/len(seg)
    zc = 0
    prev = seg[0]-m
    for v in seg:
        cur = v-m
        if (prev <= 0 and cur > 0): zc += 1
        prev = cur
    freq = zc * 5  # zero-up-crossings in 0.2s -> Hz
else:
    freq = 0
# continuity: any 30ms silence gap *within* the sustained region (start..start+1.8s)?
gap = 0
region = env[start//W: start//W + 180]
run = 0
for e in region:
    if e < mx*0.05: run += 1
    else: run = 0
    if run >= 3: gap = 1
print(f"peak={peak} freq={freq} gap={gap}")
PY
)"
    echo "  wav: $WAV ($(wc -c < "$WAV") B) — $RES"
    PK="$(echo "$RES" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')"
    FQ="$(echo "$RES" | sed -n 's/.*freq=\([0-9]*\).*/\1/p')"
    GP="$(echo "$RES" | sed -n 's/.*gap=\([0-9]*\).*/\1/p')"
    [ "${PK:-0}" -gt 3000 ] && echo "  PASS: non-silent (peak=$PK)" || { echo "  FAIL: silent (peak=$PK)"; rc=1; }
    if [ "${FQ:-0}" -ge 400 ] && [ "${FQ:-0}" -le 480 ]; then echo "  PASS: first tone ~440 Hz (measured $FQ) — pitch correct"; else echo "  WARN: first tone freq=$FQ (expected ~440)"; fi
    [ "${GP:-1}" -eq 0 ] && echo "  PASS: no silence gap within the sustained tone (continuous)" || echo "  FAIL: silence gap detected mid-tone (a DROPOUT — the path glitches even blocking-paced)"
fi
echo ""
[ "$rc" -eq 0 ] && echo "tonegen-smoke: PASS — clean tones stream through the agnos snd_* band" || echo "tonegen-smoke: FAIL"
exit $rc
