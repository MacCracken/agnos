#!/bin/sh
# blk-write-smoke.sh — ring-3 block WRITE-PATH + capability-gate smoke (1.53.10 Phase 2).
#
# Stages /bin/blkwr (tests/blk/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a BLK_WRITE_SELFTEST kernel that runs `/bin/blkwr` from disk,
# and asserts the whole write-path + its gate: an UNARMED blk_write#78 (and RW-open) is
# REJECTED, then after arming via blk_open(_, BLK_RW_ARM_MAGIC) a known pattern is written
# to a scratch LBA in the disk's UNALLOCATED TAIL and reads back byte-identical. Exit 96.
#
# Gates: "exec: running /bin/blkwr" (dispatched), "run: exit 96" (gate + write-path), no faults.
# SECURITY: "run: exit 83" or "exit 84" => THE GATE IS BROKEN (an unarmed raw write succeeded).
# Diagnostics: 81 no disk, 82 RO-open, 85 armed RW-open fail, 86 armed write fail, 87/88 readback.
#
#
# BOOTS (1.57.9, SMOKES3 — issue archived/2026-09-25-three-smokes-score-void-as-fail-or-skip-smp4.md):
# ⛔ A FIRMWARE VOID USED TO BE SCORED AS "blkwr never dispatched". This file ran its own `qemu &` + `sleep 1`
# poll with no banner gate, so a `gnoboot: fail @ EBS` hand-off (the kernel never ran) failed the first
# assertion and read as a ring-3 exec regression. The boot now goes through qemu_dwell_kernel (6 banner-gated
# tries, fresh vars.fd each, VOID attempts kept as $LOG.attemptN, a pre-banner kernel death FAILS at once) and
# qemu_assert_booted; a run whose every try was VOID exits 2 with the reason, never 1. A VOID attempt cannot
# have touched the disk (the kernel never ran), so the retry reuses the same image.
# The dwell stops on `smp: cpus online: ` — AFTER the second `exec: blkwr returned (2nd)` (the 1.57.1 lesson,
# below) — and qemu_dwell's line-finish grace replaces the old `sleep 1`.
# ⚠ Build logs and the flagged kernel live under build/blk-write-smoke/ (per tree), not fixed /tmp names that
# collided across parallel trees. The BLK_WRITE_SELFTEST kernel is booted from a COPY and the tree is rebuilt
# PLAIN before the first boot (msc-short/msc-cdb pattern), so no exit leaves a selftest kernel in build/agnos
# for the next smoke to boot.
# ACCEL: -smp 1 keeps `-enable-kvm -cpu host` when /dev/kvm is WRITABLE (this verdict's history; `-e` used to
# pick KVM on a node QEMU could not open, which then failed to start and scored FAIL), else `-cpu max`; -smp >1
# uses smoke_accel. The `accel:` line says which produced the verdict.
# BLK_WRITE_SMP (default "1") runs the same boot at each listed CPU count, each asserting its topology
# (`smp: cpus online: N`). ⚠ Only "1" runs by default; "1 4" is a knob, not a standing gate. ⚠ The selftest
# runs from main.cyr on the BSP BEFORE interrupts, the scheduler and smp_start_aps, so -smp 4 proves the path
# under a 4-CPU topology and boot path, NOT concurrent block I/O (the msc-cdb caveat).
#
# Exit: 1 on any FAIL; else 2 if a boot was VOID; else 0.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius.
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
BLK_ROOT="$ROOT/tests/blk"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

WORK="$ROOT/build/blk-write-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"

echo "[1/4] Building blkwr (--agnos) + the BLK_WRITE_SELFTEST kernel (booted from a copy), then plain..."
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build blkwr.cyr build/blkwr --agnos ) >"$WORK/blkwr-build.log" 2>&1 || { echo "  BUILD-FAIL (blkwr, $WORK/blkwr-build.log)"; tail -8 "$WORK/blkwr-build.log"; exit 1; }
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build blkleak.cyr build/blkleak --agnos ) >"$WORK/blkleak-build.log" 2>&1 || { echo "  BUILD-FAIL (blkleak, $WORK/blkleak-build.log)"; tail -8 "$WORK/blkleak-build.log"; exit 1; }
if ! env BLK_WRITE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >"$WORK/kbuild-selftest.log" 2>&1; then
    echo "  BUILD-FAIL (kernel, see $WORK/kbuild-selftest.log)"; tail -8 "$WORK/kbuild-selftest.log"
    sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1
