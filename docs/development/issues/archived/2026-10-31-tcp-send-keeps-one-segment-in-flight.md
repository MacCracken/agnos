# 2026-10-31 — TCP send keeps one segment in flight, and ring 3 cannot wait for "writable", so a server that must not block is RTT-bound

**Status:** ✅ **RESOLVED in 1.57.17 — fix 2 only, the readiness wait (OPERATOR RULING 2026-11-04).** ⏳ **Fix 1, the
send window, is NOT done and stays a later item**: the kernel still keeps one segment in flight, so a non-blocking
sender still pays one round trip per segment — it now WAITS for it instead of polling.
What shipped (ABI rows #19-#21; invariants `docs/architecture/blocking-waits.md` § epoll_wait):
- **`epoll_wait`#21 blocks** when `max` carries **`EPW_TIMED`** (bit 32, `0x100000000`): a4 = timeout ms (> 0 bounded,
  < 0 forever, 0 poll); without the bit it is the old poll byte for byte (a 3-argument call's a4 is a stale r10). A
  canonical C9 wq wait (`ep_wait`, syscall.cyr) on `WK_EPOLL | <TCP slot bits>`, woken by `wq_wake_anybit` from the TCP
  demux (`tcp_demux_epm`: bytes queued, FIN, RST, **the ACK that clears the held segment**, a listener's child
  ESTABLISHED) and retransmit exhaustion; by every ordinary-signal post (`ep_sig_locked`: kill#16, SIGCONT, SIGWINCH,
  SIGCHLD) — **-4** (Linux's -EINTR value) when nothing is ready and the signal is not blocked; by a watched timerfd's
  deadline; and by the lifecycle (SIGKILL / SIGSTOP). #21's number kept; no new syscall.
- **`epoll_ctl`#20 op 3 = SET** (a4 = `EPOLLIN` 0x1 · **`EPOLLOUT` 0x4** · `EPOLLRDHUP` 0x2000; ERR/HUP always; 0 =
  delete) on a VFS fd or **`EP_TCP` (0x10000) `| id`** — the raw conn / listener ids ring 3 holds (they were not
  watchable at all before: #57 returns a conn id, not a VFS fd). **EPOLLOUT = no held segment**; a listener is
  readable when #57 would return a conn. **128 watches** per instance (was 8); `max` ≤ 128 (was 16).
- ⚠ The TCP table is **8 slots** (listeners included), so agora's "64 clients" cannot exist on agnos today whatever
  the watch limit — a separate item.
Proven by `scripts/smoke/epoll-smoke.sh` (`tests/epoll/epw.cyr`), **126/126** at `-smp 1` (TCG) and `-smp 4` (KVM):
the 200 ms timeout returns 0 in 205-207 ms; RX / a listener's child / FIN / RST / a signalfd's signal / an unblocked
signal (-4) / a timerfd each end a wait; a blocked signal does not; SIGKILL reaps a waiter seen BLOCKED (state 6).
**Rates (512 KB, the issue's measurement):** `-smp 4` KVM — **#109 no-wait + one EPOLLOUT wait per segment 4,363 KB/s**,
`#48` blocking 7,682, `#109` + `#44` (agora 1.13.2's shape) 135; `-smp 1` TCG — 3,533 / 3,786 / 4,478. **Bystander**
(one process, a client that never reads beside an echo client): worst steady-state echo **≤ 1 ms** (median 0.5 ms;
the first echo, which carries the guest's console write, 122-192 ms), 1,264 waits in ~3.8 s. Mutations, each red
alone at `-smp 4`: the ACK/FIN/RST epoll wake dropped (B1 stalls: 5 waits run to their 2 s deadline; H1/H2 at their
10 s timeouts); the data-queued bit dropped (R1 at its 10 s timeout; the bystander gets 21 echoes, worst 994 ms);
`ep_sig_locked` never waking (K1 / K2 at their 3 s / 5 s timeouts). cyrius peer filed:
`cyrius/docs/development/issues/2026-11-04-agnos-epoll-timeout-epollout-tcp-ids-peer.md`. agora still needs to switch.
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
