# 2026-09-25 — a pipe write into a full ring never blocks, so a writer beside a blocked reader retries at interrupt pace

**Status:** ✅ **RESOLVED 1.57.9 (2026-09-26)** — `write`#1 on a pipe BLOCKS when `a4 == 0` until a reader makes room and returns `len`; with no read end open it returns the partial count, else −1 (no SIGPIPE — agnos has no default action for it); `PIPE_BUF` = 512 (≤ 512 B lands whole, never interleaved); `a4 != 0` keeps the short write; a SIGKILL wakes a blocked writer. Gate: `ipc-wait-smoke` pipe phases at `-smp 1` and `-smp 4` (bulk 4 KB transfers in 68 ms at `-smp 4`; the writer-side wake removed, mutation W1: 1.68 s). See § Resolution.
**Filed by:** agnos, from the 1.57.8 PIPE step report (`open_problems`).
**Checked against:** agnos **1.57.8**, `kernel/core/vfs.cyr` `pipe_write` (~:918) and `pipe_read`, and
`kernel/core/syscall.cyr` `rd5_wait`.
**Severity:** a throughput limit, not a correctness bug. A full ring short-writes, and the caller retries.

## What happens

Since 1.57.8, `read`#5 with a4 = 0 on an empty pipe BLOCKS its caller (`WK_PIPE | buffer`, woken by
`pipe_write`). The write side is unchanged: a full 4080 B ring (`PIPE_RING`) short-writes, and the caller retries,
often with a poll + `sched_yield`#44. When the reader is BLOCKED (state 6) and not parked in `#44`, the writer's
`#44` park draws no directed kick. Each retry therefore parks for up to one interrupt period (10 ms) until the reader
drains the ring. A bulk producer that out-runs its consumer is paced by the tick, not by the consumer.

## The fix

A blocking write, the mirror of `rd5_wait`. A full ring with a live reader and a4 == 0 waits on a key for the
writer's side, and `pipe_read` wakes that key after it advances the tail. The last reader's close and the reader's
death wake it with EPIPE semantics (decide the return value; today a write with no reader is the existing
contract, ABI row 1). O_NONBLOCK (a4 != 0) keeps the short write.

## Gate

An `ipc-wait` phase: a writer pushes 64 KB through a pipe to a slow reader on another CPU at `-smp 4`. It must take
about the reader's time, not ~16 × 10 ms of parks. Also require a mutation that drops `pipe_read`'s wake to go RED.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/PIPE-report.json` (`open_problems[1]`).

## Resolution (1.57.9, 2026-09-26)

Shipped as the mirror of 1.57.8's blocking read (`wr1_key`/`wr1_wait`, 100 ms backstop, S7 kill boundary D). Prior art
followed: Linux `fs/pipe.c` `pipe_write` (blocks on `wr_wait`, EPIPE with a partial count when readers vanish mid-write),
FreeBSD `sys_pipe.c`, POSIX `write()` and `PIPE_BUF`. Departures: no SIGPIPE (agnos signals 9/18/19 only), `PIPE_BUF` = 512
(`_POSIX_PIPE_BUF`) because the ring is 4 KB. ABI row 1.

What it broke: an agnsh pipeline whose consumer exits early (`grep . file | echo x`) or whose stage 2 fails to spawn no longer
returns to the prompt. The cause is in agnoshi — the shell keeps the pipe's read end open while it reaps, so the producer always
sees a live reader (bash's `execute_pipeline` closes it). It was already broken before (kriya's write loop retried ~200 s); blocking
makes it permanent. New sweep row `pipeline-smoke` is red until agnoshi takes the fix filed as
`agnoshi docs/development/issue/2026-09-26-pipeline-keeps-read-end-and-hangs.md` (tested patch inside). kriya's `k_write`
stall bound (20,000 × `#44`, ~200 s) is filed in kriya.
