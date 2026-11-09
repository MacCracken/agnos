#!/bin/bash
# fs-create-mode-smoke — agnos 1.57.18: open#7's create mode (AO_MODE) and fsync#115 on ext2, from ring 3, then a
# crash cut after an fsync.
#
# Issue:  2026-11-06-open-has-no-create-mode (filed from thoth 0.55.1 — a private file landed 0644; fsync was sync#12).
# Design: kernel/core/syscall.cyr — the "open#7's CREATE MODE (AO_MODE) and a per-file sync (fsync#115)" block
#         (sc_open_mode, sys_fsync_fd) and ext2.cyr ext2_create_m; ABI § 3.3 (AO_MODE) and the #115 row.
#
# PLAIN kernel, tests/fsmode seeded as /bin/agnsh (ring3-seed.sh), -smp 1 and -smp 4: the FSMODE-* markers (header of
# tests/fsmode/fsmode.cyr), no latched invariant — and the boot is KILLED on its DONE line (qemu_dwell's TERM: no
# close, no sync#12, no shutdown after the probe's last fsync#115 — a crash cut). Then on the host, a second ext2
# implementation reads the partition: debugfs's Mode of every file the probe made (0600 / 0640 / 0755 / 04755 / 01644,
# the default 0644, the existing 0600 kept), no /fm/mbad, /fm/durable's 5,000 bytes byte for byte, /fm/data's size,
# and e2fsck -fn clean.
# ⚠ ext2 WRITES THROUGH: every write#1 is on the device when it returns, so the cut keeps /fm/durable with or without
# its fsync — what fsync#115 adds is the device FLUSH (QEMU's: a host fdatasync), which no cut on this host can see.
# The flush itself is counted in-kernel by fssys-smoke.sh (FS_SYSCALL_SELFTEST: one flush, no sector); this smoke proves
# from ring 3 that fsync#115 returns 0 and writes no sector while sync#12 writes the superblock (FSMODE-MEASURE).
# Env: FSMODE_SMP (default "1 4"); FSMODE_KERNEL=<plain kernel> uses a prebuilt kernel and skips the build (the
#      falsification hook); QEMU_TRIES; QEMU_TIMEOUT (default 240); SMOKE_KVM (0 = TCG).
# Exit 0 = every check of every boot PASSED; 1 = any FAIL; 2 = a boot never booted (firmware VOID) and nothing failed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== fs create-mode smoke (open#7 AO_MODE + fsync#115 on ext2, ring 3, a crash cut after fsync) ==="
ring3_seed_init || exit 1
for t in debugfs e2fsck md5sum python3 cyrius; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/fsmode-smoke"; LOGS="$ROOT/build/fsmode-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }
part_of() { dd if="$1" of="$2" bs=1M skip=33 count=67 status=none; }
dbg_mode() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -oE "Type: [a-z]+ +Mode: +[0-7]+" | head -1 | awk '{print $2":"$4}'; }
dbg_has() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q "Inode:"; }

if [ -n "${FSMODE_KERNEL:-}" ]; then
    KERNEL="$FSMODE_KERNEL"
    echo "  using the PREBUILT kernel $KERNEL (the falsification hook)"
else
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
( cd "$ROOT/tests/fsmode" && rm -f build/fsmode && cyrius build --agnos fsmode.cyr build/fsmode ) > "$LOGS/fsmode-build.log" 2>&1 \
    || { echo "  ERROR: fsmode build failed (see $LOGS/fsmode-build.log)"; exit 1; }
mkdir -p "$WORK/seed/bin"
cp "$ROOT/tests/fsmode/build/fsmode" "$WORK/seed/bin/agnsh"
ring3_seed_image "$WORK/F.img" "$KERNEL" "$WORK/seed" "AGNOS-FSMODE" || { echo "  ERROR: image"; exit 1; }
# /fm/durable's bytes: tests/fsmode f_byte(k + 11), k = 0..4999
DUR_MD5="$(python3 -I -c 'import sys; sys.stdout.buffer.write(bytes(((k + 11) * 7 + 3 + ((k + 11) >> 9)) & 0xFF for k in range(5000)))' | md5sum | cut -d' ' -f1)"

