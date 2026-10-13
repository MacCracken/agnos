#!/bin/sh
# AGNOS kernel functional test suite
# Boots agnos in QEMU (gnoboot + OVMF) with core/boot_finish.cyr rewritten to
# run sh_cmd_test() — the in-kernel `test` shell verb (user/test.cyr) — in place
# of the kybernet launch, then parses the serial PASS/FAIL/TOTAL output.
# Exit code: 0 = all passed, 1 = failures / harness error / the kernel died, 2 = VOID (the firmware never
# handed off to the kernel in QEMU_TRIES attempts — the suite never executed; re-run, it is not a kernel verdict).
# ⭐ 1.57.7 (HAR): the boot goes through qemu_dwell_kernel (scripts/smoke/lib/qemu-dwell.sh) — a banner-gated
# retry that classifies each attempt booted / died / VOID. Until 1.57.7 a firmware hand-off that never happened
# (`gnoboot: fail @ EBS`, no "AGNOS kernel v" line) printed "ERROR: test output not found (kernel may have
# crashed …)" and exited 1 — indistinguishable from a kernel that died; S3c's M-E3/M-E5 runs hit exactly that.
# The serial log is kept at build/ktest-logs/ktest.log (and each VOID attempt as ktest.log.attemptN).
# ⭐ 1.57.12 — A KTEST BUILD'S BOOT SELF-TESTS ARE SCORED. `KTEST=1 sh scripts/ktest.sh` boots a kernel that runs the
# core/main.cyr KTEST self-tests (syscall, context switch, VFS/initrd, userland exec, the NVMe write round-trips) BEFORE
# the in-kernel suite, and this script scored only the suite's TOTAL line: a self-test that printed FAIL — or never ran
# — still ended in "RESULT: ALL TESTS PASSED". When build/agnos.flags says KTEST, every line in KTEST_REQUIRE (below)
# must be in the log and none of KTEST_DENY. Every build must also show the boot disk's GPT intact (KTEST_GPT_LINE).
# Env: KTEST=1 (that build) · KTEST_SMP (default 1; the -smp count — above 1 the boot takes smoke_accel's accelerator,
# KVM or multi-threaded TCG, and prints it) · QEMU_TIMEOUT (default 90) · KTEST_KVM=0 (force TCG at -smp 1).
# ⭐ 1.57.10 (HAR2 — issue 2026-09-26-harness-backlog-after-1-57-9, item 1): THIS SCRIPT LEAVES A PLAIN build/agnos.
# It used to leave its TEST kernel there, and the next plain-kernel smoke was REFUSED by smoke_require_image
# ("built with [TEST]", measured by SMOKES3 at 1.57.9: agnsh-smoke straight after ktest). The TEST kernel is now
# booted from its COPY build/agnos_ktest, and the tree is rebuilt PLAIN right after that copy, before the boot
# (the blk-write/msc-cdb pattern). An EXIT trap does the same on every other way out once the TEST build has
# started: a failed build, ^C, TERM. The order in that trap matters. boot_finish.cyr is restored FIRST,
# because a plain build of the REWRITTEN source calls sh_cmd_test() with no TEST define and refuses to link.
# The plain build's output is build/ktest-logs/build-plain.log.
#
# History (why this is a rewrite, not the original): pre-1.36.2 this script
# sed-patched core/main.cyr + user/test_procs.cyr and booted the ELF32 kernel
# via `qemu -kernel`. Both went stale:
#   - The shell launch left main.cyr for core/boot_finish.cyr at the 1.36.2
#     split, so the old `sh_cmd_bench(); arch_halt();` patch silently no-op'd.
#   - The legacy `qemu -kernel` ELF32 entry hangs in apic_init under modern
#     QEMU (see scripts/bench.sh) — every smoke now boots via gnoboot + OVMF.
#   - fb_console.cyr references KASHI_FONT_VGA_8X16 (1.37.5 kashi fold-in), so a
#     bare `cyrius build` fails 'undefined KASHI_FONT_VGA_8X16'; the font-data
#     prepend lives in scripts/build.sh only.
# This harness now mirrors scripts/bench.sh: rewrite boot_finish.cyr, delegate
# the build (kashi prepend + ELF64/multiboot2 gates) to scripts/build.sh, and
# boot via gnoboot + OVMF. build.sh is the ONE place the kashi injection lives.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"

