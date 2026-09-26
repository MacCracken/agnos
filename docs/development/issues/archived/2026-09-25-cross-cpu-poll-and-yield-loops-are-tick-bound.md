# 2026-09-25 — a poll-and-yield loop across two CPUs now costs one timer tick per round

**Status:** ✅ **RESOLVED 1.57.8 (2026-09-25)**. Step PIPE, scoped by ENDFIX (PIPE-R1), shipped two changes. First, `read`#5 with a4 = 0 on a pipe read end or an owned channel endpoint now BLOCKS (the wq primitive; woken by the writer or sender, and by the last close or death for EOF). Second, `sched_yield`#44's park sends a `#44`-only directed kick. `yield_peer` `-smp 4` went from 9.9 ms to 113–122 µs. Gate: `scripts/smoke/ipc-wait-smoke.sh` (sweep row; tests/ipcw 32 verdicts at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
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

## Resolution (1.57.8, 2026-09-25)

**What shipped:**
- **Blocking reads.** `read`#5 with a4 == 0 blocks on a pipe read end (empty ring, live writer) or an owned channel
  endpoint (empty inbox, live peer). It is the `rd5_wait` C9 loop on `WK_PIPE | buffer` / `WK_CHAN | endpoint`, with
  a 100 ms backstop re-check. a4 != 0 (O_NONBLOCK), len 0 and contexts that cannot block keep −2. `CH_RECV`#97 stays
  non-blocking.
- **Wakers.** `pipe_write`, every pipe-end close, a writer's death (a class wake, `wq_wake_m`), `chan_queue`,
  `CH_CLOSE` and `chan_release_pid`.
- **The directed kick.** A `#44` park publishes `cpu_kickable = 2`. With nothing READY, it IPIs (`0xE1`) one other CPU
  whose value is 2. `#14`, in-kernel `ksyscall(14)` and the idle step publish 1, and neither send nor draw the kick.
- **Measured.** `yield_peer` `-smp 4` KVM: 9,912,481 → 113,323 ns. `-smp 1`: 10,975 → 11,496. `yield_idle` is
  unchanged, and P2c stays at 0 ticks. Pipe/channel ping-pong at `-smp 4`: 65 / 53 µs.
- **Mutations**, each RED: writer wake → 210 ms/round; sender wake → 108 ms; death wake → eof-death 110 ms; kick →
  9.75 ms; kick on `#14` → pause-pair 118 µs; no kick on `#44` → 9.48 ms. ABI rows 5/14/25/44/97;
  `docs/architecture/blocking-waits.md` § Pipe and channel reads and § The directed kick.

**What the change broke — checked before archiving:**
1. **An ABI behaviour change.** A ring-3 caller that POLLS a pipe it also writes, or multiplexes, with a4 = 0 now
   hangs. `tests/spawn/spawnx.cyr`'s crosstalk phase did exactly that (spawn-smoke went RED and was fixed with
   a4 = 1). The kernel reads a4 from `r10` unconditionally, so a 3-argument call is non-deterministic. This is filed
   with cyrius (`sys_read` should pass a4). The agnoshi `agnsh.cyr:141-163` comment "the kernel NEVER blocks on a
   channel" is stale.
2. **The first form of the kick broke `#14`.** It fired from and at `#14` pauses, so two unrelated pausers on two CPUs
   ran at 118–210 µs per pause, and cyrius `_agnos_sock_recv_block`'s 6000-pause backstop expired in under a second.
   The end review found it and ENDFIX fixed it (the kick is `#44`-only).
3. **Accepted residual, not fixed.** Any two `#44` yield loops on two CPUs ping-pong at IPI rate (~100 µs) for as long
   as both yield. The `yield_peer < 1 ms` gate requires this. Filed for an operator ruling as
   `2026-09-25-any-two-sched-yield-loops-kick-each-other.md`.
4. **Not in scope.** Pipe WRITES still do not block. Filed as `2026-09-25-pipe-writes-do-not-block.md`.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/PIPE-report.json`, `PIPE-endreview.json`, `ENDFIX-report.json`; logs under `logs/PIPE/` and `logs/ENDFIX/`.
