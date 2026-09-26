#!/bin/bash
# tcp-inbound-smoke — agnos 1.57.7 step S4, ring-3 end-to-end on a PLAIN kernel (D19): tests/tcpin seeded as
# /bin/agnsh (the orchestrator) and /bin/tcpin (the X phase's children), plus a host helper keyed on its markers.
#
# Issues: docs/development/issues/2026-09-23-inbound-tcp-syn-dropped-by-isr-drain.md (A1, A2, A2b, X),
#         docs/development/issues/2026-09-23-sock-recv-never-reports-eof-after-peer-fin.md (E1, E2, A3).
#
# Phases (tests/tcpin/tcpin.cyr has the detail):
#   E1  EOF over loopback (the FIN demuxed in syscall context)          TCPIN-EOF-LO-OK
#   E2  EOF over the wire (a QEMU guestfwd `cmd:printf BYE-WIRE` peer; its FIN arrives through the ISR drain)
#                                                                      TCPIN-EOF-WIRE-OK
#   A1  ISR-ONLY accept: in the window the program makes no net syscall, so the SYN, its ACK and the GET can only
#       have been demuxed by the timer/MSI drain; ONE #57 finds the conn with data queued.
#                                                                      TCPIN-ISR-ACCEPT-OK + host `A1 ok=1`
#   A2  a pause-between-polls server: 12 sequential host clients, each connect-to-close < 2 s ("fast" rules out
#       the SLIRP SYN-retransmit rescue the issue measured)           `A2 ok=12 fast=12`
#   A2b the same with a busy-poll server                               `A2B ok=12 fast=12`
#   A3  FIN-before-accept burst: 10 concurrent clients send GET + shutdown(SHUT_WR) while nobody accepts for 3 s;
#       all served (accepted in CLOSE_WAIT, data then EOF, reply sent in CLOSE_WAIT)
#                                                                      TCPIN-A3-OK served=10 + host `A3 ok=10`
#   X   cross-CPU mix: an echo server + 2 auto-port clients on loopback (unpinned #43 children) while the
#       orchestrator serves 12 inbound                                 TCPIN-X-OK + host `X ok=12`
# A3 ADMISSION ARITHMETIC: 8 slots, the kept listener = 1, the passive reserve = 1, so at most 6 passive children
# at once and at most 4 in SYN_RCVD. The 10 SYNs arrive together, so about 4 are admitted and the rest wait for
# the host's SYN retransmits (~1-3 s, then doubling); the guest drains children from +3 s. The last admissions land
# around +20 s; the 60 s client timeout and the 90 s guest cap leave >= 3x margin. A1's child is closed.
#
# Variants (all GATED): msix (-smp 1, MSI-X), vectors0 (-smp 1, virtio-net vectors=0: the timer drain alone),
# smp4 (-smp 4 under smoke_accel: KVM if /dev/kvm is writable, else tcg,thread=multi).
# Exit 0 only when every check of every variant passes; 2 when a variant never booted (firmware VOID).
# Env: TCPIN_VARIANTS (default "msix vectors0 smp4"), TCPIN_KERNEL (a prebuilt kernel — the falsification hook),
#      QEMU_TRIES, QEMU_TIMEOUT (default 300).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== tcp-inbound smoke (inbound TCP in interrupt context + #49 EOF + half-close) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/tcp-inbound"; LOGS="$ROOT/build/tcp-inbound-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

if [ -n "${TCPIN_KERNEL:-}" ]; then
    KERNEL="$TCPIN_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/tcpin/tcpin (--agnos)..."
( cd "$ROOT/tests/tcpin" && cyrius build --agnos tcpin.cyr build/tcpin ) > "$LOGS/tcpin-build.log" 2>&1 \
    || { echo "  ERROR: tcpin build failed (see $LOGS/tcpin-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/tcpin/build/tcpin" "$SEED/bin/agnsh"
cp "$ROOT/tests/tcpin/build/tcpin" "$SEED/bin/tcpin"
ring3_seed_image "$WORK/T.img" "$KERNEL" "$SEED" "AGNOS-TCPIN" || { echo "  ERROR: image"; exit 1; }

cat > "$WORK/helper.py" <<'PY'
# Host half of tcp-inbound-smoke: follows the serial log (offset reset whenever it SHRINKS — qemu_dwell truncates
# it on every VOID retry) and runs each phase's clients when its marker appears. Results go to helper.out.
import os, socket, sys, threading, time
log, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
GET = b"GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
res = open(out, "a", buffering=1)
def one(half_close=False, tmo=15.0):
    t0 = time.time(); data = b""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=tmo)
        s.settimeout(tmo); s.sendall(GET)
        if half_close: s.shutdown(socket.SHUT_WR)
        while True:
            d = s.recv(4096)
            if not d: break
            data += d
        s.close()
    except Exception as e:
        res.write("  client error: %s\n" % e)
    return data.startswith(b"HTTP/1.1 200"), time.time() - t0
def seq(tag, n):
    ok = fast = 0
    for _ in range(n):
        o, dt = one()
        ok += o; fast += (o and dt < 2.0)
    res.write("%s ok=%d fast=%d\n" % (tag, ok, fast))
