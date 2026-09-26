# 2026-09-25 — any two `sched_yield`#44 loops on two CPUs keep each other awake at IPI rate

**Status:** ✅ **RESOLVED 1.57.9 (2026-09-26)** — operator ruling option 1 (directed yield). `sched_yield`#44 is a quiet, local yield again (no cross-CPU kick); the new `sched_yield_to`#108 hands off to, and kicks only the CPU of, a NAMED peer (self, an epoch-valid child or parent). Gate: `ipc-wait-smoke` (two unrelated `#44` loops at `-smp 4` for 300 ms: 0 kicks — with the kick restored, mutation M1: 4,679; `yield-peer` through `#108`: ~0.13 ms per round at `-smp 4`; `yield-handoff`: 148 µs). See § Resolution.
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

## Resolution (1.57.9, 2026-09-26)

Shipped as the operator's option 1. Prior art followed: Linux `sched_yield` (`do_sched_yield`, local runqueue only, and its
man-page warning against waiting with it), Linux `yield_to` → `set_next_buddy` (the handoff) and KVM's directed yield, Mach
`thread_switch`, FreeBSD `sched_relinquish`. `#44` sends no IPI; `#108` hands off when the peer is READY on the caller's CPU and
kicks the peer's CPU only when the peer is parked in a yield. ABI rows 44 and 108; `docs/architecture/blocking-waits.md`.

What it broke: by the ruling, a `#44` poll loop beside a peer RUNNING on another CPU costs up to one timer tick per round again.
The two such loops in agnoshi (the background-job prompt poll, `run`/pipeline reaping) are filed in agnoshi as
`docs/development/issue/2026-09-26-poll-and-yield-loops-should-block.md` (move them to `read` a4 = 0 / `WAIT_BLOCK`).
cyrius needs `SYS_SCHED_YIELD_TO` = 108 (peer filing); the ABI gate is red for #106/#107/#108 until then.
