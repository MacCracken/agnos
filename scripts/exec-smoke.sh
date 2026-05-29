#!/bin/bash
# exec-from-disk smoke (1.40.x — bite 2). Boots the EXEC_SELFTEST kernel
# against a write-friendly ext2 partition. The kernel hand-builds a minimal
# static ELF64 (write(1,"EXEC-DISK-OK\n",13); exit(42)), writes it to ext2 as
# /prog, then `run /prog` — exercising elf_load_from_file (streaming load) +
# exec_and_wait end-to-end. Gates on:
#     EXEC-DISK-OK      (the program ran in ring 3 and wrote to fd 1)
#     run: exit 42      (exec_and_wait resumed the kernel + captured the code)
# plus `e2fsck -fn` clean on the post-boot image (the /prog write didn't
# corrupt the FS).
#
# Build first:  EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1 ./scripts/build.sh
#   (EXEC_SELFTEST seeds+runs /prog; the ext2 mount is the default disk path.)
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2,
#           e2fsck, dd, strings. gnoboot at ../gnoboot/build/.
# Exit 0 if both markers print AND fsck is clean; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/exec-smoke"
LOGS="$ROOT/build/exec-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-exec.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Write-friendly ext2 (the 1.33.x write path's profile — no csum/64bit).
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "exec-from-disk seed" > "$SEED/hello.txt"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-EXEC -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting EXEC_SELFTEST kernel (NVMe + GPT ext2)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/exec-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXEC" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- exec lines from boot log ---"
strings "$LOG" | grep -E "^exec:|^run:" | sed 's/^/  /'
echo ""

# 1.40.3 validates exec-from-disk END TO END: /prog (a hand-built static ELF64)
# is written to ext2, stream-loaded (elf_load_from_file), run in ring 3 via
# exec_and_wait, and its exit code captured. "EXEC-DISK-OK" proves the program
# executed in ring 3 and its write(1,…) reached the console; "run: exit 42"
# proves exec_and_wait resumed the kernel with the program's exit code.
rc=0
# 1.40.4: ENOEXEC — the non-ELF /notelf is refused cleanly (no crash; the boot
# proceeds to the subdir run after it).
if strings "$LOG" | grep -q "^run: not an executable"; then
    echo "  PASS: ENOEXEC — non-ELF /notelf refused cleanly"
else
    echo "  FAIL: no 'run: not an executable' for /notelf (ENOEXEC path)"; rc=1
fi
# Subdir program path — /bin/prog2 is loaded from a subdirectory (proves
# sh_abspath + ext2_path_lookup), run in ring 3 (EXEC-DISK-OK), and exits 42.
if strings "$LOG" | grep -q "^exec: running /bin/prog2"; then
    echo "  PASS: subdir program /bin/prog2 dispatched (path resolution)"
else
    echo "  FAIL: /bin/prog2 not attempted"; rc=1
fi
if strings "$LOG" | grep -q "^EXEC-DISK-OK"; then
    echo "  PASS: /bin/prog2 ran in ring 3 from a subdir — write(1) reached the console"
else
    echo "  FAIL: no 'EXEC-DISK-OK' (subdir program did not run in ring 3)"; rc=1
fi
if strings "$LOG" | grep -q "^run: exit 42"; then
    echo "  PASS: exec_and_wait captured exit code 42 (subdir program)"
else
    echo "  FAIL: no 'run: exit 42' (ring-3 exit / exit-code path)"; rc=1
fi

# Post-boot fsck: the writes (/bin/prog2 + /notelf) must leave the FS clean.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean after the writes"
else
    echo "  FAIL: e2fsck flagged the post-boot image (see $LOGS/fsck.log)"; rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "exec-from-disk smoke: PASS"; else echo "exec-from-disk smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
