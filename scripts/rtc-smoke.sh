#!/bin/bash
# RTC boot-clock smoke test for the AGNOS kernel (1.35.5).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# RTC_SELFTEST=1 boot-hook, then asserts the serial log.
#
# Gate:
#   "rtc: clock PASS"  — hermetic civil_to_unix anchors (2024-01-01 00:00:00 =
#                        1704067200, +3661 s, the 2024-03-01 leap boundary =
#                        1709251200, epoch = 0) + BCD decode (0x59→59); PLUS a
#                        live-bounded rtc_read_unix() that reads QEMU's emulated
#                        CMOS (host time) and must land past 2020-01-01, so the
#                        UIP/BCD/century read path is genuinely exercised without
#                        depending on the exact host clock. LOAD-BEARING.
#
# The boot path itself also seeds the wall clock from the RTC (see the
# "Wall clock: RTC seed Unix ..." line in any normal boot); `date` then shows
# `[RTC]`, and a later `ntp <server>` refines to `[NTP]`.
#
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
# Exit 0 if the gate passes; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
    /usr/share/qemu/OVMF_CODE.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
    /usr/share/qemu/OVMF_VARS.fd
"
OVMF_CODE=""
for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)." >&2
    exit 1
fi

for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not on PATH" >&2
        exit 1
    fi
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }

if ! strings "$AGNOS" | grep -q "rtc: clock PASS"; then
    echo "ERROR: kernel was not built with RTC_SELFTEST=1" >&2
    echo "       rebuild: RTC_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/rtc-smoke"
LOGS="$ROOT/build/rtc-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"

ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI
mmd -i "$ESP"@@1048576 ::EFI/BOOT
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mmd -i "$ESP"@@1048576 ::boot
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS RTC boot-clock smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/rtc.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"
chmod +w "$WORK/vars.fd"

timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -netdev "user,id=u1" \
    -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial log (rtc / wall-clock lines) ---"
grep -E "rtc:|Wall clock:" "$LOG" || echo "(no rtc lines captured)"
echo "-------------------------------------------"

if grep -q "rtc: clock PASS" "$LOG"; then
    echo "PASS: civil_to_unix anchors + BCD + live CMOS read"
    echo ""
    echo "=== rtc-smoke: 1 passed, 0 failed ==="
    exit 0
fi

echo "FAIL: 'rtc: clock PASS' not found — civil_to_unix / CMOS-read regression"
echo ""
echo "=== rtc-smoke: 0 passed, 1 failed ==="
exit 1
