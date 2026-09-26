# Foreground exec on Path 2 — `execwait`#37 and kmain's `run` as scheduled children (invariants)

> **Last Updated**: 2026-09-25 (1.57.7 — Path 2 step S3b, bites F0–F5). Built, gated, **NOT burned** (see "Iron").
>
> Code: `sys_execwait`, `spawn_load_child`, `spawn_shape_strict`, `execwait_rsp0_check`, the boot-only
> `kernel_resume` gates in [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) · `proc_wait_child_exit`,
> `fg_latch`, `fg_note_first_entry`, `fg_if0_tripwire`, `execwait_note_first`, ktest T12 in
> [`kernel/core/sched.cyr`](../../kernel/core/sched.cyr) · `proc_fgwait[16]`, `proc_slot_reusable`,
> `proc_is_fg_child` in [`kernel/core/proc.cyr`](../../kernel/core/proc.cyr) · `kernel_run_child{,_keep,_done}`,
> `kernel_exec_boot`, `kernel_exec_foreground`, the boot-only `exec_and_wait` in
> [`kernel/arch/x86_64/ring3.cyr`](../../kernel/arch/x86_64/ring3.cyr). Gate: `scripts/smoke/fg-smoke.sh`
> (`tests/fg`), waitx P13 (`scripts/smoke/wait-ring3-smoke.sh`), `scripts/harness/run37-smp4-test.py`.
> The wait primitive it uses is [`blocking-waits.md`](blocking-waits.md).

## What changed

Until 1.57.7 a foreground program — an `execwait`#37 child, kmain's `run` (the emergency shell, the post-scheduler
boot selftests) and kybernet's `/bin/agnsh` — ran **out of band**: `exec_and_wait` saved the caller's kernel
continuation in per-CPU cells (`exec_ctx`, `kernel_return_*`, and for #37 a per-CPU `ew37_*` snapshot), pinned the
child to the caller's CPU and entered it with `enter_ring3`'s iretq, IF=0; the child's `exit` longjmp'd back through
`kernel_resume`. Such a child could not be preempted, yield, block or nest (one level, `ew37_busy`), accrued no CPU
time, and starved every other process on its CPU while it ran.

Since S3b the child is an **ordinary scheduled IF=1 process** and the waiter **blocks in the kernel**:

- **#37** (`sys_execwait`): load the child with #43's load half (`spawn_load_child(…, strict = 1)`), record it in the
  caller's `proc_fgwait` cell, publish it READY (unpinned, any CPU), then `proc_wait_child_exit` (WK_CHILD | me, no
  deadline). On wake: the RSP0 witness, the ONE status read, `proc_reap_child` under the caller's CR3, clear the cell,
  return the code. The caller shows #99 state 6 while it waits. Nesting is bounded only by the 16-slot table.
- **kmain** (`kernel_run_child(pid, pin)`, reached through `kernel_exec_foreground` from the shared `sh_cmd_run` and
  `kybernet_exec_agnsh`): the same wait, the child BSP-pinned (D22). kmain may block: it is a real process (state 2,
  `on_cpu` = BSP) on its own region-1 stack and the boot CR3; it stays BSP-pinned because that stack IS the BSP boot
  stack. The split `kernel_run_child_keep` (returns with the child dead but UNREAPED, its slot held by the fgwait
  cell) + `kernel_run_child_done` (reap, then clear) exists for KSTACK's fallback phase, which reads the child's data
  page between the two. `kr_refused` tells a refusal from a child that itself exited -1.
- **Before `sched_active = 1`** (the compile-gated `sh_exec("run …")` selftest hooks, bote, a KTEST-build kybernet)
  `kernel_exec_foreground` takes `kernel_exec_boot` — the old out-of-band path, which restores the caller's IF.

## Invariants

- **INV-FG-1 — after `sched_active = 1` no ring-3 code runs with IF=0.** `enter_ring3` (RFLAGS 0x002) is the only IF=0
  source and `exec_and_wait` refuses after the scheduler starts (F4); every other writer of p+152 sets IF
  (`proc_create_user`/`_kclaim` 0x200, fork `| 0x200`, the scheduler's save); IOPL 0, so ring 3 cannot `cli`.
  **Tripwire:** `fg_if0_tripwire(p)` at the #14 and #44 dispatch in `syscall_handler` (the pid `kstack_check_entry`
  returned; one frame load, NO LAPIC read) latches `fg: IF=0 ring-3 caller after sched_active -- foreground invariant
  broken`. Consequence for later steps: every post-scheduler ring-3 process is tick-preemptible and blockable.
- **INV-FG-2 — a waiter W writes `proc_fgwait[W] = c + 1` BEFORE `c` is READY and clears it only AFTER reaping `c`,
  OR when W itself is dying (S7): then C has a pending SIGKILL and the zombie/orphan rules of the death chain own C's
  status.** ⭐ S7 (1.57.7, [`process-lifecycle.md`](process-lifecycle.md)): `#37` publishes the cell under `sched_lock`
  (`proc_fgwait_publish` — a kill already pending on W marks C); a SIGKILL of W also kills C (the kill arm's
  `proc_fg_chain_kill_locked`, and `proc_kill_fg_child` on W's abort path); C is **unstoppable** while W waits on it
  (a tree stop of W returns −2); `#37` returns C's wait status (265 for a SIGKILL). kmain's `kernel_run_child` keeps
  its raw exit code; `/bin/agnsh` is unstoppable and is killed only at B1 / a wait interrupt (it is BSP-pinned).
  While the cell is set and W is live, `proc_alloc_slot` (through `proc_slot_reusable`) does not reuse `c`'s dead slot.
  This closes "ppid 0 = reaped": every kmain child has ppid 0, which the reuse scan reads as reaped, so without the
  cell a concurrent #43 could take a dead kmain child's slot before kmain read its status (recovery `storm`; ktest T12
  row B, mutation M5). **DEP-2:** only while the waiter is alive — a dead waiter's stale cell never pins a slot (T12
  row D2, M5b). `proc_alloc_slot` scrubs the cell of a fresh slot (T12 scrub row, M10). S7's `proc_stoppable` and any
  future orphan reaper must skip a slot for which `proc_is_fg_child` is 1.
