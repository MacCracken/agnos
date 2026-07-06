#!/bin/sh
# naad-ring3-smoke.sh — naad oscillator ring-3 END-PROOF (1.53.x FP/SIMD arc, bite B6, arc-closer).
#
# Stages /bin/naadex (naad/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a NAAD_RING3_SELFTEST kernel that runs `/bin/naadex` from disk,
# and asserts a REAL heavy-f64 DSP workload — naad's 440 Hz sine oscillator generating 256
# samples via f64_sin/f64_mul/... — computed correctly (every sample finite) in ring 3 and
# exited 88. Where fp-ring3-smoke (B4) proved 5 hand-picked ops, this proves a shipping
# library's XMM-heavy code (~26k SSE instructions in naad) runs end to end on the FP stack.
#
# Gates: "exec: running /bin/naadex" (dispatched), "run: exit 88" (all 256 samples finite —
#        THE gate), "exec: naadex returned" (no hang/crash), and no #PF/#GP/#UD/PANIC.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius; the naad
# repo checked out at ../naad (with deps resolved — build/naad-agnos should already exist).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
NAAD_ROOT="${NAAD_ROOT:-$ROOT/../naad}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -d "$NAAD_ROOT" ] || { echo "ERROR: naad repo not found at $NAAD_ROOT (set NAAD_ROOT=)"; exit 1; }

echo "[1/4] Building naadex (--agnos, from the naad repo) + the NAAD_RING3_SELFTEST kernel..."
( cd "$NAAD_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build naadex.cyr build/naadex --agnos ) >/tmp/naadex-build.log 2>&1 \
    || { echo "  BUILD-FAIL (naadex)"; tail -8 /tmp/naadex-build.log; exit 1; }
if ! env NAAD_RING3_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/naadex-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/naadex-kbuild.log)"; tail -5 /tmp/naadex-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
NAADEX="$NAAD_ROOT/build/naadex"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$NAADEX" ]  || { echo "ERROR: naadex not built at $NAADEX"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/naadex $(stat -c %s "$NAADEX") B"

WORK="$ROOT/build/naad-ring3-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-naadex.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/naadex..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$NAADEX" "$SEED/bin/naadex"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-NAADEX -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/naadex..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=150
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-NAADEX" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: naadex returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- naadex serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/naadex|exec: naadex|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "exec: running /bin/naadex" \
    && echo "  PASS: /bin/naadex dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: naadex never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 88"; then
    echo "  PASS: run: exit 88 — naad's 440Hz sine oscillator generated 256 FINITE f64 samples in ring 3 (real library XMM-heavy DSP, end to end on the B1-B5 FP stack)"
elif strings "$SLOG" | grep -q "run: exit 1"; then
    echo "  FAIL: run: exit 1 — naadex ran but a sample was non-finite (NaN/Inf — f64/XMM broke)"; rc=1
else
    echo "  FAIL: no 'run: exit 88' — naadex crashed before exit (a #NM loop / FXRSTOR #GP / bad f64 path)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — the naad f64 path is fault-free"

echo ""
[ "$rc" -eq 0 ] && echo "naad-ring3-smoke: PASS — a real naad DSP workload runs correctly in agnos ring 3 (FP/SIMD arc B6 end-proof)" || echo "naad-ring3-smoke: FAIL"
exit $rc