for smp in ${FSMODE_SMP:-1 4}; do
    LOG="$LOGS/fsmode-smp$smp.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$smp")"; export R3_ACCEL
    P="[smp$smp]"
    echo ""
    echo "Boot $P: -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/F.img" "$WORK/F-$smp.img"
    ring3_seed_boot "$WORK/F-$smp.img" "$LOG" "FSMODE-DONE" "${QEMU_TIMEOUT:-240}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "FSMODE|kybernet: (exec|emergency)" | sed 's/^/    /'
    want "kybernet: exec /bin/agnsh"             "$P kybernet launched fsmode"
    want "FSMODE-MODE-0600-OK"                   "$P M  AO_MODE 0600: stat#33 reads 0100600"
    want "FSMODE-MODE-0640-OK"                   "$P M  AO_MODE 0640: 0100640"
    want "FSMODE-MODE-0755-OK"                   "$P M  AO_MODE 0755: 0100755"
    want "FSMODE-MODE-04755-OK"                  "$P M  AO_MODE 04755: setuid kept (0104755)"
    want "FSMODE-MODE-01644-OK"                  "$P M  AO_MODE 01644: sticky kept (0101644)"
    want "FSMODE-MODE-DEFAULT-OK"                "$P M  no AO_MODE (the field set): the default 0100644"
    want "FSMODE-MODE-EXISTING-KEPT-OK"          "$P M  an existing file opened AO_CREAT | AO_MODE 0777 keeps 0600"
    want "FSMODE-MODE-BAD-REFUSED-OK"            "$P M  a field above 07777 (010000, 0xFFFFFFFF, bit 63): -1, nothing created"
    want "FSMODE-FSYNC-FILE-OK"                  "$P F  fsync#115 on an ext2 file: 0, no sector written"
    want "FSMODE-FSYNC-RDONLY-OK"                "$P F  fsync#115 on a read-only fd: 0"
    want "FSMODE-FSYNC-DIR-OK"                   "$P F  fsync#115 on an AO_DIRECTORY fd: 0"
    want "FSMODE-FSYNC-NONFILE-REFUSED-OK"       "$P F  fsync#115 on the console, a pipe's ends, a closed fd, 99, -1: -1"
    want "FSMODE-MEASURE-OK"                     "$P F  20 x fsync#115 wrote no sector; 20 x sync#12 wrote the superblock each time"
    want "FSMODE-DURABLE-FSYNCED-OK"             "$P D  /fm/durable written + fsync#115 before the cut"
    want "FSMODE-DONE pass=14 fail=0"            "$P FSMODE-DONE pass=14 fail=0"
    deny "FSMODE-FAIL-"                          "$P no FAIL marker"
    deny "kybernet: emergency"                   "$P fsmode never exited"
    deny "$SMOKE_INVARIANT_DENY"                 "$P no latched invariant"
    strings "$LOG" | grep -oE "FSMODE-MEASURE .*" | head -1 | sed 's/^/    measured: /'

    part_of "$WORK/F-$smp.img" "$WORK/F-$smp.part"
    for pm in m600:0600 m640:0640 m755:0755 m4755:04755 m1644:01644 mdef:0644; do
        f="${pm%%:*}"; m="${pm##*:}"
        got="$(dbg_mode "$WORK/F-$smp.part" "/fm/$f")"
        if [ "$got" = "regular:$m" ]; then ok "$P on disk (debugfs): /fm/$f is a regular file of Mode $m"
        else bad "$P on disk (debugfs): /fm/$f is '$got', want regular:$m"; fi
    done
    if dbg_has "$WORK/F-$smp.part" /fm/mbad; then bad "$P on disk: /fm/mbad exists (a refused create made a file)"
    else ok "$P on disk: /fm/mbad absent (the refused creates made nothing)"; fi
    dm="$(debugfs -R "cat /fm/durable" "$WORK/F-$smp.part" 2>/dev/null | md5sum | cut -d' ' -f1)"
    [ "$dm" = "$DUR_MD5" ] && ok "$P after the cut: /fm/durable holds its 5,000 bytes byte for byte" \
                           || bad "$P after the cut: /fm/durable md5 $dm, want $DUR_MD5"
    dsz="$(debugfs -R "stat /fm/data" "$WORK/F-$smp.part" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | awk '{print $2}')"
    [ "$dsz" = "172032" ] && ok "$P after the cut: /fm/data is 172,032 bytes (8 KiB + 40 x 4 KiB)" \
                          || bad "$P after the cut: /fm/data size '$dsz', want 172032"
    if e2fsck -fn "$WORK/F-$smp.part" > "$LOGS/fsmode-smp$smp.fsck.log" 2>&1; then
        ok "$P e2fsck -fn clean after the cut"
    else
        bad "$P e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/fsmode-smp$smp.fsck.log" | head -20
    fi
done

echo ""
echo "=== fs-create-mode-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
