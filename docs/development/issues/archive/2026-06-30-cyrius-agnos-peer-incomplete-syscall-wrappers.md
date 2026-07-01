# cyrius agnos peer is INCOMPLETE — 8 implemented agnos syscalls have no `SYS_*`/`sys_*` wrapper

**Status**: ✅ **RESOLVED 2026-06-30 — cyrius 6.3.14 added all 8 `SYS_*`/`sys_*` wrappers** to `lib/syscalls_x86_64_agnos.cyr` (klug#36 / execwait#37 / fbinfo#38 / blit#39 / kbscan#42 / spawn_path#43 / sched_yield#44 / exec_redirect#62), at the exact agnos numbers + ABI filed here (`a4=r10` on `blit`, `klug` not `klog`, back-referencing the cyrius-side issue in a code comment). **Link-proven**: a `--agnos` exerciser referencing all 8 builds `OK` under 6.3.14 and emits the right immediates (`0x24/0x25/0x26/0x27/0x2a/0x2b/0x2c/0x3e`). agnos-side follow-ons also done: the **klog→klug rename** (0 refs left in `kernel/core/` + the ABI docs + `architecture/overview.md` + `state.md`; only the historical `doc-health.md` ledger keeps "klog"), and the **number-space-overlap hazard** is recorded as ABI decision **O5** in `agnos-userland-abi.md`. Remaining: agnos's own `cyrius.cyml` pin is still **6.3.9** — bump to **6.3.14** when a consumer or the kernel next needs the named wrappers. The cyrius-side issue is theirs to close. *(Original filing below.)*

**Status (original)**: Filed 2026-06-30 — **proactive completeness audit; SURFACED to cyrius** at `cyrius/docs/development/issues/2026-06-30-agnos-syscall-peer-incomplete-8-wrappers.md` (agnos-side is hands-off on cyrius per [[feedback_cyrius_hands_off]] — the cyrius side adds the wrappers). **Cyrius-side fix; no agnos kernel change needed** (the kernel already implements all 64 — this is purely the userland peer being behind the kernel). Non-blocking *today* only because the consumers that need these haven't advanced their `--agnos` lanes to the call yet; this exists so cyrius adds them **before** each consumer hits a hard link error one at a time.
**Date**: 2026-06-30
**Affects**: `cyrius/lib/syscalls_x86_64_agnos.cyr` (the cyrius stdlib's agnos syscall peer) — and, for the value/numbering confirmation, `agnos/docs/development/agnos-userland-abi.md` + `syscall-additions.md`.
**Related (same shape, both RESOLVED once surfaced — the precedent this audit generalizes)**: `archive/2026-06-16-cyrius-patra-lseek-syscall-gap.md` (lseek#58), `archive/2026-06-23-cyrius-agnos-peer-missing-signal-number-constants.md` (SIGHUP…). Both were "kernel has it, cyrius peer omits it → downstream hard link error," fixed by adding the constant/wrapper to the cyrius peer.

## The gap

The agnos kernel dispatches a **contiguous 0–63** syscall surface (`kernel/core/syscall.cyr` + `syscall_hw.cyr`). The cyrius agnos peer exposes `SYS_*` constants + `sys_*` wrappers for **0–35, 40–41, 45–61, 63** — but **omits 8 numbers the kernel implements**:

| # | kernel syscall (signature) | what it does | base-system consumer that needs it on `--agnos` |
|---|---|---|---|
| **36** | `klug(buf, len)` *(the syscall name is **klug**, not the dead "klog")* | copy the unified klug log ring (`core/klug.cyr`) into a user buffer | **aegis** (security-daemon log read), **phylax** (threat detection), **sakshi** (logging lib) |
| **37** | `execwait(path, pathlen) → child exit code` | load a static ELF64 from disk, run it to completion in ring 3, return its exit code | **bote** (MCP core — spawn tools), **daimon** (agent orchestrator), **t-ron** (MCP security), **thoth** (TUI) — agnsh/ark/kriya already call it via a **raw** `syscall(37,…)` (the very landmine below) |
| **43** | `spawn_path(path, len) → pid` | NON-blocking from-disk spawn (scheduled, returns immediately) | **bote**, **daimon** (concurrent agent/tool spawning) |
| **62** | `exec_redirect(src_fd, dst_fd)` | arm a one-shot fd redirect before `execwait`/spawn — capture a child's stdout/stderr | **bote**, **daimon**, **t-ron** (capture + read a tool's output) |
| **44** | `sched_yield()` | cooperative yield to the scheduler | threading / cooperative-loop consumers |
| **38** | `fbinfo(buf, len)` | write the 24-byte framebuffer geometry struct | chakshu, kii, aethersafha (TUI / graphics) |
| **39** | `blit(src, w, h, dstxy)` | copy a w×h 32bpp block to the framebuffer | chakshu, kii, aethersafha |
| **42** | `kbscan(buf, max)` | NON-blocking raw-scancode drain for ring-3 input | chakshu, cyim (TUI input) |

## Why it matters (the landmine, not just an omission)

Without a peer wrapper a consumer has two bad options:

1. **Hand-roll `syscall(37, …)`** — but the agnos 0–63 surface **deliberately reuses Linux x86-64 numbers that mean something else** (documented in `2026-06-15-cyrius-stdlib-missing-syscalls.md`). On agnos `37` is `execwait`; on the Linux floor `37` is `alarm`. A raw number compiles on both targets and **silently mis-dispatches** on the wrong one. The portable `sys_*` wrapper (`#ifdef CYRIUS_TARGET_AGNOS`) is the only safe way to call these.
2. **Fail to link** — a consumer that references a bare `execwait`/`klug`/`exec_redirect` constant that the peer doesn't define gets a hard `undefined variable` link error on `--agnos` (exactly how patra/lseek + t-ron/SIGHUP surfaced).

The base-system security stack we're bringing onto agnos — **kavach, bote, t-ron, thoth, phylax, aegis** — lands squarely on the **process/exec band (37 / 43 / 62)** for spawning + capturing tool subprocesses, and **klug (36)** for reading the audit/log ring. The graphics/input three (38 / 39 / 42) are for the TUI/graphics tools (chakshu, kii, cyim, aethersafha).

## The ask (cyrius-side)

Add the 8 to `cyrius/lib/syscalls_x86_64_agnos.cyr`, mirroring the existing peer pattern (a `SYS_*` enum value + a `sys_*` wrapper), with the **agnos** numbers + ABI:

```
SYS_KLUG = 36;        fn sys_klug(buf, len): i64 { return syscall(SYS_KLUG, buf, len); }
SYS_EXECWAIT = 37;    fn sys_execwait(path, pathlen): i64 { return syscall(SYS_EXECWAIT, path, pathlen); }
SYS_FBINFO = 38;      fn sys_fbinfo(buf, len): i64 { return syscall(SYS_FBINFO, buf, len); }
SYS_BLIT = 39;        fn sys_blit(src, w, h, dstxy): i64 { return syscall(SYS_BLIT, src, w, h, dstxy); }  # a4=r10
SYS_KBSCAN = 42;      fn sys_kbscan(buf, max): i64 { return syscall(SYS_KBSCAN, buf, max); }
SYS_SPAWN_PATH = 43;  fn sys_spawn_path(path, len): i64 { return syscall(SYS_SPAWN_PATH, path, len); }
SYS_SCHED_YIELD = 44; fn sys_sched_yield(): i64 { return syscall(SYS_SCHED_YIELD); }
SYS_EXEC_REDIRECT = 62; fn sys_exec_redirect(src_fd, dst_fd): i64 { return syscall(SYS_EXEC_REDIRECT, src_fd, dst_fd); }
```

(Names indicative; the ABI owner confirms — note **`klug`** not `klog`, and `blit`'s 4th arg `dstxy` arrives via `r10` like the other 4-arg agnos calls.) Once they land, the consumer `--agnos` lanes that need them link cleanly and stop hand-rolling raw numbers.

## agnos-side follow-on (separate, this repo)

- **klog → klug rename.** The subsystem is `core/klug.cyr` (the unified klug ring) but syscall #36 + its ABI-doc/selftest references still say "klog" (44 occurrences across `kernel/core/{klug,syscall,main}.cyr` + `docs/development/{syscall-additions,agnos-userland-abi}.md`). "klog" is dead; align on **klug** so the cyrius wrapper above (`sys_klug`#36) and the ABI doc agree. Tracked here so the rename + the cyrius wrapper name land consistently.
- Record in `agnos-userland-abi.md` that the 0–63 number space deliberately overlaps Linux's, so consumers MUST use the cyrius `sys_*` wrappers (above), never raw numbers (the §"Cross-cutting hazard" point from the 2026-06-15 doc, made load-bearing now that the base-system consumers are coming).
