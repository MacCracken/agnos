#!/bin/bash
# ext2-rename-replace-smoke — agnos 1.57.17: rename#31 on ext2 REPLACING an existing name, atomic with respect to a
# crash, an open fd keeping the replaced file, and flock#59 on an AO_DIRECTORY fd.
#
# Issues: 2026-10-28-ext2-rename-cannot-replace-an-existing-file (hapi: `hapi adopt` could not run at all) and
#         2026-11-02-ext2-rename-cannot-replace-loses-every-descent-save (descent: every save after a character's
#         creation failed at the rename, silently).
# Design: kernel/core/ext2.cyr ext2_rename_replace (the write order and why every cut leaves the destination naming the
#         old inode or the new one) and the in-core orphan block above ext2_unlink (an inode whose last name goes while
#         an fd holds it is freed at its last close — Linux ext2_evict_inode).
#
#   part CUTS  EXT2_RNCUT_SELFTEST=1 kernel, -smp 1, one boot per (scenario, cut): the kernel runs ONE rename over an
#              existing name named by the host-seeded /rncut and HALTS right after the cut (every write before it is on
#              the medium, none after — blk_write completes before it returns). On the host, per cut:
#                - the destination exists and names the OLD file (cuts 0-1) or the NEW one (cuts 2-5, 9), byte for byte
#                  (a directory: the old empty one or the new one holding its child) — never missing;
#                - the source name is there exactly while the order says it must be;
#                - cut 0 (nothing written), 5 and 9 (the op complete): `e2fsck -fn` clean;
#                - every other cut: `e2fsck -fy` repairs it (exit <= 1), `e2fsck -fn` is clean after, and the
#                  destination STILL names what it named before the repair (e2fsck never deletes it).
#              Scenarios: F a file over a file in one directory (the staging pattern), X a file over a file across
#              directories, D a directory over an EMPTY directory across parents.
#   part RING3 PLAIN kernel, tests/rnrep seeded as /bin/agnsh (ring3-seed.sh), -smp 1 and -smp 4: the RNREP-* markers
#              (header of tests/rnrep/rnrep.cyr), no latched invariant, then on the host `e2fsck -fn` clean (so every
#              replaced or unlinked inode was freed at its last close — a links-0 inode left allocated is a "zero dtime"
#              error) and the end state by debugfs.
# Env: RNREP_PARTS (default "cuts ring3"); RNREP_SCEN (default "F X D"); RNREP_CUTS (default "0 1 2 3 4 5 9");
#      RNREP_SMP (default "1 4"); RNREP_KERNEL=<plain kernel> / RNREP_CUT_KERNEL=<EXT2_RNCUT_SELFTEST kernel> use
#      prebuilt kernels and skip the builds (the falsification hook); QEMU_TRIES; QEMU_TIMEOUT (ring 3, default 300);
#      SMOKE_KVM (0 = TCG for every boot).
# Exit 0 = every check of every boot PASSED; 1 = any FAIL; 2 = a boot never booted (firmware VOID) and nothing failed.
# Leaves a PLAIN build in build/agnos when it built one.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== ext2 rename-replace smoke (rename#31 over an existing name, crash cuts, open-fd orphans, flock#59 on a dir fd) ==="
ring3_seed_init || exit 1
for t in debugfs e2fsck md5sum cyrius; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/rnrep-smoke"; LOGS="$ROOT/build/rnrep-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# The extracted ext2 partition of image $1 -> $2 (33 MiB offset, 67 MiB — ring3_seed_image's layout).
part_of() { dd if="$1" of="$2" bs=1M skip=33 count=67 status=none; }
# 1 when path $2 resolves in partition $1.
dbg_has() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q "Inode:"; }
dbg_md5() { debugfs -R "cat $2" "$1" 2>/dev/null | md5sum | cut -d' ' -f1; }
dbg_type() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}'; }

PARTS="${RNREP_PARTS:-cuts ring3}"
BUILT_FLAG=0

# ════════════════════════════════════ part CUTS ════════════════════════════════════
case " $PARTS " in *" cuts "*)
echo ""
echo "Part CUTS: one rename over an existing name, the box halted after each cut"
if [ -n "${RNREP_CUT_KERNEL:-}" ]; then
    CUTK="$RNREP_CUT_KERNEL"
    echo "  using the PREBUILT cut kernel $CUTK"
else
    EXT2_RNCUT_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-rncut.log" 2>&1 || { echo "  ERROR: EXT2_RNCUT_SELFTEST build failed (see $LOGS/build-rncut.log)"; exit 1; }
    CUTK="$WORK/agnos-rncut"
    cp "$ROOT/build/agnos" "$CUTK"
    BUILT_FLAG=1
