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
#
# Defaults to N=4 iterations spread across the stress window. Override
# via ITERATIONS=N (max 64 per the audit doc's long-term goal).
#
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, mkfs.ext4,
#           e2fsck, dd, strings. gnoboot at ../gnoboot/build/.
# REQUIRES the kernel to be built with JBD2_CRASH_SELFTEST=1.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext4 e2fsck dd strings; do
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
python3 "$ROOT/scripts/mk-dirty-journal-img.py" "$IMG_TEMPLATE" "$PART_OFFSET" --csum-v3

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
        recovery="dirty journal → replay"
    elif strings "$BOOT2_LOG" | grep -q "jbd2: clean journal"; then
        crash_count_clean=$((crash_count_clean + 1))
        recovery="clean journal at boot 2"
    else
        recovery="boot 2 didn't reach mount (boot hang?)"
    fi
    echo "    boot 2: $recovery"

    # Dispositive: e2fsck -fn on the partition slice
    dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-iter-$iter.img" status=none
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
echo "  iterations:       $ITERATIONS"
echo "  e2fsck PASS:      $pass_count"
echo "  e2fsck FAIL:      $fail_count"
echo "  boot-2 saw dirty: $crash_count_dirty  (replay actually fired)"
echo "  boot-2 saw clean: $crash_count_clean  (either no writes pre-kill OR SB-clean done pre-kill)"

if [ "$pass_count" -eq "$ITERATIONS" ]; then
    echo "=== jbd2-crash-smoke: PASS ($pass_count/$ITERATIONS clean) ==="
    exit 0
else
    echo "=== jbd2-crash-smoke: FAIL ($fail_count/$ITERATIONS dirty) ==="
    exit 1
fi
