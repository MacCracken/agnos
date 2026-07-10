# 2026-07-09 — cyrius: userland wrappers for agnos block-device syscalls (#75–80)

**Status:** OPEN — cyrius-side ask. **Filed in the cyrius repo** (the copy the cyrius agent
acts on): `cyrius/docs/development/issues/2026-07-09-agnos-sys-blk-peers.md`. This is the
agnos-side mirror ([[feedback_cross_repo_issues_both_repos]] — cross-repo issues go in BOTH repos).
**Pairs with:** `2026-07-09-ring3-block-device-syscalls-for-install.md` (the agnos kernel side).
**Driver:** the native-install primitive — agnova (and sovereign `mkfs`/`partition` tools)
must be able to call the new agnos raw block-device syscalls from Cyrius.

## Ask

Add `#ifdef CYRIUS_TARGET_AGNOS` userland wrappers to
`cyrius/lib/syscalls_x86_64_agnos.cyr` for the new agnos block syscalls, in the same
shape as the existing `sys_snd_*` (#64–69) and `sys_shm_*` (#71–74) wrappers. These are
**agnos-only** (no Linux/macOS peer); consumers that use them must be agnos-target or gate
the call under `#ifdef CYRIUS_TARGET_AGNOS`.

The agnos enum constants (`SYS_BLK_*`) land in the agnos kernel's syscall table + the
agnos-target syscall enum at the 1.53.10 cut; the cyrius wrappers just expose them:

```cyrius
# Raw block-device access (agnos 1.53.10). RW-open is capability-gated kernel-side —
# these wrappers only marshal the syscall; the kernel enforces the installer capability.
fn sys_blk_enum(buf, cap): i64        { return syscall(SYS_BLK_ENUM, buf, cap); }
fn sys_blk_open(name, mode): i64      { return syscall(SYS_BLK_OPEN, name, mode); }   # mode 0=RO 1=RW
fn sys_blk_read(h, lba, buf, nsec): i64  { return syscall(SYS_BLK_READ, h, lba, buf, nsec); }
fn sys_blk_write(h, lba, buf, nsec): i64 { return syscall(SYS_BLK_WRITE, h, lba, buf, nsec); }
fn sys_blk_info(h, out): i64          { return syscall(SYS_BLK_INFO, h, out); }
fn sys_blk_close(h): i64              { return syscall(SYS_BLK_CLOSE, h); }
```

## Notes

- Final syscall numbers + arg order are set by the agnos kernel at 1.53.10 — sync the
  `SYS_BLK_*` enum values in `syscalls_x86_64_agnos.cyr` to whatever the kernel assigns
  (indicatively #75–80; `blk_read`/`blk_write` are the a4=r10 5-reg calls, mind the agnos
  syscall ABI on the 4th arg like `snd_write`#66 does).
- No `net.cyr`-style portable wrapper — this surface is agnos-native (Linux consumers use
  `/dev` + `parted`/`mkfs`, a different world). Keep it in the agnos syscall file only.
- Consumer: **agnova**'s executor (post-port) + any sovereign `mkfs`/`partition` tool.
