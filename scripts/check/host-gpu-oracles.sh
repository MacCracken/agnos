#!/bin/sh
# host-gpu-oracles — build and RUN the zero-burn host oracles that model GPU behaviour.
#
# ⛔ THE GAP THIS CLOSES: tests/gpu/*.cyr were run by hand and by nothing else. check-array-sizing.sh
# SCANS them, shader-blob.sh cites them, and no script has ever EXECUTED one. So an oracle could go
# red — or stop compiling — and the tree would stay green until somebody remembered to run it, which
# is the same class of defect as a gate wired with a bare `; rc=$?`: a check that exists on paper and
# cannot fail in practice.
#
# ⚠ SCOPE, STATED HONESTLY: this runs texlist ONLY. It is the oracle for the op 0x0C grid mapping
# (rungs 14 and 14b), which is live work with mutations that must keep firing. doomcol, doomwall,
# texmodel/texgate, edgemodel, refraster and the rest are equally host-runnable and equally unwired;
# adding them is a separate bite, not something to smuggle in beside a rung.
#
# What PASSES: exit 95. texlist returns 86 if any grid case is inexact OR if fewer than all of its
# mutations go red — so this gate covers both the model and its own falsification.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GPU="$ROOT/tests/gpu"

command -v cyrius >/dev/null 2>&1 || { echo "host-gpu-oracles: cyrius not on PATH"; exit 2; }

# ⚠ tests/gpu includes from the parent tree (lib/io.cyr, tricore.cyr), which the wrapper refuses by
# default. Without this the build fails and the gate would report a TOOLING failure as an oracle
# failure — two very different things to be told at 2am.
CYRIUS_ALLOW_PARENT_INCLUDES=1
export CYRIUS_ALLOW_PARENT_INCLUDES

mkdir -p "$GPU/build"

rc=0
for t in texlist; do
    out="$(cd "$GPU" && cyrius build "$t.cyr" "build/$t" 2>&1)" || {
        echo "host-gpu-oracles: FAIL -- $t.cyr does not BUILD"
        echo "$out" | tail -20
        exit 1
    }
    "$GPU/build/$t" > "/tmp/host-gpu-$t.log" 2>&1
    got=$?
    if [ "$got" -ne 95 ]; then
        echo "host-gpu-oracles: FAIL -- $t exited $got, want 95"
        tail -30 "/tmp/host-gpu-$t.log"
        rc=1
    else
        echo "host-gpu-oracles: PASS -- $t exit 95"
    fi
done
exit $rc
