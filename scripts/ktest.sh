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

# Guard the call-site rewrite: if `kybernet(); arch_halt();` ever moves or is
# renamed (as it did at the 1.36.2 split), the sed would silently no-op and
# sh_cmd_test() would never be wired in — the kernel would boot normally into
# agnsh and emit zero test markers. Fail loud instead. Expect exactly one.
BFIN_MATCHES=$(grep -c 'kybernet(); arch_halt();' "$BFIN_CYR" || true)
if [ "$BFIN_MATCHES" -ne 1 ]; then
    echo "ERROR: ktest.sh expected exactly 1 'kybernet(); arch_halt();' launch site in $BFIN_CYR, found $BFIN_MATCHES" >&2
    echo "       the test entry-point rewrite would no-op — boot_finish.cyr's launch site diverged from ktest.sh's contract." >&2
    exit 1
fi
sed -i 's/kybernet(); arch_halt();/sh_cmd_test(); arch_halt();/' "$BFIN_CYR"

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
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
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

FAILURES=$(echo "$TOTAL_LINE" | sed 's/.*passed, //' | sed 's/ failed.*//' | tr -d '[:space:]')
if [ "$FAILURES" = "0" ]; then
    echo "RESULT: ALL TESTS PASSED"
    exit 0
else
    echo "RESULT: $FAILURES TESTS FAILED"
    exit 1
fi
