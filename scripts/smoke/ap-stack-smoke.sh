#!/bin/sh
# ap-stack-smoke.sh — the AP boot/TSS stacks live in region 7, and kernel .rodata survives the wake (1.57.3).
#
# Builds an SMP_STACK_SELFTEST kernel, boots it under gnoboot + OVMF + NVMe with -smp 4 (smp-smoke.sh's
# recipe: 128 MB disk, ESP 1MiB..33MiB, nvme — the only geometry that hands off on this box, see the
# 1.56.51 note there) and asserts the runtime half of the relocation filed in
# docs/development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md:
#   · "smp: cpus online: 4"                 — INIT-SIPI-SIPI woke APs 1-3 and they counted in (the trampoline's
#                                             first push landed on a MAPPED stack; WHERE is the next assertion —
#                                             the old region-1 windows also count in, silently: see the mutation);
#   · "smpstk: ap N in region-7 window OK"   for N = 1, 2, 3 — each AP's live RSP, sampled in ap_entry
#                                             (pcpu_ap_rsp), lies in [DIRECTMAP_BASE + 0xFC0000,
#                                             DIRECTMAP_BASE + 0x1000000): the direct-map alias of the
#                                             region-7 AP window, per gdt.cyr tss_get_cpu_stack's map.
#                                             This is the TRAMPOLINE half (smp.cyr) only;
#   · "smpstk: ap N rsp0 at region-7 window top OK" for N = 1, 2, 3 — each AP's TSS.RSP0, read back
#                                             from tss_array while it still holds tss_get_cpu_stack's
#                                             value (sched_active == 0), EQUALS DIRECTMAP_BASE +
#                                             0xFD0000 + N*0x10000, the top the trampoline computed.
#                                             ⚠ 1.57.3 review: the gdt.cyr half. That RSP0 is dead
#                                             until a ring-3 proc lands on the AP (its CPL0 idle never
#                                             pushes through it, and the first real switch overwrites
#                                             it), so NEITHER other oracle can see it regress — a
#                                             tss_get_cpu_stack put back on region 1 scored PASS here
#                                             before this line existed (mutation (b) below);
#   · "smpstk: rodata intact after AP wake"  — the rekha chunk literals (the .rodata the 1.57.2 region-1
#                                             windows [0x310000, 0x340000) sat on) re-hashed IN PLACE after
#                                             the APs took timer frames still equal the generator FNV-1a-64.
#                                             ⭐ THE LOAD-BEARING ORACLE: a stack anywhere in the image
#                                             scribbles here on every tick, and no -smp 1 gate can see it;
#   · "kybernet:"                            — boot continuity past the wake with 4 CPUs online.
#   FORBIDDEN: "OUT OF WINDOW", "rsp0 NOT the region-7 top", "CORRUPTED".
# VOID (exit 2, neither PASS nor FAIL) when the kernel banner never appeared: UEFI did not hand off, so
# nothing in the log describes the kernel under test (qemu_dwell_kernel retries that case, banner-gated).
#
# ⭐ MUTATION-PROVEN 2026-09-13 (1.57.3; restored byte-exact, sha256 + cmp against the pre-mutation
# copies): the trampoline put back on `add eax, 0x310000` WITHOUT the direct-map rebase (smp.cyr) and
# tss_get_cpu_stack put back on 0x300000 + cpu_id * 0x10000 + 0x10000 (gdt.cyr) — the exact 1.57.2
# placement — still booted to "smp: cpus online: 4" and to the kybernet lines (the corruption is SILENT,
# exactly the finding) and printed, verbatim:
#     smpstk: ap 1 rsp=0x31ffa8        smpstk: ap 1 OUT OF WINDOW
#     smpstk: ap 2 rsp=0x32ffa8        smpstk: ap 2 OUT OF WINDOW
#     smpstk: ap 3 rsp=0x33ffa8        smpstk: ap 3 OUT OF WINDOW
#     smpstk: rodata CORRUPTED by AP stacks
# -> "ap-stack-smoke: FAIL", exit 1. BOTH stack oracles trip on the old layout (the 0x3?FFA8 samples are
# 88 B under the old tops 0x320000 / 0x330000 / 0x340000, inside the chunk literals). The restored tree
# prints
#     smpstk: ap 1 rsp=0x200fdffa8 / ap 2 rsp=0x200feffa8 / ap 3 rsp=0x200ffffa8  (three "... OK")
#     smpstk: ap 1 rsp0=0x200fe0000 / ap 2 rsp0=0x200ff0000 / ap 3 rsp0=0x201000000  (three "... top OK")
#     smpstk: rodata intact after AP wake
# -> PASS, exit 0.
# ⭐ MUTATION (b), 2026-09-13 (1.57.3 review; gdt.cyr restored byte-exact, sha256 + cmp): tss_get_cpu_stack
# ALONE put back on `0x300000 + cpu_id * 0x10000 + 0x10000`, the trampoline left correct. That kernel is
# the 1.57.2 TSS placement inside .rodata — and it passed every line above except the rsp0 ones, verbatim:
#     smpstk: ap 1 rsp=0x200fdffa8       smpstk: ap 1 in region-7 window OK
#     smpstk: ap 1 rsp0=0x320000         smpstk: ap 1 rsp0 NOT the region-7 top
#     smpstk: ap 2 rsp0=0x330000         smpstk: ap 2 rsp0 NOT the region-7 top
#     smpstk: ap 3 rsp0=0x340000         smpstk: ap 3 rsp0 NOT the region-7 top
#     smpstk: rodata intact after AP wake        (+ "smp: cpus online: 4", the kybernet lines)
# -> "ap-stack-smoke: FAIL", exit 1 — on the rsp0 lines ONLY. That is the point: the stale RSP0 is never
# used as a stack before the first real switch replaces it, so the in-place hash cannot see it, and
# mutation (a)'s evidence was produced entirely by the trampoline half. Without this oracle the gdt.cyr
# half of the relocation had no gate at all.
#
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built, cyrius (+ ../rekha or the REKHA_REF
# clone, which scripts/build.sh resolves).
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF not found"; exit 1; }

echo "[1/3] Building the SMP_STACK_SELFTEST kernel..."
if ! env SMP_STACK_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/ap-stack-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/ap-stack-kbuild.log)"; tail -8 /tmp/ap-stack-kbuild.log; exit 1
fi
[ -f "$AGNOS" ] || { echo "ERROR: agnos not built"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/ap-stack-smoke"; LOGS="$ROOT/build/ap-stack-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"; LOG="$LOGS/ap-stack.log"
# smp-smoke.sh's proven -smp 4 recipe, verbatim: {1MiB..33MiB ESP on a 128 MB disk} x {nvme}.
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "[2/3] Booting gnoboot+OVMF+NVMe, -smp 4 (-cpu max, TCG — smp-smoke.sh's recipe)..."
# ⚠ qemu_dwell_kernel: banner-gated retry, a fresh vars.fd per attempt, and the log is read only after
# QEMU has exited. The marker is the shell prompt: every smpstk line and the kybernet launch are printed
# from main.cyr BEFORE kybernet execs the shell, so they are in the log by the time it appears (this
# ESP carries no /bin/agnsh, so the prompt is the emergency shell's — the same shape smp-smoke gates).
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-90}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
    -serial stdio -display none -no-reboot

