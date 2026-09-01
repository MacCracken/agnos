#!/bin/sh
# Syscall ABI three-way consistency check.
#
# The agnos syscall ABI is written down in THREE places that must agree, and until 2026-08-05 nothing
# compared them:
#
#   1. kernel/core/syscall.cyr                 — the implementation. CANONICAL.
#   2. docs/development/agnos-userland-abi.md  — the human contract.
#   3. cyrius lib/syscalls_x86_64_agnos.cyr    — the `SysNrAgnos` enum every ring-3 program compiles against.
#
# ⛔ WHY THIS EXISTS. A 2026-08-05 audit found the ABI doc individually documented **65 of 96** syscalls
# — 14 behind a "backfill pending" placeholder and 17 with no mention at all (the audio band, the shm
# band the whole desktop pixel path runs on, the block band the installer needs). Worse, the doc named
# the cyrius peer as its authority while the cyrius peer named the doc as its own, so for 45-59 NEITHER
# was canonical and a wrong number in either could be "verified" against the other. Those 31 gaps
# accumulated over ~15 minor versions because nothing diffed them.
#
# ⛔ THE CONSEQUENCE IS NOT HYPOTHETICAL. agnos redefines the numbers (exit is #0, not Linux's 60), so a
# wrong number COMPILES CLEAN and calls a different arm. Confirmed shipping in jalwa: `mkdir`(83) -> GPU
# f64 dispatch, `poll`(7) -> `open` **per frame**, `read`(0) -> **exit**.
#
# ⛔ WHAT THIS CHECKS, AND WHY IT IS NOT A THREE-WAY NAME DIFF. The kernel is canonical for the NUMBER
# SET — `if (num == N)` is unambiguous. It is NOT a reliable source of NAMES: the dispatch comments are
# free-form and inconsistent (`# gpu_present() —`, `# epoll_create`, `# exit — halt...`, and two arms
# with no comment at all). A gate that hard-failed on comment prose would cry wolf, and a gate that
# cries wolf gets disabled. So:
#
#   A. NUMBER SETS   kernel == doc == cyrius, both directions.        HARD FAIL. Fully reliable.
#   B. NAMES         doc == cyrius, for every number.                 HARD FAIL. Both machine-readable.
#   C. KERNEL NAMES  where a dispatch comment yields a name, it must
#                    match doc+cyrius.                                HARD FAIL on disagreement,
#                                                                     NOTE (not failure) where absent.
#
# B is what catches the real defect: doc and cyrius are the two files a human edits by hand, and they
# are the two that drift.
#
# Usage:  sh scripts/check/syscall-abi-check.sh
# Exit:   0 = consistent · 1 = not (every disagreement is printed, not just the first)
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# The cyrius peer. Prefer the sibling REPO (what a cyrius change is authored in), fall back to the
# installed toolchain (what this kernel is actually built against).
# ⛔ NO SKIP PATH. If neither is present this FAILS. A check that quietly passes when it could not find
# one of its three inputs is a false green, and this tree has paid for those.
SIBLINGS="${SIBLINGS_ROOT:-$(cd "$ROOT/.." && pwd)}"
CYPEER=""
if [ -f "$SIBLINGS/cyrius/lib/syscalls_x86_64_agnos.cyr" ]; then
    CYPEER="$SIBLINGS/cyrius/lib/syscalls_x86_64_agnos.cyr"
