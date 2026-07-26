#!/bin/bash
# tsc-smoke — does a ring-3 DIVIDE BY ZERO kill the process, or the machine?
#
# ⭐ THIS TEST EXISTS BECAUSE A BURN FOUND THE BUG. On the rung-10 flash (2026-07-25)
# /bin/gputri --bench divided by a zero timing and archaemenid FROZE mid-line — no fault
# message, no CMOS stamp, no prompt, hard power cycle. Vector 0 (#DE) sat in idt.cyr's
# "deliberately NOT installed" list, so the bare-iretq default returned straight to the
# faulting idiv, which divided by zero again, forever.
#
# ⛔ A userland arithmetic mistake must never halt the kernel. PASS = the deliberate #DE kills
# the proc and BOOT CONTINUES to a prompt. A regression here is a HANG, which is exactly why
# this is an automated gate rather than something anyone re-checks by hand.
#
# ⚠ It needs a REAL ext2 agnos-fs (the TSC_SELFTEST hook writes /bin/divz and execs it), so this
# clones tsc-smoke's image builder rather than the ESP-only one — the first attempt used an
# ESP-only image, ext2_active stayed 0, and the selftest returned silently with its strings
# present in the binary. String present is not code called.
#
# Build first:  TSC_SELFTEST=1 sh scripts/build.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run TSC_SELFTEST=1 ./scripts/build.sh"; exit 1; }
# ⛔ VERIFY THE FLAG LANDED, not merely that a build exists. A mode flag whose #define was never
# emitted ships a silent no-op. ⚠ NECESSARY BUT NOT SUFFICIENT — the string lives in the
# function body, so it appears as soon as the function COMPILES even if nothing CALLS it. That
# is exactly how the first run of this smoke passed the guard while the hook never ran (it was
# called ~450 lines too early, before ext2 was mounted). The log assertions are the real gate.
if ! strings "$AGNOS" | grep -q "tsc: ring-3 probe"; then
    echo "ERROR: kernel not built with TSC_SELFTEST=1 — rebuild:"
    echo "       TSC_SELFTEST=1 sh scripts/build.sh"
    exit 1
