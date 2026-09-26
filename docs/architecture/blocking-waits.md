# Blocking waits — the BLOCKED state and the wait/wake primitive (invariants)

> **Last Updated**: 2026-09-26 (1.57.9 ENDFIX — the #108 handoff; pipeline fd hygiene. Before: 1.57.9 — `#44` is a quiet local yield again; the directed yield `sched_yield_to`#108
> kicks only its named peer's CPU; pipe WRITES block too — `wr1_wait`, `pipe_wkey`, `pipe_lock`, PIPE_BUF 512, EPIPE. 1.57.8 — blocking pipe / channel reads, `WK_PIPE`/`WK_CHAN`, `wq_wake_m`, the `#44`
> directed park kick (withdrawn 1.57.9). 1.57.7 — Path 2 step S3d, bites S3.6–S3.9: keep-current, the `#44`/`#14` park, the
> halt protocol and `cpu_kickable`, the idle step, the 0xE1 reschedule kick, the keyboard's one-reader-per-line wait,
> the sound waits. S3c (S3.4–S3.5) wrote the primitive and its first users. Later Path 2 steps extend this document:
> S3b (foreground exec: the #37 child and kmain's `run` are scheduled children, the waiter blocks on `WK_CHILD` — see
> [`foreground-exec.md`](foreground-exec.md); S3b-F2 removed the INTERIM clause), S6 (the network waits), S7 (the lifecycle
> hooks `wq_signal_*`).)
>
> Code: the primitive, `sched_clock_us`, `sched_exit_tail`, the voluntary switch and the ktest cases (T1–T10) in
> [`kernel/core/sched.cyr`](../../kernel/core/sched.cyr) · the wait cells, keys and reasons in
> [`kernel/core/proc.cyr`](../../kernel/core/proc.cyr) · `wq_tick`'s call in `timer_handler`
> ([`kernel/arch/x86_64/pic.cyr`](../../kernel/arch/x86_64/pic.cyr)) · the users `sleep_ms`#41, `waitpid_poll` /
> `waitpid_peek` / `sys_waitpid_block` and the `#59` arm in [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr)
> · the flock table in [`kernel/core/vfs.cyr`](../../kernel/core/vfs.cyr) · `flock_lock` in
> [`kernel/arch/x86_64/smp.cyr`](../../kernel/arch/x86_64/smp.cyr).
> Gates: `scripts/smoke/wait-ring3-smoke.sh` (`tests/waits/waitx.cyr` as `/bin/agnsh`, `-smp 1` and `-smp 4`),
> `scripts/smoke/wait-kbd-smoke.sh` (the keyboard, over HMP), kstack-smoke's block/wake, ping-pong, pause-window,
> fallback, spurious-0xE1 and kick-gate phases (`KSTACK_SELFTEST`), ktest T1–T11 (T8–T8f the keyboard, T11
> keep-current).
> The switch itself (the voluntary `int 0xE0` path) is Invariant 7 of
> [`kernel-stacks-and-preemption.md`](kernel-stacks-and-preemption.md).

Until 1.57.7 a syscall that had to wait held its CPU: `preempt_disable(); sti; hlt`-loop until the event
(`sleep_ms`#41), or returned WOULD_BLOCK and left ring 3 to poll (`waitpid`#4, `flock`#59 — whose comment
promised a ring-3 spinner nobody wrote). Path 2 gave every process its own kernel stack (1.57.6), so a syscall can
now leave its CPU **inside the kernel** and be resumed later, on any CPU.

## States (process table field +8)

| State | Meaning | Who sets it | Who makes it READY again |
|---|---|---|---|
| 0 | dead / free | exit#0, `fault_kill_current`, reaps | — |
| 1 | READY | the switch revive (1..3 → 1), wakers | — |
| 2 | RUNNING | `do_context_switch` (new), `wq_cancel`, the BLOCK guard | — |
| 3 | CLAIMING | `proc_alloc_slot` | its creator |
| 4 | DYING (S7: claimed, or an orphan reaping itself) | the lifecycle step (S7) | never |
| 5 | STOPPED (S7) | the lifecycle step (S7) | SIGCONT (S7), or its parent's death |
| **6** | **BLOCKED** — left its CPU inside a kernel wait | `wq_arm` (under `sched_lock`, LAST) | **only** `wq_wake`, `wq_tick`, `wq_interrupt` |

`sched_next` picks only 1; `do_context_switch` revives only 1..3 (a proc in 4/5/6 left its CPU on purpose);
`proc_alloc_slot` reuses only 0 with `on_cpu == -1`. `#99 proclist` reports 6 as it is. INV-RUN: the process
current on a CPU is state 2 with `on_cpu` == that CPU.

## The API (C9 — the only names later steps use)