- **INV-FG-3 — a child's death stores state 0 and THEN `wq_wake(WK_CHILD | ppid)`** (exit#0 and `fault_kill_current`,
  S3c; S7's death chain keeps it). A missed wake is a hang, not a latency (no deadline): mutations M3/M3b.
- **INV-FG-4 — `sys_execwait` gets a4 as a parameter (read at dispatch) and caches `me` before any block point.** No
  per-CPU cell is read after the wait; the caller may resume on another CPU (fg-smoke MIGRATE: 40 blocking #37s from
  an unpinned process keep its frame and stack intact).
- **INV-FG-5 — the load window has no block point and runs preempt-disabled.** From the first staging write
  (`spawn_path_buf`, the env buffer, the loader cells) to the final `cr3_load(caller)`, `spawn_load_child` is ONE
  `preempt_disable` bracket (the loader brackets itself too); `sched_cpl0_switch_ok`'s live-CR3 rule enforces the
  borrowed-CR3 half independently.

## The shape: strict, and nothing restored

`#62` redirects apply **into the child's private fd table** — for #37 exactly as for #43 — and nothing is restored:
the table dies with the child at its reap (`proc_reap_child` → `proc_destroy_fd_table(c, 0)`, under `fs_lock`). The
per-CPU backup arrays `pcpu_redir_backup`/`pcpu_redir_bsrc` and `exec_redirect_apply/restore` are gone.
**DEP-1:** `spawn_shape_strict` refuses a #37 child that could only get the GLOBAL `vfs_table` (the D11 kmalloc
fallback) — redirect armed or not: a scheduled child there would share proc 0's fds concurrently with kmain (its
`close(1)` would close kmain's console). Operator OQ-7 extended the same refusal to legacy #43 (it used to run
unredirected there). SPAWN_SELFTEST (13)/(14).

## Stated changes (read the code before relying on the old behaviour)

- READY is published AFTER the caller's CR3 is restored (`spawn_load_child` returns a state-3 child; DEP-5). Safe:
  `pd_audit` walks the direct map, every child field is stored before the READY store (x86-TSO; the picker takes
  `sched_lock`), and the caller's CR3 is private.
- `sh_cmd_run` prints `run: exit N` AFTER the reap (a `KSTACK_HW` reap line can now precede it).
- Kernel-launched programs start with **rbp = stack top** (was 0) and **RFLAGS 0x202** (was 0x002; agnsh's was 0x202
  through the retired `exec_preempt` arm) — `proc_create_user`'s initial frame.
- The per-launch SYSCALL-MSR re-assert (STAR/LSTAR/SFMASK/EFER.SCE, 1.40.3 history) moved into
  `kernel_run_child_keep` (`syscall_msr_init`, this CPU only; the entry stub is never rebuilt). A #37 child needs none:
  its caller is already in a SYSCALL.
- `exec: rsp0 restored` (EXEC_SELFTEST) is now checked after the WAKE: the caller comes back through the resched switch
  tail, whose `kstack_install` is what the witness verifies.

## Boot-only out-of-band path

`exec_and_wait` / `enter_ring3` / `kernel_resume` / `exec_ctx` / `kernel_return_*` / `exec_resume_pid` / FG-1 remain
for the pre-scheduler hooks only. After `sched_active = 1` `exec_and_wait` REFUSES (-1, current restored to kmain,
latched `exec: exec_and_wait is boot-only -- refused after sched_active`), and the two `kernel_resume` gates (exit#0,
`fault_kill_current`) are wrapped in `sched_active == 0`. No NMI kill path is needed: nothing can be stuck out of band
after the scheduler starts. Retiring the path entirely (moving the ~40 hooks after the scheduler; DOOM pacing then
becomes a blocking `sleep_ms`) is a planned 1.58 step (OQ-11).

## Latched lines and witnesses

`fg_latch` bits (klug + COM1, once per boot, all in `SMOKE_INVARIANT_DENY`): 1 the INV-FG-1 tripwire · 2
`fg: kernel_run_child cannot block here -- child reaped, -1` · 4 `fg: execwait cannot block here -- refused` · 8
`fg: execwait wait ended abnormally -- child orphaned` · 16 the boot-only refusal. S7 takes bit 32 and up.
`execwait: first scheduled child` (latched once, NOT denied) proves the scheduled #37 route ran — fg-smoke and
run37-smp4 require it (mutation M-WIT).

## Iron (REASONED, iron-read only — QEMU gates do not read CMOS)

CMOS checkpoint slot 0x50: **0x20** when a kernel-launched program becomes READY (`kernel_run_child_keep`; it was
`enter_ring3`'s iretq), **0x21** at its FIRST CPL3 dispatch (`fg_note_first_entry`, in `sched_leave_old`). (0x21 also
appears in `test_procs.cyr` inside `if (0 == 1)`, never executed.) The iron-only risk classes are agnsh's first CPL3
entry through `sched_leave_old` (`sched_fix_live_frame` — the historical torn-frame class) and the SYSCALL-MSR state
on that first entry. Built, gated, NOT burned: the burn is the operator's call.