fi
# -smp 1 boots that only run one rename and halt: KVM when it is there (the cut is a property of the write order, not
# of timing), TCG otherwise.
if [ -w /dev/kvm ] && [ "${SMOKE_KVM:-1}" = "1" ]; then CUT_ACCEL="-enable-kvm -cpu host"; else CUT_ACCEL="-cpu max"; fi
echo "  accel: $CUT_ACCEL"

# The two files' bytes: OLD (5000 B) and NEW (7000 B) — two 4 KiB blocks each, so a free is a multi-block one.
yes "OLD-content-the-replaced-file" | head -c 5000 > "$WORK/old.bin"
yes "NEW-content-the-replacing-file-second-generation" | head -c 7000 > "$WORK/new.bin"
OLD_MD5="$(md5sum < "$WORK/old.bin" | cut -d' ' -f1)"
NEW_MD5="$(md5sum < "$WORK/new.bin" | cut -d' ' -f1)"
printf 'S-CHILD\n' > "$WORK/child.bin"
CHILD_MD5="$(md5sum < "$WORK/child.bin" | cut -d' ' -f1)"

# dst_state <partition> <scenario> -> OLD / NEW / MISSING / WRONG
dst_state() {
    case "$2" in
        F|X)
            _dp="/cut/x"; [ "$2" = "X" ] && _dp="/cut/b/x"
            if ! dbg_has "$1" "$_dp"; then echo MISSING; return 0; fi
            _m="$(dbg_md5 "$1" "$_dp")"
            if [ "$_m" = "$OLD_MD5" ]; then echo OLD; elif [ "$_m" = "$NEW_MD5" ]; then echo NEW; else echo WRONG; fi ;;
        D)
            if [ "$(dbg_type "$1" /cut/b/v)" != "directory" ]; then echo MISSING; return 0; fi
            if dbg_has "$1" /cut/b/v/f; then
                if [ "$(dbg_md5 "$1" /cut/b/v/f)" = "$CHILD_MD5" ]; then echo NEW; else echo WRONG; fi
            else echo OLD; fi ;;
    esac
    return 0
}

