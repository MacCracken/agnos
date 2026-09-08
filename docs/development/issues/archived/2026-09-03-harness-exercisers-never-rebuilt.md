# Ring-3 test harnesses booted prebuilt artifacts and never checked they were current — RESOLVED

**Status:** RESOLVED in agnos **1.57.1**. **30 of 30 harnesses now carry a freshness guard** — the
count was 1 of 30 when this was filed and when it was re-measured at 1.57.1.

## What shipped

- ⭐ **`scripts/harness/_freshness.py`** — the shared helper the issue's own "needs no shared
  infrastructure" line was wrong about. That was true at one instance and the wrong call at thirty:
  hand-rolling it 29 more times is how 29 guards get built with the same hole.
- **`refuse_stale_kernel()` on 24 harnesses.** ⛔ THE BIGGER HALF: every one of these exists to test
  KERNEL behaviour and resolved `build/agnos` as a bare path, so a stale kernel made the whole result
  a fiction — measured, when four consecutive mutation runs each re-introducing a real kernel defect
  all reported `exit 95`.
- **Exerciser guards** watching **every build input** (`*.cyr`, `lib/*.cyr`, `cyrius.cyml`), not just
  the one `.cyr`. The first guard written (1.56.60) watched `tlm.cyr` alone, and a toolchain pin
  change rewrites the vendored `lib/` — so a binary from a *different compiler* scored as fresh.
- ⭐ **The prebuilt-IMAGE class, which this file never named and which is the worst of them** — six
  harnesses boot a frozen image carrying kernel, agnsh and every staged tool at once, with measured
  drift of 1, 21 and 38 days. Neither an exerciser nor a kernel check touches it; they now compare
  the image against `build/agnos` directly.
- **Five specific fossils fixed**, including `console-line-smoke.sh` — a **scored sweep gate** that
  built its image only when ABSENT, so `run_gate` rebuilt the kernel and then scored an image made
  from a different one.

## Verified both ways, not asserted

- **No false fire:** with the tree fresh, `mountlist-test.py` runs to `exit 95`.
- **It bites:** `touch kernel/core/proc.cyr` without rebuilding, and `mountlist`, `readdir-at`,
  `telemetry`, `hid-halt-oracle` and `sweep` all refuse with `is OLDER than its kernel sources`;
  `agnsh-type` and `doom-input` refuse on the image path.

## ⚠ What was deliberately NOT built, and why it needs no ruling after all

The issue said the rootfs-staged harnesses were **blocked on an operator design decision** about
auto-building siblings. ⭐ **That blocker dissolves once you separate refusing from building.**
`refuse_stale()` never compiles anything — so it is safe for *every* harness including sibling-built
artifacts, because it cannot compile a sibling against a toolchain that repo never declared (the
hazard `stage_one` in `scripts/burn/stage-tools.sh` documents at length). Auto-building remains a
convenience question and an open one; **correctness is closed.**

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
