# cyrius stdlib — wire the AGNOS server-socket peer to kernel sock_listen#56 / sock_accept#57

**Status**: Filed (request — cyrius-side work, hands-off from agnos sessions per `feedback_cyrius_hands_off`; driven by the user / cyrius agent).
**Date**: 2026-06-18
**Priority**: **HIGH — closed-beta Phase-1 gate.** This is the one remaining piece between "the AGNOS kernel can `accept()`" and "an AGNOS *service binary* can `accept()`." The 2026-06-14 beta rescope makes the founder **Docker AGNOS service-sweep at the server base** (agora / descent / sandhi / web accepting connections) the closed-beta opening gate (Late June / Early July 2026). Until this peer lands, no Cyrius service compiled `--agnos` can host a socket, regardless of kernel readiness.
**From**: agnos 1.45.10 (kernel) vs cyrius 6.2.21 (`lib/net.cyr`).
**Supersedes the "not wanted yet" framing** in `docs/development/issues/2026-06-15-cyrius-stdlib-missing-syscalls.md` (filed at cyrius 6.2.7, AGNOS surface 45–55): inbound-TCP server is now wanted — it is the closed-beta gate — and the kernel surface it was gated on has since landed (#56/#57 at 1.45.5/.6).
**Related**: `kernel/core/syscall.cyr` (#56/#57 dispatch), `kernel/core/net_tcp.cyr` (`tcp_listen`/`tcp_accept`), `docs/development/syscall-additions.md`, `docs/development/agnos-userland-abi.md`. cyrius: `lib/net.cyr` (the fail-loud server shims), `lib/tls_native_conn.cyr`.

## What changed since the 6.2.7 completeness pass

The cyrius 6.2.7 stdlib pass (and the v6.2.3 client-band peer) deliberately fail-loud the server-socket shims because, *at that time*, AGNOS did not expose a ring-3 listen/accept surface — "AGNOS Phase B (inbound TCP)". **That is no longer true.** The kernel landed the server-socket syscalls:

- **agnos 1.45.5** — `sock_listen#56` + `sock_accept#57` (bind+listen merged; accept non-blocking, `net_poll`-driven handshake). `tcp-listen-smoke` 2/2 (host `netcat` → AGNOS accept).
- **agnos 1.45.6** — net-syscall hardening sweep fixed the CRITICAL LISTEN-slot reuse aliasing the reclaim exposed (`tcp_close` now reaps pending children).

So the cyrius comment in `lib/net.cyr:260-262` — *"the ring-3 listen/accept surface isn't exposed yet"* — is now **stale**, and the `#ifdef CYRIUS_TARGET_AGNOS → return Err(1)` branches can be replaced with real kernel wrappers.

## The kernel ABI to wire against (verified from `kernel/core/syscall.cyr`)

### `sock_listen` — syscall **#56**
```
sock_listen(port = arg1) -> rax
```
- `arg1` = local TCP port (validated `1 <= port <= 65535`; else returns `-1`).
- Returns the **listen_id** `0..7` on success, or `-1` (port already bound / conn table full).
- **Merges bind + listen** — the kernel's `tcp_bind(port, ip)` is just `tcp_listen(port)` with `ip` unused, so BSD `bind()` + `listen()` both fold onto this single call. A separate `sock_bind` is deferred kernel-side until a bind-without-listen consumer appears.
- Non-blocking. `a2..a4` unused.

### `sock_accept` — syscall **#57**
```
sock_accept(listen_id = arg1) -> rax
```
- `arg1` = the listen_id returned by `#56` (validated `>= 0`).
- **Non-blocking.** Calls `net_poll()` FIRST (drives the inbound `SYN → SYN_RCVD → ESTABLISHED` handshake under `net_handle_tcp`), then `tcp_accept`.
- Returns the **conn_id** `0..7` of the next ESTABLISHED-but-not-yet-accepted inbound connection, or `-1` if none pending yet (**WOULD_BLOCK — the server poll-loops**), or `listen_id` is bad / not a LISTEN slot.
- The returned conn_id is a **normal connection** usable with the already-wired client-band calls: `sock_send#48` / `sock_recv#49` / `sock_close#50`. `a2..a4` unused.

## The cyrius shims to replace (`lib/net.cyr` @ 6.2.21)

```
sock_bind(fd, addr, port)   : Result   # line 263 — #ifdef CYRIUS_TARGET_AGNOS return Err(1)
sock_listen(fd, backlog)    : Result   # line 276 — #ifdef CYRIUS_TARGET_AGNOS return Err(1)
sock_accept(fd)             : Result   # line 288 — #ifdef CYRIUS_TARGET_AGNOS return Err(1)
```

## Requested wiring (cyrius-side)

1. **`sock_bind` + `sock_listen` → one kernel `sock_listen#56(port)`.** Because the kernel merges bind+listen, the BSD two-call split collapses: have `sock_bind` stash the port and `sock_listen` issue `#56` (or fold both into a single AGNOS path). `#56` returns a **listen_id**, not a BSD fd — so introduce a **listen_id ↔ fd adapter** mirroring the existing **conn_id ↔ tagged-fd adapter** the client path already uses (the same adapter that routes `sys_read`/`sys_write` for socket fds via `#48`/`#49`). `backlog` is advisory on AGNOS (8-slot conn table); accept the arg and ignore it.
2. **`sock_accept` → kernel `sock_accept#57(listen_id)`.** Map the listen-fd back to its listen_id, issue `#57`. On `-1` return `Err(EWOULDBLOCK)` so the existing non-blocking server poll-loop pattern works (mirrors how the client `sock_recv#49` WOULD_BLOCK path is already handled). On success, **wrap the returned conn_id in a tagged socket fd** using the existing client-band adapter — the accepted connection then transparently uses the already-working `sock_send#48` / `sock_recv#49` / `sock_close#50`.
3. **Update the stale comments** (`lib/net.cyr:260-262`, the per-fn `AGNOS Phase B` notes) — inbound TCP is exposed as of agnos 1.45.5.

No new kernel work is requested — the kernel ABI is complete. The only kernel-side deferrals that *remain* (and are NOT blockers for the server peer) are the optional socket-options from the 6.2.7 issue: `SO_REUSEADDR`/`shutdown` no-op cleanly today; a real `SO_REUSEADDR` and half-close are nice-to-haves once server workloads stress them, not gates.

## Consumers unblocked

- **agora** (telnet BBS) — note its fork-per-connection model (ADR 0007) has no AGNOS analog; the AGNOS port maps onto `spawn#3`/`spawn_path#43` + `waitpid#4`, OR runs single-process accept-loop. (Service-side concern, separate from this peer.)
- **cyrius-yeomans-descent** (MUD), **sandhi** HTTP server, sovereign remote-shell, web server — epoll/single-thread accept-loops that map directly onto `#56`/`#57` + the non-blocking `#57` poll.

## Verification once wired

Build a trivial Cyrius echo-server `--agnos`, stage to `/bin`, boot under QEMU+OVMF+gnoboot with SLIRP hostfwd (reuse `agnos/scripts/tcp-listen-smoke.sh` scaffolding), and confirm a host `netcat`/`curl` round-trips through `sock_listen#56` → `sock_accept#57` → `sock_send#48`/`sock_recv#49` → `sock_close#50`. The kernel half already passes `tcp-listen-smoke` 2/2; this proves the cyrius peer end-to-end.
