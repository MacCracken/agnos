# 2026-09-23 — `sock_send`#48 and `sock_connect`#47 hold the CPU while they wait: a send over 2 KB to a local process never finishes

**Status:** 🟡 **OPEN** — fixed by step **S6** (`sock_connect`#47 / `sock_send`#48 — and `icmp_echo`#55/#100 — block only their caller on the Path 2 wait primitive, woken by the RX demux; one segment in flight; after ~8 s without ACK progress `#48` returns the committed count). Needs S3c/S3d/S3b, S4 and S5 first. Not in 1.57.6. The Path 2 foundation this step builds on — per-process syscall kernel stacks, the deferred `on_cpu` release, preempt-disabling spinlocks, region-7 guard pages (bites S3.1–S3.3) — landed in **1.57.6**; see `docs/development/planning/blocking-syscall-concurrency.md` § Path 2 plan and the roadmap's 1.57.x table.
**Filed by:** daimon (the AGNOS agent orchestrator). Its HTTP API answers clients on the same
machine, and it calls MCP servers there.
**Checked against:** agnos **1.57.5**: the `#47` and `#48` arms in `kernel/core/syscall.cyr` (`:10629`,
`:10674`), and `tcp_send` / `tcp_send_chunk` / `TCP_RX_RING` in `kernel/core/net_tcp.cyr` (`:458`,
`:194`, `:67`), read in the working tree.
**Severity (consumer's view): high.** On agnos, daimon cannot send a local client an answer over
about 2 KB without stopping the machine. Measured below.

> Both arms open the `sleep_ms`#41 window, `preempt_disable` + `sti`, for the whole wait. `#47`'s own
> comment says so: *"No other proc is scheduled while connecting (preempt held)"*, for up to ~8 s.
> `#48`'s `tcp_send` sends one chunk at a time, and waits up to 800 ticks (~8 s) for each chunk's ACK
> (`:477`). A connection's receive ring is `TCP_RX_RING = 2048` bytes (`:67`). Once the peer's ring is
> full the window is 0, and `tcp_send_chunk` sends a 1-byte persist probe (`:194`), which also waits.
>
> When the receiver is a process on the same machine, that process has to run to drain its ring, and
> it cannot while the sender holds the CPU. So a send larger than the receiver's free ring space
> never finishes: every probe waits out its ~8 s, one byte at a time, and nothing else runs.

---

## Measured (daimon's guest test, agnos 1.57.5 under QEMU, one CPU)

- **daimon answering a local client.** A client registered 25 agents and sent `GET /v1/agents`. The
  answer's body is 2389 bytes (the same request measured on Linux), sent with one `#48` after the
  headers. The client printed that it sent the request, and nothing more for the remaining 150 s of
  the run.
- **A local client answering daimon.** The test's MCP server, a process in the guest, answered
  daimon's request with a 9 KB JSON-RPC result in one `#48`. The send never returned (160 s).
- With every write split into pieces of at most 1 KB, and a `pause`#14 between pieces, both
  transfers complete, and so does the rest of the test.

## The ask

1. **Do not hold the CPU while `#47` / `#48` wait.** Yield between polls as `pause`#14 does, or
   block the caller until the ACK, window update or SYN-ACK arrives. This is the `sleep_ms`#41
   filing's ask, for the network waits.
2. **Or return short when the peer's window is 0.** Then the caller can yield and retry. Today the
   count is short only when the connection drops.
3. A larger receive ring would move the threshold, not remove it.

## What daimon does meanwhile

daimon 2.4.1 writes every answer on agnos in pieces of at most 1 KB, and yields between them
(`daimon_write_all`). A client that is reading keeps up, and a detached call's relay works the same
way. That is a mitigation, not a fix:
- a local client that stops reading can still stop the machine, from inside daimon's `#48`;
- a connect to a host that does not answer still stops every process for up to ~8 s. daimon's MCP
  forwards and `web_fetch` connect with `#47`.

## Caught in the act (later on 2026-09-23, with QEMU's monitor)

daimon's guest test was run with QEMU held to 30% of a CPU (`systemd-run --user --scope -p
CPUQuota=30%`), on the released agnos 1.57.5. At that speed the kernel refused its TSC calibration,
and its LAPIC reload came out at 25–36 million against 10 million unrestricted. With the monitor
attached, a watchdog sampled the vCPU once the serial log had been quiet for 60 s:

- six samples over 12 s: `HLT=1`, `CPL=0`, `IF=1`, RIP `0x1188cf` (just past the `hlt` of the small
  function that sets a per-CPU flag and halts, `arch_wait`), and **CR3 the same in every sample**,
  a user process's (`0x0ffde000`), not the kernel's `0x1000`. One process held the CPU; nothing was
  scheduled;
- its kernel stack, by the saved-RBP chain: `arch_wait` ← `0x1bd797`, a one-argument function that
  calls it when its argument reaches a global threshold (`net_wait_backoff`) ← `0x1bf6b8`, a loop that
  calls `net_poll`, reads control-block offset `0x80` (the retransmit flags) and calls that function
  (`tcp_send`'s ACK wait) ← `0x21a616`, inside the `num == 48` arm of `ksyscall`. (Identified by the
  code at those addresses in the release binary, which has no symbols.)

It was caught twice, once for each direction of the test's exchange:
- **the test client**, answering daimon's forwarded MCP call: `tcp_send(conn 5, len 1024)`, its data
  the second 1 KB of a 9 KB JSON-RPC result;
- **daimon**, relaying that answer to the client: `tcp_send(conn 3, len 1024)`, a 1 KB piece of the
  answer as read from the child's pipe. CR3 was again the same in all six samples (`0x0ffe4000`).

Neither receiver had stopped reading. Each was slow: with 1 KB pieces and one `pause`#14 between
them, the sender came back before the receiver had drained, and the next piece met a full ring. So
the hold does not need a receiver that stops, only one that falls behind. On a loaded machine that
is any receiver.

daimon 2.4.3 writes 512 bytes at a time with a 1 ms yield between pieces (several rounds of the
scheduler), and yields between the reads it relays. Its test client does the same at 20 ms. That
narrows the window. It cannot close it, because nothing tells a sender the receiver's free space
before `#48` commits. The ask above stands, with this as its measurement.