fi
( smoke_require_image "$ROOT/build/agnos" "BLK_WRITE_SELFTEST" ) || { sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1; }
AGNOS="$WORK/agnos-blkwr"; cp "$ROOT/build/agnos" "$AGNOS"
sh "$ROOT/scripts/build.sh" >"$WORK/kbuild-plain.log" 2>&1 || { echo "  BUILD-FAIL (plain kernel, see $WORK/kbuild-plain.log)"; exit 1; }

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
BLKWR="$BLK_ROOT/build/blkwr"
# 1.57.1 — /bin/blkleak is the exit-disarm gate's first half: it arms the raw-write capability and
# exits WITHOUT closing, so the blkwr run after it can observe whether the arm survived process exit.
BLKLEAK="$BLK_ROOT/build/blkleak"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$BLKWR" ]   || { echo "ERROR: blkwr not built at $BLKWR"; exit 1; }
[ -f "$BLKLEAK" ] || { echo "ERROR: blkleak not built at $BLKLEAK"; exit 1; }
echo "  agnos (BLK_WRITE_SELFTEST copy) $(stat -c %s "$AGNOS") B   /bin/blkwr $(stat -c %s "$BLKWR") B"

PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$BLKWR" "$SEED/bin/blkwr"
cp "$BLKLEAK" "$SEED/bin/blkleak"

# A FRESH disk per boot: blkwr's readback of its scratch LBA must not be satisfied by a previous boot's pattern.
build_img() {   # $1 = image path
    dd if=/dev/zero of="$1" bs=1M count=256 status=none
    parted -s "$1" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
    sgdisk -t 2:8300 "$1" >/dev/null
    mformat -i "$1"@@1048576 -F
    mmd -i "$1"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$1"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$1"@@1048576 "$AGNOS" ::boot/agnos
    mkfs.ext2 -F -q -L AGNOS-BLKWR -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$1" $PART_BLOCKS
}