if [ ! -x "$CYRB" ]; then
    echo "ERROR: cyrius required at $CYRB" >&2; exit 1
fi

echo "Building AGNOS with test suite..."
# Rewrite the kybernet() launch in core/boot_finish.cyr to run sh_cmd_test()
# then halt. boot_finish.cyr is where the launch site moved at the 1.36.2 split
# (main.cyr no longer holds `kybernet();`). sh_cmd_test() (user/test.cyr) runs
# the in-kernel PMM/heap/VFS/proc/syscall/kstdlib/initrd checks and prints the
# `=== AGNOS Kernel Test Suite ===` / `TOTAL:` / `ALL TESTS PASSED` markers
# parsed below. No userland is execed and no rootfs is needed. ⚠ The test
# initrd is built ONLY by a KTEST build (main.cyr's KTEST VFS/initrd block, at
# 0x6000), so a plain run fails the three [initrd] checks that need it (370
# executed, 367 passed); `KTEST=1 sh scripts/ktest.sh` passes them and executes
# two more inside test_initrd's open branch (372, all passed at 1.57.12).
BFIN_CYR="$ROOT/kernel/core/boot_finish.cyr"
# `.ktestbak` (not `.bak`): a plain `.bak` suffix collides with the committed
# `*.cyr.bak` cruft the kernel tree carries — and historically THIS script
# corrupted core/main.cyr by cp'ing an already-patched file over its `.bak`
# (its restore never ran because `set -e` exited on the build failure first).
# `.ktestbak` + the EXIT/INT/TERM trap below make that class of bug impossible.
BFIN_BAK="$BFIN_CYR.ktestbak"
cp "$BFIN_CYR" "$BFIN_BAK"
KLOGS="$ROOT/build/ktest-logs"
rm -rf "$KLOGS"; mkdir -p "$KLOGS"

