#!/bin/bash
# epoll-smoke — agnos 1.57.17: epoll_wait#21 BLOCKS (a wq wait woken by every watched type), epoll_ctl#20 op 3 SET
# watches TCP conn / listener ids with EPOLLIN / EPOLLOUT / EPOLLRDHUP, 128 watches. Ring 3 end to end on a PLAIN
# kernel: tests/epoll seeded as /bin/agnsh (the driver) and /bin/epw (the signal phases' children), plus a host peer
# on the hostfwd'd guest port 8090 keyed on the driver's -ARM / -GO markers.
#
# Issue: docs/development/issues/archived/2026-10-31-tcp-send-keeps-one-segment-in-flight.md (fix 2 — OPERATOR RULING
# 2026-11-04: the readiness wait; the send window stays a later item). Phases (tests/epoll/epw.cyr has the detail):
#   CAP / SET  128 legacy watches, the 129th refused; the legacy poll ignores a junk a4; 128 records; op-3 refusals,
#              SET replaces the legacy entries with one, DEL, a timed max 0 / reserved bit refused.
#   TMO / POLL / TFD  a 200 ms wait with nothing ready -> 0 in [200, 300) ms; timeout 0 polls; a timerfd due in 1 s
#              ends a 3 s wait at ~1 s.
#   K1-K4      (children, each seen BLOCKED in #99 first) an unblocked unwatched signal -> -4 at once; a watched
#              signalfd -> 1 record; a sigprocmask-blocked signal does not end the wait; SIGKILL reaps a waiter.
#   L1 / R1 / O1 / H1 / H2  a listener's child, RX, nothing held (EPOLLOUT at once), the peer's FIN, a peer reset.
#   B1 / B2 / B3  a 512 KB send: #109 no-wait + one EPOLLOUT wait per segment (no wait may time out) vs #48 blocking
#              vs #109 + #44 (agora 1.13.2's shape); the host verifies the pattern and reports each rate.
#              GATED: B1 >= 0.4 x B2 in the same boot (measured 0.61 KVM -smp 4, 0.91 TCG -smp 1). B3 is reported
#              only (the issue's "before": at -smp 4 each #44 parks until a tick, ~136 KB/s).
#   S1         ONE process: client A never reads (#109 no-wait to it whenever EPOLLOUT says so), client B echoes
#              16-byte lines every 20 ms for 4 s: B's worst round trip < 1 s (its first, which carries the guest's
#              console write of the marker, reported apart) and the loop made < 20000 waits (it blocked: a poll loop
#              would make millions).
# Two boots, both GATED: -smp 1 (TCG) and -smp 4 (smoke_accel: KVM when /dev/kvm is writable, else tcg,thread=multi).
# Exit 0 only when every check of every boot passes; 2 when a boot never reached the kernel (firmware VOID).
# Env: EPW_SMP (default "1 4"), EPW_KERNEL (a prebuilt kernel: the falsification hook, skips the build — how the
#      mutants are run), QEMU_TIMEOUT (default 400).
# NEGATIVES (1.57.17, each red alone, source restored byte-identical — the issue file's Status records the runs):
#   M1 net_handle_tcp without `nht_e |= 1 << nht_t` (no epoll wake on the ACK / FIN / RST events) -> every B1 EPOLLOUT
#      wait runs to its 2 s deadline (slow > 0, 512 KB never sent), H1 / H2 return only at their 10 s timeouts;
#   M2 the data-queued bit dropped -> R1 returns only at its 10 s timeout;
#   M3 ep_sig_locked never waking -> K1 / K2 return only at their 3 s / 5 s timeouts.
# ⚠ A level-triggered wait re-scans at its deadline, so a LOST wake still answers rc 1 there: every wake gate bounds
#   the ELAPSED time, never only the return code.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== epoll smoke (a blocking epoll_wait#21: EPOLLOUT, TCP ids, signals, 128 watches) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/epoll-smoke"; LOGS="$ROOT/build/epoll-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

