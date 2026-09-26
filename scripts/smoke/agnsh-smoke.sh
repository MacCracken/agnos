#!/bin/bash
# agnsh-smoke (1.41.4) — boots a PRODUCTION kernel against an ext2 rootfs that
# contains /bin/agnsh (the agnos-ABI build of the agnoshi shell). kybernet
# (PID 1) execs /bin/agnsh in ring 3 — the "first boot-to-agnsh-on-disk".
#
# PASS = kybernet reaches "exec /bin/agnsh", does NOT print "emergency
# shell" (i.e. agnsh launched, no fallback). Prints the boot tail for eyeball.
#
# Build first:  ./scripts/build.sh                       (plain production kernel)
# agnsh:        ../agnoshi/build/agnsh_agnos              (cyrius build --agnos ...)
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, strings.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built ($AGNSH) — 'cyrius build --agnos src/agnsh.cyr build/agnsh_agnos' in agnoshi"; exit 1; }

WORK="$ROOT/build/agnsh-smoke"; LOGS="$ROOT/build/agnsh-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
# ⭐ 1.57.7 (IMG-fix, reviews A6/B6): this smoke's verdict is about the PRODUCTION kernel — refuse any other.
# The wrappers that boot a flagged kernel through this harness (exec-redirect-smoke, syscall-harden-smoke) name
# the flags they built with in AGNSH_SMOKE_FLAGS. The check sits AFTER the log dir is cleared, so a refused run
# leaves no stale agnsh.log for a wrapper to read as if this boot had produced it.
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
smoke_require_image "$AGNOS" "${AGNSH_SMOKE_FLAGS:-}"
IMG="$WORK/agnos-agnsh.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AGNSH" "$SEED/bin/agnsh"
echo "seeded /bin/agnsh ($(stat -c%s "$SEED/bin/agnsh") bytes)"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AGNSH -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/agnsh.log"
echo "Booting production kernel (NVMe + ext2 with /bin/agnsh)..."
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
# 1.57.6 (S3): SMOKE_SMP=N boots with -smp N (default 1 = unchanged). A multi-CPU boot takes smoke_accel's
# KVM / multi-threaded-TCG accelerator (qemu-dwell.sh) and says which, so a -smp 4 verdict is attributable.
SMOKE_SMP="${SMOKE_SMP:-1}"
ACCEL="$(smoke_accel "$SMOKE_SMP")"
echo "accel: $ACCEL (-smp $SMOKE_SMP)"

# ⛔⛔ 1.56.51: RETRY ONLY WHEN THE KERNEL NEVER RAN — AND NEVER WHEN IT DID.
# Measured 2026-08-28: this smoke fails roughly 1 run in 4 on an otherwise idle box, and far more
# often under load (it failed 3 of 5 while a 12-agent audit was saturating the CPU). Every failing
# run has the same signature: the serial log ends in OVMF's "Please select boot device" menu and
# the kernel banner NEVER APPEARS. The firmware did not hand off, so the kernel under test never
# executed — the run measured nothing. Raising QEMU_TIMEOUT does not help; the menu is terminal,
# not slow. That flake cost a wrong bisect during the 1.56.51 sweep: a kernel change was blamed for
# a boot failure and then found to pass 2 of 3 re-runs on the identical binary.
# ⭐ THE RETRY IS PRINCIPLED, NOT BLIND, AND THAT DISTINCTION IS THE WHOLE POINT. "The kernel never
# started" and "the kernel started and failed an assertion" are different events and only the first
# is retryable. Gating on the banner keeps a REAL regression from being retried away — which is
# exactly the risk in sweep.sh's unconditional double-run, where a genuine failure gets two chances
# to look like a flake. If the banner is present, whatever the assertions say is the verdict.
# ⭐ 1.57.7 (IMG-fix, review A2): the hand-rolled retry loop that stood here became qemu_dwell_kernel. It retried on the
# banner alone and overwrote each attempt's log, so a kernel that died before its banner (the boot-stack
# window IMG moved) read as a firmware VOID and was retried away. qemu_dwell_kernel keeps every non-booted
# attempt as $LOG.attemptN, says why it is a VOID, and FAILS (exit 1) a kernel that took control and died.
# Default tries 3, as this smoke always had.
QEMU_TRIES="${QEMU_TRIES:-3}"
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-40}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M $ACCEL -smp "$SMOKE_SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
    -serial stdio -display none -no-reboot
