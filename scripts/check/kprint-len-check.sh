#!/bin/sh
# kprint/kprintln literal-length check.
#
# Cyrius kprint takes (string, length) and the compiler does NOT verify the two agree — a declared length that
# is 1 short truncates the line, 1 long runs into adjacent memory. This is a recurring defect class in this
# tree: the 1.55.4 cut caught four of them pre-burn by hand, and an off-by-one in a burn's PASS line is
# indistinguishable from a failed burn when you are reading a photo of a console.
#
# This was a manual step until 2026-07-19, when a fresh A4 instrumentation bite introduced four more (out of
# 917 literals in gpu.cyr + main.cyr — every pre-existing one was correct). Making it a script means it can
# ride check.sh instead of depending on someone remembering.
#
# Usage:  sh scripts/check/kprint-len-check.sh [file ...]     (default: all kernel/**/*.cyr)
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ⚠ THE VACUITY FLOOR BELOW APPLIES ONLY TO THE FULL-TREE SWEEP, AND THIS FLAG IS WHY. Line 13
# documents `[file ...]`, and docs/development/planning/rung17-tri-depth.md:185 tells readers to
# "recount with scripts/check/kprint-len-check.sh <file>" — a single file has ~86 literals, so an
# unconditional floor turns every documented single-file invocation into a spurious hard error.
# A floor that fires on correct usage is a worse gate than no floor.
if [ $# -gt 0 ]; then
    FILES="$*"
    SWEEP=0
else
    FILES="$(find kernel -name '*.cyr' | sort)"
    SWEEP=1
fi

python3 - "$FILES" "$SWEEP" <<'PY'
import re, sys

# ⚠ ea_expect / ea_expect_valid ADDED 1.56.30. They take (rec, want, name, nlen) with the same
# unchecked-length contract, and they were NOT covered — a rung-17 case shipped declaring 43 for a
# 44-byte name and printed "...is accepte" in the ABI battery. Same defect class as the kprint one
# this file was written for, in a function the gate simply did not look at. The lesson is not
# "add ea_expect": it is that a length-checking gate must enumerate EVERY (string, length) API in
# the tree, because the ones it omits are exactly where the bug survives.
pat = re.compile(r'\bkprint(?:ln)?\("((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\)')
eapat = re.compile(r'\bea_expect(?:_valid)?\(.*?"((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\)')
# ⚠ serial_print / serial_println ADDED 1.56.51 — AND THE GATE'S OWN LESSON ABOVE PREDICTED THIS.
# They carry the identical (string, length) contract and were the one remaining uncovered API, so
# they were exactly where the bug survived: the sweep found TWO live off-by-ones on the first scan
# (fb_console.cyr's PAT warning declaring 47 for 46 bytes, test_procs.cyr's "HW getpid=" declaring
# 11 for 10) — each printing one byte past its literal. A mismatch introduced during this very sweep
# also passed check.sh 30/30 before this line existed, which is the same gap demonstrating itself.
# ⚠ The ISR-safe console path (net_handle_icmp, elf.cyr's W^X notice) uses serial_println precisely
# BECAUSE it is not console_lock'd — so this API is on the growth path, not a legacy corner.
serpat = re.compile(r'\bserial_print(?:ln)?\("((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\)')
# ⚠ klug_append / klug_info / klug_warn / klug_err ADDED 1.56.57 — AND THIS IS THE THIRD TIME THIS
# GATE'S OWN LESSON (nine lines above) HAS BEEN PROVEN BY THE API IT OMITTED. The klug family carries the
# identical (string, length) contract and was uncovered, so it was exactly where the bug survived:
# kernel/core/proc.cyr:1624 declared 15 for a 16-byte literal, truncating its trailing newline so the next
# line ran on. It sat green through every check.sh 32/32 because no regex here looked at it.
# ⛔ klug_append IS THE HIGHEST-STAKES MEMBER, NOT THE LOWEST: fault_kill_current (core/syscall.cyr:710)
# writes ~30 fields with klug_append ONLY — never kprint — because the framebuffer may be unmapped under
# the faulting CR3. A length bug there corrupts the sole record of a ring-3 fault, on the exact path where
# no console exists to notice it.
klugpat = re.compile(r'\bklug_(?:append|info|warn|err)\("((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\)')
# ⚠ sh_exec / test_assert / test_assert_eq ADDED 1.56.57, IN THE SAME SWEEP AS klug — AND THIS FAMILY
# CARRIED 21 LIVE MISMATCHES, the largest single haul this gate has ever taken. Most were
# declared == actual + 1 (someone counting the NUL), which truncates nothing and over-reads one byte,
# so every one of them printed a plausible-looking label and nobody looked twice.
# ⛔ sh_exec IS NOT A PRINTER — kernel/user/shell.cyr:486 computes `arglen = len - cmd_end`, so an
# over-long len lengthens the ARGV STRING handed to the exec path, not just a console line. That is
# the reason this family is worth a distinct regex rather than being waved off as cosmetic.
# ⛔⛔ AND THE PATTERN MUST BE TAIL-ANCHORED, NOT NON-GREEDY LIKE eapat. The (name, nlen) pair is the
# LAST two arguments, and these calls routinely carry an EARLIER (string, int) pair that is not a
# length: `test_assert_eq(memchr("hello", 108, 5), 2, "memchr 'l' at 2", 15)` — 108 is a CHARACTER
# CODE. A leading `.*?` matches "hello",108 first and reports a phantom mismatch while missing the
# real one; a greedy `.*` anchored to the close-paren takes the label pair every time. Measured: the
# non-greedy form produced 5 false positives and MISSED test.cyr:403, whose line also contains a
#     correct `memeq(&hbuf, "8000000000000000", 16)`.
tailpat = re.compile(r'\b(?:sh_exec|test_assert|test_assert_eq)\(.*"((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\s*\)\s*;?\s*$')
bad = 0
total = 0
sweep = int(sys.argv[2])
unread = []
for path in sys.argv[1].split():
    try:
        lines = open(path, encoding='utf-8').readlines()
    except OSError:
        # ⛔ AN UNREADABLE FILE IS NOT A CLEAN FILE. This used to `continue`, so a renamed, deleted or
        # permission-denied path contributed 0 literals and 0 mismatches — indistinguishable from a
        # file that was checked and was fine. That is the vacuity this gate exists to refuse, sitting
        # inside the gate itself.
        unread.append(path)
        continue
    for lineno, line in enumerate(lines, 1):
        for m in list(pat.finditer(line)) + list(eapat.finditer(line)) + list(serpat.finditer(line)) + list(klugpat.finditer(line)) + list(tailpat.finditer(line.rstrip())):
            literal, declared = m.group(1), int(m.group(2))
            # Cyrius escapes follow C conventions closely enough for a length count.
            actual = len(literal.encode().decode('unicode_escape'))
            total += 1
            if actual != declared:
                bad += 1
                print(f"  MISMATCH {path}:{lineno}  declared={declared} actual={actual}")
                print(f"           {literal!r}")

# ⛔ THE READABILITY FLOOR APPLIES IN BOTH MODES, AND IT IS THE ONE THAT ACTUALLY DISCRIMINATES.
# A literal COUNT cannot be the single-file discriminator: kernel/core/kprint.cyr legitimately holds
# ZERO matching literals (it is where the emitters are DEFINED, not called), so any count floor either
# fails that correct file or passes a missing one. "Did I read every file I was handed?" is true of a
# healthy single file, a healthy tree, and nothing else.
if unread:
    print(f"  ERROR: {len(unread)} file(s) could not be read — not checked, not clean:")
    for u in unread[:10]:
        print(f"           {u}")
    sys.exit(1)

# ⚠ CORPUS FLOOR, SWEEP MODE ONLY. In a full-tree run a collapsed file list or a dead regex must redden
# rather than report a green "0 mismatched". It is gated to sweep mode because line 13 documents
# `[file ...]` and docs/development/planning/rung17-tri-depth.md:185 tells readers to recount a single
# file — ~86 literals — which an unconditional 3000 floor turned into a spurious hard error.
if sweep == 1 and total < 3000:
    print(f"  ERROR: only {total} literals enumerated — the file list or a regex is broken, not the tree")
    sys.exit(1)
print(f"  checked {total} kprint/ea_expect/serial_print/klug/sh_exec/test_assert literals, {bad} mismatched")
sys.exit(1 if bad else 0)
PY
