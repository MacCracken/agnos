#!/bin/sh
# blk-ring3-smoke.sh — ring-3 raw block-device READ-PATH smoke (1.53.10 Phase 1).
#
# Stages /bin/blkprobe (blk-test/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a BLK_RING3_SELFTEST kernel that runs `/bin/blkprobe` from
# disk, and asserts the ring-3 block read-path works end to end: blk_enum#75 finds the
# NVMe disk, blk_open#76 hands back a RO handle, blk_read#77 pulls LBA 1, and its first
# 8 bytes are the "EFI PART" GPT signature (parted wrote a GPT on this image). Exit 95.
#
# Gates: "exec: running /bin/blkprobe" (dispatched), "run: exit 95" (the read-path gate),
#        "exec: blkprobe returned" (no hang/crash), and no #PF/#GP/#UD/PANIC.
# Diagnostic exits: 90=enum err, 91=no disk, 92=open fail, 93=read fail, 94=GPT sig bad.
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

echo "[1/4] Building blkprobe (--agnos) + the BLK_RING3_SELFTEST kernel..."
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build blkprobe.cyr build/blkprobe --agnos ) >/tmp/blkprobe-build.log 2>&1 || { echo "  BUILD-FAIL (blkprobe)"; tail -8 /tmp/blkprobe-build.log; exit 1; }
if ! env BLK_RING3_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/blkprobe-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/blkprobe-kbuild.log)"; tail -8 /tmp/blkprobe-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
BLKPROBE="$BLK_ROOT/build/blkprobe"
[ -f "$GNOBOOT" ]  || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$BLKPROBE" ] || { echo "ERROR: blkprobe not built at $BLKPROBE"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/blkprobe $(stat -c %s "$BLKPROBE") B"

WORK="$ROOT/build/blk-ring3-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-blkprobe.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding a GPT disk (parted) with /bin/blkprobe..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$BLKPROBE" "$SEED/bin/blkprobe"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-BLK -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/blkprobe..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=120
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-BLK" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: blkprobe returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- blkprobe serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/blkprobe|exec: blkprobe|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "exec: running /bin/blkprobe" \
    && echo "  PASS: /bin/blkprobe dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: blkprobe never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 95"; then
    echo "  PASS: run: exit 95 — ring-3 read-path OK end to end (blk_enum#75 → blk_open#76 RO → blk_read#77 LBA 1 → 'EFI PART' GPT signature matched)"
elif strings "$SLOG" | grep -q "run: exit 91"; then
    echo "  FAIL: run: exit 91 — blk_enum found NO disk (backend not registered / active)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 92"; then
    echo "  FAIL: run: exit 92 — blk_open(RO) failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 93"; then
    echo "  FAIL: run: exit 93 — blk_read(LBA 1) failed (returned != 1)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 94"; then
    echo "  FAIL: run: exit 94 — read succeeded but LBA 1 is NOT a GPT header ('EFI PART' mismatch)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 90"; then
    echo "  FAIL: run: exit 90 — blk_enum syscall error (<0)"; rc=1
else
    echo "  FAIL: no 'run: exit 95' — blkprobe crashed before exit (bad syscall wiring / unmapped-buffer fault)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — the block read-path is fault-free"

echo ""
[ "$rc" -eq 0 ] && echo "blk-ring3-smoke: PASS — ring-3 raw block read-path works on agnos (1.53.10 Phase 1)" || echo "blk-ring3-smoke: FAIL"
exit $rc