# Restore boot_finish.cyr no matter how we exit (build error, QEMU failure,
# parse failure, ^C). Set BEFORE the sed so any failure path restores.
restore_sources() {
    [ -f "$BFIN_BAK" ] && mv -f "$BFIN_BAK" "$BFIN_CYR"
}
# 1.57.10 (HAR2): once the TEST build has started, build/agnos is left PLAIN (see the header). A no-op
# before that point, and after the explicit restore below (KTEST_BUILT goes back to 0).
KTEST_BUILT=0
# ⭐ 1.57.12: the restore build runs with EVERY build.sh flag variable unset — the names inside `[ -n "$NAME" ]` on
# build.sh's `#define` lines — so it is plain even when the caller exported a flag. `KTEST=1 sh scripts/ktest.sh` (how
# the KTEST boot self-tests run) used to leave build/agnos built with flags=KTEST: the restore inherited the caller's
# KTEST=1, and smoke_require_image refuses that image in every plain smoke run after it.
KTEST_FLAG_VARS=$(grep '#define' "$ROOT/scripts/build.sh" | grep -o '\[ -n "\$[A-Z0-9_]*" \]' | sed 's/.*\$\([A-Z0-9_]*\).*/\1/' | sort -u)
restore_plain() {
    [ "$KTEST_BUILT" = 1 ] || return 0
    KTEST_BUILT=0
    echo "Restoring a PLAIN build/agnos (the TEST kernel boots from build/agnos_ktest)..." >&2
    ( for v in $KTEST_FLAG_VARS; do unset "$v"; done
      sh "$ROOT/scripts/build.sh" ) > "$KLOGS/build-plain.log" 2>&1 \
        || echo "WARN: could not restore the plain build/agnos — run: sh scripts/build.sh (log: $KLOGS/build-plain.log)" >&2
}
# Sources FIRST: a plain build of the rewritten boot_finish.cyr would call sh_cmd_test() without TEST.
ktest_exit() { restore_sources; restore_plain; }
trap ktest_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Guard the call-site rewrite: if the launch site ever moves or is renamed (as it
# did at the 1.36.2 split), the sed would silently no-op and sh_cmd_test() would
# never be wired in — the kernel would boot normally into agnsh and emit zero test
# markers. Fail loud instead. Expect exactly one.
#
# ⛔ THIS GUARD DID ITS JOB AND THE FIX WAS NEVER MADE. boot_finish.cyr grew a
# `power_quiesce_devices()` call between kybernet() and arch_halt() on 2026-07-19;
# from then until 1.56.44 this script matched 0 and exited 1 on every invocation —
# so `sh scripts/ktest.sh` had been dead for three weeks and every QEMU kernel-test
# claim in that window rests on nothing. The guard fired correctly; nobody ran it.
# That is the same defect class as host-gpu-oracles.sh being absent from CI.
#
# ⚠ Match the FULL launch line, not a substring. `arch_halt();` alone still appears in
# boot_finish.cyr (the no-shell fallback at :31), so a loosened pattern would double-match
# and the exact-count check below would reject a tree that is actually fine — or worse, a
# `kybernet();`-only pattern would rewrite the call while leaving the guard's own error text
# describing a line that no longer exists.
# ⚠ power_stop_final() is PRESERVED across the rewrite: the test path must stop exactly as
# production does, or ktest measures a different shutdown.
#
# ⭐ 1.56.60 — THIS CONTRACT CHANGED, DELIBERATELY, AND THIS SCRIPT WAS UPDATED WITH IT.
# boot_finish.cyr:27 was `kybernet(); power_quiesce_devices(); arch_halt();` until 1.56.60,
# when the bare quiesce+halt tail became the named terminus power_stop_final() (core/power.cyr)
# so that the non-syscall stop path also disarms the modeset latch and prints a line saying the
# box is stopped. power_stop_final() CONTAINS the power_quiesce_devices() this script used to
# preserve by name, so the test path still quiesces exactly as production does — it now also
# gets the disarm, which no-ops silently when no latch is armed (modeset_latch.cyr:391).
# ⛔ IF YOU CHANGE boot_finish.cyr's LAUNCH LINE AGAIN, CHANGE scripts/bench.sh IN THE SAME
# COMMIT. That line has silently killed this script for three weeks and bench.sh for six.
BFIN_LAUNCH='kybernet(); power_stop_final();'
BFIN_MATCHES=$(grep -c "$BFIN_LAUNCH" "$BFIN_CYR" || true)
if [ "$BFIN_MATCHES" -ne 1 ]; then
    echo "ERROR: ktest.sh expected exactly 1 '$BFIN_LAUNCH' launch site in $BFIN_CYR, found $BFIN_MATCHES" >&2
    echo "       the test entry-point rewrite would no-op — boot_finish.cyr's launch site diverged from ktest.sh's contract." >&2
    exit 1
fi
sed -i 's/kybernet(); power_stop_final();/sh_cmd_test(); power_stop_final();/' "$BFIN_CYR"
# ⭐ ASSERT THE REWRITE LANDED, mirroring bench.sh. The count check above proves the pattern was
# PRESENT; it does not prove the sed replaced it, and a guard that only checks its precondition is
# how the 2026-07-19 break stayed invisible for three weeks.
grep -q 'sh_cmd_test(); power_stop_final();' "$BFIN_CYR" || {
    echo "ERROR: ktest.sh's entry-point rewrite did not land in $BFIN_CYR" >&2
    exit 1
}

# Build the PRODUCTION ELF64 kernel (kybernet→sh_cmd_test already rewritten).
# scripts/build.sh owns the kashi font-data prepend + the ELF64/multiboot2
# gates (CYRIUS_ELF64_KERNEL=1, #define ELF64_KERNEL) + the multiboot2
# validation. TEST=1 makes build.sh prepend `#define TEST`, which compiles in
# user/test.cyr (sh_cmd_test + the test suite) and the shell `test` verb — both
# gated by `#ifdef TEST`; without it the rewritten sh_cmd_test() call is an
# undefined function and the build refuses to emit. The test kernel must take
# the SAME ELF64 path the real kernel does — the legacy `qemu -kernel` ELF32
# entry hangs in apic_init under modern QEMU, so ktest (like bench + every
# smoke) boots via gnoboot + OVMF below.
KTEST_BUILT=1
TEST=1 sh "$ROOT/scripts/build.sh" >&2
cp "$ROOT/build/agnos" "$ROOT/build/agnos_ktest"
# 1.57.12: what the TEST kernel was built with, read before restore_plain rewrites build/agnos.flags.
KTEST_BUILD_FLAGS=$(sed -n 's/^flags=//p' "$ROOT/build/agnos.flags" 2>/dev/null | head -1)

# Sources restored, then build/agnos rebuilt PLAIN before the boot (the boot uses the copy). Both are then
# done, so the traps are cleared: a later exit has nothing left to restore.
restore_sources
restore_plain
trap - EXIT INT TERM
sed -n 's/^flags=/  build\/agnos restored: flags=/p' "$ROOT/build/agnos.flags" 2>/dev/null | sed 's/flags=$/flags= (plain)/'

KTEST_SMP="${KTEST_SMP:-1}"
case "$KTEST_SMP" in ''|*[!0-9]*|0) echo "ERROR: KTEST_SMP='$KTEST_SMP' is not a CPU count" >&2; rm -f "$ROOT/build/agnos_ktest"; exit 1 ;; esac
echo "Booting test kernel via gnoboot + OVMF (-smp $KTEST_SMP, ${QEMU_TIMEOUT:-90}s dwell per attempt, banner-gated retry)..."
# gnoboot is the only ELF64 entry path (QEMU rejects the ELF64 kernel on its
# Linux `-kernel` protocol — no PVH note). Build a minimal GPT/ESP image with
# gnoboot + /boot/agnos; the kernel reaches core/boot_finish.cyr, runs
# sh_cmd_test() in place of kybernet(), then arch_halt()s. Mirrors bench.sh's
# OVMF plumbing, minus the ext2 data partition (no rootfs needed).
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done

