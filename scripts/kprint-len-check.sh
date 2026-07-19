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
# Usage:  sh scripts/kprint-len-check.sh [file ...]     (default: all kernel/**/*.cyr)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ $# -gt 0 ]; then
    FILES="$*"
else
    FILES="$(find kernel -name '*.cyr' | sort)"
fi

python3 - "$FILES" <<'PY'
import re, sys

pat = re.compile(r'\bkprint(?:ln)?\("((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\)')
bad = 0
total = 0
for path in sys.argv[1].split():
    try:
        lines = open(path, encoding='utf-8').readlines()
    except OSError:
        continue
    for lineno, line in enumerate(lines, 1):
        for m in pat.finditer(line):
            literal, declared = m.group(1), int(m.group(2))
            # Cyrius escapes follow C conventions closely enough for a length count.
            actual = len(literal.encode().decode('unicode_escape'))
            total += 1
            if actual != declared:
                bad += 1
                print(f"  MISMATCH {path}:{lineno}  declared={declared} actual={actual}")
                print(f"           {literal!r}")

print(f"  checked {total} kprint literals, {bad} mismatched")
sys.exit(1 if bad else 0)
PY
