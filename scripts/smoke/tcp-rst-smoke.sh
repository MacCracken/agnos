#!/bin/bash
# tcp-rst-smoke — agnos 1.57.17: a segment that matches no connection is answered with ONE RST (RFC 9293 § 3.10.7.1),
# measured from the HOST through QEMU user networking (SLIRP), at -smp 1 and -smp 4.
#
# Issue: docs/development/issues/archived/2026-10-31-a-segment-for-no-connection-gets-no-rst.md (filed from agora 1.12.4).
# Kernel: kernel/core/net_tcp.cyr tcp_rst_noconn + net_handle_tcp_locked's no-match path. The in-kernel shapes (SEQ /
# ACK / flags / checksums, the destination gate, never-in-reply-to-a-RST) are TCP_ADDR_SELFTEST's R arms
# (sock-owner-smoke boot A); this smoke is what a peer actually sees.
#
# Boots a TCP_LISTEN_SMOKE=1 kernel (the in-kernel HTTP server on :8080, net_poll-ing forever, selftests.cyr) with two
# hostfwds — HP_SRV -> guest 8080 (the server) and HP_CLOSED -> guest 2424 (nothing listens) — and a host probe:
#   C  CLOSED PORT. SLIRP accepts the host connection at once and SYNs the guest. Before 1.57.17 the guest dropped the
#      SYN and the host saw EOF only when SLIRP gave up on its own SYN — 86.04 s, measured in the issue. Now the guest
#      answers RST|ACK and SLIRP ends the host connection at once. PASS: an end (EOF / reset / refused) in < 2 s.
#   H  HALF-OPEN (the issue's case 1, a 4-tuple agnos let go of): the server sends its banner and closes (FIN); the
#      host reads EOF but keeps its end OPEN, so SLIRP holds CLOSE_WAIT toward the guest. agnos's held FIN slot sees
#      its FIN ACKed and is released TCP_FINWAIT2_US (8 s) later — the 4-tuple is gone. After TCPRST_HOLD (11 s) the
#      host sends a byte every 0.25 s. The held slot advertised window 0 (its ring is unbound), so SLIRP's first
#      segment to the guest is a zero-window PROBE on its persist timer (TCPTV_PERSMIN, 5 s — measured 5.0 / 5.5 s).
#      Before 1.57.17 every probe was dropped and SLIRP kept probing: every send succeeded and the host never
#      learned. Now the probe draws <SEQ=SEG.ACK><CTL=RST>, SLIRP closes the host socket, and a later send raises
#      EPIPE / ECONNRESET. PASS: an error within 10 s of the first send (the 5 s persist floor + margin).
#   then a second plain fetch (`http: served conn=2`, the dwell marker) proves the server outlived both.
# Exit 0 = every check of every variant passed; 1 = any FAIL; 2 = a variant never booted (firmware VOID).
# Env: TCPRST_SMP (default "1 4"); SMOKE_KERNEL=<path> boots a prebuilt kernel (the falsification hook — a kernel
#      without the fix fails C with `end=timeout dt=20` and H with `end=none`); TCPRST_CAP (default 20 s: the wait
#      ceiling for each end); TCPRST_HOLD (default 11 s); QEMU_TRIES; QEMU_TIMEOUT (default 150).
# Requires: a kernel built with TCP_LISTEN_SMOKE=1 (sweep's run_gate builds it), qemu, OVMF, mtools, parted, gnoboot,
# python3.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/gnoboot}"
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

WORK="$ROOT/build/tcp-rst-smoke"
LOGS="$ROOT/build/tcp-rst-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

cat > "$WORK/probe.py" <<'PY'
# Host half of tcp-rst-smoke: follows the serial log (offset reset whenever it SHRINKS — qemu_dwell truncates it on
# every VOID retry), and once the server says it is serving runs C, H and the closing fetch. Results -> argv[4].
import os, socket, sys, time
log, srv, closed, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
cap, hold = float(sys.argv[5]), float(sys.argv[6])
res = open(out, "a", buffering=1)
def serving(budget):
    off = 0; buf = b""; t0 = time.time()
    while time.time() - t0 < budget:
        try: sz = os.path.getsize(log)
        except OSError: sz = 0
        if sz < off: off = 0; buf = b""; res.write("probe: log shrank, offset reset\n")
        if sz > off:
            with open(log, "rb") as f: f.seek(off); buf += f.read(sz - off)
            off = sz
        if b"http: serving :8080" in buf: return True
        time.sleep(0.2)
    return False
def fetch():
    s = socket.create_connection(("127.0.0.1", srv), timeout=10); s.settimeout(10); data = b""
    while True:
        d = s.recv(4096)
        if not d: break
        data += d
    return s, data
if not serving(600):
    res.write("probe: the server never said it was serving\n"); sys.exit(1)
time.sleep(0.5)
# C — the closed port.
t0 = time.time(); end = "timeout"
try:
    s = socket.create_connection(("127.0.0.1", closed), timeout=cap); s.settimeout(cap)
    try:
        d = s.recv(1)
        end = "eof" if not d else "data"
    except ConnectionResetError: end = "reset"
    except socket.timeout: end = "timeout"
    s.close()
