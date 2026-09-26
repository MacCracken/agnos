#!/bin/bash
# fork-smoke — does `fork`#96 actually produce a second process that resumes where the parent
# called it, diverges by return value, and gets its OWN copy of the parent's memory?
#
# ⛔ WHY THIS IS A RING-3 SMOKE AND NOT A KERNEL SELFTEST. fork's entire contract is the CALLER's
# resume context — the child must continue at the parent's post-SYSCALL RIP, on the parent's user
# stack, with rax = 0 — and `sys_fork` deliberately REFUSES a caller on the kernel CR3 for exactly
# that reason. There is no kernel-side test to write. `/bin/forker` forks and reports from both
# sides; the boot selftest runs it through the same `sh_exec("run ...")` path exec-from-disk uses,
# so "the program never ran" is distinguishable from "fork misbehaved".
#
# The five markers, in order, and what each one alone proves:
#   FORKER-ALIVE    the program ran at all (else it is a spawn problem, not a fork one)
#   FORK-CHILD      a SECOND process resumed at the fork site with rax == 0
#   FORK-CHILD-OK   the child saw the parent's pre-fork stack value, and could write its own copy
#   FORK-PARENT     the parent survived its own fork and got a POSITIVE pid
#   FORK-PARENT-OK  wait-any(-1) returned the child's exit code, AND the child's write was NOT
#                   visible to the parent — the full-copy property, which a shared mapping fails
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
AGNSH_BIN="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
FORKER="${FORKER_BIN:-$ROOT/tests/fork/build/forker_agnos}"
# ⛔⛔ 1.56.55 — BUILD BEFORE THE IMAGE IS ASSEMBLED. THIS WAS THE OTHER WAY ROUND AND THE GATE WAS
# MEASURING THE PREVIOUS COMMAND'S KERNEL. `mcopy … "$AGNOS" ::boot/agnos` ran at what is now line ~72
# while `FORK_SELFTEST=1 build.sh` ran ~7 lines LATER, so the ESP received whatever `build/agnos`
# happened to be lying around and the FORK_SELFTEST kernel this smoke exists to boot was compiled
# after the disk it should have been written to. A first run therefore booted a plain kernel, printed
# no FORK-* marker at all, and left the right kernel behind for NEXT time.
# ⭐ AND THAT IS WHY IT LOOKED GREEN: sweep.sh gives each smoke ONE retry, so attempt 1 failed while
# building the correct kernel and attempt 2 booted it and passed. The gate was passing on its own
# retry rather than on its subject, and would go red the moment the retry was removed or any other
# gate rebuilt build/agnos in between. Measured 2026-08-31: a single standalone run on a tree whose
# build/agnos was a plain kernel reported all five phase-1 markers absent.
# ⚠ The forker is rebuilt here too. It was NEVER rebuilt by this script — the seed copied a stale
# tests/fork/build/forker_agnos, so an edit to forker.cyr silently did not reach the boot.
echo "Building FORK_SELFTEST kernel + /bin/forker (before the image is assembled)..."
FORK_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "BUILD FAILED (kernel)"; exit 1; }
( cd "$ROOT/tests/fork" && cyrius build --agnos forker.cyr build/forker_agnos ) >/dev/null 2>&1 \
    || { echo "BUILD FAILED (forker)"; exit 1; }

[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH_BIN" ] || { echo "ERROR: agnsh-agnos not built ($AGNSH_BIN)"; exit 1; }
[ -f "$FORKER" ]    || { echo "ERROR: forker not built — run: cd tests/fork && cyrius build --agnos forker.cyr build/forker_agnos"; exit 1; }

WORK="$ROOT/build/fork-smoke"; LOGS="$ROOT/build/fork-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-agnsh.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AGNSH_BIN" "$SEED/bin/agnsh"
cp "$FORKER" "$SEED/bin/forker"
echo "seeded /bin/agnsh + /bin/forker ($(stat -c%s "$SEED/bin/forker") bytes)"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-FORKER -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting FORK_SELFTEST kernel (NVMe + ext2 with /bin/forker)..."
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"

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
# ⭐ 1.57.7 (S3d, S3.9): BOTH SMP BY DEFAULT — one invocation boots -smp 1 THEN -smp 4 (fork's child resumes through
# the scheduler, and the -smp 4 boot runs it on real parallel CPUs with KVM when /dev/kvm is writable — printed).
# Each boot goes through qemu_dwell_kernel (the classified, banner-gated retry: 6 tries) and qemu_assert_booted
# (a boot with no banner is VOID, never scored). SMOKE_SMP=N set explicitly keeps ONE boot at -smp N.
# Exit 0 only when every boot passed, 1 on any FAIL, 2 when a boot was VOID (and nothing failed).
SMPS="${SMOKE_SMP:-1 4}"
rc=0; nvoid=0
for SMP in $SMPS; do
LOG="$LOGS/agnsh-smp$SMP.log"
ACCEL="$(smoke_accel "$SMP")"
BIMG="$WORK/agnos-agnsh-smp$SMP.img"; cp "$IMG" "$BIMG"          # a fresh disk per boot (the first boot may write)
echo ""
echo "=== boot -smp $SMP  accel: $ACCEL ==="
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-40}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M $ACCEL -smp "$SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$BIMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FORKER" \
    -serial stdio -display none -no-reboot
