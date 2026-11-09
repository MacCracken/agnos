# 2026-11-06 — there is no readiness wait on one fd, so a client cannot run a deadline of its own

**Status:** ✅ **RESOLVED in agnos 1.57.18** (2026-11-08, both halves). **`epoll_wait`#21 watches `#97` channel endpoints**
(EPOLLIN = inbox non-empty or peer gone; EPOLLOUT = the peer's inbox has room; peer gone = IN | OUT | HUP; authority
re-derived on every pass, so an inherited claim cannot be watched) — one watch on a kept instance with `EPW_TIMED` is the
readiness wait on one fd with a deadline in ms that consumes nothing, for channels, sockets, signalfd and timerfd. The
cyrius `fd_wait_ready` on it is filed (`cyrius/docs/development/issues/2026-11-08-agnos-fd-wait-ready-and-sock-connect-deadline.md`).
The Related ask: **`sock_connect`#47 `SC_TIMED`** (a3 bit 32; then a4 = ms) bounds the connect at min(a4, ~8 s) measured
once from entry, and a4 = 0 is a non-blocking connect finished by `EPOLLOUT` on `EP_TCP | id` (measured: a 1.5 s deadline
returns at +2.6–9.9 ms past it). Gate `scripts/smoke/pty-backpressure-smoke.sh`. ABI rows 20, 21, 47.
*(Filed from thoth **0.55.1**. It also holds thoth's F8 gate, the AGNOS window.)*
**Checked against:** agnos **107ad763** (1.57.17) and cyrius **6.7.18**, whose `fd_wait_ready` answers -38 on agnos ("agnos has no poll").
**Severity:** medium. A turn can sit far past its deadline, and a surface cannot wait on a channel without spinning.

## What happens

sandhi's stream loop waits with `fd_wait_ready` and gets an idle turn between reads. On agnos that call declines, so the loop goes straight into a blocking read and no idle turn ever comes.

thoth's `[hoosh].timeout_ms` counts frames at that idle turn, because hoosh sends a `: keep-alive` comment through a silent stream every 15 s and any byte restarts a read deadline. Measured on agnos with a 2.5 s deadline and a comment every 500 ms: the turn ran 10.7 s, until the gateway hung up. On Linux the same shape stops at its deadline: 1.5 s with a 1.5 s deadline, and 18.0 s with an 18 s one against a real hoosh. hoosh's own keep-alive to its clients has the same dependency when it reads a remote provider.

`epoll_wait#21` blocks with a deadline since 1.57.17, and watches signalfd, timerfd and TCP. It does not watch a `#97` channel, which is the other half of this: the window's event channel cannot be waited on, so a surface polls and calls `sys_pause` (thoth's roadmap, F8).

## The ask

A wait on one fd with a deadline in milliseconds, for sockets and channels, that does not consume anything: readable, deadline passed, or an error. `epoll_wait#21` covering channels would serve too, with cyrius's `fd_wait_ready` built on a one-shot epoll set.

**Related:** `sock_connect#47` blocks about 8 s on its own clock, with no deadline from the caller: a turn to a blackholed address took 8.7 s, and a listener that never accepts 8.2 s. thoth's startup probe asks for 3 s, which agnos has no way to honour. A timeout argument, or a non-blocking connect that this wait can finish, would close it.

## What thoth does meanwhile

The deadline holds against true silence, through the peer's read timeout. A stalled stream with keep-alives runs until hoosh's own 300 s, and the roadmap carries that as a degradation.
