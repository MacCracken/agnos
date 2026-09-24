#!/bin/bash
# ring3-smoke (1.44.4 one proc / .5 two procs / .6 syscalls / .7 concurrent exec+exit) —
# boots agnos under qemu + OVMF + gnoboot with RING3_SELFTEST=1 and asserts:
#   "ring3: child exited"— proc B (1.44.8: a real in-memory ELF64 loaded by elf_load, the
#                          spawn-#3 loader; own CR3, IF=1) runs a FINITE program (count to
#                          N then `exit` #0) to completion and is cleanly retired (state=0,
#                          NOT resurrected), WHILE proc A (a second ring-3 proc making
#                          getpid syscalls) keeps running. The "a program runs to completion
#                          while another stays live" core, from an actual ELF binary.
#   "ring3: preempt OK" — proc A stayed live + preemptible through B's exit (counter > 0).
#   "ring3: gate held"  — under preempt_disable() proc A's counter FREEZES => the
#                          1.44.0 preempt gate covers ring-3 too.
#   "wx: RWX segment refused" — 1.57.2 W^X CLOSED. ring3_wx_check hands elf_load a copy of the
#                          proc-B ELF re-flagged p_flags = R|W|X; the loader must refuse it
#                          (elf.cyr, the `(p_flags & 3) == 3` arm). "wx: RWX segment LOADED" is
#                          the mutation marker and is FORBIDDEN. Proven 1.57.2: reverting one
#                          refusal site turns this red; restoring it turns it green.
#
# Build first:  RING3_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — RING3_SELFTEST=1 ./scripts/build.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "ring3: preempt OK"; then
    echo "ERROR: kernel was not built with RING3_SELFTEST=1" >&2
    echo "       rebuild: RING3_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found"; exit 1; }

WORK="$ROOT/build/ring3-smoke"; LOGS="$ROOT/build/ring3-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
# ⛔⛔ 1.56.51 — THIS SMOKE'S ESP RECIPE COULD NOT BOOT, AND THE FAILURE LOOKED LIKE THE KERNEL.
# Isolated by a 2x2 over {ESP geometry} x {block device}, one QEMU run per cell: ONLY
# {1MiB..33MiB on a 128 MB disk} x {nvme} hands off. The old `mkpart ESP fat32 1MiB 100%` on a 64 MB
# disk yields a 63 MiB FAT32 at 1 sector/cluster (129024 clusters) that OVMF's FAT driver will not
# boot, and virtio-blk does not boot on this box under EITHER geometry. Both had to change.
# ⚠ The visible symptom was NOT "no boot" — it was the smoke's own assertions grepping an empty log
# and reporting a wall of red naming real regression guards. 25 smokes shared this copy-pasted
# recipe, four of them gates in sweep.sh. See scripts/smoke/edge-abi-smoke.sh for the measurement.
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

echo "=== AGNOS 1.44.x preemptive ring-3 smoke ==="
LOG="$LOGS/ring3.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
# 1.57.6 (S3): SMOKE_SMP=N boots with -smp N (default 1 = unchanged); see smoke_accel in qemu-dwell.sh.
SMOKE_SMP="${SMOKE_SMP:-1}"
ACCEL="$(smoke_accel "$SMOKE_SMP")"
echo "accel: $ACCEL (-smp $SMOKE_SMP)"
# ⛔⛔ 1.56.55 — 40 s WAS TOO SHORT AND THE TAIL OF THE SELFTEST FELL OFF THE END. RING3_SELFTEST
# runs ~10 sub-tests, and the last three markers (`ring3: yield OK`, `ring3: gate held`, `ring3: done`)
# landed after the dwell expired, so the smoke reported them "not found". That read as two defects that
# do not exist: `gate held` looked like a DETERMINISTIC preempt-gate regression (it never printed), and
# `yield OK` looked FLAKY (it printed only when the boot happened to get that far). Measured: at
# QEMU_TIMEOUT=120 all eight assertions pass and `ring3: done` prints; at 40 the log simply stops
# mid-selftest, most often right after the `ring3: Y= A=` line — with the ratio it needed already in it.
# ⭐ THE TELL WAS IN THE LOG THE WHOLE TIME: `ring3: Y=54 A=38284` satisfies `A > Y*10` by 70x, and the
# very next statement is the `yield OK` kprintln. A missing marker whose PRECONDITION is visible in the
# line above it is a truncated log, not a failed assertion.
# ⚠ 1.57.2 — qemu_dwell_kernel, NOT qemu_dwell. Two consecutive baseline runs of this smoke died in
# the firmware ("gnoboot: fail @ EBS", then the OVMF boot menu) before the kernel ran once, and each
# reported 0 PASS / 8 FAIL against an EMPTY log — the exact void-run-read-as-regression the helper's
# header documents. Retries are banner-gated, so a kernel that boots and then fails gets no second try.
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-120}" "$WORK/vars.fd" "$OVMF_VARS" \
    qemu-system-x86_64 \
    -machine q35 -m 512M $ACCEL -smp "$SMOKE_SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
    -serial stdio -display none -no-reboot

