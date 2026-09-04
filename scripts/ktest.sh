#!/bin/sh
# AGNOS kernel functional test suite
# Boots agnos in QEMU (gnoboot + OVMF) with core/boot_finish.cyr rewritten to
# run sh_cmd_test() — the in-kernel `test` shell verb (user/test.cyr) — in place
# of the kybernet launch, then parses the serial PASS/FAIL/TOTAL output.
# Exit code: 0 = all passed, 1 = failures / harness error.
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
# parsed below. All seven checks are self-contained (the test initrd is built
# unconditionally at boot in main.cyr), so no userland is execed and no rootfs
# is needed.
BFIN_CYR="$ROOT/kernel/core/boot_finish.cyr"
# `.ktestbak` (not `.bak`): a plain `.bak` suffix collides with the committed
# `*.cyr.bak` cruft the kernel tree carries — and historically THIS script
# corrupted core/main.cyr by cp'ing an already-patched file over its `.bak`
# (its restore never ran because `set -e` exited on the build failure first).
# `.ktestbak` + the EXIT/INT/TERM trap below make that class of bug impossible.
BFIN_BAK="$BFIN_CYR.ktestbak"
cp "$BFIN_CYR" "$BFIN_BAK"

# Restore boot_finish.cyr no matter how we exit (build error, QEMU failure,
# parse failure, ^C). Set BEFORE the sed so any failure path restores.
restore_sources() {
    [ -f "$BFIN_BAK" ] && mv -f "$BFIN_BAK" "$BFIN_CYR"
}
trap restore_sources EXIT INT TERM

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
TEST=1 sh "$ROOT/scripts/build.sh" >&2
cp "$ROOT/build/agnos" "$ROOT/build/agnos_ktest"

# Sources restored — undo the trap so a later failure doesn't try to restore
# already-restored files.
restore_sources
trap - EXIT INT TERM

echo "Booting test kernel via gnoboot + OVMF (${QEMU_TIMEOUT:-40}s timeout)..."
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
cp "$OVMF_VARS_SRC" "$KWORK/vars.fd"; chmod +w "$KWORK/vars.fd"

# Prefer KVM when available; fall back to -cpu max (TCG). KTEST_KVM=0 forces TCG.
KTEST_ACCEL="-cpu max"
if [ -r /dev/kvm ] && [ "${KTEST_KVM:-1}" = "1" ]; then KTEST_ACCEL="-enable-kvm -cpu host"; fi
OUTPUT=$(timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M $KTEST_ACCEL \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$KWORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-KTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' || true)
rm -rf "$KWORK"
rm -f "$ROOT/build/agnos_ktest"

# Parse results
echo ""
echo "$OUTPUT" | grep -E "=== AGNOS Kernel|^\[|PASS:|FAIL:|TOTAL:|ALL TESTS" || true
echo ""

TOTAL_LINE=$(echo "$OUTPUT" | grep "TOTAL:" | head -1)
if [ -z "$TOTAL_LINE" ]; then
    echo "ERROR: test output not found (kernel may have crashed or not reached boot_finish)"
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
# the three reds are the environmental [initrd] checks gnoboot cannot satisfy, not regressions —
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

if [ "$FAILURES" = "0" ]; then
    echo "RESULT: ALL TESTS PASSED — $EXECUTED checks executed (floor $KTEST_MIN_CHECKS), 0 failed"
    exit 0
else
    echo "RESULT: $FAILURES TESTS FAILED — $EXECUTED checks executed (floor $KTEST_MIN_CHECKS), $PASSED passed"
    exit 1
fi
