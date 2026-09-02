#!/bin/bash
# jbd2-crash-smoke.sh — crash-injection validation of the JBD2 stack.
#
# For each iteration:
#   1. Fresh mkfs.ext4 image
#   2. Boot agnos with JBD2_CRASH_SELFTEST (~3 s stress loop of put_inode
#      commits), SIGKILL QEMU at a varied time within the stress window
#      so the kill lands at unpredictable points (pre-commit / mid-commit
#      / post-commit pre-checkpoint / mid-checkpoint / post-checkpoint).
#   3. Reboot agnos against the same image. Replay (if dirty journal) +
#      sync. Wait until shell prompt is seen.
#   4. Extract partition; host `e2fsck -fn` MUST be clean.
#   5. AND the iteration must have been ARMED — the kill landed on a running
#      stress loop, boot 2 reached its mount decision, and the extracted
#      partition differs from the pristine template. e2fsck -fn is clean on an
#      image nothing ever touched, so without (5) step (4) grades mkfs.ext4's
#      output rather than the JBD2 stack. See the VACUITY FLOOR block below.
#
# Defaults to N=4 iterations spread across the stress window. Override
# via ITERATIONS=N (max 64 per the audit doc's long-term goal).
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           e2fsck, dd, strings, cmp. gnoboot at ../gnoboot/build/.
# REQUIRES the kernel to be built with JBD2_CRASH_SELFTEST=1.

set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 e2fsck dd strings cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "jbd2-crash:"; then
    echo "ERROR: kernel not built with JBD2_CRASH_SELFTEST=1" >&2
    echo "       rebuild: JBD2_CRASH_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

ITERATIONS=${ITERATIONS:-4}
WORK="$ROOT/build/jbd2-crash-smoke"; LOGS="$ROOT/build/jbd2-crash-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG_TEMPLATE="$WORK/agnos-jbd2-crash-template.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Build a template image once.
echo "=== AGNOS JBD2 crash-injection smoke (1.38.7, N=$ITERATIONS) ==="
echo "Building template image..."
dd if=/dev/zero of="$IMG_TEMPLATE" bs=1M count=128 status=none
parted -s "$IMG_TEMPLATE" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext4 33MiB 100MiB
sgdisk -t 2:8300 "$IMG_TEMPLATE" >/dev/null
mformat -i "$IMG_TEMPLATE"@@1048576 -F
mmd -i "$IMG_TEMPLATE"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG_TEMPLATE"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG_TEMPLATE"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext4 -F -q -L AGNOS-EXT -b 4096 -m 0 -E offset=$PART_OFFSET "$IMG_TEMPLATE" $PART_BLOCKS
# Match iron: stamp the journal CSUM_V3 + 64BIT (what Linux does on first RW mount).
python3 "$ROOT/scripts/tool/mk-dirty-journal-img.py" "$IMG_TEMPLATE" "$PART_OFFSET" --csum-v3

# Keep the pristine partition slice. It is the log-free witness the floor below leans on: an
# iteration whose extracted slice is byte-identical to this one had NOTHING written to it by either
# boot, so its e2fsck verdict is a verdict on mkfs.ext4's output, not on the JBD2 stack.
dd if="$IMG_TEMPLATE" bs=1M skip=33 count=67 of="$WORK/part-template.img" status=none

# Kill timing strategy: spread across the ~3 s stress window (kernel boots
# in ~1.5 s, then selftest runs ~3 s, then shell). Cover early/mid/late
# crash points within the busy window.
KILL_TIMES="2.0 2.7 3.4 4.1"
if [ "$ITERATIONS" -gt 4 ]; then
    # For >4 iterations, use varied times spread across the stress window
    KILL_TIMES=""
    for i in $(seq 1 "$ITERATIONS"); do
        # spread 1.5–5.0 s across iterations
        t=$(awk -v i="$i" -v n="$ITERATIONS" 'BEGIN { printf "%.2f", 1.5 + (i - 1) * 3.5 / (n - 1) }')
        KILL_TIMES="$KILL_TIMES $t"
    done
fi

pass_count=0
fail_count=0
crash_count_dirty=0     # iterations where boot 2 found dirty journal (replay fired)
crash_count_clean=0     # iterations where boot 2 found clean journal (already SB-synced or crash was before any writes)