except ConnectionRefusedError: end = "refused"
except Exception as e: end = "error:%s" % e.__class__.__name__
res.write("CLOSED end=%s dt=%.2f\n" % (end, time.time() - t0))
# H — the half-open connection.
try:
    s, data = fetch()
    res.write("HALFOPEN-BANNER ok=%d bytes=%d\n" % (b"tcp_listen smoke" in data, len(data)))
    time.sleep(hold)
    t1 = time.time(); end = "none"; n = 0
    while time.time() - t1 < cap:
        try:
            s.send(b"X"); n += 1
        except (BrokenPipeError, ConnectionResetError) as e:
            end = "reset"; break
        time.sleep(0.25)
    res.write("HALFOPEN end=%s dt=%.2f sends=%d\n" % (end, time.time() - t1, n))
    s.close()
except Exception as e:
    res.write("HALFOPEN end=error:%s\n" % e)
# The closing fetch: the server outlived both (and its `http: served conn=2` ends the dwell).
try:
    s, data = fetch(); s.close()
    res.write("FINAL-FETCH ok=%d\n" % (b"tcp_listen smoke" in data))
except Exception as e:
    res.write("FINAL-FETCH error: %s\n" % e)
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }
hget() { grep -E "^$1 " "$HOUT" | tail -1; }
hfield() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

echo "=== tcp-rst-smoke (a segment for no connection draws a RST; RFC 9293 § 3.10.7.1) ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
CAP="${TCPRST_CAP:-20}"; HOLD="${TCPRST_HOLD:-11}"
for smp in ${TCPRST_SMP:-1 4}; do
    P="[smp$smp]"
    LOG="$LOGS/smp$smp.log"; HOUT="$LOGS/smp$smp.host"; : > "$LOG"; : > "$HOUT"
    ACCEL="$(smoke_accel "$smp")"
    HP_SRV="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    HP_CLOSED="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    echo ""
    echo "Variant $P: -smp $smp  accel: $ACCEL  server port $HP_SRV  closed port $HP_CLOSED"
    python3 "$WORK/probe.py" "$LOG" "$HP_SRV" "$HP_CLOSED" "$HOUT" "$CAP" "$HOLD" > "$LOGS/smp$smp.probe-err" 2>&1 &
    PROBE_PID=$!
    # shellcheck disable=SC2086
    qemu_dwell_kernel "$LOG" "http: served conn=2" "${QEMU_TIMEOUT:-150}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M -smp "$smp" $ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "nvme,drive=esp0,serial=AGNOS-RST" \
        -netdev "user,id=u1,hostfwd=tcp:127.0.0.1:$HP_SRV-:8080,hostfwd=tcp:127.0.0.1:$HP_CLOSED-:2424" \
        -device "virtio-net-pci,netdev=u1" \
        -serial stdio -display none -no-reboot
    sleep 1
    kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null
    if ! strings "$LOG" | grep -q "AGNOS kernel v"; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    sed 's/^/    host: /' "$HOUT"
    echo "  -- $P verdicts --"
    want "http: serving :8080"                   "$P the server came up"
    want "http: served conn=1"                   "$P the server served the half-open connection"
    want "http: served conn=2"                   "$P the server outlived both cases (the closing fetch)"
    if grep -q "^HALFOPEN-BANNER ok=1" "$HOUT"; then ok "$P host received the banner"; else bad "$P host did not receive the banner"; fi
    C="$(hget CLOSED)"; CE="$(hfield "$C" end)"; CD="$(hfield "$C" dt)"
    case "$CE" in
        eof|reset|refused)
            if python3 -c "import sys; sys.exit(0 if float('${CD:-99}') < 2.0 else 1)"; then
                ok "$P C: a connect to a port nobody listens on ended at once ($CE after ${CD} s; 86 s before 1.57.17)"
            else bad "$P C: the closed port ended ($CE) but only after ${CD} s (want < 2 s)"; fi ;;
        *) bad "$P C: the closed port did not end within ${CAP} s (end=${CE:-?} dt=${CD:-?}) — the SYN drew no RST|ACK" ;;
    esac
    H="$(hget HALFOPEN)"; HE="$(hfield "$H" end)"; HD="$(hfield "$H" dt)"
    if [ "$HE" = "reset" ] && python3 -c "import sys; sys.exit(0 if float('${HD:-99}') < 10.0 else 1)"; then
        ok "$P H: a send into the 4-tuple agnos released was reset (the host learned ${HD} s after its first send)"
    else bad "$P H: the host never learned its peer was gone (end=${HE:-?} dt=${HD:-?}; want reset in < 10 s)"; fi
    if grep -q "^FINAL-FETCH ok=1" "$HOUT"; then ok "$P the closing fetch got the banner"; else bad "$P the closing fetch failed"; fi
    deny "fault:|PANIC"                          "$P no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"                 "$P no latched invariant (incl. net: lock overlap/missing)"
    [ "$fail" -eq 0 ] || { echo "        --- last 15 lines of the kernel log ---"; strings "$LOG" | tail -15 | sed 's/^/        /'; }
done

echo ""
echo "=== tcp-rst-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