for S in ${RNREP_SCEN:-F X D}; do
    for K in ${RNREP_CUTS:-0 1 2 3 4 5 9}; do
        P="[cut $S$K]"
        CW="$WORK/cut-$S$K"; mkdir -p "$CW/seed/cut"
        case "$S" in
            F) cp "$WORK/old.bin" "$CW/seed/cut/x"; cp "$WORK/new.bin" "$CW/seed/cut/x.tmp"; SRC="/cut/x.tmp"; DST="/cut/x" ;;
            X) mkdir -p "$CW/seed/cut/a" "$CW/seed/cut/b"
               cp "$WORK/new.bin" "$CW/seed/cut/a/x"; cp "$WORK/old.bin" "$CW/seed/cut/b/x"; SRC="/cut/a/x"; DST="/cut/b/x" ;;
            D) mkdir -p "$CW/seed/cut/a/s" "$CW/seed/cut/b/v"
               cp "$WORK/child.bin" "$CW/seed/cut/a/s/f"; SRC="/cut/a/s"; DST="/cut/b/v" ;;
        esac
        printf '%s%s' "$S" "$K" > "$CW/seed/rncut"
        ring3_seed_image "$CW/img" "$CUTK" "$CW/seed" "AGNOS-RNCUT" || { echo "  ERROR: image $P"; exit 1; }
        LOG="$LOGS/cut-$S$K.log"; : > "$LOG"
        R3_ACCEL="$CUT_ACCEL"; export R3_ACCEL
        ring3_seed_boot "$CW/img" "$LOG" "rncut: HALT" 120 "$CW" -smp 1
        if [ $? -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
        strings "$LOG" | grep -E "rncut:" | sed 's/^/    /'
        if [ "$K" = "9" ]; then
            want "rncut: DONE r=0"            "$P the whole rename returned 0"
        else
            want "rncut: HALT at cut $K\$"    "$P halted at cut $K"
            deny "rncut: DONE"                "$P halted INSIDE the op (no DONE line)"
        fi
        deny "rncut: SKIP|rncut: BAD|$SMOKE_INVARIANT_DENY" "$P the driver ran, no latched invariant"
        part_of "$CW/img" "$CW/part.img"

        # what the order says this cut must hold
        EXP=NEW; [ "$K" -lt 2 ] && EXP=OLD
        SRC_THERE=0
        case "$S" in F|X) [ "$K" -le 2 ] && SRC_THERE=1 ;; D) [ "$K" -eq 0 ] && SRC_THERE=1 ;; esac
        st="$(dst_state "$CW/part.img" "$S")"
        if [ "$st" = "$EXP" ]; then ok "$P the destination names the $EXP $( [ "$S" = D ] && echo directory || echo file)"
        else bad "$P the destination is $st, want $EXP"; fi
        if dbg_has "$CW/part.img" "$SRC"; then sh_=1; else sh_=0; fi
        if [ "$sh_" = "$SRC_THERE" ]; then ok "$P the source name is $( [ "$sh_" = 1 ] && echo present || echo gone), as the order says"
        else bad "$P the source name present=$sh_, want $SRC_THERE"; fi
        # NEVER TOO LOW (a file): the new inode's on-disk link count covers every name that references it at this cut —
        # an unlink of one name would otherwise free it under the other (the reason for step 1's +1).
        case "$S" in F|X)
            names=0; [ "$st" = NEW ] && names=$((names + 1)); [ "$sh_" = 1 ] && names=$((names + 1))
            np="$DST"; [ "$sh_" = 1 ] && np="$SRC"
            nl_="$(debugfs -R "stat $np" "$CW/part.img" 2>/dev/null | grep -oE "Links: [0-9]+" | head -1 | awk '{print $2}')"
            if [ -n "$nl_" ] && [ "$nl_" -ge "$names" ]; then ok "$P the new inode's link count $nl_ covers its $names name(s)"
            else bad "$P the new inode's link count '$nl_' is below its $names name(s) (an unlink of one would free it under the other)"; fi ;;
        esac

        if [ "$K" = "0" ] || [ "$K" = "5" ] || [ "$K" = "9" ]; then
            if e2fsck -fn "$CW/part.img" > "$LOGS/cut-$S$K.fsck-n.log" 2>&1; then ok "$P e2fsck -fn clean (no repair needed)"
            else bad "$P e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/cut-$S$K.fsck-n.log" | head -20; fi
        else
            cp "$CW/part.img" "$CW/rep.img"
            e2fsck -fy "$CW/rep.img" > "$LOGS/cut-$S$K.fsck-y.log" 2>&1; frc=$?
            grep -E "^(Entry|Inode|Unattached|Unconnected|Deleted|Connect|Pass|'\.\.')" "$LOGS/cut-$S$K.fsck-y.log" | grep -v "^Pass" | head -6 | sed 's/^/    e2fsck: /'
            if [ "$frc" -le 1 ]; then ok "$P e2fsck -fy repaired the cut (exit $frc)"
            else bad "$P e2fsck -fy exit $frc (not repairable)"; sed 's/^/        /' "$LOGS/cut-$S$K.fsck-y.log" | head -20; fi
            if e2fsck -fn "$CW/rep.img" > "$LOGS/cut-$S$K.fsck-n2.log" 2>&1; then ok "$P e2fsck -fn clean after the repair"
            else bad "$P e2fsck -fn still reports problems after -fy"; fi
            st2="$(dst_state "$CW/rep.img" "$S")"
            if [ "$st2" = "$EXP" ]; then ok "$P after the repair the destination still names the $EXP one"
            else bad "$P after the repair the destination is $st2, want $EXP (e2fsck changed what the name holds)"; fi
        fi
        rm -f "$CW/img"
    done
done
;;
esac

# ════════════════════════════════════ part RING3 ════════════════════════════════════
case " $PARTS " in *" ring3 "*)
echo ""
echo "Part RING3: tests/rnrep as /bin/agnsh on a PLAIN kernel"
if [ -n "${RNREP_KERNEL:-}" ]; then
    KERNEL="$RNREP_KERNEL"
    echo "  using the PREBUILT kernel $KERNEL (the falsification hook)"
else
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
    BUILT_FLAG=0
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
( cd "$ROOT/tests/rnrep" && cyrius build --agnos rnrep.cyr build/rnrep ) > "$LOGS/rnrep-build.log" 2>&1 \
    || { echo "  ERROR: rnrep build failed (see $LOGS/rnrep-build.log)"; exit 1; }
mkdir -p "$WORK/seed/bin"
cp "$ROOT/tests/rnrep/build/rnrep" "$WORK/seed/bin/agnsh"
ring3_seed_image "$WORK/R.img" "$KERNEL" "$WORK/seed" "AGNOS-RNREP" || { echo "  ERROR: image R"; exit 1; }

