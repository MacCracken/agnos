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
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
TG_ROOT="$ROOT/tests/audio"

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
# ⚠ A GATE THIS FILE'S OWN HEADER NAMES, SCORED AS A WARN. Line 13 lists "tonegen started + returned"
# among the gates; until 1.56.59 the `+ returned` half was one WARN with no rc, so "tonegen ran to
# completion" and "tonegen never came back" left the script in exactly the same state and both ended
# at "tonegen-smoke: PASS", exit 0. The scenario is built by the loop directly above: `kill $QPID` at
# line 77 fires the moment the HARD timeout expires whether or not tonegen finished, so a stream that
# wedges mid-run yields a truncated wav and an unset done_marker — and nothing here objected.
# MEASURED on the extracted-verdict rig, healthy 3 s 440 Hz capture with done_marker=0: the old form
# printed "WARN: 'tonegen returned' marker not seen (hard timeout 75s)" and then "tonegen-smoke: PASS
# — clean tones stream through the agnos snd_* band", exit 0. A truncated capture that happens to hold
# 1.8 s of clean tone clears every remaining gate, so this WARN was the only thing that knew.
[ "$done_marker" -eq 1 ] && echo "  PASS: tonegen ran to completion" \
    || { echo "  FAIL: 'tonegen returned' marker never appeared (hard timeout ${HARD}s) — the run was cut off, so any wav below is a fragment of the stream, not the stream"; rc=1; }

if [ ! -s "$WAV" ]; then
    echo "  FAIL: no wav captured at $WAV"; rc=1
else
    RES="$(python3 - "$WAV" <<'PY'
