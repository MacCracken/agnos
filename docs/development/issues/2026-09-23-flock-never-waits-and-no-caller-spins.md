# 2026-09-23 — `flock`#59 never waits, and nothing above it spins: contended locks proceed unlocked

**Filed by:** patra (the sovereign database), during its 1.15.0 cut. patra takes a whole-file
`flock` around every statement: `LOCK_EX` for writes, `LOCK_SH` for reads.
**Checked against:** agnos **1.57.5**: the `#59` arm in `kernel/core/syscall.cyr` (at line 10950)
and `flock_apply` in `kernel/core/vfs.cyr` (1167–1222), read in the working tree. On the ring-3
side: the cyrius peer (`lib/syscalls_x86_64_agnos.cyr`, `SYS_FLOCK = 59`) and `lib/io.cyr`'s
`xflock` (cyrius 6.6.6), plus patra 1.15.0's `src/`. **By inspection only**: patra's agnos build
compiles warning-free, but nothing here has been run on agnos.
**Consumer impact:** any caller written against `flock(2)`, which waits for a conflicting lock
unless `LOCK_NB` is set. On agnos a contended `LOCK_EX` or `LOCK_SH` returns -1 at once, and a
caller that does not check proceeds without the lock. patra does not check (its 14 `LOCK_EX` and
3 `LOCK_SH` sites rely on waiting), so on agnos two processes can write one database at the same
time, and a reader can run in the middle of another process's write. That includes libro's JSONL
audit journal, which appends through patra's `jsonl_append` under `LOCK_EX`.

> `#59` is non-blocking by design, and its comment says who is meant to wait: *"a contended SH/EX
> returns -1 (WOULD_BLOCK) and the ring-3 caller poll-spins (yielding so the holder can release)"*.
> No ring-3 layer does. `xflock`, the stdlib's portable entry point, issues `#59` once and returns
> the result. patra, named in the same comment as one of the reasons `#59` exists, waits on
> `LOCK_EX` the way it does on every other target, which is to say it calls it and moves on. The
> spin the kernel counts on is in nobody's code.

---

## What the code does

- **`flock_apply` (`kernel/core/vfs.cyr:1177`) returns -1 on any conflict with another pid**: EX
  against any holder, SH against an EX holder. It never reads `LOCK_NB` (bit 4), so `LOCK_EX` and
  `LOCK_EX | LOCK_NB` behave identically. The non-blocking form is the only form.
- **It also returns -1 when the 16-slot table is full** (`vfs.cyr:1222`). Under the agnos -1
  convention a caller cannot tell "contended" from "no slot", so a ring-3 spinner would spin forever
  on a full table.
- **cyrius `lib/io.cyr` `xflock`, agnos arm**: `return sys_flock(fd, op);`, one call, no retry.
- **patra**: `patra_lock_ex(fd);` opens every write statement (13 sites in `src/lib.cyr`, e.g.
  `_exec_create`) and `jsonl_append` (`src/jsonl.cyr:27`). `patra_lock_sh` opens both JSONL readers
  (`src/jsonl.cyr:212, 400`), and `_tx_lock_sh` opens every `SELECT` (`src/lib.cyr:2063`). None
  checks the result. The one site that *wants* non-blocking behaviour, `patra_open`'s crash recovery
  (`LOCK_EX | LOCK_NB`, checked `== 0`), is correct on agnos as it stands.
- **Threads are not affected**: agnos runs a process's threads serially, which is why
  `lib/sync.cyr`'s agnos `mutex_lock` is a no-op. This is cross-process only.

## The ask

One of:

1. **`#59` waits when `LOCK_NB` is clear**: park the caller until the conflicting holder
   releases, scheduling others meanwhile (as `pause`#14 yields to a ready process), and return -1
   at once only when `LOCK_NB` is set. That is `flock(2)`'s contract; every consumer written against
   it (patra, libro through patra, agora) then works unchanged, and `LOCK_NB` means something.
2. **`#59` stays non-blocking, and the poll-spin gets a home in ring 3**: `lib/io.cyr`'s `xflock`
   agnos arm loops on -1 while `LOCK_NB` is clear, yielding each time so the holder can run and
   release. It must yield with `pause`#14 or `sched_yield`, **not** `sleep_ms`#41, which holds the
   CPU (`2026-09-23-sleep-ms-holds-the-cpu.md`), so a sleeping spinner would starve the very
   holder it waits on. Then the comment's contract is true and consumers need nothing. That change
   lands in cyrius, but the contract is the kernel's, so it is filed here first.

Either way, **distinguish "contended" from "table full"** (a different return, or a larger table),
so a waiter can fail on the latter instead of spinning forever.

## What patra does meanwhile

Nothing in code. It does not work around kernel lock semantics. patra 1.15.0 documents the gap:
the *Platforms* section of `docs/development/roadmap.md`, the footguns in `state.md`, and
`SECURITY.md`'s deployment table all point here. Until this lands, a patra database written by more
than one agnos process is not safe.
