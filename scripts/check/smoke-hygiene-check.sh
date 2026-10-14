#!/bin/sh
# smoke-hygiene-check — the smokes, harnesses and QEMU drivers find their siblings by ONE rule, never write into a
# sibling, and never share a fixed /tmp path or socket with another tree. check.sh gate 40 (1.57.14, the 1.57.13
# carried repair).
#
# ⛔ WHY. 1.57.13 repaired the SWEEP rows only; ~90 other smokes, ~40 harnesses and six QEMU drivers under
# scripts/tool + scripts/probe still carried the defects it fixed there, and nothing stopped the next one copying them:
#   (a) a sibling default of `$ROOT/../<repo>` (Python: os.path.join(ROOT, "../<repo>")). From a worktree $ROOT/.. is
#       .claude/worktrees/, which holds no sibling: the 1.57.12 sweep set SIBLINGS_ROOT, and the doom / naad rows that
#       read only their own variable failed in 7 s. Twenty-six harnesses read no variable at all.
#   (b) a QEMU socket at a fixed /tmp/agnos-*.sock: two trees running one harness bind ONE path, and a driver can talk
#       to the other tree's QEMU. (A socket under the smoke's WORK dir is the other half: a sweep worker copy's path
#       overflows the 108-byte sun_path — hid-mouse-deferred and pipeline VOIDed at 1.57.11 and 1.57.12.) The hash in
#       smoke_qsock / qsock is per-tree ONLY because its argument names the tree: qsock("agnos-mon.sock") is the same
#       path in every tree, the shared socket again.
#   (c) fixed /tmp/<name>.log build logs, shared by every tree the same way.
#   (d) a smoke building INSIDE a sibling (`cd "$X_ROOT" && cyrius build`) — writing build/, lib/, cyrius.lock, even a
#       tracked dist/ bundle (vani-tone's `cyrius distlib core`) into a repo agnos only reads.
# ⭐ PRIOR ART: Linux scripts/checkpatch.pl and tools/docs/documentation-file-ref-check — a lint that refuses a
# known-bad idiom at the line that introduces it, naming the fix; shellcheck's per-line rules (and its `# shellcheck
# disable=` per-line marker, the model for the two markers below). The rules are the ones the helpers document:
# scripts/smoke/lib/qemu-dwell.sh `smoke_qsock`, scripts/harness/_qsock.py, scripts/harness/_siblings.py (OpenSSH
# ControlPath %C / $XDG_RUNTIME_DIR for the sockets; stage-tools.sh's SIBLINGS_ROOT for the siblings).
#
# HOW IT READS. Shell: line text with comments stripped (quote-aware), plus a per-file assignment table
# (`[export|readonly|local|declare] VAR=…`, several per line). Python: the same line text for S1 / S3 / literal
# sockets, and the ast for S2 / S4 (assignments incl. tuple unpacking, function parameters traced to every call site
# and default, f-strings, `%`, `+` and `.format`). A docstring is text (S1 / S3 see it), never a socket sink.
# TREE-ROOTED: ROOT, and any variable EVERY assignment of which is built from a tree-rooted one (`"$ROOT/build/x"`,
# os.path.join(WORK, …), f"{ROOT}/…") or from mktemp / tempfile.mkdtemp (unique per run). File-wide, not scoped.
# THE RULES
#   S1 sibling default  — shell: `$ROOT/..` / `${ROOT}/..` / `"$ROOT"/..` except inside the allowed
#                         `${SIBLINGS_ROOT:-$ROOT/..}`; `dirname "$ROOT"`; any `../../..` (out of the tree from
#                         scripts/<group>/); a bare `$SIBLINGS_ROOT` / `${SIBLINGS_ROOT}` (unset, it names /<repo>).
#                         Python: os.path.join(ROOT, "..…") / ROOT + "/.." / dirname(ROOT) / f"{ROOT}/.." /
#                         os.pardir / Path(ROOT).parent / four `.parent`s / `../../..`; and os.environ.get("X_ROOT|
#                         X_BIN|X_DIR", default), which reads an exported-but-EMPTY X as "" (`${X:-…}` treats it as
#                         unset). The fix: `${<NAME>_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/<repo>}` /
#                         `sibling("<repo>", "<NAME>_ROOT")` / `os.environ.get("X_BIN") or os.path.join(sibling(…), …)`.
#   S2 socket           — a literal path under /tmp ending .sock/.socket; a literal `unix:…`; every `unix:` and every
#                         `path=` of a `socket` chardev / `addr.path=` whose value is not a variable EVERY assignment
#                         of which is `$(smoke_qsock "$<tree-rooted>/…")` / `qsock(<tree-rooted>)` (a path built ON a
#                         qsock'd variable, `unix:$Q/x`, is refused too); and every smoke_qsock / qsock call whose
#                         argument is not tree-rooted (the hash would be the same in every tree). Only tree-rooted calls
#                         count toward the floor. ONE marker: a QEMU driver handed its socket path as an argument writes
#                         `# socket path from scripts/<caller>` on the line, honoured only when that caller exists and
#                         itself binds through smoke_qsock / qsock(os.path.join(…)) (lockup-driver.py ← lockup-repro.sh).
#   S3 fixed /tmp path  — any other literal /tmp/<name> in code; `${TMPDIR:-/tmp}/<name>` and `$TMPDIR/<name>`; Python
#                         gettempdir() and a literal "/tmp" (mkdtemp / mkstemp / TemporaryDirectory / an XXX mktemp
#                         template are per-run and allowed). ONE marker: a path INSIDE the VM (typed at agnsh, written
#                         into a guest script) carries `# guest path` on its line.
#   S4 sibling write    — any `cyrius build|distlib|deps|init|update|test|bench`, `make`, `sh|bash …build….sh` or
#                         `./…build….sh` in the SCOPE of `cd "$<sibling var>"` (the rest of its subshell, to the next
#                         `cd` — so `&&`, `;`, and the cd-then-next-line forms alike); `cyrius build` with an output
#                         argument under a sibling; a sibling's `…build….sh` run by path; `make -C "$<sibling>"`.
#                         Python: a call with cwd= a sibling, os.chdir(sibling), ["cyrius","build",src,<sibling…>].
#                         A sibling var is ANY variable one assignment of which names SIBLINGS_ROOT / $SIBLINGS /
#                         $ROOT/.. / sibling(…), or starts from another sibling var. Copy the sources under build/
#                         first, as naad-ring3-smoke.sh / agnova-install-smoke.sh do. A message ("… (cd $X && cyrius
#                         build …)", any quoted string holding whitespace) is not a command.
# NOT SEEN (a text + ast lint, not an interpreter — the forms it does not follow, so a green is not a proof):
#   a socket path handed to another PROGRAM as an argument or environment variable (lockup-repro.sh → lockup-driver.py's
#   `--qmp`; the marker above covers the driver side only); eval / `sh -c "…"` strings and Python shell=True strings;
#   a cd in a function whose build runs after the function returns past an unrelated `)`; Python name tracking is
#   file-wide, not per-scope, and a parameter is traced only to direct calls by name in the same file; sockets QEMU
#   takes in a form other than `unix:` / socket `path=` (vhost-user `-device …,chardev=` reuses a chardev, which is
#   seen; a raw `-netdev …fd=` is not); scripts/burn/ (stage-*.sh --build builds inside siblings BY DESIGN — operator
#   staging) and the top-level scripts (build.sh / test.sh / bench.sh KASHI_DIR / REKHA_DIR defaults), outside the walk.
# WHICH FILES: every *.sh / *.py under scripts/smoke/, scripts/harness/, scripts/tool/ and scripts/probe/ (os.walk, so
# an un-added new one is covered).
# EXEMPT: the two helpers that DEFINE the rules — scripts/harness/_qsock.py, scripts/harness/_siblings.py (their
# docstrings quote the bad forms) — and they must exist (a deleted helper is a FAIL, not a skip).
# FLOORS (an enumeration that found almost nothing is VACUOUS, not clean): ≥ 180 files, ≥ 150 SIBLINGS-rule sites,
# ≥ 60 tree-rooted qsock sockets — measured 1.57.14 (review fix): 196 files, 199 sites, 70 sockets (+1 by a caller).
# MUTATION RECORD (1.57.14). First cut (smoke + harness only, regexes): the pre-conversion scripts/ scored 305 sites
# (178 S1, 47 fixed sockets + their 47 binds, 30 /tmp logs, 3 sibling builds); eight planted mutants each red on its
# line; planted in the tree (symlink-smoke.sh) check.sh scored this gate FAIL, file restored byte-identical (md5).
# Review fix (this form): the pre-conversion scripts/ score 327 sites over the four directories (187 S1, 107 S2,
# 30 S3, 3 S4 — the six tool/probe drivers' fixed sockets and `../gnoboot` / `../agnoshi` / `../anuenue` defaults
# among them). 67 planted files in a copy, each scored on its own: 47 that must be red ARE red on the planted line, 20
# legitimate forms stay green — the review's 21 missed forms (`unix:%s` % / + / .format / an inline f-expression,
# os.path.join("/tmp", …), gettempdir, f"{ROOT}/..", os.pardir, pathlib parent, `../../..` from HERE, cwd=sibling,
# a chardev path=, dirname "$ROOT", ${TMPDIR:-/tmp}/x, cd + next-line build, cd ; build, a build output in a sibling,
# a sibling's build.sh, a reassigned socket var, a bare $SIBLINGS_ROOT); the relative-qsock hole (qsock("x.sock"),
# smoke_qsock "x.sock", smoke_qsock "$N" with N a bare name); the review's false positives in their tree-rooted form
# (`MON="$(smoke_qsock …)"`, `export` / `readonly` / `local`, two assignments on a line, a tuple of qsocks, a socket
# parameter positional / keyword with a `=None` default, use before assignment, a chardev on a qsock'd var) and the
# two markers (honoured; refused when the named caller is missing or binds no qsock). The review's original FP probes
# whose WORK is never assigned are RED now by design (WORK is not tree-rooted there), and the unmarked guest-path
# probes are RED until they carry `# guest path`. (scratchpad r14/hyg-fix/mut2.py + mutants-new.log.)
# Usage: smoke-hygiene-check.sh [<tree>]   (default: this tree; a copy is how the mutation runs plant a site)
# Exit 0 clean · 1 a rule fired (file:line, rule, the line, the fix) or vacuous / unmeasurable.
set -u
TREE="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "smoke-hygiene-check: FAILED — no python3, measured NOTHING"; exit 1; }
exec python3 -I - "$TREE" <<'PYEOF'
import ast, os, re, shlex, sys
tree = sys.argv[1]
DIRS = ("scripts/smoke", "scripts/harness", "scripts/tool", "scripts/probe")
EXEMPT = ("scripts/harness/_qsock.py", "scripts/harness/_siblings.py")
MIN_FILES, MIN_SIB, MIN_QSOCK = 180, 150, 60
for e in EXEMPT:
    if not os.path.isfile(os.path.join(tree, e)):
        print("smoke-hygiene-check: FAILED — helper %s is missing (the rules it defines have no implementation)" % e)
        sys.exit(1)

