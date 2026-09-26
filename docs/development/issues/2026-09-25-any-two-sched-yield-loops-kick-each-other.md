# 2026-09-25 — any two `sched_yield`#44 loops on two CPUs keep each other awake at IPI rate

**Status:** 🟡 **OPEN, FOR AN OPERATOR RULING.** This is the accepted residual of 1.57.8's `#44` directed kick, and
it is documented in ABI row 44 and `docs/architecture/blocking-waits.md`. It is not a defect of the change: the issue
that change closed requires it (its `yield_peer < 1 ms` gate).
**Filed by:** agnos, from the 1.57.8 ENDFIX step report (`open_problems[0]`, "The operator may want to rule on
it").
**Checked against:** agnos **1.57.8**, `kernel/core/sched.cyr` `sched_halt_window` and `sched_kick_parker`
(~:992).
**Severity:** CPU and power cost while two yield loops run. It is not a hang and returns no wrong result.

## What happens

A `#44` park publishes `cpu_kickable = 2`. If nothing is READY, it sends one `0xE1` kick to another CPU whose
value is 2. The kernel cannot tell whom a yielder waits for. Any two `#44` yield loops on two CPUs therefore wake
each other every ~100 µs (≈ 10k IPIs and syscalls per second per pair) for as long as both yield, including loops that
are unrelated to each other. `#14` pause does not take part (ENDFIX), so pause loops still sleep a whole interrupt.

Real pairs today:
- agnsh's `#44` bg-poll prompt beside a background job that itself loops on `#44`;
- agnoshi `run_agnos`'s waitpid + `#44` loop beside a foreground child that loops on `#44`.

## Options

1. Keep it. The cure is in userland: move poll+yield loops to blocking reads (`read`#5 a4 = 0, since 1.57.8) or to
   `waitpid` `WAIT_BLOCK` (`0x100 | pid`, since 1.57.7). agnoshi owns both of the loops above.
2. Credit productive work. A CPU whose park directly follows a kicked wake does not kick again unless its process did
   work in between. ENDFIX measured that this fails the `yield_peer` gate, because that benchmark's rounds do no work.
3. Give userland a directed yield towards a peer (a new number), so the kernel knows whom to kick.

## Gate (for whichever ruling)

Two unrelated `#44` idle loops at `-smp 4` for 300 ms. Under options 2 or 3, `sched_kicks` must stay bounded.
Under option 1, the agnoshi loops must be converted and measured with `bench-ring3` `yield_idle`.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/ENDFIX-report.json`, `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/PIPE-endreview.json` (PIPE-R1).
