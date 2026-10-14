#!/bin/bash
# sandhi-async-smoke — agnos 1.57.14: sandhi's cooperative server (`sandhi_server_run_async`) BOOTED on agnos.
#
# Why: roadmap § "Recorded by cyrius 6.6.19". agnos has no readiness probe that leaves data in place, so cyrius
# 6.6.19 (A2) built `async_await_readable` on agnos over a STASH in its socket adapter (`_agnos_fd_ready`
# pre-accepts a listener's pending conn, `sys_sock_accept` hands it out before issuing #57; `sleep_ms`#41 backoff
# 1 -> 32 ms). That was verified only under cyrius's PTRACE_SYSEMU fake kernel; this gate is the boot test cyrius
# asked agnos for, at the 6.6.20 pin.
#
# tests/sandhi/sandhix is seeded as /bin/agnsh on a PLAIN kernel (ring3-seed.sh) and serves HTTP on guest 8090 with
# NO stop flag, so its idle path is `async_await_readable(sfd)` — the stash. The host helper times nothing until the
# server is known to LISTEN and has parked again, so every accept comes through the stash:
#   R   2 s on, GET /ready, re-sent until answered (90 s)  host `R ok=1`; guest `SANDHIX-READY`
#   P1  2 s later (parked), one GET                       host `P1 ok=1 fast=1` (< 2 s connect-to-close)
#   P2  6 concurrent GETs (max_conns 4 -> two batches)    host `P2 ok=6` (+ an INFO line with the slowest)
#   P3  3 s idle (parked again), then 3 sequential GETs   host `P3 ok=3`
#   Q   GET /quit -> the handler prints `SANDHIX-DONE served=10` and exits 0 (/ready is answered, never counted)
# ⚠ WHY R, AND NOT A FIXED SLEEP: sandhix prints `SANDHIX-LISTENING` BEFORE sandhi_server_run_async binds and
#   listens, and agnos DROPS a SYN to a port with no listener (net_tcp.cyr: `tcp_find_listen` < 0 -> return; no RST).
#   A P1 that raced listen() would not be refused — SLIRP would re-send the SYN later and P1 would be served SLOW
#   (fast=0) for a reason that is the harness's, not the stash's. An R attempt that comes back with no bytes at all
#   is re-sent; it is never counted, so a late duplicate cannot move `served=10`. Measured at 1.57.14 with R sent
#   AT ONCE on the marker: it raced listen() on both variants and was answered at 6.07 s (TCG -smp 1) / 6.32 s (KVM
#   -smp 4) — SLIRP's re-sent SYN, so a P1 sent there would have scored fast=0. R therefore waits the same 2 s the
#   P1 of the first version did (that alone passed 20/20), and the probe turns "usually listening by then" into a
#   checked fact.
# P2 ADMISSION ARITHMETIC: 8 TCP slots, the listener = 1, the passive reserve = 1 -> at most 6 passive children, and
#   at most TCP_SYNRCVD_MAX = 4 in SYN_RCVD. The 6 SYNs arrive together, so when the guest is slow to finish the
#   handshakes (TCG -smp 1) about 4 are admitted and the rest are dropped and wait for SLIRP's SYN re-send (SLIRP
#   completes the host-side handshake itself and re-sends the guest-side SYN with a doubling backoff); sandhi then
#   accepts at most max_conns = 4 per batch. Measured at 1.57.14: slowest of the 6 = 6.17 s on TCG -smp 1, 1.14 s
#   on KVM -smp 4. The client timeout is 60 s, tcp-inbound-smoke's, so two more doublings still fit (>= 3x margin
#   over the measured tail); a 20 s timeout would have covered only one.
# Variants (both GATED): smp1 (-smp 1, TCG) and smp4 (-smp 4 under smoke_accel).
# Exit 0 only when every check of every variant passes; 2 when a variant never booted (firmware VOID).
# Env: SANDHIX_VARIANTS (default "smp1 smp4"), SANDHIX_KERNEL (a prebuilt kernel), QEMU_TRIES, QEMU_TIMEOUT (default 240).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== sandhi-async smoke (sandhi_server_run_async on a booted agnos: the 6.6.19 readiness stash) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/sandhi-async"; LOGS="$ROOT/build/sandhi-async-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