def strip_comment(line, py):
    """The code part of one line: a '#' that starts a word (shell) / any '#' (Python) outside quotes ends it."""
    q = None; i = 0; n = len(line)
    while i < n:
        c = line[i]
        if q:
            if c == "\\" and q != "'": i += 2; continue
            if c == q: q = None
        elif c in "'\"":
            q = c
        elif c == "\\":
            i += 2; continue
        elif c == "#" and (py or i == 0 or line[i - 1] in " \t;(|&"):
            return line[:i]
        i += 1
    return line

files = []
for sub in DIRS:
    for dp, dn, fn in os.walk(os.path.join(tree, sub)):
        dn[:] = sorted(d for d in dn if d != "__pycache__")
        for f in sorted(fn):
            if f.endswith((".sh", ".py")):
                rel = os.path.relpath(os.path.join(dp, f), tree)
                if rel not in EXEMPT:
                    files.append(rel)

GUEST = re.compile(r'#.*\bguest path\b')          # S3's one per-line marker: the path is INSIDE the VM
ALLOWED_SIB = "${SIBLINGS_ROOT:-$ROOT/..}"
FIX_SH_SIB = '${<NAME>_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/<repo>}'
FIX_PY_SIB = 'sibling("<repo>", "<NAME>_ROOT") from scripts/harness/_siblings.py'
SH_SIB = [
    (re.compile(r'\$\{?ROOT\}?"?/\.\.'), "the tree's parent through $ROOT/.."),
    (re.compile(r'\bdirname\s+"?\$\{?ROOT\b'), "the tree's parent through dirname $ROOT"),
    (re.compile(r'\.\./\.\./\.\.(?=[/"\'\s)}]|$)'), "three levels up (out of the tree from scripts/<group>/)"),
    (re.compile(r'\$SIBLINGS_ROOT\b|\$\{SIBLINGS_ROOT\}'), "a bare $SIBLINGS_ROOT (unset or empty, it names /<repo>)"),
]
PY_SIB = [
    (re.compile(r'\bROOT\s*,\s*[rbuf]?["\']\.\.|\bROOT\s*\+\s*[rbuf]?["\']/\.\.|os\.path\.dirname\(\s*ROOT\s*\)'), "the tree's parent through ROOT"),
    (re.compile(r'\{ROOT\}/\.\.'), 'the tree\'s parent through f"{ROOT}/.."'),
    (re.compile(r'\bos\.pardir\b'), "os.pardir"),
    (re.compile(r'\bPath\(\s*ROOT\s*\)\s*\.parent\b|(?:\.parent){4}\b'), "a pathlib parent of the tree"),
    (re.compile(r'\.\./\.\./\.\.(?=[/"\']|$)'), "three levels up (out of the tree from scripts/<group>/)"),
    (re.compile(r'\bos\.environ\.get\(\s*[rbuf]?["\'][A-Z0-9_]+_(?:ROOT|BIN|DIR)["\']\s*,'),
     'os.environ.get(X, default): an exported-but-EMPTY X is "", not unset — os.environ.get(X) or default'),
]
TMP_SOCK = re.compile(r'/tmp/[^\s"\'`]*\.sock(et)?\b')
TMP_PATH = re.compile(r'(?<![\w$}])/tmp/[A-Za-z0-9_.@%+-]')
TMPDIR_PATH = re.compile(r'\$\{TMPDIR(?::?[-=][^}]*)?\}/[A-Za-z0-9_.@%+-]|\$TMPDIR/[A-Za-z0-9_.@%+-]')
PY_TMP = re.compile(r'\bgettempdir\s*\(|[rbuf]?["\']/tmp/?["\']')
PY_TMP_OK = re.compile(r'\bmk[ds]temp\b|\bTemporaryDirectory\b|\bNamedTemporaryFile\b|XXX')
SIB_VALUE = re.compile(r'\$\{SIBLINGS_ROOT:-|\$SIBLINGS\b|\$\{SIBLINGS\}|SIBLINGS_ROOT|\$\{?ROOT\}?"?/\.\.')
SH_ASSIGN = re.compile(r'(?:^|(?<=[\s;&|(]))(?:(?:export|readonly|local|declare(?:\s+-\w+)*)\s+)?([A-Za-z_]\w*)=')
SH_QSOCK_VAL = re.compile(r'"?\$\(\s*smoke_qsock\b')
SH_START_VAR = re.compile(r'"?\$\{?([A-Za-z_]\w*)')
SH_QSOCK_CALL = re.compile(r'\bsmoke_qsock\s+(?!\(\))(\S+)')
BUILD_CMD = re.compile(r'\bcyrius\s+(?:build|distlib|deps|init|update|test|bench)\b|(?:^|[\s;&|(])make(?:\s|$)'
                       r'|\b(?:sh|bash)\s+\S*build\S*\.sh\b|(?:^|[\s;&|(])\./\S*build\S*\.sh\b')
