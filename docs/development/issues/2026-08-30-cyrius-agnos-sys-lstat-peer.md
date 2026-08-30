---
name: cyrius agnos sys_lstat peer
description: "#102 lstat is implemented in the agnos kernel and documented in the ABI; ring 3 cannot call it by name until cyrius adds the peer"
type: issue
---

# cyrius needs the `sys_lstat`#102 peer

**Status:** 🟡 **OPEN** — one enum entry and one wrapper in `cyrius/lib/syscalls_x86_64_agnos.cyr`.
**Repo owning the fix:** cyrius. Filed here because agnos is the side that minted the number.
**Blocks:** `scripts/check.sh` gate *"syscall ABI (kernel/doc/cyrius agree)"* — currently
`kernel 102 · abi-doc 102 · cyrius 101`. This is the only red gate in the 1.56.53 tree.

## What landed on the agnos side (1.56.53)

`#102 lstat(path, pathlen, statbuf)` — `stat`#33 that does **not** follow the final symlink. Same
48-byte struct, same failure shape; the only difference is `ext2_path_lookup_ex(..., follow_last=0)`,
the lookup mode `readlink`#70 introduced. Kernel arm, ABI row, and a mutation-tested gate
(`ext2w: Wlstat no-follow OK`, six arms) are all in.

## Why it was minted — the iron burn, not the roadmap's predicted consumer

The roadmap carried `lstat` as *"blocked on a consumer (kriya `ln -s`, or ark install layouts)"*. The
2026-08-30 validation burn produced a blunter one: **two root-filesystem entries that could be listed
but neither stat'd nor removed.** `/sl_s` (a slow symlink whose 70-byte target does not exist) and
`/lp` (a deliberate self-referential ELOOP link) — leftover `EXT2_WRITE_SELFTEST` fixtures that the
bare burn kernel never cleans up. Every `ls` and every `rm` printed `operation not permitted`, five
times in one capture (`agnosticos/basictests.txt`).

⭐ **`unlink`#30 was never the problem.** It resolves the parent and calls
`ext2_unlink(parent, basename)`, which refuses only directories — the selftest's own cleanup removes
both fixtures happily. What failed is that kriya's `rm` is written to **never** follow a symlink and
classifies every operand with `fs_lstat_at` first. On agnos that routed to path-based #33, which
follows, and the lookup fell into a target that does not exist.

kriya's own source says it (`src/lib/sys.cyr`, `fn k_lstat`):

> ⚠ NOT a true lstat on agnos … agnos has no lstat peer at all, so this routes to path-based
> `sys_stat`#33 — which FOLLOWS the final symlink … agnos roadmap carries `lstat` as
> unslotted-pending-a-consumer; **this is that consumer.**

⇒ A correct no-follow userland could not be correct on agnos, and the visible result was undeletable
files.

## The ask

```
SYS_LSTAT = 102
fn sys_lstat(path, pathlen, statbuf): i64 { return syscall(SYS_LSTAT, path, pathlen, statbuf); }
```

Mirroring `sys_stat`#33 exactly — same three arguments, same return. Then `k_lstat`'s agnos arm in
kriya changes from `_k_agnos_stat(path, buf)` to the real call, and its ⚠ comment can go.

⚠ **agnos is hands-off on cyrius by convention** — the same convention `symlink`#63 and `readlink`#70
were handled under (both shipped one-sided and were flagged to the operator; both peers have since
landed, which is why cyrius reads 101 and not 99). This is filed rather than done for that reason.

## Until it lands

Ring 3 can call it by raw number — `syscall(102, path, pathlen, buf)` — exactly as hapi did for #70
before its peer landed. Nothing is blocked except the name and the ABI gate.