echo "[3/3] Checks..."
# ⛔ NON-VACUITY FLOOR: did the kernel run at all? If the banner never appeared, UEFI did not hand off and
# nothing below describes the kernel under test. VOID is neither PASS nor FAIL — say so, and exit non-zero
# so a caller cannot score it green.
if ! strings "$LOG" 2>/dev/null | grep -q "AGNOS kernel v"; then
    echo "  VOID: kernel banner never appeared — UEFI did not hand off; the kernel under test did not execute."
    echo "        Not an AP-stack result. Log: $LOG"
    echo ""
    echo "ap-stack-smoke: VOID (kernel never ran)"
    exit 2
fi
echo "  --- smp / smpstk serial lines ---"
strings "$LOG" | grep -aE "smp: |smpstk: |kybernet:|PANIC|Double Fault" | sed 's/^/  /' | head -24
rc=0
strings "$LOG" | grep -q "smp: cpus online: 4" \
    && echo "  PASS: smp: cpus online: 4 — APs 1-3 woke and counted in (where their stacks ARE is the next three lines)" \
    || { echo "  FAIL: no 'smp: cpus online: 4' — the AP wake did not complete (a bad stack VA faults an AP with no IDT to report it)"; rc=1; }
for n in 1 2 3; do
    if strings "$LOG" | grep -q "smpstk: ap $n in region-7 window OK"; then
        echo "  PASS: ap $n RSP in [DIRECTMAP_BASE + 0xFC0000, DIRECTMAP_BASE + 0x1000000) ($(strings "$LOG" | grep -o "smpstk: ap $n rsp=0x[0-9A-Fa-f]*" | head -1))"
    elif strings "$LOG" | grep -q "smpstk: ap $n OUT OF WINDOW"; then
        echo "  FAIL: ap $n OUT OF WINDOW ($(strings "$LOG" | grep -o "smpstk: ap $n rsp=0x[0-9A-Fa-f]*" | head -1)) — the AP's BOOT stack is not in the region-7 window (smp.cyr trampoline regressed)"; rc=1
    else
        echo "  FAIL: no verdict for ap $n — it never reached the sample (not online) or the selftest did not run"; rc=1
    fi
    # The gdt.cyr half: TSS.RSP0 must be THE window top the trampoline set, not merely somewhere in region 7.
    if strings "$LOG" | grep -q "smpstk: ap $n rsp0 at region-7 window top OK"; then
        echo "  PASS: ap $n TSS.RSP0 == DIRECTMAP_BASE + 0xFD0000 + $n*0x10000 ($(strings "$LOG" | grep -o "smpstk: ap $n rsp0=0x[0-9A-Fa-f]*" | head -1))"
    elif strings "$LOG" | grep -q "smpstk: ap $n rsp0 NOT the region-7 top"; then
        echo "  FAIL: ap $n rsp0 NOT the region-7 top ($(strings "$LOG" | grep -o "smpstk: ap $n rsp0=0x[0-9A-Fa-f]*" | head -1)) — tss_get_cpu_stack (gdt.cyr) no longer hands this AP the trampoline's window top"; rc=1
    else
        echo "  FAIL: no rsp0 verdict for ap $n — the selftest did not read its TSS slot (not online, or a build without the 1.57.3 rsp0 oracle)"; rc=1
    fi
