#!/bin/bash
# arc-close hardening smoke test for the AGNOS kernel (1.35.7, pass 1).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# HARDENING_SELFTEST=1 boot-hook, then asserts the serial log.
#
# Gate (hermetic — no network required):
#   "hardening: ip-clamp PASS"  — table over ip_safe_payload_len, the ingress
#                        clamp that stops a forged IPv4 total-length from making
#                        the ICMP/UDP/TCP handlers over-read net_rx_pkt: valid
#                        pass-through, padded-frame untouched, forged total>avail
#                        clamped, ihl<20 / total<ihl / truncated-frame rejected.
#                        LOAD-BEARING (1.35.7 arc-close hardening pass 1). See
#                        agnosticos/docs/development/arc-close-hardening-1-35.md.
#
# Valid-traffic non-regression (the clamp must not break real frames) is covered
# by the dns / icmp / tcp / ntp smokes, which all drive net_poll with real
# packets.
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

if ! strings "$AGNOS" | grep -q "hardening: ip-clamp PASS"; then
    echo "ERROR: kernel was not built with HARDENING_SELFTEST=1" >&2
    echo "       rebuild: HARDENING_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/hardening-smoke"
LOGS="$ROOT/build/hardening-smoke-logs"
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

echo "=== AGNOS arc-close hardening smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/hardening.log"
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

echo "--- serial log (hardening lines) ---"
grep -E "hardening:" "$LOG" || echo "(no hardening lines captured)"
echo "------------------------------------"

if grep -q "hardening: ip-clamp PASS" "$LOG"; then
    echo "PASS: ip_safe_payload_len ingress clamp (forged IP-length over-read guard)"
    echo ""
    echo "=== hardening-smoke: 1 passed, 0 failed ==="
    exit 0
fi

echo "FAIL: 'hardening: ip-clamp PASS' not found — ingress-clamp regression"
echo ""
echo "=== hardening-smoke: 0 passed, 1 failed ==="
exit 1