if [ -n "${EPW_KERNEL:-}" ]; then
    KERNEL="$EPW_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson), into this smoke's own WORK dir.
echo "Building tests/epoll/epw (--agnos)..."
( cd "$ROOT/tests/epoll" && cyrius build --agnos epw.cyr "$WORK/epw" ) > "$LOGS/epw-build.log" 2>&1 \
    || { echo "  ERROR: epw build failed (see $LOGS/epw-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$WORK/epw" "$SEED/bin/agnsh"
cp "$WORK/epw" "$SEED/bin/epw"
ring3_seed_image "$WORK/E.img" "$KERNEL" "$SEED" "AGNOS-EPOLL" || { echo "  ERROR: image"; exit 1; }

cat > "$WORK/helper.py" <<'PY'
# Host half of epoll-smoke: follows the serial log (offset reset whenever it SHRINKS — qemu_dwell truncates it on every
# VOID retry) and runs each phase's peer action when its marker line appears. Results go to the out file.
import os, socket, statistics, struct, sys, time
log, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
res = open(out, "a", buffering=1)
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(256))
st = {}
def conn(tmo=15.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=tmo)
    s.settimeout(tmo)
    return s
def l1():
    time.sleep(0.3); st["main"] = conn(); res.write("H L1 connected\n")
def r1():
    time.sleep(0.3); st["main"].sendall(b"x"); res.write("H R1 sent\n")
def h1():
    time.sleep(0.3); st["main"].shutdown(socket.SHUT_WR); res.write("H H1 fin\n")
def h2acc():
    try: st["main"].close()
    except Exception: pass
    st["c2"] = conn(); res.write("H H2 connected\n")
def h2():
    time.sleep(0.3)
    s = st["c2"]; s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close()
    res.write("H H2 reset\n")
