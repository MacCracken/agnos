# 2026-09-23 — `spawn_path`#43 answers -1 for every failure: a full process table and a missing or broken executable look the same

**Status:** ✅ **RESOLVED 1.57.6 (2026-09-24)** — `spawn_path`#43 returns `pid` or a negated `SPAWN_E_*` code: −2 `NOPROC` (process table full), −3 `NOMEM`, −4 `NOENT`, −5 `NOEXEC`, −6 `ARGS`; −1 is reserved for "anything else" and no 1.57.6 path produces it. `execwait`#37 folds every code to −1. Gate: `scripts/smoke/spawn-smoke.sh` (sweep row; kernel block `spawnk: elf codes OK`, ring 3 `SPAWNX-ENOENT-OK`, `-ENOEXEC-OK`, `-ENOEXEC-TINY-OK`, `-ENOPROC-OK`, `-EARGS-LINE-OK` at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). It starts agents with `#43`, and when a start
fails it has to tell its operator why.
**Checked against:** agnos **1.57.5**: the `#43` arm in `kernel/core/syscall.cyr` (`:10487`),
`elf_load_from_file` in `kernel/core/elf.cyr` (`:346`), and `proc_create_user` / `proc_alloc_slot` in
`kernel/core/proc.cyr` (`:606`, `:387`), read in the working tree.
**Consumer impact:** when the machine's 16 process slots are all in use, daimon cannot say so. It can
only answer that agnos "could not create the agent's process: its process table is full, or it
cannot load the executable".

> Every failure of `#43` is -1:
> - in the arm itself: a bad path range (`:10510`), a line over 127 bytes (`:10511`), no filesystem
>   (`:10512`), an empty name (`:10531`);
> - in `elf_load_from_file`: a missing or short file (`elf.cyr:353`), not an ELF (`:361`–`:365`), a
>   bad program header or segment (`:367`–`:450`), out of memory (`:418`, `:481`, `:526`);
> - and a full process table: `proc_create_user` gets -1 from `proc_alloc_slot` (`proc.cyr:607`–`:608`),
>   and `elf_load_from_file` returns it (`elf.cyr:661`).
>
> `proclist`#99 cannot answer the question either. agnos has no zombie state: an exited process that
> its parent has not reaped is state 0, which `#99` skips, yet `proc_alloc_slot` will not reuse its
> slot (the 1.56.55 note at `proc.cyr:402`). So a caller can count fewer records than there are slots
> in use.

---

## Measured (daimon's guest test, agnos 1.57.5 under QEMU)

- Before any agent, `#99` listed 4 processes: pids 0 and 1 (no name recorded), `agnsh` (pid 2, the
  test's launcher in kybernet's shell slot) and `guest` (pid 3).
- 12 agents started. `#99` then listed 16.
- The 13th `#43` returned -1, and so did four more attempts: the same answer a missing file gets.
- Stopping the 12 freed every slot, and 12 started again.

## The ask

Distinct negative codes, as `#97` already has with `CH_E_*`. At least:

- **no free process slot** (and out of memory): a resource condition a caller can wait out or report
  as capacity;
- **the executable does not exist or cannot be read**;
- **the file is not a loadable ELF**;
- **the arguments are invalid** (the line, or the env blob).

-1 can stay as "anything else", so existing callers keep working.

## What daimon does meanwhile

- It checks the executable exists (`stat`#33) just before `#43`, so a missing file is refused before
  the spawn, with its own answer.
- A failed `#43` is answered as "its process table is full, or it cannot load the executable", and
  audited (`agent.spawn.fail`). The agent is marked failed and can be started again.
- A full channel table is already distinct (`CH_MINT` answers `-CH_E_FULL`). daimon answers that one
  precisely: 503, "no room for another agent" (daimon 2.4.1).

---

## Resolution (1.57.6, 2026-09-24)

**What shipped** (ABI §4.8 code table, normative): the codes come from `elf_load_from_file`
(`elf_bail_code`) and from the `#43` body, which now lives in `spawn_path_sys` with ONE wrapper exit.

| code | name | meaning |
|---|---|---|
| −2 | `SPAWN_E_NOPROC` | the 16-slot table is full — deliberately agnos's WOULD_BLOCK value; found only after the ELF is loaded, so back off |
| −3 | `SPAWN_E_NOMEM` | page tables / 2 MB pages exhausted, or a `SPAWN_F_CLEANFD` child got no private fd table |
| −4 | `SPAWN_E_NOENT` | missing, not a regular file, short read, or no ext2 root |
| −5 | `SPAWN_E_NOEXEC` | not an ELF64 agnos loads (size, magic/class, entry, phdrs, PT_LOAD bounds, W^X) |
| −6 | `SPAWN_E_ARGS` | bad a2, a path range the caller does not own, empty path, bad argv blob, > 16 tokens/entries, or (flagged forms only) a bad env blob |

Every consumer surveyed tests `pid < 0`, so existing callers keep working; a failed pid passed to
`waitpid`#4 lands in the same wait-any arm for −2..−6 as for −1.

**The `#99` observation (zombies not listed):** documented, not changed (lead decision D10) — ABI row 99
and §4.8 say that an exited, unreaped child holds its slot but is not listed, and that **−2 from `#43`, not
a `#99` count, is the authoritative "table full" answer**. Listing unreaped children with a distinct state
is part of roadmap step S7.

**What the change broke — checked before archiving:** nothing observed (sweep, `ktest`, `agnsh-smoke`, the
spawn/#37 harnesses). The 1.57.5 control reads −1 for every kind. The "argc<=8" comment is fixed.

**Consumer notes:** daimon can map −2/−3 to capacity and −4/−5 to precise errors. cyrius peer constants are
filed in cyrius `docs/development/issues/2026-09-24-agnos-spawn-flags-redirect-ops-and-uptime-us-peer.md`.