if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF not found — cannot boot the ELF64 test kernel (gnoboot needs UEFI)." >&2
    rm -f "$ROOT/build/agnos_ktest"; exit 1
fi
if [ ! -f "$GNOBOOT" ]; then
    echo "ERROR: gnoboot not built at $GNOBOOT — build it (gnoboot/scripts/build.sh) first." >&2
    rm -f "$ROOT/build/agnos_ktest"; exit 1
fi

KWORK="$ROOT/build/ktest-boot"
rm -rf "$KWORK"; mkdir -p "$KWORK"
IMG="$KWORK/ktest.img"
# ⛔⛔ 1.56.51 — THE DISK WAS 64 MB AND THAT IS WHY THIS HARNESS BOOTED NOTHING. Every invocation
# died on "ERROR: test output not found (kernel may have crashed or not reached boot_finish)", which
# reads as a KERNEL failure and is not one: OVMF never handed off, so the run measured nothing and
# the in-kernel suite never executed. The 1.56.51 sweep isolated the working cell by a 2x2 over
# {ESP geometry} x {block device} and recorded it in scripts/smoke/rtc-smoke.sh: ONLY
# {1MiB..33MiB on a 128 MB disk} x {nvme} hands off. ktest.sh already had the right partition extent
# and the right device — only the DISK SIZE was still on the old recipe, so it fell outside the
# measured cell and was never re-tested. With 128 MB the suite runs: 97 passed, 6 failed.
# ⚠ Do not "simplify" this back to 64 MB because the partition is only 32 MiB. The extent is not
# the variable that was measured — the pair is.
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$ROOT/build/agnos_ktest" ::boot/agnos
# ⭐ 1.57.12: the disk's first MiB — the primary GPT (protective MBR, header, entry array: LBAs 0-33) and the gap up to
# the ESP at LBA 2048 — is copied out before the boot and compared after it (build/ktest-logs/gpt-before.bin /
# gpt-after.bin). A KTEST build's NVMe round-trips wrote LBA 5 and LBAs 20-27 — inside the entry array — and until
# 1.57.12 never put them back, so every KTEST boot read 33 garbage partitions off this disk; they now write a window in
# that gap (gpt_scratch_lbas_on: LBAs 34-42 here) and put it back. Nothing a ktest boot runs may leave LBAs 0-2047
# changed: a change fails the run. (LBAs 0-33 only, until the window moved into the gap.)
KTEST_CMP_LBAS=2048
dd if="$IMG" of="$KLOGS/gpt-before.bin" bs=512 count=$KTEST_CMP_LBAS status=none
cp "$OVMF_VARS_SRC" "$KWORK/vars.fd"; chmod +w "$KWORK/vars.fd"