def bulk(tag):
    got = 0; bad = 0; t0 = None; err = None
    try:
        s = conn(30.0); s.settimeout(60.0)
        while True:
            d = s.recv(65536)
            if not d: break
            if t0 is None: t0 = time.time()
            o = got % 256
            exp = (pat[o:] + pat * (len(d) // 256 + 2))[:len(d)]
            if d != exp: bad += sum(1 for a, b in zip(d, exp) if a != b)
            got += len(d)
        s.close()
    except Exception as e:
        err = str(e)
    dt = (time.time() - t0) if t0 else 0.0
    kbps = int(got / 1024.0 / dt) if dt > 0 else 0
    res.write("HOST-%s got=%d bad=%d ms=%d kbps=%d err=%s\n" % (tag, got, bad, int(dt * 1000), kbps, err))
def s1():
    a = socket.socket(); a.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048); a.settimeout(15.0)
    a.connect(("127.0.0.1", port)); a.sendall(b"A"); st["a"] = a
    res.write("H S1 A connected rcvbuf=%d (never read)\n" % a.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
def s1b():
    rtts = []; err = None
    try:
        b = conn(); b.settimeout(5.0)
        t_end = time.time() + 4.0; i = 0
        while time.time() < t_end:
            line = ("p%014d\n" % i).encode()
            t = time.time(); b.sendall(line); got = b""
            while len(got) < 16:
                d = b.recv(16 - len(got))
                if not d: raise Exception("eof")
                got += d
            rtts.append((time.time() - t) * 1000.0)
            if got != line: err = "mismatch"
            i += 1; time.sleep(0.02)
        b.sendall(b"Q" * 16)
        time.sleep(0.3); b.close()
    except Exception as e:
        err = str(e)
    # The FIRST round trip also carries the guest's console write of EPW-S1-GOT-A (~0.2 s on the framebuffer) and B's
    # accept: reported as first_ms; max_ms is the worst of the rest, the steady state the bystander lives in.
    first = rtts[0] if rtts else -1; rest = rtts[1:]
    mx = max(rest) if rest else -1; med = statistics.median(rest) if rest else -1
    res.write("HOST-S1 n=%d max_ms=%d med_ms=%.1f first_ms=%d err=%s\n" % (len(rtts), int(mx), med, int(first), err))
    try: st["a"].close()
    except Exception: pass
acts = [(b"EPW-L1-ARM\n", l1), (b"EPW-R1-ARM\n", r1), (b"EPW-H1-ARM\n", h1), (b"EPW-H2-ACC\n", h2acc),
        (b"EPW-H2-ARM\n", h2), (b"EPW-B1-GO\n", lambda: bulk("B1")), (b"EPW-B2-GO\n", lambda: bulk("B2")),
        (b"EPW-B3-GO\n", lambda: bulk("B3")), (b"EPW-S1-GO\n", s1), (b"EPW-S1-GOT-A\n", s1b)]
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
            done.add(i)
            try: fn()
            except Exception as e: res.write("helper: %s failed: %s\n" % (m.strip().decode(), e))
    if b"EPW-DONE" in buf: break
    time.sleep(0.05)
PY

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
hwant(){ if grep -qE -- "$1" "$HOUT"; then ok "$2"; else bad "$2 (host missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }
# The value of key K on the first guest line starting with TAG (empty if none).
gv()   { strings "$LOG" | grep -oE "$1( [a-z_0-9]+=-?[0-9]+)+" | head -1 | grep -oE " $2=-?[0-9]+" | head -1 | sed 's/.*=//'; }
hv()   { grep -E "^$1 " "$HOUT" | head -1 | grep -oE "(^| )$2=-?[0-9]+" | head -1 | sed 's/.*=//'; }
# range TAG KEY LO HI LABEL: LO <= value < HI (HI empty = no upper bound).
range() {
    local v; v="$(gv "$1" "$2")"
    if [ -z "$v" ]; then bad "$5 ($1 $2 missing)"; return; fi
    if [ "$v" -ge "$3" ] && { [ -z "$4" ] || [ "$v" -lt "$4" ]; }; then ok "$5 ($2=$v)"; else bad "$5 ($2=$v, want [$3, ${4:-inf}))"; fi
}
eqv()  { local v; v="$(gv "$1" "$2")"; if [ "$v" = "$3" ]; then ok "$4"; else bad "$4 ($1 $2=${v:-none}, want $3)"; fi; }

for SMP in ${EPW_SMP:-1 4}; do
    LOG="$LOGS/epw-smp$SMP.log"; HOUT="$LOGS/helper-smp$SMP.out"; : > "$LOG"; : > "$HOUT"
    R3_ACCEL="$(smoke_accel "$SMP")"; export R3_ACCEL
    HP="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    echo ""
    echo "Boot -smp $SMP  accel: $R3_ACCEL  host port $HP"
    python3 "$WORK/helper.py" "$LOG" "$HP" "$HOUT" > "$LOGS/helper-smp$SMP.err" 2>&1 &
    HPID=$!
    cp "$WORK/E.img" "$WORK/E-$SMP.img"
    ring3_seed_boot "$WORK/E-$SMP.img" "$LOG" "EPW-DONE" "${QEMU_TIMEOUT:-400}" "$WORK" -smp "$SMP" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HP-:8090" -device "virtio-net-pci,netdev=n0"
    brc=$?
    kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
    if [ "$brc" -eq 2 ]; then echo "  VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "EPW-|kybernet: (exec|emergency|shell)" | sed 's/^/    /'
    sed 's/^/    host: /' "$HOUT"
    echo "  -- -smp $SMP verdicts --"
    want "kybernet: exec /bin/agnsh"           "[$SMP] kybernet launched the driver"
    want "EPW-START netip=[1-9]"              "[$SMP] net_ip configured"
    want "EPW-CAP-OK"                         "[$SMP] CAP: 128 watches, the 129th refused; the legacy poll ignores a4; 128 records (legacy + timed)"
    want "EPW-SET-OK"                         "[$SMP] SET: refusals, SET replaces 128 legacy entries with one, DEL, bad max / bits"
    eqv   EPW-TMO rc 0                          "[$SMP] TMO: a 200 ms wait with nothing ready returns 0"
    range EPW-TMO us 200000 300000              "[$SMP] TMO: ... after >= 200 ms and < 300 ms"
    eqv   EPW-POLL rc 0                         "[$SMP] POLL: timeout 0 returns 0"
    range EPW-POLL us 0 20000                   "[$SMP] POLL: ... at once"
    eqv   EPW-TFD rc 1                          "[$SMP] TFD: a timerfd due in 1 s ends a 3 s wait"
    range EPW-TFD us 900000 1600000             "[$SMP] TFD: ... at ~1 s (its deadline is the only wake)"
    for K in 1 2 3; do eqv EPW-KP$K blocked 1   "[$SMP] K$K: the child was BLOCKED (#99 state 6) before the signal"; done
    eqv   EPW-K1 rc -4                          "[$SMP] K1: an unblocked, unwatched signal ends the wait with -4"
    range EPW-K1 us 0 1000000                   "[$SMP] K1: ... promptly (timeout 3 s)"
    eqv   EPW-K2 rc 1                           "[$SMP] K2: a watched signalfd's signal ends the wait with its record"
    eqv   EPW-K2 dataok 1                       "[$SMP] K2: ... the record names the signalfd"
    range EPW-K2 us 0 1000000                   "[$SMP] K2: ... promptly (timeout 5 s)"
    eqv   EPW-K3 rc 0                           "[$SMP] K3: a sigprocmask-blocked signal does NOT end the wait"
    range EPW-K3 us 600000 ""                   "[$SMP] K3: ... it runs to its 600 ms timeout"
    eqv   EPW-KP4 blocked 1                     "[$SMP] K4: a -1 (forever) waiter is BLOCKED (state 6: it parked, no spin)"
    eqv   EPW-KP4 status 265                    "[$SMP] K4: SIGKILL ends it (status 265)"
    range EPW-KP4 reap_us 0 1000000             "[$SMP] K4: ... and it is reaped promptly"
    deny  "EPW-K4 rc="                            "[$SMP] K4: the killed waiter never returned to ring 3"
    eqv   EPW-L1 set 0                          "[$SMP] L1: op-3 SET on the caller's listener id"
    eqv   EPW-L1 rc 1                           "[$SMP] L1: a listener's child wakes the wait"
    eqv   EPW-L1 ev 1                           "[$SMP] L1: ... EPOLLIN"
    eqv   EPW-L1 dataok 1                       "[$SMP] L1: ... the record names EP_TCP | listen id"
    range EPW-L1 us 250000 5000000              "[$SMP] L1: ... after the host's 300 ms delay (it waited), well before its 10 s timeout"
    eqv   EPW-R1 rc 1                           "[$SMP] R1: RX wakes the wait"
    eqv   EPW-R1 ev 1                           "[$SMP] R1: ... EPOLLIN"
    eqv   EPW-R1 n 1                            "[$SMP] R1: ... and #49 reads the byte"
    range EPW-R1 us 250000 5000000              "[$SMP] R1: ... after the host's 300 ms delay (it waited), well before its 10 s timeout"
    eqv   EPW-O1 rc 1                           "[$SMP] O1: nothing held: EPOLLOUT"
    eqv   EPW-O1 ev 4                           "[$SMP] O1: ... mask EPOLLOUT"
    range EPW-O1 us 0 50000                     "[$SMP] O1: ... at once"
    eqv   EPW-H1 rc 1                           "[$SMP] H1: the peer's FIN wakes the wait"
    eqv   EPW-H1 ev 8193                        "[$SMP] H1: ... EPOLLIN | EPOLLRDHUP"
    eqv   EPW-H1 eof -1                         "[$SMP] H1: ... and #49 answers EOF"
    range EPW-H1 us 250000 5000000              "[$SMP] H1: ... woken by the FIN, well before its 10 s timeout"
    eqv   EPW-H2 rc 1                           "[$SMP] H2: a peer reset wakes a wait with no interest bit"
    range EPW-H2 us 250000 5000000              "[$SMP] H2: ... woken by the reset, well before its 10 s timeout"
    H2EV="$(gv EPW-H2 ev)"
    if [ -n "$H2EV" ] && [ $((H2EV & 24)) -eq 24 ]; then ok "[$SMP] H2: ... EPOLLERR | EPOLLHUP (ev=$H2EV)"; else bad "[$SMP] H2: ... EPOLLERR | EPOLLHUP (ev=${H2EV:-none})"; fi
    for B in 1 2 3; do
        eqv   EPW-B$B bytes 524288              "[$SMP] B$B: 512 KB committed"
        hwant "^HOST-B$B got=524288 bad=0 "     "[$SMP] B$B: the host received 512 KB, pattern-exact"
    done
    eqv   EPW-B1 slow 0                         "[$SMP] B1: no EPOLLOUT wait ran to its 2 s deadline (each was woken by the ACK)"
    R1K="$(hv HOST-B1 kbps)"; R2K="$(hv HOST-B2 kbps)"; R3K="$(hv HOST-B3 kbps)"
    echo "  INFO: [$SMP] rates KB/s: B1 #109+EPOLLOUT=${R1K:-?}  B2 #48=${R2K:-?}  B3 #109+#44=${R3K:-?}"
    if [ -n "$R1K" ] && [ -n "$R2K" ] && [ "$R2K" -gt 0 ] && [ $((R1K * 5)) -ge $((R2K * 2)) ]; then ok "[$SMP] B1 >= 0.4 x B2 ($R1K vs $R2K KB/s)"
    else bad "[$SMP] B1 >= 0.4 x B2 (B1=${R1K:-none} B2=${R2K:-none} KB/s)"; fi
    eqv   EPW-S1 done 1                         "[$SMP] S1: the bystander's Q ended the loop"
    range EPW-S1 waits 1 20000                  "[$SMP] S1: < 20000 waits in the window (the loop blocked)"
    range EPW-S1 a_bytes 1 ""                   "[$SMP] S1: A was sent bytes while it read nothing"
    hwant "^HOST-S1 n=[0-9]+ max_ms=[0-9]+ med_ms=[0-9.]+ first_ms=-?[0-9]+ err=None" "[$SMP] S1: the bystander's echoes were all exact"
    HN="$(hv HOST-S1 n)"; HM="$(hv HOST-S1 max_ms)"; HF="$(hv HOST-S1 first_ms)"
    if [ -n "$HN" ] && [ "$HN" -ge 50 ]; then ok "[$SMP] S1: >= 50 bystander round trips (n=$HN)"; else bad "[$SMP] S1: >= 50 bystander round trips (n=${HN:-none})"; fi
    if [ -n "$HM" ] && [ "$HM" -lt 1000 ]; then ok "[$SMP] S1: the bystander's worst echo < 1 s (${HM} ms) beside a client that reads nothing"
    else bad "[$SMP] S1: the bystander's worst echo < 1 s (max_ms=${HM:-none})"; fi
    if [ -n "$HF" ] && [ "$HF" -lt 1000 ]; then ok "[$SMP] S1: ... its first echo too (${HF} ms, the guest's console write included)"
    else bad "[$SMP] S1: ... its first echo too (first_ms=${HF:-none})"; fi
    grep -E "^HOST-S1 " "$HOUT" | sed "s/^/  INFO: [$SMP] /"
    strings "$LOG" | grep -oE "EPW-S1 waits=.*" | sed "s/^/  INFO: [$SMP] /"
    want "EPW-DONE"                           "[$SMP] EPW-DONE"
    deny "EPW-FAIL|EPW-BAD-ROLE|EPW-NO-ROLE|EPW-NONET" "[$SMP] no EPW-FAIL marker"
    deny "fault: pid=|#GP|#PF|PANIC"           "[$SMP] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"               "[$SMP] no latched invariant"
    deny "kybernet: emergency"                 "[$SMP] the driver exited 0 (no emergency shell)"
done

echo ""
echo "=== epoll-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
