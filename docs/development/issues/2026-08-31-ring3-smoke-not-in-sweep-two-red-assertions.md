---
name: ring3-smoke is not in sweep.sh and has been red
description: "ring3-smoke.sh carries the only regression test for proc_alloc_slot's reuse scan, is absent from the sweep table, and has one deterministic failure plus one flaky timing assertion"
type: issue
---

# `ring3-smoke.sh` is not in `sweep.sh`, and it has been failing

**Status:** 🟡 **OPEN.** Two separate problems: a gate that is not run, and two assertions inside it
that do not pass when it is.
**Found:** 2026-08-31 (1.56.55), while verifying that the `proc_alloc_slot` zombie guard did not break
slot reuse — the regression test for that change turned out not to be in the sweep.
**Severity:** **Medium.** Nothing is newly broken. But the kernel's process-table allocator, the
ring-3 preempt gate and `sched_yield`#44 have no gate anyone runs.

## 1. The gate is not in the sweep table

`scripts/sweep.sh` has 26 `run_gate` rows and **none of them is `ring3-smoke.sh`**. That smoke asserts
things nothing else does:

- `ring3: nonlifo reuse OK` — **the only regression test for `proc_alloc_slot`'s reuse scan**, the
  code changed at 1.56.55 to stop reusing an exited-but-unreaped child's slot.
- `ring3: nonlifo signal clear OK` — a recycled slot does not inherit pending signals.
- a ring-3 parent `spawn`#3-ing a child ELF and `waitpid`#4-ing it entirely from ring 3.
- ≥8 concurrent ring-3 procs (the PD[8..63] VA-collision fix).
- the ring-3 preempt gate, and `sched_yield`#44's slice donation.

⇒ The 1.56.55 allocator change was verified only because it was run **by hand**. A gate that exists
and is never invoked is worth about as much as one that cannot fail — the class this cut spent most of
its time removing.

## 2. `ring3: gate held` fails deterministically, and does so on HEAD

```
FAIL: 'ring3: gate held' not found — preempt gate regression for ring-3
```

⭐ **Measured on an unmodified tree**, not just a patched one: `git stash push -- kernel/`, rebuild,
run — same failure. It reproduced on every run of both kernels (4 runs modified, 1 baseline). So this
is **pre-existing**, not fallout from the 1.56.55 reap/alloc work, and it has presumably been red for
as long as the gate has been out of the sweep. Nobody was looking.

⚠ **Do not assume it is stale-test-versus-good-code or the reverse.** The repo's own rule applies
here verbatim: *"when a gate has been red long enough to be described rather than fixed, re-derive
what it asserts against the code before carrying the number forward."* Neither half has been
re-derived. The marker is `ring3: gate held`; the assertion is about the ring-3 preempt gate.

## 3. `ring3: yield OK` is FLAKY, on HEAD too

It is a timing assertion — the non-yielder's counter must exceed the yielder's by >10x — so it is
sensitive to host load, and this box runs QEMU continuously.

| tree | runs | yield result |
|---|---|---|
| 1.56.55 (reap/alloc changes) | 3 | 1 PASS / 2 FAIL |
| HEAD (unmodified) | 3 | 2 PASS / 1 FAIL |

⛔ **Both flake.** The difference is not meaningful at n=3 under load, and the first HEAD sample alone
would have supported the wrong conclusion — that the allocator change broke `sched_yield`. It did not.
⭐ Worth keeping as method: a single baseline run is not a baseline for a flaky assertion.

## What to do

1. **Decide the `gate held` question first**, by re-deriving the assertion against the code. Adding
   the smoke to `sweep.sh` while it fails deterministically would turn the arc sweep red for a reason
   unrelated to whatever cut is in flight — and a permanently-red sweep is how gates get ignored.
2. **Make `yield OK` non-flaky or explicitly tolerant.** A ratio assertion on a loaded host needs
   either a retry-with-quorum shape or a bound derived from something other than wall-clock racing.
3. **Then add it to `sweep.sh`**, so the allocator, the preempt gate and `#44` are covered by the one
   command that is actually run.

⚠ Deliberately **not** done as part of 1.56.55: adding a knowingly-red gate to the sweep on release
eve is a scope call for the operator, and fixing the preempt-gate assertion needs the re-derivation in
step 1, which is its own piece of work.

## Related

- [`2026-08-05-syscall-96-fork.md`](2026-08-05-syscall-96-fork.md) — the same cut found `fork-smoke.sh`
  passing on `sweep.sh`'s retry rather than on its subject, and 13 SKIP guards across six smokes
  scoring a missing prerequisite as a PASS. This file is the third face of that: a gate nobody runs.
