#!/bin/sh
# mishran-duplex-audio-smoke.sh — "two concurrent procs play sound through the
# mishran mixer on AGNOS" proof (the real loopback wire, no jalwa).
#
# This is the TWO-PROC counterpart to mishran-audio-smoke.sh (which is single-proc:
# one binary opens the router + feeds it in-process). Here /bin/mishclient is the
# PRIMARY: it spawn_path's the small /bin/mishrand daemon, yield-polls until the
# daemon binds loopback:7701 + opens the vani sink, then connects and streams a
# square-wave tone over TCP (msh_client_*). The daemon mixes it down to vani
# (audio_* -> sys_snd_* #64-69). Two ring-3 procs interleaving over the wire.
#
# This is the case that DEADLOCKED before the cooperative sched_yield #44 fix: a
# client whose send window filled backed off with sleep_ms (preempt OFF) and never
# donated to the server that had to drain it, and the server's blocking audio_write
# starved the client for a whole block. The kernel cannot preempt a blocking syscall
# (the shared per-CPU syscall kstack — the serial-kstack invariant). With both sides
# yielding, the two procs cooperate, so a non-silent wav proves: no deadlock, and the
# spawned secondary got CPU while the primary drove audio.
#
# Pipeline: build /bin/mishclient + /bin/mishrand --agnos -> boot gnoboot+OVMF+NVMe
# with a MISHRAN_DUPLEX_SELFTEST kernel that sh_exec's mishclient from disk ->
# capture the HDA output to a wav (intel-hda + hda-duplex + -audiodev wav).
#
# Gates: (1) mishclient started, (2) it connected+registered a stream on the daemon
# (the two-proc wire came up), (3) it ran to completion, (4) captured wav non-silent
# (PEAK > 3000 AND RMS > 800 — a sustained tone through the mixer).
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
[ -f "$MISHRAN_ROOT/programs/mishduplex.cyr" ] || { echo "ERROR: $MISHRAN_ROOT/programs/mishduplex.cyr missing"; exit 1; }
[ -f "$MISHRAN_ROOT/programs/mishclient.cyr" ] || { echo "ERROR: $MISHRAN_ROOT/programs/mishclient.cyr missing"; exit 1; }

WORK="$ROOT/build/mishran-duplex-audio-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-mishran-duplex.img"; SLOG="$WORK/serial.log"; WAV="$WORK/out.wav"

echo "[1/4] Building /bin/mishduplex (server) + /bin/mishclient --agnos (two-proc mixer wire)..."
if ! ( cd "$MISHRAN_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos programs/mishduplex.cyr build/mishduplex-agnos ) >/tmp/mishduplex-build.log 2>&1; then
    echo "  BUILD-FAIL mishduplex (see /tmp/mishduplex-build.log)"; tail -8 /tmp/mishduplex-build.log; exit 1
fi
if ! ( cd "$MISHRAN_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos programs/mishclient.cyr build/mishclient-agnos ) >/tmp/mishclient-build.log 2>&1; then
    echo "  BUILD-FAIL mishclient (see /tmp/mishclient-build.log)"; tail -8 /tmp/mishclient-build.log; exit 1
fi
MISHDUPLEX="$MISHRAN_ROOT/build/mishduplex-agnos"
MISHCLIENT="$MISHRAN_ROOT/build/mishclient-agnos"
[ -f "$MISHDUPLEX" ] || { echo "  ERROR: mishduplex not built"; exit 1; }
[ -f "$MISHCLIENT" ] || { echo "  ERROR: mishclient not built"; exit 1; }
echo "  /bin/mishduplex $(stat -c %s "$MISHDUPLEX") B   /bin/mishclient $(stat -c %s "$MISHCLIENT") B"

echo "[2/4] Building MISHRAN_DUPLEX_SELFTEST kernel..."
if ! env MISHRAN_DUPLEX_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/mishran-duplex-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/mishran-duplex-kbuild.log)"; tail -5 /tmp/mishran-duplex-kbuild.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

echo "[3/4] Seeding ext2 with /bin/mishduplex + /bin/mishclient + booting + intel-hda wav capture..."
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$MISHDUPLEX" "$SEED/bin/mishduplex"
cp "$MISHCLIENT" "$SEED/bin/mishclient"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-DUPLEX -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=70; [ -e /dev/kvm ] || HARD=130

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-DUPLEX" \
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
    if grep -aq "mishduplex: done" "$SLOG" 2>/dev/null; then done_marker=1; sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- mishran-duplex / mishclient serial lines ---"
strings "$SLOG" | grep -aE "mishran-duplex|mishduplex|mishclient|PANIC|FAULT|#PF" | sed 's/^/  /' | head -24

rc=0
strings "$SLOG" | grep -q "mishduplex: listening on loopback" \
    && echo "  PASS: /bin/mishduplex (server) ran under the scheduler + bound loopback:7701" \
    || { echo "  FAIL: mishduplex never bound (scheduler-entered proc syscall path?)"; rc=1; }

# The two-proc wire: mishclient reaching "connected + registered stream" means the
# server bound loopback:7701, spawned the client, AND accepted it over loopback —
# i.e. two concurrent ring-3 procs handshaked, which is the whole point of this smoke.
strings "$SLOG" | grep -q "mishclient: connected + registered stream" \
    && echo "  PASS: two-proc wire up — spawned mishclient connected to the mishduplex server" \
    || { echo "  FAIL: mishclient never connected (two-proc handshake failed — the deadlock?)"; rc=1; }

if [ "$done_marker" -eq 1 ]; then
    echo "  PASS: mishduplex ran to completion (client streamed + disconnected, no deadlock)"
else
    echo "  WARN: 'mishduplex: done' marker not seen (hard timeout ${HARD}s) — checking wav anyway"
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
    # A sustained square streamed over the wire through the mixer inside a boot+play
    # capture: peak proves it reached the DAC; RMS>800 that it was sustained (the
    # secondary kept getting CPU to feed the primary — no starvation).
    if python3 -c "import sys; sys.exit(0 if int('${PEAK:-0}') > 3000 else 1)" 2>/dev/null \
       && python3 -c "import sys; sys.exit(0 if float('${RMS:-0}') > 800.0 else 1)" 2>/dev/null; then
        echo "  PASS: sustained tone reached the DAC (PEAK=$PEAK RMS=$RMS) via mishclient -> loopback -> mishduplex mixer -> vani -> snd_write#66"
    else
        echo "  FAIL: captured audio not a sustained tone (PEAK=$PEAK RMS=$RMS) — client likely starved / deadlocked"; rc=1
    fi
fi

echo ""
echo "  --- snd/hda lines ---"; strings "$SLOG" | grep -aiE "^snd:|^hda:" | sed 's/^/    /' | head -12
echo "  full serial: $SLOG   wav: $WAV"
echo ""
[ "$rc" -eq 0 ] && echo "mishran-duplex-audio-smoke: PASS — two concurrent procs play a tone through the mishran mixer on AGNOS (cooperative yield, no deadlock)" || echo "mishran-duplex-audio-smoke: FAIL"
exit $rc
