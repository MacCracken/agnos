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

if [ $# -gt 0 ]; then
    FILES="$*"
else
    FILES="$(find kernel -name '*.cyr' | sort)"
fi

python3 - "$FILES" <<'PY'
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
bad = 0
total = 0
for path in sys.argv[1].split():
    try:
        lines = open(path, encoding='utf-8').readlines()
    except OSError:
        continue
    for lineno, line in enumerate(lines, 1):
        for m in list(pat.finditer(line)) + list(eapat.finditer(line)) + list(serpat.finditer(line)):
            literal, declared = m.group(1), int(m.group(2))
            # Cyrius escapes follow C conventions closely enough for a length count.
            actual = len(literal.encode().decode('unicode_escape'))
            total += 1
            if actual != declared:
                bad += 1
                print(f"  MISMATCH {path}:{lineno}  declared={declared} actual={actual}")
                print(f"           {literal!r}")

print(f"  checked {total} kprint/ea_expect/serial_print literals, {bad} mismatched")
sys.exit(1 if bad else 0)
PY
