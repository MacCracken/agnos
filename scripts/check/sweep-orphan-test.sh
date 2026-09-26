#!/bin/sh
# sweep-orphan-test.sh — 1.57.9 ENDFIX (end review PSWEEP-R1): does a parallel sweep whose CONTROLLER dies without
# running its traps (SIGKILL / OOM / a harness hard-kill) leave workers, worker copies or a queue behind — and can a
# later run be scored by the dead run's workers?
#
# HERMETIC: no QEMU, no kernel build. It builds a miniature tree in a temp dir — the sweep.sh under test (default: this
# tree's scripts/sweep.sh; $1 overrides, e.g. a pre-fix copy for the RED run), a no-op scripts/build.sh and check.sh,
# and a stub for every smoke the table names (each prints the directory it ran from, then sleeps $STUB_SLEEP) — and
# runs `SWEEP_JOBS=2 SWEEP_ONLY='^1\.39\.x'` (four singleton rows) in it:
#   run A (STUB_SLEEP=30): once two rows are claimed, SIGKILL A's controller (no trap runs);
#   (a) within 20 s no process of A's worker copies (.<mini>.sweep.<A>.w<K>) may be alive  — workers die with it;
#   run B (STUB_SLEEP=2), to completion:
#   (b) every row B scores ran in one of B's OWN copies (no stub output from a .sweep.<A>. path) and B passes;
#   (c) afterwards no .sweep.<A>.w* copy and no build/sweep-queue* directory of A's is left.
# Prior art (handoff-1.57.9/steps/ENDFIX-prior-art.md): Linux PR_SET_PDEATHSIG, xdist/execnet channel EOF, GNU parallel
# --termseq, run-scoped scratch (xfstests tmp=/tmp/$$), the pidfile `kill -0` rule.
# NOT a check.sh gate (it sleeps ~70 s); run it when scripts/sweep.sh's dispatch, queue or cleanup changes.
# Measured 1.57.9 ENDFIX: RED on the PSWEEP sweep.sh (all three), GREEN on the ENDFIX one.
# Exit 0 = PASS, 1 = FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="${1:-$ROOT/scripts/sweep.sh}"
[ -f "$SUT" ] || { echo "sweep-orphan-test: no sweep.sh at '$SUT'"; exit 1; }
for t in rsync setsid pgrep pkill; do
    command -v "$t" >/dev/null 2>&1 || { echo "sweep-orphan-test: missing '$t' — measured NOTHING"; exit 1; }
done
BASE="$(mktemp -d "${TMPDIR:-/tmp}/sweep-orphan.XXXXXX")" || exit 1
MINI="$BASE/mini"
mkdir -p "$MINI/scripts/smoke" "$MINI/build"
cp "$SUT" "$MINI/scripts/sweep.sh"
printf '#!/bin/sh\nR="$(cd "$(dirname "$0")/.." && pwd)"; mkdir -p "$R/build"; : > "$R/build/agnos"; exit 0\n' > "$MINI/scripts/build.sh"
printf '#!/bin/sh\necho "check stub: PASS"; exit 0\n' > "$MINI/scripts/check.sh"
for s in $(grep -oE '"[A-Za-z0-9._-]+\.sh"' "$SUT" | tr -d '"' | sort -u); do
    printf '#!/bin/sh\necho "STUB-RAN-IN $(cd "$(dirname "$0")/../.." && pwd)"\nsleep "${STUB_SLEEP:-2}"\necho "stub smoke: PASS"\nexit 0\n' > "$MINI/scripts/smoke/$s"
done
fail=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
cleanup() {
    for p in $(pgrep -f "$BASE/" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
    rm -rf "$BASE"
}
trap cleanup EXIT INT TERM

echo "=== sweep-orphan-test (SUT: $SUT) ==="
( cd "$MINI" && STUB_SLEEP=30 SWEEP_JOBS=2 SWEEP_ONLY='^1\.39\.x' exec setsid sh scripts/sweep.sh ) > "$BASE/A.log" 2>&1 &
APID=$!
w=0
while [ "$w" -lt 60 ]; do
    [ "$(ls -d "$MINI"/build/sweep-queue*/claim.* 2>/dev/null | wc -l)" -ge 2 ] && break
    sleep 0.5; w=$((w + 1))
done
[ "$(ls -d "$MINI"/build/sweep-queue*/claim.* 2>/dev/null | wc -l)" -ge 2 ] || { bad "run A never claimed two rows (see $BASE/A.log)"; cat "$BASE/A.log"; exit 1; }
# setsid via `exec` keeps the pid: $APID IS the controller.
kill -KILL "$APID" 2>/dev/null
echo "  run A controller (pid $APID) SIGKILLed with two rows running"
w=0
while [ "$w" -lt 20 ]; do
    [ -z "$(pgrep -f "\.sweep\.$APID\.w" 2>/dev/null)" ] && break
    sleep 1; w=$((w + 1))
done
left=$(pgrep -af "\.sweep\.$APID\.w" 2>/dev/null | head -3)
if [ -z "$left" ]; then ok "(a) run A's workers died with their controller (${w} s)"; else bad "(a) run A's workers outlived their controller by 20 s:"; echo "$left" | sed 's/^/        /'; fi

( cd "$MINI" && STUB_SLEEP=2 SWEEP_JOBS=2 SWEEP_ONLY='^1\.39\.x' sh scripts/sweep.sh ) > "$BASE/B.log" 2>&1
brc=$?
if [ "$brc" -eq 3 ]; then ok "(b) run B completed clean (SWEEP_ONLY exit 3)"; else bad "(b) run B exited $brc, not 3 (see below)"; tail -15 "$BASE/B.log" | sed 's/^/        /'; fi
if grep -q "STUB-RAN-IN .*\.sweep\.$APID\." "$MINI"/build/sweep-logs/*.parallel.log 2>/dev/null; then
    bad "(b) run B scored a row that run A's orphan worker ran from its stale copy:"
    grep -h "STUB-RAN-IN .*\.sweep\.$APID\." "$MINI"/build/sweep-logs/*.parallel.log | head -3 | sed 's/^/        /'
else
    ok "(b) every row run B scored ran in run B's own copies"
fi
sleep 3
stale=$(ls -d "$BASE"/.mini.sweep."$APID".w* "$MINI/build/sweep-queue.$APID" 2>/dev/null)
if [ -z "$stale" ]; then ok "(c) nothing of run A (copies, queue) is left"; else bad "(c) run A left behind:"; echo "$stale" | sed 's/^/        /'; fi

echo "=== sweep-orphan-test: $([ "$fail" -eq 0 ] && echo PASS || echo "FAIL ($fail)") ==="
[ "$fail" -eq 0 ]
