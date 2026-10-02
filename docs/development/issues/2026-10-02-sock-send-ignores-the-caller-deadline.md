# 2026-10-02 — `sock_send` (#48) waits up to 8 s for ACK progress with no caller bound, so a cyrius TLS write overshoots its deadline

**Status:** 🟡 **OPEN** — filed from cyrius **6.6.14** (the TLS follow-ups; CVE-61's *Not covered* in cyrius
`docs/audit/2026-09-03-security-audit.md`).
**Checked against:** agnos **1.57.10** — `kernel/core/syscall.cyr` (the #48 arm, ~11489-11510),
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
