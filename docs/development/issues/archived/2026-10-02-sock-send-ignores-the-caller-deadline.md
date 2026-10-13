# 2026-10-02 — `sock_send` (#48) waits up to 8 s for ACK progress with no caller bound, so a cyrius TLS write overshoots its deadline

**Status:** ✅ **RESOLVED 1.57.13 (2026-10-13)** — **`sock_send_dl`#109, `sock_send`#48 with a caller ceiling**
(the operator's 1.57.13 repair sweep; the number was pre-assigned). `(conn_id, buf, len, timeout_us)` → the committed
count (possibly 0) / -1; ABI §3.2 row 109. Two departures from "The fix" below, both decided from prior art and
recorded in the arm (`kernel/core/syscall.cyr` `num == 109`), in `tcp_send_dl` (`kernel/core/net_tcp.cyr`) and in the
ABI row:
1. **A NEW NUMBER, not `a4` on #48** — the #100 rule (`roadmap.md` "Widening a LIVE syscall's arity is NOT backward
   compatible on this ABI"): `a4` is a stale register in every shipped three-argument #48 caller, so reading it would
   have handed them a garbage bound. #48 is unchanged (its arm says `a4` is never read and points at #109).
2. **A CEILING measured once from entry, not a per-progress bound.** The proposal's `min(a4, TCP_PROGRESS_US)` passed
   as `se_prog` is re-armed by every ACK (FreeBSD `sbwait`'s per-wait `sb_timeo`), so a peer that ACKs inside every
   bound stretches the call — measured on exactly that mutant, a reader taking 512 B every 50 ms held a 300 ms call for
   **1.63 s**. Linux SO_SNDTIMEO keeps one `timeo` per `tcp_sendmsg` that every wait decrements; agnos #47 computes its
   ceiling once. `tcp_send_ex` gains an absolute `se_cap` (0 for every existing caller) that `tcp_send_cap_clamp`
   applies to each of its three D6 deadlines. The ceiling bounds the WAITING; a chunk that goes without a wait still
   goes. `timeout_us = 0` → exactly #48 (`tcp_send_own`); `< 0` → no wait (Linux maps a negative SO_SNDTIMEO to no
   wait); D6 still applies under it, so a stalled peer returns at `min(timeout_us, ~8 s)`.
**Evidence (the acceptance below, on the final source):** `scripts/smoke/sock-send-dl-smoke.sh` — new sweep row,
44/44 at `-smp 1` (TCG) + `-smp 4` (KVM) (`build/sweep-logs/07-1.57.13_sock_send_dl_109_caller_ceiling…attempt1.log`).
A 300 ms #109 against a reader that has stopped reading returns the committed count in 300–310 ms — locally (2049
committed: the 2 KB ring + the persist probe) and against a HOST peer through SLIRP (SO_RCVBUF 2048, after ~1.49 MB
filled the path); with an earlier segment in flight it returns 0 in the same band; a negative ceiling returns in < 1
ms; ceiling 0 returns at 8.0 s exactly as #48; a trickling reader cannot stretch the ceiling (4609–5121 committed in
~305 ms); #109 on a conn the caller does not own is -1 every way (bounded, unbounded, len 0) and sends nothing; the
stream stays byte-exact locally and the host receives exactly the committed total, pattern-verified. **Negatives**, each
red and the source restored byte-identical (the rebuilt kernel `cmp`-equal to the gated one): the arm passing 0 for
the ceiling (c1 8.0 s, W1 8.0 s — 6 FAIL), the arm without `tcp_auth` acting as the conn's owner (r1 = r2 = 5, 10
bytes leaked — 2 FAIL), the per-progress sketch above (N11t 1.63 s — 3 FAIL).
**What the change could break, checked before archiving:** every `tcp_send_ex` caller moved together (`tcp_send_own`
with cap 0, `tcpst_arm_stall` in `selftests.cyr`); with cap 0 every clamp is the identity, so #48, the in-kernel
`tcp_send` and the VFS_SOCK `write` path keep their behaviour — the TCP / net rows are green on the final source: TCP
hermetic 62/62, loopback 9/9, tcp_listen 4/4, inbound TCP 60/60 (on its second attempt — the first's `-smp 4` A3
read 482 bytes without `GET ` or EOF on one accepted conn, a receive-path flake #109 does not touch; log
`build/sweep-logs/04-…attempt1.log`), socket ownership 95/95, sock-wait 70/70. aarch64 gets a `tcp_send_dl` stub (the
32 functions / 17 variables it fails on are unchanged).
**Review fixes (1.57.13, same cut):** (1) D6 site 2 — the clamp where a partial ACK re-arms D6 — had no gate (no agnos
or SLIRP receiver takes part of a segment: each chunk is capped at the advertised window, which only opens); tcp-smoke
arm `tcp: dlpart` (TCP_SELFTEST) pre-queues a partial ACK of the call's own segment and stalls: a 300 ms
`tcp_send_dl` returns 100 committed in 0.30–0.31 s; that site unclamped → 8.0 s, red. (2) D6 under a ceiling above
it was untested: N11's c5 passes 20 s (LO) and INT64_MAX (IP, the 2^40 clamp) against the zero-window reader and
returns at the D6 8.0 s; `tcp_send_dl` passing `TCP_SEND_DL_MAX_US` as its D6 window → 15.4 s, `DL-OVER-D6-*` red.
(3) A #48 defect found on the way, fixed: `tcp_wait_done`'s mode-2 re-check did not see a PARTIAL ACK, so one consumed
before the wait armed (the sender's own `net_poll`, or a drain racing the arm) left the sender asleep to the OLD D6
deadline and D6 restarted there — up to 2 × `TCP_PROGRESS_US` after the partial ACK. `tcp_block` now takes the
SND.UNA the sender decided on and the predicate stops on any change; tcp-smoke arm `tcp: d6part` (a stale-snapshot
block 4–188 µs, was 2 s; a 600 ms D6 after a partial ACK 0.60–0.61 s, was 1.21 s — both red on the pre-fix code).
The seven TCP/net rows on the post-review source (`SWEEP_ONLY`, one job): TCP hermetic 66/66, loopback 9/9,
tcp_listen 4/4, inbound TCP 60/60 (first attempt), socket ownership 95/95, sock-wait 70/70, sock_send_dl 48/48.
**Still open, on cyrius's side:** `SYS_SOCK_SEND_DL` + `sys_sock_send_dl`, then `_agnos_sock_send_dl` passing the time
left and `agnos_tls_deadline.sh`'s real-kernel leg; the ABI gate reads kernel 111 (with `console_mode`#110 / `fd_kind`#111, same release) against cyrius 108 until the peers land — filed `cyrius/docs/development/issues/2026-10-13-agnos-sys-sock-send-dl-109-peer.md`.
**Filed against:** agnos **1.57.10**, from cyrius **6.6.14** (the TLS follow-ups; CVE-61's *Not covered* in cyrius
`docs/audit/2026-09-03-security-audit.md`) — `kernel/core/syscall.cyr` (the #48 arm, ~11489-11510),
`kernel/core/net_tcp.cyr` (`TCP_PROGRESS_US` :97, `tcp_send_ex` :988, `tcp_send_own` :1054).
**Severity:** availability, bounded. Nothing is corrupted; a caller's write deadline is overshot by up to one
progress window (~8 s).

## What happens

cyrius 6.6.13 gave every native TLS read and write a caller deadline (`tls_native_set_deadline` /
`tls_set_deadline`, cyrius CVE-61). On agnos a write cannot honour it:

- The #48 arm (`sock_send(conn_id=arg1, buf=arg2, len=arg3)`, its comment says "a4 unused") calls
  `tcp_send_own(arg1, arg2, arg3, tcp_caller_tag())`.
- `tcp_send_own` is `tcp_send_ex(conn_id, data, len, sd_own, TCP_PROGRESS_US)`, with
  `TCP_PROGRESS_US = 8000000` hard-coded.
- `tcp_send_ex` waits for each segment's ACK (S6: one segment in flight; the caller blocks) and returns the
  committed count only after `se_prog` microseconds with no ACK progress (D6).
- There is no writability readiness to wait on first (no `EPOLLOUT` anywhere in `kernel/core/`), and no
  non-blocking send.

So cyrius's agnos send leaf (`_agnos_sock_send_dl`, cyrius `lib/syscalls_x86_64_agnos.cyr` ~2350) can check the
deadline only BETWEEN #48 calls, and one call against a peer that stops ACKing holds the caller for up to 8 s
past its deadline. Measured with cyrius's fake-kernel harness (`tests/gates/platform/agnos_tls_deadline.sh`, a
#48 that takes 8 s): under a +1 s deadline the TLS write returns `TLS_ERR_TIMEOUT` ~8.25 s late, on cyrius 6.6.13
and 6.6.14 alike. Not yet re-measured on a real agnos boot.

Reads are already bounded: `_agnos_sock_recv_block` polls #49 against the deadline.

## The fix (agnos's call — it is an ABI change)

`tcp_send_ex` already takes the progress bound as a parameter (`se_prog`); only the syscall arm pins it.

- **Proposed:** #48 reads `a4` (`ksyscall_a4_get()`, unused by #48 today) as a progress bound in microseconds:
  `0` keeps today's `TCP_PROGRESS_US`; otherwise `min(a4, TCP_PROGRESS_US)`. When it expires, #48 returns the
  committed count, exactly as it does at 8 s now (possibly 0 — "no progress yet", not fatal). Callers that pass
  nothing in `a4` see no change.
- **Alternative (larger):** `EPOLLOUT` readiness for TCP conns plus a non-blocking #48, mirroring the POSIX shape
  cyrius uses on Linux and macOS.

Either way the syscall ABI notes and the ABI gate move with it. Once agnos ships one, cyrius changes
`_agnos_sock_send_dl` to pass the time left (the cyrius side is small and is NOT done speculatively — it would
commit agnos to an ABI shape agnos has not agreed to).

## Acceptance

- A #48 call with `a4 = N µs` against a conn whose peer has stopped ACKing returns within ~N µs (not 8 s), with
  the committed count.
- `a4 = 0` behaves exactly as 1.57.10 (the existing net/TCP gates unchanged).
- cyrius then re-runs `agnos_tls_deadline.sh` with a real-kernel leg and drops this from its CVE-61 *Not covered*.
