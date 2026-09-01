# `#96 fork` — built and gated in the kernel; agora still cannot call it without the cyrius peer

**Status:** 🟠 **BUILT AND GATED, BUT STILL OPEN ON THE cyrius PEER — 1.56.55.** `scripts/smoke/fork-smoke.sh` (in `sweep.sh`) proves the contract from ring 3 across TWO phases: phase 1 — the child resumes at the parent's post-SYSCALL RIP with `rax == 0`, sees the parent's pre-fork stack value, writes its **own** copy, exits, and the parent reaps it with `waitpid(-1)` and confirms the child's write was **not** visible; phase 2 — the parent forks **two** children and reaps both, distinctly. **The kernel arm is done. The file stays open because `agora` cannot call it**: cyrius has no `SYS_FORK = 96` (its own header still asserts *"STILL NOT MINTED. No dispatch arm exists in agnos 1.56.40"*), so ring 3 can reach `#96` only by raw number, which is what the test does. Peer filed as [cyrius `issues/2026-08-30-agnos-sys-fork-96-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-fork-96-peer.md).

⛔⛔ **1.56.55 — THE TWO-CHILD CASE WAS BROKEN, AND THE GATE THAT SHIPPED WITH WAIT-ANY COULD NOT SEE IT.** Adding a second forked child to `forker.cyr` turned up **two independent defects**, and the second one was hiding the first:
- **`proc_alloc_slot` reused an exited-but-UNREAPED child's slot.** agnos has no zombie state: `exit`#0 sets `state = 0` and deliberately does not reap, so `state == 0` means both "free" and "waiting for its parent" — and the scan reused either. Forking twice returned **the same pid twice** (`FORK-MULTI-P1 pid=3 / FORK-MULTI-P2 pid=3`); child 2 was allocated straight over child 1's exit status before the parent collected it. `proc_alloc_slot`'s own banner stated the premise fork invalidated: *"safe today because reuse only follows a reap done BY the reaper AFTER it captured the exit code."* True while every child was reaped synchronously by its spawner; false the moment fork produced the first unreaped child. This is the allocator-side face of the rule the 1.44.15 multi-collapse revert established from the reap side. Fixed with a `proc_ppid` guard (reuse only a row that is reaped, orphaned, or whose parent slot is gone — the orphan clause is load-bearing, since nothing in agnos reaps an orphan and without it a zombie pins its slot to reboot).
- **A reaped slot stayed its parent's child.** `proc_ppid` was cleared in exactly ONE place — `proc_alloc_slot`'s recycle scrub — which runs at slot REUSE, not at reap. A reaped **non-top** slot therefore kept `ppid == parent` + `state == 0`, verbatim the predicate wait-any scans for, so the next `waitpid(-1)` re-matched it forever, returned its stale code again, and never reached the parent's other children. Fixed by clearing `proc_ppid` on **both** reap doors (`proc_reap`, `proc_reap_child`).

⭐ **MUTATION-TESTED, THREE KERNELS, AND PHASE 1 WAS GREEN IN ALL THREE** — which is exactly how both defects survived: neither fix → `FORK-MULTI-EARLY-NOCHILD` (pid 3 twice); alloc guard only → `FORK-MULTI-DUP` (pids 3 and 4, code 21 returned twice); both → **PASS**. ⛔ Note the masking: while slots were handed out twice the phantom could not form, so fixing the phantom alone changes nothing observable. A first draft of the record predicted `DUP` for the unfixed kernel; the measurement said `EARLY-NOCHILD`, and the record was corrected from the log rather than the other way round.

⛔⛔ **AND THE GATE ITSELF WAS MEASURING THE PREVIOUS COMMAND'S KERNEL.** `fork-smoke.sh` ran `mcopy … build/agnos ::boot/agnos` at line 64 and `FORK_SELFTEST=1 build.sh` at line 71 — so the ESP received whatever kernel happened to be lying around, and the FORK_SELFTEST kernel the smoke exists to boot was compiled *after* the disk it should have been written to. A standalone run on a tree whose `build/agnos` was a plain kernel reported **all five phase-1 markers absent** (measured 2026-08-31). ⭐ **It looked green because `sweep.sh` gives each smoke one retry**: attempt 1 failed while building the correct kernel, attempt 2 booted it and passed. The gate was passing on its own retry, not on its subject. Build now precedes image assembly, and `/bin/forker` is rebuilt too — it never was, so an edit to `forker.cyr` silently did not reach the boot.

⛔⛔ **THE REAL BUG WAS A SLOT-MAP INVERSION, AND 1.56.54 SHIPPED IT WORKING BY ACCIDENT.** fork wrote the child's return value to `p+32` — the `rax` field per `struct Process`'s doc-comment. It is not. `sched.cyr` carries the invariant: *"REVERSED-LABEL SLOT MAP (load-bearing): the proc-slot caller-saved fields restore into the REVERSE of their labels … p+32→r11 … p+112→rax. So the rax=0 return value goes to p+112 (NOT p+32)."* The labels are right for the SAVE side and for the symmetric timer round-trip, which is why nothing had noticed; they are wrong for any row written BY HAND — which is exactly what fork does. The child still read 0 only because the preceding `memset` zeroes `p+112` as well.
⭐ **Caught by mutation, not by reading.** Setting `p+32` to 99 left the child reading 0 and the gate GREEN; setting `p+112` to 99 makes the child read 99 and the gate FAIL. A passing test that cannot fail is what exposed it.

