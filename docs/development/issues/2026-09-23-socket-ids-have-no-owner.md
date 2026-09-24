# 2026-09-23 — TCP connection ids have no owner: any process can read, write or close any connection

**Status:** 🟡 **OPEN** — fixed by step **S5** (owner tag pid+1 and epoch stamped inside `tcp_slot_claim`; `tcp_auth` on #48/#49/#50/#57; release at death; the same stamp for UDP ids #51/#53/#54). Builds on S4. Not in 1.57.6. The Path 2 foundation this step builds on — per-process syscall kernel stacks, the deferred `on_cpu` release, preempt-disabling spinlocks, region-7 guard pages (bites S3.1–S3.3) — landed in **1.57.6**; see `docs/development/planning/blocking-syscall-concurrency.md` § Path 2 plan and the roadmap's 1.57.x table.
**Filed by:** daimon (the AGNOS agent orchestrator). It serves an HTTP API and starts agent processes
beside it on the same box.
**Checked against:** agnos **1.57.5**: the `#48`, `#49` and `#50` arms in `kernel/core/syscall.cyr`,
and `kernel/core/net_tcp.cyr`, read in the working tree.
**Severity (consumer's view): high.** On agnos, any agent daimon starts can read the requests arriving
at daimon's API, write answers into its connections, or close its listener.

> `sock_send`#48, `sock_recv`#49 and `sock_close`#50 take a connection id (0–7, one table for the
> whole machine) and check its range, and nothing else. No arm, and nothing in `net_tcp.cyr`'s conn
> record (its layout is at the top of that file), relates a connection to the process that opened or
> accepted it. So a process that names an id owns it. The ids are small, sequential and shared, so
> they are easily guessed.

---

## What a process can do today with an id it did not open

- `#49`: drain another process's receive ring. It reads that process's traffic, and the owner never
  sees it.
- `#48`: send on another process's connection, for example an answer to a request the owner is
  still handling.
- `#50`: close another process's connection. On a LISTEN slot it also reaps that listener's pending
  children (`tcp_close`'s state-5 arm), which takes a server off the network.

`sock_accept`#57 checks only that its id is a LISTEN slot, so a process can also take another
server's pending connections.

## The ask

Record the owning process (and its `proc_epoch`, as the channel band does) when a connection is made:
`tcp_connect` for `#47`, the passive open for a listener's children, `tcp_listen` for `#56`. Then
refuse `#48`/`#49`/`#50`/`#57` from anyone else. The channel band's `chan_auth` is the model already in
the tree: authority re-derived from the owner on every call. If a connection is ever to be handed
over, an explicit transfer (like `CH_ENDOW`) keeps the rule.

## What daimon does meanwhile

Nothing in ring 3 can close this. daimon's AGNOS support (2.4.0) documents it as a known exposure:
until this is fixed, an agent on the same agnos box can interfere with daimon's API.
