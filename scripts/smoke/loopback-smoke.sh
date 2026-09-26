#!/bin/bash
# Loopback (lo) smoke (LOOPBACK_SELFTEST=1): UDP to 127.0.0.1, ICMP + TCP to our own net_ip over the lo queue,
# socket-as-VFS-fd, epoll readiness, and (1.57.7 S4.7) `lo: close-wait ready` — a peer FIN makes the server side
# readable AND EOF once its bytes are drained. `lo: selftest done` (printed at EVERY exit of loopback_selftest)
# is the dwell marker.
# 1.57.7 (S4.1): banner-gated retry, exit 2 on VOID, PASS/FAIL per check, $SMOKE_INVARIANT_DENY denied. Gated by
# scripts/sweep.sh (LOOPBACK_SELFTEST=1) since 1.57.7.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"     # qemu_dwell_kernel, qemu_assert_booted, SMOKE_INVARIANT_DENY
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found — this gate measured NOTHING" >&2
    exit 1
fi
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="${SMOKE_KERNEL:-$ROOT/build/agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "lo: UDP loopback"; then
    echo "ERROR: kernel was not built with LOOPBACK_SELFTEST=1 — rebuild: LOOPBACK_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/loopback-smoke"
LOGS="$ROOT/build/loopback-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS loopback (lo) smoke ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
LOG="$LOGS/loopback.log"
qemu_dwell_kernel "$LOG" "lo: selftest done" "${QEMU_TIMEOUT:-60}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
    -netdev "user,id=u1" -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot
qemu_assert_booted "$LOG" || exit 2

echo "--- serial log (lo lines) ---"
grep -a "lo:" "$LOG" || echo "(no lo lines captured)"
echo "-----------------------------"

pass=0
fail=0
check() {
    if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass + 1));
    else echo "FAIL: '$1' not found — $3"; fail=$((fail + 1)); fi
}
deny() {
    if grep -qE "$1" "$LOG"; then echo "FAIL: $2"; grep -E "$1" "$LOG" | head -3 | sed 's/^/        /'; fail=$((fail + 1));
    else echo "PASS: $3"; pass=$((pass + 1)); fi
}

check "lo: UDP loopback OK"       "UDP datagram to 127.0.0.1 looped back (net_tx queue + net_lo_drain demux)"     "UDP loopback regression (check 'lo: got=')"
check "lo: ICMP ping loopback OK" "ICMP echo to net_ip self-looped (request + reply both via the lo queue)"       "ICMP loopback regression"
check "lo: TCP loopback OK"       "TCP handshake to net_ip completed over lo (SYN/SYN-ACK/ACK via the lo queue)"  "TCP loopback handshake regression"
check "lo: socket-as-VFS-fd OK"   "accepted conn as a VFS_SOCK fd; read#5 through the fd got the client's bytes; close OK" "socket-as-VFS-fd regression"
check "lo: epoll sock-ready OK"   "epoll readiness on a VFS_SOCK fd flips 0->1 across the client send"            "epoll socket-readiness regression"
check "lo: close-wait ready OK"   "after the client's FIN the drained server side is readable AND EOF (1.57.7)"   "CLOSE_WAIT EOF regression"
check "lo: selftest done"         "loopback_selftest ran to an exit"                                               "loopback_selftest did not finish"
deny "lo: [a-zA-Z -]+ FAIL" "a loopback check printed FAIL" "no loopback check printed FAIL"
deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant (incl. net: lock overlap/missing)"

echo ""
echo "=== loopback-smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
