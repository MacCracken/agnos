#!/bin/sh
# fp-ring3-smoke.sh — ring-3 f64 first-touch smoke (1.53.x FP/SIMD arc, bite B4).
#
# Stages /bin/fpex (tests/fp/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with an FP_RING3_SELFTEST kernel that runs `/bin/fpex` from disk,
# and asserts the ring-3 f64 program computed correctly and exited 84.
#
# fpex does f64 arithmetic in ring 3 (7*3=21, +1=22, /2=11). The whole B1→B3 FP stack
# must work: enter_ring3 sets CR0.TS → the first f64 op #NMs → nm_handler FXRSTORs
# fpex's per-proc area → the f64 computes → exit 84. A wrong XMM restore → "run: exit 1";
# a #GP on the first FXRSTOR (illegal B2 default image) → a crash before exit.
#
# Gates: "exec: running /bin/fpex" (dispatched), "run: exit 84" (f64 correct, THE gate),
#        "exec: fpex returned" (no hang/crash), and no #PF/#GP/#UD/PANIC.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius.
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
FP_ROOT="$ROOT/tests/fp"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building fpex (--agnos) + the FP_RING3_SELFTEST kernel..."
( cd "$FP_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build fpex.cyr build/fpex --agnos ) >/tmp/fpex-build.log 2>&1 || { echo "  BUILD-FAIL (fpex)"; tail -5 /tmp/fpex-build.log; exit 1; }
if ! env FP_RING3_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/fpex-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/fpex-kbuild.log)"; tail -5 /tmp/fpex-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
FPEX="$FP_ROOT/build/fpex"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$FPEX" ]    || { echo "ERROR: fpex not built at $FPEX"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/fpex $(stat -c %s "$FPEX") B"

WORK="$ROOT/build/fp-ring3-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-fpex.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/fpex..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$FPEX" "$SEED/bin/fpex"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-FPEX -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/fpex..."
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=120
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # qemu_attempt_verdict / qemu_assert_booted
# ⛔ 1.57.7 (IMG-fix, D15/B3 class) — BANNER-CLASSIFIED RETRY. This smoke booted ONCE, so the ~1-in-4 firmware
# hand-off flake (`gnoboot: fail @ EBS`, the kernel never ran) failed its sweep row outright: the IMG-fix sweep lost
# this row on two EBS VOIDs in a row (logs/IMG-fix/sweep-logs). Now a VOID attempt is retried (QEMU_TRIES, default
# 6) with its log kept as <log>.attemptN, a kernel that died before its banner FAILS at once (qemu_attempt_verdict),
# and a run with no banner in any attempt is VOID (exit 2), never scored.
_try=1
while :; do
    cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
    qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-FPEX" \
        -serial "file:$SLOG" -display none -no-reboot &
    QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
    i=0
    while [ $i -lt $HARD ]; do
        sleep 1; i=$((i+1))
        if grep -aq "exec: fpex returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
        # a failed hand-off is terminal — stop waiting now; the classification below decides
        if ! grep -aq "AGNOS kernel v" "$SLOG" 2>/dev/null && grep -aqE "gnoboot: fail @|BootManagerMenuApp|BdsDxe: failed to load" "$SLOG" 2>/dev/null; then break; fi
        kill -0 $QPID 2>/dev/null || break
    done
    kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync
    qemu_attempt_verdict "$SLOG" "$_try" && break
    [ "$_try" -ge "${QEMU_TRIES:-6}" ] && break
    _try=$((_try + 1))
done
# ⛔ DID THE KERNEL RUN AT ALL? Placed AFTER the wait loop, not after the launch — this smoke
# backgrounds QEMU, so checking straight after the `&` would read an empty log every time.
# Without this an OVMF hand-off failure makes every assertion below evaluate against that
# empty log: this gate printed "fpex never dispatched" from a kernel that never executed.
qemu_assert_booted "$SLOG" || { echo "fp-ring3-smoke: VOID"; exit 2; }

echo "[4/4] Checks..."
echo "  --- fpex serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/fpex|exec: fpex|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "exec: running /bin/fpex" \
    && echo "  PASS: /bin/fpex dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: fpex never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 84"; then
    echo "  PASS: run: exit 84 — ring-3 f64 (mulsd/addsd/divsd + comisd) computed CORRECTLY end to end (B1 enable → B2 area → B3 #NM restore → ring-3 use)"
elif strings "$SLOG" | grep -q "run: exit 1"; then
    echo "  FAIL: run: exit 1 — fpex ran but the f64 result was WRONG (XMM not restored correctly)"; rc=1
else
    echo "  FAIL: no 'run: exit 84' — fpex crashed before exit (a #GP on the first FXRSTOR = illegal B2 default image, or a #NM loop)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — the FP path is fault-free"

echo ""
[ "$rc" -eq 0 ] && echo "fp-ring3-smoke: PASS — real cyrius f64 runs correctly in agnos ring 3" || echo "fp-ring3-smoke: FAIL"
exit $rc