| Name | Contract |
|---|---|
| `wq_can_block()` | 1 when THIS context may block: scheduler live; preempt_count 0 (no lock held, not an ISR body); a real proc, not this CPU's idle; state 2 with `on_cpu` == this CPU (INV-RUN — else a latched `wq: current is not running on this CPU (INV-RUN)`); on its own CR3. IF-agnostic. (S3b-F2 deleted the INTERIM #37-child clause.) Reads the CPU index once (the hot path of every `flock` without `LOCK_NB`). |
| `wq_arm(key, dl)` | Publish BLOCKED on `key` with deadline `dl` (`sched_clock_us`; 0 = none). **0** armed · **1** a lifecycle signal is pending (S7; nothing armed) · **2** may not block (nothing armed). A proc found at state **0** (a remote retire) leaves through `sched_exit_tail` when preempt_count is 0, else returns 2 so the caller unwinds and drops its lock first. |
| `wq_cancel()` | Withdraw an armed wait (the condition turned out true, or the deadline passed): 6 or 1 → 2, clears key / deadline / reason; returns the reason a waker may already have left (`WR_NONE` if none). |
| `wq_sleep()` | Leave the CPU (`sched_switch_vol(2)`) until woken; returns `WR_EVENT` / `WR_TIMEOUT` / `WR_SIGNAL`. A wake that landed before the switch returns at once (the BLOCK guard). |
| `wq_wake(key)` | Make every BLOCKED proc on `key` READY with `WR_EVENT`; returns how many. IRQ-saving; callable from ISRs and under a condition lock. It builds the woken-pid mask in a LOCAL (`ww_m`): S3.8's kick runs after `sched_spin_unlock`, where a shared cell would already hold another CPU's concurrent mask, so the kick goes inside `wq_wake` from that local. Never publish the mask through shared state. |
| `wq_interrupt(p)` / `wq_interrupt_locked(p)` | BLOCKED `p` → READY with `WR_SIGNAL` (S7's signal delivery). 1 = it was waiting. |
| `wq_tick()` | Expire deadlines (`WR_TIMEOUT`) — every CPU's timer tick, outside the BSP-only block. |
| `wq_signal_pending(p)`, `wq_signal_point()` | Lifecycle hooks, bodies return 0 until S7 (below). |
| `sched_clock_us()`, `wq_deadline_after_us(us)` | The wait clock (below). |
| `sched_exit_tail()` | A dead process leaves its CPU at once (below). |

Keys (high byte = class, low bits = object): `WK_SLEEP | pid`, `WK_FLOCK | inode`, `WK_CHILD | ppid`, `WK_KBD`,
`WK_KBD_OWNER`, `WK_SND` (S3d), `WK_TCP | cid`, `WK_ICMP | pid` (S6), `WK_PIPE | buffer`, `WK_CHAN | endpoint`
(1.57.8), `WK_TEST | n` (selftests). `wq_wake_m(key, msk)` wakes `(wait key & msk) == key` — `wq_wake` is msk −1; a
CLASS wake (msk `0xFF00…`) serves a waker that can no longer name the objects (a pipe writer's death). Reasons: `WR_NONE`
0, `WR_EVENT` 1, `WR_TIMEOUT` 2, `WR_SIGNAL` 3. The cells are pid-indexed arrays in proc.cyr (shared, because
vfs.cyr names `WK_FLOCK` and `proc_alloc_slot` scrubs them): `proc_wait_key`, `proc_wait_deadline`,
`proc_wake_reason`.

### The canonical wait

```
if cond -> done
loop:
    a = wq_arm(KEY, dl)
    if a == 1 -> wq_signal_point(): ABORT -> return; else continue
    if a == 2 -> take the legacy step (this context cannot block)
    if cond -> wq_cancel(); done                       # the RE-CHECK after the arm is the whole point
    if dl != 0 && sched_clock_us() >= dl -> wq_cancel(); timeout
    r = wq_sleep()
    if r == WR_SIGNAL -> wq_signal_point()
    re-check
```

**The waker always makes the condition true BEFORE `wq_wake`.** Lost-wakeup proof: the waiter publishes 6 under
`sched_lock` (whose `xchg` is a full fence) BEFORE its condition re-check, and every waker's condition store
precedes its `sched_lock` acquire. So either the re-check sees the condition, or the wake sees 6 and sets 1 — which
`sched_block_intent_satisfied` (the switch declines) or `sched_next` (it is picked) then honours. kstack-smoke's
ping-pong phase proves it: two probes hand a turn back and forth across a preemptible gap between the check and the
arm; a re-check moved before the arm (mutation M-C6) loses the wake every round (5 s watchdog expiries).

## Discipline (C6 R1–R6, C7)

- **R1 — IF=0.** `wq_arm`, `wq_cancel` and `wq_sleep` run IF=0: syscalls by SFMASK; kmain / ktest callers bracket
  the whole arm … sleep|cancel with one `kbd_irq_save/restore`. Each asserts it: a latched
  `wq: wait primitive entered with IF=1`, then `cli`.
- **R2 — preempt_count 0 at `wq_sleep`.** Every plain spinlock and ISR body raises the count, so "no lock held"
  and "not in an ISR" are enforced, not a convention.
- **R3 — `wq_arm` may be called holding the condition's own lock** (`flock_lock`): that is what makes the flock
  re-check atomic with the arm. The caller drops the lock before `wq_sleep`.
- **R4 — never reuse `pcpu_cpu()`, a `pcpu_*` pointer or per-CPU scratch across a wait**; recompute after it (the
  process may resume on another CPU). Only `wq_sleep`'s `c0` is compared across the switch (the cross-CPU witness).
  Per-CPU scratch whose live span must never contain a `wq_*` call: `pcpu_spawn_elf_buf`, `pcpu_spawn_path_buf`,
  `pcpu_spawn_env_buf`, `pcpu_sc_open_abs`, `pcpu_sc_gpuop`, the `fb_scale` row buffer, `gpu_texl_stage`
  (syscall.cyr), `pcpu_elf_hdr_buf`, `pcpu_exec_env_src/len` (elf.cyr) — each carries an R4/R6 comment.
- **R5 — ISRs only wake.**
- **R6 — the live CR3 must be the slot's** (`sched_live_cr3_ok`): the loaders' `cr3_load(0x1000)` windows contain
  no wait (`sched_cpl0_switch_ok` would refuse the switch and `wq_sleep` would say `PANIC: wq sleep not switched`).
- **Locks (C7).** `sched_lock` is the innermost leaf (IF=0 only; nothing acquired and nothing printed under it — a
  failure line is latched and emitted after the unlock). `fs_lock < flock_lock < sched_lock`: the flock releases
  take `flock_lock` under `fs_lock` (`vfs_close`) and wake under it; `flock_lock` is never held across `wq_sleep`
  and never taken in an ISR body.

A `wq_sleep` whose switch was refused with state 6 still published is a caller bug (`wq_can_block` proved every
pre-lock guard): `PANIC: wq sleep not switched`, then halt. A return in state 1 (a guard refused after an early wake)
is repaired and reported once (`wq: sleep resumed in a non-running state`). All of these lines are in
`SMOKE_INVARIANT_DENY`; the klug-only `wq: first cross-CPU resume from a kernel wait` is NOT (waitx P8 requires it).

## The clock — `sched_clock_us`

Every deadline is on `sched_clock_us()`: `(rdtsc − tsc_base) / tsc_per_us` when the TSC is calibrated (final before
`sched_active = 1`), else `timer_ticks × 10000` (**tick mode** — the calibration was refused, which is permanent once
ring 3 runs). In tick mode the clock advances only with BSP ticks, so deadlines **stall while the BSP runs a long IF=0
syscall**, and it has one-tick granularity: `wq_deadline_after_us` adds one tick (10 ms) so "sleeps at least `us`"
holds with a partial first tick (ktest T5b measures it in real time; mutation M-C14). Deadlines expire in `wq_tick`
at the first tick at or after them — a sleep is `ms` plus up to one tick. See
[`kernel-clocks.md`](kernel-clocks.md).

### WQ-DL — the deadline bookkeeping self-heals

`wq_ntimed` (procs with a deadline) and `wq_min_deadline` let `wq_tick` return after two unlocked reads. Its rescan
under `sched_lock` is **authoritative**: it recounts both and clears any deadline on a proc that is not BLOCKED (a
remote retire, a death path, `proc_alloc_slot`'s scrub). So nothing else has to keep the counter exact — it may be
stale-HIGH (an extra rescan), never stale-low.

## `sched_exit_tail` and the `wq_arm` state-0 rule

`exit`#0 and `fault_kill_current` end in `sched_exit_tail()`: a BLOCK-shaped voluntary switch (the BLOCK guard
proceeds on state 0, `do_context_switch` never revives 0 and hands a dead `old` back to the boot CR3), so the dead
process leaves its CPU at once and its reaper's `on_cpu` fence spins for a few instructions, not up to a tick
(measured, M-S2: `-smp 4` fence spins 0 vs 8,121–25,069 with the old `sti; hlt` tail). The `sti; hlt` loop remains
the fallback before the scheduler runs or when the switch is refused. The two `kernel_resume` gates above it stay
until S3b-F4. `wq_arm` on a state-0 proc (a remote retire) uses the same tail when preempt_count is 0, and returns 2
when a condition lock is held — exiting while holding `flock_lock` would spin `sti; hlt` forever at preempt_count 1
and every flock caller would spin on that lock. ⛔ **The rule has a second half: a caller that got 2 while holding a
condition lock calls `wq_exit_if_retired()` once it has dropped every lock, before it returns anything.** With
preempt_count back at 0, a state-0 caller leaves through `sched_exit_tail` there. Returning −1 instead would SYSRET a
dead process to ring 3, where it keeps running (and can make more syscalls) until its next tick, while its reaper spins
in `proc_reap_off_cpu_fence` at IF=0. `flock_wait` (the `#59` loop) does this; ktest T9b drives it with a retire landed
between the arm's `wq_can_block` and its `wq_arm`, and mutation M-A7 (the call dropped) turns T9b red. S7's death paths
inherit the same unwind-then-exit shape.

## The lifecycle hooks (S7's contract — filled by S7, 1.57.7)

`wq_signal_pending(p)` (non-zero → `wq_arm` returns 1 instead of blocking) and `wq_signal_point()` (1 = ABORT the
syscall, 0 = CONTINUE). ⛔ **`wq_signal_point` must never return CONTINUE while `wq_signal_pending(p)` stays non-zero**,
or every canonical loop spins IF=0 on `wq_arm == 1`.
⭐ **Filled by S7** ([`process-lifecycle.md`](process-lifecycle.md)): `wq_signal_pending(p)` = a kill or a stop is
pending for `p` (read under `sched_lock` by `wq_arm`); `wq_signal_point()` = `lifecycle_park_or_abort(me, VIA_WAIT)`:
**ABORT** when a kill is pending — each arm unwinds with its documented abort value (`sleep_ms` 0, `flock` −1, the
keyboard read −1, WAIT_BLOCK −2, `#37` −1, the S6 net waits) and none of them reaches ring 3: B1 ends the process;
**PARK** (state 5, `stop … via=wait`) when a stop is pending, then **CONTINUE** after SIGCONT — the arm re-arms with the
SAME absolute deadline (a SIGCONT past it returns at once); a stop that no longer applies (unstoppable, no live
parent) is dropped (CONTINUE). **Precondition: every signal point runs with `preempt_count == 0`** — the canonical
waits call it after dropping their condition lock and only when `wq_can_block() == 1`; a violation latches
`lifecycle: signal point with preempt held` (denied) and unwinds instead of spinning. A kill of a BLOCKED process sets
the flag and calls `wq_interrupt_locked` in the same hold, so its sleep returns `WR_SIGNAL`. The legacy fallbacks
(`kbd_read_blocking_held`, `sleep_ms`'s legacy loop) poll `proc_kill_requested_self()` once per iteration (defence in
depth — unreachable from ring 3). **A STOPPED keyboard reader keeps the keyboard line** until SIGCONT or death (a
stopped reader keeps its terminal); a killed `WK_KBD_OWNER` waiter unwinds through its own acquire loop, which
decrements `kbd_line_waiters` right after `wq_sleep`.

## The INTERIM clause — removed by S3b-F2 (1.57.7)

Until S3b-F2 the child of an in-flight `execwait`#37 could not block (its parent's continuation lived in per-CPU exec
cells), so `wq_can_block`, `sched_yield_kernel` and `sched_cpl0_switch_ok` refused it: legacy sleep, `LOCK_NB` flock,
`WAIT_BLOCK` −2, a no-op `#44`, the held keyboard/sound paths. S3b made #37 a blocking wait — the child is an ordinary
scheduled process and its caller sleeps on `WK_CHILD | me` ([`foreground-exec.md`](foreground-exec.md)) — and deleted
the clause at every site. A #37 child blocks like any process; waitx P13 (`ew37`) runs the blocking expectations (its
sleep blocks: spinner share ≥ 0.8×; its flock waits and returns 0 within 50 ms of the unlock); mutation M-FGBLK (the
clause re-created in `wq_can_block`) turns P13 RED. The refused-context paths now serve only pre-scheduler and
preempt-held kernel code.

