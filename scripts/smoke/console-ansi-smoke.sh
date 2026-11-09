#!/bin/sh
# console-ansi-smoke.sh — 1.57.18: sweep wrapper for scripts/harness/console-ansi-test.py (issue
# 2026-11-06-the-console-is-short-of-a-terminal). THE CONSOLE AS A TERMINAL, judged on the FRAMEBUFFER (HMP
# screendump; COM1 has no cursor): EL 0/1/2 and ED 0/1 in the active background, UTF-8 through kashi's CP437 cells with
# one replacement cell per maximal subpart (wide = 2 cells, combining = 0), a drawn cursor (?25h / ?25l, no ghost after
# a move, a scroll or an erased line), 16+ CSI parameters, SGR 7/27, OSC/DCS/APC/PM/SOS swallowed (bounded at 4096),
# Tab, the last-column pending wrap and DECAWM ?7, and console_mode#110's per-process COM1 opt-out (CM_NOSERIAL).
# Reports (not scored): one 128x64 frame mirrored vs opted out, and the cost of a whole-console scroll.
# The tty-smoke.sh precedent: it REBUILDS tests/waits/waitx and the PLAIN kernel first (the harness refuses stale
# artifacts rather than building them), then runs the harness, which boots -smp 1 then -smp 4 (KVM when /dev/kvm is
# writable), banner-gated (a boot with no "AGNOS kernel v" is VOID, retried, never scored), and denies the shared
# SMOKE_INVARIANT_DENY through scripts/harness/_invdeny.py.
# ⛔ The success line is the ONLY line carrying "smoke" and "PASS" together (sweep.sh's run_gate greps for it).
# Env: CA_SMP (default "1 4"), SMOKE_KVM, QEMU_TRIES.
# Exit: 0 all PASS · 1 any FAIL · 2 VOID / INCONCLUSIVE.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== console-ansi smoke (EL/ED, UTF-8, cursor, CSI/SGR/strings, Tab, pending wrap, #110 COM1 opt-out) ==="
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
LOGS="$ROOT/build/console-ansi-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
echo "Building tests/waits/waitx (--agnos) and the plain kernel..."
( cd "$ROOT/tests/waits" && cyrius build --agnos waitx.cyr build/waitx ) > "$LOGS/waitx-build.log" 2>&1 \
    || { echo "  ERROR: waitx build failed (see $LOGS/waitx-build.log)"; exit 1; }
sh "$ROOT/scripts/build.sh" > "$LOGS/build.log" 2>&1 || { echo "  ERROR: kernel build failed (see $LOGS/build.log)"; exit 1; }
python3 "$ROOT/scripts/harness/console-ansi-test.py"
rc=$?
cp "$ROOT"/build/console-ansi/serial-smp*.log "$LOGS/" 2>/dev/null || true
case "$rc" in
    0) echo "console-ansi-smoke: PASS"; exit 0 ;;
    2) echo "console-ansi-smoke: VOID (a boot never handed off, or nothing could be measured — not a kernel verdict)"; exit 2 ;;
    *) echo "console-ansi-smoke: FAILED (harness rc=$rc)"; exit 1 ;;
esac