fi

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${DE_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — falling back to TCG; the 16 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/tsc-smoke"
LOGS="$ROOT/build/tsc-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-tsc.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 95 * 1048576 ))             # 95 MiB ext2 — roomy for the 16 MB ark
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
printf 'archaemenid\n' > "$SEED/etc/hostname"
echo "Building the ext2 image (the DE hook creates /bin/divz itself)..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-ARK -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting TSC_SELFTEST kernel ($KVM_ARGS)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/tsc.log"
timeout "${QEMU_TIMEOUT:-120}" qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-ARK" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- tsc lines from the boot log ---"
# ⛔ `^[a-z-]*tsc:`, NOT `^tsc:`. The anchored form matched the calibration and ring-3-probe lines
# only — it could not match `gpu-tsc:` or `hda-tsc:`, because those start with a letter before the
# 't'. Meanwhile the two accessor gates below tell the operator to "see the gpu-tsc:/hda-tsc: lines
# above for which arm", and those lines were being filtered out of the very dump they point at. A
# red gate therefore arrived with NO arm score, NO per_us value, NO tick count, and — worst — with
# the "arm D oracle is FROZEN" explanation suppressed, which is the one line that exists to stop a
# reader misdiagnosing a stopped clock as a broken udelay. Diagnosing it cost a fresh 2-minute boot.
# ⚠ The character class covers a THIRD adopter of the pattern for free; `^tsc:|^gpu-tsc:|^hda-tsc:`
# would have to be edited again, and this bug is precisely what "edit it again" failed to do once.
strings "$LOG" | grep -E "^[a-z-]*tsc:|^run: exit|AGNOS shell|agnos>" | sed 's/^/  /'
echo ""

pass=0; fail=0
chk() { if strings "$LOG" | grep -q "$1"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $3"; fail=$((fail+1)); fi; }

chk "cycles per microsecond" \
    "the TSC calibrated against live 100 Hz ticks" \
    "calibration REFUSED or never ran -- uptime_us would report -1"
chk "tsc: ring-3 probe" \
    "the probe actually RAN (string present is not code called)" \
    "the hook never ran -- check ext2_active and the call site, not the #define"

# ⭐ THE DIFFERENTIAL. The probe's exit code IS the microseconds uptime_us#95 measured across a
# busy loop run with INTERRUPTS DISABLED. `run: exit 0` means the clock did not advance -- which
# is precisely what uptime_ms#40 does on this path, and precisely the failure that cost two iron
# burns. Any NONZERO exit is the proof.
if strings "$LOG" | grep -qE "^run: exit 1$"; then
    echo "PASS: ⭐ uptime_us#95 ADVANCED with interrupts off ($(strings "$LOG" | grep -oE '^run: exit [0-9]+' | tail -1))"
    pass=$((pass+1))
else
    echo "FAIL: uptime_us#95 measured ZERO across the busy loop -- the clock does NOT advance"
    echo "      with interrupts off, so it is no better than uptime_ms#40 and the rung-10"
    echo "      bench still has no usable instrument."
    fail=$((fail+1))
fi

chk "gpu-tsc: PASS" \
    "gpu_tsc_per_us() -- all 4 arms (fallback branch, sane bound, calibrated branch, real udelay)" \
    "gpu_tsc_per_us() selftest FAILED -- see the gpu-tsc: lines above for which arm"
chk "hda-tsc: PASS" \
    "hda_tsc_per_us() -- all 4 arms (fallback branch, sane bound, calibrated branch, real udelay)" \
    "hda_tsc_per_us() selftest FAILED -- see the hda-tsc: lines above for which arm"

# ⭐ THE DIFFERENTIAL THAT PROVES THE RETUNE IS LIVE. Before this change every GPU timing path --
# and every HDA settle -- multiplied by a hardcoded 3000 no matter what calibration measured. So
# compare the numbers ACROSS LINES, in the harness, independently of the kernels' own arm C: the
# per_us each accessor reports must equal the per_us tsc_calibrate measured. If an accessor ever
# regresses to a constant, the two diverge on any box whose TSC is not exactly that file's
# fallback -- which is every box, since each fallback is one specific machine's measurement.
#
# ⚠ ANCHOR EACH EXTRACTION TO ITS OWN LINE. `grep -oE "per_us [0-9]+" | head -1` worked only while
# exactly one line in the whole boot log carried that token; the moment hda-tsc: printed a second
# one, "first match wins" silently became "whichever selftest main.cyr happens to call first".
# A gate whose correctness depends on unrelated call ordering is a gate waiting to test the wrong
# thing.
CAL=$(strings "$LOG" | grep -oE "^tsc: [0-9]+ cycles" | grep -oE "[0-9]+" | head -1)
tsc_accessor_chk() {
    _name="$1"; _tag="$2"; _what="$3"
    _got=$(strings "$LOG" | grep -oE "^${_tag}: [0-9]+/4 arms; per_us [0-9]+" | grep -oE "[0-9]+$" | head -1)
    if [ -n "$CAL" ] && [ -n "$_got" ] && [ "$CAL" = "$_got" ]; then
        echo "PASS: ⭐ $_name timing uses the CALIBRATED clock (accessor $_got == calibrated $CAL)"
        pass=$((pass+1))
    else
        echo "FAIL: $_name accessor reports '$_got' but calibration measured '$CAL' -- the $_name"
        echo "      timing paths are NOT tracking the measured clock. That is the whole point of"
        echo "      the indirection; a constant here silently mis-scales $_what."
        fail=$((fail+1))
    fi
}
tsc_accessor_chk "GPU" "gpu-tsc" "every dispatch watchdog and every PSP settle"
tsc_accessor_chk "HDA" "hda-tsc" "every codec reset settle and every verb-ring timeout"

echo ""
[ "$fail" -eq 0 ] && { echo "=== tsc-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== tsc-smoke: $pass passed, $fail failed ==="; exit 1
