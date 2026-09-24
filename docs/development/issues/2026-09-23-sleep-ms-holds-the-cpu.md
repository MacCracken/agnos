# 2026-09-23 — `sleep_ms`#41 holds the CPU: nothing else runs while a process sleeps

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