for smp in ${RNREP_SMP:-1 4}; do
    LOG="$LOGS/rnrep-smp$smp.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$smp")"; export R3_ACCEL
    P="[smp$smp]"
    echo ""
    echo "Boot $P: -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/R.img" "$WORK/R-$smp.img"
    ring3_seed_boot "$WORK/R-$smp.img" "$LOG" "RNREP-DONE" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "RNREP|kybernet: (exec|emergency)" | sed 's/^/    /'
    want "kybernet: exec /bin/agnsh"           "$P kybernet launched rnrep"
    want "RNREP-STAGING-OK"                    "$P S  20 x (write x.tmp, sync, rename over x): x is each new inode, its bytes, 1 link"
    want "RNREP-OPEN-OLD-OK"                   "$P O  an fd on the replaced file reads its own bytes; 3 new files never take its inode"
    want "RNREP-UNLINK-OPEN-OK"                "$P O  the same for unlink#30 of an open file"
    want "RNREP-REFUSE-DIR-NONEMPTY-OK"        "$P R  a directory over a non-empty directory refused"
    want "RNREP-REFUSE-DIR-OVER-FILE-OK"       "$P R  a directory over a file refused"
    want "RNREP-REFUSE-FILE-OVER-DIR-OK"       "$P R  a file over a directory refused"
    want "RNREP-REFUSE-DOT-OK"                 "$P R  '.' / '..' as either name refused"
    want "RNREP-REFUSE-SUBTREE-OK"             "$P R  a directory into its own subtree refused"
    want "RNREP-SAME-INODE-NOOP-OK"            "$P R  two names of one inode: 0, nothing done"
    want "RNREP-OVER-HARDLINK-OK"              "$P R  over a hard-linked file: its other name keeps it"
    want "RNREP-XDIR-FILE-OK"                  "$P R  a file over a file across directories"
    want "RNREP-DIR-OVER-EMPTY-OK"             "$P R  a directory over an EMPTY directory (one parent; links)"
    want "RNREP-DIR-OVER-EMPTY-XDIR-OK"        "$P R  ... across parents (its '..', both parents' links)"
    want "RNREP-FLOCK-DIR-EXCL-OK"             "$P L  a dir fd's LOCK_EX refuses another process's NB EX and NB SH"
    want "RNREP-FLOCK-DIR-UNLOCK-OK"           "$P L  after LOCK_UN the other process takes it"
    want "RNREP-FLOCK-DIR-SHARED-OK"           "$P L  SH + SH share; the NB conversion to EX is refused"
    want "RNREP-FLOCK-DIR-CLOSE-OK"            "$P L  close#6 of the dir fd releases its lock"
    want "RNREP-FLOCK-FILE-OK"                 "$P L  a file fd still locks"
    want "RNREP-FLOCK-CONSOLE-REFUSED-OK"      "$P L  a console fd is still refused"
    want "RNREP-DONE pass=19 fail=0"           "$P RNREP-DONE pass=19 fail=0"
    deny "RNREP-FAIL-"                         "$P no FAIL marker"
    deny "kybernet: emergency"                 "$P rnrep exited 0"
    deny "$SMOKE_INVARIANT_DENY|ext2: orphan table full" "$P no latched invariant, no orphan-table overflow"

    part_of "$WORK/R-$smp.img" "$WORK/R-$smp.part"
    if e2fsck -fn "$WORK/R-$smp.part" > "$LOGS/rnrep-smp$smp.fsck.log" 2>&1; then
        ok "$P e2fsck -fn clean (every replaced / unlinked inode freed at its last close)"
    else
        bad "$P e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/rnrep-smp$smp.fsck.log" | head -30
    fi
    xsz="$(debugfs -R "stat /rr/x" "$WORK/R-$smp.part" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | awk '{print $2}')"
    [ "$xsz" = "8140" ] && ok "$P on disk: /rr/x is the 20th generation (8140 B)" || bad "$P on disk: /rr/x size '$xsz', want 8140"
    for gone in /rr/x.tmp /rr/o.tmp /rr/d1 /rr/p2/m /rr/p2/y /rr/hn /rr/u; do
        if dbg_has "$WORK/R-$smp.part" "$gone"; then bad "$P on disk: $gone still present"; else ok "$P on disk: $gone gone"; fi
    done
    for here in /rr/d3/m /rr/p1/e/c /rr/p1/y /rr/h /rr/h2 /rr/o; do
        if dbg_has "$WORK/R-$smp.part" "$here"; then ok "$P on disk: $here present"; else bad "$P on disk: $here missing"; fi
    done
done
;;
esac

# Leave a PLAIN build (the cut part's flag build overwrote build/agnos).
if [ "$BUILT_FLAG" = "1" ]; then sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain-final.log" 2>&1; fi

echo ""
echo "=== ext2-rename-replace-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