# ⚠⚠ VACUITY FLOOR — WHY THIS SCRIPT NOW SCORES MORE THAN e2fsck, AND WHAT IT USED TO SCORE.
# Until 1.56.58 the ONLY graded thing here was `pass_count -eq ITERATIONS`, and pass_count was
# incremented in exactly one place: the `e2fsck -fn` at the bottom of the loop. e2fsck -fn is clean
# on a PRISTINE image. So every way of crash-injecting NOTHING scored a green "PASS (4/4 clean)":
#   · OVMF never hands off. MEASURED on this host at ~30% hand-off success (scripts/smoke/lib/
#     qemu-dwell.sh's header: "3 kernel banners in 10 attempts"), and this script has no banner
#     guard and no retry. Boot 1 dies in the firmware menu, writes nothing; boot 2 does the same;
#     the extracted slice is byte-identical to the template and e2fsck is trivially clean.
#   · The selftest REFUSES to run. ext2.cyr:5785-5788 prints "jbd2-crash: skip (no fs)" /
#     "(no journal)" / "(journal dirty)" / "(FS RO)" and returns without a single commit. One
#     silent failure of the mk-dirty-journal-img.py stamp above is enough to land there — that
#     tool's exit status is not checked, and a journal it leaves dirty takes the third branch.
#     Same pristine image, same green.
#   · Boot 2 hangs. Replay — the thing this smoke is NAMED for — never runs. e2fsck -fn does not
#     replay either (it refuses journal recovery in read-only mode), so it grades an unrecovered
#     image and reports nothing.
# The old form PRINTED all three ("boot 1 last marker: <none>", "boot 2 didn't reach mount (boot
# hang?)", "boot-2 saw dirty: 0") in the lines immediately above "PASS" and scored none of them.
# They are scored now. An iteration counts as ARMED only if the crash landed on a live journal
# workload, boot 2 reached its mount decision, and the bytes on disk actually moved.
armed_count=0
UNARMED="$LOGS/unarmed.txt"; : > "$UNARMED"

iter=0
for KILL_AFTER in $KILL_TIMES; do
    iter=$((iter + 1))
    echo ""
    echo "--- iteration $iter / $ITERATIONS (kill at ${KILL_AFTER}s) ---"

    IMG="$WORK/iter-$iter.img"
    cp "$IMG_TEMPLATE" "$IMG"
    cp "$OVMF_VARS_SRC" "$WORK/vars-$iter.fd"; chmod +w "$WORK/vars-$iter.fd"
    BOOT1_LOG="$LOGS/boot1-iter-$iter.log"
    BOOT2_LOG="$LOGS/boot2-iter-$iter.log"

    # Boot 1: SIGKILL mid-stress
    timeout -s KILL "$KILL_AFTER" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$iter.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-EXT" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$BOOT1_LOG" || true

    last_commit_line=$(strings "$BOOT1_LOG" | grep -E "jbd2: commit_tx: COMMITTED|jbd2-crash: [0-9]+/100 done|jbd2-crash: stress loop PASS" | tail -1)
    echo "    boot 1 last marker: ${last_commit_line:-<none>}"

    # Did the SIGKILL land on a running stress loop? Matched on the loop's OPENING banner
    # ("jbd2-crash: stress loop begin", ext2.cyr:5790) as well as the progress/commit markers,
    # because a kill in the intended pre-commit window is a legitimate iteration and prints no
    # COMMITTED line at all. Matched on the short prefix "jbd2-crash: stress" so a kill that
    # truncates that banner mid-line still counts. A log with NONE of these is a boot that never
    # reached the workload — firmware menu, triple fault, or the selftest's own skip path.
    boot1_skip=""
    if strings "$BOOT1_LOG" | grep -qE "jbd2-crash: stress|jbd2-crash: [0-9]+/100 done|jbd2: commit_tx: COMMITTED"; then
        boot1_stressed=1
    else
        boot1_stressed=0
        boot1_skip=$(strings "$BOOT1_LOG" | grep -m1 "jbd2-crash: skip" || true)
    fi

    # Boot 2: agnos boots against the kill-1-time image. Should replay if dirty,
    # then reach shell. 30 s timeout is generous.
    timeout -s KILL 30 qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$iter.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-EXT" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$BOOT2_LOG" || true

    if strings "$BOOT2_LOG" | grep -q "jbd2: DIRTY journal"; then
        crash_count_dirty=$((crash_count_dirty + 1))
        boot2_mounted=1
        recovery="dirty journal → replay"
    elif strings "$BOOT2_LOG" | grep -q "jbd2: clean journal"; then
        crash_count_clean=$((crash_count_clean + 1))
        boot2_mounted=1
        recovery="clean journal at boot 2"
    else
        boot2_mounted=0
        recovery="boot 2 didn't reach mount (boot hang?)"
    fi
    echo "    boot 2: $recovery"

    # Dispositive: e2fsck -fn on the partition slice
    dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-iter-$iter.img" status=none

    # ⚠ ARMING CHECK — is this iteration's e2fsck verdict about anything? Three independent
    # witnesses, and the third does not read the kernel's log at all: a slice byte-identical to the
    # pristine template proves no boot wrote so much as a superblock timestamp, whatever the serial
    # output claimed. Reasons are accumulated into a FILE and emitted with `cat`, never replayed
    # through printf as a format string — $boot1_skip is kernel-log-derived text and a stray % in it
    # would be a conversion spec (same discipline as scripts/check/toolchain-pin-check.sh).
    if cmp -s "$WORK/part-template.img" "$WORK/part-iter-$iter.img"; then
        bytes_moved=0
    else
        bytes_moved=1
    fi
    if [ "$boot1_stressed" = 1 ] && [ "$boot2_mounted" = 1 ] && [ "$bytes_moved" = 1 ]; then
        armed_count=$((armed_count + 1))
        echo "    ARMED: crash landed on a live stress loop, boot 2 mounted, disk bytes moved"
    else
        why=""
        [ "$boot1_stressed" = 1 ] || why="$why boot-1-never-reached-the-stress-loop${boot1_skip:+ (${boot1_skip})}"
        [ "$boot2_mounted"  = 1 ] || why="$why boot-2-never-reached-mount"
        [ "$bytes_moved"    = 1 ] || why="$why partition-byte-identical-to-template"
        echo "    NOT ARMED:$why"
        printf '    iteration %s (kill at %ss):%s\n' "$iter" "$KILL_AFTER" "$why" >> "$UNARMED"
    fi

    if e2fsck -fn "$WORK/part-iter-$iter.img" >"$LOGS/e2fsck-iter-$iter.log" 2>&1; then
        echo "    PASS: e2fsck -fn clean"
        pass_count=$((pass_count + 1))
    else
        echo "    FAIL: e2fsck -fn reported errors (see $LOGS/e2fsck-iter-$iter.log):"
        sed 's/^/      /' "$LOGS/e2fsck-iter-$iter.log" | head -20
        fail_count=$((fail_count + 1))
    fi
