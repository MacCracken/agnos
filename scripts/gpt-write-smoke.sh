#!/bin/sh
# gpt-write-smoke.sh — sovereign GPT/mkfs writer smoke (1.53.x Phase 4).
#
# Stages /bin/gptwr (blk-test/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a GPT_WRITE_SELFTEST kernel that runs `/bin/gptwr` from disk,
# and asserts the tool's exit code. gptwr is the ring-3 successor to blkprobe/blkwr: it
# builds a byte-accurate GPT partition table + FAT ESP in userland and writes it through
# sys_blk_* — replacing agnova's `parted` + `mkfs.fat` shell-outs.
#
# BITE 7 (this run): gptwr builds + self-verifies the full GPT (Bites 1-2), writes it to the live
# disk's UNALLOCATED TAIL + readback-verifies it (Bites 3a/3b), formats the ESP as FAT32 (Bite 6),
# and now creates the \EFI subdirectory (Bite 7): allocates cluster 3, writes its '.'/'..' dirents,
# marks it EOC in both FATs, and publishes the \EFI dirent in the root (exit 97). A bug can only
# touch throwaway tail sectors — never the live GPT/ESP/rootfs at absolute LBA 0/1/2-33. THREE
# INDEPENDENT ORACLES on the dumped bytes: sgdisk (foreign GPT impl, "No problems found" + the two
# type GUIDs), mtools minfo/mdir (foreign FAT impl — FAT32 recognized, \EFI listed + descendable),
# and fsck.fat (strict FAT checker, no errors) prove the tool's output is REAL, not merely self-
# consistent. Needs a 1 GiB disk for the tail room.
#
# Gates: "exec: running /bin/gptwr", "run: exit 97", no faults, sgdisk + mtools + fsck.fat clean.
# Diagnostics: 91/92/93 CRC vector, 90 GPT sig, 89 hdr-CRC, 88 array-CRC, 87 ESP-GUID,
#   86 rootfs-GUID, 85 backup-hdr, 84 hdr-fields, 83 protective-MBR, 79 no-disk, 78 overrun,
#   77 arm/RW-open, 76 MBR-write, 75 MBR-readback, 74 MBR-mismatch, 73 hdr-write, 72 array-write,
#   71 backup-array-write, 70 backup-hdr-write, 69 GPT-readback.
#
# The disk is a real GPT/NVMe image (same seeding as blk-write-smoke.sh) so this smoke is
# forward-compatible with bites 3+ (which DO write to the disk's unallocated tail).
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
BLK_ROOT="$ROOT/blk-test"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy minfo mdir sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building gptwr (--agnos) + the GPT_WRITE_SELFTEST kernel..."
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build gptwr.cyr build/gptwr --agnos ) >/tmp/gptwr-build.log 2>&1 || { echo "  BUILD-FAIL (gptwr)"; tail -8 /tmp/gptwr-build.log; exit 1; }
if ! env GPT_WRITE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/gptwr-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/gptwr-kbuild.log)"; tail -8 /tmp/gptwr-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
GPTWR="$BLK_ROOT/build/gptwr"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$GPTWR" ]   || { echo "ERROR: gptwr not built at $GPTWR"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/gptwr $(stat -c %s "$GPTWR") B"

WORK="$ROOT/build/gpt-write-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-gptwr.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding a 1 GiB GPT disk (parted) with /bin/gptwr (tail past 240 MiB = gptwr scratch)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$GPTWR" "$SEED/bin/gptwr"
dd if=/dev/zero of="$IMG" bs=1M count=1024 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-GPTWR -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/gptwr..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=120
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-GPTWR" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: gptwr returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- gptwr serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/gptwr|exec: gptwr|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "exec: running /bin/gptwr" \
    && echo "  PASS: /bin/gptwr dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: gptwr never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 97"; then
    echo "  PASS: run: exit 97 — GPT + FAT32 ESP + \\EFI, \\EFI\\BOOT, \\boot directory skeleton written to the scratch tail; every structure read back byte-identical"
elif strings "$SLOG" | grep -qE "run: exit 91|run: exit 92|run: exit 93"; then
    echo "  FAIL: run: exit 91/92/93 — a CRC32 canonical vector mismatched (transcription bug in crc32)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 90"; then
    echo "  FAIL: run: exit 90 — GPT header signature ('EFI PART') wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 89"; then
    echo "  FAIL: run: exit 89 — primary header CRC self-check failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 88"; then
    echo "  FAIL: run: exit 88 — partition-array CRC self-check failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 87"; then
    echo "  FAIL: run: exit 87 — ESP entry type-GUID/LBA wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 86"; then
    echo "  FAIL: run: exit 86 — rootfs entry type-GUID/LBA wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 85"; then
    echo "  FAIL: run: exit 85 — backup header (swapped LBAs / CRC) wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 84"; then
    echo "  FAIL: run: exit 84 — primary header field sanity wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 83"; then
    echo "  FAIL: run: exit 83 — protective MBR (0xEE type / 0x55AA sig / first-LBA) wrong"; rc=1
