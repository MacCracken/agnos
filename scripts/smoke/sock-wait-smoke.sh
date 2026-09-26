#!/bin/bash
# sock-wait-smoke — agnos 1.57.7 step S6, ring-3 end-to-end on a PLAIN kernel (D19): tests/sockwait seeded as
# /bin/agnsh (the driver) and /bin/sockw (every child role), plus a host sink on 127.0.0.1:HP (reached as 10.0.2.2).
#
# Issue: docs/development/issues/2026-09-23-sock-send-and-connect-hold-the-cpu.md — sock_connect#47, sock_send#48,
# icmp_echo#55/#100 held the CPU (preempt disabled) for up to ~8 s; now they block ONLY their caller.
#
# Phases (tests/sockwait/sockw.cyr has the detail; LO = 127.0.0.1, IP = net_ip):
#   N0  setup                                                  SOCKW-CLOCK-OK, SOCKW-NETIP
#   N1  a loopback handshake completes in the caller's own poll SOCKW-CONNECT-FAST-{LO,IP} (<= 200 ms)
#   N2  the issue's repro: 16 KB one-shot to a slow reader     SOCKW-SEND-OK-{LO,IP}, SOCKW-SEND-FAST-{LO,IP} (<= 4 s)
#   N3  #48 blocked on a full window does not hold the CPU     SOCKW-SEND-YIELDS-{LO,IP} (spinner share >= 800 per mille)
#   N4  D6 + one segment in flight at entry (10 s stall)       SOCKW-STALL-{LO,IP}, SOCKW-STALL-ONEFLIGHT-{LO,IP}
#   N5  a reader stalled 55 s keeps its connection (persist)   SOCKW-PERSIST-OK
#   N6  #47 to a silent port: deadline once, CPU given away    SOCKW-DIAL-DEADLINE-{LO,IP}, SOCKW-CONNECT-YIELDS-{LO,IP}
#   N7  #55/#100: concurrent pingers, a silent host, the bound SOCKW-PING-CONCURRENT, -PING-SILENT-OK, -PING-YIELDS, -PING-BOUND
#   N8  the wire: 16 KB to the host sink + 64 B echo RTTs      SOCKW-WIRE-OK + host HOST-SINK got=16384, SOCKW-WIRE-LAT-OK
#   N9  the RST path: nine dials to a closed host port         SOCKW-DIAL-RST (each -1 <= 500 ms)
#   N10 no slot leaks: three loopback conversations            SOCKW-SLOTS-OK
# Two boots, both GATED: -smp 1 (TCG) and -smp 4 (smoke_accel: KVM when /dev/kvm is writable, else tcg,thread=multi).
# Exit 0 only when every check of every boot passes; 2 when a boot never reached the kernel (firmware VOID).
# Env: SOCKW_SMP (default "1 4"), SOCKW_MODE (all | wire), SOCKW_KERNEL (a prebuilt kernel: the falsification hook,
#      skips the build), SOCKW_KBUILD_ENV (e.g. "KSTACK_HW=1" for the plain build), SOCKW_QEMU_EXTRA (extra QEMU
#      args, e.g. a filter-dump pcap), QEMU_TIMEOUT (default 420).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== sock-wait smoke (#47/#48/#55/#100 block only their caller) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/sock-wait"; LOGS="$ROOT/build/sock-wait-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
MODE="${SOCKW_MODE:-all}"

if [ -n "${SOCKW_KERNEL:-}" ]; then
    KERNEL="$SOCKW_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook)."
else
    echo "Building the PLAIN kernel ${SOCKW_KBUILD_ENV:-}..."
    env ${SOCKW_KBUILD_ENV:-} sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/sockwait/sockw (--agnos)..."
( cd "$ROOT/tests/sockwait" && cyrius build --agnos sockw.cyr build/sockw ) > "$LOGS/sockw-build.log" 2>&1 \
    || { echo "  ERROR: sockw build failed (see $LOGS/sockw-build.log)"; exit 1; }

# HP: a host sink port; CP: a port that was bound then closed (nothing listens: SLIRP answers the SYN with RST).
HP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
CP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')"
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/sw"
cp "$ROOT/tests/sockwait/build/sockw" "$SEED/bin/agnsh"
cp "$ROOT/tests/sockwait/build/sockw" "$SEED/bin/sockw"
printf '%s' "$MODE" > "$SEED/sw/mode"
printf '%s' "$HP" > "$SEED/sw/hostport"
printf '%s' "$CP" > "$SEED/sw/closedport"
ring3_seed_image "$WORK/S.img" "$KERNEL" "$SEED" "AGNOS-SOCKW" || { echo "  ERROR: image"; exit 1; }

cat > "$WORK/sink.py" <<'PY'
# Host sink for N8: per connection, read 16384 bytes, answer "OK 16384\n", then echo until EOF.
import socket, sys, threading
port, out = int(sys.argv[1]), sys.argv[2]
res = open(out, "a", buffering=1)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(8)
def serve(c):
    try:
        c.settimeout(60); got = 0
        while got < 16384:
            d = c.recv(16384 - got)
            if not d: break
            got += len(d)
        res.write("HOST-SINK got=%d\n" % got)
        c.sendall(b"OK %d\n" % got)
        while True:
            d = c.recv(4096)
            if not d: break
            c.sendall(d)
    except Exception as e:
        res.write("HOST-SINK error %s\n" % e)
    c.close()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
