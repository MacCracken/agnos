# 2026-10-31 — TCP send keeps one segment in flight, and ring 3 cannot wait for "writable", so a server that must not block is RTT-bound

**Status:** 🟡 OPEN.
*(Filed from agora **1.13.2**: measured with its `scripts/agnos-smoke.py` on agnos 1.57.14 in QEMU, KVM, user
networking. agora has taken what it can on its side; the rest is below.)*
**Checked against:** agnos **bdc587d7** (1.57.14).
- `tcp_send_ex` (`kernel/core/net_tcp.cyr:993-1005`) keeps "ONE segment in flight at EVERY entry", held in the
  connection's single `TCP_RETX_BUF` (1,460 B, `:91`). `tcp_send_chunk` (`:348`) sizes each chunk to the peer's
  window with no in-flight subtraction, because there is never more than one.
- `epoll_wait` #21 (`kernel/core/syscall.cyr:10241`) is a poll, not a wait (`:10302`). It reports a socket only
  when it is readable (`:10277`), and an epoll instance holds at most eight watches (`:10226`).

**Severity:** performance, medium for consumers. Nothing is lost or wrong. A single-process server on agnos sends
to one client at a fraction of what the kernel's own blocking send achieves.

## What happens

agora serves every session from one process on agnos (it has no `fork`). It must never block on one client's
socket, or every other session stalls: in agora 1.12.2 a client that stopped reading held every other session for
**23.8 s**. Since 1.12.3 it sends with `sock_send_dl` #109 and a negative ceiling (no wait). That call commits a
segment only once the one before it is ACKed. The kernel holds exactly one, so each call moves at most one
segment, and the next can go only after a round trip.

Ring 3 then has nothing to wait on for that round trip:

- `epoll_wait` does not block and has no writable event, so it cannot say "the held segment was ACKed".
- `sleep_ms` #41 waits for the 100 Hz tick, so a server paced by it gets one segment per sweep: agora 1.12.4–1.13.1
  slept 20 ms a sweep, about 30 ms with the tick.
- `sched_yield` #44 parks until the next interrupt, and the ACK's virtio-net RX MSI-X is one. agora 1.13.2 yields
  while a drain is moving bytes. That is better, but each segment still costs a halt, an interrupt, a return to
  ring 3 and a pass over every session, where `#48` blocking in `tcp_block` is woken by the ACK itself.

Measured, one 61 KB `read` and four pipelined (245 KB), KVM:

| Send path | `read 1` | 4 × `read 1` | Another session's worst echo |
|---|---:|---:|---:|
| `#48`, blocking (agora 1.12.2) | 2,680 KB/s | 2,859 KB/s | **23,820 ms** (a non-reading client holds the loop) |
| `#109` no wait, 20 ms sleep (agora 1.13.1) | 49 KB/s | 109 KB/s | 31 ms |
| `#109` no wait, yield while moving (agora 1.13.2) | 276–415 KB/s | 475–717 KB/s | 30–31 ms |

The bystander column is why agora cannot simply go back to waiting in the send. The best a non-blocking server can
do today is a sixth to a tenth of what the kernel sends for a blocking one.

## The fix (agnos's call)

Either of these removes the bound. The first helps every sender; the second lets a server wait instead of
polling.

1. **A send window.** Let more than one segment be in flight: a per-connection send buffer that `#48` / `#109`
   copy into and return from, with the kernel sending and retransmitting as the peer's window and ACKs allow. A
   no-wait call then commits what fits in the buffer at once, not one MSS. A non-blocking sender is limited by the
   window instead of the round trip, and a blocking one stops paying a round trip per segment too.
2. **A readiness wait for sockets.** `epoll_wait` that can block until a watched fd is ready or a timeout passes.
   The comment at `:10302` names this as its own design item: a wake from every watched fd type. That needs
   `EPOLLOUT` for a socket (writable: no held segment, or room in a send buffer) and more than eight watches. A
   server like agora watches its listener, its signalfd and up to 64 client sockets, plus a MUD socket for each
   session in the Descent. With that, agora's agnos sweep can wait on readiness exactly as its Linux sweep waits
   on `poll(2)`, and the yield can go.

## How to confirm the fix

agora's harness (`~/Repos/agora/scripts/agnos-smoke.py`, which boots this tree's `build/agnos`) prints the rates on
its `read` and `make-room` lines, and its `bystander` check must stay green (a worst echo under 1 s while a client
reads nothing). With either fix, `read` should approach the `#48` figure above while `bystander` stays at tens of
milliseconds. agora will switch to a readiness wait once one exists.
