#!/bin/sh
# brace-balance-check — every `{` under kernel/ is closed by exactly one `}`, per file, and no `}` appears at
# depth 0.
#
# ⛔ WHY (1.57.12). cycc 6.6.6 accepts an unmatched top-level `}` WITHOUT A DIAGNOSTIC and stops parsing the unit
# there: every declaration after it is silently dropped and the build says `OK` (filed:
# `cyrius/docs/development/issues/2026-10-11-stray-top-level-brace-silently-ends-the-unit.md`). In the kernel the
# dropped definitions surface as dozens of "undefined variable" errors in OTHER files and nothing at the real
# line — the ZFS writer's bite B4 lost a bisect to one. Same shape as pp-balance-check.sh (gate 35): a pure text
# walk that never invokes cyrius, so its verdict cannot depend on the compiler's tolerance.
#
# Lexing: `#` to end of line is a comment (and every directive line); "…" is a string literal with `\` escapes;
# '…' likewise (a quote in code is a char literal — none carries a brace today, the rule keeps it that way).
# Braces inside comments and strings do not count. `#ifdef` branches are counted as written, so each branch of a
# directive must balance on its own — a split `{` across `#ifdef`/`#else` is refused (it would also defeat any
# reader of the source).
#
# Exit 0 if every file balances (the file count is printed — vacuity floor 10); 1 naming file:line otherwise.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
python3 -I - <<'PY'
import os, sys
bad = []; n = 0
for dp, _, fs in sorted(os.walk("kernel")):
    for f in sorted(fs):
        if not f.endswith(".cyr"):
            continue
        p = os.path.join(dp, f); n += 1
        s = open(p, encoding="utf-8", errors="replace").read()
        depth = 0; line = 1; i = 0; st = None; opened = []
        while i < len(s):
            c = s[i]
            if c == "\n":
                line += 1
            if st in ("str", "chr"):
                if c == "\\":
                    i += 2; continue
                if (st == "str" and c == '"') or (st == "chr" and c == "'"):
                    st = None
            elif st == "cmt":
                if c == "\n":
                    st = None
            else:
                if c == "#":
                    st = "cmt"
                elif c == '"':
                    st = "str"
                elif c == "'":
                    st = "chr"
                elif c == "{":
                    depth += 1; opened.append(line)
                elif c == "}":
                    if depth == 0:
                        bad.append("%s:%d: unmatched '}' at top level -- cycc drops everything after it" % (p, line))
                    else:
                        depth -= 1; opened.pop()
            i += 1
        if depth:
            bad.append("%s: %d unclosed '{' at end of file (opened at line %s)" % (p, depth, ", ".join(map(str, opened[-3:]))))
if n < 10:
    print("brace-balance-check: FAILED — found %d .cyr files under kernel/; vacuous below 10" % n); sys.exit(1)
if bad:
    print("brace-balance-check: FAILED — %d problem(s):" % len(bad))
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("brace-balance-check: OK — %d kernel .cyr files balance" % n)
PY
