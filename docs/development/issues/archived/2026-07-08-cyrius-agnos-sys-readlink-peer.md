# cyrius stdlib — add the AGNOS `sys_readlink` peer for kernel `readlink`#70

**Status**: 🔧 **OPEN** — the agnos kernel `readlink`#70 half is **shipped + QEMU-proven** (see
below); this is the cyrius ring-3 wrapper, the ABI-completeness half. **Not blocking**: the first
consumer (hapi) already calls #70 via a *locally-defined* number (`AGNOS_SYS_READLINK`#70 in
`hapi/src/agnos_compat.cyr`, the same self-contained pattern it used for `symlink`#63 before the
6.4.x peer), and mirshi emulates the syscall — so the round-trip works today. The peer makes the
call native (`sys_readlink(...)`) for hapi and any future `--agnos` consumer once they re-sync
their vendored `lib/`. **The cyrius-side request is filed IN the cyrius repo at
`docs/development/issues/2026-07-08-agnos-sys-readlink-peer.md`** (cyrius house format) — the cyrius
language agent picks it up there; this agnos-side copy is the mirror.
**Date**: 2026-07-08
**Priority**: **Low — ABI-completeness.** The kernel + the sole consumer + the mirshi supervisor
are all done and proven; only the canonical cyrius wrapper is missing. No consumer is blocked (the
local-number path is proven), unlike the `sys_symlink`#63 peer which *gated* ark M3.
**From**: agnos `readlink`#70 (kernel) vs cyrius `lib/syscalls_x86_64_agnos.cyr` (has `sys_symlink`
but **no `sys_readlink`** — and no `sys_lstat`/`sys_fstat` either; `sys_fstat` fails closed).
**Related**: agnos `kernel/core/syscall.cyr` (#70 dispatch), `kernel/core/ext2.cyr`
(`ext2_readlink` + the new no-follow `ext2_path_lookup_ex`), `docs/development/agnos-userland-abi.md`
(§3.2 row 70). cyrius: `lib/syscalls_x86_64_agnos.cyr` (`sys_symlink`#63 is the immediate neighbor —
`sys_readlink` slots right after it, and `SYS_READLINK = 70` after the audio band `SYS_SND_AVAIL`#69).

## The gap

The agnos file-op peer band in cyrius `lib/syscalls_x86_64_agnos.cyr` exposes `sys_symlink`#63 (create
a link) but nothing to *introspect* one — there is no `sys_readlink` and no `sys_lstat`, and path-based
`sys_stat`#33 FOLLOWS the final symlink. So a `--agnos` symlink manager could create a link but never
SEE an existing one or read its target. The agnos kernel closed that with `readlink`#70; this peer is
the ring-3 wrapper for it.

## The kernel ABI to wire against (verified from `kernel/core/syscall.cyr`, QEMU-proven)

### `readlink` — syscall **#70**
```
readlink(path = arg1, pathlen = arg2, buf = arg3, buflen = a4) -> rax
```
- `arg1`/`arg2` = the path to the symlink + length (a real path: `sc_path_ok`'d, **ext2-only** —
  symlinks need inodes; FAT/exFAT → `-1`). The FINAL component is resolved **NO-FOLLOW**
  (`ext2_path_lookup_ex(path, len, follow_last=0)`), so #70 reads the LINK, not its target; a
  mid-path symlink still resolves.
- `arg3`/`a4` = the output `buf` + its capacity (`is_user_range(buf, buflen)`; the target is written
  **not** NUL-terminated, `≤ buflen`). `a4` arrives via `r10` (the 4-arg agnos convention, same as
  `sys_symlink`#63 / `sys_link`#32).
- Returns the **target byte length** (`> 0`) on success; **-1** when the path is absent, the final
  component is not a symlink (`ext2_readlink`'s `0xA000` mode check), the target exceeds `buflen`, or
  the mount isn't ext2. (`ext2_readlink` reads fast-inline / slow-block, extent-aware.)
- Number **#70** = the next free agnos syscall (the audio band occupies #64-69).

### The cyrius peer to add (mirrors `sys_symlink` exactly)
```cyrius
# in enum SysNrAgnos, after SYS_SND_AVAIL = 69:
    SYS_READLINK   = 70;          # readlink(path, pathlen, buf, buflen) → target bytes / -1 (a4=r10).
    #   Symlink-INTROSPECTION peer of SYS_SYMLINK=63: reads the link's TEXT target NO-FOLLOW into
    #   buf (≤ buflen, not NUL-terminated); -1 if path absent / not a symlink / target > buflen / non-ext2.

# after fn sys_symlink(...):
# Read the TEXT target of the symlink at `path` (len `pathlen`) into `buf` (cap `buflen`),
# returning the target byte count (≤ buflen, NOT NUL-terminated) or -1. 4-arg, a4 in r10. The
# no-follow introspection peer of sys_symlink#63 (agnos readlink#70) — resolves the FINAL path
# component WITHOUT following it, so a --agnos symlink manager (hapi) can SEE an existing link +
# read its target (there is no lstat peer, and path-based sys_stat#33 FOLLOWS the final symlink).
fn sys_readlink(path, pathlen, buf, buflen): i64 {
    return syscall(SYS_READLINK, path, pathlen, buf, buflen);
}
```

## Status of the other three halves (all done — this is the only open piece)

- **Kernel (agnos)** — `readlink`#70 handler + the `ext2_path_lookup_ex(path, len, follow_last)`
  no-follow refactor (public `ext2_path_lookup` = the `follow_last=1` wrapper, every prior caller
  byte-identical). **QEMU-proven**: `SYMLINK_SELFTEST=1 ./scripts/build.sh && scripts/symlink-smoke.sh`
  now asserts `READLINK-OK` — the same `/hn_link` returns `archaemenid` via `open()` (follow) and
  `/etc/hostname` via `readlink`#70 (no-follow); e2fsck-clean. (CHANGELOG `[Unreleased]`.)
- **Consumer (hapi)** — `link_probe` flipped to readlink-first (`hapi_readlink` shim,
  `AGNOS_SYS_READLINK`#70 local number); builds `--agnos` + Linux, suite 242/0.
- **Supervisor (mirshi)** — emulates #70 → host `readlink(89)` (unconfined) / `readlinkat(267)`
  (`--root`); seccomp allows 89 + 267; `docker/tools/rltest.cyr` smoke PASS (both modes). Suite 295/0.

## Done-criteria

The peer is done when `sys_readlink` is in `lib/syscalls_x86_64_agnos.cyr` and a `--agnos` program
calling the *native* `sys_readlink(...)` (not the raw local number) reads a symlink's target under
mirshi and on real agnos. On landing, flip hapi's `hapi_readlink` agnos branch from
`syscall(AGNOS_SYS_READLINK, ...)` to `sys_readlink(...)` on its next `lib/` re-sync (mirroring how
`hapi_symlink` moved to the native peer at hapi 1.0.3) and archive this issue.
