# Socket ownership and loopback admission (1.57.7, S5)

Closes `docs/development/issues/archived/2026-09-23-socket-ids-have-no-owner.md` (TCP and UDP) and
`archived/2026-09-23-tcp-server-cannot-be-loopback-only.md` (gaps 2 and 3; gap 1 kernel-side — usable once the cyrius adapter
passes `SOCK_LISTEN_LOOPBACK`). Code: `kernel/core/net_tcp.cyr`, `net.cyr`, `net_ingress.cyr`, the #47–#57 / #106
arms in `syscall.cyr`, the VFS_SOCK paths in `vfs.cyr`. Gate: `scripts/smoke/sock-owner-smoke.sh`. Locking is
S4's ([`net-concurrency.md`](net-concurrency.md)); S5 adds no lock.

## Record layout

TCP: stride `TCP_CONN_STRIDE` = 176 (`tcp_conn_base` is the only stride site). +152 owner **tag** (pid+1; 0 =
kernel-owned or released), +160 owner **epoch** (`proc_epoch[tag-1]` at stamp time), +168 **local address** the
conn speaks from. Meta bit 11 `TCP_FLAG_LO_ONLY` on LISTEN entries. UDP: stride 64, +48 tag, +56 epoch; +16 is the
slot's boot-pool buffer.

## Invariants

1. **The stamp is written only inside the claim.** `tcp_slot_claim_locked` / `udp_bind_owned` write tag and epoch
   under the table lock, before the state publish. A passive child (state 6) ignores the caller and inherits its
   LISTENER's tag+epoch, read in the same demux hold as `tcp_find_listen` and the parent re-check — never the
   interrupted process's identity.
2. **Tag 0 = kernel-owned; no ring-3 path passes the owner check on it** (a caller's tag is ≥ 1). ⛔ **The kernel
   must close every VFS_SOCK fd it creates:** a VFS_SOCK over a tag-0 conn is usable by whoever holds the fd
   (`tcp_fd_owner` returns 0 for it), and proc 0 and every child share the global table.
3. **Authority is re-derived per call.** Each arm checks `tcp_auth`/`udp_auth` first (before `is_user_range`, the
   `len <= 0` shortcut, the sti window and any `net_poll`), and the op re-checks the owner under the lock in the same
   hold as its cb reads/stores; the two checks are redundant defence. Every owner decision that precedes a cb access
   is made in the same hold as that access (waiters snapshot (tag, epoch, gen) and re-check with
   `tcp_same_locked`). No fork/spawn inheritance, no transfer op, no init/pid-0 override: an inherited tagged fd is
   inert, and a non-owner's `close` of its copy is a no-op release (like pipes).
4. **Revocation.** Both death sites (exit#0 and `fault_kill_current`; S7: the one `proc_death_release`) call
   `tcp_release_pid` / `udp_release_pid` before the state-0 store (the epoch match needs the slot not yet
   recyclable). Both are heap-free and IRQ-safe (per-slot holds; LISTENs first so their reap RSTs unaccepted
   children; then every other slot of that incarnation in ANY state — held state-0 slots included). Idempotent.
5. **Held slots (Q1, POSIX fd semantics).** An owned conn that dies by RST or retransmit exhaustion keeps its slot,
   id and queued bytes until the owner's `#50` or death. Unaccepted passive children and kernel conns are never held.
   `tcp_slot_reusable` is the ONE predicate (allocator, passive-reserve counter; S6's pin clause goes into it).
6. **The one release tail unstamps** (`tcp_slot_release_locked`: disarm, unbind, tag/epoch 0, CLOSED last). The RST
   and exhaustion sites publish CLOSED with the tag intact — that is the hold. ⭐ 1.57.7 (S6): closing an ESTABLISHED
   or CLOSE_WAIT conn (#50, VFS close, death) does NOT release it: the close body unstamps it FIRST (the owner's id is
   dead at once) and keeps it as a kernel-held FIN slot (state 3, tag 0) until the FIN handshake ends — it never
   counts against a process and any claim can reclaim it (net-concurrency.md §11).
7. ⛔ **Held-slot trap:** every path that claims an owned slot and exits without handing out its id (connect
   timeout, RST/state 0, S6's ABORT) MUST release it by snapshot (`tcp_slot_release_if(id, st, g0)` or
   `tcp_slot_release_locked` under `tcp_same_locked`) — including when the slot is in state 0 — or Q1 holds it until
   the process dies. `tcp_close`/`tcp_send`/`tcp_recv`/`tcp_accept` (own 0) are kernel-only and no-ops on owned conns.
8. **`net_wire_frame` is the only wire entry** (`net_rx_drain`'s single call; the smoke checks it statically).
   A wire IPv4 frame with a 127/8 source or destination, a source ≥ 224.0.0.0, or our own address as a source is
   dropped and counted (`net_drop_martian`). It is a wrapper, not a flag: an ISR wire drain can interrupt
   `net_lo_drain` on the same CPU, so a "from the wire" global would be wrong. Because of it the TCP destination gate
   admits 127/8 (plus `net_ip`; broadcast and everything else stay refused — the 1.56.52 amplifier fix stands), and
   a NIC-less box (net_ip 0) has loopback TCP.
9. **LOOPBACK class = bind(127.0.0.1).** `#56` class 1 sets `TCP_FLAG_LO_ONLY`; the claim refuses a passive child
   whose SYN was not addressed to 127/8 (a local dial to net_ip included) — enforced ONCE, in the claim, in the same
   hold as the listener lookup. Such a SYN can only originate on this host (invariant 8).
10. **Local address (+168).** Active: `net_src_for(dst)` at the claim; passive child: the SYN's destination; LISTEN:
    0. `tcp_send_pkt_seq` sources every segment from it, so a dial to 127.0.0.2 is answered FROM 127.0.0.2 (the
    route alone would say 127.0.0.1 and the reply would never match). **The demux keys on it too** (1.57.7 ENDFIX,
    S5-R1): `tcp_find_conn(sport, dport, src_ip, dst_ip)` matches +168 against the segment's destination (0 on either
    side = wildcard), and the state-1 duplicate check uses the same key — `127.0.0.1:P -> 127.0.0.2:X` and
    `127.0.0.1:P -> 127.0.0.3:X` are two connections whose server children differ ONLY in +168 (arm A6d).
11. **UDP.** Listener buffers come from a boot pool (`udp_pool_init`, never freed); owner fields as TCP; `#53/#54`
    refuse a non-owner; `#52` refuses a source port bound by ANOTHER owner, kernel ports included (EADDRINUSE), and
    returns the frame length on the wire and the loopback path alike.

## sock_peer#106

`(peer_ip << 16) | peer_port` for a connection the caller owns; -1 for a bad id, not yours, CLOSED or LISTEN. By
invariant 8, `ip >> 24 == 127` or `ip == net_config#61(0)` identifies a local client unforgeably.