else
    for d in $(ls -d "$HOME"/.cyrius/versions/*/ 2>/dev/null | sort -V -r); do
        if [ -f "$d/lib/syscalls_x86_64_agnos.cyr" ]; then CYPEER="$d/lib/syscalls_x86_64_agnos.cyr"; break; fi
    done
fi

python3 - "$CYPEER" <<'PY'
import re, sys

cypeer = sys.argv[1]
fail = 0

def die(msg):
    print("  FAIL: " + msg)

if not cypeer:
    print("  FAIL: cyrius syscall peer not found — looked for ../cyrius/lib/syscalls_x86_64_agnos.cyr and")
    print("        ~/.cyrius/versions/*/lib/syscalls_x86_64_agnos.cyr. Set SIBLINGS_ROOT, or install a")
    print("        toolchain. This check does NOT skip: two of three sources cannot verify an ABI.")
    sys.exit(1)

# ---------------------------------------------------------------- 1. KERNEL — the number set
#
# ⛔ #44 sched_yield is NOT in this file's dispatch chain — it is serviced only by the ring-3 SYSCALL
# entry stub, so a naive `grep 'if (num == '` returns 95 and reports a hole that does not exist. That
# trap cost time during the 2026-08-05 audit; it is handled explicitly rather than left to be
# rediscovered. If the stub gains or loses a number, this is where to add it.
#
# ⛔⛔ 1.56.55 — AND THE STUB DID GAIN ONE, AND NOBODY ADDED IT, SO THIS GATE WENT BLIND ON `fork`.
# `#96 fork` dispatches from arch/x86_64/syscall_hw.cyr (`if (sc_num == 96) { return sys_fork(...); }`)
# for the same reason #44 and #14 do — the child's resume context lives in pcpu_sc_entry_regs, valid
# only on a path reached from the ring-3 entry stub. It has NO arm in kernel/core/syscall.cyr, which
# is the only file scanned below, so the kernel number set silently excluded 96. The ABI doc had no
# `| 96 |` row and cyrius had no SYS_FORK either — so all THREE sources agreed by MUTUAL ABSENCE and
# this check reported nothing while a shipped, sweep-gated syscall was undocumented on both sides.
# ⭐ THAT IS THE EXACT FALSE-GREEN THIS FILE'S OWN HEADER WARNS ABOUT ("a check that quietly passes
# when it could not find one of its three inputs is a false green, and this tree has paid for those").
# The comment above already said "if the stub gains or loses a number, this is where to add it"; the
# instruction was correct and simply was not followed when fork landed. Adding a number to the stub
# WITHOUT adding it here now costs a red gate rather than a silent hole — which is the right cost.
ENTRY_STUB_ONLY = {44: "sched_yield", 96: "fork"}

ksrc = open("kernel/core/syscall.cyr", encoding="utf-8").read().splitlines()
kernel = {}
kname = dict(ENTRY_STUB_ONLY)
for i, ln in enumerate(ksrc):
    m = re.search(r'if \(num == (\d+)\)', ln)
    if not m:
        continue
    n = int(m.group(1))
    kernel[n] = True
    # Best-effort name: the comment on this line after the arm, or the next line's comment.
    # Accept both `# name(...)` and a bare `# name` / `# name — prose`.
    after = ln.split('if (num ==', 1)[1]
    tail = after.split('#', 1)[1] if '#' in after else ""
    if not tail and i + 1 < len(ksrc):
        nxt = ksrc[i + 1].strip()
        if nxt.startswith('#'):
            tail = nxt[1:]
    nm = re.match(r"\s*([a-z_][a-z0-9_]*)\s*(?:\(|\s*(?:—|-|:)|\s*$)", tail)
    if nm:
        kname[n] = nm.group(1)
for n in ENTRY_STUB_ONLY:
    kernel[n] = True

# ---------------------------------------------------------------- 2. ABI DOC
#
# ⛔ PARSE ONLY THE SYSCALL-TABLE SECTIONS. The doc also contains offset/field tables with the exact
# same `| N | \`name\` |` shape — §3.4 GPU op codes, §4.1 `stat`, §4.2 `getdents`, §4.3 `uname`,
# §4.4 `sysinfo`. A whole-file regex reads `| 3 | \`namelen\` |` out of the getdents record and reports
# syscall #3 as being called "namelen". The first draft of this check did exactly that and produced
# eight fake name disagreements — a gate's own false positives are indistinguishable from the defect
# it hunts, so the section filter is load-bearing, not tidiness.
SYSCALL_SECTIONS = (re.compile(r'^## 2\.'), re.compile(r'^## 3\.'), re.compile(r'^### 3\.[12]\b'))
OTHER_SECTIONS   = (re.compile(r'^### 3\.[34]\b'), re.compile(r'^## [014-9]\.'), re.compile(r'^## \d\d'))

doc = {}
outside = {}          # rows matching the syscall-row shape but found OUTSIDE the syscall sections
in_tbl = False
for ln in open("docs/development/agnos-userland-abi.md", encoding="utf-8"):
    if ln.startswith('#'):
        if any(r.match(ln) for r in OTHER_SECTIONS):
            in_tbl = False
        elif any(r.match(ln) for r in SYSCALL_SECTIONS):
            in_tbl = True
    m = re.match(r'^\|\s*(\d+)\s*\|\s*`([a-z0-9_]+)`', ln)
    if not m:
        continue
    if in_tbl:
        doc[int(m.group(1))] = m.group(2)
    else:
        outside.setdefault(int(m.group(1)), m.group(2))

# ---------------------------------------------------------------- 3. CYRIUS PEER
cy = {}
for ln in open(cypeer, encoding="utf-8"):
    m = re.match(r'\s*(SYS_[A-Z0-9_]+)\s*=\s*(\d+)\s*;', ln)
    if m:
        cy[int(m.group(2))] = m.group(1)[4:].lower()   # SYS_SPAWN_PATH -> spawn_path

print("  kernel %d · abi-doc %d · cyrius %d" % (len(kernel), len(doc), len(cy)))
print("  peer: %s" % cypeer)

# ---------------------------------------------------------------- A. NUMBER SETS
for label, other in (("abi-doc", doc), ("cyrius", cy)):
    miss = sorted(set(kernel) - set(other))
    if miss:
        fail = 1
        die("%d syscall(s) the kernel implements are absent from %s:" % (len(miss), label))
        for n in miss:
            print("          #%-3d %s" % (n, kname.get(n, "?")))
    extra = sorted(set(other) - set(kernel))
    if extra:
        fail = 1
        die("%d number(s) in %s with NO kernel arm — a caller gets the dispatch fall-through value"
            " and reads it as data:" % (len(extra), label))
        for n in extra:
            print("          #%-3d %s" % (n, other[n]))

# ---------------------------------------------------------------- B. NAMES (doc vs cyrius)
# ⛔ Numbers alone are not enough. Two sources agreeing that #83 exists while disagreeing about WHAT it
# is, is exactly the state that lets a consumer call the wrong arm and compile clean.
bad = [(n, doc[n], cy[n]) for n in sorted(set(doc) & set(cy)) if doc[n] != cy[n]]
if bad:
    fail = 1
    die("%d name disagreement(s) between the ABI doc and the cyrius peer:" % len(bad))
    print("          %-5s %-24s %s" % ("#", "abi-doc", "cyrius"))
    for n, d, c in bad:
        print("          %-5d %-24s %s" % (n, d, c))

# ---------------------------------------------------------------- C. KERNEL NAMES (advisory source)
kbad = []
for n in sorted(set(kname) & set(doc) & set(cy)):
    if doc[n] == cy[n] and kname[n] != doc[n]:
        kbad.append((n, kname[n], doc[n]))
if kbad:
    fail = 1
    die("%d name(s) where the kernel dispatch comment disagrees with BOTH other sources"
        " (kernel is canonical):" % len(kbad))
    print("          %-5s %-24s %s" % ("#", "kernel comment", "doc + cyrius"))
    for n, k, d in kbad:
        print("          %-5d %-24s %s" % (n, k, d))

# ---------------------------------------------------------------- D. MISPLACED SYSCALL ROWS
# ⛔ THE SECTION FILTER IS ALSO A BLIND SPOT, AND THIS CLOSES IT. Because §B only reads rows inside the
# syscall sections, a syscall row written into the WRONG section (§3.4 op codes, §4.x structs) is
# invisible: the check would report it "absent from abi-doc" while the author is looking straight at
# the row they just wrote, or — worse — not report it at all. Found by a negative control on
# 2026-08-05: a deliberately-planted `#96 fork` row appended past §4 was silently ignored and the gate
# passed. The control was wrong, but the blind spot it exposed was real.
#
# Detection is exact rather than heuristic: a row outside the syscall sections is only flagged when its
# number is one the kernel implements AND its name matches what cyrius calls that number. A struct
# field (`| 48 | \`machine\` |` in the uname layout) can never satisfy the second half.
misplaced = sorted(n for n, nm in outside.items()
                   if n in kernel and n in cy and cy[n] == nm and n not in doc)
if misplaced:
    fail = 1
    die("%d syscall row(s) in a NON-syscall section of the ABI doc — move them into §2/§3.2, they are"
        " not being checked where they are:" % len(misplaced))
    for n in misplaced:
        print("          #%-3d %s" % (n, outside[n]))

unnamed = sorted(set(kernel) - set(kname))
if unnamed:
    # NOTE, not FAIL — see the header. A missing comment is a docs nit; failing on it would make this
    # gate unrunnable over a file whose comment style predates it by 50 releases.
    print("  NOTE: %d dispatch arm(s) carry no leading `# name` comment, so their kernel-side name could"
          " not be cross-checked: %s" % (len(unnamed), ", ".join("#%d" % n for n in unnamed)))
    print("        (numbers and doc/cyrius names for these ARE still checked above.)")

if fail == 0:
    print("  OK: kernel, ABI doc and the cyrius peer agree on all %d syscalls." % len(kernel))
sys.exit(fail)
PY
