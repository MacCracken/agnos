# `#96 fork` — the number is reserved, the syscall is not built, and agora cannot run on agnos without it

**Status:** 🔵 **OPEN — RESERVED AND UNBUILT at 1.56.54.** Re-verified 2026-08-30: no `num == 96` dispatch arm, no `proc_dup_address_space`, and the `waitpid`#4 wait-any prerequisite (`arg1 < 0`) is still rejected. agora's fork-per-connection BBS therefore still cannot serve a second connection on agnos. ⚠ **Order matters and has not changed**: wait-any first (it forces the `proc_ppid[16]` array fork also needs), then full-copy `proc_dup_address_space` over PD[1..510]. LARGE; wants slotting.

**Original status:** 🟡 **OPEN** — filed 2026-08-05. Number assigned by the operator; nothing minted yet.
**Number:** **`#96`** — ⭐ **settled 2026-08-05.** It was contested with the local-IPC band; the
operator ruled that **fork keeps `#96`** and the channel band takes **`#97`**
([`2026-08-05-syscall-97-chan-op.md`](2026-08-05-syscall-97-chan-op.md)). Next free is **`#98`**.
**Cross-repo:** agnos (kernel) **+ cyrius** (`lib/syscalls_x86_64_agnos.cyr` peer must move in lockstep).
**Severity:** Medium — a named consumer is blocked outright, but nothing regresses without it.
**Affects:** agnos 1.56.39 and earlier; every cyrius toolchain (no `SYS_FORK` constant exists).

## Summary

`agora`, the telnet BBS, is fork-per-connection: `agora/src/main.cyr:2702` calls `sys_fork()`. agnos
has no fork syscall, so agora cannot serve a second connection on agnos at all. It is the only named
consumer, and it is a real one — agora is iron-validated on archaemenid over its own transport.

## What it needs

- **Full-copy `proc_dup_address_space` over PD[1..510]** — not copy-on-write. CoW needs a
  write-fault path agnos does not have, and the roadmap's own line is that the kernel grows per
  native workload, not to match Linux.
- ⛔ **`waitpid #4` wait-any lands FIRST.** `#4` implements `WNOHANG` for a *single* pid only; the
  `arg1 < 0` case (scan for `ppid == proc_current && state == 0`) is missing, and every fork-model
  server needs it. It also forces the `proc_ppid[16]` array that fork needs anyway, so the two are
  one piece of work in the right order — not two independent items.
- The cyrius peer gains `SYS_FORK = 96` **in the same change**, plus a `sys_fork()` wrapper.

## ⛔ Do not mint the number before the kernel arm exists

A `SYS_FORK = 96` constant that dispatches to an unimplemented arm is worse than no constant: on agnos
an unknown `num` falls through the dispatch chain and the caller gets a return value it will read as
data. See [[reference_target_arm_contract_bugs_are_invisible_offtarget]] — a target-armed contract bug
does not show up off-target, so a host build of a `sys_fork()` consumer would look perfectly healthy.

## Sequencing against `#97`

Independent. They contend only for a number, and that contention is resolved. `#97` is the desktop's
critical path and `#96` is agora's; neither blocks the other, and whichever is built first must **not**
take the other's number on the grounds that it got there first — the operator assigned both.

## Pointers

- Roadmap row and the `waitpid` dependency → [`../roadmap.md`](../roadmap.md)
- ABI table (⚠ see [`2026-08-05-abi-doc-covers-two-thirds-of-the-syscalls.md`](2026-08-05-abi-doc-covers-two-thirds-of-the-syscalls.md)
  before treating that table as complete) → [`../agnos-userland-abi.md`](../agnos-userland-abi.md)
