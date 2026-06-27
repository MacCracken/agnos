# agnos — shell pipes are single-foreground/store-and-forward; streaming + SMP-safe pipes need per-process fd tables

**Status**: Filed (follow-on to the 1.46.x two-stage shell-pipe feature). The shipped MVP is correct under `execwait#37` run-to-completion; this tracks the prerequisites for *streaming* and *SMP-safe* pipes.

## Shipped model (correct, but bounded)
`cmd1 | cmd2` (e.g. `iam | anuenue`) is **store-and-forward**: `cmd1` runs to completion under `execwait#37` (IF=0, run-to-completion) with its stdout redirected into the kernel pipe (`exec_redirect#62`), then `cmd2` drains it with its stdin redirected from the pipe (the `read#5` `VFS_DEVICE` tag guard). This is correct **only** because:
- The fd table is **one GLOBAL array** (`vfs_table`, `vfs.cyr:133`). `exec_redirect#62` swaps the global `vfs_table[0]`/`[1]` entry for the child's run (only the *arming* trigger is per-CPU, `syscall.cyr:162`). Nothing else touches fd 0/1 during the window because #37 is run-to-completion.
- EOF comes from **sequencing** (`cmd1` exits before `cmd2` starts → `pipe_read` returns 0 once drained), not a write-end refcount.

## Gaps for streaming / SMP-safe pipes
1. **Per-process fd tables.** Under SMP STEP-2 preemption (the active 1.46.x arc), a concurrently-scheduled proc — or the agnsh prompt — writing the *global* fd 1 during a redirect window would leak into the pipe; a buggy child `close(3)` zeroes agnsh's pipe fd. `proc.cyr:606/645` already mark per-proc fds "future" — they are the prerequisite for both safety and concurrency. Until then, **pipes/`exec_redirect` are a single-foreground-only feature**.
2. **`spawn_path#43` redirect hook.** #43 (non-blocking) applies no redirect (`syscall.cyr:157` + the #43 handler never calls `exec_redirect_apply`). So a producer can't be spawned concurrently with a consumer — required for true streaming (producer + consumer alive together). Needs a #43 redirect path (or per-proc fds inherited at spawn).
3. **Pipe backpressure + EOF semantics.** `pipe_write` (`vfs.cyr:703`) never blocks — it caps 4088 B/call, wraps `%4088`, and **silently overwrites** on overflow (a >4088-byte `cmd1` corrupts with no error the shell can detect). `pipe_read` returns 0 on empty with no write-end refcount, so "empty, writer open" is indistinguishable from EOF. Streaming needs block-on-full backpressure + a write-end refcount (shared with the buffer-leak fix).
4. **N-stage chains.** The redirect copies the fd entry at apply time; the read tail lives in the swapped-in copy and is discarded on restore — fine for one full drain, wrong for persistent N-stage tail state. The agnoshi driver is intentionally 2-stage.

## MVP scope (shipped, documented)
2-stage, sequential, single-foreground, total `cmd1` stdout ≤ 4088 bytes. Documented in `agnoshi/src/run_agnos.cyr` (`sh_run_pipeline`) + both CHANGELOGs. `iam | anuenue` and similar small-output pipes are fully covered.