## The users

- **`sleep_ms`#41** — `wq_arm(WK_SLEEP | pid, deadline)` + `wq_sleep` in the canonical loop; `ms < 0` → −1, 0 → 0.
  Callers that cannot block keep the legacy preempt-held tick loop verbatim (pre-scheduler DOOM pacing and
  exec-smoke's `/bin/timetest` stay byte-identical). That loop waits `ceil(ms/10)` BSP tick edges, so it lasts
  **≥ `ms` in the tick clock** (`uptime_ms`#40, the clock its callers pace in). As `uptime_us`#95 measures it, it can
  end **up to one tick early** (it starts counting from a partial first tick), **plus the LAPIC-vs-TSC rate error**.
  S3c measured `sleep_ms(300)` at 282.5 ms under TCG `-smp 1` (1.75 ticks short: the TCG LAPIC tick runs ≈6% fast
  against the TSC) and 292.8 ms under KVM `-smp 4`. S1b re-bases the LAPIC tick on the PM timer, which removes the
  rate part. Since S3b-F2 a #37 child's sleep is on the blocking path, and waitx P13 gates it ≥ `ms` in #95 (it gated the
  interim child's legacy loop in #40 until then).
- **`waitpid`#4 `WAIT_BLOCK`** — `arg1 = 0x100 | pid`, `0x1FF` = any. `sys_waitpid_block` arms `WK_CHILD | me`
  FIRST, then `waitpid_peek` (a pure read that re-runs `proc_may_reap` every time, so a target recycled by another
  reaper answers −1, never a stranger's status), then reaps through `waitpid_poll` — the single home of the return
  encoding (S7's status encoding lands there). Every exit path stores state 0, THEN sends SIGCHLD and wakes
  `WK_CHILD | ppid`. No deadline.
- **`flock`#59** — see below.

## flock — the table, the wait, and pid ownership

vfs.cyr keeps the table logic (`flock_try_locked(inode, pid, op, drop_own)` under `flock_lock` → 0 OK · 1 CONFLICT ·
2 FULL · 3 INVALID; `flock_release_inode`, `flock_release_pid`); the `#59` arm owns the wait: with `LOCK_NB` clear
and `wq_can_block()`, a CONFLICT arms `WK_FLOCK | inode` UNDER `flock_lock` (R3), drops the lock, sleeps, retries.
Every removal (UN, close, exit, fault kill) and every EX→SH downgrade wakes the inode's waiters — a broadcast; no
FIFO fairness; no timeout (S7's SIGKILL breaks cycles). **−2 = the table is full** (16 slots) and never waits. A
**blocking conversion** (SH↔EX, `drop_own` = 1) removes the caller's own entry before it waits, as flock(2) does; a
failed `LOCK_NB` conversion keeps it (ktest T9, waitx P5d; mutation M-E4).

⚠ **The owner is the PID, not the open-file description.** flock(2) ties a lock to the OFD, so a fork child sharing
the parent's OFD shares its lock. agnos has no OFD layer — `vfs_fd_inherit` copies each 32-byte fd entry into the
child's own table — so a `fork` child that locks through an inherited fd while its parent holds the lock WAITS, and
deadlocks if the parent then `WAIT_BLOCK`s on it; a two-lock cycle parks both processes until S7's SIGKILL. Per-OFD
semantics need a shared OFD object for every fd type (an fd-table redesign) — filed as a follow-up, not done here.

## Keep-current (S3.6)

`sched_next` returns a READY non-idle process when there is one; when only **this CPU's idle** is READY and the
process current here is still **RUNNING (state 2)** and pickable here, it returns that current process, and
`do_context_switch`'s `new == old` early-out keeps it. A lone runner used to alternate with the idle every tick
(~50% of a CPU — waitx P2b measured it; mutation M-D1). ⛔ **A leaving process is never kept**: every path that leaves
a CPU publishes its state (1 YIELD, 6 BLOCKED, 0 dead, S7's 4/5) under `sched_lock` BEFORE it switches, so the
`== 2` test is exactly "still wants the CPU" (M-D3: dropping it keeps a BLOCKED waiter → `PANIC: wq sleep not
switched`). This is also the structural fix for the blocking critique's `sched_suspend_current` livelock. ktest T11
checks both halves deterministically under `sched_lock`.
⚠ A consequence every later step must know: with keep-current a CPU-bound runner is never switched out while only the
idle is READY, so a check that runs only at switch-IN never runs for it — S7 must act on a pending SIGKILL/SIGSTOP at
the TICK. And affinity is now sticky: a sleeper resumes on the CPU whose tick (or kick) woke it (waitx P8's `hop`
varies its sleep start so it still witnesses a cross-CPU resume when the CPUs' tick phases are clustered).

## Yield and park (S3.6)

With keep-current a yield with only the idle READY is a no-op — so every poll + `#44` loop whose peers are BLOCKED
(the normal state once waits block) would spin its core at 100% and be charged for it. `sched_yield_or_halt()`:
**1** switched to another READY process and back · **2** parked — `sched_halt_window()` halted the CPU for one
interrupt (IF=1 at preempt_count 0: a designated CPL0 preempt point, **not charged** — `cpu_in_halt`), then offered
the CPU once more (`sched_yield_kernel`) so whatever that interrupt made READY runs at once · **0** refused
(pre-scheduler, preempt held, a borrowed CR3): the caller keeps its legacy path.
`#44` = `sched_yield_or_halt(2, -1)`; `#108` = `sched_yield_or_halt(2, pid)` for an authorized target;
`#14` = `sched_yield_or_halt(1, -1)`, then `ksyscall(14)`'s legacy hlt only when refused; the `#14` arm's own window
(an in-kernel `ksyscall(14)`) is `sched_halt_window(1, -1)` followed by the yield when the window found work.
⛔ `sched_ready_for_me(me)` — the park's scan — excludes `me` AND **this CPU's idle**: the idle is READY whenever a
parker is current, and finding it would bounce through keep-current and never halt (M-D4). Measured: a `#44` loop
for 300 ms beside a sleeping child is charged 0 ticks (P2c; M-D2 — the park removed — 30); bench `yield_idle` ≈ one
interrupt period (a ~µs reading is the M-D2 signature). A yield toward a peer RUNNING on another CPU parks too (it is
not READY here) — which made `yield_peer` at `-smp 4` a tick-bound ping-pong (9.9 ms per round) until 1.57.8's
directed kick, now the directed yield `#108` (below).

⭐ **The directed yield (1.57.9) — `sched_yield_to`#108; `#44` is quiet.** A park takes `hw_k`, the `cpu_kickable`
value it publishes — **2** for a YIELD park (`#44`, `#108`), **1** for every other park (`#14` pause, an in-kernel
`ksyscall(14)`) and for the idle step — and `hw_t`, the directed-yield target (-1 for everything but `#108`). After
its scan found nothing, a park with a target calls `sched_kick_target(t)`, then halts. **Only the target's CPU is ever
kicked:** t READY but pickable only elsewhere (pinned) → `sched_kick_for(t)`; t CURRENT on another CPU that is parked
in a yield (`cpu_kickable == 2` and `pcpu_curproc == t`) → one 0xE1; t busy, BLOCKED, STOPPED or in a `#14` park →
nothing. The kick goes out after this CPU published its own `2` + `mfence` + scan, so the woken peer's next `#108`
sees this CPU and kicks back: a pair that names each other trades one IPI per round. **Authority:** self (a plain
`#44`, 0) · an epoch-valid direct child · the epoch-valid direct PARENT (`yt_auth_ok`, sched.cyr); never pid 0 / kmain,
an idle or a kthread (`proc_is_user`), never dead / zombie / claiming / dying. **-1 on a refusal, AFTER the same quiet
yield/park `#44` does** — a `while (!flag) sched_yield_to(peer)` loop whose peer died must not spin a core. An
in-kernel `ksyscall(108)` returns -1 with no effect (as `ksyscall(44)` does).
- **Prior art** (the handoff note `YIELD-prior-art.md`, from the Linux, KVM, XNU and FreeBSD sources): an UNDIRECTED yield
  never touches another CPU — Linux `do_sched_yield` (local rq, no IPI), FreeBSD `sched_relinquish`, Win32
  `SwitchToThread` ("will not switch execution to another processor, even if that processor is idle"), L4
  `ThreadSwitch(nilthread)`. So `#44` is quiet. Where a DIRECTED yield exists its reach is a trust group or a capability
  (Linux `yield_to`: the thread group; KVM: the VM; Mach `thread_switch`: a port / the task), and only Linux `yield_to`
  signals across CPUs — `resched_curr(p_rq)`, one IPI to the target's own CPU. `#108` follows that targeting; agnos's
  only trust group is the spawn edge (no threads, no process groups).
- ⭐ **The HANDOFF (1.57.9 end review YIELD-R1).** Every directed yield in that table first makes its target run NEXT
  when it can run where the caller is: Linux `yield_to_task_fair()` → `set_next_buddy()` ("we'd really like se to run
  next"; `pick_eevdf()` returns `cfs_rq->next` first — "will affect latency but not fairness" — and `clear_buddies()`
  drops it once picked), Mach `thread_switch` hands off, L4 `ThreadSwitch` donates. As first shipped, `#108`'s
  voluntary switch was the ordinary round-robin pick and ignored the target: with the target and a busy third process
  both READY on the caller's CPU, "yield to t" ran whichever came first in slot order (ipcw `yield-handoff`, `-smp 1`:
  **10.0 ms per round**, one leg of every round through the busy process until its tick). Now `#108` publishes a
  per-CPU one-shot hint (`pcpu_yield_to`, sched.cyr, written by `sched_yield_kernel_to` with IF=0 around its own
  `int 0xE0`) that `sched_next()` consumes first, under `sched_lock`, and returns the target iff it is READY, off every
  CPU, not this CPU's idle and pickable here; else the round-robin pick runs unchanged. Measured: `yield-handoff`
  **148 µs per round at `-smp 1` and `-smp 4`**. `#44` / `#14` / every in-kernel yield carry no hint.
- **Departures, on purpose:** (1) `#44` still PARKS for one interrupt with nothing READY where Linux returns at once — the
  "poll + yield must not spin a core" rule above. (2) `#108` adds the PARENT direction to kill#16's child-only rule —
  both sides of a spinning pair must name each other, and every real pair is parent↔child; it is advisory (the worst
  case is a spurious wake of a CPU its target parked "run me asap"). (3) Returns 0 / -1, not Linux's >0 / 0 / -ESRCH:
  no "boosted" bit is exposed (it would only leak scheduling state); the kicks are counted in `sysinfo`#35 +200.
  (4) A bad target degrades to a plain yield and returns -1 (Mach/L4 degrade and return success; the -1 tells the
  caller its peer is gone). (5) No KVM `dy_eligible` damper: KVM guesses its target, here both sides asked by name —
  a `#108` pair costs ~10k IPIs/s **by request**. (6) Kicking a CURRENT-but-halted target is an agnos addition:
  Linux has no "current but halted" state. (7) The handoff has no eligibility test (Linux's `entity_eligible()`):
  round-robin keeps no lag to be eligible against; fairness to a third process is kept by the timer tick, which never
  carries a hint, so a busy process still gets every tick that lands while the pair runs. (8) No migration (Mach pulls
  the target onto the caller's processor) and no timeslice donation (L4; agnos has no per-process slice): a target
  current or pinned on another CPU gets the directed kick instead.
- **Why (issue 2026-09-25-any-two-sched-yield-loops-kick-each-other, OPERATOR RULING 2026-09-25 option 1):** 1.57.8
  gave every `#44` park an undirected kick (`sched_kick_parker`: one 0xE1 to the first other CPU parked in `#44`). The
  kernel cannot tell whom a yielder waits for, so ANY two `#44` loops on two CPUs woke each other every ~100 µs for as
  long as both yielded (agnsh's bg poll beside a yielding job; agnoshi `run_agnos` beside a yielding child).
- **Measured** (`ipc-wait-smoke`, `-smp 4`, KVM): `yield-peer` (`#108` both ways) ~127 µs per round (8.95 ms with the
  `#108` kick removed, mutation M2); `yield-pair` (`#44` beside an unrelated `#44` yielder, the issue's gate) **0**
  kicks in a 300 ms window and ~10 ms per call — 4679 kicks and 127 µs per call with 1.57.8's `#44` kick restored
  (M1); a refused `#108` ~10 ms per call (9.8 µs when the refusal skipped the park, M4). `-smp 1`: the pairs alternate
  by direct switches (~85–99 µs), 0 kicks.
- ⛔ **`#14` pause neither sends nor draws a directed kick** (1.57.8 end review, PIPE-R1): until then every park did
  both, so crab's `#14` idle beside a cyrius `_agnos_sock_recv_block` `#14` backoff — or agnsh's `#44` bg poll beside
  either — woke each other every ~100–200 µs forever, and the sock_recv backstop of 6000 pauses (sized for ~10 ms
  pauses) expired in under a second. `ipc-wait-smoke`'s `pause-pair`, `mixed-pair` and `yield-pair` gate ≤ 30 kicks per
  300 ms at every `-smp` and ≥ 1 ms per call at `-smp > 1`. A park beside a BUSY process (it never parks), a BLOCKED
  one (current nowhere) or a `#14` pauser kicks nothing, so agnsh's prompt poll beside a busy job still halts (P2c).
- The cure for a pair that polls each other is still a blocking read (`#5` a4 = 0) or `WAIT_BLOCK` (below); `#108` is
  for the pairs that really do spin.

## The halt protocol and `cpu_kickable` (S3.6/S3.8)

Two per-CPU flags (proc.cyr): **`cpu_in_halt`** is the ACCOUNTING flag — every `arch_wait` sets it, including the
preempt-held waits that cannot take work; the timer ISR consumes it so a halted tick is charged to nobody.
**`cpu_kickable`** is the KICK-TARGET flag — 1 only while this CPU is halted (or about to halt) in the idle step or a
park and **will re-scan for READY work when its hlt ends**. Kick targeting never reads `cpu_in_halt`.
Writers: only code running ON that CPU — set by `sched_idle_step` / `sched_halt_window` at IF=0 before their scan,
cleared after their hlt (or when the scan finds work) — and the timer ISR on that CPU, which clears it (a tick may
switch the halted context out; a flag left at 1 on a CPU now running another process would draw kicks it cannot
serve). Any future halting context that should receive kicks MUST use the same order:

    cli · cpu_in_halt = cpu_kickable = 1 · mfence · scan for READY · (work: clear, take it) · sti;hlt · re-read cpu · clear

**THE DEKKER PROOF (the idle step AND the park).** A waker stores `state = 1` under `sched_lock`, releases it (the
`xchg` is a full fence), then loads `cpu_kickable[t]`. The halter stores `cpu_kickable[c] = 1`, `mfence`s, then loads
the states. Both sides store-then-load across a full fence, so they cannot both miss: either the halter's scan sees
READY (it takes the work instead of halting), or the waker sees the flag and kicks — and a kick that arrives while the
halter is still IF=0 stays pending and ends the `hlt` the instant the `sti` shadow closes (`arch_sti_hlt` is
`sti; hlt`, the shadow covering the hlt). Scanning FIRST and setting the flag after would lose exactly the kick that
lands between them — this ordering is not mutation-provable (a nanosecond race); it is stated here instead.
**The idle step** (`sched_idle_step`, both the BSP's `kernel_idle_loop` and every AP's `ap_entry` tail): scan result
1 → take it through the voluntary switch (`sched_yield_kernel` → `int 0xE0`: the idle adds no switch path); 2 (READY
but fenced — `on_cpu != -1`, INV-11: its old CPU is still in its switch tail, µs; up to 50 ms only in kstack-smoke's
fence phase) → `sti; pause; cli`, never halt; 0 → `sti;hlt`. A yield that REFUSES READY work 1000 times in a row on one
CPU prints the latched, denied `sched: IDLE REFUSED A READY PICK 1000 TIMES` — never on a correct kernel (the idle is
at preempt 0 on its own CR3; a lost race resets on the next hlt). Before
`sched_active` the step only halts; an AP in STEP-1 (`smp_sched_aps == 0`) scans nothing it may pick and halts.

## The kick — vector 0xE1 (S3.8)

`wq_wake` (its local woken mask), `wq_interrupt` (the proc it woke) and `wq_tick` (only procs **pinned to another
CPU** — the ticking CPU's own `do_context_switch` takes the rest) call `sched_kick_for(p, kicked)` / `sched_kick_mask`
after `sched_lock` is released. Targets: a pinned proc → its pin's CPU; an unpinned one → nothing if THIS CPU
interrupted its own halt (it re-scans on return), else the first kickable online CPU after this one, skipping CPUs
this wake already kicked (the spreading — reasoned, not mutation-provable: it needs simultaneous multi-proc wakes onto
several halted CPUs). Never self; only a `cpu_kickable` CPU. `resched_kick_handler` is **EOI-ONLY and never
switches**: the woken CPU's own code takes the work (the idle step re-scans; the park's trailing yield). DPL0, IST0,
`clac` first, a fixed 43-byte stub. ⚠ **LIMITS**: a BUSY CPU is never kicked — a READY process that only it can run
waits ≤ 1 tick (no wake-time preemption: 0xE1 cannot preempt, and a hardware 0xE0 is EOI-only by the intent cell).
A preempting kick needs a NEW reschedule-capable handler (the timer's exact tail) — a new CPL0 resume path; S6 must
not assume one exists (PLAN OQ-5: measured there first).
Measured (`-smp 4`, KVM): a flock waiter woken for another CPU runs **74 µs** after the unlock (P12; M-G1 — no kick —
9.0 ms, M-G2 — the idle re-halts — 9.0 ms); woken for a CPU parked in `#44`, **70 µs** (P12b; M-G5 — the park not
kickable — 9.0 ms). The `wq_tick` kick of a pinned sleeper is report-only: on this host the four CPUs' tick phases
are clustered, so the BSP's own tick is the first after a deadline and PINNED-SLEEP reads ~7 ms overshoot for a
`sleep_ms(3)` with and without it (M-G8).

### Wake latency (after S3d)

| Wake | Latency |
|---|---|
| an ISR wake (xHCI key MSI, S6's NIC RX) on the SAME CPU, which is idle or parked | immediate — the step/park re-scans when the ISR returns |
| a wake for a REMOTE idle or parked CPU | one IPI (tens of µs) |
| a wake for a BUSY CPU (the only CPU the proc may run on) | ≤ 1 tick — no wake-time preemption |
| a deadline (`wq_tick`) of a proc pinned to a remote idle/parked CPU | one IPI (when another CPU's tick expires it first) |
| tick-mode clock (TSC refused) | BSP ticks (10 ms) |

## Pipe and channel reads (1.57.8)

`read`#5 on a pipe read end or an owned channel endpoint that would answer −2 (WOULD_BLOCK: empty with a live
writer / a live peer) **blocks its caller when `a4 == 0`** (`rd5_wait`, syscall.cyr — the canonical C9 loop);
`a4 != 0` is O_NONBLOCK and keeps −2, as do a zero-length read and a context that cannot block. `rd5_key(fd)` is both
the pre-check and the side-effect-free re-check after the arm: `WK_PIPE | buffer` (`pipe_key`, vfs.cyr) while the
ring is empty and `pipe_writers_open` finds a writer, `WK_CHAN | endpoint` while `chan_w == chan_r` and the peer end
is open, else 0 (data, EOF or an error — the read itself decides). **Wakers, each AFTER its condition store:**
`pipe_write` (the head), `vfs_close_inner` (every pipe-end close — it may be the last writer), `proc_death_finish`
(a CLASS wake of every `WK_PIPE` reader after the writer's state 0 or its orphan teardown: `pipe_writers_open` skips
dead tables, and an orphan's table is already gone, so the pipes cannot be named), `chan_queue` (the sender's
`chan_w`; both `CH_SEND`#97 and `write`#1), `CH_CLOSE` and `chan_release_pid` (the peer's `chan_end_open`). A 100 ms
backstop deadline re-checks anyway: a writer dropped by a path with no wake costs latency, never a hang. **Kill
(S7 boundary D):** a SIGKILL's `WR_SIGNAL`, or a kill pending at the arm, ABORTs with −1, which never reaches ring 3
(B1 ends the process); a STOP parks inside `wq_signal_point` and the loop re-arms. `CH_RECV`#97 stays non-blocking
(its a4 is the capacity, and it is the batch op a compositor polls across every channel it holds). Pipe WRITES block too
since 1.57.9 (next section). Gate: `scripts/smoke/ipc-wait-smoke.sh` (tests/ipcw,
`-smp 1` and `-smp 4`): pipe and channel ping-pongs 35–175 µs per round (< 1 ms gated), EOF by close ≈ the child's
own 30 ms, EOF by death ≈ 32 ms, a kill of a reader in state 6 reaped 265 in < 1 ms. Mutations: the writer wake
dropped → pipe-pp 210 ms per round (backstop-bound, RED); the sender wake dropped → chan-pp 108 ms (RED); the death
class wake dropped → eof-death 110 ms (RED). `bench-ring3` `pipe_wr_rd8` pays the writer's `wq_wake` (sched_lock + a
16-slot scan): 6.9 → 7.1 µs at `-smp 1`, 15.4 → 16.4 µs at `-smp 4`.

## Pipe writes (1.57.9)

`write`#1 on a pipe write end that took fewer bytes than asked **blocks its caller when `a4 == 0`** (`wr1_wait`,
syscall.cyr — `rd5_wait`'s mirror, the canonical C9 loop); `a4 != 0` is O_NONBLOCK and keeps the short write, as does
a context that cannot block (kernel callers). The writer sleeps on its **own** key, `pipe_wkey = pipe_key | 1`
(vfs.cyr; Linux `wr_wait`, FreeBSD `PIPE_WANTW`) — bit 0 is free because the buffer is a whole 4 KB slab page — so a
writer's `wq_wake(pipe_key)` after each copy never wakes the other writers. `wr1_key(fd, need)` is the pre-check and
the side-effect-free re-check after the arm: `pipe_wkey` while the ring has fewer than `need` free bytes **and**
`pipe_ends_open(buf, 0)` finds a read end (the `pipe_writers_open` scan with the same two rules: a dead state-0
table does not count, pid 0 always does), else 0. `need` is the whole write for ≤ `PIPE_BUF` (512) bytes — a small
write lands whole, in ONE `pipe_lock` hold, never interleaved — and 1 above it (FreeBSD's rule). **Wakers, each
AFTER its condition store:** `pipe_read` (the tail, after `pipe_lock` is dropped — unconditional on a copy, not Linux's
`was_full`, which is only sound under the lock), `vfs_close_inner` (`wq_wake_m(pipe_key, ~1)` wakes both keys: a
closed read end may be the last), `proc_death_finish` (its `WK_PIPE` class wake already matches `pipe_wkey`: a dying
reader's table stops counting at state 0). The 100 ms backstop deadline re-checks anyway. **Returns:** `len`; the
**partial count** when the last reader went away after some bytes were taken (Linux `if (!ret)`, FreeBSD "don't
return EPIPE if any byte was written"); **-1** when no reader is left and nothing was taken (EPIPE — no SIGPIPE: D3).
`pipe_write` itself returns -1 for a refused write with no reader, so the O_NONBLOCK and kernel paths see EPIPE too
(scanned only on the refused path — a readerless pipe with room still takes bytes until full). **Kill (S7 boundary
D):** ABORT → -1, never reaching ring 3 (B1); a STOP parks in `wq_signal_point` and the loop re-arms. **`pipe_lock`**
(smp.cyr, one global leaf below `sched_lock`, nothing acquired under it) covers every ring's head/tail
read-modify-write and byte copy in `pipe_write_n` and `pipe_read`: before 1.57.9 two writers on two CPUs could load
the same head and write the same slots. The user copy under it cannot fault once `is_user_range` has passed (user
pages are never CoW). ⚠ Hazards that are the caller's: a process holding the only read end that writes into its own
full pipe waits until killed (Linux too). ⛔ **agnsh pipelines whose consumer stops early hang** (1.57.9 end review
PIPEW-E1, measured by `scripts/smoke/pipeline-smoke.sh`): `sh_run_pipeline` (agnoshi `run_agnos.cyr`) keeps its own
`rfd` through both reaps (and reaps stage 1 holding it when stage 2 fails to spawn), and spawns stage 1 WITHOUT
`SPAWN_F_CLEANFD`, so stage 1 inherits the read end of its own pipe — bash's `execute_pipeline` names this exact case
("the read end of the pipe (fildes[0]) stays open in the first process, so that process will never get a SIGPIPE") and
closes it through `fds_to_close`. With a read end open anywhere, a full pipe blocks its writer forever (Linux and
FreeBSD agree), so `grep . /etc/ssl/cert.pem | echo x` and the stage-2-spawn-failure case never return to the prompt:
RED at `-smp 1` and `-smp 4` with the staged agnsh and with agnoshi's head build. The PIPEW note's "a hang either way"
is right for the shipped tools and wrong in general: kriya's `k_write` retries a short write up to 20,000 `#44` passes
(≥ 200 s per stalled write), so with PIPEW reverted the same smoke still found no prompt in 40 s; but a cyrius stdlib
producer that makes ONE `sys_write` (`file_write`, `println`) took the 0, dropped the rest and exited before PIPEW —
for it PIPEW turns a completed (lossy) pipeline into a hang whenever the 3-argument `sys_write`'s leftover r10 (a4) is
0. The kernel keeps POSIX semantics (a live read end is a reader); the fix is the shell's: spawn each stage with
`SPAWN_F_CLEANFD`, close `rfd` once stage 2 exists and before reaping stage 1 on the failure paths — GREEN at both
`-smp` with that patch (handoff-1.57.9/steps/ENDFIX-report.json) — plus cyrius passing a4 = 0. Gate: `scripts/smoke/ipc-wait-smoke.sh`
phases `pipe-bulk` (one 64 KB write to a reader that sleeps 2 ms per 8 KB: the write returns within the reader's own
sleep time + 30 ms — measured 68–71 ms against 66–74 ms asleep), `wr-epipe-close` / `wr-epipe-death` (4180 then -1,
46–55 ms), `wr-kill` (state 6 → 265 in < 1 ms), `two-writer` (2 × 64 records of 512 B, none mixed), `wr-nb`, at
`-smp 1` and `-smp 4`. Mutations (each RED alone at `-smp 4`): `pipe_read`'s writer wake dropped → pipe-bulk 1.68 s;
the close wake back to readers-only → wr-epipe-close 139 ms; the death class wake masked to readers only →
wr-epipe-death 121 ms (eof-death stays green); the PIPE_BUF all-or-nothing rule dropped → two-writer 36 mixed
records and wr-nb.

## Keyboard line ownership (S3.7)

`read`#5 on fd 0 (still the console) BLOCKS ONLY ITS CALLER: `kbd_read_line_waiting` arms `WK_KBD` (a 100 ms backstop)
when `kb_buf` is empty and is woken by `hid_kb_push` (the xHCI MSI ISR, the BSP tick's drain, any reader's drain — any
IF; `wq_wake` saves IF itself). IF=0 throughout; the whole make/break stream is drained in order inside the line.
**ONE READER PER LINE** — three cells in keyboard.cyr under `input_lock`: `kbd_line_owner` (pid + 1, 0 = free),
`kbd_line_ep` (the owner's `proc_epoch`: live iff its state ≥ 1 AND the epoch matches — a collapsed slot, `p >=
proc_count`, reads state −1 = dead), `kbd_line_waiters`. `kbd_line_acquire(me, dl)` → 0 owned · −1 S7 signal abort ·
−2 deadline · −3 refused (the caller takes the held read); `kbd_line_try_take`, `kbd_line_release`,
`kbd_line_release_pid` (exit#0, `fault_kill_current`; S7's chain later), `kbd_ring_nonempty` (the side-effect-free
re-check). A dead owner is reclaimed with a klug-only line.
⛔ **The owner wait arms OUTSIDE `input_lock`** (the canonical C9 loop: `waiters++` under the lock, unlock, arm,
re-check under the lock, cancel or sleep): `input_lock` still takes nothing under it (smp.cyr's lock order), and
`wq_arm`'s state-0 → `sched_exit_tail` path never runs holding it. **Lost-wakeup proof**: a release between
`waiters++` and the arm finds no BLOCKED waiter, but the post-arm re-check sees the line free; a release after the arm
wakes the waiter (READY) and the BLOCK-intent guard makes its `wq_sleep` return at once; the releaser reads
`kbd_line_waiters` under `input_lock` AFTER clearing the owner, so it cannot miss a waiter that saw the line busy.
**NB-OWN**: the non-blocking reader (agnsh's prompt poll, `a4 != 0`) answers −2 WITHOUT DRAINING while another live
process owns the line; it takes the line itself on entry and releases it on the way out, which is a no-op while its
own partial line is buffered (`nbline_pos > 0`, the −3 case) — so a line is never split between readers (ktest T8f,
wait-kbd K5; M-F6). Two readers are NOT owner-aware and stay so: `kbscan`#42 (raw scancodes — DOOM owns the keyboard
by convention) and the kernel recovery shell's input loop (kmain, emergency only). **Refused contexts**
(pre-scheduler, preempt-held kernel callers) keep `kbd_read_blocking_held` — the pre-1.57.7
CPU-holding read, which takes the line when it is free and otherwise proceeds UNOWNED (the legacy interleave).
**HID report slots (a defect the wait-kbd gate found):** every keyboard transfer TRB used to DMA into ONE report
buffer, so two reports completed before the drain kept only the last — a key pressed and released inside one IF=0
stretch was lost (`abc` read `bc`). Each TRB now has its own 16-byte slot and the drain folds the slot the event's TRB
pointer names (mutation M-HID). 1.57.8 extends the same slots to the MOUSE rows, which had kept the shared buffer —
there it lost the first report's motion and button edge and counted the last one's deltas once per event. Both kinds
now share `hid_slot_buf` (arm: TRB `idx` → `buf + idx*16` when mps ≤ 16) and `hid_row_evt_buf` (drain: the event's
TRB pointer → slot, read through the direct map); gate `hid-mouse-deferred-smoke.sh` (HID_MOUSE_DEFER_SELFTEST: four
QEMU mouse reports complete while IF=0 and `hid_poll_lock` hold the drain, then one drain must see dx 5, dy 7, the
press and the release).
Handoff notes for S7: a STOPPED (5) owner is live and freezes the keyboard until SIGCONT (S7 chooses and documents);
`kbd_line_waiters` is decremented by the waiter itself — S7's death path must fix it for a proc killed inside the
`WK_KBD_OWNER` wait (or recount); `kbd_line_release_pid` lives in x86-only syscall.cyr — an aarch64 stub is needed if
a shared file calls it.

## Sound waits (S3.7)

`snd_write`#66's blocking form (`snd_write_waiting`) copies what fits and arms `WK_SND` until the DAC frees ring space;
`snd_drain`#68 (`snd_drain_waiting`) waits until the DAC has played the target; caps unchanged (`frames/480 + 300`
ticks as µs; 1 s). ⛔ The wake is inside `hda_stream_service`'s `snd_hw_frames` recompute, BEFORE its `hda_stream_on`
early return — which is always taken for a #66 stream (`snd_open` clears `hda_stream_on`), so a wake at the end of the
function would never fire. BSP tick, IF=0, inside the ISR body's preempt bracket. Re-reading the user buffer after a
resume is valid: the switch restores the slot CR3 and the `int 0xE0` frame's saved `RFLAGS.AC = 1`. Refused contexts
keep `snd_write_held` / `snd_drain_held` (verbatim). waitx P10/P11; M-F2, M-F2b, M-F2c.

## Global-state owners (the percpu audit's last row)

What a CPU-holding wait used to serialize by accident at `-smp 1`, and who owns it now:
`kb_shift` / `kb_ctrl` → the keyboard line owner (reset at a fresh line) · `fb_line_live` → the line owner sets it to
1, the console clears it on newline/CR · `nbline_buf` / `nbline_pos` → the NB reader, which owns the line while
`nbline_pos > 0` · `snd_appl` → the single open stream (`snd_open` refuses a second) · `timer_ticks` → BSP-only, used
for `uptime_ms`#40 and the tick-mode clock · `sys_exit_code` → informational, racy, pre-existing (the per-process exit
code at p+168 is authoritative).

## Network waits (1.57.7 S6)

`sock_connect`#47 (`tcp_connect_ex`), `sock_send`#48 (`tcp_send_ex`) and `icmp_echo`#55 / `icmp_echo_ex`#100
(`icmp_ping_us`) are canonical waits: `tcp_block(cid, mode, tag, ep, gen, dl)` on `WK_TCP|cid`, `icmp_block(pid, seq,
dl)` on `WK_ICMP|pid`; a context that cannot block takes `net_legacy_step` (pre-scheduler: the old spin then hlt;
post-scheduler IF=0: `sti; hlt; cli` under preempt — IF out == IF in). ⛔ A **pre-scheduler SYSCALL** (a
boot-selftest foreground `run`, entered IF=0) is neither: its hlt would have no interrupt to end it, so the four arms
reopen the old preempt-held `sti` window for it (`net_sys_window_open`/`_close`, net_tcp.cyr — `sched_active != 1`
only). S6 shipped without it and DOOM_SELFTEST's `/bin/doom` hung forever in #47 dialling setu's unanswered
loopback:7700 (doom-smoke 3 colours; now a sweep row). Wakes (condition stored under the net lock,
`wq_wake` after the unlock): an ACK that covers or partially covers the held segment, SYN_SENT → ESTABLISHED, every RST,
ESTABLISHED → CLOSE_WAIT, a window-opening ACK, retransmit exhaustion (timer-scan mask), `tcp_close_own` /
`tcp_release_pid`, a matched echo reply. **Deadlines are computed once** (#47's ~8 s from entry; #48's D6 progress clock
restarts only on ACK progress; #100's bound) and are absolute locals on the blocked frame. **ABORT** (`wq_signal_point`
== 1): #47 closes its slot (under `tcp_same_locked`) and returns -1; #48 returns the committed count with its segment
still armed; #55/#100 clear their slot and return -1. **The own-poll effect:** a loopback ACK or echo reply is usually
consumed inside the waiter's OWN `net_poll` before it arms (lo raises no interrupt), which is why the wake arms
(`tcp: ackwake`, `tcp: rstwake`, `icmp: wake`) block directly in `tcp_block`/`icmp_block` with the frame pre-queued and
let `net_tick` deliver it. Busy wake latency is tick-bound (a waiter woken while its CPU runs a spinner waits for that
CPU's next tick): measured, not changed (OQ-5; sock-wait-smoke N8 `busy_rtt64_med_us`).
