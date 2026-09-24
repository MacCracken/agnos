# 2026-09-23 — `spawn_path`#43 answers -1 for every failure: a full process table and a missing or broken executable look the same

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
