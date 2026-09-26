#!/bin/sh
# wait-kbd-smoke.sh — 1.57.7 (Path 2, S3d B2): sweep wrapper for scripts/harness/wait-kbd-test.py.
#   read#5 on the keyboard (fd 0, a4 = 0) BLOCKS ONLY ITS CALLER; ONE reader owns each cooked line (a second
#   blocking reader waits for the line; the NB reader answers -2 without draining while another live process owns
#   it, and keeps the line while its partial line is live). Phases K0-K5 are described in the harness header.
# The console-line-smoke.sh precedent: a smoke wrapping a harness .py. It REBUILDS tests/waits/waitx and the PLAIN
# kernel first (the harness refuses stale artifacts rather than building them), then runs the harness, which boots
# -smp 1 then -smp 4 (KVM when /dev/kvm is writable, else multi-threaded TCG — printed), banner-gated (a boot
# with no "AGNOS kernel v" is VOID, retried, never scored), and denies the shared SMOKE_INVARIANT_DENY through
# scripts/harness/_invdeny.py.
# Env: WAITKBD_SMP (default "1 4"), SMOKE_KVM, QEMU_TRIES.
# Exit: 0 all PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== wait-kbd smoke (the keyboard read blocks only its caller; one reader per line) ==="
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
LOGS="$ROOT/build/wait-kbd-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
echo "Building tests/waits/waitx (--agnos) and the PLAIN kernel..."
( cd "$ROOT/tests/waits" && cyrius build --agnos waitx.cyr build/waitx ) > "$LOGS/waitx-build.log" 2>&1 \
    || { echo "  ERROR: waitx build failed (see $LOGS/waitx-build.log)"; exit 1; }
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
python3 "$ROOT/scripts/harness/wait-kbd-test.py"
rc=$?
cp "$ROOT"/build/wait-kbd/serial-smp*.log* "$LOGS/" 2>/dev/null || true
case "$rc" in
    0) echo "wait-kbd-smoke: PASS"; exit 0 ;;
    2) echo "wait-kbd-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2 ;;
    *) echo "wait-kbd-smoke: FAILED (harness rc=$rc)"; exit 1 ;;
esac
