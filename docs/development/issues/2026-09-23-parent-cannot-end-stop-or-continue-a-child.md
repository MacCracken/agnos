# 2026-09-23 — a parent cannot end, stop or continue its child: signals are pending bits with no default action

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