⚠ **Harness constraint, confirmed by log ORDER and worth keeping:** under a foreground `exec_and_wait` the child's lines appear only AFTER the run ends, so the parent's `waitpid` can never observe it — sched.cyr's IF=0 no-context-switch model. Both parent and child must be ordinary scheduled procs. Two earlier harness failures were mis-read as structural blockers and were not: `arch_wait()` is a bare `hlt` with no `sti`, and `elf_load_from_file` deliberately leaves ring-0 selectors for the caller to fix (`proc_set_ring3` before `proc_set_state(pid,1)` — the sequence `#43` documents).

⚠ **Still owed, and it is the ONLY thing keeping this file open:** the cyrius `SYS_FORK = 96` peer + `sys_fork()` wrapper. The issue's own rule (*"do not mint the number before the kernel arm exists"*) is satisfied and the ask is **filed** (cyrius `issues/2026-08-30-agnos-sys-fork-96-peer.md`), but the constant does not exist yet, so `agora`'s `sys_fork()` still does not resolve. agnos does not modify cyrius; `scripts/check/syscall-abi-check.sh` reads `kernel 103 · abi-doc 103 · cyrius 101` and stays red on `#96` and `#102` until both peers land — the same one-sided state `#63` and `#70` shipped in.

⛔⛔ **AND THE ABI GATE WAS BLIND TO `#96` UNTIL 1.56.55, WHICH IS WHY NOBODY NOTICED THE DOC HALF EITHER.** `syscall-abi-check.sh` scans only `kernel/core/syscall.cyr` for the kernel number set, and `#96` dispatches from `arch/x86_64/syscall_hw.cyr` (the entry stub, like `#44` and `#14`). So the kernel set excluded 96, the ABI doc had no `| 96 |` row, cyrius had no `SYS_FORK` — and **all three sources agreed by mutual absence** while a shipped, sweep-gated syscall was undocumented on both sides. The gate's own comment already said *"if the stub gains or loses a number, this is where to add it"*; the instruction was right and simply was not followed when fork landed. `ENTRY_STUB_ONLY` now carries `96`, and the ABI doc has its row.

**What is done and proven** (`scripts/smoke/fork-smoke.sh`, ring-3 `/bin/forker`):
- `waitpid`#4 **wait-any** (`arg1 < 0`) — scans for a dead child of the caller, reaps the lowest, returns its code; `-2` while children live, `-1` when there are none. The `-2`/`-1` split is the contract a fork loop depends on.
- **`proc_dup_address_space`** — full copy (not CoW; agnos has no write-fault unshare path) of PD[1..510] plus the high-arena PDPT[128..511] PDs, reusing `proc_map_page`/`_nx`/`_hi` so the 0x87 bits, NX bit 63 and the KPTI entry-511 stash stay in one place.
- **`sys_fork`#96**, dispatched from `syscall_handler` — **not** `ksyscall` — for the same reason `#44`/`#14` are: the child's resume context comes from `pcpu_sc_entry_regs`, valid only on a path reached from the ring-3 entry stub.
- ⭐ **MEASURED IN QEMU**: `FORK-CHILD` and `FORK-CHILD-OK` both print. A second process really does resume at the parent's post-SYSCALL RIP with `rax == 0`, sees the parent's pre-fork stack value, and writes its **own** copy. `FORK-PARENT` prints too — the parent survives with a positive pid.

**What is NOT done — SUPERSEDED 1.56.54/1.56.55, retained so the resolution is legible.** This read: *"`FORK-PARENT-OK` — the parent's `waitpid(-1)` loop times out and never observes the exited child … the failure is in the parent/child handoff under a foreground `exec_and_wait`."* `FORK-PARENT-OK` has printed since 1.56.54, and phase 2's `FORK-MULTI-OK` since 1.56.55. The diagnosis in that sentence was right about the mechanism (`exit`#0 does set state 0 without reaping, and the child IS findable) and wrong about the location: the handoff was fine, and the two real defects were in `proc_alloc_slot` and the reap paths — see the Status header.

⛔ **AND THE HARNESS QUESTION IS THE REAL ONE, because agnos has almost nowhere a forked child can run.** Two shapes were tried and both are structurally wrong, for reasons that are properties of this kernel rather than of `#96`:
- **Foreground `exec_and_wait` runs the child IF=0** — sched.cyr states it: *"Refuse IF=0 callers (foreground exec/execwait children): their no-context-switch model is load-bearing."*
- **The boot thread cannot safely be switched away from** — *"restoring it would time-travel kmain."* Marking the proc ready and polling from boot printed its banner and stopped.
⇒ **The one context where a forked child can be scheduled alongside its parent is a proc spawned from agnsh via `spawn_path`#43, after boot.** That is where the remaining verification belongs, and it is also the shape the named consumer (agora, fork-per-connection) actually runs in.

⚠ **SUPERSEDED — both of these are now done.** They read: *"`fork-smoke.sh` is deliberately NOT wired into `sweep.sh` while it is red on `FORK-PARENT-OK`"* and *"the cyrius `SYS_FORK = 96` peer is not filed yet"*. The smoke went into `sweep.sh` at 1.56.55 (`run_gate "1.56.55 fork#96 + waitpid wait-any"`) and the cyrius peer was filed 2026-08-30. ⭐ The principle in the first line — *"a gate that passes while its subject is incomplete is the failure mode this repo has spent two cuts removing"* — is why phase 2 was NOT added to the marker list until the two defects it found were actually fixed.

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
