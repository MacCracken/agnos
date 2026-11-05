# 2026-10-31 — A segment for a connection that does not exist gets no RST, so the peer never learns the connection is gone

**Status:** 🟡 OPEN.
*(Filed from agora **1.12.4**, from its `scripts/agnos-smoke.py` run of agora's agnos build on agnos 1.57.14 in QEMU
(KVM, user networking). Both symptoms below were measured there; the cause is from reading the code.)*
**Checked against:** agnos **bdc587d7** (1.57.14). In `kernel/core/net_tcp.cyr`, `net_handle_tcp_locked` returns 0
for every segment that matches no connection unless it is a pure SYN to a listener (`:1481-1489`). `tcp_find_conn`
skips every state-0 slot (`:1400`), so a slot the retransmit timer declared dead (`:574-576`) counts as no connection.
**Severity:** protocol conformance, medium for consumers. Nothing is lost on the agnos side. A peer can hang forever:
a client that is only reading never learns that its server is gone. A connect to a port with no listener waits out
the client's own SYN timeout instead of being refused.

## What happens

RFC 9293 § 3.10.7.1 (CLOSED STATE, i.e. "TCB does not exist"): "An incoming segment not containing a RST causes a
RST to be sent in response." § 3.5.2 states the same rule, and § 3.5.1 depends on it: a half-open connection is
discovered when the side that still has it sends and gets a reset back. agnos drops these segments silently. A peer
meets this in three ways.

**1. A connection agnos gave up on.** This is the one agora hit. A client stopped reading, its window closed, and
agora's 128 KB send queue for it filled, so agora closed the session (`#50`). A data segment was still held unACKed,
so `tcp_close_locked` folded the FIN into it (`0x19`, `:1216`) or, with nothing held, armed a bare FIN (`0x11`). The
slot became a held FIN slot (state 3, `:1223`). The persist cap that keeps a live zero-window peer from being given
up on (`:1564-1571`) applies only to a held `0x18` in state 2 or 4. A held FIN slot therefore retransmits on the
ordinary backoff (`tcp_retx_rto`, 1 s doubling to 16 s) and is declared dead after `TCP_RTO_RETRIES` (5) resends.
That is about 47 s (1 + 2 + 4 + 8 + 16 + 16 s) after the segment was first sent, or less if its retry count had
grown before the close. Neither the data nor the FIN reached the peer, and no RST was sent.

Giving up is reasonable: the table has eight slots, and Linux also bounds orphaned connections
(`tcp_orphan_retries`). The problem is what happens next. When the peer's application reads, its window reopens and
it sends a window update. Any later data it sends goes the same way. Each segment finds no connection and is
dropped. The peer stays ESTABLISHED until a timer of its own fires. A peer that is only reading never sends data,
and with no keepalive it never learns the connection is gone.

Measured: the agora harness's non-reading client read what QEMU had buffered for it (1,928,178 B), then sent 3 bytes
and waited 120 s. It saw no EOF and no reset. Under user networking the guest's TCP peer is QEMU's slirp, which holds
the host connection open.

**2. A port with no listener.** A SYN to a port nobody listens on is dropped (`:1489`). The client retransmits
until its own SYN timeout, instead of getting a RST (ECONNREFUSED) at once. Measured: a host connection through a
QEMU `hostfwd` to guest port 2424, where nothing listened, was accepted by QEMU at once and ended with EOF after
**86.04 s**, when slirp gave up on its SYN to the guest.

**3. After an agnos reboot.** A peer of any connection from before the reboot sends into a 4-tuple agnos has no
record of. It learns only when its own retransmission timeout runs out. This one is from reading the code; nothing
here measured it.

## The fix (agnos's call)

Answer every segment that matches no connection and is not itself a RST with a RST, shaped as § 3.10.7.1 gives it:

- ACK bit on: `<SEQ=SEG.ACK><CTL=RST>`
- ACK bit off: `<SEQ=0><ACK=SEG.SEQ+SEG.LEN><CTL=RST,ACK>`, where SEG.LEN counts a SYN and a FIN as one each.

Constraints that keep it safe:

- **Behind the existing destination gate** (`:1463-1468`: 127/8 and `net_ip` only). The 1.56.52 broadcast-amplifier
  fix stands, and a broadcast or foreign-destination frame still gets nothing.
- **At most one reply, never larger than the segment that provoked it, and never in reply to a RST.** A reflection
  off a spoofed source then gains nothing, and two hosts cannot ping-pong. The passive-open path already answers any
  SYN to a listener with a SYN-ACK, so this adds no new class of reply.
- **No slot.** Build the reply from the segment's own addresses and ports, as the selftest's `tcpaddr_frame_build`
  (`:1786`) does, so the eight-slot table and the passive reserve are untouched. The RST is sent from interrupt
  context, under the same rules as the SYN-ACK path.

The same branch also covers § 3.10.7.2's LISTEN-state case (an ACK-bearing segment to a listener gets a RST): it
reaches the same `return 0` today.

Optionally, the timer scan could send a RST|ACK when it gives up on a held FIN slot whose peer was demonstrably alive
(it ACKed the probes), so such a peer learns without having to send first. The CLOSED-state RST alone resolves
agora's case, because the peer sends a window update as soon as its application reads.

## How to confirm the fix

- **agora's harness** (`~/Repos/agora/scripts/agnos-smoke.py`, which boots this tree's `build/agnos`): its `dropped`
  check reports how the non-reader's connection ended and passes either way. Today it reports `(no EOF)`. With the
  fix it should report `reset` or `EOF` once the host has read QEMU's buffer.
- **The closed port:** add a second `hostfwd` to a guest port with no listener, connect from the host, and time the
  end. Today it takes 86 s. With the fix it should end at once.
- **In-kernel:** `TCP_ADDR_SELFTEST` already builds raw frames. An ACK to an unused 4-tuple should leave exactly one
  RST in the loopback queue, and a RST to an unused 4-tuple should leave nothing.
