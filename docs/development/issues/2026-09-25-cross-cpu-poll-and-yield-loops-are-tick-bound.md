# 2026-09-25 — a poll-and-yield loop across two CPUs now costs one timer tick per round

**Status:** 🟡 **OPEN** — planned for **1.57.8** (operator, 2026-09-25: "file this issue to be done in next release").
Introduced by 1.57.7's Path 2 bite S3d (keep-current + the idle park); found and measured by that step, not fixed in it.
**Filed by:** agnos, from the 1.57.7 S3d step report (`open_problems`, "LEAD ATTENTION").
**Checked against:** agnos **1.57.7** in flight (after bite S3d; not yet released), `scripts/bench-ring3.sh`
(`tests/scbench/`), KVM `-cpu host`.
**Severity:** a throughput regression, not a correctness bug. No gate fails; the kernel is doing what S3d designed.

## What happens

Two processes on DIFFERENT CPUs that loop "poll a non-blocking read (it answers −2), then `sched_yield`#44" at each
other now complete one round per timer tick (10 ms):

| `bench-ring3` `yield_peer` (n = 2000) | ns per round |
|---|---:|
| `-smp 1`, 1.57.7 after S3d | 10,975 (unchanged) |
| `-smp 4`, the kernel before S3d | 530,996 |
| `-smp 4`, 1.57.7 after S3d | **9,912,481** (≈ 18.7× slower) |

`pipe_wr_rd8` (one process writing and reading its own pipe) is not affected: 15,449 ns at `-smp 4` after S3d, against
36,989 before.

## Why

S3d's keep-current rule keeps a RUNNING process on its CPU when only that CPU's idle is READY, and `#44` parks the
caller (`sched_yield_or_halt`: flag, `mfence`, scan, `sti; hlt`) when nothing is READY for this CPU. A peer that is
RUNNING on another CPU is not READY here, so each `#44` parks until the next interrupt. Neither side ever becomes READY,
so nothing kicks the parked CPU early, and every round waits for the tick.

## Who it hits

Any cross-CPU producer/consumer that polls a pipe or channel for −2 and yields between polls: pipes (`read`#2 on a pipe
fd opened non-blocking), channels (`chan_op`#97), and any cyrius/agnoshi/daimon loop written in that shape. At `-smp 1`
the two sides alternate on one CPU and nothing changed.

## What not to do

"Do not park while another non-idle process runs elsewhere" restores the 1.57.6 number, but it also brings back the
100 % spin that S3d removed: agnsh's prompt poll next to a busy background job. S3d recorded this and rejected it.

## The fix (1.57.8)

Make the waits real, so the consumer never needs to poll and yield:
- a pipe read with no data and a live writer BLOCKS on the Path 2 wq primitive (`wq_arm` / `wq_sleep`) and is woken by
  the writer (and by the last writer's close, for EOF); `O_NONBLOCK` keeps −2;
- a channel receive gets the same blocking form (woken by the sender and by the peer's close);
- decide whether `#44` should also wake a parked peer CPU when the yielding process's peer is RUNNING there (a directed
  kick), or leave `#44` as a pure yield once the blocking reads exist.

## Gate

`bench-ring3` `yield_peer` and a new cross-CPU pipe ping-pong (blocking reads) at `-smp 4`: round time back under 1 ms
(the pre-S3d number or better), `-smp 1` unchanged; a mutation that drops the writer-side wake turns the ping-pong
tick-bound again (RED); agnsh's prompt poll beside a busy background job stays off the CPU (the S3d P2c gate stays green).

## Evidence (operator-local, from the 1.57.7 run)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/logs/S3d/B6/bench-ring3.out` (after S3d) and
`bench-ring3-PRE-S3d-kernel-smp4.out` (before), plus `steps/S3d-report.json` `open_problems[0]`.