def a3():
    out3 = [None] * 10
    def w(i): out3[i] = one(True, 60.0)
    th = [threading.Thread(target=w, args=(i,)) for i in range(10)]
    for t in th: t.start()
    for t in th: t.join()
    ok = sum(1 for o in out3 if o and o[0]); mx = max((o[1] for o in out3 if o), default=0)
    res.write("A3 ok=%d maxdt=%.1f\n" % (ok, mx))
acts = [(b"TCPIN-ISR-WINDOW", lambda: res.write("A1 ok=%d\n" % one()[0])),
        (b"TCPIN-SERVING\n", lambda: seq("A2", 12)),
        (b"TCPIN-SERVING-BUSY", lambda: seq("A2B", 12)),
        (b"TCPIN-A3-HOLD", a3),
        (b"TCPIN-X-GO", lambda: seq("X", 12))]
off = 0; buf = b""; done = set(); t0 = time.time()
while time.time() - t0 < 900:
    try: sz = os.path.getsize(log)
    except OSError: sz = 0
    if sz < off:
        off = 0; buf = b""; done = set(); res.write("helper: log shrank, offset reset\n")
    if sz > off:
        with open(log, "rb") as f: f.seek(off); buf += f.read(sz - off)
        off = sz
    for i, (m, fn) in enumerate(acts):
        if i not in done and m in buf:
            done.add(i); fn()
    if b"TCPIN-DONE" in buf: break
    time.sleep(0.1)
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
hwant(){ if grep -qE -- "$1" "$HOUT"; then ok "$2"; else bad "$2 (host missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for v in ${TCPIN_VARIANTS:-msix vectors0 smp4}; do
    LOG="$LOGS/tcpin-$v.log"; HOUT="$LOGS/helper-$v.out"; : > "$LOG"; : > "$HOUT"
    SMP=1; DEV="virtio-net-pci,netdev=n0"; R3_ACCEL="-cpu max"
    case "$v" in
        msix) ;;
        vectors0) DEV="virtio-net-pci,netdev=n0,vectors=0" ;;
        smp4) SMP=4; R3_ACCEL="$(smoke_accel 4)" ;;
        *) echo "  ERROR: unknown variant '$v'"; exit 1 ;;
    esac
    export R3_ACCEL
    HP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    echo ""
    echo "Variant $v: -smp $SMP  accel: $R3_ACCEL  host port $HP"
    python3 "$WORK/helper.py" "$LOG" "$HP" "$HOUT" > "$LOGS/helper-$v.err" 2>&1 &
    HPID=$!
    cp "$WORK/T.img" "$WORK/T-$v.img"
    ring3_seed_boot "$WORK/T-$v.img" "$LOG" "TCPIN-DONE" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$SMP" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HP-:8090,guestfwd=tcp:10.0.2.100:18903-cmd:printf BYE-WIRE" \
        -device "$DEV"
    brc=$?
    kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
    if [ "$brc" -eq 2 ]; then echo "  VOID: variant $v never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "TCPIN-|TCPX-|kybernet: (exec|emergency)" | sed 's/^/    /'
    sed 's/^/    host: /' "$HOUT"
    echo "  -- $v verdicts --"
    want "kybernet: exec /bin/agnsh"              "[$v] kybernet launched the orchestrator"
    want "TCPIN-EOF-LO-OK"                        "[$v] E1 EOF over loopback"
    want "TCPIN-EOF-WIRE-OK"                      "[$v] E2 EOF over the wire (guestfwd cmd: form)"
    want "TCPIN-ISR-ACCEPT-OK"                    "[$v] A1 interrupt-context passive open (one #57, data queued)"
    hwant "^A1 ok=1"                              "[$v] A1 host got the 200"
    want "TCPIN-A2-DONE served=12"                "[$v] A2 pause server served 12"
    hwant "^A2 ok=12 fast=12"                     "[$v] A2 host 12/12 ok, 12/12 fast (< 2 s)"
    want "TCPIN-A2B-DONE served=12"               "[$v] A2b busy server served 12"
    hwant "^A2B ok=12 fast=12"                    "[$v] A2b host 12/12 ok, 12/12 fast"
    want "TCPIN-A3-OK served=10"                  "[$v] A3 FIN-before-accept burst served 10 (half-close)"
    hwant "^A3 ok=10"                             "[$v] A3 host 10/10"
    want "TCPIN-X-OK srv=0 cli=0,0 served=12"     "[$v] X cross-CPU mix (echo server + 2 clients + 12 inbound)"
    want "TCPX-SRV-OK n=80"                       "[$v] X echo server 80 byte-exact"
    want "TCPX-CLI-OK k=1 n=40"                   "[$v] X client 1"
    want "TCPX-CLI-OK k=2 n=40"                   "[$v] X client 2"
    hwant "^X ok=12"                              "[$v] X host 12/12"
    want "TCPIN-DONE"                             "[$v] TCPIN-DONE"
    deny "TCPIN-.*FAIL|TCPX-.*FAIL|NOCONN"        "[$v] no FAIL / NOCONN marker"
    deny "fault:|PANIC"                           "[$v] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"                  "[$v] no latched invariant (incl. net: lock overlap/missing)"
    if strings "$LOG" | grep -q "virtio-net: TX ring full"; then echo "  INFO: [$v] virtio-net TX ring filled at least once"; fi
    grep -E "^A3 " "$HOUT" | sed "s/^/  INFO: [$v] /"
done

echo ""
echo "=== tcp-inbound-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
