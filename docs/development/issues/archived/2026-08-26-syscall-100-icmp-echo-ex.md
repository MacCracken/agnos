# `#100 icmp_echo_ex(dst_ip, timeout_ms)` + ICMP counters on `net_config`#61

**Status:** ✅ **RESOLVED — SHIPPED 1.56.48 and now IRON-VERIFIED.** Swept 2026-08-30. The header said *"Minted and QEMU-proven"*; the 2026-08-30 archaemenid burn closed the remaining half — a live gateway ping succeeded against a real network (`icmp: gw reply`), which QEMU's SLIRP cannot prove. The cyrius wrapper is carried in that repo's own issues folder.

**Original status:** ✅ **Minted and QEMU-proven** 2026-08-26 (agnos 1.56.48).
**Repo owning the design:** agnos.
**Cross-repo:** cyrius needs the wrappers — [`2026-08-24-agnos-syscall-99-proclist-wrapper.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-24-agnos-syscall-99-proclist-wrapper.md) carries them.
**Consumer:** `yo` — see its `docs/development/roadmap.md` § 0.6.x, which filed all of this as "blocked on agnos".
**Precedent:** same shape as `#98 ptrscan` and `#99 proclist`.

---

## What was added

Three things, in one release, all driven by one consumer question: *why did this probe come back with nothing?*

### 1. `#100 icmp_echo_ex(dst_ip, timeout_ms)` — a caller-chosen deadline

```
icmp_echo_ex(dst_ip, timeout_ms) -> RTT in ms (>= 0), or -1 (timeout / NIC down)
```

`timeout_ms <= 0` means "kernel default" (~3 s), so the new arm and `#55` agree when
the caller expresses no preference. Clamped to 60 s. Resolution is the 100 Hz tick, so
the bound is rounded **down** to whole ticks with a floor of 1 — a sub-10 ms request
waits one tick rather than zero, because "never wait" is not what a caller asking for
1 ms means.

### 2. `icmp_ping(dst_ip, timeout_ticks)` — the kernel-side parameter

`fn icmp_ping(dst_ip)` became `fn icmp_ping(dst_ip, timeout_ticks)`; `0` selects the
historical 300-tick bound. All four in-kernel callers pass `0` and are byte-unchanged
in behaviour (`selftests.cyr`, `net_ingress.cyr`, `shell.cyr`, and `#55`).

### 3. `net_config`#61 fields 4..7 — ICMP counters

| field | counter | meaning |
|---|---|---|
| 4 | `icmp_tx` | echo requests this kernel sent |
| 5 | `icmp_rx` | echo replies that matched our id **and** seq |
| 6 | `icmp_replies_sent` | inbound echo requests we answered |
| 7 | `icmp_timeouts` | `icmp_ping` calls that expired unmatched |

Free-running, never reset, monotonic. Written without a lock — `net_handle_icmp` is
reachable from the timer ISR via `net_rx_drain`, and these are diagnostics, so a torn
read costs one count. **Do not build control flow on them.**

---

## Why `#100` rather than a second argument to `#55`

⛔ **This is the load-bearing decision in this ticket, and it generalises.**

Measured on cyrius 6.5.35 by disassembling a two-call test program: the compiler pops
only as many registers as the call site passes.

```
syscall(39)          ->  pop %rax                              ; rsi/rdx untouched
syscall(39, 1234)    ->  pop %rdx ; pop %rsi ; pop %rdi ; pop %rax
```

Unused syscall argument registers are **not zeroed**. They hold whatever the previous
code left there. So had `#55` started reading `arg2` as a timeout, every already-shipped
one-argument caller — cyrius's own `fn sys_icmp_echo(dst_ip)` wrapper, and every `yo`
binary built against it — would have handed the kernel a garbage bound: sometimes huge,
sometimes a few milliseconds, never reproducible, and presenting as flaky ping timeouts
rather than as an ABI break.

**Widening a live syscall's arity is not backward compatible on this ABI.** `#55`'s
arity is now documented as frozen at one argument, in the arm itself. The roadmap's
syscall line carries the general rule: *mint a number; do not widen an arm.*

## Why the counters went on `#61` instead of a new number

`net_config` already takes a field selector and already returns `-1` for an unknown
field, so adding fields 4..7 is purely additive with zero ABI hazard and costs no
number. Minting a second number for four counters would have been the more expensive
answer to the same question, and the roadmap is explicit that numbers are not spent
casually. The semantic stretch is real and is recorded in the arm: fields 0..3 are
configuration, 4..7 are statistics, under one getter.

## Why they exist at all

A ring-3 prober that gets nothing back could not distinguish **"we never transmitted"**
from **"we transmitted and nothing answered"**. `yo --diag` on AGNOS could report the
DHCP lease and the `icmp_echo` return code, and no more. `tx > 0` with `rx == 0` is a
network problem; `tx == 0` is a local one. That is the first fork in every AGNOS network
debug and the kernel was the only thing that knew.

The timeout is the same story from the other end: `yo` accepts `-W` on every backend but
**could not honour it on AGNOS**, because the bound lived in the kernel and took no
argument. The `#55` comment had named this as "a future enhancement that would
parameterise `icmp_ping`" since 1.45.4.

---

## Also fixed here: the reply match was on identifier alone

`net_handle_icmp` accepted any echo reply whose ICMP identifier equalled `icmp_id`.
`icmp_id` is a **per-kernel constant** (`0x4147`), so a late reply to a *previous* ping —
one whose deadline had already expired — satisfied whatever wait happened to be open.
The RTT was then measured from the wrong start, and a host that had stopped answering
could still look reachable.

`icmp_ping` bumps `icmp_seq` per call, so the sequence number was already the
discriminator; it simply was not being read. It now matches **id and seq**.

`yo`'s [ADR 0002](https://github.com/MacCracken/yo/blob/main/docs/adr/0002-focused-kernel-icmp-syscall.md)
filed this as an untested hazard — *"one ping is in flight kernel-wide, and a stale reply
carrying `0x4147` satisfies whatever wait is currently open … stated as untested, not as
broken."* It is now closed rather than merely untested.

---

## Verification — exercised against a booted kernel, not just compiled

⭐ This is the step the `#99` ticket flagged as *"not yet done"* for `proclist`. It is
done here. A throwaway ring-3 prober was cross-built `--agnos`, staged on the ext2
rootfs and run under QEMU via `yo`'s smoke harness:

```
P100: counters before  tx=0 rx=0 repl=0 to=0
P100: echo_ex(gw,500ms) rtt_ms=0
P100: echo_ex(gw,0)     rtt_ms=0
P100: echo#55(gw)       rtt_ms=0
P100: echo_ex(dead,200ms) rc=-1 elapsed_ms=200
P100: bad field rc=-1
P100: counters after   tx=4 rx=3 repl=0 to=1
```

- **The deadline is honoured**: 200 ms requested against a black hole, **200 ms
  elapsed**. Before this change the same call took ~3 s.
- **The counters are self-consistent**: `tx = rx + timeouts` (4 = 3 + 1).
- `#55` still works, and `#100` with `0` matches it.
- An unknown `net_config` field still returns `-1`.

Regression: `yo`'s own AGNOS smoke (`scripts/agnos-qemu-smoke.sh`) passes against this
kernel — **2/2 replies, 0% loss** through the unchanged `#55` path, which is the check
that matters for the id+seq matching change.

---

## Acceptance

- `#100` arm exists and dispatches. ✅
- `#55` behaviour byte-unchanged, arity frozen and documented. ✅
- `net_config` 4..7 return counters; unknown fields still `-1`. ✅
- Reply matching requires id **and** seq. ✅
- Exercised on a booted kernel, not merely compiled. ✅
- ⚠ **Not yet done:** consumed through cyrius wrappers by `yo`. The wrappers are the
  cyrius ticket; `yo` 0.6.1 is the first real consumer and carries that verification.
- ⚠ **Not yet done:** iron burn. QEMU/SLIRP replies are sub-tick, so every RTT here
  reads `0 ms`; a burn is what exercises a non-zero tick count.
