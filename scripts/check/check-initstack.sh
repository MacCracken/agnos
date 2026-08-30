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
[ -n "$ARGC" ] && [ -n "$ENVC" ] || { echo "FAIL: could not read the argc/envc caps"; exit 1; }

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
if [ -n "$BLOB" ] && [ "$BLOB" -gt "$ENVC" ]; then
    echo "FAIL: sc_env_blob_ok admits $BLOB entries but the loader's env loop caps at $ENVC"
    rc=1
fi
[ "$rc" -eq 0 ] && echo "  init-stack: $SLOTS slots, worst top index $TOPIDX, string region $STRREGION B"
exit $rc
