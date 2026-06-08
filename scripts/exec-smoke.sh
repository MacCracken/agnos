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
    echo "  PASS: /bin/prog2 ran in ring 3 — write(1) reached the console"
else
    echo "  FAIL: no 'EXEC-DISK-OK' (subdir program did not run in ring 3)"; rc=1
fi
if strings "$LOG" | grep -q "^run: exit 42"; then
    echo "  PASS: exec_and_wait captured exit code 42 (/bin/prog2)"
else
    echo "  FAIL: no 'run: exit 42' (ring-3 exit / exit-code path)"; rc=1
fi
# 1.40.8: argv DEREF — `run /bin/argv Z` exits with argv[1][0] = 'Z' = 0x5A = 90.
# This is exec #2 (after /bin/prog2) — within the proven 2-exec-per-boot envelope
# (a 3rd real exec currently exhausts the 2 MB-page pool; teardown is a follow-on).
# exit 90 is a STRONGER argv test than the 1.40.7 argc-count run it replaces: it
# requires argc>=2 AND argv[1] to point at the real "Z" string in the user stack
# (the 1.40.7 wrong-buffer bug — strings in a kernel scratch page — would make
# argv[1] dereference garbage; argc-count alone could not catch it).
if strings "$LOG" | grep -q "^run: exit 90"; then
    echo "  PASS: argv[1] dereferenced — /bin/argv Z exited with argv[1][0]=90"
else
    echo "  FAIL: no 'run: exit 90' (argv[i] pointers don't resolve to arg strings)"; rc=1
fi
# 1.42.10: sysinfo syscalls (uname#34 + sysinfo#35) — /bin/sysi is exec #3 (the
# 1.42.4 reap work lifted the old 2-exec-per-boot cap). It calls both new syscalls
# into a user-stack buffer and exits sysname[0]('A'=0x41) + totalram byte3 (0x01
# of the 16 MB / 0x01000000 pmm pool) = 73 — so 'run: exit 66' proves both
# syscalls dispatch from ring 3, pass is_user_range, and write the right struct bytes.
if strings "$LOG" | grep -q "^run: exit 73"; then
    echo "  PASS: sysinfo syscalls — /bin/sysi uname#34 + sysinfo#35 wrote correct struct bytes (exit 73)"
else
    echo "  FAIL: no 'run: exit 66' (uname#34 / sysinfo#35 didn't write the expected struct bytes)"; rc=1
fi
# 1.42.12: klog#36 — /bin/klog is exec #4; it calls klog(buf, 200) and exits with
# the byte count returned. The boot log is >> 200 B by now, so klog returns 200,
# proving the syscall copied the requested tail of the unified klug ring into a
# user buffer (bounds + count). The [I]/[W]/[E] level lines emitted just before
# also confirm the leveled-log API is captured.
if strings "$LOG" | grep -q "^run: exit 200"; then
    echo "  PASS: klog#36 — /bin/klog copied 200 B of the unified klug ring to a user buffer (exit 200)"
else
    echo "  FAIL: no 'run: exit 200' (klog#36 didn't copy the requested ring bytes to userland)"; rc=1
fi
# 1.43.x: execwait #37 — /bin/exwv is a RING-3 program that calls execwait(37) on
# /bin/prog2 and exits with the returned code. Because exwv runs in ring 3, its
# execwait is a real SYSCALL and prog2's own syscalls nest under exwv's live #37
# frame — so this exercises the full ring-3-caller path (H1 resume-context
# save/restore + H2 disjoint second kstack), not just dispatch. The gate is a
# SECOND "run: exit 42": prog2's direct run above prints the first; exwv resuming
# correctly across the nested exec and propagating prog2's code prints the second.
# If H1/H2 were broken, exwv would fault/hang/wrong-exit and this count stays at 1.
if strings "$LOG" | grep -q "^exec: running /bin/exwv"; then
    echo "  PASS: execwait #37 — /bin/exwv (ring-3 caller) dispatched"
else
    echo "  FAIL: /bin/exwv not attempted (execwait validator missing)"; rc=1
fi
EXIT42_N=$(strings "$LOG" | grep -c "^run: exit 42")
if [ "$EXIT42_N" -ge 2 ]; then
    echo "  PASS: execwait #37 — exwv resumed across the nested exec + propagated prog2's exit 42 (count=$EXIT42_N)"
else
    echo "  FAIL: execwait #37 — only $EXIT42_N 'run: exit 42' (exwv did not resume/propagate; H1/H2 regression)"; rc=1
fi
# 1.43.2: envp — /bin/envtest reads envp[0][0] (the kernel-staged "HOME=/") and
# exits with it: 'H' = 0x48 = 72. Proves the exec stack now carries a real envp at
# the SysV offset cyrius's getenv() reads (and NOT argv — argv0 starts '/' = 47).
if strings "$LOG" | grep -q "^run: exit 72"; then
    echo "  PASS: envp — /bin/envtest read kernel-staged envp[0] \"HOME=/\" from ring 3 (exit 72='H')"
else
    echo "  FAIL: no 'run: exit 72' (envp not staged / not readable at the SysV offset)"; rc=1
fi
# 1.43.4 — framebuffer fbinfo(38)+blit(39). /bin/fbtest queries geometry, blits a
# 4x4 block to FB(0,0), exits bpp(32)+blit_rc(0)+56 = 88. Proves BOTH new syscalls
# dispatch from ring 3, fbinfo writes the struct (bpp=32), and blit copies into
# fb_phys + returns 0 (exit 87 would mean blit returned -1 / no FB present).
if strings "$LOG" | grep -q "^run: exit 88"; then
    echo "  PASS: fbinfo+blit — /bin/fbtest queried geometry + blitted to the framebuffer from ring 3 (exit 88)"
else
    echo "  FAIL: no 'run: exit 88' (fbinfo/blit didn't dispatch, or blit returned -1 / no FB)"; rc=1
fi
# 1.43.5 — uptime_ms(40)+sleep_ms(41). /bin/timetest reads the ms clock, sleeps
# 50 ms (5 ticks), reads again, exits t1-t0 = 50. Proves both syscalls dispatch
# AND that sleep_ms advanced the clock via its sti+hlt window (exit 0 would mean
# a frozen clock / broken sleep window — the waitpid IF=0 hard-hang class).
if strings "$LOG" | grep -q "^run: exit 50"; then
    echo "  PASS: uptime_ms+sleep_ms — /bin/timetest slept 50 ms and the monotonic clock advanced 50 ms (exit 50)"
else
    echo "  FAIL: no 'run: exit 50' (timing syscalls didn't dispatch, or sleep_ms didn't advance the clock)"; rc=1
fi
# Clean return after ALL runs — "selftest done" proves exec_and_wait returned
# into its caller frame each time (multi-run + shell-loop shape).
if strings "$LOG" | grep -q "^exec: selftest done"; then
    echo "  PASS: exec_and_wait returned cleanly after each run ('selftest done')"
else
    echo "  FAIL: no 'exec: selftest done' (exec_and_wait did not return cleanly)"; rc=1
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