done
if strings "$LOG" | grep -q "smpstk: rodata intact after AP wake"; then
    echo "  PASS: rekha chunk literals re-hashed IN PLACE after the wake == generator FNV-1a-64 (no AP stack is in the image)"
elif strings "$LOG" | grep -q "smpstk: rodata CORRUPTED by AP stacks"; then
    echo "  FAIL: rodata CORRUPTED by AP stacks — the in-place hash of the chunk literals changed after the wake: an AP stack is inside the kernel image again"; rc=1
else
    echo "  FAIL: no rodata verdict line — the selftest did not run to its hash (build without SMP_STACK_SELFTEST, or a hang before it)"; rc=1
fi
strings "$LOG" | grep -q "kybernet:" \
    && echo "  PASS: kybernet launched — boot continuity with 4 CPUs online" \
    || { echo "  FAIL: kybernet never launched post-wake"; rc=1; }
strings "$LOG" | grep -qE "PANIC|Double Fault" \
    && { echo "  FAIL: a ring-0 PANIC / Double Fault line appeared in the log"; rc=1; } \
    || echo "  PASS: no ring-0 PANIC / Double Fault line"

echo ""
[ "$rc" -eq 0 ] && echo "ap-stack-smoke: PASS — AP1-3 boot/TSS stacks in region 7 (direct-map), kernel .rodata intact after the wake (1.57.3)" || echo "ap-stack-smoke: FAIL"
exit $rc
