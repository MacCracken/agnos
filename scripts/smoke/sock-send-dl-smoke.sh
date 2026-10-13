#!/bin/bash
# sock-send-dl-smoke — agnos 1.57.13: sock_send_dl#109, sock_send#48 with a CALLER CEILING, ring 3 end to end on a
# PLAIN kernel: tests/sockwait seeded as /bin/agnsh (the driver, mode "t") and /bin/sockw (every child role), plus a
# host peer on 127.0.0.1:SP (reached as 10.0.2.2) that STOPS READING (a tiny SO_RCVBUF).
#
# Issue: docs/development/issues/archived/2026-10-02-sock-send-ignores-the-caller-deadline.md — #48 waits up to ~8 s
# for ACK progress with no caller bound, so a cyrius TLS write overshot its deadline by up to one D6 window.
# The pattern is sock-wait-smoke's (#100's bound was proven there: N7 SOCKW-PING-BOUND); the phases are its N11-N13
# (tests/sockwait/sockw.cyr has the detail):
#   N11 a local reader that reads nothing for 24 s (its 2 KB ring fills: a zero window), LO and IP:
#       c1 300 ms ceiling -> the committed count in [295 ms, 1.5 s]; c2 (c1's probe in flight) -> 0 in the same band;
#       c3 a negative ceiling -> 0 with no wait; c4 ceiling 0 = #48 -> [7 s, 12 s]; c5 a ceiling ABOVE the D6 window
#       (LO 20 s, IP INT64_MAX = the 2^40 clamp) -> D6 still applies under it: [7 s, 12 s], the reader draining ~15 s
#       after c5 starts; then the stream is byte-exact.
#                                                         SOCKW-DL-BOUND-{LO,IP}, -DL-ZERO-IS-48-{LO,IP},
#                                                         SOCKW-DL-OVER-D6-{LO,IP}, -DL-STREAM-{LO,IP}
#   N11t the ceiling is measured ONCE from entry: a reader taking 512 B every ~50 ms (ACK progress well inside every
#       300 ms) cannot stretch a 300 ms #109 — it returns a partial count in [295 ms, 1.5 s]; the stream stays exact.
#                                                         SOCKW-DL-TRICKLE-{LO,IP}
#   N12 #109 on a conn the caller does not own is -1 (bounded, unbounded, len 0) and sends nothing; the owner's works.
#                                                         SOCKW-DL-FOREIGN-REFUSED
#   N13 the wire: push 8 KB #109s until one comes back short (SLIRP's and the host's buffers full, window 0); a
#       300 ms ceiling returns in [295 ms, 1.5 s]; ceiling 0 waits the D6 window (>= 7 s); after a GO dial the peer
#       drains and receives EXACTLY the committed total, pattern-verified.
#                                                         SOCKW-DLW-BOUND, -DLW-ZERO-IS-48, -DLW-DRAINED + HOST-STALL got=
# Two boots, both GATED: -smp 1 (TCG) and -smp 4 (smoke_accel: KVM when /dev/kvm is writable, else tcg,thread=multi).
# Exit 0 only when every check of every boot passes; 2 when a boot never reached the kernel (firmware VOID).
# Env: DL_SMP (default "1 4"), DL_KERNEL (a prebuilt kernel: the falsification hook, skips the build — how the
#      mutants are run), QEMU_TIMEOUT (default 420).
# NEGATIVES (1.57.13, each red, source restored byte-identical): the #109 arm passing 0 for the ceiling (the bound
# ignored: c1 and W1 return after ~8 s) -> DL-BOUND-* and DLW-BOUND red; the arm without tcp_auth and acting as the
# conn's own tag (a foreign conn_id accepted) -> DL-FOREIGN-REFUSED red; tcp_send_dl re-arming the ceiling on every ACK
# (the issue's per-progress sketch: se_prog = min(timeout_us, 8 s), no cap) -> DL-TRICKLE-* red; tcp_send_dl passing
# TCP_SEND_DL_MAX_US as se_prog (D6 dropped whenever a ceiling is set) -> c5 waits for the drain, DL-OVER-D6-* red.
# D6 SITE 2 (the ACK-progress clamp — a partial ACK, then a stall) is NOT reachable from here: an agnos or SLIRP
# receiver never takes part of a segment (each chunk is capped at the advertised window, which only opens). It is
# gated hermetically by tcp-smoke.sh's `tcp: dlpart` arm (TCP_SELFTEST), whose negative is that site unclamped.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== sock-send-dl smoke (sock_send_dl#109: a caller ceiling on #48) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/sock-send-dl"; LOGS="$ROOT/build/sock-send-dl-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

