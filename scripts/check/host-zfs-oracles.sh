#!/bin/sh
# host-zfs-oracles — regenerate the ZFS codec vectors, REBUILD tests/zfscodec, run it, and score it.
#
# What it proves: kernel/core/zfs_codec.cyr — SHA-256 (one-shot and streaming), SHA-512/256,
# fletcher2/4, the ZAP name hash, and the lz4 / lzjb / zle / gzip decoders — agrees with vectors
# that scripts/check/zfs-codec-vectors.py derives from INDEPENDENT producers (hashlib, zlib, the lz4
# CLI, Python ports of the OpenZFS compressors), and that every decoder stays inside its buffers on
# hostile input (each runs against PROT_NONE guard pages at both ends, plus a mutation fuzz).
# The oracle INCLUDES the kernel file — there is one implementation, not a mirror of it.
#
# Exit: 0 iff the oracle exited 95 AND scored at least ZFS_ORACLE_FLOOR passing cases; 1 on a red
# oracle (or a vacuous one); 2 on a TOOLING failure (no cyrius / python3 / lz4, or the generator
# could not run) — "the tools are missing" and "the codec is wrong" are different things to be told.
#
# ⚠ THIS REBUILDS BEFORE IT RUNS, and deletes the old binary first. A binary left over from an
# earlier source is evidence about that source, not this one (host-gpu-oracles.sh's header has the
# story of a committed oracle that passed while its source did not compile). Same for the vectors:
# they are regenerated on every run and never committed (tests/zfscodec/gen/ is git-ignored).
#
# ⛔ VACUITY: the oracle's own exit is computed from a failure counter, so an oracle whose case list
# went missing would exit 95 having checked nothing. Two floors stop that: the oracle refuses to
# pass unless it ran exactly the generated count (and >= its own floor), and THIS script counts the
# `PASS ` lines it printed and requires ZFS_ORACLE_FLOOR of them. The number is the count measured
# on 2026-10-09 (249: 248 generated + 1 local). Adding vectors raises the real count above it,
# which is fine; if a deliberate removal drops below it, RE-MEASURE and lower it in the same edit.
# Deleting the floor to make the gate quiet puts the hole back.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$ROOT/tests/zfscodec"
LOGD="${CHECK_LOGS:-$ROOT/build/check-logs}"
LOG="$LOGD/host-zfs-zfscodec.log"
ZFS_ORACLE_FLOOR=249
mkdir -p "$LOGD"

command -v cyrius  >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- cyrius not on PATH"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- python3 not on PATH"; exit 2; }
command -v lz4     >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- the lz4 CLI is not installed (the LZ4 vectors come from it)"; exit 2; }

gen="$(python3 -I "$ROOT/scripts/check/zfs-codec-vectors.py" 2>&1)" || {
    echo "host-zfs-oracles: TOOLING -- zfs-codec-vectors.py failed; no vectors, nothing tested"
    echo "$gen" | tail -20
    exit 2
}
echo "host-zfs-oracles: $gen"

# The oracle includes ../../kernel/..., which the wrapper refuses by default.
CYRIUS_ALLOW_PARENT_INCLUDES=1
export CYRIUS_ALLOW_PARENT_INCLUDES
rm -f "$T/build/zfscodec"
out="$(cd "$T" && cyrius build zfscodec.cyr build/zfscodec 2>&1)" || {
    echo "host-zfs-oracles: FAIL -- tests/zfscodec/zfscodec.cyr does not BUILD"
    echo "$out" | tail -20
    exit 1
}
[ -x "$T/build/zfscodec" ] || { echo "host-zfs-oracles: FAIL -- the build reported OK but left no binary"; exit 1; }

"$T/build/zfscodec" > "$LOG" 2>&1
got=$?
pass=$(LC_ALL=C grep -ac '^PASS ' "$LOG" 2>/dev/null || true)
pass=${pass:-0}
case "$pass" in *[!0-9]*) pass=0 ;; esac
fail=$(LC_ALL=C grep -ac '^FAIL ' "$LOG" 2>/dev/null || true)
fail=${fail:-0}
case "$fail" in *[!0-9]*) fail=0 ;; esac

if [ "$got" -ne 95 ]; then
    echo "host-zfs-oracles: FAIL -- zfscodec exited $got, want 95 ($pass case(s) passed, $fail failed before it stopped)"
    [ "$got" -gt 128 ] && echo "    a SIGNAL ($((got - 128))): a decoder or checksum touched a guard page — an out-of-bounds access"
    LC_ALL=C grep -a '^FAIL \|^  ' "$LOG" | head -30
    tail -5 "$LOG"
    exit 1
fi
if [ "$pass" -lt "$ZFS_ORACLE_FLOOR" ]; then
    echo "host-zfs-oracles: FAIL -- zfscodec exited 95 over $pass passing case(s), floor $ZFS_ORACLE_FLOOR"
    echo "    VACUOUS: the oracle reports success by finding no failures, and it scored too few cases"
    echo "    to have looked for many."
    tail -5 "$LOG"
    exit 1
fi
echo "host-zfs-oracles: PASS -- zfscodec exit 95, $pass case(s) scored (floor $ZFS_ORACLE_FLOOR), 0 failed"
exit 0
