# Process lifecycle — end, stop, continue, reap (1.57.7, S7)

A parent can **end** (`kill 9`), **stop** (`kill 19`) and **continue** (`kill 18`) its child, and with
`KILL_TREE` (`sig | 0x100`) every epoch-validated descendant. Every death — `exit`#0, a ring-3 fault, a kill — runs
ONE chain, and an orphan reaps itself. Issue: `docs/development/issues/archived/2026-09-23-parent-cannot-end-stop-or-continue-a-child.md`.
ABI: `docs/development/agnos-userland-abi.md` rows #0/#3/#4/#16/#18/#37/#43/#96/#99 and §4.9.

## States (`proc_table + 8`)

| value | meaning | picked by `sched_next` | reusable |
|---|---|---|---|
| 0 | dead: reaped/free, OR exited-unreaped (a zombie; `#99` reports it as **7**) | no | only via `proc_slot_reusable` + `on_cpu == -1` |
| 1 / 2 / 3 | ready / running / claiming (birth) | 1 only | no |
| 4 | DYING — claimed by a remote killer, or an orphan reaping itself | no | no |
| 5 | STOPPED | no (keep-current keeps only 2) | no |
| 6 | BLOCKED (a kernel wait) | no | no |

Lifecycle state is five pid-indexed arrays in `proc.cyr` (`proc_kill_pending`, `proc_stop_pending` 0/1 direct/2
tree, `proc_term_sig`, `proc_ppid_epoch`, `proc_death_done`), scrubbed at `proc_alloc_slot`, written under
`sched_lock` (the scrub of a CLAIMING slot is the one exception). Every transition decision is a pure table
(`lc_kill_action`, `lc_stop_action`, `lc_tick_action`, `lc_park_action`, `lc_birth_action`, `lc_orphan`,
`lc_parent_live`) that ktest's `[lifecycle]` section drives row by row.

## Identity: the parent is an INCARNATION

