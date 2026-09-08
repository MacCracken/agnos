"""Shared staleness guards for the ring-3 test harnesses.

⛔ WHY THIS EXISTS. Measured 2026-09-03 and again at 1.57.1: 29 of the 30 harnesses in this
directory resolved their exerciser AND `build/agnos` as PATHS TO PREBUILT ARTIFACTS and never
checked either was current. Editing a `.cyr` and re-running scored a confident PASS against a
binary compiled hours or weeks earlier — and four consecutive mutation runs, each deliberately
re-introducing a kernel defect, all reported `exit 95` because the assertions meant to catch them
were not in the binary under test.

⚠ A GATE THAT SILENTLY TESTS YESTERDAY'S ARTIFACT IS STRICTLY WORSE THAN AN ABSENT ONE. An absent
gate is silent; this one actively certifies the change you did not run, in the moment you are
trusting it most.

⭐ THE 1.57.1 TEMPLATE LESSON: watch ALL BUILD INPUTS, not just the one `.cyr`. The first guard
written (telemetry-test.py, 1.56.60) watched `tlm.cyr` alone — and a toolchain pin change rewrites
the vendored `lib/`, so a binary from a DIFFERENT COMPILER scored as fresh. `exerciser_sources()`
below is the corrected set; use it rather than hand-rolling a source list.

⛔ REFUSING IS NOT THE SAME AS BUILDING, and only one of them needs an operator ruling.
`refuse_stale()` never builds anything — it fails loudly and tells you the command. That is safe
for EVERY harness, including ones whose artifact comes from a sibling repo, because it does not
compile a sibling against a toolchain that repo never declared (the hazard `stage_one` in
scripts/burn/stage-tools.sh documents at length). Auto-building is the part that needs a decision;
this module deliberately does not offer it.
"""

import glob
import os
import sys


def _newest(paths):
    """Newest mtime among paths that exist. 0.0 when none do."""
    best = 0.0
    for p in paths:
        try:
            m = os.path.getmtime(p)
            if m > best:
                best = m
        except OSError:
            pass
    return best


def exerciser_sources(project_dir):
    """Every build input for an in-tree `tests/<x>/` exerciser.

    ⚠ Includes cyrius.cyml and lib/*.cyr on purpose — see the template note above.
    """
    return (glob.glob(os.path.join(project_dir, "*.cyr"))
            + glob.glob(os.path.join(project_dir, "lib", "*.cyr"))
            + [os.path.join(project_dir, "cyrius.cyml")])


def kernel_sources(root):
    """Every `.cyr` under kernel/ — the build inputs for build/agnos."""
    out = []
    for d, _sub, files in os.walk(os.path.join(root, "kernel")):
        for n in files:
            if n.endswith(".cyr"):
                out.append(os.path.join(d, n))
    return out


def refuse_stale(binary, sources, what, howto, exit_code=2):
    """Exit `exit_code` when `binary` is older than the newest of `sources`.

    ⚠ No-ops when the binary is absent — absence is a DIFFERENT failure and each harness already
    reports it in its own words. This guard is only about STALENESS.
    ⚠ Also no-ops when no source exists, rather than guessing: a missing source tree means this
    check has nothing to say, and a guard that fires on "I could not measure" trains people to
    ignore it.
    """
    if not os.path.exists(binary):
        return
    newest = _newest(sources)
    if not newest:
        return
    if os.path.getmtime(binary) >= newest:
        return
    print(f"FAIL: {binary} is OLDER than its {what} — it was edited but never rebuilt.")
    print("      Whatever you just changed is ABSENT from the artifact this would boot,")
    print("      so a green result here would be about a different build entirely.")
    print(f"      Rebuild with: {howto}")
    sys.exit(exit_code)


def refuse_stale_kernel(root, agnos_path=None):
    """The check every harness needs: build/agnos vs kernel/**/*.cyr.

    ⛔ THIS IS THE BIGGER HALF. Every harness here exists to test KERNEL behaviour, so a stale
    build/agnos makes the entire result a fiction — the exerciser guard alone does not help.
    """
    agnos = agnos_path or os.path.join(root, "build", "agnos")
    refuse_stale(agnos, kernel_sources(root),
                 "kernel sources (kernel/**/*.cyr)", "sh scripts/build.sh")


def refuse_stale_image(image, deps, howto):
    """A whole prebuilt disk image vs the things baked into it.

    ⛔ THE WORST SUB-CLASS AND THE ONE THE ORIGINAL ISSUE NEVER NAMED: six harnesses boot a frozen
    image carrying the kernel, agnsh and every staged tool at once, with measured drift of 1, 21 and
    38 days against a same-day build/agnos. Nothing about an exerciser check touches that.
    """
    refuse_stale(image, deps, "contents (kernel / staged rootfs)", howto)
