# 2026-09-23 — `sleep_ms`#41 holds the CPU: nothing else runs while a process sleeps

**Status:** ✅ **RESOLVED 1.57.7 (2026-09-25)** — steps S3c (+ S3b-F2 for `execwait`#37 children): `sleep_ms`#41 blocks only its caller (`#99` state 6) on the Path 2 wq primitive; every other process runs meanwhile. Gate: `scripts/smoke/wait-ring3-smoke.sh` (sweep row; waitx P1–P3b, the P2 share phase, and P13 flipped to `WAITX-OK ew37 block` at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). A supervisor sleeps between polls of its children.
**Checked against:** agnos **1.57.5**: the `#41` arm in `kernel/core/syscall.cyr`, the `#14` path in
`kernel/arch/x86_64/syscall_hw.cyr` and `sys_sched_yield` in `kernel/core/sched.cyr`, read in the
working tree. The cyrius peer (`lib/syscalls_x86_64_agnos.cyr`) routes both `sys_sleep_ms` and
`sys_nanosleep` to `#41`, and `lib/chrono.cyr`'s `sleep_ms` calls it.
**Consumer impact:** any program that sleeps while another process should be running. On agnos, a
supervisor that sleeps between `waitpid`#4 polls never sees its child finish, because the child does
not run.

> The `#41` arm disables preemption for the whole sleep (`preempt_disable(); sti;` then `arch_wait()`
> until the tick target). Its comment records why: *"we can't be preempted off mid-sleep on this
> single core"*, written for the no-preempt ring-3 model. Background jobs have time-sliced since
> 1.44.x, so a sleeping process now freezes every other runnable process for the length of its sleep.
> `pause`#14 already does the right thing: it yields to a ready process first (`sys_sched_yield`),
> and halts only when nothing else is ready.

---

## Measured

daimon's guest test boots 1.57.5 under QEMU. The test program (in the `/bin/agnsh` slot) starts agents
with `spawn_path`#43 and waits for them.

- **Waiting with `sleep_ms`#41 (10 ms polls):** 7 assertions failed, and the run then hung in its
  last section, printing no summary within 120 s. (The fixture agents also looped on `sleep_ms` in
  that run.)
  - A child that had been sent SIGTERM did not run until the parent had given up on it; its own
    `AGENT user argv` line appeared in the console after the parent's failure lines.
  - A child that exits at once was not collected in 3 s.
- **Waiting with `pause`#14 until the same deadline:** 31 of 31 passed, and the first child's SIGTERM
  handling and exit were collected within the grace period.

## The ask

- Let `#41` block only its caller: mark the process waiting until its tick target, and schedule
  others meanwhile, as `pause`#14 does when something is ready.
- Keep the IF=1 window, so the tick still advances when nothing else is ready.
- If some callers rely on the no-switch behaviour, a separate "pace without yielding" call would keep
  them working, and let `sleep_ms` mean what its name says.

## What daimon does meanwhile

daimon 2.4.0 waits with its own `daimon_yield_ms`, a loop of `pause`#14 until the deadline, wherever
it used `sleep_ms`/`nanosleep`. sandhi's accept loop does not sleep on agnos: `EAGAIN` from the
non-blocking `#57` is retried at once. So it spins instead, which starves other processes too. daimon
2.4.0 replaces that loop on agnos with its own.

## Resolution (1.57.7, 2026-09-25)

**What shipped:** the voluntary switch (`int 0xE0`), the BLOCKED state and the wq wait/wake primitive (S3.4);
`sleep_ms` on it (S3.5). The sleep lasts ≥ `ms` by `uptime_us`#95, up to one 10 ms tick longer (deadlines expire
at the first tick at or after them); S3d's `0xE1` kick wakes a remote pinned sleeper. Callers that cannot block
(before the scheduler: DOOM's pacing, exec-smoke's `/bin/timetest`) keep the CPU-holding loop, whose deadline is
in `uptime_ms`#40, which S1b put on the TSC. Since S3b-F2 an `execwait`#37 child is an ordinary scheduled process
and blocks like any other. There is no "pace without yielding" call: a caller that must hold its CPU spins on
`#95`. ABI rows 14/41/44.

**What the change broke — checked before archiving:** (1) S3d's park (the other half of the blocking model) makes a
cross-CPU poll+`sched_yield`#44 round cost one tick (`yield_peer` `-smp 4`: 9.9 ms vs 531 µs) — filed for 1.57.8 as
`2026-09-25-cross-cpu-poll-and-yield-loops-are-tick-bound.md` (OPEN). (2) The legacy loop could end up to one tick
early as `#95` measures it; S1b's deadline-in-`#40` closed that. (3) Found on the way and fixed in S3c: every
ring-3 `#GP` froze the box (the `#GP` stub read the faulting user RSP at CPL0 under SMAP). Consumer comments now
stale (read-only siblings): puka `src/pty.cyr:351`, setu `src/client.cyr:382`, mishran `src/transport.cyr:112`,
aethersafha `src/setu_dispatch.cyr:308` say `sleep_ms` starves the peer; daimon's `daimon_yield_ms` may return to
`sleep_ms`; cyrius comment updates are in the combined peer filing.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S3c-report.json`, `S3c-fix-report.json`, `S3b-report.json`.
