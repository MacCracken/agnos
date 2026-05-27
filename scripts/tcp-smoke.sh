#!/bin/bash
# TCP receive-ring smoke test for the AGNOS kernel (1.35.1 B1).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with the
# TCP_SELFTEST=1 boot-hook, then asserts the serial log.
#
# Gate (hermetic — no network required):
#   "tcp: ring PASS"   — the in-order receive ring delivers a multi-chunk
#                        byte stream in FIFO order AND across a buffer wrap,
#                        byte-exact. This is the B1 fix for the 1.32.0
#                        overwrite-latest path that silently truncated any
#                        multi-segment transfer. LOAD-BEARING.
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

if ! strings "$AGNOS" | grep -q "tcp: ring PASS"; then
    echo "ERROR: kernel was not built with TCP_SELFTEST=1" >&2
    echo "       rebuild: TCP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/tcp-smoke"
LOGS="$ROOT/build/tcp-smoke-logs"
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

echo "=== AGNOS TCP receive-ring smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/tcp.log"
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

echo "--- serial log (TCP lines) ---"
grep -E "tcp:" "$LOG" || echo "(no tcp lines captured)"
echo "------------------------------"

pass=0
fail=0

if grep -q "tcp: ring PASS" "$LOG"; then
    echo "PASS: B1 in-order receive ring (FIFO order + buffer wrap, byte-exact)"
    pass=$((pass + 1))
else
    echo "FAIL: 'tcp: ring PASS' not found — ring reassembly regression"
    fail=$((fail + 1))
fi

if grep -q "tcp: retx PASS" "$LOG"; then
    echo "PASS: B2 retransmit logic (RTO backoff + arm/disarm + resend + give-up)"
    pass=$((pass + 1))
else
    echo "FAIL: 'tcp: retx PASS' not found — retransmit logic regression"
    fail=$((fail + 1))
fi

if grep -q "tcp: mss PASS" "$LOG"; then
    echo "PASS: B3 MSS option (emit + parse + effective-MSS clamp/default)"
    pass=$((pass + 1))
else
    echo "FAIL: 'tcp: mss PASS' not found — MSS option regression"
    fail=$((fail + 1))
fi

echo ""
echo "=== tcp-smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
