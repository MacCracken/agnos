"""The ONE source of the kernel's latched-invariant deny pattern for the Python harnesses (agnos 1.57.7, S3d).

⛔ WHY THIS EXISTS. `SMOKE_INVARIANT_DENY` (scripts/smoke/lib/qemu-dwell.sh) lists the kernel's LATCHED invariant
lines — each prints once per boot to klug + COM1 and changes no exit code, so a gate that does not grep for them
scores PASS while they fire. The shell smokes source it. Until 1.57.7 the three Python harnesses that deny it
(agnsh-bg-smp4, run37-smp4, agnsh-multijob) each carried a PASTED COPY, and every step that added an alternative had
to remember four places: a copy that drifts silently stops denying the new line in exactly the harness that would
have caught it. This loader reads the definition itself, so there is no copy left to drift. New harnesses MUST use it.

⚠ The shell side keeps its contract (PLAN §5.7): ONE double-quoted `SMOKE_INVARIANT_DENY="..."` assignment on ONE
line. A continuation line or a second assignment would silently drop alternatives here — so this loader REFUSES
(raises SystemExit, the harness exits non-zero) when the line is missing, empty, or not a single quoted value.
Usage:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _invdeny import smoke_invariant_deny
    INV_DENY = smoke_invariant_deny()          # a Python-re-compatible alternation (the patterns are plain text)
"""

import os
import re

_QD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "smoke", "lib", "qemu-dwell.sh")


def smoke_invariant_deny(path=None):
    """The double-quoted value of qemu-dwell.sh's `SMOKE_INVARIANT_DENY=` line. Exits the harness (3) if absent."""
    p = path or _QD
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        raise SystemExit(f"FAIL: _invdeny: cannot read {p}: {e} — the deny pattern is unknown, nothing was denied")
    hits = [ln for ln in lines if ln.startswith("SMOKE_INVARIANT_DENY=")]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: _invdeny: {p} has {len(hits)} SMOKE_INVARIANT_DENY= lines (want exactly 1)")
    m = re.fullmatch(r'SMOKE_INVARIANT_DENY="([^"]+)"\s*', hits[0])
    if not m:
        raise SystemExit(f"FAIL: _invdeny: the SMOKE_INVARIANT_DENY line in {p} is not ONE double-quoted value")
    return m.group(1)


if __name__ == "__main__":
    print(smoke_invariant_deny())