if [ -n "${SANDHIX_KERNEL:-}" ]; then
    KERNEL="$SANDHIX_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson); vendor its stdlib at the pin first.
echo "Building tests/sandhi/sandhix (--agnos)..."
( cd "$ROOT/tests/sandhi" && cyrius lib sync && rm -f build/sandhix && cyrius build --agnos sandhix.cyr build/sandhix; rc=$?; rm -f cyrius.lock; exit $rc ) \
    > "$LOGS/sandhix-build.log" 2>&1 || { echo "  ERROR: sandhix build failed (see $LOGS/sandhix-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/sandhi/build/sandhix" "$SEED/bin/agnsh"
ring3_seed_image "$WORK/S.img" "$KERNEL" "$SEED" "AGNOS-SANDHI" || { echo "  ERROR: image"; exit 1; }

cat > "$WORK/helper.py" <<'PY'
# Host half of sandhi-async-smoke: follows the serial log (offset reset whenever it SHRINKS — qemu_dwell truncates
# it on every VOID retry) and runs the phases once `SANDHIX-LISTENING` appears. Results go to helper.out.
import os, socket, sys, threading, time
log, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
res = open(out, "a", buffering=1)
def one(path=b"/", tmo=60.0):                          # 60 s: the P2 arithmetic in the header
    t0 = time.time(); data = b""
    req = b"GET " + path + b" HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=tmo)
        s.settimeout(tmo); s.sendall(req)
        while True:
            d = s.recv(4096)
            if not d: break
            data += d
        s.close()
    except Exception as e:
        res.write("  client error: %s\n" % e)
    ok = data.startswith(b"HTTP/1.1 200") and (b"sandhi-async-ready" if path == b"/ready" else b"sandhi-async-ok") in data
    return ok, time.time() - t0, len(data)
def run():
    # R: the server is LISTENING only once /ready is answered (see the header). Re-sent only when an attempt got no
    # bytes at all; anything else that is not the ready reply is a real failure and stops here.
    time.sleep(2.0)                                   # past listen() in every measured run (header); R checks it
    t_r = time.time(); tries = 0; ready = False
    while time.time() - t_r < 90.0:
        tries += 1
        o, dt, nb = one(b"/ready")
        if o: ready = True; break
        if nb: break
        time.sleep(0.5)
    res.write("R ok=%d tries=%d dt=%.2f\n" % (ready, tries, time.time() - t_r))
    if not ready: return
    time.sleep(2.0)                                   # let the server finish R's batch and park in async_await_readable
    o, dt, _ = one(); res.write("P1 ok=%d fast=%d dt=%.2f\n" % (o, o and dt < 2.0, dt))
    r = [None] * 6
    def w(i): r[i] = one()
    th = [threading.Thread(target=w, args=(i,)) for i in range(6)]
    for t in th: t.start()
    for t in th: t.join()
    res.write("P2 ok=%d maxdt=%.2f\n" % (sum(1 for x in r if x and x[0]), max(x[1] for x in r if x)))
    time.sleep(3.0)                                   # idle: parked again
    ok = 0
    for _ in range(3): ok += one()[0]
    res.write("P3 ok=%d\n" % ok)
    one(b"/quit", 10.0)                               # the server exits inside this handler; no reply expected
    res.write("Q sent\n")
off = 0; buf = b""; started = False; t0 = time.time()
while time.time() - t0 < 600:
    try: sz = os.path.getsize(log)
    except OSError: sz = 0
    if sz < off:
        off = 0; buf = b""; res.write("helper: log shrank, offset reset\n")
    if sz > off:
        with open(log, "rb") as f: f.seek(off); buf += f.read(sz - off)
        off = sz
    if not started and b"SANDHIX-LISTENING" in buf:
        started = True; run()
    if b"SANDHIX-DONE" in buf or b"SANDHIX-FAIL" in buf: break
    time.sleep(0.1)
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
hwant(){ if grep -qE -- "$1" "$HOUT"; then ok "$2"; else bad "$2 (host missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for v in ${SANDHIX_VARIANTS:-smp1 smp4}; do
    LOG="$LOGS/sandhix-$v.log"; HOUT="$LOGS/helper-$v.out"; : > "$LOG"; : > "$HOUT"
    SMP=1; R3_ACCEL="-cpu max"
    case "$v" in
        smp1) ;;
        smp4) SMP=4; R3_ACCEL="$(smoke_accel 4)" ;;
        *) echo "  ERROR: unknown variant '$v'"; exit 1 ;;
    esac
    export R3_ACCEL
    HP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    echo ""
    echo "Variant $v: -smp $SMP  accel: $R3_ACCEL  host port $HP"
    python3 "$WORK/helper.py" "$LOG" "$HP" "$HOUT" > "$LOGS/helper-$v.err" 2>&1 &
    HPID=$!
    cp "$WORK/S.img" "$WORK/S-$v.img"
    # ⚠ The dwell marker is a BASIC regex (qemu_dwell's `grep -qa`), so the alternation is `\|` — a bare `|` is a literal
    # there, and the first run of this smoke dwelled every variant to its full timeout (240 s) for that reason alone.
    ring3_seed_boot "$WORK/S-$v.img" "$LOG" 'SANDHIX-DONE\|SANDHIX-FAIL' "${QEMU_TIMEOUT:-240}" "$WORK" -smp "$SMP" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HP-:8090" -device "virtio-net-pci,netdev=n0"
    brc=$?
    sleep 1; kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
    if [ "$brc" -eq 2 ]; then echo "  VOID: variant $v never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "SANDHIX-|kybernet: (exec|emergency)" | grep -v "SANDHIX-REQ" | sed 's/^/    /'
    echo "    SANDHIX-REQ lines: $(strings "$LOG" | grep -c 'SANDHIX-REQ')"
    sed 's/^/    host: /' "$HOUT"
    echo "  -- $v verdicts --"
    want "kybernet: exec /bin/agnsh"              "[$v] kybernet launched sandhix"
    want "SANDHIX-LISTENING"                      "[$v] sandhix reached sandhi_server_run_async"
    hwant "^R ok=1"                               "[$v] R /ready answered 200 (the server listens)"
    want "SANDHIX-READY"                          "[$v] the guest served /ready"
    hwant "^P1 ok=1 fast=1"                       "[$v] P1 one GET after the park answered 200 (< 2 s)"
    hwant "^P2 ok=6"                              "[$v] P2 6 concurrent GETs answered 200 (two batches)"
    hwant "^P3 ok=3"                              "[$v] P3 3 GETs after a 3 s idle park answered 200"
    want "SANDHIX-DONE served=10"                 "[$v] the server counted exactly 10 requests and exited 0 on /quit"
    # INFO, not a verdict: the P2 tail against the 60 s client timeout (the header's admission arithmetic).
    p2t="$(sed -n 's/^P2 ok=[0-9]* maxdt=//p' "$HOUT" | head -1)"
    echo "  INFO: [$v] P2 slowest of 6 = ${p2t:-?} s (client timeout 60 s)"
    deny "SANDHIX-FAIL"                           "[$v] no SANDHIX-FAIL (bind / listen / arena)"
    deny "kybernet: emergency"                    "[$v] no emergency shell (sandhix exited 0)"
    deny "fault:|PANIC"                           "[$v] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"                  "[$v] no latched invariant"
done

echo ""
echo "=== sandhi-async-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