# Prefer KVM when available; fall back to -cpu max (TCG). KTEST_KVM=0 forces TCG.
KLOG="$KLOGS/ktest.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # qemu_dwell_kernel, qemu_assert_booted, smoke_accel
KTEST_ACCEL="-cpu max"
if [ -r /dev/kvm ] && [ "${KTEST_KVM:-1}" = "1" ]; then KTEST_ACCEL="-enable-kvm -cpu host"; fi
# 1.57.12: more than one CPU takes smoke_accel's choice (KVM, else MULTI-threaded TCG — single-threaded TCG runs the
# vCPUs one at a time and proves nothing about parallelism; qemu-dwell.sh has the why).
if [ "$KTEST_SMP" -gt 1 ]; then KTEST_ACCEL=$(smoke_accel "$KTEST_SMP"); fi
echo "  accel: $KTEST_ACCEL  (-smp $KTEST_SMP)"
# End a failed firmware hand-off early (it is terminal, not slow); the retry itself stays banner-gated.
QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp|Please select boot device}"
export QEMU_DWELL_VOID
# Marker `TOTAL:` — the suite's last reporter line (qemu_dwell lets the line finish before the kill).
qemu_dwell_kernel "$KLOG" "TOTAL:" "${QEMU_TIMEOUT:-90}" "$KWORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -smp "$KTEST_SMP" $KTEST_ACCEL \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$KWORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-KTEST" \
    -serial stdio -display none -no-reboot
dd if="$IMG" of="$KLOGS/gpt-after.bin" bs=512 count=$KTEST_CMP_LBAS status=none
rm -rf "$KWORK"
rm -f "$ROOT/build/agnos_ktest"
if ! qemu_assert_booted "$KLOG"; then
    echo "RESULT: VOID — the test kernel never executed (log: $KLOG)"
    exit 2
fi
KGPT_BAD=0
if ! cmp -s "$KLOGS/gpt-before.bin" "$KLOGS/gpt-after.bin"; then
    KGPT_BAD=1
    echo "ERROR: the test kernel changed the disk's primary GPT or the gap before the ESP (LBAs 0-$((KTEST_CMP_LBAS - 1))) — first differing bytes:" >&2
    cmp -l "$KLOGS/gpt-before.bin" "$KLOGS/gpt-after.bin" 2>/dev/null | head -5 | awk '{ printf "         LBA %d +%d: %s -> %s (octal)\n", int(($1 - 1) / 512), ($1 - 1) % 512, $2, $3 }' >&2
fi
OUTPUT=$(tr -d '\0' < "$KLOG")

