# `#96 fork` — the number is reserved, the syscall is not built, and agora cannot run on agnos without it

**Status:** 🟡 **PARTIAL — 1.56.54. THE HARD PART IS BUILT AND MEASURED; THE wait-any HANDOFF IS NOT.**

**What is done and proven** (`scripts/smoke/fork-smoke.sh`, ring-3 `/bin/forker`):
- `waitpid`#4 **wait-any** (`arg1 < 0`) — scans for a dead child of the caller, reaps the lowest, returns its code; `-2` while children live, `-1` when there are none. The `-2`/`-1` split is the contract a fork loop depends on.
- **`proc_dup_address_space`** — full copy (not CoW; agnos has no write-fault unshare path) of PD[1..510] plus the high-arena PDPT[128..511] PDs, reusing `proc_map_page`/`_nx`/`_hi` so the 0x87 bits, NX bit 63 and the KPTI entry-511 stash stay in one place.
- **`sys_fork`#96**, dispatched from `syscall_handler` — **not** `ksyscall` — for the same reason `#44`/`#14` are: the child's resume context comes from `pcpu_sc_entry_regs`, valid only on a path reached from the ring-3 entry stub.
- ⭐ **MEASURED IN QEMU**: `FORK-CHILD` and `FORK-CHILD-OK` both print. A second process really does resume at the parent's post-SYSCALL RIP with `rax == 0`, sees the parent's pre-fork stack value, and writes its **own** copy. `FORK-PARENT` prints too — the parent survives with a positive pid.

**What is NOT done:** `FORK-PARENT-OK` — the parent's `waitpid(-1)` loop times out and never observes the exited child. `exit`#0 sets state 0 without reaping, so the child should be findable; the failure is in the parent/child handoff under a foreground `exec_and_wait`, not in the copy or the resume.

⛔ **AND THE HARNESS QUESTION IS THE REAL ONE, because agnos has almost nowhere a forked child can run.** Two shapes were tried and both are structurally wrong, for reasons that are properties of this kernel rather than of `#96`:
- **Foreground `exec_and_wait` runs the child IF=0** — sched.cyr states it: *"Refuse IF=0 callers (foreground exec/execwait children): their no-context-switch model is load-bearing."*
- **The boot thread cannot safely be switched away from** — *"restoring it would time-travel kmain."* Marking the proc ready and polling from boot printed its banner and stopped.
⇒ **The one context where a forked child can be scheduled alongside its parent is a proc spawned from agnsh via `spawn_path`#43, after boot.** That is where the remaining verification belongs, and it is also the shape the named consumer (agora, fork-per-connection) actually runs in.

⚠ `scripts/smoke/fork-smoke.sh` is **deliberately NOT wired into `sweep.sh`** while it is red on `FORK-PARENT-OK`. A gate that passes while its subject is incomplete is the failure mode this repo has spent two cuts removing.
⚠ The cyrius `SYS_FORK = 96` peer is **not** filed yet — the issue's own rule is *"do not mint the number before the kernel arm exists"*, and it now does, but not completely. File it when wait-any closes.

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
