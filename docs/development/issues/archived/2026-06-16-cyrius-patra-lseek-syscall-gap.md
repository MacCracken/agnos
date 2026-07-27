# cyrius/AGNOS — no file-seek syscall: `patra` (→ libro → t-ron) fails to link on `--agnos`

**Status**: ✅ **RESOLVED — both sides shipped (closed 2026-06-30, archived).** The agnos kernel added **`lseek`#58** (`lseek(fd, offset, whence)`, whence 0=SET/1=CUR/2=END) at **1.45.13**, and the cyrius agnos peer now exposes **`SYS_LSEEK = 58` + `fn sys_lseek(fd, off, whence)`** in `lib/syscalls_x86_64_agnos.cyr`. So `patra`'s `syscall(SYS_LSEEK, fd, off, whence)` links + works on `--agnos` — the hard link error is gone. (Original status below: *Filed — BLOCKS a downstream consumer's AGNOS target; a hard link error, not a runtime fail-closed stub.*)
**Date**: 2026-06-16
**From**: thoth (the agentic-coding TUI) — reconfirmed on cyrius **6.2.15**.
**AGNOS surface at filing**: 1.45.x — syscalls 0–42 (frozen base + 1.43.x graphics/
timing/input) + the 1.45.x net/entropy/clock band 45–55. **No file-seek primitive.**
**Affects (if added)**: `kernel/core/syscall.cyr`, `docs/development/syscall-additions.md`,
`docs/development/agnos-userland-abi.md`.
**Related**: [`2026-06-15-cyrius-stdlib-missing-syscalls.md`](2026-06-15-cyrius-stdlib-missing-syscalls.md)
(the networking gap map — this issue is the FS-side sibling it did **not** cover),
`syscall-additions.md` (current surface; `AO_APPEND`#0x400 "seek to end" is itself
TODO/not-honored), `agnos-userland-abi.md` (the file model).

## Summary

AGNOS's file model is **sequential** — `open`#7 / `read`#5 / `write`#1 advance an
implicit per-fd cursor; there is **no `lseek`/seek syscall** to reposition it (and
`AO_APPEND` is documented as not-yet-honored). The cyrius stdlib's **`patra`** (the
embedded SQL/page store) needs **random-access positioning within its database file**
to persist a write-ahead log and page-indexed data. It composes that on a
`SYS_LSEEK`, which exists in the Linux/macOS/Windows/aarch64 syscall floors but **not**
in `syscalls_x86_64_agnos.cyr`.

Because `SYS_LSEEK` is simply undefined on the AGNOS target, this is **not** a
fail-closed runtime stub like the 2026-06-15 networking gaps — it is a **compile-time
link failure**:

```
$ cyrius build --agnos src/main.cyr build/thoth_agnos
error:lib/patra.cyr:114: undefined variable 'SYS_LSEEK' (missing include or enum?)
FAIL
```

The offending floor (cyrius 6.2.15 `lib/patra.cyr`):

```cyr
fn _pt_seek(fd, off): i64 {
    return syscall(SYS_LSEEK, fd, off, 0);   // line 113-114: SEEK_SET-style absolute seek
}
```

`patra` calls `_pt_seek` to rewind to the DB header, walk WAL pages, and seek to
`page_offset(page_num)` for every page read/write (`patra.cyr:140/149/202/382/448/480`).
None of that has a sequential-only fallback — random access is intrinsic to a paged store.

## Why thoth hits it (the dependency chain)

```
thoth  →  t-ron (per-tool MCP authorization)
       →  libro (t-ron's tamper-evident audit chain)
       →  patra_store (libro persists the audit ledger)
       →  patra _pt_seek
       →  syscall(SYS_LSEEK, …)        ← undefined on AGNOS
```

thoth's AGNOS lane is staged, wired, and announced-as-blocked (never faked) precisely
on this gap (thoth ADR-0008). thoth itself needs no change — it lights up with **zero
thoth edits** the instant the floor gains a seek primitive.

## Corroboration — it is `patra`, narrowly

Among the first-party consumers, **only `hoosh` and `thoth` depend on `patra`**; the
AGNOS-shipping `kriya` / `klug` use no `patra` and link `--agnos` fine. So this is not
a broad floor hole — it is one paged-store primitive that one capability path
(t-ron's audit ledger) pulls in. That keeps the AGNOS-side ask small and well-scoped.

## The ask (AGNOS-side; cyrius adapts)

A single absolute-position file-seek primitive is sufficient. Two shapes, either works:

| Option | Shape | Notes |
|---|---|---|
| **A — `lseek`** | `lseek(fd, offset, whence) → new_off / -1` | Direct match for cyrius's `syscall(SYS_LSEEK, fd, off, 0)` (whence `0` = `SEEK_SET`). `SEEK_SET` alone covers patra; `SEEK_END`/`SEEK_CUR` optional. Repositions the existing per-fd cursor. |
| **B — positioned I/O** | `pread(fd, buf, len, off)` / `pwrite(fd, buf, len, off)` | Avoids a stateful cursor entirely; patra's accesses are all `seek-then-read/write`, so positioned variants map cleanly. Larger cyrius-side change (patra would need a positioned path). |

**Recommendation: Option A (`lseek`, `SEEK_SET`)** — minimal AGNOS surface, exact fit
for the existing cyrius call site, no patra restructure. The FS band ended at #33
(`stat`) and the next band starts at #45 (`getrandom`), so **#43 or #44 is a natural
free slot** (AGNOS owners to assign per the number-overlap discipline in O5 /
`agnos-userland-abi.md` — must **not** reuse a Linux number raw).

Until then the AGNOS target for any `patra`-dependent binary (hoosh, thoth) cannot
link. This is the lone remaining blocker for thoth's canonical AGNOS lane (its
Linux **and aarch64-Linux** lanes both build on cyrius 6.2.15; aarch64 unblocked when
the cycc `#pure`/pass-1 scanner fix landed in **v6.2.2**).

## Note for the eventual macOS/Windows patra path

cyrius issue `2026-06-16-var-syscall-number-defeats-macho-pe-reroute.md` reports that a
`var SYS_FOO = N; syscall(SYS_FOO, …)` first arg does not const-fold, so the
macOS/Windows syscall reroute never fires (silently). `patra`'s `syscall(SYS_LSEEK, …)`
is exactly that enum-then-`syscall` shape — so even once AGNOS gains seek, the
**Darwin/Windows** patra path may need that cycc fix or a literal-folded call site.
Recorded here so it isn't rediscovered later; not an AGNOS-side concern.
