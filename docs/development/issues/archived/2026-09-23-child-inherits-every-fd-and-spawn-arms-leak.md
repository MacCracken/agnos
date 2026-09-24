# 2026-09-23 — a spawned child inherits every fd its parent holds; `exec_redirect` arms one fd; a failed `spawn_path` leaves `CH_ENDOW` armed

**Status:** ✅ **RESOLVED 1.57.6 (2026-09-24)** — all three asks: `SPAWN_F_CLEANFD` (`a2 | 0x20000`: the child gets fds 0/1/2 + the armed redirect sources + the placed endowment, nothing else); `exec_redirect`#62 `REDIR_ADD` (`0x100|src`, up to 4 pairs) and `REDIR_CLEAR` (`0x200`); spawn arms are **per-process** and cleared on every `#43`/`#37` return, `CH_ENDOW(-1)` disarms. The design also found and fixed a pipe-buffer use-after-free (a cross-process data leak). Gate: `scripts/smoke/spawn-smoke.sh` (sweep row; 14 `SPAWNX-ARMS-CLEARED-<kind>-OK`, `-CLEAN-OK`, `-CAPTURE-STDERR-OK`, `-FDPASS-OK`, `-DUP21-OK`, `-PTY-ENDOW-OK`, `-ARM-PER-PROCESS-OK`, `-PIPE-NO-CROSSTALK`) + `exec-redirect-smoke.sh` (multi-pair `2>&1`). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). It starts agents with `spawn_path`#43, and on
Linux it can capture each agent's stdout and stderr (`serve --agent-output capture`).
**Checked against:** agnos **1.57.5**: `proc_create_user` in `kernel/core/proc.cyr` (`vfs_fd_inherit`,
`chan_place_into_child`), the `#43` and `#62` arms in `kernel/core/syscall.cyr`, and `pipe_read` in
`kernel/core/vfs.cyr`, read in the working tree.
**Consumer impact:** daimon refuses `--agent-output capture` on agnos (2.4.0), because capturing there
would hand every agent every other agent's output pipe.

> Three spawn-time gaps.
> 1. **Inheritance is total.** `proc_create_user` gives each child a copy of its creator's whole fd
>    table (`vfs_fd_inherit`), and there is no close-on-exec. Channels are safe: an inherited channel
>    fd is inert by construction (`chan_auth`). Files and pipes are not inert.
> 2. **`exec_redirect`#62 arms one fd.** A child's stdout can be sent to a pipe, but not its stdout
>    and stderr together.
> 3. **A failed `#43` leaves `CH_ENDOW` armed.** On failure the `#43` arm clears the redirect
>    (`redir_pending_set(0)`) but not the endowment. `chan_place_into_child` runs only at the end of
>    `proc_create_user`, so a spawn that fails before creating the process leaves the arm for
>    whatever this CPU spawns next.

---

## 1. Why inheritance blocks output capture

To capture an agent's output, daimon would hold each agent's pipe read end, and a write end until
the spawn. Every later agent is born with copies of all of them. It could:
- read another agent's output before daimon does (`pipe_read` consumes);
- write into another agent's pipe, forging that agent's output.

On Linux daimon closes every inherited descriptor in the child before exec. On agnos the parent has
no hook between the copy and the child's first instruction.

**Ask:** a close-on-spawn flag per fd, or a spawn form whose child starts with only stdio plus what is
explicitly passed. The channel band already works that way (`CH_ENDOW`); a pipe equivalent, or a
general "endow this fd" arm, would do.

## 2. stdout and stderr

**Ask:** let `#62` arm more than one redirect for the next spawn (at least fds 1 and 2), or accept a
small list.

## 3. The endowment on a failed spawn

daimon closes both ends of a channel whose spawn failed, so `chan_place_into_child` then refuses the
closed endpoint. A consumer that does not close them hands its endpoint to an unrelated process.

