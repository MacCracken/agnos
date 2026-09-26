# 2026-09-23 — a TCP server cannot be loopback-only: `sock_listen` takes no address, TCP to 127.0.0.1 is dropped, and accept gives no peer address

**Status:** ✅ **RESOLVED-KERNEL 1.57.7 (2026-09-25)** — step S5 (consumer adapter pending in the cyrius filing): `sock_listen`#56 takes an address class in arg1 bits 32–39 (0 = ANY, 1 = LOOPBACK, `SOCK_LISTEN_LOOPBACK = 0x100000000`); 127.0.0.0/8 is admitted as a TCP destination; the wire drops 127/8 and our own address as a source; `sock_peer`#106 returns the peer address. Gate: `scripts/smoke/sock-owner-smoke.sh` (SOCK-LISTEN-LO, -LO-REFUSES-NETIP, -ANY-LO, -LO8, -PEER). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). Its HTTP API is unauthenticated until daimon's
2.5.x, so it listens on 127.0.0.1 by default (daimon's VULN-011). A local client reaches it there,
and nothing on the network can.
**Checked against:** agnos **1.57.5**: `kernel/core/syscall.cyr` (`#56`, `#57`),
`kernel/core/net_tcp.cyr` (`tcp_listen`, `net_handle_tcp`), `kernel/core/net.cyr` (`net_src_for`,
`net_is_loopback`), read in the working tree.
**Consumer impact:** on agnos daimon cannot keep its API off the network, and a local client cannot
reach it at 127.0.0.1. daimon warns and audits at start (`http.listen.not_loopback`).

> Three gaps, one outcome.
> 1. **`sock_listen`#56 takes a port and no address.** `tcp_listen` records the port only; the
>    arm's comment says *"the kernel's tcp_bind is just tcp_listen, ip unused"*. A listener serves
>    the NIC's address, so there is no loopback-only server.
> 2. **TCP to 127.0.0.1 is dropped.** `net_src_for` gives 127.x traffic a 127.0.0.1 source, which
>    made on-device loopback TCP work at 1.56.34. But `net_handle_tcp` begins
>    `if (dst_ip != net_ip) { return 0; }` (added 1.56.52 against broadcast SYN amplification), and
>    that refuses 127.0.0.1 too.
> 3. **Accept gives no peer address.** There is no `getpeername`, so a server cannot tell a local
>    client from a remote one, or rate-limit per client. daimon falls back to one shared bucket.

---

## Measured (2, in daimon's guest test)

A client inside the guest makes daimon's 17 HTTP checks with `sock_connect`#47:

- to `net_ip` (10.0.2.15 under QEMU): **17 of 17 passed**;
- to `0x7F000001` (127.0.0.1): **every request failed**. No answer came, and the first check
  (`GET /v1/health`) already failed.

## The ask

1. **An address for `#56`:** at least "this host only" (127.0.0.1) as well as "the NIC's address".
   The TCP arm then admits a SYN for that listener only when its destination matches.
2. **Admit 127.0.0.0/8 in `net_handle_tcp`'s destination check.** Those frames only ever arrive
   through the loopback queue (`net_is_loopback`), so the check still refuses broadcast.
3. **The peer address of an accepted connection:** a getter, or an out-parameter on `#57`.

## What daimon does meanwhile

- daimon listens where the kernel puts it (the NIC's address), and warns and audits that its API is
  reachable from the network.
- Its Host check still refuses a request that does not name a loopback host, which stops browsers
  and DNS rebinding but not a direct network client.
- Its guest test dials the guest's own address.

## Resolution (1.57.7, 2026-09-25)

**What shipped:** gap 1 — the class bits (a LOOPBACK listener admits only SYNs addressed to 127/8, which can only
originate on this host; a local dial to net_ip is refused); gap 2 — all of 127/8 completes, the reply comes from the
address dialled, and `net_wire_frame` is the only wire entry (martian filter); gap 3 — `sock_peer`#106
`(conn_id) → (peer_ip << 16) | peer_port / −1`, owner-checked. Every pre-1.57.7 `#56` value decodes to class 0.

**What the change broke — checked before archiving:** `#56` now refuses a non-zero bit in 16–31 or 40–63 (−1). The
end review found the demux ignoring the local address (two SYN_SENTs from one port to 127.0.0.2 and 127.0.0.3
collided) — fixed in ENDFIX (S5-R1). **Consumer side still open:** cyrius's server adapter must pass
`port | SOCK_LISTEN_LOOPBACK` for a 127/8 bind and fail closed on an older kernel, and a `sys_getpeername` over
`#106` is asked for — both in cyrius `docs/development/issues/2026-09-25-agnos-sock-peer-spawn-limits-wait-block-kill-tree-peer.md`.
daimon can drop its `http.listen.not_loopback` warning on ≥ 1.57.7 with that cyrius.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S5-report.json`, `ENDFIX-report.json`.
