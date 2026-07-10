# 2026-07-10 — Directory-listing syscall `readdir` (#81) + its cyrius wrapper

**Status:** ✅ **CLOSED** (2026-07-10) — all three legs done. **Kernel:** cut 1.53.13
(`ext2_readdir_sys` + dispatch #81). **cyrius:** `SYS_READDIR = 81` + `sys_readdir(path, buf,
max)` agnos-gated wrapper shipped in **v6.4.43** (see the RESOLVED copy in
`cyrius/docs/development/issues/2026-07-10-agnos-sys-readdir-wrapper.md`). **Consumer:** crab
migrated off the raw `syscall(81, …)` to the named `sys_readdir(…)` and cut **0.3.0** (pin
6.4.34 → 6.4.43). QEMU-proven end-to-end on agnos: both crab panes list their real directories
(`/bin` → `aethersafha`/`crab`/`puka`; `/` → `bin/`/`lost+found/`) and navigate (setu-nav +
setu-pane tests PASS). Follow-ups below (fd-relative readdir, richer records, FAT) remain open
as separate kernel work.

## Problem

A file manager (crab) — and any Cyrius program — needs to **list a directory** from ring 3.
agnos had internal dirent walking (`ext2_print_dir`, path lookup via `ext2_path_lookup`) but
**no ring-3 syscall**, so a userland program couldn't enumerate a directory.

## Kernel side (done)

- **`kernel/core/ext2.cyr` — `ext2_readdir_sys(path, buf, max_entries)`** — resolves `path`
  (a user NUL-terminated cstring) to a directory inode via `ext2_path_lookup`, walks its
  dirents (same shape as `ext2_print_dir`), and writes up to `max_entries` **fixed 64-byte
  records** to the ring-3 `buf`:
  - bytes `0..62` = entry name, NUL-terminated, truncated to 62;
  - byte `63` = type (`1` = directory, `0` = file).
  - `.` and `..` are skipped.
  - Both pointers are `is_user_range`-validated; the name copy is bounded.
- **`kernel/core/syscall.cyr`** — dispatch: `if (num == 81) return ext2_readdir_sys(arg1,
  arg2, arg3);`  → `readdir(path, buf, max) -> count` (≥ 0), or a negative error
  (`-1` bad ptr / not ext2, `-2` path not found, `-4` not a directory).

Proven on agnos: crab (`syscall(81, "/bin", buf, 32)`) shows `aethersafha` / `crab` / `puka`;
`syscall(81, "/", …)` shows `bin/` / `lost+found/`.

## cyrius-side ask (open)

Add a stdlib wrapper so programs write `sys_readdir(path, buf, max)` instead of the raw
`syscall(81, …)` — and so it's `#ifdef CYRIUS_TARGET_AGNOS`-gated (agnos-only; on Linux it
should return an error / not emit syscall 81, which is `fchdir` there). Mirror the existing
`sys_shm_*` (6.4.34) and `sys_blk_*` (6.4.39) agnos wrappers in `lib/syscalls_x86_64_agnos.cyr`.

Done in cyrius v6.4.43; crab migrated to `sys_readdir(…)` at 0.3.0 (was the raw `syscall(81, …)`
under its own `#ifdef CYRIUS_TARGET_AGNOS`).

## Follow-ups (kernel, later)

- Path-relative / fd-based `readdir` (currently path-only, absolute).
- Entry metadata beyond name+type (size, mtime) — a wider record or a `stat` syscall.
- FAT/exFAT readdir (this is ext2-only; `exfat_ls`/`fatfs_ls` exist internally but aren't wired).