**Ask:** clear the arm on `#43`'s failure path, beside the redirect arm, as `#62`'s comment already
promises for redirects ("Either consumer clears the one-shot, including on its own refusal/failure
paths").

---

## Resolution (1.57.6, 2026-09-24)

**What shipped** (ABI §4.8 + rows 3/25/37/43/62/97/99; invariants in
[`docs/architecture/spawn-and-fd-lifetime.md`](../../../architecture/spawn-and-fd-lifetime.md)):

1. **Inheritance.** `SPAWN_F_CLEANFD` = `0x20000` in `#43`'s a2: the child's fd table is fds 0/1/2 (after
   redirects) + every armed `#62` redirect **source** + the placed `CH_ENDOW` endowment; every other slot is
   zeroed on the child's COPY before it becomes READY (the parent's fds are untouched). A CLEANFD child that
   could not get a private fd table is torn down unrun (−3). The unflagged forms still inherit everything
   (legacy, `SPAWNX-LEGACY-INHERITS`).
2. **stdout + stderr.** `#62` op in a1 bits 8+: `0` = replace (the legacy one-pair form), `0x100|src` =
   `REDIR_ADD` (up to 4 pairs, re-points an existing src, refused onto the armed endowment fd), exactly
   `0x200` = `REDIR_CLEAR`.
3. **Arms on a failed spawn.** The redirect set and the endowment are per-PROCESS (they were per-CPU): armed
   by, and consumed only by, the arming process's next child creation. **Every `#43` and `#37` return clears
   the caller's whole arm state**, success or refusal; `spawn`#3 consumes the endowment and clears it on
   every return (and never consumes `#62` pairs); `CH_ENDOW(-1)` disarms (returns 0; was −`CH_E_BADFD`);
   `CH_CLOSE` of the armed end disarms; placement re-checks owner and `chan_epoch`. Recycled slots and
   `fork`#96 children start with none.

**Found and fixed on the way:** the **pipe-buffer use-after-free** — a buffer was freed on the creator's
second close while a child still held an inherited or redirected end, so a later pipe reused the block
(the 1.57.5 control: `SPAWNX-PIPE-CROSSTALK bytes=63`). A buffer now lives until the last reference
ANYWHERE drops (every table, dead ones included, and the `#37` redirect backups), under one `fs_lock` hold
at every dropper. Also: `#37`'s redirect-restore double free, `vfs_create_pipe`'s create-failure double
free, reaped `#43` children never releasing pipe references, an orphan zombie's fd table leaking at slot
reuse, and `vfs_fd_inherit` zeroing the child's base before its `kmalloc` (lead decision D11).

**What the change broke — checked before archiving:** nothing observed across the sweep, `ktest`,
`agnsh-smoke` and the pipe-stream / run37-smp4 / agnsh-bg-smp4 / pipe / redirect / pty-host /
puka-child-stdout (bg + desktop) / aethersafha-clients (bg + fg) harnesses. The per-CPU → per-process arm
change was relied on by no in-tree consumer (all arm and spawn from the same process). `aethersafha-smoke`'s
framebuffer failure is identical on the pre-change kernel. A `-smp 4` triple fault found by the new gate (an
AP left on a reaped process's freed page tables in `do_context_switch`, 7 of 8 boots) was fixed in the same
step; it predated this work.

**Consumer notes:** daimon — `pipe` ×2, `#62(1, o_w)`, `#62(0x100|2, e_w)`, `#43(blob, len |
SPAWN_F_ARGV | SPAWN_F_CLEANFD, env, envlen)`, close the write ends, read to EOF; on an error path between
arming and spawning `#62(0x200, 0)` + `CH_ENDOW(-1)`. agnoshi should `REDIR_CLEAR` on error paths after
`#62`. cyrius wrappers are filed in cyrius
`docs/development/issues/2026-09-24-agnos-spawn-flags-redirect-ops-and-uptime-us-peer.md`.
