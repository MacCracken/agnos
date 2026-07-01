# agnos — streaming / SMP-safe shell pipes (per-process-fd prerequisite SHIPPED 1.47.0; concurrent-spawn + backpressure + N-stage remain)

**Status**: OPEN — **RE-SCOPED 2026-06-30** (the prerequisite half closed + archived; this is now a feature-enhancement track). The named blocker — **per-process fd tables — SHIPPED at 1.47.0 (bite 2b)**, and the pipe write-end refcount / 4 KB-buffer-leak (part of gap 3) at **1.47.0 (bite 2c)** (that doc is now archived). The MVP store-and-forward path (2-stage, sequential, single-foreground, ≤ 4088 B; `iam | anuenue`) is correct and unchanged. **What REMAINS is the streaming / multi-foreground *feature* built on top of the now-present per-proc fd tables** — gaps 2–4 below. Non-MVP; no bug, an enhancement.

## Shipped model (correct, but bounded)
`cmd1 | cmd2` (e.g. `iam | anuenue`) is **store-and-forward**: `cmd1` runs to completion under `execwait#37` (IF=0, run-to-completion) with its stdout redirected into the kernel pipe (`exec_redirect#62`), then `cmd2` drains it with its stdin redirected from the pipe (the `read#5` `VFS_DEVICE` tag guard). This is correct **only** because:
- The fd table is **one GLOBAL array** (`vfs_table`, `vfs.cyr:133`). `exec_redirect#62` swaps the global `vfs_table[0]`/`[1]` entry for the child's run (only the *arming* trigger is per-CPU, `syscall.cyr:162`). Nothing else touches fd 0/1 during the window because #37 is run-to-completion.
- EOF comes from **sequencing** (`cmd1` exits before `cmd2` starts → `pipe_read` returns 0 once drained), not a write-end refcount.

## Done (the prerequisite half — split out + archived)
1. **Per-process fd tables. ✅ SHIPPED 1.47.0 (bite 2b) — no longer a gap.** Each proc now has its own kmalloc'd 32-entry fd table (`proc_fd_base[16]`), inherited at `proc_create_user` and freed at reap; the `execwait#37` redirect targets the CHILD's table (`ew37_cpid`). So a concurrently-scheduled proc / the agnsh prompt writing fd 1, or a buggy child `close()`, can no longer clobber another proc's fds — the **safety prerequisite** for concurrent / streaming pipes is met. (The pipe write-end refcount + 4 KB buffer-leak fix, gap 3's refcount half, also shipped — 1.47.0 bite 2c, archived as `2026-06-27-agnos-pipe-buffer-leak-refcount.md`.)

## Gaps that REMAIN for streaming / multi-foreground pipes (the open feature)
2. **`spawn_path#43` redirect hook.** #43 (non-blocking) applies no redirect (`syscall.cyr:157` + the #43 handler never calls `exec_redirect_apply`). So a producer can't be spawned concurrently with a consumer — required for true streaming (producer + consumer alive together). Needs a #43 redirect path (now feasible since redirect can target a per-proc fd table inherited at spawn).
3. **Pipe backpressure + EOF semantics.** `pipe_write` (`vfs.cyr:703`) never blocks — it caps 4088 B/call, wraps `%4088`, and **silently overwrites** on overflow (a >4088-byte `cmd1` corrupts with no error the shell can detect). `pipe_read` returns 0 on empty, so "empty, writer open" is indistinguishable from EOF. The write-end refcount half landed at 1.47.0 2c (above); what remains is **block-on-full backpressure** + using the refcount to make `pipe_read` return EOF only when the last writer closes.
4. **N-stage chains.** The redirect copies the fd entry at apply time; the read tail lives in the swapped-in copy and is discarded on restore — fine for one full drain, wrong for persistent N-stage tail state. The agnoshi driver is intentionally 2-stage.

## MVP scope (shipped, documented)
2-stage, sequential, single-foreground, total `cmd1` stdout ≤ 4088 bytes. Documented in `agnoshi/src/run_agnos.cyr` (`sh_run_pipeline`) + both CHANGELOGs. `iam | anuenue` and similar small-output pipes are fully covered.
