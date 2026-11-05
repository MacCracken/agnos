#!/bin/sh
# pty-winsize-smoke.sh — 1.57.17: a terminal channel's window size, `#97 chan_op` CH_WINSZ_SET (0x06) / CH_WINSZ_GET
# (0x07), and SIGWINCH (28) to the terminal's WATCHING HOLDERS on a resize, from ring 3.
# Issue 2026-10-30-a-terminal-channel-has-no-window-size (puka / darshana / bannermanor).
#
# tests/chan/ptyws.cyr is seeded as /bin/agnsh (the driver — it plays the terminal emulator — AND every child role,
# spawned by #43). Phases (the program's header has the details): caps — bits 6 and 7 advertised · not-terminal — GET
# is -1 on out-of-range, console, pipe, closed fds and on a fresh channel's own ends, SET refuses a pipe and a 0
# dimension, a pre-endowment SET sizes the far end · display — a DISPLAY endowment reads -1 although sized, and SET
# from either side of it is refused · pty-get-* — a PTY endowment reads -1 before any SET, then 100x30 / 800x480 px on
# fd 0, 1 and 2 (owner) and from a grandchild (a PTY descendant); SET from inside the terminal is refused and changes
# nothing; the emulator's own copy of the endowed end reads -1; SET after the owner's death is PEERGONE · winch-* —
# five resizes (same, change, same, pixels only, change): the watching holder sees 0,1,0,1,1 SIGWINCH records, a
# non-watching holder and a non-holding watcher (inert inherited copies) see none · winch-epoll-* (the 1.57.17 merge
# with the blocking epoll_wait#21) — a watching holder BLOCKED in a timed epoll_wait on its bit-28 signalfd sleeps
# through an unchanged-size SET to its 300 ms deadline, and a changed-size SET ends its 5 s wait in < 1 s with the
# signalfd's EPOLLIN record · recycled — a re-minted terminal reads -1 before any SET.
# PLAIN kernel. Boots -smp 1 THEN -smp 4, BOTH GATED; the -smp 4 boot takes smoke_accel's accelerator (KVM when
# /dev/kvm is writable, else multi-threaded TCG — printed). Per boot it REQUIRES every phase's `PTYW-OK <phase>`,
# `PTYW-DONE ... fail=0`, `PTYW-EXIT 0` and `kybernet: shell exited`, and DENIES `PTYW-FAIL`, `fault: pid=`, `#GP`,
# `#PF`, `PANIC` and the shared SMOKE_INVARIANT_DENY. Every boot is banner-gated (no "AGNOS kernel v" = VOID, re-run by
# ring3_seed_boot's retry, never scored).
# Env: PTYWS_KERNEL=<prebuilt kernel> (a control / mutation run), PTYWS_SMP (default "1 4"), QEMU_TIMEOUT (default 180).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== pty-winsize smoke (#97 CH_WINSZ_SET / CH_WINSZ_GET on a terminal channel, SIGWINCH to its watching holders) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/pty-winsize"; LOGS="$ROOT/build/pty-winsize-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/chan/ptyws (--agnos)..."
( cd "$ROOT/tests/chan" && cyrius build --agnos ptyws.cyr build/ptyws ) > "$LOGS/ptyws-build.log" 2>&1 \
    || { echo "  ERROR: ptyws build failed (see $LOGS/ptyws-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/chan/build/ptyws" "$SEED/bin/agnsh"

if [ -n "${PTYWS_KERNEL:-}" ]; then
    KERNEL="$PTYWS_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (a control run)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
ring3_seed_image "$WORK/I.img" "$KERNEL" "$SEED" "AGNOS-PTYWS" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for smp in ${PTYWS_SMP:-1 4}; do
    LOG="$LOGS/ptyws-smp$smp.log"
    if [ "$smp" -gt 1 ]; then R3_ACCEL="$(smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
    export R3_ACCEL
    echo ""
    echo "Boot -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/I.img" "$WORK/I-$smp.img"
    ring3_seed_boot "$WORK/I-$smp.img" "$LOG" "PTYW-EXIT 0" "${QEMU_TIMEOUT:-180}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "PTYW|kybernet: (exec|shell|emergency)" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    want "PTYW-OK caps "                     "[smp$smp] caps: CH_CAPS advertises CH_WINSZ_SET (bit 6) and CH_WINSZ_GET (bit 7)"
    want "PTYW-OK not-terminal "             "[smp$smp] not-terminal: GET -1 on fd -1/32, the console, a pipe, a closed fd, a fresh channel's own ends; SET refuses a pipe and a 0 dimension; a pre-endowment SET sizes the far end, which still reads -1; selector 2 is -6"
    want "PTYW-OK display "                  "[smp$smp] display: a DISPLAY endowment reads -1 although sized; SET from the client and (after the endowment) from the driver is -5"
    want "PTYW-OK pty-get-before-set "       "[smp$smp] pty-get-before-set: a PTY endowment reads -1 before any SET"
    want "PTYW-OK pty-get-owner "            "[smp$smp] pty-get-owner: after SET 100x30 (800x480 px) the owner reads (100<<16)|30 on fd 0, 1, 2 and (800<<16)|480 with selector 1"
    want "PTYW-OK pty-get-descendant "       "[smp$smp] pty-get-descendant: a grandchild (a PTY descendant) reads the same size and its SET is -5"
    want "PTYW-OK pty-set-refused-inside "   "[smp$smp] pty-set-refused-inside: the owner's SET on its terminal end is -5 and the size is unchanged after both refusals"
    want "PTYW-OK pty-emulator-side "        "[smp$smp] pty-emulator-side: the emulator's copy of the endowed end reads -1; SET after the owner's death is -9 (PEERGONE)"
    want "PTYW-OK winch-sets "               "[smp$smp] winch-sets: the pre-endowment SET and all five resizes return 0; three roles ready"
    want "PTYW-OK winch-watching-holder "    "[smp$smp] winch-watching-holder: born 100x30; SIGWINCH records 0,1,0,1,1 for same / change / same / pixels only / change"
    want "PTYW-OK winch-nonwatching-holder " "[smp$smp] winch-nonwatching-holder: a holder without a bit-28 signalfd is never posted (a fresh bit-28 signalfd reads nothing)"
    want "PTYW-OK winch-nonholding-watcher " "[smp$smp] winch-nonholding-watcher: a bit-28 watcher holding only inert copies of both ends is never posted"
    want "PTYW-OK winch-epoll-unchanged "    "[smp$smp] winch-epoll-unchanged: an unchanged-size SET leaves a holder BLOCKED in epoll_wait asleep to its 300 ms deadline (0, no record)"
    want "PTYW-OK winch-epoll-wake "         "[smp$smp] winch-epoll-wake: a changed-size SET wakes a holder BLOCKED in a 5 s epoll_wait on its bit-28 signalfd in < 1 s (the signalfd's EPOLLIN record, one sig-28 record)"
    want "PTYW-OK recycled "                 "[smp$smp] recycled: a re-minted terminal reads -1 before any SET (the size died with the endpoint)"
    if strings "$LOG" | grep -qE "PTYW-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] PTYW-DONE with fail=0"; else bad "[smp$smp] PTYW-DONE with fail=0 (missing or fail > 0)"; fi
    want "PTYW-EXIT 0"                       "[smp$smp] the driver ran to its end and exits 0"
    want "kybernet: shell exited"            "[smp$smp] kybernet saw /bin/agnsh (the driver) exit"
    deny "PTYW-FAIL"                         "[smp$smp] no PTYW-FAIL line"
    deny "fault: pid=|#GP|#PF|PANIC"         "[smp$smp] no fault, #GP/#PF or PANIC line"
    deny "$SMOKE_INVARIANT_DENY"             "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
done

[ -z "${PTYWS_KERNEL:-}" ] || sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo ""
echo "=== pty-winsize-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "pty-winsize-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "pty-winsize-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "pty-winsize-smoke: PASS"
exit 0
