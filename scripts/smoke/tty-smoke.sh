#!/bin/sh
# tty-smoke.sh — 1.57.13: sweep wrapper for scripts/harness/tty-test.py.
#   console_mode#110 (NOECHO hides the line on the waiting AND the NB reader whoever reads it, the mode dies with its
#   holder — exit and kill — and never holds the line, FLUSH discards typeahead and the NB partial line), fd_kind#111
#   (console, file, memfile, directory, pipe ends, closed and invalid fds, the event fds), SIGWINCH (28) posted ONLY to a
#   bit-28 signalfd watcher when the console grid really changes, a read of console fd 2 is the cooked line, and the
#   framebuffer ghost-prompt check (HMP screendump). Phases T0-T11 are described in the harness header.
# The wait-kbd-smoke.sh precedent: it REBUILDS tests/waits/waitx and a TTY_SELFTEST kernel first (the harness refuses
# stale artifacts and a non-TTY_SELFTEST image rather than building them), then runs the harness, which boots -smp 1
# then -smp 4, banner-gated (a boot with no "AGNOS kernel v" is VOID, retried, never scored), and denies the shared
# SMOKE_INVARIANT_DENY through scripts/harness/_invdeny.py.
# Env: TTY_SMP (default "1 4"), SMOKE_KVM, QEMU_TRIES.
# Exit: 0 all PASS · 1 any FAIL · 2 VOID. Leaves a TTY_SELFTEST build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== tty smoke (console_mode#110 NOECHO/FLUSH, fd_kind#111, SIGWINCH to watchers only) ==="
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
LOGS="$ROOT/build/tty-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
echo "Building tests/waits/waitx (--agnos) and the TTY_SELFTEST kernel..."
( cd "$ROOT/tests/waits" && cyrius build --agnos waitx.cyr build/waitx ) > "$LOGS/waitx-build.log" 2>&1 \
    || { echo "  ERROR: waitx build failed (see $LOGS/waitx-build.log)"; exit 1; }
TTY_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-tty.log" 2>&1 || { echo "  ERROR: TTY_SELFTEST build failed (see $LOGS/build-tty.log)"; exit 1; }
python3 "$ROOT/scripts/harness/tty-test.py"
rc=$?
cp "$ROOT"/build/tty/serial-smp*.log* "$LOGS/" 2>/dev/null || true
case "$rc" in
    0) echo "tty-smoke: PASS"; exit 0 ;;
    2) echo "tty-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2 ;;
    *) echo "tty-smoke: FAILED (harness rc=$rc)"; exit 1 ;;
esac