if [ -n "${DL_KERNEL:-}" ]; then
    KERNEL="$DL_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson). Into this smoke's own WORK dir, not
# tests/sockwait/build/: the sock-wait row builds that path.
echo "Building tests/sockwait/sockw (--agnos)..."
( cd "$ROOT/tests/sockwait" && cyrius build --agnos sockw.cyr "$WORK/sockw" ) > "$LOGS/sockw-build.log" 2>&1 \
    || { echo "  ERROR: sockw build failed (see $LOGS/sockw-build.log)"; exit 1; }

# SP: the host stall peer's port (bound again with SO_REUSEADDR by each boot's peer, as sock-wait's sink is).
SP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/sw"
cp "$WORK/sockw" "$SEED/bin/agnsh"
cp "$WORK/sockw" "$SEED/bin/sockw"
printf '%s' "t" > "$SEED/sw/mode"
printf '%s' "$SP" > "$SEED/sw/stallport"
ring3_seed_image "$WORK/S.img" "$KERNEL" "$SEED" "AGNOS-SOCKDL" || { echo "  ERROR: image"; exit 1; }

cat > "$WORK/stall.py" <<'PY'
# Host peer for N13: the FIRST connection is never read (SO_RCVBUF set tiny before listen, so the accepted socket's
# window closes fast); the SECOND connection is the guest's GO — then drain the first to EOF, verifying the pattern
# s_pat(i) = (i * 7 + 3) & 0xFF, and report HOST-STALL got=<n> bad=<mismatches>.
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
res = open(out, "a", buffering=1)
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(256))
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
srv.bind(("127.0.0.1", port)); srv.listen(4)
stall, _ = srv.accept()
res.write("HOST-STALL accepted rcvbuf=%d\n" % stall.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
go, _ = srv.accept()
go.close()
res.write("HOST-STALL go\n")
stall.settimeout(120)
got = 0; bad = 0
try:
    while True:
        d = stall.recv(65536)
        if not d: break
        o = got % 256
        exp = (pat[o:] + pat * (len(d) // 256 + 2))[:len(d)]
        if d != exp:
            bad += sum(1 for a, b in zip(d, exp) if a != b)
        got += len(d)
except Exception as e:
    res.write("HOST-STALL error %s\n" % e)
res.write("HOST-STALL got=%d bad=%d\n" % (got, bad))
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for SMP in ${DL_SMP:-1 4}; do
    LOG="$LOGS/sockdl-smp$SMP.log"; HOUT="$LOGS/stall-smp$SMP.out"; : > "$LOG"; : > "$HOUT"
    R3_ACCEL="$(smoke_accel "$SMP")"; export R3_ACCEL
    echo ""
    echo "Boot -smp $SMP  accel: $R3_ACCEL  host stall peer $SP"
    python3 "$WORK/stall.py" "$SP" "$HOUT" > "$LOGS/stall-smp$SMP.err" 2>&1 &
    PEER=$!
    cp "$WORK/S.img" "$WORK/S-$SMP.img"
    ring3_seed_boot "$WORK/S-$SMP.img" "$LOG" "kybernet: shell exited" "${QEMU_TIMEOUT:-420}" "$WORK" -smp "$SMP" \
        -netdev "user,id=n0" -device "virtio-net-pci,netdev=n0"
    brc=$?
    # The peer writes its count at EOF; give it up to 10 s after the boot, then stop it.
    w=0; while [ $w -lt 20 ] && ! grep -q "^HOST-STALL got=" "$HOUT" 2>/dev/null; do sleep 0.5; w=$((w + 1)); done
    kill "$PEER" 2>/dev/null; wait "$PEER" 2>/dev/null
    if [ "$brc" -eq 2 ]; then echo "  VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "SOCKW-|kybernet: (exec|emergency|shell)" | sed 's/^/    /'
    sed 's/^/    host: /' "$HOUT"
    echo "  -- -smp $SMP verdicts --"
    want "kybernet: exec /bin/agnsh"          "[$SMP] kybernet launched the driver"
    want "SOCKW-CLOCK-OK"                     "[$SMP] N0 #95 clock"
    want "SOCKW-NETIP ip=[1-9]"               "[$SMP] N0 net_ip"
    for V in LO IP; do
        want "SOCKW-DL-BOUND-$V exit=0"       "[$SMP] N11 $V: a 300 ms ceiling returns the committed count in [295 ms, 1.5 s] (fresh conn, and with a segment in flight); a negative one does not wait"
        want "SOCKW-DL-ZERO-IS-48-$V"         "[$SMP] N11 $V: ceiling 0 is #48 (the D6 window, 7-12 s)"
        want "SOCKW-DL-OVER-D6-$V"            "[$SMP] N11 $V: a ceiling above the D6 window (LO 20 s, IP INT64_MAX) still returns at D6 (7-12 s)"
        want "SOCKW-DL-STREAM-$V bytes=16384" "[$SMP] N11 $V: the stream is byte-exact across the six calls"
        want "SOCKW-DL-TRICKLE-$V bytes=16384" "[$SMP] N11t $V: a reader ACKing every ~50 ms cannot stretch a 300 ms ceiling (measured once from entry); stream exact"
    done
    want "SOCKW-DL-FOREIGN-REFUSED"           "[$SMP] N12 #109 on a conn the caller does not own: -1, nothing sent"
    want "SOCKW-DLW-BOUND us="                "[$SMP] N13 wire: a 300 ms ceiling against a host peer that stopped reading returns in [295 ms, 1.5 s]"
    want "SOCKW-DLW-ZERO-IS-48 us="           "[$SMP] N13 wire: ceiling 0 waits the D6 window (>= 7 s)"
    want "SOCKW-DLW-DRAINED total="           "[$SMP] N13 wire: after GO every committed byte is ACKed"
    GT="$(strings "$LOG" | grep -oE 'SOCKW-DLW total=[0-9]+' | head -1 | sed 's/.*=//')"
    HG="$(grep -oE '^HOST-STALL got=[0-9]+ bad=[0-9]+' "$HOUT" | head -1)"
    if [ -n "$GT" ] && [ "$HG" = "HOST-STALL got=$GT bad=0" ]; then ok "[$SMP] N13 the host received exactly the committed total ($GT), pattern-verified"
    else bad "[$SMP] N13 the host received exactly the committed total (guest total=${GT:-none}, host: ${HG:-none})"; fi
    want "SOCKW-DONE"                         "[$SMP] SOCKW-DONE"
    want "SOCKW-EXIT 0"                       "[$SMP] SOCKW-EXIT 0"
    want "kybernet: shell exited"             "[$SMP] the driver exited 0 (kybernet saw it)"
    deny "SOCKW-FAIL|NOCONN|BAD-ROLE|NO-ROLE" "[$SMP] no SOCKW-FAIL"
    deny "fault: pid=|#GP|#PF|PANIC"          "[$SMP] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"              "[$SMP] no latched invariant"
    if [ "$(strings "$LOG" | grep -c 'kybernet: exec /bin/agnsh')" -gt 1 ]; then bad "[$SMP] the driver was launched twice"; fi
done

echo ""
echo "=== sock-send-dl-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
