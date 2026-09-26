# 2026-09-23 — TCP connection ids have no owner: any process can read, write or close any connection

**Status:** ✅ **RESOLVED 1.57.7 (2026-09-25)** — step S5: every TCP connection and listener and every UDP listener is owned by the process incarnation (pid + epoch) that opened it; `#47`–`#57` and `#106` check the owner first and return −1 to anyone else; ids are released (one FIN) at the owner's exit or fault. Gate: `scripts/smoke/sock-owner-smoke.sh` (sweep row, 94/0: 30 kernel arms O0–A8, U1–U4; ring 3 `SOCK-CHILD-REFUSED`, no `-READ-LEAK`, the release markers; `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
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

## Resolution (1.57.7, 2026-09-25)

**What shipped:** owner tag (pid+1) and epoch stamped inside `tcp_slot_claim_locked` (TCP stride 176: +152 owner,
+160 epoch, +168 local address); a passive child inherits its listener's stamp; UDP stride 64 with the same stamp
and a boot-time buffer pool; `VFS_SOCK` read/write/close and epoll guarded by the owner; `tcp_release_pid` /
`udp_release_pid` from the death chain. A connection that dies keeps its id until its owner closes it (operator
OQ-3). No transfer operation (none asked).

**What the change broke — checked before archiving:** an inherited tagged socket fd is inert in a fork child (cyrius
`sys_close` on it no longer FINs the parent's connection — intended); `udp_unbind`#54 on an already-free id is now
−1 (was 0); `udp_send`#52 returns the frame length and refuses another owner's source port. Found in the end review
and fixed (ENDFIX S5-R1): the demux ignored the local address (+168), so two connections from one port to two 127/8
addresses collided — `tcp_find_conn` now matches it (arm A6d).

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S5-report.json`, `ENDFIX-report.json`.
