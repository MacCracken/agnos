#!/bin/sh
# fssys-smoke — 1.41.3 FS-syscall self-test (FS_SYSCALL_SELFTEST=1), boot-verified with the on-disk
# side effects checked by an INDEPENDENT tool.
#
# ⛔ WHY THIS EXISTS (1.57.5). `FS_SYSCALL_SELFTEST` shipped at 1.41.3 with its runner described in
# docs/development/build.md as "gated by scripts/sweep.sh" — and no sweep row, smoke or harness ever set
# the flag. Nothing built it. So when cyrius 6.5.1 made a wrong argument count a HARD ERROR, the four
# 3-argument `ksyscall(...)` calls inside fs_syscall_selftest() (core/main.cyr) made the flag build
# refuse to emit a binary, and it stayed that way across every pin from 6.5.1 to 6.6.4 — found only by
# a static arity scan during the 6.6.6 pin move, not by any run. A gate that is documented and not run
# is worse than no gate: it tells the reader the code is exercised. This file is the run.
#
# What it proves, in order:
#   1. the flag build BOOTS (the selftest sits before the shell launch; a fault there ends the boot);
#   2. every one of the nine 1.41.3 FS syscalls the selftest drives through ksyscall() — mkdir#9 /
#      open#7(AO_CREAT) / stat#33 / rename#31 / getdents#29 / unlink#30 / rmdir#10 / sync#12, plus the
#      close#6 that pairs each open — reports `fssys: ALL PASS`, and no `fssys: ... FAIL` line appears;
#   3. ⭐ the disk agrees: the selftest creates /fss, /fss/a, renames a->b, unlinks b and rmdirs /fss, so
#      AFTER the boot the ext2 partition must NOT contain /fss (debugfs), and e2fsck must find it clean.
#      The kernel's own `ext2_path_lookup` verifies each step from inside; this half verifies the same
#      facts from outside, with a second implementation of ext2 — a selftest that only grades itself is
#      the failure mode the ext2 write arc was built to avoid.
#
# Usage:   FS_SYSCALL_SELFTEST=1 sh scripts/build.sh && sh scripts/smoke/fssys-smoke.sh
# Exit:    0 = every assertion passed; 1 = a failure; 2 = wrong kernel in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'" >&2; exit 1; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
# The selftest's verdict literals are only in a flag build; a leftover production build/agnos is the
# usual way a smoke like this runs the WRONG kernel and grades an absence.
if ! strings "$AGNOS" | grep -q "fssys: ALL PASS"; then
    echo "ERROR: kernel not built with FS_SYSCALL_SELFTEST=1 — rebuild:" >&2
    echo "       FS_SYSCALL_SELFTEST=1 sh scripts/build.sh" >&2
    exit 2
fi

WORK="$ROOT/build/fssys-smoke"; LOGS="$ROOT/build/fssys-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-fssys.img"
# Same GPT/ESP/ext2 cell as ext2-write-smoke.sh — {1..33 MiB ESP on a 128 MB disk} x {nvme} is the only
# geometry OVMF hands off on (rtc-smoke.sh carries the measurement); do not "simplify" it.
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
echo "=== AGNOS FS-syscall smoke (FS_SYSCALL_SELFTEST, ext2 root on NVMe) ==="
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "fssys seed" > "$SEED/hello.txt"
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-FSSYS -b 4096 -m 0 -O "$FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS
# Negative control for assertion 3: the seed image must NOT already satisfy "no /fss" vacuously because
# debugfs cannot read it at all. Prove debugfs can see the seed file before the boot changes anything.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-pre.img" status=none
if ! debugfs -R "ls -l /" "$WORK/part-pre.img" 2>/dev/null | grep -q "hello.txt"; then
    echo "ERROR: host debugfs cannot list the seed image — the on-disk half of this smoke would be vacuous." >&2
    exit 1
fi

LOG="$LOGS/fssys.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
# Banner-gated: a firmware run that never hands off is retried and reported as VOID, never graded.
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-60}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FSSYS" \
    -serial stdio -display none -no-reboot

echo "--- fssys lines ---"
strings "$LOG" | grep -E "fssys:" | sed 's/^/  /'
echo "-------------------"
if ! strings "$LOG" | grep -q "AGNOS kernel v"; then
    echo "  VOID: UEFI never handed off to the kernel on any attempt — the kernel under test DID NOT EXECUTE."
    echo "  Any assertion below would describe an EMPTY log. Treat this run as VOID, not as a failure."
    exit 1
fi

# The disk AFTER the boot, read by a second ext2 implementation.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
POST_LS="$(debugfs -R "ls -l /" "$WORK/part-post.img" 2>/dev/null || true)"
e2fsck -fn "$WORK/part-post.img" > "$WORK/e2fsck.txt" 2>&1; FSCK_RC=$?

pass=0; fail=0
chk() { if [ "$1" = 1 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $3"; fail=$((fail+1)); fi; }

strings "$LOG" | grep -q "fssys: ALL PASS" && r=1 || r=0
chk "$r" "fssys: ALL PASS — mkdir#9 / open#7 / stat#33 / rename#31 / getdents#29 / unlink#30 / rmdir#10 / sync#12 through ksyscall()" \
         "no 'fssys: ALL PASS' — a syscall handler or its ext2 backend broke (see the fssys lines above)"

strings "$LOG" | grep -qE "fssys: .*FAIL" && r=0 || r=1
chk "$r" "no 'fssys: ... FAIL' line (every per-step verify held)" \
         "a per-step 'fssys: ... FAIL' line was printed: $(strings "$LOG" | grep -E 'fssys: .*FAIL' | head -1)"

strings "$LOG" | grep -q "AGNOS shell" && r=1 || r=0
chk "$r" "boot reached the shell after the selftest (no fault in the ksyscall path)" \
         "boot did not reach the shell — the selftest, or the sync it ends with, took the box down"

printf '%s\n' "$POST_LS" | grep -q "hello.txt" && r=1 || r=0
chk "$r" "host debugfs reads the post-boot ext2 (the seed file is still there)" \
         "host debugfs cannot read the post-boot partition — the selftest's writes corrupted the filesystem"

printf '%s\n' "$POST_LS" | grep -qE "[[:space:]]fss([[:space:]]|$)" && r=0 || r=1
chk "$r" "/fss is GONE from the disk after mkdir -> ... -> rmdir (the on-disk side effects round-tripped)" \
         "/fss is still on the disk — rmdir#10 (or the unlink before it) did not reach the media"

[ "$FSCK_RC" -eq 0 ] && r=1 || r=0
chk "$r" "e2fsck -fn is clean after the syscall sequence (no orphaned inode or block from the create/unlink pair)" \
         "e2fsck -fn rc=$FSCK_RC — the syscall sequence left the ext2 inconsistent: $(grep -vE '^(Pass|e2fsck|AGNOS)' "$WORK/e2fsck.txt" | head -2 | tr '\n' ' ')"

echo ""
[ "$fail" -eq 0 ] && { echo "=== fssys-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== fssys-smoke: $pass passed, $fail failed ==="; exit 1
