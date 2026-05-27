#!/bin/bash
# DNS stub-resolver smoke test for the AGNOS kernel (1.35.x bite 2).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# DNS_SELFTEST=1 boot-hook + QEMU user-mode (SLIRP) networking, then asserts
# the serial log. SLIRP supplies a hermetic environment: DHCP hands out
# resolver 10.0.2.3 (DHCP option 6) and forwards DNS to the host resolver.
#
# Gates (both hermetic — no internet required):
#   1. "dns: parse PASS"      — the hand-built RFC 1035 response (answer NAME
#                               is a 0xC0 compression pointer) parsed back to
#                               93.184.216.34. Proves dns_skip_name + the
#                               answer walk. LOAD-BEARING.
#   2. "dns: resolver=10.0.2.3" — DHCP option 6 captured (bite 1). Proves the
#                               opt-6 capture end-to-end through QEMU SLIRP.
#
# Informational (internet-dependent, NOT required to pass):
#   3. "dns: live=..."        — a real example.com lookup forwarded by SLIRP
#                               to the host resolver. Present only when the
#                               host has working DNS.
#
# Requires: qemu-system-x86_64, OVMF firmware, mtools (mformat/mmd/mcopy),
# parted, gnoboot built. Exit 0 if both gates pass; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

# --- OVMF discovery (same as ext2-smoke.sh / tcp-listen-smoke.sh) ----------
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

# Verify the kernel was built with DNS_SELFTEST — grep for a literal only the
# selftest hook emits.
if ! strings "$AGNOS" | grep -q "dns: parse PASS"; then
    echo "ERROR: kernel was not built with DNS_SELFTEST=1" >&2
    echo "       rebuild: DNS_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/dns-smoke"
LOGS="$ROOT/build/dns-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"

# --- Minimal ESP-only boot image -------------------------------------------
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI
mmd -i "$ESP"@@1048576 ::EFI/BOOT
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mmd -i "$ESP"@@1048576 ::boot
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS DNS stub-resolver smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  gnoboot:   $GNOBOOT"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/dns.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"
chmod +w "$WORK/vars.fd"

# SLIRP user-mode networking: built-in DHCP (10.0.2.15 / gw 10.0.2.2 / dns
# 10.0.2.3) + DNS forwarding to the host resolver. virtio-net-pci is the
# modern path the kernel drives in QEMU (r8169 is iron-only).
timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -netdev "user,id=u1" \
    -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial log (DNS lines) ---"
grep -E "dhcp: ACK|dns:" "$LOG" || echo "(no dhcp/dns lines captured)"
echo "------------------------------"

pass=0
fail=0

if grep -q "dns: parse PASS" "$LOG"; then
    echo "PASS: hermetic RFC 1035 parse (compression-pointer answer -> 93.184.216.34)"
    pass=$((pass + 1))
else
    echo "FAIL: 'dns: parse PASS' not found — parse/skip-name regression"
    fail=$((fail + 1))
fi

if grep -q "dns: resolver=10.0.2.3" "$LOG"; then
    echo "PASS: DHCP option 6 captured (resolver=10.0.2.3)"
    pass=$((pass + 1))
else
    echo "FAIL: DHCP option-6 resolver not captured (expected 10.0.2.3)"
    echo "      (if DHCP itself failed under SLIRP, check the dhcp: ACK line)"
    fail=$((fail + 1))
fi

# Informational only — does not affect exit status.
if grep -q "dns: live=" "$LOG"; then
    echo "INFO: live lookup succeeded — $(grep -m1 'dns: live=' "$LOG")"
else
    echo "INFO: live lookup skipped/failed (host DNS unavailable — not required)"
fi

echo ""
echo "=== dns-smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
