#!/bin/bash
# cwd-smoke — agnos 1.57.18: the per-process WORKING DIRECTORY (chdir#112 / getcwd#113) and every path-taking syscall
# resolving a relative path from it.
#
# Issue:  2026-11-06-a-relative-path-has-no-working-directory (thoth 0.55.1's jail read /etc/secret.txt for a relative
#         "etc/secret.txt"); operator ruling 2026-11-08 — the kernel keeps a cwd per process.
# Design: docs/architecture/working-directory.md (the ingress kernel/core/syscall.cyr sc_path_take; the storage
#         kernel/core/proc.cyr proc_cwd_*, ROOM slot 12; the per-CPU ingress slots, ROOM slot 13).
#
# PLAIN kernel, tests/cwd seeded as /bin/agnsh (ring3-seed.sh's recipe), the ESP's FAT at /mnt/fat, and — unless
# CWD_ZFS=0 — the ZFS fixture's pool (scripts/tool/zfs-fixture.sh --ensure, the zfs-ring3-smoke payload, so its cached
# fixture serves) as a third GPT partition at /mnt/zfs. One boot per -smp (default 1 and 4), each on a fresh copy of the
# image: the CWDX-* markers (header of tests/cwd/cwdx.cyr), no latched invariant, then on the host `e2fsck -fn` clean
# and the end state by debugfs (/etc/secret.txt untouched, /proj/etc/secret.txt the project's).
# Env: CWD_SMP (default "1 4"); CWD_ZFS (default 1; 0 = no pool, the ZFS clauses report ABSENT and the run is VOID for
#      them); CWD_KERNEL=<plain kernel> boots a prebuilt kernel and skips the build (the falsification hook);
#      QEMU_TRIES; QEMU_TIMEOUT (default 300); SMOKE_KVM (0 = TCG for every boot).
# Exit 0 = every check of every boot PASSED; 1 = any FAIL; 2 = a boot never booted (firmware VOID), or the ZFS pool
# could not be attached, and nothing failed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== cwd smoke (chdir#112 / getcwd#113: relative paths from a per-process working directory) ==="
ring3_seed_init || exit 1
for t in debugfs e2fsck md5sum cyrius; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/cwd-smoke"; LOGS="$ROOT/build/cwd-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# ── the kernel ──
if [ -n "${CWD_KERNEL:-}" ]; then
    KERNEL="$CWD_KERNEL"
    echo "  using the PREBUILT kernel $KERNEL (the falsification hook)"
else
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    smoke_require_image "$ROOT/build/agnos" "" || exit 1
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi

# ── the probe (rebuilt every run: the stale-artifact lesson) ──
( cd "$ROOT/tests/cwd" && rm -f build/cwdx && cyrius build --agnos cwdx.cyr build/cwdx ) > "$LOGS/cwdx-build.log" 2>&1 \
    || { echo "  ERROR: cwdx build failed (see $LOGS/cwdx-build.log)"; exit 1; }
SEED="$WORK/seed"
mkdir -p "$SEED/bin" "$SEED/etc" "$SEED/proj" "$SEED/mnt/zfs"
cp "$ROOT/tests/cwd/build/cwdx" "$SEED/bin/agnsh"
printf 'ROOT-SECRET\n' > "$SEED/etc/secret.txt"
printf 'PROJ-NOTE\n' > "$SEED/proj/note.txt"
SECRET_MD5="$(md5sum < "$SEED/etc/secret.txt" | cut -d' ' -f1)"

# ── the ZFS pool (the zfs-ring3-smoke payload, so the fixture it ensured serves this run too) ──
POOL=""
if [ "${CWD_ZFS:-1}" = "1" ]; then
    ( cd "$ROOT/tests/zfs" && rm -f build/zfsx && cyrius build --agnos zfsx.cyr build/zfsx ) > "$LOGS/zfsx-build.log" 2>&1
    if [ -f "$ROOT/tests/zfs/build/zfsx" ]; then
        mkdir -p "$WORK/payload"; cp "$ROOT/tests/zfs/build/zfsx" "$WORK/payload/zfsx"
        FIX="$(bash "$ROOT/scripts/tool/zfs-fixture.sh" --ensure --payload "$WORK/payload" 2>"$LOGS/zfs-fixture.log" | tail -1)"
        if [ -n "$FIX" ] && [ -f "$FIX/DONE" ] && [ -f "$FIX/main.img" ]; then POOL="$FIX/main.img"; fi
    fi
    if [ -z "$POOL" ]; then echo "  NOTE: no ZFS fixture (see $LOGS/zfs-fixture.log) — the ZFS clauses will be VOID"; fi
fi
[ -n "$POOL" ] && echo "  pool: $POOL ($(stat -c %s "$POOL") bytes)"

# ── the image: ring3_seed_image's ESP 1-33 MiB + ext2 33-100 MiB, and the pool as partition 3 from 100 MiB ──
IMG="$WORK/C.img"
if [ -n "$POOL" ]; then
    PMIB=$(( ($(stat -c %s "$POOL") + 1048575) / 1048576 ))
    rm -f "$IMG"
    dd if=/dev/zero of="$IMG" bs=1M count=$(( 101 + PMIB )) status=none || exit 1
    parted -s "$IMG" mklabel gpt \
        mkpart ESP fat32 1MiB 33MiB set 1 esp on \
        mkpart agnos-fs ext2 33MiB 100MiB \
        mkpart zfs 100MiB $(( 100 + PMIB ))MiB || exit 1
    sgdisk -t 2:8300 -t 3:a504 "$IMG" >/dev/null || exit 1
    mformat -i "$IMG"@@1048576 -F || exit 1
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot || exit 1
    mcopy -i "$IMG"@@1048576 "$R3_GNOBOOT" ::EFI/BOOT/BOOTX64.EFI || exit 1
    mcopy -i "$IMG"@@1048576 "$KERNEL" ::boot/agnos || exit 1
    mkfs.ext2 -F -q -L AGNOS-CWD -b 4096 -m 0 \
        -O "${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}" \
        -d "$SEED" -E offset=$(( 33 * 1048576 )) "$IMG" $(( 67 * 1048576 / 4096 )) || exit 1
    dd if="$POOL" of="$IMG" bs=1M seek=100 conv=notrunc status=none || exit 1
