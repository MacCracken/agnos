#!/bin/sh
# check-ci-release-gate.sh — every self-hosted CI job must actually run on a RELEASE, not just on main.
#
# ⛔⛔ WHY THIS EXISTS. `release.yml` fires only on tag refs and gates the whole release on
# `ci: uses: ./.github/workflows/ci.yml`, a job it names "CI Gate (must pass before release)". Under
# `workflow_call` the called workflow evaluates `github.ref` as the CALLER's ref — for a tag push that
# is `refs/tags/v1.56.52`, never `refs/heads/main`. Both self-hosted jobs (`boot-test`, `benchmarks`)
# carried `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`, so both evaluated
# FALSE and were skipped for every release run. `release.yml` has no boot of its own — grep it for
# qemu/boot/smoke/ktest and the only hit is a prose comment.
# ⇒ No tagged release of agnos has ever had its kernel booted by CI, and CLAUDE.md's Closeout step 2
# ("Boot sweep") assumed that gate existed.
#
# ⚠ THIS PROPERTY CANNOT BE TESTED FROM A DEVELOPER MACHINE — there is no way to run a tag-triggered
# reusable-workflow dispatch locally, so the fix would otherwise be asserted and never exercised. A
# static gate is the durable half: it re-reads the guards on every `check.sh` run, so deleting the tag
# clause fails the build instead of silently un-gating the next twelve releases.
#
# The rule: any job with `runs-on:` naming `self-hosted` must have an `if:` whose ref test admits tag
# refs — either by not testing `github.ref` at all, or by including a `refs/tags/` clause.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
[ -f "$CI" ] || { echo "  SKIP: no .github/workflows/ci.yml"; exit 0; }

python3 - "$CI" <<'PYEOF'
import re, sys
ci = sys.argv[1]
lines = open(ci, encoding='utf-8').read().split('\n')

# Collect jobs: a job header is exactly two-space-indented `name:` with nothing after it.
# ⛔ THE `if:` MUST ABSORB ITS CONTINUATION LINES. YAML lets a condition run across several lines —
# `if: >` with an indented block, or a bare condition broken after a `&&`. Reading only the first
# physical line was an affirmatively WRONG PASS in the case this gate exists to catch: if `github.ref`
# happened to sit on a continuation, the first line showed no ref test and the job was reported
# "reachable on a tag run" when its guard excluded exactly that. Anything indented deeper than the
# `if:` key itself is part of the same scalar.
jobs, cur = [], None
i = 0
while i < len(lines):
    ln = lines[i]
    m = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', ln)
    if m:
        cur = {'name': m.group(1), 'runs': '', 'if': ''}
        jobs.append(cur)
        i += 1
        continue
    if cur is not None:
        if ln.strip() and not ln.startswith('    '):
            cur = None
            i += 1
            continue
        m = re.match(r'^    runs-on:\s*(.*)$', ln)
        if m:
            cur['runs'] = m.group(1)
            i += 1
            continue
        m = re.match(r'^    if:\s*(.*)$', ln)
        if m:
            cond = m.group(1)
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() == '':
                    j += 1
                    continue
                if re.match(r'^     +\S', nxt) and not re.match(r'^    [a-zA-Z0-9_-]+:', nxt):
                    cond += ' ' + nxt.strip()
                    j += 1
                    continue
                break
            cur['if'] = cond
            i = j
            continue
    i += 1

selfhosted = [j for j in jobs if 'self-hosted' in j['runs']]

# ⛔ AN EXPECTED COUNT, NOT MERELY "AT LEAST ONE". A gate that matches nothing cannot fail — the class
# this repo has been bitten by four times — but "not empty" is not enough either: with two self-hosted
# jobs, dropping ONE of them (a rename, a re-indent, a job deleted) still leaves a non-empty list and
# the gate goes green while half its subject has vanished. Assert the number.
EXPECTED = 2       # boot-test, benchmarks
if len(selfhosted) != EXPECTED:
    print(f"  FAIL: expected {EXPECTED} self-hosted jobs in ci.yml, found {len(selfhosted)}"
          f" ({', '.join(j['name'] for j in selfhosted) or 'none'})")
    print( "        Either a job was removed/renamed, or the parser stopped matching. Both are FAILURES:")
    print( "        a gate that silently stops covering its subject is worse than no gate.")
    print(f"        If the change is intended, update EXPECTED in {__file__ if False else 'this script'}.")
    sys.exit(1)

rc = 0
for j in selfhosted:
    cond = j['if']
    if not cond:
        print(f"  PASS: {j['name']} has no 'if:' guard, so a tag run reaches it")
        continue
    if 'github.ref' not in cond:
        print(f"  PASS: {j['name']} guard does not test github.ref, so a tag run reaches it")
        continue
    if 'refs/tags/' in cond:
        print(f"  PASS: {j['name']} guard admits tag refs")
        continue
    print(f"  FAIL: job '{j['name']}' is self-hosted and its 'if:' tests github.ref with NO refs/tags/ clause")
    print(f"        -> SKIPPED on every release: workflow_call evaluates github.ref as the CALLER's tag ref.")
    print(f"        if: {cond}")
    rc = 1
sys.exit(rc)
PYEOF
