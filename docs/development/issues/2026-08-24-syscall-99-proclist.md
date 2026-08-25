# `#99 proclist` — the first process-enumeration primitive

**Status:** ✅ **Built** in 1.56.47 (`kernel/core/syscall.cyr`, `if (num == 99)`).
**Cross-repo:** peer filed at
[`cyrius/docs/development/issues/2026-08-24-agnos-syscall-99-proclist-wrapper.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-24-agnos-syscall-99-proclist-wrapper.md),
per the standing rule that an agnos↔cyrius syscall is recorded on both sides.
**Driver:** chakshu v1.0 — *"ship as the AGNOS default monitor"*.

---

## The gap

AGNOS exposed **no way to enumerate processes**. The ring-3 surface offered `getpid`,
`spawn`, `waitpid` and `kill`, and there is no procfs. Nothing could answer *"what is
running on this machine?"* — which is the entire question a system monitor exists to answer.

This was not a degradation, it was an absence: chakshu's `--agnos` build rendered its
`PID S CPU% MEM% CMD` header and **zero rows**, on every boot, correctly, because there was
nothing to ask. Its roadmap carried the gap under *"Blocked upstream (not schedulable
here)"* with the note that there was no workaround from the consumer side. That was right.

## What was missing vs what was merely unreachable

Worth separating, because only one of these was real work:

- **Unreachable, already present:** `pid` and `state` live in `proc_table` (`struct Process`
  +0 and +8); `ppid` in `proc_ppid[]`. All of it existed; none of it was exposed.
- **Genuinely absent:** a process **name**. `struct Process` is pure register state, and
  `proc_create_user(entry, stack_top)` never saw a path — so a ring-3 process's only
  identity was its pid number. A table of bare pids is not a monitor.

## The name, and where it is captured

1.56.47 adds `proc_names[]` (16 × 32 B) plus `proc_set_name` / `proc_name_ptr` /
`proc_clear_name` in `kernel/core/proc.cyr`, and calls `proc_set_name` from
`elf_load_from_file` immediately after `proc_create_user` returns — **the one point in the
kernel where a path and a pid are both in hand**. The basename is stored, not the full path:
the column is narrow and `/bin/shu` tells a reader nothing that `shu` does not.

⚠ **Sizing.** Module-scope `var X[N]` is N × u64 = N*8 **bytes**, so 16 × 32 B is declared
`var proc_names[64]`, not `[512]`. This file already documents that trap twice
(`proc_full_said`, and the `var pscr[2]` bug in `#98` where the module-scope rule was applied
to a function local and dx/dy came back as garbage).

## Contract

```
proclist(buf, max) -> records written, -1 on a bad user range or max < 1
```

64-byte record, one per live slot, dead slots skipped:

| off | type | field |
|---|---|---|
| +0 | u64 | `pid` |
| +8 | u64 | `state` — 1 ready · 2 running · 3 claiming |
| +16 | u64 | `ppid` — 0 = init |
| +24 | u8[32] | `name` — NUL-terminated basename |
| +56 | u64 | `reserved` — always 0 today |

The walk runs under `preempt_disable` so the set cannot change mid-copy, and the name field
is NUL-padded to a full 32 bytes so ring 3 can never read a stale byte left by a previous
occupant of the slot.

## ⚠ The reserved field is a decision, not slack

Per-process **rss** and **cpu time** are not tracked by this kernel. They are therefore not
invented here — a monitor showing a fabricated MEM% is worse than one showing none. When
the kernel does track them they land at `+56` and **the record size does not change**, so
consumers that zero-check the field keep working. Widening the record later would require a
new syscall number; using the reserved field does not.

## ⚠ Guarding, for consumers

A kernel older than 1.56.47 has no `#99` arm. A negative return means *"this kernel cannot
enumerate"* and must be reported as such — **not** as an empty process table. Those are
different facts and conflating them reports a lie in the quiet direction.

Consumers must call it as `sys_proclist` via the cyrius wrapper. A raw `syscall(99, …)` is
the bug class `roadmap.md` tracks: raw Linux numbers compiling clean on agnos and
dispatching a different arm.

## Why `#99`

0-95 and 97-98 have dispatch arms; `99` had none. `#96` is **reserved for `fork`** by the
operator ruling of 2026-08-05 and was not taken. `#44` looks free to a `num ==` grep and is
not — `sched_yield` dispatches in the ring-3 entry stub, not in `ksyscall`.

## Follow-ups (not in 1.56.47)

- Per-process rss and cpu time into the reserved field. Needs the kernel to account them
  first; the mmap arena cursor (`proc_himmap_next[]`) is the obvious starting point for rss.
- 16-slot ceiling. `proc_table` is 16 processes; `proclist` inherits that and cannot report
  more. Fine for today's system, and the record format does not care if it grows.