import sys, struct, math
raw = open(sys.argv[1], "rb").read()
i = raw.find(b"data"); off = i+8 if 0 <= i and i+8 <= len(raw) else 44
pcm = raw[off:]; n = len(pcm)//4
WANT = 180  # 10ms windows the continuity check below claims to cover = 1.8s
if n == 0: print("SILENT peak=0 freq=0 gap=1 found=0 frames=0 want=%d" % WANT); sys.exit(0)
if n > 6000000: n = 6000000
S = struct.unpack("<%dh" % (n*2), pcm[:n*4])
SR = 48000
mono = [(S[2*j]+S[2*j+1])//2 for j in range(n)]
peak = max(abs(v) for v in mono)
# locate the first sustained tone: first 1s window whose RMS is high
W = SR//100  # 10ms
env = [math.sqrt(sum(mono[k+j]*mono[k+j] for j in range(W))/W) for k in range(0, n-W, W)]
mx = max(env) if env else 0
# first index where energy is sustained (>= 0.4*peak-RMS for >= 30 windows).
# `found` is reported because start=0 means BOTH "the tone starts at sample 0" and "no tone
# was located at all", and the caller's floor has to be able to tell those two apart.
thr = mx*0.4
start = 0
found = 0
for idx in range(len(env)-30):
    if all(env[idx+q] > thr for q in range(30)): start = idx*W; found = 1; break
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
region = env[start//W: start//W + WANT]
run = 0
for e in region:
    if e < mx*0.05: run += 1
    else: run = 0
    if run >= 3: gap = 1
# `frames`/`want` are the enumeration count this verdict rests on, reported rather than implied:
# gap==0 is the empty-set answer as much as it is the clean-tone answer.
print(f"peak={peak} freq={freq} gap={gap} found={found} frames={len(region)} want={WANT}")
PY
)"
    echo "  wav: $WAV ($(wc -c < "$WAV") B) — $RES"
    PK="$(echo "$RES" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')"
    FQ="$(echo "$RES" | sed -n 's/.*freq=\([0-9]*\).*/\1/p')"
    GP="$(echo "$RES" | sed -n 's/.*gap=\([0-9]*\).*/\1/p')"
    FD="$(echo "$RES" | sed -n 's/.*found=\([0-9]*\).*/\1/p')"
    FR="$(echo "$RES" | sed -n 's/.*frames=\([0-9]*\).*/\1/p')"
    WN="$(echo "$RES" | sed -n 's/.*want=\([0-9]*\).*/\1/p')"
    [ "${PK:-0}" -gt 3000 ] && echo "  PASS: non-silent (peak=$PK)" || { echo "  FAIL: silent (peak=$PK)"; rc=1; }
    # ⚠ THE SECOND WARN-AS-A-GATE, AND THE ONE THAT LET A CAPTURE WITH NO WAVEFORM IN IT SCORE GREEN.
    # Line 14 names "the first sustained tone reads ~440 Hz (pitch correct)" as a gate; through 1.56.58
    # its else branch was a WARN that never touched rc, so pitch was unfalsifiable — the only sense in
    # which this smoke checked the pitch was that it printed a number a human might read.
    # ⛔ The concrete scenario is not a slightly-flat tone, it is NO TONE AT ALL. `freq` is counted from
    # zero-up-crossings of the AC-coupled slice, so a DAC latched at a constant level — the classic
    # stuck-ring symptom this smoke exists to catch — measures freq=0 while clearing every other gate:
    # peak is loud, the envelope is flat so the tone "locates" at sample 0, and 180/180 windows read
    # "continuous". MEASURED on the extracted-verdict rig against a synthesised 3 s DC rail at 12000:
    # "PASS: non-silent (peak=12000)" · "WARN: first tone freq=0 (expected ~440)" · "PASS: no silence
    # gap ... (continuous across 180/180 10ms windows)" · "tonegen-smoke: PASS", exit 0. A 1000 Hz
    # capture — right path, wrong rate, i.e. a sample-rate regression — scored green the same way.
    # ⭐ WHY IT IS SAFE TO SCORE IT NOW, when it was examined and left a WARN at 1.56.58 (the sweep's
    # one declined finding — docs/development/issues/2026-09-02-vacuous-gates-sweep.md:15): all a WARN
    # can buy is protection from a false red on an untrustworthy measurement, and the floor added at
    # the bottom of this block in that SAME cut already refuses the verdict when the tone was not
    # located or fewer than $WN windows were read — which is every case in which this number is not
    # worth reading. On a truncated capture the two now fail together and say so in two lines; that is
    # one root cause reported twice, not a spurious red.
    if [ "${FQ:-0}" -ge 400 ] && [ "${FQ:-0}" -le 480 ]; then
        echo "  PASS: first tone ~440 Hz (measured $FQ) — pitch correct"
    else
        echo "  FAIL: first tone freq=${FQ:-?} Hz, expected ~440 (located=${FD:-?}) — a measured 0 means no oscillation was counted at all in the located region (a latched DAC), anything else means the rate is wrong"; rc=1
    fi
    # ⚠ THE MISSING rc, AND THE VACUITY FLOOR UNDER IT. Until 1.56.58 the dropout gate was one line:
    #     [ "${GP:-1}" -eq 0 ] && echo "  PASS: no silence gap ..." || echo "  FAIL: silence gap ..."
    # The else branch printed the word FAIL and never touched rc, so a run that had just reported a
    # DROPOUT fell through to the verdict below and printed "tonegen-smoke: PASS", exit 0. Measured
    # on a synthesised capture with 100 ms zeroed out of the sustained sine: "FAIL: silence gap
    # detected mid-tone" and "tonegen-smoke: PASS" printed from the same run. The one property this
    # whole script exists to prove — that the snd_* path does not glitch even when kernel-paced —
    # was unfalsifiable, and had been since the gate was written.
    # ⚠ AND THE PASS SIDE WAS VACUOUS TOO, which is the worse half. `gap` is a count of consecutive
    # sub-threshold windows over an UNFLOORED enumeration: `region` is up to 180 windows taken from
    # the located tone, and when there are none the loop never runs, gap stays 0, and "no silence gap
    # within the sustained tone" prints having examined NOTHING. That is not hypothetical — the
    # `kill $QPID` at line 77 fires the moment the HARD timeout expires whether or not tonegen
    # finished, and through 1.56.58 the `done_marker` check above only WARNed about the missing
    # marker (it FAILs as of 1.56.59, so the same stall is now caught twice — which is right: one
    # gate says the run was cut off, this one says what the fragment contains), so a
    # boot that stalls mid-stream leaves a wav holding a fraction of a second of tone and this gate
    # was the only thing that would have noticed. Measured against the OLD form: a 0.5 s capture scored
    # "PASS ... (continuous)" off 49 windows, a 10 ms capture scored it off ZERO, and 100 bytes of
    # non-audio junk scored the whole smoke green — peak clears 3000 on garbage, the pitch check was
    # still WARN-only at that cut (it scores as of 1.56.59), and nothing else was left to object.
    # start=0 was hiding the same hole from the other end: it means "tone begins at sample 0" and
    # "no sustained tone found" indistinguishably, so an all-silent capture measured the first 1.8 s
    # of silence against a threshold of 5% of near-zero, matched nothing, and reported continuity.
    # So the analyser now reports whether it LOCATED the tone and HOW MANY windows it actually read,
    # and both are asserted here before gap is believed. A run that says "frames=49/180" is reporting
    # that its own enumeration broke, not that the audio path is clean.
    # ⚠ The fallbacks are deliberately the FAILING values (found=0, frames=0, want=180): if the
    # analyser dies or its output format rots, the parse yields empty and this must fail, not sail
    # through on a "${WN:-0}" floor of zero that every capture clears.
    if [ "${FD:-0}" -ne 1 ] || [ "${FR:-0}" -lt "${WN:-180}" ]; then
        echo "  FAIL: continuity unverifiable — sustained tone located=${FD:-?}, examined ${FR:-?}/${WN:-180} 10ms windows (capture truncated, silent, or analyser output unparsable)"; rc=1
    elif [ "${GP:-1}" -eq 0 ]; then
        echo "  PASS: no silence gap within the sustained tone (continuous across $FR/$WN 10ms windows)"
    else
        echo "  FAIL: silence gap detected mid-tone (a DROPOUT — the path glitches even blocking-paced)"; rc=1
    fi
fi
echo ""
[ "$rc" -eq 0 ] && echo "tonegen-smoke: PASS — clean tones stream through the agnos snd_* band" || echo "tonegen-smoke: FAIL"
exit $rc
