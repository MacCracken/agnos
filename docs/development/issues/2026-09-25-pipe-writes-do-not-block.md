# 2026-09-25 — a pipe write into a full ring never blocks, so a writer beside a blocked reader retries at interrupt pace

**Status:** 🟡 **OPEN**, unslotted. Found by 1.57.8 step PIPE. It is outside that step's scope: the issue it fixed
covered the READ side only.
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
