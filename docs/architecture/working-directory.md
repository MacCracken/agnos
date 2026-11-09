# The per-process working directory — `chdir`#112, `getcwd`#113 and the path ingress (invariants)

> **Last Updated**: 2026-11-08 (1.57.18 — issue `2026-11-06-a-relative-path-has-no-working-directory`, operator ruling
> 2026-11-08: the kernel keeps a working directory per process; it reverses ABI § 3.2's "CWD is userland-owned").
>
> Code: `sc_path_take`, `sc_cpath_take`, `path_clean_join`, `sc_path_is_dir`, `sys_chdir`, `sys_getcwd`,
> `spawn_seed_cwd`, the program-path resolution in `spawn_load_child`, and the path preamble of every path-taking arm
> in [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) · `proc_cwd_len`, `proc_cwd_buf`, `proc_cwd_set`,
> `proc_cwd_inherit`, `proc_cwd_reset` and their two call sites (`proc_alloc_slot`, `proc_create_user`) in
> [`kernel/core/proc.cyr`](../../kernel/core/proc.cyr) · `sys_fork` in
> [`kernel/arch/x86_64/syscall_hw.cyr`](../../kernel/arch/x86_64/syscall_hw.cyr) · the default env's `PWD=` in
> `elf_load_from_file` ([`kernel/core/elf.cyr`](../../kernel/core/elf.cyr)) · `fat_path_is_dir` / `exfat_path_is_dir`.
> ROOM slots 12 (`proc_cwd_buf`) and 13 (`pcpu_sc_path`) in [`kernel/core/room.cyr`](../../kernel/core/room.cyr).
> Gate: `scripts/smoke/cwd-smoke.sh` (`tests/cwd/cwdx.cyr`), `-smp 1` and `-smp 4`, ext2 + the ZFS fixture + the ESP's FAT.
> ABI: [`agnos-userland-abi.md`](../development/agnos-userland-abi.md) § 3.2 rows 112–113 and the paragraph after the table.

## What changed

Until 1.57.18 agnos had no working directory: a relative path was rooted at `/` (open#7 only — the other arms
refused it outright through `vfs_resolve_mount`'s "must be absolute"), and the ABI told every program to resolve its
own relative operands against `$PWD`. A program that did not read the wrong file, silently: thoth's "relative, no `..`"
jail read `/etc/secret.txt` for `etc/secret.txt` from a project directory. Now:

- every process has a **working directory**, a normalized absolute path string;
- **every** path a syscall takes goes through ONE ingress, `sc_path_take`, which copies it into the kernel and, when it
  is relative, resolves it against the caller's working directory;
- `chdir`#112 sets it, `getcwd`#113 reads it; a child inherits it, and a `spawn_path`#43 / `execwait`#37 child is
  **seeded** from a valid `PWD=` in the env it is given — so agnsh's children (agnsh exports `PWD`) start in agnsh's
  directory with no agnsh change.

## Prior art

| | Where the cwd lives | Relative lookup | `..` | Inheritance |
|---|---|---|---|---|
| **Linux** | `current->fs->pwd`, a `struct path` (vfsmount + dentry) in `struct fs_struct` (`include/linux/fs_struct.h`), under `fs->lock` / `fs->seq` | `path_init()` (`fs/namei.c`) starts at `fs->pwd` for `AT_FDCWD` | PHYSICAL: `follow_dotdot()` walks the dentry's parent, crossing mounts with `follow_up()` | `copy_fs()` (`kernel/fork.c`): shared under `CLONE_FS` (threads), else `copy_fs_struct()`; `execve` keeps it |
| **FreeBSD** | `struct pwd { pwd_cdir, pwd_rdir, pwd_jdir }` vnodes, in a refcounted `struct pwddesc` (`sys/sys/filedesc.h`, 13.0+) | `namei()` starts at `pwd_cdir` | physical, through the vnode | `pdcopy()` / `pdshare()` at `fork1()` |
| **Plan 9** | `up->dot`, a `Chan*` that carries its own name (`c->path`) | `namec()` starts at `dot` | the chan's NAME is cleaned LEXICALLY (`cleanname()`, `libc/port/cleanname.c`) — Plan 9 has binds and unions, no symlinks | `sysrfork`: `p->dot = up->dot; incref(p->dot)` |
| **seL4** | none: the kernel has no file system; a cwd is a user-level server's state | — | — | — |

`chdir(2)`: Linux `ksys_chdir()` (`fs/open.c`) is `user_path_at(LOOKUP_FOLLOW | LOOKUP_DIRECTORY)` → permission →
`set_fs_pwd()`; a non-directory is `ENOTDIR`, a missing path `ENOENT`, and nothing changes on failure. `getcwd(2)`:
`fs/d_path.c` builds the path from the dentry, `ERANGE` when the buffer is too small (never a cut name), `ENOENT` when
the cwd has been unlinked; the raw syscall returns the length INCLUDING the NUL. Path length: Linux `PATH_MAX` = 4096
including the NUL (`getname()` → `ENAMETOOLONG`); FreeBSD `MAXPATHLEN` = 1024. A shell keeps a LOGICAL `$PWD`: bash's
`cd` (`-L`, the default) cleans `..` lexically, and at startup bash keeps an inherited `$PWD` only when it names the
same directory as `.` (`set_working_directory`, `variables.c`). vidya `systems/filesystems` (the dentry/inode split,
`AT_FDCWD` relative opens).

## What agnos adopts, and where it departs

**Adopted:** a per-process cwd (Linux, FreeBSD, Plan 9); inheritance at every process birth and across exec (Linux
`copy_fs`, Plan 9 `sysrfork`); `chdir` refuses a missing path and a non-directory and changes nothing on failure,
following a final symlink (Linux `LOOKUP_FOLLOW | LOOKUP_DIRECTORY`); `getcwd` refuses a too-small buffer and never
truncates (`ERANGE`); `PATH_MAX` 4096 including the NUL; the kernel copies the path once (`getname()`); `execve`'s
rule for a relative program path — resolved from the cwd, **no `PATH` search** (that is `execvp`'s, in userland).

**Departures, and why:**

1. **A string, not a dentry.** agnos routes a path by its STRING, longest-prefix, across backends that share no
   inode space — ext2 at `/`, ZFS at `/mnt/zfs`, FAT at `/mnt/fat`, exFAT at `/mnt/exfat`, the `/fonts` intercept — and
   has no dentry cache to hold. So the cwd is Plan 9's model: a name. Relative resolution is `cwd + "/" + name`, then
   routed exactly like an absolute path. There is no reference held on the directory.
2. **`..` is LEXICAL in a relative join** (Plan 9's `cleanname`, a shell's logical `$PWD`): `path_clean_join` drops
   empty components and `.`, and `..` removes the component before it, never climbing above `/`. `..` from
   `/mnt/zfs/a` is `/mnt/zfs` and from `/mnt/zfs` is `/mnt` — ACROSS the mount boundary, which a string router needs
   (an inode `..` inside the pool would stop at its root). The cost, as for a shell's `cd -L`: after `chdir("/l")`
   where `/l -> /x/y`, `..` is `/`, where Linux's physical walk gives `/x`. `chdir` cleans an absolute target too (a
   cwd must be normalized), and keeps a symlink's path, not its target. **An absolute path given to any other call is
   copied verbatim** — its `.`/`..` are the backend's, as before (ext2's on-disk `..`, ZFS's canonical walk). That is
   the Linux + bash split: the shell's `cd` is logical, the kernel's absolute lookup is physical.
3. **A removed or renamed cwd.** Linux keeps the dentry: after `rmdir` of the cwd, relative lookups fail with
   `ENOENT` and `getcwd` answers `ENOENT`; after a rename the process follows the directory to its new name. agnos holds
   no reference, so: **removed** — every relative lookup fails cleanly (the string names nothing: `-1`), `getcwd` still
   answers the string (a pure read, no lookup), `chdir("..")` works lexically; **renamed** — relative lookups resolve
   the OLD name, which is missing (`-1`) or, if something new was made there, that new thing. A program that must
   detect it stats `.` (relative: resolves to the cwd) — `-1` means the directory is gone.
4. **Seeded from `PWD=`.** No mainstream kernel reads an environment. agnos does, at `#43`/`#37` only, because the
   shell that exists today (agnsh) tracks its own directory and exports `PWD`/`OLDPWD`, and the seed makes every one of
   its children right with no agnsh change. The rule is bash's startup rule, minus the identity check (there is no
   inode to compare with): an absolute, existing directory, else ignored.
5. **`getcwd` returns the length WITHOUT the NUL** (agnos's `(ptr, len)` convention, as `readlink`#70), and writes the
   NUL too; Linux's raw syscall counts the NUL.

## The rules

### Representation and storage

- A cwd is a **normalized absolute path**: starts with `/`, no empty / `.` / `..` component, no trailing `/` except
  `/` itself, no NUL byte, at most **`CWD_MAX` = 4095** bytes (so it and a NUL fit 4096).
- `proc_cwd_len[16]` (`.bss`, 128 B) per pid; **length 0 means `/`** — the reset state, and the only one a process
  that never chdirs has. `proc_cwd_buf` (ROOM slot 12, 16 × 4096 B = 64 KB) holds the bytes for a length > 0. Every
  read of the room is behind `len > 0`, which only a chdir, a seed or an inheritance copy produces, all long after
  `room_init`.
- **Reset at reuse:** `proc_alloc_slot` sets the new slot's length to 0 — a recycled pid never sees its last
  occupant's cwd. **Inheritance always stores the creator's length**, a root creator's 0 included, so the two defences
  are independent (the smoke's RECYCLE clause fails only when both are removed).

### The ingress — `sc_path_take(uptr, ulen, slot)`

- Validates (`sc_path_ok`: 1+ bytes, an owned user range — the page-table walk), refuses an INPUT over `CWD_MAX`,
  copies the path into this CPU's ingress slot (`sc_path_buf(slot)`), NUL-terminates it, and — when it is relative —
  writes `path_clean_join(cwd, rel)` there instead. Returns the length or -1. The arm then routes the KERNEL copy, so
  the backend reads exactly the bytes that were checked (one read of user memory, as `getname()`).
- **Never truncated:** an input over 4095 bytes, or a join whose result (or any prefix the walk builds) would pass
  4095, is `-1`. The 1.57.12 B6 rule ("a relative name of 255+ bytes is refused; it was truncated to 254 and
  created") is the same rule with the real bound: 254 was the old rooting buffer's size, not a path limit.
- **The arms that take a path, and only through here:** open#7, mkdir#9, rmdir#10, unlink#30, rename#31 (slot 0 and
  slot 1), link#32 (both), stat#33, symlink#63 (the LINK path — the TARGET is text and is stored verbatim, so a
  relative target stays relative to the link's directory when followed, as on Linux), readlink#70, readdir#81 and
  readdir_at#101 (through `sc_cpath_take`, their NUL-terminated form in a 256-byte window — a window without a NUL is
  now -1, where the backend's strlen used to stop at 255 and list what the first 255 bytes named), lstat#102,
  statfs#103, chdir#112, and the PROGRAM path of spawn_path#43 / execwait#37 (`spawn_load_child`, which joins it into
  slot 0 itself: the path token is inside the staged line). No other syscall takes a path: mount#11 / umount#24 are
  argument-less stubs, exec_redirect#62 and flock#59 take fds, mountlist#104 none.
- **The initrd fallback** (open#7 with no root mount at all) still gets the caller's raw name: initrd names are flat.
- **Per-CPU, two slots** (ROOM slot 13, 4 × 2 × 4096 B): the arms run IF=0 outside `fs_lock` until their backend
  arm, so two CPUs are in them at once (the 1.56.51 `pcpu_sc_open_abs` lesson); rename / link hold two paths. R4/R6
  apply: no `wq_*` call inside a slot's live span (`blocking-waits.md`). The smoke's CONCURRENT clause (three
  processes, three cwds, relative reads at once, `-smp 4` under KVM) goes red when the slots are shared.

### `chdir`#112(path, len) → 0 / −1

The cleaned absolute form of `path` (a relative one joined to the current cwd) becomes the cwd when it names an
existing **directory** on whatever owns it (`sc_path_is_dir`, under `fs_lock`: ext2 — the inode mode; ZFS —
`zfs_stat`; FAT — the dirent's `ATTR_DIRECTORY`; exFAT — the set's FileAttributes; a mount root is one; `/` always
is). A final symlink is followed for the check and the LINK's path is stored. −1, nothing changed: a bad range, an
empty path, a NUL byte, over `CWD_MAX` (input or result), missing, not a directory. The check and the store run on the
caller's CPU, and only the caller writes its own cwd, so nothing can change it between them.

### `getcwd`#113(buf, cap) → length / −1

Copies the cwd and a NUL; returns its length L (the NUL not counted). `cap < L + 1` is −1 with **nothing written**.
Only the `L + 1` bytes written are validated. A pure read — no lookup, no lock.

### Inheritance and the `PWD=` seed

- `proc_create_user` (spawn#3, spawn_path#43, execwait#37, every kernel load) and `sys_fork` copy the creator's cwd
  into the child while it is CLAIMING. The first process (kybernet's agnsh, loaded by kmain), every kernel thread and
  idle start at `/` (kmain's cwd is `/`; a kthread's slot is reset and never inherits).
- **#43 / #37 then seed** (`spawn_seed_cwd`, before READY): the FIRST `PWD=` entry of the env blob, when its value is
  absolute, cleans to ≤ 4095 bytes and names an existing directory, becomes the child's cwd. **Precedence: a valid
  `PWD=` > the creator's cwd.** An invalid one — relative, empty, too long, missing, a file — is **ignored**: the child
  keeps the creator's cwd, and its env still carries the bogus text untouched (the kernel never rewrites an env).
- **The default env** (a #43/#37/kernel load with no env blob) says `PWD=<the cwd the child is born with>` — the
  creator's — `PWD=/` byte-identically for a creator at `/`. Until 1.57.18 it said `PWD=/` always, which would send a
  `$PWD`-resolving program to the wrong file once the cwd is not `/`. A cwd too long for the init stack's string
  region omits the variable (never cuts it).

### SMP and locking

pid p's cwd is written only (a) by p itself (chdir, on the one CPU running it), (b) by p's creator while p is CLAIMING
(never scheduled yet — inheritance, the seed), (c) by `proc_alloc_slot` handing the slot out. It is read only by p
itself and by p's creator while p is CLAIMING. The READY publish orders the creator's stores before the first CPU that
runs p reads them (x86-TSO; the picker takes `sched_lock`). agnos has no threads sharing an address space, so there is
no `CLONE_FS` case. **No third-party reader exists**; one (a `/proc`-like enumeration) must take a seqcount, as Linux
`fs_struct->seq` does, because a length and its bytes are not one atomic store.

## Limits stated

- The PROGRAM path of #43/#37 keeps the loader's 255-byte cap (`vfs_file_size` / `vfs_read_file_at`'s
  `vfs_sec_name_ok`), now of the RESOLVED path; a longer one is `-SPAWN_E_ARGS`, never cut.
- ZFS resolves at most 1023 bytes of a mount-relative path (`zfs_resolve`), FAT/exFAT names 255: those backends refuse
  a longer resolved path themselves (`-1`).
- `getcwd` does not report a removed cwd (Linux `ENOENT`); `stat(".")` does.