# Parse results
echo ""
echo "$OUTPUT" | grep -E "=== AGNOS Kernel|^\[|PASS:|FAIL:|TOTAL:|ALL TESTS" || true
echo ""

TOTAL_LINE=$(echo "$OUTPUT" | grep "TOTAL:" | head -1)
if [ -z "$TOTAL_LINE" ]; then
    # The banner IS in the log (qemu_assert_booted above), so this is the kernel's own failure: it booted and
    # never reached the suite's reporter. Never a VOID.
    echo "ERROR: test output not found — the kernel booted but crashed or never reached boot_finish (log: $KLOG)"
    exit 1
fi

# The producer is kernel/user/test.cyr:464-468, verbatim:
#     serial_print("TOTAL: ", 7);  kfmt_int(test_pass);
#     serial_print(" passed, ", 9); kfmt_int(test_fail); serial_println(" failed", 7);
# so the line is exactly `TOTAL: <pass> passed, <fail> failed`. Parse BOTH halves. The failure
# count is the verdict; the PASS count is the only thing that proves the verdict is about anything.
PASSED=$(echo "$TOTAL_LINE" | sed 's/.*TOTAL: *//' | sed 's/ *passed.*//' | tr -d '[:space:]')
FAILURES=$(echo "$TOTAL_LINE" | sed 's/.*passed, //' | sed 's/ failed.*//' | tr -d '[:space:]')

# ⚠ A ROTTED PARSE MUST NOT BE ALLOWED TO DECIDE. Both extractions are unanchored substitutions: if
# the producer's wording ever moves off `<n> passed, <n> failed`, NEITHER pattern matches and the
# variable keeps the whole line — measured on `TOTAL: 97 ok, 6 bad`, the old form printed
# "RESULT: TOTAL:97ok,6bad TESTS FAILED". Fail-closed but unreadable, and the same rot on the pass
# side would feed a non-number to the `-lt` in the floor below (an arithmetic error in some shells,
# a silent 0 in others — i.e. it would take the floor out with it). Demand digits from both, and
# name the line that broke rather than describing it as a kernel failure.
BAD_PARSE=""
case "$PASSED"   in ''|*[!0-9]*) BAD_PARSE="pass count '$PASSED'" ;; esac
case "$FAILURES" in ''|*[!0-9]*) BAD_PARSE="${BAD_PARSE:+$BAD_PARSE and }fail count '$FAILURES'" ;; esac
if [ -n "$BAD_PARSE" ]; then
    echo "ERROR: ktest.sh could not parse $BAD_PARSE out of the suite's TOTAL line:" >&2
    echo "         $TOTAL_LINE" >&2
    echo "       This harness's parse has diverged from kernel/user/test.cyr's reporter — the run is" >&2
    echo "       unscored, NOT green. Fix the extraction here to match the producer's wording." >&2
    exit 1
fi

