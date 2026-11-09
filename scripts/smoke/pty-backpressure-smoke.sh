#!/bin/sh
# pty-backpressure-smoke.sh — 1.57.18: BACK-PRESSURE on a terminal channel (write#1 on a `#97` PTY-mode endpoint, or on
# the emulator's end of one, waits for room instead of dropping the oldest record), epoll_wait#21 WATCHING `#97` channel
# endpoints (EPOLLIN / EPOLLOUT / EPOLLHUP, authority re-derived), and sock_connect#47's CALLER DEADLINE (SC_TIMED, a3 bit
# 32; a4 = ms; a4 0 = non-blocking), from ring 3.
# Issues 2026-11-06-a-channel-write-drops-the-oldest-record-and-nobody-is-told, 2026-11-06-no-readiness-wait-on-one-fd
# (thoth 0.55.x).
#
# tests/chan/ptybp.cyr is seeded as /bin/agnsh (the driver — it plays the terminal emulator — AND every child role,
# spawned by #43). Phases (the program's header has the details): big (the issue's 20,000-byte reply arrives whole, the
# writer seen BLOCKED) · nb-emulator / nb-terminal (a4 != 0 takes what fits: 4096, then 0; -1 after the peer died) ·
# death-none / death-partial (a reader's death wakes a blocked writer: -1 / 64, before the 100 ms backstop) · kill
# (SIGKILL of a blocked writer: 265 in < 50 ms) · stop-cont (a stopped writer stays stopped through a drain; SIGCONT
# finishes the write) · display-drop / send-drop (a display channel and CH_SEND keep drop-oldest) · two-writer (the
# terminal's owner and its grandchild: 400 records, none lost, torn or reordered) · ep-timeout / ep-in / ep-out / ep-hup /
# ep-display-out / ep-in-term / ep-inert (epoll on a channel) · conn-1500 / conn-3000 / conn-noflag / conn-clamp /
# conn-nb-hole / conn-slots / conn-loop / conn-nb-loop / conn-nb-rst (#47 SC_TIMED).
# PLAIN kernel. Boots -smp 1 THEN -smp 4, BOTH GATED; the -smp 4 boot takes smoke_accel's accelerator (KVM when
# /dev/kvm is writable, else multi-threaded TCG — printed). No NIC is needed: the #47 deadline phases dial a SILENT
# LOOPBACK peer (sock-wait N6's full-table fixture: a passive open refused for capacity drops every SYN), so they do not
# depend on the build host's network or routes (slirp restrict=on was measured to RESET such a SYN, and an empty hub
# never sends it — no gateway MAC). Per boot it REQUIRES every phase's `PTYB-OK <phase>`,
# `PTYB-DONE ... fail=0`, `PTYB-EXIT 0` and `kybernet: shell exited`, and DENIES `PTYB-FAIL`, `fault: pid=`, `#GP`,
# `#PF`, `PANIC` and the shared SMOKE_INVARIANT_DENY. Every boot is banner-gated (no "AGNOS kernel v" = VOID, re-run by
# ring3_seed_boot's retry, never scored).
# Env: PTYBP_KERNEL=<prebuilt kernel> (a control / mutation run), PTYBP_SMP (default "1 4"), QEMU_TIMEOUT (default 300).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== pty-backpressure smoke (terminal write#1 back-pressure, epoll_wait#21 on #97 channels, #47 SC_TIMED) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/pty-backpressure"; LOGS="$ROOT/build/pty-backpressure-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/chan/ptybp (--agnos)..."
( cd "$ROOT/tests/chan" && cyrius build --agnos ptybp.cyr build/ptybp ) > "$LOGS/ptybp-build.log" 2>&1 \
    || { echo "  ERROR: ptybp build failed (see $LOGS/ptybp-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/chan/build/ptybp" "$SEED/bin/agnsh"

if [ -n "${PTYBP_KERNEL:-}" ]; then
    KERNEL="$PTYBP_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (a control run)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
ring3_seed_image "$WORK/I.img" "$KERNEL" "$SEED" "AGNOS-PTYBP" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for smp in ${PTYBP_SMP:-1 4}; do
    LOG="$LOGS/ptybp-smp$smp.log"
    if [ "$smp" -gt 1 ]; then R3_ACCEL="$(smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
    export R3_ACCEL
    echo ""
    echo "Boot -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/I.img" "$WORK/I-$smp.img"
    ring3_seed_boot "$WORK/I-$smp.img" "$LOG" "PTYB-EXIT 0" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "PTYB|kybernet: (exec|shell|emergency)" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    want "PTYB-OK big "            "[smp$smp] big: a 20,000-byte write#1 from inside the terminal arrives whole and in order at a slow host; the writer was seen BLOCKED (state 6) after 200 ms, its write returned 20000, and each drain woke it (< 350 ms)"
    want "PTYB-OK nb-emulator "    "[smp$smp] nb-emulator: a4 != 0 from the emulator's end: 5000 -> 4096, 10 -> 0 on a full inbox; -1 (NB and blocking) once the terminal's owner died"
    want "PTYB-OK nb-terminal "    "[smp$smp] nb-terminal: a4 != 0 from inside the terminal: 5000 -> 4096, 10 -> 0; the host reads exactly 4096 bytes in order"
    want "PTYB-OK death-none "     "[smp$smp] death-none: a blocking write on a full inbox returns -1 (nothing taken) < 90 ms after the reader's death"
    want "PTYB-OK death-partial "  "[smp$smp] death-partial: a blocking 200-byte write that took one record returns 64 < 90 ms after the reader's death"
    want "PTYB-OK kill "           "[smp$smp] kill: SIGKILL of a writer BLOCKED on a full inbox — WAIT_BLOCK 265 in < 50 ms"
    want "PTYB-OK stop-cont "      "[smp$smp] stop-cont: a STOPPED blocked writer stays stopped through a full drain (no record); SIGCONT finishes its 8192 bytes in order"
    want "PTYB-OK display-drop "   "[smp$smp] display-drop: a DISPLAY channel keeps drop-oldest — a child's 100 x 8 B write#1 (a4 0) return 8 at once, the newest 64 arrive (seq 36..99)"
    want "PTYB-OK ep-display-out " "[smp$smp] ep-display-out: a 200-byte write#1 on an unendowed channel is a 64-byte short write; over a FULL peer inbox it is still EPOLLOUT"
    want "PTYB-OK send-drop "      "[smp$smp] send-drop: CH_SEND on a TERMINAL channel keeps drop-oldest — the program reads the newest 64 (seq 36)"
    want "PTYB-OK two-writer "     "[smp$smp] two-writer: the terminal's owner and its grandchild each write 200 x 64 B blocking: 400 records, none lost, torn or reordered"
    want "PTYB-OK ep-timeout "     "[smp$smp] ep-timeout: EPW_TIMED 300 ms on an empty channel end returns 0 in [300, 350) ms"
    want "PTYB-OK ep-in "          "[smp$smp] ep-in: a record queued 50 ms into a 5 s wait ends it: 1, EPOLLIN, data = the fd, < 1 s"
    want "PTYB-OK ep-out "         "[smp$smp] ep-out: a FULL terminal inbox polls not-writable; one record read 50 ms into a 5 s wait ends it with EPOLLOUT < 1 s"
    want "PTYB-OK ep-hup "         "[smp$smp] ep-hup: the peer's CH_CLOSE 50 ms into a 5 s EPOLLIN wait ends it with EPOLLIN | EPOLLHUP < 1 s (a close: no SIGCHLD to wake it instead)"
    want "PTYB-OK ep-in-term "     "[smp$smp] ep-in-term: the program in the terminal watches its fd 0 (a PTY-mode end): the host's write ends its 5 s wait < 1 s"
    want "PTYB-OK ep-inert "       "[smp$smp] ep-inert: SET on an inherited inert claim is -1; a legacy ADD of one reports nothing; the owner's SET + poll of the same end reports it"
    want "PTYB-FIXTURE up=1 free_all=8 free_fixture=2" "[smp$smp] the silent-peer fixture is up as asserted (8 slots, 2 left free)"
    want "PTYB-OK conn-1500 "      "[smp$smp] conn-1500: #47 SC_TIMED 1500 ms to a silent peer returns -1 within [deadline, deadline + 25 ms)"
    want "PTYB-OK conn-3000 "      "[smp$smp] conn-3000: #47 SC_TIMED 3000 ms to a silent peer returns -1 within [deadline, deadline + 25 ms)"
    want "PTYB-OK conn-noflag "    "[smp$smp] conn-noflag: without SC_TIMED (a3 = -1, bit 32 set) a4 is not read — the ~8 s ceiling (7-12 s)"
    want "PTYB-OK conn-clamp "     "[smp$smp] conn-clamp: SC_TIMED 20000 ms is clamped to the ~8 s ceiling"
    want "PTYB-OK conn-nb-hole "   "[smp$smp] conn-nb-hole: SC_TIMED a4 0 returns the id at once; no EPOLLOUT in 500 ms to a silent peer; #50 closes it"
    want "PTYB-OK conn-slots "     "[smp$smp] conn-slots: the TCP table's free slots are unchanged after the spent deadlines (no half-open left)"
    want "PTYB-OK conn-loop "      "[smp$smp] conn-loop: SC_TIMED 1000 ms connects on loopback; a3 0x10000 and -1 without the bit still auto-assign a port"
    want "PTYB-OK conn-nb-loop "   "[smp$smp] conn-nb-loop: SC_TIMED a4 0 to a loopback listener returns the id at once and EPOLLOUT reports it connected"
    want "PTYB-OK conn-nb-rst "    "[smp$smp] conn-nb-rst: SC_TIMED a4 0 to a closed loopback port returns the id at once; EPOLLERR | EPOLLHUP (no EPOLLOUT) reports the refusal; #50 frees the slot"
    if strings "$LOG" | grep -qE "PTYB-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] PTYB-DONE with fail=0"; else bad "[smp$smp] PTYB-DONE with fail=0 (missing or fail > 0)"; fi
    want "PTYB-EXIT 0"             "[smp$smp] the driver ran to its end and exits 0"
    want "kybernet: shell exited"  "[smp$smp] kybernet saw /bin/agnsh (the driver) exit"
    deny "PTYB-FAIL"               "[smp$smp] no PTYB-FAIL line"
    deny "fault: pid=|#GP|#PF|PANIC" "[smp$smp] no fault, #GP/#PF or PANIC line"
    deny "$SMOKE_INVARIANT_DENY"   "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
done

[ -z "${PTYBP_KERNEL:-}" ] || sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo ""
echo "=== pty-backpressure-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "pty-backpressure-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "pty-backpressure-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "pty-backpressure-smoke: PASS"
exit 0