elif strings "$SLOG" | grep -q "run: exit 79"; then
    echo "  FAIL: run: exit 79 — blk_enum found no disk (or RO-open failed)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 78"; then
    echo "  FAIL: run: exit 78 — synthetic image overruns disk capacity (scratch tail too small)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 77"; then
    echo "  FAIL: run: exit 77 — armed RW-open failed (arm didn't take)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 76"; then
    echo "  FAIL: run: exit 76 — MBR write to scratch base failed (!= 1 sector)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 75"; then
    echo "  FAIL: run: exit 75 — MBR readback failed (!= 1 sector)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 74"; then
    echo "  FAIL: run: exit 74 — MBR readback did not match what was written"; rc=1
elif strings "$SLOG" | grep -q "run: exit 73"; then
    echo "  FAIL: run: exit 73 — primary GPT header write (base+1) failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 72"; then
    echo "  FAIL: run: exit 72 — entry-array write (base+2, 32 sectors) failed (!= 32)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 71"; then
    echo "  FAIL: run: exit 71 — backup-array write (base+N-33) failed (!= 32)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 70"; then
    echo "  FAIL: run: exit 70 — backup-header write (base+N-1) failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 69"; then
    echo "  FAIL: run: exit 69 — a GPT region readback did not match what was written"; rc=1
elif strings "$SLOG" | grep -q "run: exit 68"; then
    echo "  FAIL: run: exit 68 — CountOfClusters < 65525: the ESP geometry is FAT16, not FAT32"; rc=1
elif strings "$SLOG" | grep -q "run: exit 67"; then
    echo "  FAIL: run: exit 67 — FAT boot sector write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 66"; then
    echo "  FAIL: run: exit 66 — FSInfo write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 65"; then
    echo "  FAIL: run: exit 65 — FAT table write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 64"; then
    echo "  FAIL: run: exit 64 — FAT metadata-region zeroing write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 63"; then
    echo "  FAIL: run: exit 63 — FAT boot sector readback mismatch"; rc=1
elif strings "$SLOG" | grep -q "run: exit 62"; then
    echo "  FAIL: run: exit 62 — FAT[0..2] readback mismatch"; rc=1
elif strings "$SLOG" | grep -q "run: exit 61"; then
    echo "  FAIL: run: exit 61 — BPB self-check failed (bytes/sec, TotSec32, RootClus, or FATSz16)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 60"; then
    echo "  FAIL: run: exit 60 — \\EFI directory-cluster write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 59"; then
    echo "  FAIL: run: exit 59 — FAT re-write (allocating cluster 3) failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 58"; then
    echo "  FAIL: run: exit 58 — root-cluster (\\EFI dirent publish) write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 57"; then
    echo "  FAIL: run: exit 57 — FSInfo re-write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 56"; then
    echo "  FAIL: run: exit 56 — \\EFI cluster / FAT[3] readback mismatch"; rc=1
elif strings "$SLOG" | grep -q "run: exit 55"; then
    echo "  FAIL: run: exit 55 — root \\EFI dirent readback mismatch"; rc=1
elif strings "$SLOG" | grep -q "run: exit 54"; then
    echo "  FAIL: run: exit 54 — \\EFI\\BOOT or \\boot directory-cluster write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 53"; then
    echo "  FAIL: run: exit 53 — FAT re-write (allocating clusters 4/5) failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 52"; then
    echo "  FAIL: run: exit 52 — parent-dirent publish (BOOT under \\EFI / root) write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 51"; then
    echo "  FAIL: run: exit 51 — FSInfo re-write failed"; rc=1
elif strings "$SLOG" | grep -q "run: exit 50"; then
    echo "  FAIL: run: exit 50 — \\EFI\\BOOT / \\boot readback mismatch"; rc=1
else
    echo "  FAIL: no 'run: exit 97' — gptwr crashed before exit (bad wiring / fault)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — gptwr ran fault-free in ring 3"

