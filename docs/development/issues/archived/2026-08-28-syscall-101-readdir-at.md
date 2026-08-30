# `#101 readdir_at` — a directory listing that can resume

**Status:** ✅ **RESOLVED — SHIPPED 1.56.50, hardened 1.56.51.** Swept 2026-08-30. Kernel arm, cursor contract, `-5` misalignment refusal and the ABI row are all present and consistent. Nothing carried.

**Original status:** ✅ **Built** 2026-08-28 (agnos 1.56.50), and **exercised against a booted kernel**.
**Repo owning the design:** agnos (this file).
**Cross-repo:** filed in **both** repos — cyrius peer is
`docs/development/issues/2026-08-28-cyrius-syscall-101-readdir-at-wrapper.md` (cyrius 6.5.36).
**Severity:** Medium — `#81` silently truncated, which reads as a filesystem fault.
**Precedent:** identical in shape to `#100 icmp_echo_ex` (a separate number rather than widening an
existing one) and `#99 proclist`.

---

## The defect

`#81 readdir(path, buf, max)` always starts at the top of the directory and stops at `max`. A
directory with more entries than the caller's buffer is **silently truncated**, and the caller cannot
tell truncation from a small directory. crab's pane cap was exactly this ceiling: on iron 2026-08-19
`/` held 114 entries against a 32-entry cap, and a file the shell's `ls` listed was simply absent
from the pane — which reads as a filesystem fault, not as a cap.

## What was added

`ext2_readdir_at_sys` in `kernel/core/ext2.cyr`, dispatched at `#101`:

```
readdir_at(path, buf, max, cursor_uva) -> entry count (>=0), or <0
  errors: -1 bad ptr / not ext2 · -2 not found · -4 not a dir · -5 misaligned cursor
```

`*cursor` is `0` to start. On return it is the byte offset to resume from, or **`-1` when the
directory is exhausted**. Callers loop `while (cur != -1)`. Passing `-1` back in returns `0` and
changes nothing, so a loop that overruns by one is harmless rather than an infinite restart.

## Why the cursor is a byte offset

It is POSIX `telldir`'s cookie, and the only value that survives ext2 directories being a chain of
**variable-length** records. An entry *index* would force a re-walk from the top on every call —
the O(n²) that resumability exists to avoid.

## Why a new number and not a 4th argument on `#81`

⛔ `#81`'s callers pass three arguments. Unused syscall argument registers are **not zeroed by the
compiler** — agnos already records this at `#55` (*"arity is part of a syscall's ABI here"*) and
cyrius measured it on 6.5.35. Widening `#81` would hand the kernel garbage in the 4th register from
every existing call site, and unlike `#55`'s timeout **this argument is a pointer the kernel writes
through**. `#96` remains reserved for `fork` and was not taken.

## ⚠ Guarding — the part consumers get wrong

A kernel older than 1.56.50 has no `#101` arm; the dispatcher returns `-1`. Treat a negative return
as *"this kernel cannot resume a listing"* and **fall back to `#81`**, rather than rendering an empty
directory. "No entries" and "this kernel cannot page" are different facts. crab does exactly this.

Consumers must also not hard-code `101`. A raw `syscall(101, …)` is the bug class `roadmap.md`
tracks; cyrius 6.5.36 ships `SYS_READDIR_AT` + `sys_readdir_at` so they do not have to.

## ⛔ The cursor is user data and is validated as such

Rejected unless 4-byte aligned (ext2 records always are) and inside the directory — a misaligned
offset would parse a record header out of the middle of a filename. `ext2_dirent_valid` still bounds
every record to its block, so the worst a *valid-looking* wrong offset can do is yield nonsense
names, never a read outside `ext2_dir_buf`.

## Acceptance

- ✅ `tests/readdir/rdat.cyr` — ring-3 exerciser, exit `95` iff the contract holds; `90`-`97`
  pinpoint the clause that broke. `scripts/harness/readdir-at-test.py` boots it under QEMU.
- ⭐ **The oracle is "paged == single-shot", not "paged > 0"**: it compares its batched total against
  what one `#81` call reports. A walk returning the first batch forever would still terminate and
  still return entries; a walk skipping one record per batch would still look plausible. One
  comparison catches omissions and duplicates together.
- ✅ **Mutation-proven four ways**, each a full kernel rebuild and boot: resuming at the block start
  instead of mid-block (exit 93, never terminates), the budget checked after the record is consumed
  (92, a batch overruns `max`), exhaustion writing `0` instead of `-1` (93), and the alignment guard
  removed (97).
- ✅ First consumer: crab, against a seeded **1200-entry** directory — `showing 1024 of 1200`.
- ⚠ **Not yet done:** exercised through the cyrius `sys_readdir_at` wrapper. `rdat.cyr` predates
  cyrius 6.5.36 and calls the raw number; crab carries that verification.
