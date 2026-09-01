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

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/agnsh.log"
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
QEMU_TRIES="${QEMU_TRIES:-3}"
qtry=1
while [ "$qtry" -le "$QEMU_TRIES" ]; do
    cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
    qemu_dwell "$LOG" "agnos>" "${QEMU_TIMEOUT:-40}" \
        qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-FORKER" \
        -serial stdio -display none -no-reboot
    if strings "$LOG" | grep -q "AGNOS kernel v"; then break; fi
    if [ "$qtry" -lt "$QEMU_TRIES" ]; then
        echo "  (firmware never handed off — kernel did not start; retrying $qtry/$((QEMU_TRIES - 1)))"
    else
        echo "  UEFI never handed off to the kernel in $QEMU_TRIES attempts — INFRASTRUCTURE, not the kernel."
        echo "  The assertions below therefore describe nothing; treat this run as VOID, not as a failure."
    fi
    qtry=$((qtry + 1))
done

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
for m in "FORKER-ALIVE" "FORK-CHILD" "FORK-CHILD-OK" "FORK-PARENT" "FORK-PARENT-OK" "FORK-MULTI-BEGIN" "FORK-MULTI-OK"; do
    if strings "$LOG" | grep -q "$m"; then
        echo "  PASS: $m"
    else
        echo "  FAIL: $m absent"; rc=1
    fi
done
# ⛔ The named failure lines the program emits are more informative than a missing marker — print any.
strings "$LOG" | grep -E "FORK-FAILED|FORK-COW-LEAK|FORK-WAIT-|FORK-CHILD-STACK-WRONG|FORK-CHILD-WRITE-WRONG|FORK-PARENT-STACK-CLOBBERED|FORK-MULTI-DUP|FORK-MULTI-GHOST|FORK-MULTI-TIMEOUT|FORK-MULTI-EARLY-NOCHILD|FORK-MULTI-WRONG-CODE|FORK-MULTI-NOFORK" | sed 's/^/  SAID: /'
# ⚠ The box must SURVIVE the fork — a child resuming on a bad context would fault or hang, and the
# selftest prints this only after sh_exec returns.
if strings "$LOG" | grep -q "fork: SURVIVED back in kernel"; then
    echo "  PASS: kernel resumed after the forked run"
else
    echo "  FAIL: never returned from the forked run (hang or fault)"; rc=1
fi
[ "$rc" = "0" ] && echo "fork-smoke: PASS" || echo "fork-smoke: FAIL"
exit $rc