# ⛔⛔ VACUITY FLOOR — WITHOUT IT THIS HARNESS CERTIFIES A KERNEL THAT RAN ZERO TESTS. The verdict
# below is a statement about the FAILURE count alone, and "0 failed" is precisely what a suite that
# executed nothing reports. All seven check bodies in sh_cmd_test() (pmm, heap, vfs, proc, syscall,
# kstdlib, initrd — user/test.cyr) are `#ifdef TEST`-gated, and so is the reporter that prints this
# line; compile the bodies out while the reporter survives — one mis-scoped `#ifdef`, or a build.sh
# that stops prepending `#define TEST` ahead of the check bodies but not the runner — and the kernel
# emits `TOTAL: 0 passed, 0 failed` followed by `ALL TESTS PASSED`, and the old form exited 0
# announcing RESULT: ALL TESTS PASSED. Measured 2026-09-02 against that exact serial text. The -z
# guard above catches only a MISSING TOTAL line; it has never fired on one reporting zero tests.
# ⚠ So the executed count is asserted AND PRINTED on success rather than implied: a run that says
# "3 checks" is reporting that the suite stopped being built, not that the kernel is clean.
# ⚠ FLOOR DERIVATION, FROM RECORDED RUNS — do not round it to a nicer number without redoing this.
# Every executed tally this tree has on record: 103 (97 passed / 6 failed, 1.56.51 — the header note
# above), 109 (103/6, mid-1.56.52 CHANGELOG), 110 (107/3, end of 1.56.52 — state.md and CHANGELOG;
# the three reds are the [initrd] checks — the test initrd exists only in a KTEST build, see above —
# i.e. THE HEALTHY TREE EXITS 1 HERE TODAY). `grep -c test_assert
# kernel/user/test.cyr` counts 117 call sites across the seven bodies, the two largest being kstdlib
# (30) and vfs (23) — measured 2026-09-02. 64 sits far enough below the 103-110 band that adding or
# retiring a handful of assertions never cries wolf, and far enough above the 57 that would survive
# BOTH of those bodies vanishing (110 - 53) that a suite which lost its two largest halves cannot
# report green. It is a constant on purpose: an env-var override would be one `KTEST_MIN_CHECKS=0`
# away from restoring exactly the vacuum it exists to close.
KTEST_MIN_CHECKS=64
EXECUTED=$((PASSED + FAILURES))
if [ "$EXECUTED" -lt "$KTEST_MIN_CHECKS" ]; then
    echo "ERROR: the in-kernel suite executed only $EXECUTED checks ($PASSED passed, $FAILURES failed);" >&2
    echo "       this gate is vacuous below $KTEST_MIN_CHECKS and scores the run UNVERIFIED, not passed." >&2
    echo "       Zero failures out of a suite that ran nothing is not a pass. Check that scripts/build.sh" >&2
    echo "       still prepends '#define TEST' and that sh_cmd_test()'s seven check bodies are INSIDE" >&2
    echo "       the TEST #ifdef rather than compiled away beneath a surviving reporter." >&2
    exit 1
fi

# ⭐ 1.57.12 — THE KTEST BOOT SELF-TESTS (header). Each REQUIRE row is "name|ERE" — the line the self-test prints
# when it passed (core/main.cyr, core/nvme.cyr: grep the quoted text); each DENY ERE is a line one prints when it
# failed. The pass lines are required rather than the FAIL lines merely denied because a self-test that stops early,
# or is compiled out, prints neither. KTEST_GPT_LINE is required in every build: the disk ktest.sh makes holds one
# ESP entry and both CRCs verify, so anything else is the kernel misreading or damaging it.
KTEST_GPT_LINE='gpt: present, first=34 last=[0-9]+ parts=1/128 hdr-CRC-OK arr-CRC-OK'
KTEST_REQUIRE='syscall write|Syscall write works!
hw syscall|HW syscall test: HW-OK
context switch|ctxsw: A=[0-9]+ B=[0-9]+ of [0-9]+ rounds, waited [0-9]+ hlts -- both threads ran and retired OK
vfs write|VFS write: OK
initrd mount|Initrd: 2 files
initrd hello.txt|initrd hello.txt: Hello, AGNOS!
initrd test|initrd test: PASS
vfs memfile|VFS memfile read: HELLO
userland exit code|Exit code: 42
userland exec|Userland exec complete
nvme window|nvme: KTEST round-trip LBAs [0-9]+ and [0-9]+\.\.[0-9]+ \(outside the GPT and every partition\)
nvme single-LBA|nvme: LBA[0-9]+ single-LBA write-then-read PASS \(original restored\)
nvme multi-LBA|nvme: LBA[0-9]+ multi-LBA\([0-9]+\) round-trip PASS \(original restored\)'
KTEST_DENY='hlts -- FAIL|Userland exec FAIL|write-then-read FAIL|round-trip FAIL|KTEST restore of LBA [0-9]+ FAILED|KTEST write round-trips skipped|nvme: (read|write)(_sectors)? LBA [0-9]+ .*failed'
KBOOT_BAD=0
if ! printf '%s\n' "$OUTPUT" | grep -qE "$KTEST_GPT_LINE"; then
    KBOOT_BAD=$((KBOOT_BAD + 1))
    echo "ERROR: no intact-GPT summary line (/$KTEST_GPT_LINE/) — the kernel misread or damaged the boot disk's GPT:" >&2
    printf '%s\n' "$OUTPUT" | grep -E "gpt: " | head -3 | sed 's/^/         /' >&2
