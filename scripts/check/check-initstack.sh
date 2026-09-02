#!/bin/sh
# check-initstack.sh — the SysV init-stack pointer array must hold every argv/envp slot the two
# loader caps can produce.
#
# ⛔⛔ WHY THIS EXISTS. The array lives in [ELF_INIT_BLOCK+8, ELF_INIT_STR) and the loader's last write
# is the auxv AT_NULL VALUE at index argc + 3 + envc. Those two counts are capped in DIFFERENT
# FUNCTIONS that never see each other: argc in elf.cyr's argv tokenizer, envc in its env loop — and
# sc_env_blob_ok, which applies the 16-entry blob cap, runs before argv is tokenized and structurally
# cannot know argc. So nothing in the code held the combined invariant, and when argc was raised
# 8 -> 16 at 1.46.x the array silently became too small: argc + envc >= 28 wrote past ELF_INIT_STR
# and clobbered the argv strings the array points at.
#
# ⚠ THE INVARIANT ROTTED IN THREE SEPARATE COMMENTS BEFORE IT WAS CAUGHT ("~27 ptr slots", "31 slots",
# "the 2-entry envp"), each hand-derived and each wrong. A runtime guard is not enough on its own —
# with the widened array it is UNREACHABLE for every input the syscall gates admit, so it can never
# fire in a test. This gate is the durable half: it re-derives the arithmetic from the live constants
# on every run, so raising either cap without widening the window fails the build instead of
# corrupting a child's argv.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELF="$ROOT/kernel/core/elf.cyr"
SYS="$ROOT/kernel/core/syscall.cyr"

# ⚠ VACUITY FLOOR, PART 1 — THE INPUTS MUST BE THERE. Every number below is a `sed`/`grep` over these
# two paths, and a grep over a path that does not exist prints nothing and exits 1, which inside a
# command substitution is INDISTINGUISHABLE from "the cap is not in the file". So a rename or a move
# of kernel/core/syscall.cyr — the kind the 1.56.22 tree-split did to a dozen scripts — would have
# emptied BLOB and retired the third assertion below with no output whatsoever, on a gate whose whole
# job is to re-derive an invariant from the live source. Say which file is missing instead.
[ -f "$ELF" ] || { echo "FAIL: $ELF not found — the init-stack gate has no source to re-derive from"; exit 1; }
[ -f "$SYS" ] || { echo "FAIL: $SYS not found — the init-stack gate has no source to re-derive from"; exit 1; }

hexval() { sed -n "s/^var $1 *= *\(0x[0-9A-Fa-f]*\);.*/\1/p" "$2" | head -1; }

BLOCK=$(hexval ELF_INIT_BLOCK "$ELF")
STR=$(hexval ELF_INIT_STR "$ELF")
STACK=$(hexval ELF_STACK_SIZE "$ELF")
[ -n "$BLOCK" ] && [ -n "$STR" ] && [ -n "$STACK" ] || { echo "FAIL: could not read ELF_INIT_* constants"; exit 1; }

# argc cap: the tokenizer's `if (argc >= N) { break; }`
ARGC=$(grep -oE 'if \(argc >= [0-9]+\) \{ break; \}' "$ELF" | grep -oE '[0-9]+' | head -1)
# envc cap: the env loop's `if (envc >= N) { break; }`
ENVC=$(grep -oE 'if \(envc >= [0-9]+\) \{ break; \}' "$ELF" | grep -oE '[0-9]+' | head -1)
# and the blob-entry cap sc_env_blob_ok enforces, which must not exceed the loop's
BLOB=$(grep -oE 'if \(entries > [0-9]+\) \{ return 0; \}' "$SYS" | grep -oE '[0-9]+' | head -1)
# ⚠ VACUITY FLOOR, PART 2 — ALL THREE PARSES ARE MANDATORY, BLOB INCLUDED. Until 1.56.58 only ARGC and
# ENVC were asserted here; BLOB was guarded down at its own comparison instead (`[ -n "$BLOB" ] &&
# [ "$BLOB" -gt "$ENVC" ]`), which converts a rotted pattern into a SILENT NO-OP rather than a
# failure. MEASURED 2026-09-02, on a copy of syscall.cyr carrying ONE EXTRA SPACE
# (`if (entries  > 16) { return 0; }`): the gate printed the identical green line
#     init-stack: 63 slots, worst top index 35, string region 3584 B
# and exited 0, with the sc_env_blob_ok-vs-env-loop comparison gone and nothing said about it. That
# is precisely the rot this file's header exists to catch — the invariant that "rotted in three
# separate comments before it was caught" — reproduced inside the gate written to prevent it. A cap
# this gate cannot read is a cap it is not checking, and it now says so and fails.
[ -n "$ARGC" ] || { echo "FAIL: could not read the argc cap ('if (argc >= N) { break; }' in $ELF)"; exit 1; }
[ -n "$ENVC" ] || { echo "FAIL: could not read the envc cap ('if (envc >= N) { break; }' in $ELF)"; exit 1; }
[ -n "$BLOB" ] || { echo "FAIL: could not read sc_env_blob_ok's entry cap ('if (entries > N) { return 0; }' in $SYS)"; exit 1; }

SLOTS=$(( ( $STR - $BLOCK - 8 ) / 8 ))
TOPIDX=$(( $ARGC + 3 + $ENVC ))
STRREGION=$(( $STACK - $STR ))

rc=0
if [ "$TOPIDX" -gt $(( $SLOTS - 1 )) ]; then
    echo "FAIL: init-stack pointer array overflows"
    echo "      slots=$SLOTS (indices 0..$(( $SLOTS - 1 ))), worst top index=$TOPIDX (argc=$ARGC + 3 + envc=$ENVC)"
    echo "      widen ELF_INIT_STR, or lower a cap — see the derivation at elf.cyr's ELF_INIT_STR"
    rc=1
fi
# argv payload <=127 B + <=argc NULs, env blob <=1024 B (already NUL-separated)
NEED=$(( 127 + $ARGC + 1024 ))
if [ "$STRREGION" -lt "$NEED" ]; then
    echo "FAIL: init-stack string region too small: have $STRREGION B, worst case needs $NEED B"
    rc=1
fi
if [ "$BLOB" -gt "$ENVC" ]; then
    echo "FAIL: sc_env_blob_ok admits $BLOB entries but the loader's env loop caps at $ENVC"
    rc=1
fi
# ⚠ PRINT WHAT WAS PARSED, NOT JUST THE VERDICT. All four caps go on the success line so a run whose
# enumeration broke is reporting it: this gate's only inputs are four numbers scraped out of two
# source files, and the failure mode above was one of them going missing without a word. A green line
# naming argc=16 / envc=16 / blob cap 16 is evidence the three assertions ran against real values.
[ "$rc" -eq 0 ] && echo "  init-stack: $SLOTS slots, worst top index $TOPIDX (argc<=$ARGC + 3 + envc<=$ENVC), string region $STRREGION B, blob cap $BLOB"
exit $rc
