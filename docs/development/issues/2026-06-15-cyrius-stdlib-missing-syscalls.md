# cyrius stdlib — missing AGNOS syscalls surfaced by the 6.2.7 agnos-completeness pass

**Status**: Filed (informational / kernel-gap tracking) — **nothing here blocks AGNOS today**.
**Update 2026-06-18**: the inbound-TCP-server premise in §2 ("only if inbound-TCP server
(Phase B) lands") is now **superseded** — the kernel landed `sock_listen#56`/`sock_accept#57`
(agnos 1.45.5/.6) and inbound TCP IS now wanted (the closed-beta founder server-sweep).
That work is tracked separately in `2026-06-18-cyrius-agnos-server-socket-peer.md`. The
`setsockopt`/`shutdown` socket-options in §2 remain genuinely optional. Everything else here
stays correctly fail-closed/steady-state.
**Date**: 2026-06-15
**From**: cyrius 6.2.7 (the stdlib agnos-completeness pass that resolved sandhi's
filed cascade — see cyrius `docs/development/issues/2026-06-15-cyrius-thread-agnos-clone-dispatch.md`).
**AGNOS surface at filing**: 1.45.9 — syscalls 0–42 (frozen base + 1.43.x graphics/
timing/input) + the 1.45.x net/entropy/clock band 45–55.
**Affects (if any added)**: `kernel/core/syscall.cyr`, `docs/development/agnos-userland-abi.md`,
`docs/development/syscall-additions.md`.
**Related**: `syscall-additions.md` (current surface), `agnos-userland-abi.md`
(contract), proposal `2026-06-14-agnos-net-entropy-clock-syscalls.md` (#45–#55).

## Summary

cyrius 6.2.7 ran a systematic **stdlib agnos-completeness pass**: it made every
stdlib module a sandhi-from-source `cyrius build --agnos` pulls compile + behave
correctly-or-fail-closed on the AGNOS target. Doing so enumerated the POSIX
primitives the cyrius stdlib composes on that AGNOS's surface (0–55) does **not**
provide.

**Important: none of these block AGNOS.** cyrius now either peer-splits the
module to an AGNOS variant or guards the call site, so each missing primitive
**fail-closes cleanly** (returns `-1`/`0`/"unsupported") rather than mis-compiling
or mis-dispatching. This doc exists so the AGNOS side can **prioritise** these
kernel-level gaps *if and when* the corresponding consumer path (an inbound-TCP
server, multicast/mDNS, or subprocess test-running) is wanted on AGNOS. Until
then the cyrius fail-closed behaviour is the intended steady state.

## The missing calls

Grouped by the consumer that surfaced them. "cyrius today" is how the stdlib
copes now (fail-closed); "AGNOS could add" is the kernel-side primitive that
would let cyrius compose a *working* path instead of a fail-closed stub.

### 1. POSIX process model — `fork` / `dup2` / `execve` / `chdir` / `wait4`

| Primitive | Why cyrius wants it | cyrius today | AGNOS could add |
|---|---|---|---|
| `fork` (address-space clone) | `lib/regression.cyr` test-runner verbs (pipe-to-bin, exec-capture, bounded-run, ssh/scp) fork a child, redirect its fds, then `execve` | `lib/regression_agnos.cyr` fail-closes every fork+exec verb → `-1` "unsupported"; `lib/process_agnos.cyr` routes `run`/`spawn` to `spawn`#3 / `execwait`#37 where it can | a `fork`-equivalent is likely **out of scope** for the cooperative single-CR3 model — see below |
| `dup2(oldfd,newfd)` (fd redirect) | redirect a child's stdin/stdout/stderr before exec (capture to a file / pipe) | unsupported on AGNOS (`process_agnos.cyr` already documents "capture unsupported — no working dup") | **the high-value one**: an fd-redirect primitive (or argv+fd-redirect args on `spawn`#3 / `execwait`#37) would let the capturing process helpers work |
| `execve(path, argv, envp)` | exec with an explicit argv + environment | `spawn`#3 takes an in-memory ELF, `execwait`#37 takes a path but (today) no argv/envp | argv + envp passing on `execwait`#37 |
| `chdir(path)` | run a child in a chosen working dir (`regression_exec_in_dir3`) | fail-closed | a per-process cwd + `chdir` (only if ring-3 gains a cwd concept) |
| `wait4(pid, status, opts, rusage)` | reap with a Linux status word | `waitpid`#4 already returns the exit code directly (no status word) — cyrius's agnos `WIFEXITED`/`WEXITSTATUS` decoders handle this | nothing needed |

**Recommendation**: don't chase POSIX `fork`. The single useful addition is
**fd-redirect + argv/envp on the existing `spawn`#3 / `execwait`#37** so that
*capturing* subprocess helpers (run-a-tool-and-read-its-stdout) become possible.
Everything else here stays fail-closed and that is fine — running a fork+exec
test harness in ring 3 is not a real AGNOS workload.

### 2. BSD socket options — `setsockopt` / `getsockopt` / `shutdown`

| Primitive | Why cyrius wants it | cyrius today | AGNOS could add |
|---|---|---|---|
| `setsockopt SO_REUSEADDR` | server bind reuse (`net.cyr` `sock_reuse`) | agnos no-op → `0` | only if inbound-TCP server (Phase B) lands |
| `setsockopt SO_RCVTIMEO` | bounded blocking recv (`net.cyr` `sock_set_recv_timeout`) | agnos no-op → `0`; the recv deadline is enforced caller-side by the `sock_recv`#49 poll loop | a recv-deadline option, only if the poll-loop model is replaced |
| `setsockopt SO_REUSEPORT` | coexist with a host mDNS daemon on :5353 (`net.cyr` `sock_reuseport`) | unsupported → `-1` | with multicast (below) |
| `shutdown(fd, how)` | half-close (`net.cyr` `sock_shutdown`) | agnos no-op → `0`; the conn fully closes via `sock_close`#50 | optional half-close on #50 |

### 3. IPv4 multicast (IGMP) — `IP_ADD/DROP_MEMBERSHIP`, `IP_MULTICAST_TTL/LOOP/IF`

| Primitive | Why cyrius wants it | cyrius today | AGNOS could add |
|---|---|---|---|
| IGMP group join + multicast send opts | sandhi mDNS **QM** (multicast-response) mode + RFC 6763 service browsing (`net.cyr` `net_join_multicast` / `net_set_multicast_*`) | unsupported → `-1`; sandhi's mDNS resolver degrades to the **QU-bit unicast** path, which needs no membership and works on AGNOS today | a UDP multicast-join primitive (low priority — QU unicast covers the common case) |

### 4. Readiness / non-blocking — `fcntl(O_NONBLOCK)`, `epoll_create1`

| Primitive | Why cyrius wants it | cyrius today | AGNOS could add |
|---|---|---|---|
| `fcntl` O_NONBLOCK toggle | `lib/async.cyr`, `net.cyr` non-blocking connect | async is peer-split (`async_agnos.cyr`, serial); `net_connect_nb` uses the blocking `sock_connect`#47 on AGNOS | **nothing** — AGNOS's blocking `#47` + non-blocking `recv`#49 model is sufficient; cyrius adapts to it |
| `epoll_create1(flags)` | `async.cyr` epoll loop | AGNOS has `epoll_create`#19 (no-arg); the `1`/flags variant is absent. async is unused on the AGNOS client path so the peer skips epoll entirely | nothing — `#19` suffices; cyrius sidesteps it |

### 5. File-I/O hardening niceties — `O_NOFOLLOW`, `fstat`, per-fd `fsync` (surfaced by attn11)

attn11 (the ML/training reference) ported its file-I/O to the agnos target and
**accepted + disclosed** three weaker-than-Linux guarantees inherent to the frozen
ABI (`attn11/docs/guides/agnos.md` + `attn11/docs/audit/2026-06-10-agnos-audit.md`).
Logged here 2026-06-18 (cross-repo sweep) so the central kernel-gap tracker has them;
**none block attn11** — all degrade safely.

| Primitive | Why a consumer wants it | agnos today | AGNOS could add |
|---|---|---|---|
| `O_NOFOLLOW` open flag | symlink-refusal hardening on `secure_read_file`/`secure_write_atomic` | the `AO_*` flag set has no nofollow bit; the `io.cyr` bridge drops it → no symlink refusal on agnos | a nofollow bit in the `AO_*` flags consumed by `open`#7. Exposure bounded today by the single-user model + no user-writable symlink farms |
| `fstat(fd)` | stat an already-open fd (no TOCTOU between open and stat) | only path-`stat`#33 exists; `_file_size` must re-stat the *path* after open → size races the open (bounded — used only as an alloc cap; the read stops at real EOF, never overflows) | an fd-based stat variant |
| per-fd `fsync(fd)` | durability of one file without a global flush | falls back to global `sys_sync` (the atomic rename still aborts on a sync failure) | a per-fd `fsync` |

**Priority: LOW / opportunistic.** All three are robustness/security niceties attn11
already shipped around; surface them only if a second consumer wants the same.

## Cross-cutting hazard: the Linux↔AGNOS syscall-number overlap

AGNOS's compact `0–55` surface **reuses numbers that mean something different in
the Linux x86-64 ABI**. A raw, unguarded `syscall(<linux-number>, …)` in stdlib
does not fail to compile on AGNOS — it **silently mis-dispatches** to whatever
AGNOS call shares that number. The collisions that bit the 6.2.7 pass:

| Linux call | Linux # | AGNOS # means | Mis-dispatch effect if unguarded |
|---|---|---|---|
| `socket` | 41 | `sleep_ms` (#41) | "create socket" sleeps, returns 0 → caller treats fd 0 (stdin) as the socket |
| `shutdown` | 48 | `sock_send` (#48) | "half-close" injects a send |
| `setsockopt` | 54 | `udp_unbind` (#54) | "set option" tears down a UDP listener |
| `getsockopt` | 55 | `icmp_echo` (#55) | "read option" fires an ICMP echo (blocks ~3s) |
| `poll` | 7 | `open` (#7) | "poll fds" opens a file |
| `read`/`write` | 0/1 | `exit`/`write` (#0/#1) | **`read` becomes `exit(fd)` — the process terminates** |

This is structural, not a bug in any one module: any future stdlib code that
hand-rolls a Linux syscall number is a latent landmine on AGNOS. cyrius 6.2.7
fixed every instance (peer-split / `#ifdef CYRIUS_TARGET_AGNOS` guard / route
through the portable `sys_*` wrappers + the tagged-fd socket adapter). **No
AGNOS-side change is required for this**, but it is worth recording in
`agnos-userland-abi.md` that the number space deliberately overlaps Linux's and
that consumers must use the cyrius `sys_*` wrappers, never raw numbers.

## cyrius-side status (6.2.7) — for reference

All resolved on the cyrius side; listed so the AGNOS side knows the current
fail-closed contract:

- `lib/async.cyr` → peer-split `lib/async_agnos.cyr` (serial fallback; `sleep_ms`#41 is the one real primitive it uses).
- `lib/net.cyr` → `sock_reuse`/`sock_set_recv_timeout`/`sock_shutdown` no-op on AGNOS; `sock_reuseport`/`net_join_multicast`/`net_drop_multicast`/`net_set_multicast_{ttl,loop,if}` return `-1`.
- `lib/regression.cyr` → peer-split `lib/regression_agnos.cyr` (fork+exec verbs fail-closed); `regression_network_probe` routes through the AGNOS socket adapter.
- `lib/ws.cyr` → raw `syscall(0/1,…)` replaced with the portable `sys_read`/`sys_write` wrappers (which route tagged socket fds via `#48`/`#49`), removing the `read→exit` mis-dispatch.
- `lib/thread.cyr` / `lib/process.cyr` → already peer-split (`thread_agnos.cyr` / `process_agnos.cyr`) in prior releases.

## Priority

**Low / opportunistic.** The only addition with real consumer pull is the
**fd-redirect + argv/envp on `spawn`#3 / `execwait`#37** (group 1) — it would
unblock capturing subprocess helpers. The socket-option / multicast groups are
gated on AGNOS Phase B (inbound TCP) and mDNS-QM respectively; neither is wanted
yet, and the QU-unicast mDNS path already works. Everything else is correctly
absent and cyrius adapts to AGNOS's model rather than asking AGNOS to grow a
Linux-shaped surface.
