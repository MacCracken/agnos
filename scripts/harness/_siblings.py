"""_siblings.py — where a harness finds a sibling repo (1.57.14): the Python twin of the smokes' sibling rule.

ONE rule for every smoke, harness and tool (scripts/burn/stage-tools.sh, scripts/check/syscall-abi-check.sh, the
1.57.13 doom / naad-ring3 fix, and every smoke since 1.57.14):

    <NAME>_ROOT if it is set and non-empty, else ${SIBLINGS_ROOT:-<this tree>/..}/<repo>

⛔ WHY: from a worktree, <this tree>/.. is .claude/worktrees/, which holds no sibling. A harness that defaulted to
os.path.join(ROOT, "../gnoboot") failed in seconds with "missing ..." unless the operator exported that harness's own
variable — and most of them read no variable at all (GNOBOOT = os.path.join(ROOT, "../gnoboot/..."); the CRAB_BIN /
AE_BIN / PUKA_BIN fallbacks the same), so GNOBOOT_ROOT and SIBLINGS_ROOT were silently ignored. The 1.57.12 sweep's
run set SIBLINGS_ROOT alone, and the doom / naad rows that read only their own variable failed exactly that way.
⚠ Empty counts as unset, as `${X:-…}` does in the shell: os.environ.get("X", default) returns "" for an exported
X= and the path then resolves relative to the cwd.
⛔ A sibling is READ-ONLY to agnos: a harness reads a built binary out of it and never builds or writes there (a smoke
that must build a sibling's source copies it under this tree's build/ first, as naad-ring3-smoke.sh does).
scripts/check/smoke-hygiene-check.sh (check.sh gate 40) refuses any other sibling default in scripts/harness.
"""
import os

_TREE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def siblings_root():
    """${SIBLINGS_ROOT:-<this tree>/..}"""
    return os.environ.get("SIBLINGS_ROOT") or os.path.join(_TREE, "..")


def sibling(repo, var=None):
    """The root of sibling repo <repo>: $<var> when set and non-empty, else ${SIBLINGS_ROOT:-<tree>/..}/<repo>."""
    if var and os.environ.get(var):
        return os.environ[var]
    return os.path.join(siblings_root(), repo)