rc=0; void=0; verdicts=""
for SMP in ${BLK_WRITE_SMP:-1}; do
    T="[smp$SMP]"; IMG="$WORK/agnos-blkwr-smp$SMP.img"; SLOG="$WORK/serial-smp$SMP.log"
    echo "[2/4] $T Seeding a GPT disk (parted) with /bin/blkwr + /bin/blkleak..."
    build_img "$IMG"
    if [ "$SMP" -gt 1 ]; then ACC=$(smoke_accel "$SMP")
    elif [ -w /dev/kvm ] && [ "${SMOKE_KVM:-1}" = "1" ]; then ACC="-enable-kvm -cpu host"
    else ACC="-cpu max"; fi
    case "$ACC" in *enable-kvm*) BUDGET="${QEMU_TIMEOUT:-120}" ;; *) BUDGET="${QEMU_TIMEOUT:-240}" ;; esac
    echo "[3/4] $T Booting gnoboot+OVMF+NVMe, running /bin/blkwr (accel: $ACC -smp $SMP, budget ${BUDGET}s)..."
    # shellcheck disable=SC2086
    # ⛔ 1.57.1 — THE DWELL MUST NOT END BEFORE THE **SECOND** RETURN. "exec: blkwr returned" is printed by the
    # FIRST run too, so stopping on it ended the dwell before the exit-disarm sequence (blkleak, then blkwr
    # again) could finish — the log stopped mid-gate and the smoke scored a FAIL on its own impatience rather
    # than on the kernel. Measured: the third exec had started and never got to print.
    # ⚠ 1.57.9 — and not before the topology line either: `exec: blkwr returned (2nd)` was the marker until
    # then, and `smp: cpus online: N` prints ~1.7 s after it (measured under KVM), so the -smp assertion saw
    # it only when the 2 s grace happened to cover it. The marker is now that line, which the whole selftest
    # precedes (BLK_WRITE_SELFTEST runs before smp_start_aps).
    QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @|BootManagerMenuApp|Please select boot device}" \
    qemu_dwell_kernel "$SLOG" "smp: cpus online: " "$BUDGET" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-BLKWR" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$SLOG"; then
        why=$(qemu_void_why "$SLOG")
        echo "  VOID: $T the kernel never ran ($why) — no assertion scored; logs: $SLOG.attempt*"
        void=1; verdicts="$verdicts $T=VOID"; continue
    fi

    echo "[4/4] $T Checks..."
    r=0
    echo "  --- blkwr serial lines ---"
    strings "$SLOG" | grep -aE "exec: (running )?/bin/blkwr|exec: blkwr|run: exit|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -12
    strings "$SLOG" | grep -q "exec: running /bin/blkwr" \
        && echo "  PASS: $T /bin/blkwr dispatched (exec'd from disk in ring 3)" \
        || { echo "  FAIL: $T blkwr never dispatched"; r=1; }
    # ⛔⛔ 1.57.1 — TWO exit-96 LINES ARE REQUIRED, NOT ONE. The kernel runs /bin/blkwr TWICE under this
    # selftest, and the second run is the gate for the EXIT-DISARM of blk_rw_armed: run 1 ARMS the raw
    # write gate and exits, and blkwr's FIRST assertion is "blk_write while UNARMED must be REJECTED".
    # So if the arm survives process exit, run 2 finds the gate already open and exits **83 GATE BROKEN**.
    # ⇒ Counting only ONE 96 would score the leak as a pass, which is the vacuity this whole gate family
    # exists to prevent. `grep -c` is the assertion; do not weaken it back to `grep -q`.
    BLKWR96="$(strings "$SLOG" | grep -c 'run: exit 96' || true)"
    if [ "${BLKWR96:-0}" -ge 2 ]; then
        echo "  PASS: $T run: exit 96 TWICE — write-path + gate OK, and the raw-write arm did NOT survive"
        echo "        the first process's exit (unarmed write/RW-open REJECTED on the second run too)"
    elif [ "${BLKWR96:-0}" -eq 1 ]; then
        echo "  FAIL: $T only ONE 'run: exit 96'. If the second run exited 83, blk_rw_armed SURVIVED process"
        echo "        exit — a raw disk-write gate left open for whatever runs next (proc_reap regression)."
        strings "$SLOG" | grep -E 'run: exit [0-9]+' | head -4 | sed 's/^/        /'
        r=1
    elif strings "$SLOG" | grep -qE "run: exit 83|run: exit 84"; then
        echo "  FAIL[SECURITY]: $T an UNARMED raw write/RW-open SUCCEEDED — THE CAPABILITY GATE IS BROKEN"; r=1
    elif strings "$SLOG" | grep -q "run: exit 81"; then
        echo "  FAIL: $T run: exit 81 — blk_enum found no disk"; r=1
    elif strings "$SLOG" | grep -q "run: exit 85"; then
        echo "  FAIL: $T run: exit 85 — armed blk_open(RW) failed (arm didn't take)"; r=1
    elif strings "$SLOG" | grep -q "run: exit 86"; then
        echo "  FAIL: $T run: exit 86 — armed blk_write#78 failed (returned != nsec)"; r=1
    elif strings "$SLOG" | grep -qE "run: exit 87|run: exit 88"; then
        echo "  FAIL: $T run: exit 87/88 — readback failed or the pattern did not survive the write"; r=1
    else
        echo "  FAIL: $T no 'run: exit 96' — blkwr crashed before exit (bad wiring / fault)"; r=1
    fi
    strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
        && { echo "  FAIL: $T a fault/panic appeared in the log"; r=1; } \
        || echo "  PASS: $T no #PF/#GP/#UD/PANIC — the block write-path is fault-free"
    # The topology is this variant's content: a run that did not get $SMP CPUs must not score as one.
    if strings "$SLOG" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //' | grep -qxF "smp: cpus online: $SMP"; then
        echo "  PASS: $T all $SMP CPU(s) came online"
    else
        echo "  FAIL: $T no kernel line 'smp: cpus online: $SMP' — this boot is not the topology it claims"; r=1
    fi
    if strings "$SLOG" | grep -qE -- "$SMOKE_INVARIANT_DENY"; then
        echo "  FAIL: $T a latched kernel invariant fired:"; strings "$SLOG" | grep -E -- "$SMOKE_INVARIANT_DENY" | head -5 | sed 's/^/        /'; r=1
    else
        echo "  PASS: $T no latched kernel invariant fired (whole boot)"
    fi
    if [ "$r" -eq 0 ]; then verdicts="$verdicts $T=PASS"; else verdicts="$verdicts $T=FAIL"; rc=1; fi
done

echo ""
echo "  verdicts:$verdicts"
if [ "$rc" -ne 0 ]; then echo "blk-write-smoke: FAIL"; exit 1; fi
if [ "$void" = 1 ]; then echo "blk-write-smoke: VOID (the firmware never handed off in ${QEMU_TRIES:-6} banner-gated tries — the kernel under test never ran)"; exit 2; fi
echo "blk-write-smoke: PASS — ring-3 gated raw block write-path works on agnos (1.53.10 Phase 2)"
exit 0
