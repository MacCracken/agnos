#!/bin/bash
# TCP server-side primitives smoke test for the AGNOS kernel.
# Validates 1.32.0 bite A — tcp_listen / tcp_accept / passive-open SYN
# handler + SYN_RCVD state branch.
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with
# the TCP_LISTEN_SMOKE=1 boot-hook that:
#   1. tcp_listen(8080)         — bind the listener
#   2. poll up to ~2000 iters   — call net_poll + tcp_accept each round
#   3. on accept: send "AGNOS 1.32.0 tcp_listen smoke\n" + tcp_close
#   4. on timeout: log a 'no connection within timeout' line
#
# Host-side: after a ~2s delay (to let qemu boot past net_init), `nc`
# connects to the qemu-forwarded port, reads the banner, closes. The log
# is then grepped for the kernel-side `tcp_accept: conn_id=` line AND
# the host-side received-banner content.
#
# Scenarios:
#   1. accept-one        — single host nc connection; expect both ends.
#   2. listen-no-connect — no host probe; expect 'no connection within
#                          timeout' (proves the listener is alive but
#                          isn't spuriously accepting).
#   3. duplicate-listen  — kernel tries tcp_listen(8080) twice (the
#                          second call should return -1). Validated by
#                          a separate boot whose smoke hook attempts a
#                          second bind. (DEFERRED — needs a separate
#                          TCP_LISTEN_SMOKE_DUP=1 flag; for now skip.)
#
# Tested under: qemu 9+, edk2 OVMF (2024+).
# Requires: qemu-system-x86_64, OVMF firmware, nc (netcat), gnoboot built.
#
# Exit 0 if all selected scenarios pass; 1 if any fail.
# Logs preserved under build/tcp-listen-smoke-logs/.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

# OVMF discovery — same as ext2-smoke.sh
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
for c in $OVMF_CODE_CANDIDATES; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for c in $OVMF_VARS_CANDIDATES; do
    [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }
done

if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)." >&2
    exit 1
fi

for tool in qemu-system-x86_64 python3 mformat mmd mcopy parted; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not on PATH" >&2
        exit 1
    fi
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

if [ ! -f "$GNOBOOT" ]; then
    echo "ERROR: gnoboot not built at $GNOBOOT" >&2
    exit 1
fi
if [ ! -f "$AGNOS" ]; then
    echo "ERROR: agnos kernel not built at $AGNOS" >&2
    echo "       cd $ROOT && TCP_LISTEN_SMOKE=1 scripts/build.sh" >&2
    exit 1
fi

# Verify the kernel was built with TCP_LISTEN_SMOKE — grep for the banner
# literal that only the smoke hook emits.
if ! strings "$AGNOS" | grep -q "tcp_listen(8080)"; then
    echo "ERROR: kernel was not built with TCP_LISTEN_SMOKE=1" >&2
    echo "       rebuild: TCP_LISTEN_SMOKE=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/tcp-listen-smoke"
LOGS="$ROOT/build/tcp-listen-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"

# Build minimal ESP-only boot image (no fs scenarios — we only care about
# kernel reaching net_init + smoke hook).
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI
mmd -i "$ESP"@@1048576 ::EFI/BOOT
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mmd -i "$ESP"@@1048576 ::boot
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS TCP listen-accept smoke ==="
echo "  agnos:      $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  gnoboot:    $GNOBOOT ($(stat -c %s "$GNOBOOT") B)"
echo "  OVMF code:  $OVMF_CODE"
echo "  ESP image:  $ESP"
echo "  log dir:    $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
HOST_PORT="${HOST_PORT:-15555}"
pass=0
fail=0

# --- Scenario 1: accept-one ----------------------------------------------
# Boot qemu with hostfwd, sleep to let kernel reach net_init+listen, run
# `nc` against the hostfwd port, expect the kernel to log accept-success
# AND nc to receive the smoke banner.
echo "Scenario 1: accept-one"
cp "$OVMF_VARS_SRC" "$WORK/vars-1.fd"
chmod +w "$WORK/vars-1.fd"
LOG_1="$LOGS/1-accept-one.log"
NC_OUT_1="$LOGS/1-accept-one.nc-output"