# --- Bite 5: INDEPENDENT ORACLE — extract the tool-written GPT + validate with sgdisk ---
# gptwr wrote the nested GPT at SCRATCH_BASE=524288 for a synthetic N'=131072-sector disk.
# dd that region out to a standalone image and let sgdisk (an independent GPT implementation)
# recompute the CRCs + parse the table: this proves the bytes are a REAL valid GPT, not merely
# self-consistent with gptwr's own reader.
if [ "$rc" -eq 0 ]; then
    echo "  --- independent GPT oracle (sgdisk on the dumped scratch tail) ---"
    EXT="$WORK/extracted-gpt.img"
    dd if="$IMG" of="$EXT" bs=512 skip=524288 count=131072 status=none
    SG="$WORK/sgdisk.out"; : > "$SG"
    sgdisk -v "$EXT" >>"$SG" 2>&1; sgdisk -p "$EXT" >>"$SG" 2>&1
    sgdisk -i 1 "$EXT" >>"$SG" 2>&1; sgdisk -i 2 "$EXT" >>"$SG" 2>&1
    grep -aiE "verification|problem|partition [0-9]|GUID code" "$SG" | head -8 | sed 's/^/    /'
    if grep -aqi "No problems found" "$SG"; then
        echo "  PASS: sgdisk -v: No problems found — an independent GPT parser accepts the tool-written table + CRCs"
    else
        echo "  FAIL: sgdisk -v reported problems on the tool-written GPT"; rc=1
    fi
    grep -aqi "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" "$SG" \
        && echo "  PASS: partition 1 type GUID = EFI System (ESP)" \
        || { echo "  FAIL: partition 1 is not an ESP"; rc=1; }
    grep -aqi "0FC63DAF-8483-4772-8E79-3D69D8477DE4" "$SG" \
        && echo "  PASS: partition 2 type GUID = Linux filesystem (rootfs)" \
        || { echo "  FAIL: partition 2 is not a Linux filesystem"; rc=1; }
fi

# --- Bite 6 oracle: extract the ESP + let mtools (an independent FAT impl) validate the mkfs ---
# The ESP partition is at absolute LBA SCRATCH_BASE(524288)+ESP_S(2048)=526336, length 69632.
if [ "$rc" -eq 0 ]; then
    echo "  --- independent FAT oracle (mtools minfo/mdir on the dumped ESP) ---"
    ESPIMG="$WORK/extracted-esp.img"
    dd if="$IMG" of="$ESPIMG" bs=512 skip=526336 count=69632 status=none
    MINFO="$WORK/minfo.out"; MDIR="$WORK/mdir.out"
    minfo -i "$ESPIMG" >"$MINFO" 2>&1
    mdir  -i "$ESPIMG" :: >"$MDIR" 2>&1; mdirrc=$?
    grep -aiE "FAT32|sectors per cluster|reserved|big size|Volume|AGNOSBOOT" "$MINFO" | head -6 | sed 's/^/    /'
    if grep -aqi "FAT32" "$MINFO"; then
        echo "  PASS: mtools minfo: recognizes a FAT32 filesystem in the tool-written ESP"
    else
        echo "  FAIL: mtools minfo does not see a FAT32 filesystem"; rc=1
    fi
    if [ "$mdirrc" -eq 0 ] && grep -aqi "EFI" "$MDIR"; then
        echo "  PASS: mtools mdir: parsed the FAT + sees the \\EFI directory in the root"
    else
        echo "  FAIL: mtools mdir did not find \\EFI in the tool-written root (rc=$mdirrc)"; sed 's/^/    /' "$MDIR" | head -5; rc=1
    fi
    mdir -i "$ESPIMG" ::/EFI >"$WORK/mdir-efi.out" 2>&1; mdirefirc=$?
    if [ "$mdirefirc" -eq 0 ] && grep -aqi "BOOT" "$WORK/mdir-efi.out"; then
        echo "  PASS: mtools mdir ::/EFI: descended in, sees the BOOT subdirectory"
    else
        echo "  FAIL: mtools could not descend into \\EFI or BOOT missing (rc=$mdirefirc)"; sed 's/^/    /' "$WORK/mdir-efi.out" | head -3; rc=1
    fi
    mdir -i "$ESPIMG" ::/EFI/BOOT >"$WORK/mdir-efiboot.out" 2>&1 \
        && echo "  PASS: mtools mdir ::/EFI/BOOT: descended into the nested \\EFI\\BOOT directory" \
        || { echo "  FAIL: mtools could not descend into \\EFI\\BOOT"; sed 's/^/    /' "$WORK/mdir-efiboot.out" | head -3; rc=1; }
    mdir -i "$ESPIMG" ::/boot >"$WORK/mdir-boot.out" 2>&1 \
        && echo "  PASS: mtools mdir ::/boot: descended into the \\boot directory" \
        || { echo "  FAIL: mtools could not descend into \\boot"; sed 's/^/    /' "$WORK/mdir-boot.out" | head -3; rc=1; }
    # Third oracle: fsck.fat (dosfstools, the strictest FAT checker) — gating when present.
    if command -v fsck.fat >/dev/null 2>&1; then
        if fsck.fat -n "$ESPIMG" >"$WORK/fsck.out" 2>&1; then
            echo "  PASS: fsck.fat: no errors (strict independent FAT checker)"
        else
            echo "  FAIL: fsck.fat reported issues on the tool-written FAT32:"; sed 's/^/    /' "$WORK/fsck.out" | head -6; rc=1
        fi
    fi
fi

echo ""
[ "$rc" -eq 0 ] && echo "gpt-write-smoke: PASS — GPT + FAT32 ESP + \\EFI\\BOOT + \\boot skeleton written to disk + validated by independent parsers (sgdisk + mtools + fsck.fat) (1.53.x Phase 4 Bite 8a)" || echo "gpt-write-smoke: FAIL"
exit $rc
