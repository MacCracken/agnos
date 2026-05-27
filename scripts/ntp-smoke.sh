#!/bin/bash
# NTP/SNTP parse smoke test for the AGNOS kernel (1.35.x).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# NTP_SELFTEST=1 boot-hook, then asserts the serial log.
#
# Gate (hermetic — no network required):
#   "ntp: parse PASS"  — a synthetic SNTP response's Transmit Timestamp
#                        (NTP 3913056000) converts to Unix 1704067200
#                        (2024-01-01 00:00:00 UTC), and a +3661 s value breaks
#                        down to 01:01:01 UTC. Validates the 1900→1970 epoch
#                        delta + the civil-time math. LOAD-BEARING.
#
# The live path (a real SNTP sync) is exercised via the `ntp <server>` shell
# verb — SLIRP has no NTP server, so it's a manual / iron check, not gated here.
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

if ! strings "$AGNOS" | grep -q "ntp: parse PASS"; then
    echo "ERROR: kernel was not built with NTP_SELFTEST=1" >&2
    echo "       rebuild: NTP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/ntp-smoke"
LOGS="$ROOT/build/ntp-smoke-logs"
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

echo "=== AGNOS NTP/SNTP parse smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/ntp.log"
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

echo "--- serial log (NTP lines) ---"
grep -E "ntp:" "$LOG" || echo "(no ntp lines captured)"
echo "------------------------------"

if grep -q "ntp: parse PASS" "$LOG"; then
    echo "PASS: hermetic SNTP parse (NTP→Unix epoch + UTC breakdown)"
    echo ""
    echo "=== ntp-smoke: 1 passed, 0 failed ==="
    exit 0
fi

echo "FAIL: 'ntp: parse PASS' not found — SNTP parse/epoch regression"
echo ""
echo "=== ntp-smoke: 0 passed, 1 failed ==="
exit 1
