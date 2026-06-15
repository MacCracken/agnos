# AGNOS has no entropy syscall — cyrius native TLS + all crypto on the agnos target have no RNG source

> **Status**: OPEN — **kernel-side ABI ask** (filed agnos-side per the cross-repo
> issue convention; **kernel agent please review** — this needs a new syscall the
> kernel must provide. Cyrius can't fix it alone). This repo's kernel source is
> hands-off w.r.t. cyrius; cyrius will mirror whatever ABI the kernel lands.
> **Filed**: 2026-06-10 (cyrius deep-dive review, v6.1.31)
> **Severity**: HIGH — keys/nonces with no real entropy on the agnos userspace
> target. Not boot-blocking; bites the moment any crypto/TLS runs in ring 3 on agnos.
> **Cross-ref**: cyrius `docs/development/issues/2026-06-10-entropy-failweak-paths.md`
> (CVE-19) + `docs/audit/2026-06-10-deep-dive-review.md`.

## Summary

The agnos syscall surface (0–43 today, per the live `ksyscall` dispatch in
`kernel/core/syscall.cyr`) exposes **no getrandom-/getentropy-class primitive**.
`cyrius/lib/syscalls_x86_64_agnos.cyr` faithfully mirrors that surface, and
`cyrius/lib/random.cyr` has no `CYRIUS_TARGET_AGNOS` branch — so on the agnos
target there is **no RNG source at all**.

This matters now because cyrius's **native TLS stack became the default backend
at v6.1.21** (`lib/tls.cyr`; libssl is opt-out). The whole point of native TLS on
agnos is that a freestanding/ring-3 target has no `libssl`/`ld.so` to lean on — so
agnos crypto depends entirely on the stdlib RNG, which depends on a kernel
syscall that doesn't exist. Net: TLS session keys, AEAD nonces, ECDHE scalars,
and any `sigil` key generation on agnos would draw from nothing (or a fail-weak
fallback) — predictable secrets.

## What the kernel already has

The KASLR work already added an in-kernel RDRAND helper:
`kernel/core/pmm.cyr:64 kaslr_seed()` (and the `rdrand` plumbing the
`proposals/2026-05-11-kaslr-scope.md` work-breakdown step 1 describes:
`0F C7 F0` / `48 0F C7 F0`, with an `rdtsc` fallback when CF=0). So the entropy
*source* exists in-kernel; this ask is to **expose it to ring 3** as a syscall.

## The ask (kernel-side)

Add a `getrandom`-class syscall at the next free slot (44+ — the kernel agent
assigns the number against the live dispatch):

```
getrandom(buf, len) → bytes_written / -1
```

- Validate `is_user_range(buf, len)` (reject < 0x200000 like the other buffer
  syscalls) and `len` sane; return `-1` on bad args (agnos uses `-1`, not Linux
  `-errno`).
- Fill `buf` with `len` bytes from the kernel entropy source. **Design call for
  the kernel agent**: raw per-call RDRAND is acceptable as a hardware RNG; for
  crypto-grade output across hosts without RDRAND, a small DRBG (e.g.
  HMAC/CTR-DRBG) seeded from RDRAND + jitter and reseeded periodically is the
  stronger choice. Per the kaslr-scope RDRAND-availability note, keep the
  `rdtsc`-low-bits fallback for the no-RDRAND QEMU case **only for KASLR**, not
  for this crypto syscall — a fail-weak crypto RNG is worse than a hard error, so
  prefer returning `-1` when no real entropy source is available rather than
  silently degrading.
- Catalog it in `agnos-userland-abi.md` §3.2 + `syscall-additions.md`, and move
  it to 🔒 FROZEN once landed.

## Cyrius-side follow-up (cyrius agent, after the kernel lands the ABI)

1. Add the syscall number + `getrandom` wrapper to
   `lib/syscalls_x86_64_agnos.cyr`.
2. Add a `#ifdef CYRIUS_TARGET_AGNOS` branch to `lib/random.cyr` (`random_bytes`)
   calling it, and route `ws`/`sandhi`/`sigil` entropy through `random_bytes`
   (the same CVE-19 cleanup that fixes the raw-`/dev/urandom` bypass on
   Windows/agnos). Until then, document that crypto on agnos has no RNG.

## Validation

A ring-3 probe that calls the new syscall for 32 bytes and asserts (a) it
returns 32, (b) two successive calls differ, (c) `is_user_range` rejection on a
kernel pointer. Then a native-TLS-on-agnos handshake smoke once the cyrius-side
`random.cyr` branch lands.