echo "--- serial (ring3 lines) ---"; strings "$LOG" | grep -E "ring3:|wx:|elf:" | sed 's/^/  /'
rc=0; np=0; nf=0
pass_() { echo "PASS: $1"; np=$((np+1)); }
fail_() { echo "FAIL: $1"; nf=$((nf+1)); rc=1; }
# 1.57.2 W^X refusal gate — BOTH halves: the refused marker must be present AND the loaded marker absent.
if strings "$LOG" | grep -q "wx: RWX segment refused"; then pass_ "elf_load REFUSED a PT_LOAD flagged R|W|X (W^X closed, 1.57.2)"; else fail_ "'wx: RWX segment refused' not found — the W^X refusal in elf.cyr is gone, or ring3_wx_check no longer runs"; fi
if strings "$LOG" | grep -q "wx: RWX segment LOADED"; then fail_ "'wx: RWX segment LOADED' present — elf_load MAPPED an R|W|X segment (W^X refusal regressed)"; fi
if strings "$LOG" | grep -q "ring3: child exited"; then pass_ "a scheduled ring-3 proc (real ELF via elf_load) ran to completion + exit()ed cleanly while another stayed live"; else fail_ "'ring3: child exited' not found — concurrent exec / exit() regression"; fi
if strings "$LOG" | grep -q "ring3: preempt OK"; then pass_ "the surviving ring-3 proc stayed live + preemptible through the child's exit"; else fail_ "'ring3: preempt OK' not found — the live proc never advanced (or triple-faulted)"; fi
if strings "$LOG" | grep -q "ring3: gate held"; then pass_ "the preempt gate freezes ring-3 procs too"; else fail_ "'ring3: gate held' not found — preempt gate regression for ring-3"; fi
if strings "$LOG" | grep -q "ring3: parent spawn+wait OK"; then pass_ "a ring-3 PARENT spawn(#3)ed a child ELF + poll-waitpid(#4)ed it to exit — entirely from ring 3 (spawn#3 kernel-CR3 fix end-to-end)"; else fail_ "'ring3: parent spawn+wait OK' not found — ring-3 spawn+waitpid regression (child #UD / mis-wired tables under parent CR3)"; fi
if strings "$LOG" | grep -q "ring3: stress OK"; then pass_ ">=8 concurrent ring-3 procs (code/stack in PD[8..63]) all stayed live — the page-table VA-collision fix holds (pre-fix this triple-faults in proc_get_user_cr3's PML4 load64)"; else fail_ "'ring3: stress OK' not found — page-table VA-collision (a context switch SMAP-faulted on a user-flagged PML4, or a stress proc died)"; fi
if strings "$LOG" | grep -q "ring3: nonlifo reuse OK"; then pass_ "a NON-TOP reaped proc-table slot was REUSED by the next spawn (non-LIFO reclaim) — out-of-order background-job exits no longer leak proc_table slots"; else fail_ "'ring3: nonlifo reuse OK' not found — out-of-order reap leaks its proc_table slot (append-only allocation regression)"; fi
if strings "$LOG" | grep -q "ring3: nonlifo signal clear OK"; then pass_ "a recycled proc-table slot does not inherit the prior occupant's pending signals/mask (proc_alloc_slot clears them)"; else fail_ "'ring3: nonlifo signal clear OK' not found — recycled slot inherited stale signal state"; fi
# ⛔ 1.57.6 (S3-fix): the kernel's latched invariant lines (SMOKE_INVARIANT_DENY, qemu-dwell.sh) change no exit code.
if strings "$LOG" | grep -qE "$SMOKE_INVARIANT_DENY"; then fail_ "a latched kernel invariant line fired: $(strings "$LOG" | grep -E "$SMOKE_INVARIANT_DENY" | head -3 | tr '\n' ' ')"; else pass_ "no latched kernel invariant line (non-ready pick, out-of-band asserts, kstack_check_entry, #DF)"; fi
if strings "$LOG" | grep -q "ring3: yield OK"; then pass_ "sched_yield #44 — the yielder resumed at the post-SYSCALL RIP with rax=0 AND donated its slice (non-yielder counter >> 10x yielder)"; else fail_ "'ring3: yield OK' not found — yield round-trip broke or the slice was not donated (see 'ring3: Y= A=' line)"; fi
echo ""
echo "=== ring3-smoke: $np passed, $nf failed ==="
exit $rc
