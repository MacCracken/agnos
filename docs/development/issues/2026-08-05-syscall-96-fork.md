# `#96 fork` — the number is reserved, the syscall is not built, and agora cannot run on agnos without it

**Status:** ✅ **BUILT AND GATED — 1.56.55.** `scripts/smoke/fork-smoke.sh` (in `sweep.sh`) proves the whole contract from ring 3: the child resumes at the parent's post-SYSCALL RIP with `rax == 0`, sees the parent's pre-fork stack value, writes its **own** copy, exits — and the parent reaps it with `waitpid(-1)` and confirms the child's write was **not** visible. Parent and child interleave in the log, so they are genuinely concurrent.

⛔⛔ **THE REAL BUG WAS A SLOT-MAP INVERSION, AND 1.56.54 SHIPPED IT WORKING BY ACCIDENT.** fork wrote the child's return value to `p+32` — the `rax` field per `struct Process`'s doc-comment. It is not. `sched.cyr` carries the invariant: *"REVERSED-LABEL SLOT MAP (load-bearing): the proc-slot caller-saved fields restore into the REVERSE of their labels … p+32→r11 … p+112→rax. So the rax=0 return value goes to p+112 (NOT p+32)."* The labels are right for the SAVE side and for the symmetric timer round-trip, which is why nothing had noticed; they are wrong for any row written BY HAND — which is exactly what fork does. The child still read 0 only because the preceding `memset` zeroes `p+112` as well.
⭐ **Caught by mutation, not by reading.** Setting `p+32` to 99 left the child reading 0 and the gate GREEN; setting `p+112` to 99 makes the child read 99 and the gate FAIL. A passing test that cannot fail is what exposed it.

⚠ **Harness constraint, confirmed by log ORDER and worth keeping:** under a foreground `exec_and_wait` the child's lines appear only AFTER the run ends, so the parent's `waitpid` can never observe it — sched.cyr's IF=0 no-context-switch model. Both parent and child must be ordinary scheduled procs. Two earlier harness failures were mis-read as structural blockers and were not: `arch_wait()` is a bare `hlt` with no `sti`, and `elf_load_from_file` deliberately leaves ring-0 selectors for the caller to fix (`proc_set_ring3` before `proc_set_state(pid,1)` — the sequence `#43` documents).

⚠ **Still owed:** the cyrius `SYS_FORK = 96` peer + `sys_fork()` wrapper. Now that the kernel arm exists and is gated, the issue's own rule (*"do not mint the number before the kernel arm exists"*) is satisfied — file it in `cyrius/docs/development/issues/`.

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