else
    ring3_seed_image "$IMG" "$KERNEL" "$SEED" "AGNOS-CWD" || { echo "  ERROR: image"; exit 1; }
fi

# The markers every boot must print (tests/cwd/cwdx.cyr), and the ZFS ones when the pool is attached.
MARKS="START-ROOT CHDIR-GETCWD GETCWD-SMALL-CAP REL-MKDIR REL-OPEN-STAT REL-RENAME REL-LINK-UNLINK
REL-SYMLINK-READLINK-LSTAT REL-READDIR REL-STATFS REL-RMDIR REL-UNLINK
DOTDOT-AT-ROOT CLEAN-ABS CLEAN-REL DOTDOT-PAST-ROOT REL-DOTS-OPEN
CHDIR-FILE-REFUSED CHDIR-MISSING-REFUSED CHDIR-EMPTY-NUL-REFUSED CHDIR-REL-FILE-REFUSED CHDIR-SYMLINK-LOGICAL
SYMLINK-DOTDOT-LOGICAL ISSUE-NO-ROOT-SECRET ISSUE-PROJECT-FILE
SPAWN-INHERIT SPAWN-PWD-SEED SPAWN-PWD-CLEANED SPAWN-BOGUS-PWD-IGNORED EXECWAIT-SEED-INHERIT FORK-INHERIT
SPAWN-RELATIVE-PROGRAM RECYCLED-PID-CLEAN CONCURRENT-CWDS
FAT-CHDIR-REL-OPEN CWD-REMOVED LONG-CWD-GETCWD LONG-NAME-REFUSED-NOT-CUT LONG-CHDIR-REFUSED LONG-INPUT-REFUSED"
ZMARKS="ZFS-REL-OPEN-STAT ZFS-REL-READLINK-LSTAT ZFS-REL-READDIR-STATFS ZFS-DOTDOT-IN-POOL ZFS-REL-MKDIR-RMDIR ZFS-ACROSS-MOUNT"
NMARK=$(echo $MARKS | wc -w)
[ -n "$POOL" ] && NMARK=$(( NMARK + $(echo $ZMARKS | wc -w) ))

R3_MEM="${R3_MEM:-1024M}"; export R3_MEM
for smp in ${CWD_SMP:-1 4}; do
    LOG="$LOGS/cwd-smp$smp.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$smp")"; export R3_ACCEL
    P="[smp$smp]"
    echo ""
    echo "Boot $P: -smp $smp  accel: $R3_ACCEL"
    cp "$IMG" "$WORK/C-$smp.img"
    ring3_seed_boot "$WORK/C-$smp.img" "$LOG" "CWDX-DONE" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "CWDX|kybernet: (exec|emergency)" | sed 's/^/    /'
    want "kybernet: exec /bin/agnsh"     "$P kybernet launched cwdx"
    for m in $MARKS; do want "CWDX-$m-OK" "$P $m"; done
    if [ -n "$POOL" ]; then
        want "CWDX-ZFS-PRESENT" "$P the pool is mounted at /mnt/zfs"
        for m in $ZMARKS; do want "CWDX-$m-OK" "$P $m"; done
    else
        echo "  VOID: $P the ZFS clauses (no pool attached)"; void=$((void + 1))
    fi
    want "CWDX-DONE pass=$NMARK fail=0"  "$P CWDX-DONE pass=$NMARK fail=0"
    deny "CWDX-FAIL-|CWDX-CHILD"         "$P no FAIL marker, no failing child"
    deny "kybernet: emergency"           "$P cwdx exited 0"
    deny "$SMOKE_INVARIANT_DENY"         "$P no latched invariant"

    dd if="$WORK/C-$smp.img" of="$WORK/C-$smp.part" bs=1M skip=33 count=67 status=none
    if e2fsck -fn "$WORK/C-$smp.part" > "$LOGS/cwd-smp$smp.fsck.log" 2>&1; then ok "$P e2fsck -fn clean"
    else bad "$P e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/cwd-smp$smp.fsck.log" | head -20; fi
    sm="$(debugfs -R "cat /etc/secret.txt" "$WORK/C-$smp.part" 2>/dev/null | md5sum | cut -d' ' -f1)"
    [ "$sm" = "$SECRET_MD5" ] && ok "$P on disk: /etc/secret.txt untouched" || bad "$P on disk: /etc/secret.txt changed"
    ps="$(debugfs -R "cat /proj/etc/secret.txt" "$WORK/C-$smp.part" 2>/dev/null)"
    [ "$ps" = "PROJ-SECRET" ] && ok "$P on disk: the relative create landed at /proj/etc/secret.txt" \
        || bad "$P on disk: /proj/etc/secret.txt is '$ps', want PROJ-SECRET"
    if debugfs -R "stat /f.txt" "$WORK/C-$smp.part" 2>/dev/null | grep -q "Inode:"; then bad "$P on disk: a relative create landed at /f.txt"
    else ok "$P on disk: no relative create landed at /"; fi
    rm -f "$WORK/C-$smp.part"
done

echo ""
echo "=== cwd-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
