# 26 of 30 ring-3 test harnesses boot a PREBUILT exerciser and never check it is current — OPEN

**Status:** OPEN. One instance fixed (`scripts/harness/telemetry-test.py`, 1.56.60); the class is not.

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
