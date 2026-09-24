# 2026-09-23 — a spawned child inherits every fd its parent holds; `exec_redirect` arms one fd; a failed `spawn_path` leaves `CH_ENDOW` armed

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
