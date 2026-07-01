# cyrius stdlib — add the AGNOS `sys_symlink` peer for kernel `symlink`#63

**Status**: ✅ **RESOLVED 2026-06-30.** Both halves shipped — agnos kernel `symlink`#63 (1.51.0) + the cyrius `sys_symlink` peer (**cyrius 6.3.6**, current 6.3.9) — and the on-agnos round-trip is **proven**: `agnos/scripts/symlink-smoke.sh` boots a `--agnos` exerciser that calls `sys_symlink("/etc/hostname","/hn_link")`, the symlink lands on the agnos-fs (`debugfs`: `Type: symlink`, `Fast link dest: "/etc/hostname"`), `open("/hn_link")` follows it to the target bytes, and `e2fsck -fn` is clean. The ark v2 item (a) is closed; ark's install path is wired to the peer (`ark/src/portable.cyr`). The remaining ark M3 gate is the *unrelated* large-binary exec blocker (see `2026-06-30-large-binary-exec-stack-overflow.md`).
**Date**: 2026-06-29
**Priority**: **Medium — the ark v2 / agnova DO-FIRST prerequisite.** Unblocks **ark M3** (on-agnos install of a prebuilt signed `.ark`, = agnova's install minimum): `ark_pkg_install` pass-2 creates `.so → .so.N` symlinks. The agnos kernel half shipped at **1.51.0**; ring 3 cannot call it until this peer lands.
**From**: agnos 1.51.0 (kernel `symlink`#63) vs cyrius `lib/syscalls_x86_64_agnos.cyr` (has `sys_link` but **no `sys_symlink`**).
**Related**: agnos `kernel/core/syscall.cyr` (#63 dispatch), `kernel/core/ext2.cyr` (`ext2_symlink`, 1.33.3), `docs/development/agnos-userland-abi.md` (§ syscall table row 63). cyrius: `lib/syscalls_x86_64_agnos.cyr` (the `sys_unlink`/`sys_stat`/`sys_rename`/`sys_link` neighbors — `sys_symlink` slots right beside `sys_link`).

## The gap

The agnos file-op peer band in cyrius `lib/syscalls_x86_64_agnos.cyr` exposes `sys_unlink`#30 / `sys_rename`#31 / `sys_link`#32 (hardlink) / `sys_stat`#33 — but there is **no `sys_symlink`**. So no `--agnos` program (ark / agnova / kriya `ln -s`) can create a symbolic link, even though the kernel now implements it. The kernel arm alone is a no-op to userland.

## The kernel ABI to wire against (verified from `kernel/core/syscall.cyr` @ 1.51.0)

### `symlink` — syscall **#63**
```
symlink(target = arg1, targetlen = arg2, linkpath = arg3, linkpathlen = a4) -> rax
```
- `arg1`/`arg2` = the symlink's **TEXT contents** (what it points at) + length. This is link TEXT, **NOT a path the kernel resolves** — a symlink may point at a nonexistent/relative target. Validated as a user buffer, `1 <= targetlen <= 4096` (one ext2 block; `ext2_symlink` re-caps at the live blocksize).
- `arg3`/`a4` = the **linkpath** (where the symlink is created) + length. A real path: `sc_path_ok`'d, **ext2-only** (symlinks need inodes; FAT/exFAT → `-1`). `a4` arrives via `r10` (the established 4-arg agnos convention, same as `sys_link`#32 / `sys_rename`#31).
- Returns **0** on success, **-1** on failure (POSIX-like). (Internally `ext2_symlink` returns the new inode > 0; the syscall normalizes to 0/-1.)

### The cyrius peer to add (mirrors `sys_link` exactly)
```cyrius
fn sys_symlink(target, targetlen, linkpath, linkpathlen): i64 {
    return syscall(SYS_SYMLINK, target, targetlen, linkpath, linkpathlen);
}
```
with `SYS_SYMLINK = 63` added to the agnos syscall-number enum (next to `SYS_LINK`). Number **#63** was the next free agnos syscall (#0–62 all taken; #44 `sched_yield` dispatches in `syscall_hw.cyr`). NOTE the 1.52.x audio band ("next free contiguous band") consequently shifts to **#64-69**.

## Done-criteria ([[feedback_qemu_test_agnos_userland]] — compiling ≠ working)

Mark the ark v2 item (a) complete only when **both** sides ship **AND** an on-agnos round-trip works: a `--agnos` program calls `sys_symlink(...)`, the symlink lands on the agnos-fs, resolves on traversal, and survives `e2fsck -fn`. The natural end-to-end exerciser is the ark M3 `.ark`-with-symlinks install.