hwant(){ if grep -qE -- "$1" "$HOUT"; then ok "$2"; else bad "$2 (host missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for SMP in ${SOCKW_SMP:-1 4}; do
    LOG="$LOGS/sockw-smp$SMP.log"; HOUT="$LOGS/sink-smp$SMP.out"; : > "$LOG"; : > "$HOUT"
    R3_ACCEL="$(smoke_accel "$SMP")"; export R3_ACCEL
    echo ""
    echo "Boot -smp $SMP  accel: $R3_ACCEL  host sink $HP  closed $CP  mode $MODE"
    python3 "$WORK/sink.py" "$HP" "$HOUT" > "$LOGS/sink-smp$SMP.err" 2>&1 &
    SPID=$!
    cp "$WORK/S.img" "$WORK/S-$SMP.img"
    ring3_seed_boot "$WORK/S-$SMP.img" "$LOG" "kybernet: shell exited" "${QEMU_TIMEOUT:-420}" "$WORK" -smp "$SMP" \
        -netdev "user,id=n0" -device "virtio-net-pci,netdev=n0" ${SOCKW_QEMU_EXTRA:-}
    brc=$?
    kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
    if [ "$brc" -eq 2 ]; then echo "  VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "SOCKW-|kybernet: (exec|emergency|shell)" | sed 's/^/    /'
    sed 's/^/    host: /' "$HOUT"
    echo "  -- -smp $SMP verdicts --"
    want "kybernet: exec /bin/agnsh"          "[$SMP] kybernet launched the driver"
    want "SOCKW-CLOCK-OK"                     "[$SMP] N0 #95 clock"
    want "SOCKW-NETIP ip=[1-9]"               "[$SMP] N0 net_ip"
    if [ "$MODE" = "all" ]; then
        for V in LO IP; do
            want "SOCKW-CONNECT-FAST-$V us="  "[$SMP] N1 connect $V completes in the caller's own poll (<= 200 ms)"
            want "SOCKW-SEND-OK-$V bytes=16384" "[$SMP] N2 16 KB one-shot to a slow $V reader, byte-verified"
            want "SOCKW-SEND-FAST-$V"         "[$SMP] N2 the $V send took <= 4 s"
            want "SOCKW-SEND-YIELDS-$V share=" "[$SMP] N3 a $V sender blocked on a full window gives the CPU away (>= 800)"
            want "SOCKW-STALL-$V exit=0"      "[$SMP] N4 D6: the first #48 returns the committed count after 7-12 s ($V)"
            want "SOCKW-STALL-ONEFLIGHT-$V bytes=16384" "[$SMP] N4 the second #48 waits for the in-flight segment; stream exact ($V)"
            want "SOCKW-DIAL-DEADLINE-$V"     "[$SMP] N6 #47 to a silent $V port returns -1 in 7-12 s"
            want "SOCKW-CONNECT-YIELDS-$V share=" "[$SMP] N6 a $V dial gives the CPU away (>= 800)"
        done
        want "SOCKW-PERSIST-OK bytes=16384"   "[$SMP] N5 a reader stalled 55 s keeps its connection (persist cap)"
        want "SOCKW-PING-CONCURRENT ok=200/200" "[$SMP] N7 two concurrent pingers each get their own 100 replies"
        want "SOCKW-PING-SILENT-OK"           "[$SMP] N7 a silent host: -1 in 1.4-2.5 s for a 1.5 s bound"
        want "SOCKW-PING-YIELDS share="       "[$SMP] N7 a blocked pinger gives the CPU away (>= 800)"
        want "SOCKW-PING-BOUND us="           "[$SMP] N7 #100 with a 1 ms bound: -1 in 1-60 ms"
        want "SOCKW-DIAL-RST us="             "[$SMP] N9 nine dials to a closed host port: each -1 <= 500 ms (RST wakes #47)"
        want "SOCKW-SLOTS-OK"                 "[$SMP] N10 no slot leaks after the refused dials"
    fi
    want "SOCKW-WIRE-OK bytes=16384"          "[$SMP] N8 16 KB to the host sink"
    hwant "^HOST-SINK got=16384"              "[$SMP] N8 the host received 16384"
    want "SOCKW-WIRE-LAT-OK"                  "[$SMP] N8 send16k <= 4 s and median 64 B RTT < 50 ms"
    strings "$LOG" | grep -E "SOCKW-WIRE-LAT " | sed "s/^/  INFO: [$SMP] /"
    want "SOCKW-DONE"                         "[$SMP] SOCKW-DONE"
    want "SOCKW-EXIT 0"                       "[$SMP] SOCKW-EXIT 0"
    want "kybernet: shell exited"             "[$SMP] the driver exited 0 (kybernet saw it)"
    deny "SOCKW-FAIL|NOCONN|BAD-ROLE|NO-ROLE" "[$SMP] no SOCKW-FAIL"
    deny "fault: pid=|#GP|#PF|PANIC"          "[$SMP] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"              "[$SMP] no latched invariant"
    if [ "$(strings "$LOG" | grep -c 'kybernet: exec /bin/agnsh')" -gt 1 ]; then bad "[$SMP] the driver was launched twice"; fi
done

echo ""
echo "=== sock-wait-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