`(ppid, ppid_epoch)` names the parent incarnation recorded at birth (`proc_create_user`, `sys_fork`). Every child
test goes through `proc_is_child_of` — authority (`sig_auth_ok` / `reap_auth_ok`), wait-any, the death chain's
zombie scan, `desc_walk` (KILL_TREE and `chan_auth`'s PTY-descendant rule). A recycled parent slot inherits none of
its predecessor's children: with SIGKILL that would be kill authority over a stranger. Authority stays child-only
(D4); KILL_TREE adds descendants-only REACH; no process-group or session reach. A dead-but-unreaped intermediate
still links; a reaped one does not (its orphans are unreachable from the old root — no reparenting, 1.57.8 roadmap).
**Recycle window** (1.57.7 ENDFIX, S7-R1): `proc_alloc_slot` bumps `proc_epoch` and scrubs `proc_death_done` INSIDE
its proctab hold, right after the CLAIMING (3) store, so a dying orphan's final hold (which takes proctab) sees
either `done == 1` or a new epoch — never the dead parent "alive"; `lc_parent_live` also refuses a CLAIMING parent
(ktest T-L12).

## The four boundaries (a kill takes effect at the first)

- **(A) CLAIM** — in the killer's own syscall (`proc_signal_deliver` → `lifecycle_after_unlock`), when the target is
  READY or STOPPED, `on_cpu == -1`, unpinned and was saved from ring 3 (`proc_cs == 0x23`): state 4, then
  `proc_death` from the killer's context.
- **(B) TICK** — `proc_tick_lifecycle` in `timer_handler`, every CPU, between `preempt_enable` and
  `do_context_switch`, for a CPL3-interrupted unpinned current (INV-L2). It also parks a pending stop (1→5 via=tick).
- **(C) B1** — `syscall_handler`'s single exit calls `proc_b1_check(me)`: 3 loads when nothing is pending; a kill
  ends the process there, a stop parks it there with the syscall's result kept on its own kernel stack.
- **(D) WAIT** — a BLOCKED target is interrupted (`wq_interrupt_locked` → `WR_SIGNAL`); the wait's signal point
  (`wq_signal_point` → `lifecycle_park_or_abort`) ABORTs to B1 (a kill) or PARKs in place (a stop) and, after a
  continue, re-arms with the SAME absolute deadline.

Pinned processes (kmain's `kernel_run_child` children — `/bin/agnsh`) are never claimed and never act at the tick:
they end at B1 or a wait interrupt. `/bin/agnsh` is unstoppable (kmain waits on it).

## Invariants

- **INV-L1 — no remote teardown of a kernel continuation.** A process is made 0/4 from another context only by a
  CLAIM, and a claim requires `proc_cs == 0x23`, `on_cpu == -1` and unpinned: no kernel frame of it exists anywhere,
  and INV-11 (`sched_frame_iretq` clears `on_cpu` only after the CPU left its stack and CR3) says no CPU has its CR3.
  Every other death is the process's own (exit, B1, a fault, its own tick). Tripwire: a claim whose `proc_cs` is not
  0x23 latches `lifecycle: claimed a kernel continuation` (denied by every smoke).
- **INV-L2 — the lifecycle tick path acts only on a CPL3-interrupted frame.** A CPU interrupted in ring 3 holds no
  kernel lock, so the death chain may take, from the timer ISR, locks the `smp.cyr` banner otherwise calls non-ISR
  (proctab, fs, heap, pmm, flock, chan/snd/shm, console if a callee kprints). The display hand-back runs in the ISR
  (`gpu_release_pid_isr` drops ownership at once) but its disk spill + kprint are deferred to the next B1
  (`klug_spill_owed`). TLB shootdowns there are IF=0 with a bounded ack wait (the fault path's shape).
- **Every transition INTO 5 re-checks the pending kill and the parent's liveness under the lock** and refuses when
  set / gone (a process about to die is never parked; a stopped process whose parent is gone would have no
  authority left that could continue it — D-33). A dying parent continues its stopped children.
- **A dying process creates no children; a tree-stopped one creates stop-pending children** (`proc_birth_check`,
  under `sched_lock` after the child's ppid/epoch stores) — a spawning agent cannot outrun a tree kill or stop.
- **Stoppability**: a user process whose parent waits on it in the foreground (`proc_fgwait[ppid] == t + 1`) cannot
  be stopped; a tree stop skips it and returns −2.
- **Every signal point runs with `preempt_count == 0`**; a violation latches `lifecycle: signal point with preempt
  held` and never spins (a wait unwinds to B1, which parks with preempt 0).

## The one death chain (`syscall.cyr`)

`proc_death(pid, code, sig, via)` = `proc_death_release` (exit code + term sig; flock, snd, shm, chan, the scanout,
tcp, udp, the keyboard line, the raw-disk arm **if this process armed it**, spawn arms, its fg cell) → one trace
line for a death by signal → `proc_death_finish`. **Review rule: no other function calls a `*_release_pid`.** The
chain contains no wait.

`proc_death_finish` REAPS BEFORE IT PUBLISHES (D-31): while the dying process still stands as 2/4 (not reusable) it
reaps its zombies; the final scan-and-publish is ONE hold of `proctab_lock` (outer) + `sched_lock` (inner), so a
child dying concurrently either is in the scan or sees `proc_death_done[parent] == 1` / state 0 and is an orphan
(D-32). A zombie for a live parent (or kmain's fg child) publishes state 0 + SIGCHLD + `wq_wake(WK_CHILD|pp)`; an
ORPHAN publishes 4, frees its own fd table and address space (`proc_reap_orphan` — self: `cr3_load(0x1000)` first,
never the reap fence's self-owned path), then publishes dead AND reaped in one proctab hold. The reuse tripwire in
`proc_slot_reusable` (`proc: orphan zombie recycled unreaped`, denied) fires if an orphan slot with a live address
space is ever handed out again — the D-29 leak (≈ 6 MB per orphan) this closes. kmain's own children (ppid 0) are
never orphans: kmain reaps them through `fgwait`.

## Locks, IRQs, preempt

`sched_lock` stays the innermost IF=0 leaf: state tests, pending stores, the claim/stop/cont transitions,
`wq_interrupt_locked`, the tree walk (≤ 16×16 pure loads), the finish publish — no klug, no release, no kick under
it. Every S7 acquirer brackets with `kbd_irq_save`. `klug_lock_word` (smp.cyr) serializes every klug append: a leaf
below everything, IRQ-saved, BOUNDED (1,000,000 pause iterations, then lock-free with `klug_lock_timeouts`
counted — a fault inside a copy must not turn the post-mortem into a hang). Signal bits are set with `atomic_or64`
and cleared (signalfd) with `atomic_and64`.

## Trace format (klug only — the smoke's oracle; S8 relies on it)

```
lifecycle: #<seq> kill pid=0x<p> sig=0x<s> via=<claim|tick|b1>
lifecycle: #<seq> stop pid=0x<p> via=<claim|tick|b1|wait>
lifecycle: #<seq> cont pid=0x<p> via=<sig|orphan>
lifecycle: #<seq> orphan pid=0x<p> reaped
```
One klug_lock hold per line, `seq` taken in the same hold, a `\n` first when the ring does not end at a line
boundary. exit#0 and fault deaths emit no line.

## Limits and risks

- A stopped keyboard reader KEEPS the keyboard line until SIGCONT or death (a stopped reader keeps its terminal).
- A kill of a READY target whose `on_cpu` is still set is pending, not claimed, and dies ≤ one slice later.
- The tick-path death runs the whole chain (and any orphan self-reap) in the timer ISR on the dying process's
  RSP0 stack before EOI; its residency was not measured in 1.57.7 (lean mode).
- A post-scheduler ppid-0 child that kmain does not fg-wait leaks as before (none exists in production).
- New iron-only surfaces (built and gated, NOT burned): the tick-path death, the B1 park (`int 0xE0` from the
  syscall exit), the self-reap's CR3 hand-back, the ISR display hand-back.

## Resource limits

1.57.7 (S8). Ring-3 contract: `spawn_limits`#107 and the #3/#4/#27/#37/#43/#96/#99 rows + §4.8 (−7) of
[`../development/agnos-userland-abi.md`](../development/agnos-userland-abi.md). Gate: `lifecycle-smoke.sh` (the S8
phases, HIGH last) and ktest `[limits]` K1–K5.

**Storage.** Parallel pid-indexed arrays in proc.cyr's shared region (the 176 B `struct Process` stride is frozen):
`proc_mem_cap` / `proc_cpu_cap` (the process's own effective caps, 4 KiB pages / 100 Hz ticks, 0 = none) and
`proc_arm_mem` / `proc_arm_cpu` (the one-shot arm for its NEXT child). No lock — the S2 arm argument: a pid's arm
cells are written only by its own #107, its own syscall exit, `proc_alloc_slot` (slot dead) and the death chain; its
cap and high-arena cursor cells only while the slot is CLAIMING (`proc_alloc_slot`, `proc_create_user`, `sys_fork`).

**The arm lifecycle — exactly ONE consume site.** `syscall_handler` clears the caller's arm (`lim_arm_clear(sh_me)`)
after the dispatch of every `#3`/`#37`/`#43`, before B1 — success, failure and refusal alike. Resets (not consumes)
happen at slot recycle (`proc_alloc_slot`, under S2's caller-slot guard), at the bootstrap (`spawn_arms_reset_all`)
and in `proc_death_release`. In-kernel `ksyscall(3/37/43)` bypasses the site; inert, because pid 0 never arms.

**Placement and inheritance.** `proc_create_user` reads the creator's `lim_eff(own cap, arm)` FIRST (P is current at
load in #3/#37/#43; kmain has no caps and never arms, so nothing that existed before 1.57.7 is capped) and stores it
after the birth check. `lim_eff` returns the arm only when it is lower: an arm can never raise. `sys_fork` copies the
caps (never the arm) and the high-arena cursor; a fork child starts at 0 ticks.

**Invariant — for every capped process, footprint ≤ `proc_mem_cap` at all times.** The footprint is COMPUTED, never
accounted (`proc_user_pages_cr3`: 512 × the present+user 2 MB PDEs of the low PD[0..510] and every present+user
PDPT[128..511] PD — the walk `proc_free_address_space` tears down; `#99`'s RSS is the same number), so munmap credits
back by itself and nothing can drift. Three mechanisms keep the invariant: (1) the loaders' pre-pass refuses an image
of (distinct PT_LOAD pages + 1 stack page) × 512 over the child's cap before allocating anything (#43 −7, #3/#37 −1);
(2) `sys_mmap` refuses (returns 0) a mapping that would pass the cap, before the free-RAM pre-count; (3) the
**no-overwrite rule**: `sys_mmap` never maps over a present PDE. Without (3) a leaked, uncounted frame escapes the cap.

**Why the no-overwrite rule was needed (fork).** The low mmap cursor is GLOBAL and `sys_munmap` rewinds it LIFO, while
fork copies every low page: P maps A at the top, forks C, munmaps A — the cursor rewinds onto a page still live in C,
and C's next mmap overwrote its own PDE (data clobbered, 2 MB leaked for good). A span with any present page is now
abandoned for the high arena. Likewise `proc_himmap_next` is per-INCARNATION: scrubbed at slot recycle and copied by
fork (an uncopied cursor started at the floor, on the child's copied high pages).

**Overlapping PT_LOADs are refused** (`elf_load_pages`, −5 / −1): the mapping loop stores each page's PDE blindly, so two
segments in one 2 MB page orphaned the first frame (2 MB per spawn, reachable from ring 3 with a crafted ELF). Mapping
the page once with the union of permissions is excluded — text+data in one page would be W+X.

**The CPU cap — `lim_cpu_tick_head(tl_p)`** runs at the head of `proc_tick_lifecycle`, after its pid bounds checks and
before its kill/stop fast check, in its OWN `sched_spin_lock` section (non-reentrant xchg: nesting it inside the
body's section would deadlock the CPU in the timer ISR with IF=0). `timer_handler` has already charged this tick. At
`proc_ticks ≥ proc_cpu_cap` it marks `SIGXCPU` (`proc_kill_mark_locked`, first kill wins; state re-checked under the
lock). The body then kills at THIS tick when its guards hold (`via=tick`, wait status 280), else at B1 or the wait
signal point. Per-tick cost for an uncapped process: one load and one compare.

**Accounting limits (the ABI says so plainly).** Budgets are per process — each child, fork included, starts at 0
ticks, so a capped agent can hand work to a fresh child; 10 ms granularity, sampled; blocked, stopped and halted time
is not CPU time; kernel time is under-charged while a syscall runs IF=0 (pending ticks coalesce into one at SYSRET).
Charging is real time because S1b measures the 100 Hz reload against the PM timer on every CPU.

**The `#99` foreign-walk residual.** `proclist` walks other processes' tables without a lock; a concurrent reap can free
a table mid-walk. Every pointer the walk follows passes `ptw_pt_ok` (4 KB aligned, inside the page-table pool
`[0x400000, 0x10000000)`) before `pmm_kva_for_access`, so the worst case is a stale count, never a dereference
outside the pool.
