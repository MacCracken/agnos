#!/bin/sh
# blk-write-smoke.sh — ring-3 block WRITE-PATH + capability-gate smoke (1.53.10 Phase 2).
#
# Stages /bin/blkwr (blk-test/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a BLK_WRITE_SELFTEST kernel that runs `/bin/blkwr` from disk,
# and asserts the whole write-path + its gate: an UNARMED blk_write#78 (and RW-open) is
# REJECTED, then after arming via blk_open(_, BLK_RW_ARM_MAGIC) a known pattern is written
# to a scratch LBA in the disk's UNALLOCATED TAIL and reads back byte-identical. Exit 96.
#
# Gates: "exec: running /bin/blkwr" (dispatched), "run: exit 96" (gate + write-path), no faults.
# SECURITY: "run: exit 83" or "exit 84" => THE GATE IS BROKEN (an unarmed raw write succeeded).
# Diagnostics: 81 no disk, 82 RO-open, 85 armed RW-open fail, 86 armed write fail, 87/88 readback.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
BLK_ROOT="$ROOT/blk-test"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building blkwr (--agnos) + the BLK_WRITE_SELFTEST kernel..."
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build blkwr.cyr build/blkwr --agnos ) >/tmp/blkwr-build.log 2>&1 || { echo "  BUILD-FAIL (blkwr)"; tail -8 /tmp/blkwr-build.log; exit 1; }
if ! env BLK_WRITE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/blkwr-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/blkwr-kbuild.log)"; tail -8 /tmp/blkwr-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
BLKWR="$BLK_ROOT/build/blkwr"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$BLKWR" ]   || { echo "ERROR: blkwr not built at $BLKWR"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/blkwr $(stat -c %s "$BLKWR") B"

WORK="$ROOT/build/blk-write-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-blkwr.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding a GPT disk (parted) with /bin/blkwr..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$BLKWR" "$SEED/bin/blkwr"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-BLKWR -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/blkwr..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=120
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-BLKWR" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: blkwr returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- blkwr serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/blkwr|exec: blkwr|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "exec: running /bin/blkwr" \
    && echo "  PASS: /bin/blkwr dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: blkwr never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 96"; then
    echo "  PASS: run: exit 96 — write-path + gate OK (unarmed write/RW-open REJECTED; armed write#78 to scratch LBA read back byte-identical)"
elif strings "$SLOG" | grep -qE "run: exit 83|run: exit 84"; then
    echo "  FAIL[SECURITY]: an UNARMED raw write/RW-open SUCCEEDED — THE CAPABILITY GATE IS BROKEN"; rc=1
elif strings "$SLOG" | grep -q "run: exit 81"; then
    echo "  FAIL: run: exit 81 — blk_enum found no disk"; rc=1
elif strings "$SLOG" | grep -q "run: exit 85"; then
    echo "  FAIL: run: exit 85 — armed blk_open(RW) failed (arm didn't take)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 86"; then
    echo "  FAIL: run: exit 86 — armed blk_write#78 failed (returned != nsec)"; rc=1
elif strings "$SLOG" | grep -qE "run: exit 87|run: exit 88"; then
    echo "  FAIL: run: exit 87/88 — readback failed or the pattern did not survive the write"; rc=1
else
    echo "  FAIL: no 'run: exit 96' — blkwr crashed before exit (bad wiring / fault)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — the block write-path is fault-free"

echo ""
[ "$rc" -eq 0 ] && echo "blk-write-smoke: PASS — ring-3 gated raw block write-path works on agnos (1.53.10 Phase 2)" || echo "blk-write-smoke: FAIL"
exit $rc
