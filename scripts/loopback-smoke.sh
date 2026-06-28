#!/bin/bash
# Loopback (lo) smoke test for the AGNOS kernel (1.49.0 loopback bite 1).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# LOOPBACK_SELFTEST=1 boot-hook + QEMU user-mode (SLIRP) networking, then
# asserts the serial log.
#
# The hook (loopback_selftest, net_ingress.cyr) sends a UDP datagram to
# 127.0.0.1 and reads it back from net_udp_buf. SLIRP would NEVER return a
# 127.0.0.1 datagram put on the wire, so a populated buffer proves the packet
# was routed INTERNALLY by net_tx (loopback queue) and drained back up the
# stack by net_lo_drain → net_demux_frame → net_handle_udp.
#
# Gate (hermetic — no internet required):
#   "lo: UDP loopback OK"  — udp_send(127.0.0.1) round-tripped through the
#                            loopback queue + demux with no wire peer.
#
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
# Build first:  LOOPBACK_SELFTEST=1 ./scripts/build.sh
# Exit 0 if the gate passes; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

# --- OVMF discovery (same as dns-smoke.sh / ext2-smoke.sh) -----------------
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

# Verify the kernel was built with LOOPBACK_SELFTEST — grep for a literal only
# the selftest hook emits.
if ! strings "$AGNOS" | grep -q "lo: UDP loopback"; then
    echo "ERROR: kernel was not built with LOOPBACK_SELFTEST=1" >&2
    echo "       rebuild: LOOPBACK_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/loopback-smoke"
LOGS="$ROOT/build/loopback-smoke-logs"
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

echo "=== AGNOS loopback (lo) smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  gnoboot:   $GNOBOOT"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/loopback.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"
chmod +w "$WORK/vars.fd"

# virtio-net-pci present so the net stack inits normally; the loopback packet
# is destined to 127.0.0.1, which never reaches SLIRP — the proof of an
# internal loop.
timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -netdev "user,id=u1" \
    -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial log (lo lines) ---"
grep -E "lo:" "$LOG" || echo "(no lo lines captured)"
echo "-----------------------------"

pass=0
fail=0
check() {
    if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass + 1));
    else echo "FAIL: '$1' not found — $3"; fail=$((fail + 1)); fi
}

echo ""
check "lo: UDP loopback OK"       "UDP datagram to 127.0.0.1 looped back (net_tx queue + net_lo_drain demux)"     "UDP loopback regression (check 'lo: got=')"
check "lo: ICMP ping loopback OK" "ICMP echo to net_ip self-looped (request + reply both via the lo queue)"       "ICMP loopback regression"
check "lo: TCP loopback OK"       "TCP handshake to net_ip completed over lo (SYN/SYN-ACK/ACK via the lo queue)"  "TCP loopback handshake regression"
check "lo: socket-as-VFS-fd OK"   "sock_accept returns a VFS_SOCK fd; read#5 through the fd got the client's bytes; close OK" "socket-as-VFS-fd dispatch regression"

echo ""
echo "=== loopback-smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