(
    timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-1.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "virtio-blk-pci,drive=esp0" \
        -netdev "user,id=u1,hostfwd=tcp::$HOST_PORT-:8080" \
        -device "virtio-net-pci,netdev=u1" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$LOG_1"
) &
QEMU_PID=$!

# Wait for the kernel to reach the listen hook. Boot through OVMF +
# gnoboot + kernel-init to the post-scheduler smoke point takes ~4-5s
# of wall time. After that the kernel polls for connections over ~8s.
# So poll the qemu hostfwd port from ~3s to ~20s after qemu start.
PROBE_LOG="$LOGS/1-accept-one.probe-log"
> "$PROBE_LOG"
for ws in 3 5 7 9 11 13 15 17; do
    sleep 2
    PY_OUT=$(python3 -c "
import socket, sys
try:
    s = socket.socket()
    s.settimeout(3)
    s.connect(('localhost', $HOST_PORT))
    data = s.recv(256)
    sys.stdout.buffer.write(data)
    s.close()
    sys.exit(0 if data else 11)
except ConnectionRefusedError:
    sys.exit(12)
except socket.timeout:
    sys.exit(13)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(14)
" 2>>"$PROBE_LOG")
    rc=$?
    echo "  probe ws=$ws rc=$rc bytes=${#PY_OUT}" >> "$PROBE_LOG"
    if [ "$rc" = "0" ]; then
        printf '%s' "$PY_OUT" > "$NC_OUT_1"
        break
    fi
done

# Wait for qemu to finish (timeout will fire if not).
wait $QEMU_PID 2>/dev/null

# Check both kernel-side log + host-side nc output.
ok_kernel=0
ok_host=0
if strings "$LOG_1" | grep -qE "tcp_accept: conn_id="; then
    ok_kernel=1
fi
if [ -f "$NC_OUT_1" ] && grep -q "tcp_listen smoke" "$NC_OUT_1"; then
    ok_host=1
fi
if [ "$ok_kernel" = "1" ] && [ "$ok_host" = "1" ]; then
    echo "  PASS: accept-one (kernel logged accept + host received banner)"
    pass=$((pass + 1))
else
    echo "  FAIL: accept-one"
    [ "$ok_kernel" = "0" ] && echo "        - kernel log missing 'tcp_accept: conn_id='"
    [ "$ok_host" = "0" ] && echo "        - host did not receive banner string"
    echo "        --- last 20 lines of kernel log ---"
    strings "$LOG_1" | tail -20 | sed 's/^/        /'
    if [ -f "$NC_OUT_1" ]; then
        echo "        --- host nc output ---"
        cat "$NC_OUT_1" | sed 's/^/        /'
    fi
    fail=$((fail + 1))
fi
echo ""

# --- Scenario 2: listen-no-connect ---------------------------------------
# Same boot but no host-side probe. Expect 'tcp_listen smoke: no
# connection within timeout' line (proves the listener didn't
# spuriously accept).
echo "Scenario 2: listen-no-connect"
cp "$OVMF_VARS_SRC" "$WORK/vars-2.fd"
chmod +w "$WORK/vars-2.fd"
LOG_2="$LOGS/2-listen-no-connect.log"

timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars-2.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -netdev "user,id=u2" \
    -device "virtio-net-pci,netdev=u2" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG_2"

if strings "$LOG_2" | grep -qE "tcp_listen smoke: no connection within timeout"; then
    echo "  PASS: listen-no-connect (timeout line emitted as expected)"
    pass=$((pass + 1))
else
    echo "  FAIL: listen-no-connect (timeout line not emitted)"
    echo "        --- last 20 lines of kernel log ---"
    strings "$LOG_2" | tail -20 | sed 's/^/        /'
    fail=$((fail + 1))
fi
echo ""

# --- Summary ------------------------------------------------------------

echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