done

echo ""
echo "=== summary ==="
# Both numbers, deliberately: $ITERATIONS is what was ASKED for and $iter is what the KILL_TIMES
# list actually delivered. A run that says "4 requested / 0 executed" is reporting that its own
# enumeration broke, not that the kernel is clean.
echo "  iterations:       $ITERATIONS requested / $iter executed"
echo "  armed:            $armed_count/$iter  (crash hit a live stress loop AND boot 2 mounted AND disk changed)"
echo "  e2fsck PASS:      $pass_count"
echo "  e2fsck FAIL:      $fail_count"
echo "  boot-2 saw dirty: $crash_count_dirty  (replay actually fired)"
echo "  boot-2 saw clean: $crash_count_clean  (either no writes pre-kill OR SB-clean done pre-kill)"

# A real e2fsck failure keeps its own verdict and its own wording — the floors below are about
# green runs that verified nothing, and must never mask a genuine inconsistency.
if [ "$pass_count" -ne "$ITERATIONS" ]; then
    echo "=== jbd2-crash-smoke: FAIL ($fail_count/$ITERATIONS dirty) ==="
    exit 1
fi

if [ "$iter" -lt 1 ]; then
    echo "=== jbd2-crash-smoke: VACUOUS — 0 iterations executed, nothing was crash-injected ==="
    echo "  KILL_TIMES was empty, so the loop body never ran and pass_count/ITERATIONS compared"
    echo "  0 against 0. Check the ITERATIONS=$ITERATIONS -> KILL_TIMES derivation above."
    exit 1
fi

if [ -s "$UNARMED" ]; then
    echo "=== jbd2-crash-smoke: VACUOUS — $armed_count/$iter iterations were armed ==="
    cat "$UNARMED"
    echo ""
    echo "  Every iteration above scored 'e2fsck -fn clean' having crash-injected nothing, which is"
    echo "  what a pristine mkfs.ext4 image scores. This is NOT a kernel verdict."
    echo "  · boot-1-never-reached-the-stress-loop: OVMF hand-off (~30% success on this host — see"
    echo "    scripts/smoke/lib/qemu-dwell.sh) or the selftest's own skip path. Re-run; if it is"
    echo "    persistent, boot the image by hand and read $LOGS/boot1-iter-*.log."
    echo "  · boot-2-never-reached-mount: replay never ran; e2fsck -fn does not replay either."
    echo "  · partition-byte-identical-to-template: neither boot wrote one byte to the filesystem."
    exit 1
fi

if [ "$crash_count_dirty" -lt 1 ]; then
    echo "=== jbd2-crash-smoke: VACUOUS — replay fired 0 times in $iter iterations ==="
    echo "  Every kill landed outside a transaction (all $crash_count_clean boots found a clean"
    echo "  journal), so the recovery path this smoke is named for executed zero times and the"
    echo "  green e2fsck line above graded four already-consistent images."
    echo "  KILL_TIMES=$KILL_TIMES no longer overlaps the stress window — read the 'boot 1 last"
    echo "  marker' lines: if they all say 'stress loop PASS', the loop now finishes before the"
    echo "  earliest kill and the times need re-spreading (or ITERATIONS raising)."
    exit 1
fi

echo "=== jbd2-crash-smoke: PASS ($pass_count/$ITERATIONS clean, $armed_count/$iter armed, $crash_count_dirty replayed) ==="
exit 0