if ! qemu_assert_booted "$LOG"; then echo "  VOID: [smp$SMP] the kernel never ran (not scored)"; nvoid=$((nvoid+1)); continue; fi

echo ""
echo "  --- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | sed 's/^/  /'
echo ""

rc=0
# ⭐ FORK-MULTI-* (1.56.55) is the TWO-CHILD phase, and it is the half that can actually fail.
# The five phase-1 markers proved the fork CONTRACT and passed even while `waitpid(-1)` was broken
# for every case with more than one child: a single child is the top proc slot, so the LIFO collapse
# in proc_reap_child deleted the row and the stale-ppid phantom could not form. FORK-MULTI-OK is the
# marker that goes red if either `store64(&proc_ppid + pid * 8, 0)` is removed from proc.cyr.
# ⭐ 1.57.7 (Path 2, S3.4): the forker runs TWICE — scheduled (kmain marks it READY; an IF=1 parent) and then in the
# FOREGROUND (`run /bin/forker`: an exec_and_wait child, an IF=0 parent that yields between its waitpid polls). Every
# marker must appear once per arm (exact-line count >= 2), and the phase-1 child must report IF=1 in BOTH arms:
# sys_fork forces IF in the child's RFLAGS, so a forked child is an ordinary scheduled process whatever its
# parent's IF (mutation M-C12 — the `| 0x200` removed — makes the foreground arm's child say FORKER-CHILD-IF=0).
for m in "FORKER-ALIVE" "FORK-CHILD" "FORK-CHILD-OK" "FORK-PARENT" "FORK-PARENT-OK" "FORK-MULTI-BEGIN" "FORK-MULTI-OK" "FORKER-CHILD-IF=1"; do
    mc=$(strings "$LOG" | grep -cx "\(\[[^]]*\] \)\{0,1\}$m")
    if [ "$mc" -ge 2 ]; then
        echo "  PASS: [smp$SMP] $m (x$mc: scheduled + foreground arms)"
    else
        echo "  FAIL: [smp$SMP] $m seen $mc time(s), want >= 2 (one per arm)"; rc=1
    fi
done
if strings "$LOG" | grep -q "FORKER-CHILD-IF=0"; then
    echo "  FAIL: [smp$SMP] a forked child ran with IF=0 (sys_fork must force IF in the child's RFLAGS)"; rc=1
else
    echo "  PASS: [smp$SMP] no forked child ran with IF=0"
fi
if strings "$LOG" | grep -q "fork: foreground SURVIVED back in kernel"; then
    echo "  PASS: [smp$SMP] the foreground (IF=0 parent) arm returned to the kernel"
else
    echo "  FAIL: [smp$SMP] the foreground arm never returned (hang or fault)"; rc=1
fi
# ⛔ The named failure lines the program emits are more informative than a missing marker — print any.
strings "$LOG" | grep -E "FORK-FAILED|FORK-COW-LEAK|FORK-WAIT-|FORK-CHILD-STACK-WRONG|FORK-CHILD-RSP-WRONG|FORK-CHILD-WRITE-WRONG|FORK-PARENT-STACK-CLOBBERED|FORK-MULTI-DUP|FORK-MULTI-GHOST|FORK-MULTI-TIMEOUT|FORK-MULTI-EARLY-NOCHILD|FORK-MULTI-WRONG-CODE|FORK-MULTI-NOFORK" | sed 's/^/  SAID: /'
# ⚠ The box must SURVIVE the fork — a child resuming on a bad context would fault or hang, and the
# selftest prints this only after sh_exec returns.
if strings "$LOG" | grep -q "fork: SURVIVED back in kernel"; then
    echo "  PASS: [smp$SMP] kernel resumed after the forked run"
else
    echo "  FAIL: [smp$SMP] never returned from the forked run (hang or fault)"; rc=1
fi
# ⛔ 1.57.6 (S3-fix): the kernel's latched invariant lines (SMOKE_INVARIANT_DENY, qemu-dwell.sh) fire once to klug +
# COM1 and change no exit code — this gate scored PASS with them firing until it grepped for them.
if strings "$LOG" | grep -qE "$SMOKE_INVARIANT_DENY"; then
    echo "  FAIL: [smp$SMP] a latched kernel invariant line fired:"; strings "$LOG" | grep -E "$SMOKE_INVARIANT_DENY" | head -5 | sed 's/^/        /'; rc=1
else
    echo "  PASS: [smp$SMP] no latched kernel invariant line (non-ready pick, out-of-band asserts, kstack_check_entry, #DF)"
fi
done
if [ "$rc" != "0" ]; then echo "fork-smoke: FAIL (smp: $SMPS)"; exit 1; fi
if [ "$nvoid" -ne 0 ]; then echo "fork-smoke: VOID ($nvoid boot(s) never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "fork-smoke: PASS (smp: $SMPS)"
exit 0