fi
case " $KTEST_BUILD_FLAGS " in
    *" KTEST "*)
        KREQ_N=0; KREQ_OK=0
        while IFS='|' read -r kname kre; do
            [ -n "$kname" ] || continue
            KREQ_N=$((KREQ_N + 1))
            if printf '%s\n' "$OUTPUT" | grep -qE -- "$kre"; then KREQ_OK=$((KREQ_OK + 1))
            else KBOOT_BAD=$((KBOOT_BAD + 1)); echo "ERROR: KTEST boot self-test '$kname' did not pass — no line /$kre/" >&2; fi
        done <<KREQ
$KTEST_REQUIRE
KREQ
        # The NVMe window must be the gap this disk HAS between its entry array and its ESP: LBAs 34..2047 (parted's
        # layout above). A window inside the GPT would pass every line above — the restore hides it — until the boot
        # that crashes between a write and its restore.
        KWIN=$(printf '%s\n' "$OUTPUT" | sed -n 's/.*nvme: KTEST round-trip LBAs \([0-9]*\) and [0-9]*\.\.\([0-9]*\) .*/\1 \2/p' | head -1)
        if [ -n "$KWIN" ]; then
            set -- $KWIN
            if [ "$1" -lt 34 ] || [ "$2" -gt 2047 ]; then
                KBOOT_BAD=$((KBOOT_BAD + 1))
                echo "ERROR: the NVMe round-trip window LBAs $1..$2 is not inside the gap LBAs 34..2047 (GPT array end .. ESP)" >&2
            fi
        fi
        KDENY_HITS=$(printf '%s\n' "$OUTPUT" | grep -E -- "$KTEST_DENY" || true)
        if [ -n "$KDENY_HITS" ]; then
            KBOOT_BAD=$((KBOOT_BAD + 1))
            echo "ERROR: KTEST boot self-test FAIL line(s):" >&2
            printf '%s\n' "$KDENY_HITS" | head -5 | sed 's/^/         /' >&2
        fi
        echo "KTEST boot self-tests: $KREQ_OK/$KREQ_N pass lines present, $(printf '%s' "$KDENY_HITS" | grep -c . || true) FAIL line(s)"
        ;;
esac

if [ "$KGPT_BAD" = 1 ]; then
    echo "RESULT: FAILED — $EXECUTED checks executed ($PASSED passed, $FAILURES failed), but the kernel changed the boot disk's GPT (see the ERROR above; build/ktest-logs/gpt-*.bin)"
    exit 1
fi
if [ "$KBOOT_BAD" -gt 0 ]; then
    echo "RESULT: FAILED — $EXECUTED checks executed ($PASSED passed, $FAILURES failed), but $KBOOT_BAD boot check(s) failed (the ERROR lines above)"
    exit 1
fi
if [ "$FAILURES" = "0" ]; then
    case " $KTEST_BUILD_FLAGS " in
        *" KTEST "*) echo "RESULT: ALL TESTS PASSED — $EXECUTED checks executed (floor $KTEST_MIN_CHECKS), 0 failed; $KREQ_N KTEST boot self-tests passed" ;;
        *)           echo "RESULT: ALL TESTS PASSED — $EXECUTED checks executed (floor $KTEST_MIN_CHECKS), 0 failed" ;;
    esac
    exit 0
else
    echo "RESULT: $FAILURES TESTS FAILED — $EXECUTED checks executed (floor $KTEST_MIN_CHECKS), $PASSED passed"
    exit 1
fi
