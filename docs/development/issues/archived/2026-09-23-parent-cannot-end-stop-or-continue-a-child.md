# 2026-09-23 — a parent cannot end, stop or continue its child: signals are pending bits with no default action

**Status:** ✅ **RESOLVED 1.57.7 (2026-09-25)** — step S7: `kill`#16 9 ends a child through one death chain (wait status **265**), 19 stops it (`#99` state 5), 18 continues it, 0 probes; `sig | 0x100` = `KILL_TREE` (−2 when a tree stop had to skip a member); wait status `0x100 | sig`, a fault `128 + vector` (142); `#99` lists unreaped children as state 7. Gates: `scripts/smoke/lifecycle-smoke.sh` (sweep row; KILL*, STOP*, TREE*, WSTAT, ORPHAN* at `-smp 1` and `-smp 4`) and `ktest` T-L* (109 assertions). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). It supervises agent processes and has to stop,
pause and resume them.
**Checked against:** agnos **1.57.5**: `kernel/core/syscall.cyr`, `kernel/core/proc.cyr`,
`kernel/core/vfs.cyr`, read in the working tree. Every line cited below was opened.
**Consumer impact:** daimon's agent stop cannot finish for an agent that does not exit by itself, and
pause/resume are impossible. The same holds for any supervisor, and for a shell's job control.

> `kill`#16 records a pending bit and nothing else. No signal has a default action: nothing in the
> kernel ends, stops or continues a process because a signal is pending. A process sees a signal only
> if it reads a signalfd. So SIGTERM works for a child that asks for it, which is right, but SIGKILL
> has no teeth. A parent has no way to end a child that will not end itself, and no way to suspend
> one.

---

## 0. What is NOT a gap

- **Authorization is right.** `proc_may_signal` (`proc.cyr:1364`) lets init signal anyone, and anyone
  else signal itself or its own direct child. That is exactly the reach a supervisor needs.
- **The graceful path works.** A child that reads a signalfd (`signalfd`#18, `vfs_read_signalfd` at
  `vfs.cyr:777`) sees SIGTERM and can shut down cleanly. daimon's agents will do that.
- **Reaping works.** `waitpid`#4 polls, returns the exit code, `-2` while running, `-1` for "not your
  child" (the `-2`/`-1` contract daimon's shim already relies on).

## 1. The gap, stated exactly

- `syscall.cyr:8721`, the `#16` arm, after its bounds and authorization checks:
  `store64(&proc_signals + arg1 * 8, sig_pending | (1 << arg2)); return 0;`
- `proc.cyr:1389` `proc_send_signal` does the same, and `proc.cyr:1398` `proc_check_pending_signals`
  only sets `pending_signal_flag`.
- The readers of `proc_signals` across `kernel/` are these, the signalfd read, the epoll readiness arm
  for `VFS_SIGNALFD`, and a selftest. None of them ends, stops or continues a process.

So a SIGKILL sent to a child that never reads its signalfd leaves the child running. A child that
hangs, or that simply ignores SIGTERM, holds its slot of the 16-entry process table (`proc.cyr:118`)
for the rest of the boot.

## 2. The ask

1. **An unconditional end** for a process the caller may signal: SIGKILL (9), or a dedicated call.
   - It takes the same path as `exit`#0, releasing channels, shm, flock and so on.
   - `waitpid`#4 should be able to tell it from a normal exit. daimon reports
     `128 + signal`, the shell's convention; anything distinguishable will do.
2. **Stop and continue** (SIGSTOP 19 / SIGCONT 18, or dedicated calls): the target is not scheduled
   while stopped, and resumes on continue. daimon exposes
   `POST /v1/agents/{id}/pause` and `/resume`.
3. **Optional:** a default action for SIGTERM when the child has not claimed it (no signalfd watching
   it): end the process, as on Linux. With (1) this is not required. daimon sends SIGTERM, waits a
   grace period, then SIGKILL.
4. **Lower priority: reach descendants.** On Linux daimon signals an agent's process group, so the
   agent's own children stop with it. agnos has no groups, but the ppid chain exists
   (`chan_pty_descendant` walks it). A "this child and its descendants" form would cover it.

## 3. What daimon does meanwhile (2.4.0)

- A stop sends SIGTERM and waits. An agent that exits is collected and reported. One that does not
  stays *Stopping*, and daimon records that it gave up.
- Pause and resume answer 501 on agnos.
- Both change as soon as (1) and (2) exist.

## Resolution (1.57.7, 2026-09-25)

**What shipped:** ask 1 SIGKILL through the one chain (exit#0, the fault kill and SIGKILL share it; an orphan reaps
itself, so its address space no longer leaks at slot reuse); ask 2 stop/continue (a stopped process resumes exactly
where it stopped, a kernel wait with the same absolute deadline); ask 3 a SIGTERM default action **declined** (D3:
any other signal stays a pending bit, now set atomically); ask 4 `KILL_TREE` (child-only authority,
descendants-only reach, epoch-validated). A kill of a `#37` waiter also kills its foreground child. Latency:
immediate for an off-CPU ring-3 target, ≤ one tick while it runs, at the end of its syscall, or at once in a kernel
wait. ABI rows 4/16/37/99, §4.9; `docs/architecture/process-lifecycle.md`.

**What the change broke — checked before archiving:** found in the end review and fixed (ENDFIX S7-R1): a recycled
parent slot looked alive between its claim and its epoch bump, so an orphan dying then could publish itself as a
zombie nobody could reap. S7 left the `RING3_SELFTEST` flag build un-buildable (fixed by S8). By design: a `#37`
foreground child cannot be stopped while its parent waits (a tree stop returns −2, operator OQ-8); there is no
reparenting on parent death (operator OQ-9, roadmap 1.57.8). daimon's `tests/agnos` asserts of the 1.57.5 limits
("pause is refused", "no signal ends a process yet") are expected to go red.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S7-report.json`, `ENDFIX-report.json`.
