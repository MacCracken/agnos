# 29 of 30 ring-3 test harnesses boot a PREBUILT exerciser and never check it is current — OPEN

**Status:** OPEN. ⚠ **The count in the title was 26 and is 29** — `puka-child-stdout` and `puka-terminal`
only existence-check a sibling binary, which is not a freshness check. Measured at 1.57.1:
`grep -l getmtime scripts/harness/*.py` matches ONE file out of 30.

✅ **1.57.1 fixed five instances and widened the template:** `console-line-smoke.sh` (⭐ a SCORED
SWEEP GATE that booted a fossil — `run_gate` rebuilds `build/agnos` and then the gate scored an image
built from a different kernel; measured live at a full day of drift), `chan-ring3-smoke.sh` (now
builds its own kernel), `launcher-panel-test.py` (copied its base image ONCE, then never again —
21 days behind), and freshness guards for `mountlist-test.py` and `readdir-at-test.py`, **the two
harnesses that produced ship evidence for 1.56.59/1.56.60**.

⭐ **AND THE TEMPLATE CHANGED, which matters more than the five:** `telemetry-test.py`s guard
watched `tlm.cyr` ALONE. A toolchain pin change rewrites the vendored `lib/`, so a binary from a
different compiler scored as fresh. Every guard now watches **all build inputs** — `*.cyr`,
`lib/*.cyr` and `cyrius.cyml`. ⛔ Any of the remaining ~24 guards written with the one-`.cyr` shape
inherits the hole.

⛔ **THE PREBUILT-IMAGE SUB-CLASS, WHICH THIS FILE NEVER NAMED AND IS THE WORST:** six harnesses boot
a whole frozen image — kernel, agnsh and every staged tool together — with measured drift of 1, 21
and 38 days. An exerciser guard does not touch it.

⚠ **The 10 rootfs-staged harnesses need an operator design decision before they can be written:** this
files own rule forbids auto-building siblings, while `scripts/burn/burn-prep.sh` already implements
the right staleness derivation and no harness calls it. Decide the shape first — 10 harnesses inherit
it. ⛔ And "needs no shared infrastructure" was true at one instance and is the wrong call at 29: a
`scripts/harness/_freshness.py` helper is the right shape.

⛔ **AND IT IS NOT JUST THE EXERCISER — IT IS THE KERNEL.** Every harness here also resolves
`AGNOS = ROOT/build/agnos` as a prebuilt path and never runs `scripts/build.sh`. A second mutation
campaign, run after fixing the exerciser staleness, re-introduced two KERNEL defects and still got
`exit 95 / PASS` on every mutant — because the edits to `kernel/core/block.cyr` and
`kernel/arch/x86_64/pic.cyr` were never compiled. **Every one of these harnesses exists to test
kernel behaviour, so a stale `build/agnos` makes the whole result a fiction.** The 1.56.60 fix now
guards both: the exerciser against its own source, and `build/agnos` against the newest mtime under
`kernel/**/*.cyr`.

**Found:** 2026-09-03, the hard way, while repairing the two telemetry defects chakshu reported.
I edited `tests/telemetry/tlm.cyr` to add two new assertions, ran the harness **four times** — once
as a baseline and three times with a kernel defect deliberately re-introduced — and got a confident
`exit 95 / PASS` from every single run. The assertions were never in the binary that booted.

---

## The mechanism

`scripts/harness/telemetry-test.py` resolves the exerciser as a **path to an artifact**:

```
TLM = os.path.join(ROOT, "tests/telemetry/build/tlm")
...
for need in (AGNOS, GNOBOOT, ROOTFS, TLM):     # existence check only
```

It never invokes `cyrius build`. `tests/telemetry/build/tlm` is produced by a **separate** command
(`cyrius build --agnos tlm.cyr build/tlm`, or `scripts/burn/stage-tools.sh`). Nothing ties the two
together, so the harness happily seeds a months-old binary into a fresh image and reports on it.

Measured: source `tlm.cyr` at **21:16**, binary `build/tlm` at **01:11** — a 20-hour-old artifact,
scored PASS four times in a row, including on runs whose entire purpose was to FAIL.

⚠ **This is strictly worse than an absent gate.** An absent gate is silent. This one actively
certifies the change you did not run, in the exact moment you are trusting it most — a mutation test.

## Why it survived

The repo has already been bitten by this shape one layer down and fixed it there. `stage_one` in
`scripts/burn/stage-tools.sh` carries a long ⛔ comment about `tests/gpu/build/` holding 51 TRACKED
binaries, so a stage could copy "whatever artifact was in git — i.e. whatever source existed when
someone last ran a compiler", and names the precedent: `edgeasm` printed `B4 PASS` from a committed
fossil while `edgeasm.cyr` **could not compile at all**. The fix there was to gitignore the binaries
and auto-build on absence.

⇒ **Auto-build-on-ABSENCE does not cover STALENESS.** The binary is present; it is just old. The
harnesses inherited the hole that fix left open.

## Scope

Neither builds nor checks staleness (26): `ae-resize-fault`, `ae-theme-repaint`, `ae-wallpaper-load`,
`aethersafha-clients`, `agnsh-bg`, `agnsh-bg-smp4`, `agnsh-delegation`, `agnsh-kvm`, `agnsh-multijob`,
`agnsh-type`, `agnsh-verb`, `console-line-preserve`, `crab-listing-cap`, `crab-resize`, `doom-input`,
`hid-cc-inject`, `hid-halt-oracle`, `hid-mouse-deferred`, `hid-wheel`, `launcher-panel`, `mountlist`,
`pipe-stream`, `puka-resize`, `readdir-at`, `run37-smp4`, `sweep`.

Already build their exerciser (3): `pty-host`, `puka-child-stdout`, `puka-terminal`.
Fixed at 1.56.60 (1): `telemetry` — refuses to run when the binary is older than its source.

⚠ **`mountlist` and `readdir-at` matter most right now**: both were used as ship evidence for
1.56.59/1.56.60 (`mlist`/`rdat` "exit 95" appears in the iron burn record), and neither can tell you
whether the binary it booted matched the source at the time.

## Fix

The 1.56.60 shape is six lines and needs no shared infrastructure:

```python
if os.path.getmtime(BIN) < os.path.getmtime(SRC):
    print("FAIL: <bin> is OLDER than <src> — the exerciser was edited but never rebuilt.")
    sys.exit(2)
```

Better, if it is cheap in each harness: build the exerciser outright, like `pty-host` does. Then the
question cannot arise. ⚠ Any auto-build must stay **scoped to in-tree `agnos/tests/*`** — the
`stage_one` comment explains why widening it to siblings is wrong: each sibling pins its own cyrius,
and building one here compiles it against a toolchain that repo never declared.

⛔ **Do not "fix" this by committing the binaries.** That is the fossil the 1.56.44 change removed.