FIX_S4 = "copy the sources under build/ and build there (naad-ring3-smoke.sh)"

CALLER = re.compile(r'#.*\bsocket path from (scripts/[\w./-]+)')   # S2's one per-line marker: the path is an argument
bad = []; nsib = 0; nq = 0; ncaller = 0
def caller_ok(line):
    """`# socket path from <script>`: honoured only when <script> exists in the tree and binds through smoke_qsock / qsock."""
    m = CALLER.search(line)
    if not m:
        return False
    try:
        src = open(os.path.join(tree, m.group(1)), encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return re.search(r'\bsmoke_qsock\s+"\$|\bqsock\(os\.path\.join\(', src) is not None
def flag(rel, i, rule, line, fix):
    global ncaller
    if rule.startswith("S2 socket at") and caller_ok(line):
        ncaller += 1; return
    bad.append((rel, i, rule, line.strip(), fix))

def blank_msgs(l):
    # A quoted string holding whitespace is a message ("… not built — (cd $X_ROOT && cyrius build …)"), not a command;
    # "$VAR" alone stays, so the real `( cd "$X_ROOT" && cyrius build … )` is still seen.
    return re.sub(r'"[^"]*"', lambda q: '""' if re.search(r'\s', q.group(0)) else q.group(0), l)

def fixpoint(assigns, seed, ok):
    """Names every one of whose assignments satisfies ok(value, current set) — at least one assignment."""
    got = set(seed)
    while True:
        add = {n for n, vals in assigns.items() if n not in got and vals and all(v is not None and ok(v, got) for v in vals)}
        if not add:
            return got
        got |= add

# ----------------------------------------------------------------------------------------------------------- shell
def check_sh(rel, raw, code):
    global nsib, nq
    assigns = {}
    for i, l in enumerate(code, 1):
        for m in SH_ASSIGN.finditer(l):
            assigns.setdefault(m.group(1), []).append(l[m.end():])
    def start_var(v):
        m = SH_START_VAR.match(v)
        return m.group(1) if m else None
    rooted = fixpoint(assigns, {"ROOT"}, lambda v, got: start_var(v) in got or re.match(r'"?\$\(\s*mktemp\b', v) is not None)
    def qsock_rooted(v):
        m = SH_QSOCK_VAL.match(v)
        if not m:
            return False
        a = SH_QSOCK_CALL.search(v)
        return bool(a) and start_var(a.group(1)) in rooted and re.match(r'"?\$\{?\w+\}?/', a.group(1)) is not None
    qvars = {n for n, vals in assigns.items() if vals and all(qsock_rooted(v) for v in vals)}
    sibs = set()
    while True:                                                      # ANY sibling assignment counts (conservative)
        add = {n for n, vals in assigns.items() if n not in sibs and any(SIB_VALUE.search(v) or start_var(v) in sibs for v in vals)}
        if not add:
            break
        sibs |= add
    sibs.discard("ROOT")

    def sock_ref(rest, rule_line, i, what):
        mv = re.match(r'"?\$\{?([A-Za-z_]\w*)\}?', rest)
        if not mv:
            flag(rel, i, "S2 fixed socket", rule_line, "smoke_qsock (qemu-dwell.sh): VAR=$(smoke_qsock \"$WORK/<name>.sock\")")
            return
        var = mv.group(1); after = rest[mv.end():]
        if after.startswith("/"):
            flag(rel, i, "S2 socket path built from $%s" % var, rule_line, "bind the whole path through smoke_qsock")
        elif var not in qvars:
            why = "not from smoke_qsock" if var not in assigns else \
                  ("assigned from something other than a TREE-ROOTED smoke_qsock" if any(SH_QSOCK_VAL.match(v) for v in assigns[var])
                   else "not from smoke_qsock")
            flag(rel, i, "S2 socket at %s $%s: %s" % (what, var, why), rule_line, '%s=$(smoke_qsock "$WORK/<name>.sock")' % var)

    blanked = [blank_msgs(l) for l in code]
    for i, l in enumerate(code, 1):
        if not l.strip():
            continue
        line = raw[i - 1]
        nsib += l.count(ALLOWED_SIB)
        # S1
        l1 = l.replace(ALLOWED_SIB, "")
        for rx, what in SH_SIB:
            if rx.search(l1):
                flag(rel, i, "S1 sibling default (%s)" % what, line, FIX_SH_SIB); break
        # S2
        if TMP_SOCK.search(l):
            flag(rel, i, "S2 fixed socket", line, "smoke_qsock (qemu-dwell.sh)")
        else:
            for m in re.finditer(r'unix:', l):
                sock_ref(l[m.end():], line, i, "unix:")
            if re.search(r'\bsocket\b', l):
                for m in re.finditer(r'(?<![\w.])(?:addr\.)?path=', l):
                    sock_ref(l[m.end():], line, i, "path=")
        for m in SH_QSOCK_CALL.finditer(l):
            a = m.group(1)
            if start_var(a) in rooted and re.match(r'"?\$\{?\w+\}?/', a):
                nq += 1
            else:
                flag(rel, i, "S2 smoke_qsock argument not rooted in the tree", line,
                     'smoke_qsock "$WORK/<name>.sock" — the hash of a tree-relative name is the SAME in every tree')
        # S3
        if not GUEST.search(line) and "XXX" not in l and (TMP_PATH.search(l) or TMPDIR_PATH.search(l)):
            if not TMP_SOCK.search(l):
                flag(rel, i, "S3 fixed /tmp path", line, "the tree's build/ (or $WORK); a path inside the VM: `# guest path`")
        # S4 (the output of `cyrius build`, a sibling's build script, make -C) — per line
        b = blanked[i - 1]
        mb = re.search(r'\bcyrius\s+build\b(.*)', b)
        if mb:
            cmd = re.split(r'&&|\|\||[;|)>]', mb.group(1))[0]
            try:
                toks = [t for t in shlex.split(cmd) if not t.startswith("-")]
            except ValueError:
                toks = []
            for t in toks[1:]:
                if start_var(t) in sibs or t.startswith("${SIBLINGS_ROOT"):
                    flag(rel, i, "S4 cyrius build writes its output into a sibling", line, FIX_S4); break
        for m in re.finditer(r'"?\$\{?([A-Za-z_]\w*)\}?/[^\s"]*build[^\s"/]*\.sh\b', b):
            if m.group(1) in sibs:
                flag(rel, i, "S4 runs a sibling's build script", line, FIX_S4)
        for m in re.finditer(r'(?:^|[\s;&|(])make\b[^;&|]*-C\s*"?\$\{?([A-Za-z_]\w*)', b):
            if m.group(1) in sibs:
                flag(rel, i, "S4 make -C into a sibling", line, FIX_S4)
    # S4 — a build command anywhere in the scope of `cd "$<sibling>"`: the rest of its subshell / function / script,
    # until the next cd (the `;`, the next-line and the `( cd …` + newline forms all included)
    text = "\n".join(blanked)
    starts = [0]
    for l in blanked:
        starts.append(starts[-1] + len(l) + 1)
    def line_of(off):
        lo, hi = 0, len(starts) - 1
        while lo < hi - 1:
            mid = (lo + hi) // 2
            if starts[mid] <= off: lo = mid
            else: hi = mid
        return lo + 1
    for m in re.finditer(r'\bcd\s+"?\$\{?([A-Za-z_]\w*)', text):
        if m.group(1) not in sibs and m.group(1) != "SIBLINGS_ROOT":
            continue
        depth = 0; j = m.end(); end = len(text)
        nxt = re.compile(r'\bcd\s').search(text, m.end())
        if nxt:
            end = nxt.start()
        while j < end:
            c = text[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth < 0:
                    end = j; break
            j += 1
        mb = BUILD_CMD.search(text, m.end(), end)
        if mb:
            li = line_of(mb.start())
            flag(rel, li, "S4 builds inside a sibling (in the scope of `cd $%s`, line %d)" % (m.group(1), line_of(m.start())),
                 raw[li - 1], FIX_S4)

# ---------------------------------------------------------------------------------------------------------- python
def dotted(e):
    if isinstance(e, ast.Name):
        return e.id
    if isinstance(e, ast.Attribute):
        d = dotted(e.value)
        return d + "." + e.attr if d else None
    return None

def check_py(rel, raw, code):
    global nsib, nq
    for i, l in enumerate(code, 1):
        if not l.strip():
            continue
        line = raw[i - 1]
        nsib += len(re.findall(r'\bsibling\(', l))
        for rx, what in PY_SIB:
            if rx.search(l):
                flag(rel, i, "S1 sibling default (%s)" % what, line, FIX_PY_SIB); break
        if TMP_SOCK.search(l) or re.search(r'unix:["\']?/', l):
            flag(rel, i, "S2 fixed socket", line, 'qsock(os.path.join(WORK, "<name>.sock")) (_qsock.py)')
        elif not GUEST.search(line) and "XXX" not in l and (TMP_PATH.search(l) or (PY_TMP.search(l) and not PY_TMP_OK.search(l))):
            flag(rel, i, "S3 fixed /tmp path", line, "the tree's build/ (or WORK); a path inside the VM: `# guest path`")
    try:
        t = ast.parse("\n".join(raw), filename=rel)
    except SyntaxError as e:
        flag(rel, e.lineno or 0, "PARSE", str(e), "the gate reads Python with ast; fix the syntax"); return
    parents = {}
    for node in ast.walk(t):
        for ch in ast.iter_child_nodes(node):
            parents[ch] = node
    assigns = {}
    def bind(tg, val):
        if isinstance(tg, (ast.Name, ast.Attribute)):
            d = dotted(tg)
            if d:
                assigns.setdefault(d, []).append(val)
        elif isinstance(tg, (ast.Tuple, ast.List)):
            ok = isinstance(val, (ast.Tuple, ast.List)) and len(val.elts) == len(tg.elts) and \
                 not any(isinstance(x, ast.Starred) for x in tg.elts + val.elts)
            for k, x in enumerate(tg.elts):
                bind(x, val.elts[k] if ok else None)
        elif isinstance(tg, ast.Starred):
            bind(tg.value, None)
    funcs = []
    for node in ast.walk(t):
        if isinstance(node, ast.Assign):
            for tg in node.targets: bind(tg, node.value)
        elif isinstance(node, (ast.AnnAssign,)) and node.value is not None:
            bind(node.target, node.value)
        elif isinstance(node, ast.AugAssign):
            bind(node.target, None)
        elif isinstance(node, ast.NamedExpr):
            bind(node.target, node.value)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            bind(node.target, None)
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            for it in node.items:
                if it.optional_vars is not None: bind(it.optional_vars, None)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            funcs.append(node)
    # a parameter's values: its default and the argument at every call site of the function (by name, file-wide)
    calls = [n for n in ast.walk(t) if isinstance(n, ast.Call)]
    for fn in funcs:
        a = fn.args
        pos = a.posonlyargs + a.args
        defaults = dict(zip([p.arg for p in pos][len(pos) - len(a.defaults):], a.defaults))
        defaults.update({p.arg: d for p, d in zip(a.kwonlyargs, a.kw_defaults) if d is not None})
        # a `=None` default is "no socket", not a socket: the call sites decide (unix:None would bind nothing)
        defaults = {k: d for k, d in defaults.items() if not (isinstance(d, ast.Constant) and d.value is None)}
        for p in pos + a.kwonlyargs + ([a.vararg] if a.vararg else []) + ([a.kwarg] if a.kwarg else []):
            assigns.setdefault(p.arg, [])
            if p.arg in defaults:
                assigns[p.arg].append(defaults[p.arg])
        if a.vararg: assigns[a.vararg.arg].append(None)
        if a.kwarg: assigns[a.kwarg.arg].append(None)
        name = getattr(fn, "name", None)
        sites = [c for c in calls if name and ((isinstance(c.func, ast.Name) and c.func.id == name) or
                                               (isinstance(c.func, ast.Attribute) and c.func.attr == name))]
        if not sites and name:
            for p in pos + a.kwonlyargs:
                if p.arg not in defaults: assigns[p.arg].append(None)    # never called here: unknown
        for c in sites:
            off = 1 if isinstance(c.func, ast.Attribute) and pos and pos[0].arg in ("self", "cls") else 0
            if any(isinstance(x, ast.Starred) for x in c.args) or any(k.arg is None for k in c.keywords):
                for p in pos + a.kwonlyargs: assigns[p.arg].append(None)
                continue
            for k, x in enumerate(c.args):
                if k + off < len(pos): assigns[pos[k + off].arg].append(x)
            for kw in c.keywords:
                if kw.arg in assigns: assigns[kw.arg].append(kw.value)
    def rooted_expr(e, got):
        if isinstance(e, (ast.Name, ast.Attribute)):
            return dotted(e) in got
        if isinstance(e, ast.Call):
            f = dotted(e.func) or ""
            if f.endswith("mkdtemp"):
                return True                                          # unique per run: never shared across trees
            if f in ("os.path.join", "os.path.abspath", "os.path.realpath", "os.path.normpath") and e.args:
                return rooted_expr(e.args[0], got)
            return False
        if isinstance(e, ast.JoinedStr):
            return bool(e.values) and isinstance(e.values[0], ast.FormattedValue) and rooted_expr(e.values[0].value, got)
        if isinstance(e, ast.BinOp) and isinstance(e.op, ast.Add):
            return rooted_expr(e.left, got)
        return False
    rooted = fixpoint(assigns, {"ROOT"}, rooted_expr)
    def is_qsock(e):
        return isinstance(e, ast.Call) and (dotted(e.func) or "").split(".")[-1] == "qsock" and len(e.args) >= 1
    qvars = fixpoint(assigns, set(), lambda v, got: (is_qsock(v) and rooted_expr(v.args[0], rooted)) or
                     (isinstance(v, (ast.Name, ast.Attribute)) and dotted(v) in got))
    for c in calls:
        if is_qsock(c):
            if rooted_expr(c.args[0], rooted):
                nq += 1
            else:
                flag(rel, c.lineno, "S2 qsock argument not rooted in the tree", raw[c.lineno - 1],
                     'qsock(os.path.join(WORK, "<name>.sock")) — the hash of a tree-relative name is the SAME in every tree')
    def sock_ok(e):
        if is_qsock(e):
            return True                                              # its root is checked at the call (above)
        return isinstance(e, (ast.Name, ast.Attribute)) and dotted(e) in qvars
    def sink_bad(e, ln, what):
        d = dotted(e) if isinstance(e, (ast.Name, ast.Attribute)) else None
        why = ("%s is not from a tree-rooted qsock()" % d) if d else "an expression the gate cannot trace to qsock()"
        flag(rel, ln, "S2 socket at %s{…}: %s" % (what, why), raw[ln - 1],
             'NAME = qsock(os.path.join(WORK, "<name>.sock")) and %s{NAME}; an argument: `# socket path from <the caller>`' % what)
    def markers(s, sockety):
        out = [(m.start(), m.end(), "unix:") for m in re.finditer(r'unix:', s)]
        if sockety:
            out += [(m.start(), m.end(), "path=") for m in re.finditer(r'(?<![\w.])(?:addr\.)?path=', s)]
        return out
    for node in ast.walk(t):
        if isinstance(node, ast.JoinedStr):
            text = "".join(v.value for v in node.values if isinstance(v, ast.Constant) and isinstance(v.value, str))
            sockety = bool(re.search(r'\bsocket\b', text))
            for k, v in enumerate(node.values):
                if not (isinstance(v, ast.Constant) and isinstance(v.value, str)):
                    continue
                for a, b, what in markers(v.value, sockety):
                    if b == len(v.value):
                        nxt = node.values[k + 1] if k + 1 < len(node.values) else None
                        aft = node.values[k + 2] if k + 2 < len(node.values) else None
                        if not isinstance(nxt, ast.FormattedValue):
                            flag(rel, node.lineno, "S2 fixed socket", raw[node.lineno - 1], 'qsock(...)')
                        elif isinstance(aft, ast.Constant) and str(aft.value).startswith("/"):
                            flag(rel, node.lineno, "S2 socket path built from %s" % ast.unparse(nxt.value), raw[node.lineno - 1],
                                 "bind the whole path through qsock()")
                        elif not sock_ok(nxt.value):
                            sink_bad(nxt.value, node.lineno, what)
                    else:
                        flag(rel, node.lineno, "S2 fixed socket (a literal %s)" % what, raw[node.lineno - 1], 'qsock(...)')
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            par = parents.get(node)
            if isinstance(par, (ast.JoinedStr, ast.Expr)):
                continue                                             # f-string parts above; a docstring is not a socket
            s = node.value
            for a, b, what in markers(s, bool(re.search(r'\bsocket\b', s))):
                tail = s[b:]
                if tail == "" and isinstance(par, ast.BinOp) and isinstance(par.op, ast.Add) and par.left is node:
                    if not sock_ok(par.right): sink_bad(par.right, node.lineno, what)
                elif tail.startswith("%") and isinstance(par, ast.BinOp) and isinstance(par.op, ast.Mod) and par.left is node:
                    k = len([x for x in re.findall(r'%(?:%|\(\w+\)|[-#0 +]*\d*(?:\.\d+)?[a-zA-Z])', s[:a]) if x != "%%"])
                    r = par.right
                    arg = (r.elts[k] if k < len(r.elts) else None) if isinstance(r, ast.Tuple) else (r if k == 0 else None)
                    if arg is None or not sock_ok(arg): sink_bad(arg if arg is not None else r, node.lineno, what)
                elif tail.startswith("{") and isinstance(par, ast.Attribute) and par.attr == "format" and \
                        isinstance(parents.get(par), ast.Call) and parents[par].func is par:
                    call = parents[par]; fm = re.match(r'\{([^}:!]*)', tail).group(1)
                    if fm == "":
                        k = len(re.findall(r'(?<!\{)\{[:!}]', s[:a]))
                        arg = call.args[k] if k < len(call.args) else None
                    elif fm.isdigit():
                        arg = call.args[int(fm)] if int(fm) < len(call.args) else None
                    else:
                        arg = next((kw.value for kw in call.keywords if kw.arg == fm), None)
                    if arg is None or not sock_ok(arg): sink_bad(arg if arg is not None else call, node.lineno, what)
                else:
                    flag(rel, node.lineno, "S2 fixed socket (a literal %s, or a form the gate cannot trace)" % what,
                         raw[node.lineno - 1], 'NAME = qsock(os.path.join(WORK, "<name>.sock")) and f"%s{NAME}"' % what)
    # S4 — a sibling as a working directory, or as a cyrius build output
    def sib_expr(e, got):
        if isinstance(e, ast.Call):
            f = dotted(e.func) or ""
            if f.split(".")[-1] == "sibling":
                return True
            if f in ("os.path.join", "os.path.abspath", "os.path.realpath", "os.path.normpath") and e.args:
                return sib_expr(e.args[0], got)
            return False
        if isinstance(e, (ast.Name, ast.Attribute)):
            return dotted(e) in got
        if isinstance(e, ast.JoinedStr):
            return bool(e.values) and isinstance(e.values[0], ast.FormattedValue) and sib_expr(e.values[0].value, got)
        if isinstance(e, ast.BinOp) and isinstance(e.op, ast.Add):
            return sib_expr(e.left, got)
        if isinstance(e, ast.BoolOp):
            return any(sib_expr(x, got) for x in e.values)
        return False
    sibs = set()
    while True:                                                      # ANY sibling assignment counts (conservative)
        add = {n for n, vals in assigns.items() if n not in sibs and any(v is not None and sib_expr(v, sibs) for v in vals)}
        if not add: break
        sibs |= add
    for c in calls:
        f = dotted(c.func) or ""
        for kw in c.keywords:
            if kw.arg == "cwd" and sib_expr(kw.value, sibs):
                flag(rel, c.lineno, "S4 runs a command with a sibling as its cwd", raw[c.lineno - 1], FIX_S4)
        if f in ("os.chdir", "chdir") and c.args and sib_expr(c.args[0], sibs):
            flag(rel, c.lineno, "S4 chdir into a sibling", raw[c.lineno - 1], FIX_S4)
        if c.args and isinstance(c.args[0], (ast.List, ast.Tuple)):
            el = c.args[0].elts
            if len(el) >= 2 and all(isinstance(x, ast.Constant) for x in el[:2]) and el[0].value == "cyrius" and el[1].value == "build":
                pos = [x for x in el[2:] if not (isinstance(x, ast.Constant) and str(x.value).startswith("-"))]
                if any(sib_expr(x, sibs) for x in pos[1:]):
                    flag(rel, c.lineno, "S4 cyrius build writes its output into a sibling", raw[c.lineno - 1], FIX_S4)

for rel in files:
    py = rel.endswith(".py")
    try:
        raw = open(os.path.join(tree, rel), encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        bad.append((rel, 0, "READ", str(e), "")); continue
    code = [strip_comment(l, py) for l in raw]
    (check_py if py else check_sh)(rel, raw, code)

bad = sorted(set(bad), key=lambda b: (b[0], b[1], b[2]))
vacuous = len(files) < MIN_FILES or nsib < MIN_SIB or nq < MIN_QSOCK
where = " + ".join(DIRS)
if bad:
    print("smoke-hygiene-check: FAILED — %d site(s) in %s:" % (len(bad), where))
    for rel, i, rule, line, fix in bad:
        print("  %s:%d: %s: %s" % (rel, i, rule, line[:160]))
        if fix:
            print("      fix: %s" % fix)
if vacuous:
    print("smoke-hygiene-check: FAILED — VACUOUS: %d file(s) (floor %d), %d SIBLINGS-rule site(s) (floor %d), %d tree-rooted qsock socket(s) (floor %d)"
          % (len(files), MIN_FILES, nsib, MIN_SIB, nq, MIN_QSOCK))
if bad or vacuous:
    sys.exit(1)
print("smoke-hygiene-check: OK — %d files (%s), %d SIBLINGS-rule sites, %d tree-rooted qsock sockets (+%d passed in by a qsock caller); no $ROOT/.. default, fixed socket or /tmp path, or sibling build"
      % (len(files), where, nsib, nq, ncaller))
PYEOF
