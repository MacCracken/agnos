#!/bin/bash
# TCP server-side smoke (TCP_LISTEN_SMOKE=1): the persistent HTTP server in selftests.cyr listens on :8080; the
# host connects through a SLIRP hostfwd and must receive the version banner, and the kernel must log
# `tcp_accept: conn_id=` and `http: served conn=1` (the dwell marker).
#
# 1.57.7 (S4.1): scenario 1 (accept-one) is converted to the banner-gated retry (qemu_dwell_kernel; exit 2 on a
# firmware VOID), prints a PASS/FAIL line per check and denies $SMOKE_INVARIANT_DENY. Its host probe runs in the
# background, polls the serial log for `http: serving :8080` and RESETS its read offset whenever the log shrinks
# (qemu_dwell truncates it on every VOID retry), then connects. Scenario 2 (listen-no-connect) is DELETED: it
# grepped `tcp_listen smoke: no connection within timeout`, a line the persistent server never prints and which
# exists nowhere in kernel/. Gated by scripts/sweep.sh (TCP_LISTEN_SMOKE=1) since 1.57.7.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found — this gate measured NOTHING" >&2; exit 1; }
for tool in qemu-system-x86_64 python3 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="${SMOKE_KERNEL:-$ROOT/build/agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "tcp_listen(8080)"; then
    echo "ERROR: kernel was not built with TCP_LISTEN_SMOKE=1 — rebuild: TCP_LISTEN_SMOKE=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/tcp-listen-smoke"
LOGS="$ROOT/build/tcp-listen-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

HOST_PORT="${HOST_PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}"
LOG_1="$LOGS/1-accept-one.log"
NC_OUT_1="$LOGS/1-accept-one.host-output"
PROBE_LOG="$LOGS/1-accept-one.probe-log"
: > "$LOG_1"
echo "=== AGNOS TCP listen-accept smoke (host port $HOST_PORT) ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"

# Host probe: follow the serial log (offset reset on truncation), connect once the server says it is serving.
python3 - "$LOG_1" "$HOST_PORT" "$NC_OUT_1" > "$PROBE_LOG" 2>&1 <<'PY' &
import socket, sys, time, os
log, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
off = 0; buf = b""; t0 = time.time()
while time.time() - t0 < 300:
    try: sz = os.path.getsize(log)
    except OSError: sz = 0
    if sz < off: off = 0; buf = b""; print("log shrank: offset reset", flush=True)
    if sz > off:
        with open(log, "rb") as f: f.seek(off); buf += f.read(sz - off)
        off = sz
    if b"http: serving :8080" in buf:
        for attempt in range(10):
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=5)
                s.settimeout(10); data = b""
                while True:
                    d = s.recv(4096)
                    if not d: break
                    data += d
                s.close()
                open(out, "wb").write(data)
                print("got %d bytes on attempt %d" % (len(data), attempt), flush=True)
                if data: sys.exit(0)
            except Exception as e:
                print("attempt %d: %s" % (attempt, e), flush=True)
            time.sleep(1)
        buf = b""
    time.sleep(0.2)
print("probe gave up", flush=True)
sys.exit(1)
PY
PROBE_PID=$!

qemu_dwell_kernel "$LOG_1" "http: served conn=1" "${QEMU_TIMEOUT:-60}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
    -netdev "user,id=u1,hostfwd=tcp:127.0.0.1:$HOST_PORT-:8080" \
    -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null
qemu_assert_booted "$LOG_1" || exit 2

pass=0
fail=0
if strings "$LOG_1" | grep -q "tcp_accept: conn_id="; then echo "PASS: kernel logged tcp_accept"; pass=$((pass + 1));
else echo "FAIL: kernel log missing 'tcp_accept: conn_id='"; fail=$((fail + 1)); fi
if strings "$LOG_1" | grep -q "http: served conn=1"; then echo "PASS: kernel served conn 1"; pass=$((pass + 1));
else echo "FAIL: kernel log missing 'http: served conn=1'"; fail=$((fail + 1)); fi
if [ -f "$NC_OUT_1" ] && grep -q "tcp_listen smoke" "$NC_OUT_1"; then echo "PASS: host received the banner"; pass=$((pass + 1));
else echo "FAIL: host did not receive the banner (probe log below)"; sed 's/^/        /' "$PROBE_LOG"; fail=$((fail + 1)); fi
if strings "$LOG_1" | grep -qE "$SMOKE_INVARIANT_DENY"; then
    echo "FAIL: a latched kernel invariant fired"; strings "$LOG_1" | grep -E "$SMOKE_INVARIANT_DENY" | head -3; fail=$((fail + 1))
else echo "PASS: no latched invariant (incl. net: lock overlap/missing)"; pass=$((pass + 1)); fi
[ "$fail" -eq 0 ] || { echo "        --- last 20 lines of kernel log ---"; strings "$LOG_1" | tail -20 | sed 's/^/        /'; }
echo "=== tcp-listen-smoke: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