qemu_assert_booted "$LOG" || { echo "agnsh-smoke: VOID"; exit 2; }

echo ""
echo "  --- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "kybernet: exec /bin/agnsh"; then
    echo "  PASS: kybernet attempted exec /bin/agnsh"
else
    echo "  FAIL: kybernet did not reach the agnsh exec"; rc=1
fi
if strings "$LOG" | grep -q "kybernet: emergency shell"; then
    echo "  FAIL: fell back to the in-kernel emergency shell (agnsh did not launch)"; rc=1
else
    echo "  PASS: did NOT fall back to the emergency shell"
fi
# ⛔⛔ 1.56.51 — THE TWO GATES ABOVE CANNOT DETECT agnsh DYING AT ITS FIRST SYSCALL, and this was
# MEASURED, not imagined: a deliberately-broken SYSCALL exit stub wedged the kernel the instant
# agnsh reached ring 3, the log ended at "kybernet: exec /bin/agnsh" with no banner and no fault
# line — and this smoke reported PASS. Both gates were satisfied: the exec WAS attempted, and the
# emergency-shell fallback never ran precisely BECAUSE the box was already dead. "kybernet tried"
# is a statement about kybernet, not about agnos; the only evidence agnsh actually RAN is output
# that agnsh itself produced. This is the same class as the four unfalsifiable gates the 1.56.51
# sweep found — a gate whose failure mode is indistinguishable from its success.
if strings "$LOG" | grep -q "agnoshi "; then
    echo "  PASS: agnsh reached ring 3 and printed its own banner"
else
    echo "  FAIL: no agnsh banner — it exec'd but produced no output (wedged before its first write)"; rc=1
fi
# ⭐ 1.57.7 (IMG-fix, A3): the BSP boot stack's span must be free RAM in the UEFI map the firmware handed over
# (mbi.cyr bootstack_window_check). The violation line is denied below; the OK line is REQUIRED here, so a kernel
# that stops running the check (or never reaches it) cannot pass by printing nothing.
if strings "$LOG" | grep -q "boot: BSP stack span 0x390000-0x3C0000 is free RAM in the UEFI map OK"; then
    echo "  PASS: BSP boot-stack span [0x390000, 0x3C0000) is free RAM in the UEFI map"
else
    echo "  FAIL: no 'boot: BSP stack span ... free RAM ... OK' line — the window check did not pass (or did not run)"; rc=1
fi
# ⭐ 1.57.7 (Path 2, S3.4): the voluntary-switch gate (vector 0xE0) must be installed DPL0 / IST0 / selector 0x08 at
# &resched_isr (sched.cyr resched_gates_ok). The misconfigured line is denied below; the OK line is REQUIRED here.
if strings "$LOG" | grep -q "sched: resched gate 0xE0 OK"; then
    echo "  PASS: the voluntary-switch gate 0xE0 is DPL0 / IST0 at resched_isr"
else
    echo "  FAIL: no 'sched: resched gate 0xE0 OK' line — the 0xE0 gate check did not pass (or did not run)"; rc=1
fi
# ⭐ 1.57.7 (Path 2, S3.8): the reschedule-KICK gate (vector 0xE1) the same way — DPL0 / IST0 / 0x08 at &resched_kick_isr.
if strings "$LOG" | grep -q "sched: resched gate 0xE1 OK"; then
    echo "  PASS: the reschedule-kick gate 0xE1 is DPL0 / IST0 at resched_kick_isr"
else
    echo "  FAIL: no 'sched: resched gate 0xE1 OK' line — the 0xE1 gate check did not pass (or did not run)"; rc=1
fi
# ⛔ 1.57.6 (S3-fix): the kernel's latched invariant lines (SMOKE_INVARIANT_DENY, qemu-dwell.sh) fire once to klug +
# COM1 and change no exit code — this gate scored PASS with them firing until it grepped for them.
if strings "$LOG" | grep -qE "$SMOKE_INVARIANT_DENY"; then
    echo "  FAIL: a latched kernel invariant line fired:"; strings "$LOG" | grep -E "$SMOKE_INVARIANT_DENY" | head -5 | sed 's/^/        /'; rc=1
else
    echo "  PASS: no latched kernel invariant line (non-ready pick, out-of-band asserts, kstack_check_entry, #DF)"
fi
echo ""
if [ "$rc" -eq 0 ]; then echo "agnsh-smoke: PASS"; else echo "agnsh-smoke: FAIL"; fi
exit $rc
