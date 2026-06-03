# AGNOS Userland↔Kernel Syscall ABI — Contract

> **The canonical source is `kernel/core/syscall.cyr` (the `ksyscall` dispatch) in this repo.** This doc is the
> interface both sides code against: the agnos kernel *implements* it; the Cyrius `CYRIUS_TARGET_AGNOS`
> stdlib peer (`lib/syscalls_x86_64_agnos.cyr`) *mirrors* it. **One drifts → silent wrong-syscall** (the exact
> failure the cyrius per-arch `syscalls.cyr` split was created to prevent). When the two disagree, the kernel
> wins and this doc is corrected to match it.
>
> **A row is only 🔒 FROZEN once it's IMPLEMENTED in the kernel.** A *decided spec* that isn't built yet is
> ✅ DECIDED, not frozen — the cyrius peer can mirror a DECIDED row, but it can change until the kernel lands it
> (then it freezes). You cannot freeze an ABI that still has open decisions — so the design decisions
> (the 4th-arg register, stdin discipline, dir-fds, FAT degradation) are **settled in §0 below** before any
> 1.41.x code is written.
>
> **Status legend**: 🔒 FROZEN (implemented + live in the kernel — mirror exactly, won't change) · ✅ DECIDED
> (spec agreed, **not yet implemented** — mirror-able, freezes when the kernel lands it) · 🔧 STUB (number
> reserved, returns a constant — see notes) · 🩺 DIAGNOSTIC (kernel-internal; not part of the userland shell surface).
>
> **Decision log**: O1–O4 settled **2026-05-31 (agnos-side)** — see §0. The 1.41.x surface (§3) is ✅ DECIDED;
> each row moves to 🔒 FROZEN as 1.41.1/1.41.3 implement it.
>
> Companion: agnosticos [`shell-separation-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/shell-separation-prior-art.md)
> (why this ABI is needed — the boundary audit) · [`roadmap.md`](roadmap.md) § *1.41.x — Shell Separation Arc*.

## 0. Decisions (settled 2026-05-31, agnos-side)

These were open questions; they're now decided so the cyrius peer has a real target. Recorded here, applied
throughout the doc below.

| # | Decision | Rationale |
|---|----------|-----------|
| **O2** | **`a4 = r10`** — the syscall ABI grows from 3 args to 4; the 4th is in `r10`. | `rename(old,oldlen,new,newlen)` is inherently 4-arg. `r10` is the natural 4th-arg register (SYSCALL clobbers `rcx`, which is exactly why Linux picked `r10` — we adopt the *register*, not their numbers). Additive; entry stub saves `r10`, `syscall_handler`/`ksyscall` gain `a4`. Lands with 1.41.3. |
| **O1** | **stdin = RAW** — `read(fd=0)` returns raw bytes, blocks until ≥1, **no kernel echo**. | `agnsh` ships its own `completion.cyr` + `history.cyr` line-editing — it needs raw keystrokes; cooked mode would fight its line editor. agnsh echoes. The in-kernel *emergency* shell keeps its own cooked loop (reads the keyboard directly, not via stdin). |
| **O3** | **`open(AO_DIRECTORY)` returns a normal fd** that `getdents` (29) consumes. | Reuse the `vfs_table` slot model + a dir tag — matches the existing fd plumbing; no separate dir-handle type. |
| **O4** | **FAT/exFAT `stat`/`link` degrade gracefully.** `stat` fills `st_ino=0` + size/type from the dirent; `link` is ext2-only (returns -1 on FAT). | Inherent — FAT has no inodes or hard links. `ls -l` on FAT shows size/type, ino 0. |

## 1. Calling convention (x86-64)

From `kernel/arch/x86_64/syscall_hw.cyr`:

| Register | Role |
|----------|------|
| `rax` | syscall number (in) / return value (out) |
| `rdi` | arg1 (a1) |
| `rsi` | arg2 (a2) |
| `rdx` | arg3 (a3) |
| `rcx` | **clobbered** by `SYSCALL` (holds return RIP) — do not pass args here |
| `r11` | **clobbered** by `SYSCALL` (holds return RFLAGS) |

- **Instruction**: `syscall` (AMD64 SYSCALL/SYSRET). Entry stub at `LSTAR`; `STAR` sets kernel CS `0x08`,
  user CS base `0x10` (SYSRET returns CS `0x20|3`, SS `0x18|3`). `SFMASK` masks IF → **interrupts are off
  inside the kernel during a syscall** (a blocking syscall that must wait re-enables them itself — see §5 stdin).
- **Arg count is 3 today** (`a1`/`a2`/`a3` = `rdi`/`rsi`/`rdx`). The kernel dispatcher is
  `ksyscall(num, a1, a2, a3)`.
- **Return convention**: `rax` ≥ 0 on success (fd / byte count / pid / value), **`-1` (`0 - 1`) on error**.
  AGNOS does **not** use Linux `-errno`. Some void-success calls return `0`. (A richer error channel is a
  future option; today it's `-1`.)
- **Unknown syscall number → `-1`.**
- **User-pointer rule**: every userspace buffer pointer must be **≥ `0x200000`** (the kernel reserves
  `0–2 MB`). The kernel validates with `is_user_ptr(p)` (`p ≥ 0x200000`) and `is_user_range(p, len)`
  (`p ≥ 0x200000` ∧ no `p+len` overflow). A pointer below `0x200000` → the call returns `-1`.
- **Process exit epilogue**: a static binary's `main()` returns into a `syscall(0, exit_code)` (agnos `exit`).
  Note this is **agnos exit = 0**, *not* Linux `exit_group`/`60` — the Cyrius `CYRIUS_TARGET_AGNOS` runtime
  `_start`/`exit` shim must use agnos numbers, not the Linux `syscall(60, …)` epilogue.

### 1a. ✅ DECIDED (O2) — 4th argument (`a4` = `r10`)

`rename(old, oldlen, new, newlen)` needs **four** arguments, which the original 3-arg ABI couldn't carry.
**Decision: `a4 = r10`** — `r10` is the natural 4th-arg register (SYSCALL clobbers `rcx`, which is exactly why
Linux uses `r10`; agnos adopts the *register*, not Linux's numbers). Additive kernel change (the entry stub
saves `r10`, `syscall_handler`/`ksyscall` gain `a4`); lands with 1.41.3. Rejected alternatives: NUL-terminated
names (breaks the explicit-length invariant every agnos syscall holds); a packed args-struct pointer (extra
indirection for one call). **The cyrius peer's agnos syscall wrappers pass the 4th arg in `r10`.**

## 2. 🔒 FROZEN syscall table (0–28, live today)

`a1/a2/a3` columns give the argument meaning; `→` is the return. "shell" marks calls the userland `agnsh`
will use; "🩺" marks kernel-diagnostic-only.

| # | Name | a1 | a2 | a3 | → | Notes |
|---|------|----|----|----|---|-------|
| 0 | `exit` | code | — | — | (no return) | sets exit code, resumes kernel via `kernel_resume`. **shell** |
| 1 | `write` | fd | buf | len | bytes / -1 | `vfs_write`; fd 1/2 → console. **shell** |
| 2 | `getpid` | — | — | — | pid | returns `proc_current`. **shell** |
| 3 | `spawn` | elf_addr | elf_size | — | pid / -1 | loads an **in-memory** ELF (not a path). See §5 exec note. |
| 4 | `waitpid` | pid | — | — | exit_code / -1 | busy-waits until `state==0`. **shell** |
| 5 | `read` | fd | buf | len | bytes / -1 | `vfs_read`. **fd 0 = stdin** — see §5 (currently → serial; 1.41.1 makes it the keyboard). **shell** |
| 6 | `close` | fd | — | — | 0 / -1 | `vfs_close`. **shell** |
| 7 | `open` | name | namelen | — | fd / -1 | **currently `initrd_open` ONLY** (can't reach the agnos-fs). 1.41.3 re-routes — see §5. **shell** |
| 8 | `dup` | fd | — | — | fd | 🔧 stub: returns `a1` unchanged. |
| 9 | `mkdir` | path | pathlen | — | 0 | 🔧 stub → 0. 1.41.3 makes it real. **shell** |
| 10 | `rmdir` | path | pathlen | — | 0 | 🔧 stub → 0. 1.41.3 makes it real. **shell** |
| 11 | `mount` | — | — | — | 0 | 🔧 stub (no-op). |
| 12 | `sync` | — | — | — | 0 | 🔧 stub → 0. 1.41.3 wires to `vfs_sync`. **shell** |
| 13 | `reboot` | — | — | — | (halts) | `serial_println` + `arch_halt`. **shell** (`halt`) |
| 14 | `pause` | — | — | — | 0 | `arch_wait` (one hlt). |
| 15 | `getuid` | — | — | — | 0 | 🔧 stub (always root=0). |
| 16 | `kill` | pid | sig | — | 0 / -1 | `proc_send_signal`; pid 0 protected, self/child only. |
| 17 | `sigprocmask` | how | set_ptr | oldset_ptr | 0 / -1 | how: 0=BLOCK, 1=UNBLOCK. ptrs ≥ 0x200000. |
| 18 | `signalfd` | fd | mask_ptr | flags | fd / -1 | allocates a `VFS_SIGNALFD`. |
| 19 | `epoll_create` | — | — | — | fd / -1 | allocates a `VFS_EPOLL` (8-watch list). |
| 20 | `epoll_ctl` | epfd | op | fd | 0 / -1 | op: 1=ADD, 2=clear. max 8 watches. |
| 21 | `epoll_wait` | epfd | events_ptr | max | nready | event rec = `{u32 mask; u64 data}` @ 12 B stride; `max`≤16; hlt if none ready. |
| 22 | `timerfd_create` | — | — | — | fd / -1 | allocates a `VFS_TIMERFD`. |
| 23 | `timerfd_settime` | fd | flags | val_ptr | 0 / -1 | `val_ptr`→`{u64 interval_sec; _; u64 initial_sec}` (24 B); ticks = sec×100. |
| 24 | `umount` | — | — | — | 0 | 🔧 stub → 0. |
| 25 | `pipe` | fds_ptr | — | — | 0 / -1 | writes 2× u64 fds at `fds_ptr` (16 B, ≥0x200000). `vfs_create_pipe`. |
| 26 | `write_boot_checkpoint` | byte | — | — | 0 | 🩺 writes `CMOS[0x50]=byte&0xFF` (iron-boot progress marker). |
| 27 | `mmap` | length | — | — | base_vaddr / 0 | anonymous, zero-filled, **2 MB-granular**; `0` = MAP_FAILED. |
| 28 | `munmap` | addr | length | — | 0 / -1 | frees an mmap region (2 MB-granular, LIFO vaddr reclaim). |

**Notes for the cyrius peer**: `epoll`/`signalfd`/`timerfd`/`sigprocmask`/`pipe` pass small fixed-layout
structs through user pointers — mirror the exact byte offsets above (they're agnos-native, **not** the Linux
`struct epoll_event`/`itimerspec` layouts). `dup`/`getuid`/`mount`/`umount` are stubs — the peer may expose
them but must not rely on real behavior.

## 3. ✅ DECIDED — 1.41.x additions + changes (not yet implemented; the shell-separation surface)

These are the agnos-side bites (1.41.1 stdin, 1.41.3 FS). The spec is **decided** (§0 settled O1–O4) and
mirror-able; both agents code to it, and each row **moves to 🔒 FROZEN (update §2) as the kernel lands it**.

### 3.1 Changed behavior (same numbers)

- **🔒 `read`(5) on `fd 0` → blocking keyboard stdin** (**IMPLEMENTED 1.41.1** — `kbd_read_blocking`). When
  `fd==0`, the kernel blocks until at least one real character is typed, drains any further buffered keys (up
  to `len`), and returns the count. **Line discipline = RAW (O1)** — no kernel echo; agnsh does its own echo +
  editing via `completion.cyr`/`history.cyr`. Mechanism: busy-polls `kb_has_key()` → `hid_poll()` (a
  cooperative MMIO drain of the xHCI HID transfer ring), so it works with **interrupts MASKED** (SFMASK clears
  IF on entry) — no `sti`, no `hlt`, no scheduler preemption mid-syscall. (Power follow-on: a `sti`+`hlt`
  idle-wait needs the preemptive-ring-3 arc; until then a blocked read spins one core.) Other fds keep the
  `vfs_read` path.
- **`open`(7) → mount-routed** (1.41.3). Re-route from `initrd_open`-only to `vfs_resolve_mount` →
  `ext2_open` (inode-wise) or `vfs_open_on` (FAT/exFAT), with `initrd` as the bare-name fallback. **Gains a
  flags arg** (a3) — see 3.3. Opening a **directory** returns a dir-fd usable by `getdents` (29).
- **`mkdir`(9) / `rmdir`(10) / `sync`(12) → real** (1.41.3): wire to `vfs_mkdir_on`/`vfs_rmdir_on` (mount-routed)
  and `vfs_sync`. Signatures unchanged (`mkdir`/`rmdir` take `path`,`pathlen`; `sync` takes none).

### 3.2 New syscalls (numbers assigned from the next free slots, 29+)

| # | Name | a1 | a2 | a3 | a4 | → | Semantics |
|---|------|----|----|----|----|---|-----------|
| 29 | `getdents` | dir_fd | buf | bufsize | — | bytes / 0 (end) / -1 | fills `buf` with packed dirent records (§4.2) up to `bufsize`; returns bytes written, `0` at end of dir. dir_fd from `open` on a directory. **shell** (`ls`) |
| 30 | `unlink` | path | pathlen | — | — | 0 / -1 | remove a file (mount-routed `vfs_delete_on`/`ext2` unlink). **shell** (`rm`) |
| 31 | `rename` | old | oldlen | new | newlen | 0 / -1 | rename within one filesystem (uses **a4** — §1a). **shell** (`mv`) |
| 32 | `link` | target | targetlen | linkpath | linkpathlen | 0 / -1 | hard link (a4); ext2 only initially. **shell** (`ln`) |
| 33 | `stat` | path | pathlen | statbuf | — | 0 / -1 | fills `statbuf` (§4.1, ≥0x200000) with the agnos stat struct. **shell** (`ls -l`, type) |

`create` is **not** a separate syscall — file creation is `open(7)` with the `AO_CREAT` flag (§3.3),
subsuming `touch` (CREAT) and `echo >` (CREAT|TRUNC). `chdir`/`getcwd` are **not** in the ABI: **CWD is
userland-owned** — `agnsh` tracks its own CWD and passes **absolute paths** to every syscall.

### 3.3 ✅ `open` flags (a3) — agnos-native bits

Access mode in the low 2 bits; modifiers above. **These are AGNOS values, not Linux's** (don't copy
`O_CREAT=0x40` etc. — the peer defines `AO_*` to match this table):

| Flag | Value | Meaning |
|------|-------|---------|
| `AO_RDONLY` | `0x0` | read only (default) |
| `AO_WRONLY` | `0x1` | write only |
| `AO_RDWR` | `0x2` | read+write |
| `AO_CREAT` | `0x100` | create if absent (subsumes `touch`) |
| `AO_TRUNC` | `0x200` | truncate to zero on open (with CREAT = `echo >`) |
| `AO_APPEND` | `0x400` | seek to end on each write |
| `AO_DIRECTORY` | `0x800` | must be a directory (for `getdents`) |

## 4. ✅ Struct layouts (agnos-native — mirror exactly)

### 4.1 `stat` struct (48 bytes, 8-byte fields)

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| 0 | `st_mode` | u64 | POSIX-style type+perm bits (`0x8000`=file, `0x4000`=dir, `0xA000`=symlink in the top nibble — the kernel already speaks these via `ext2_inode_mode`) |
| 8 | `st_nlink` | u64 | hard-link count |
| 16 | `st_size` | u64 | size in bytes |
| 24 | `st_ino` | u64 | inode number (ext2) / 0 for FAT/exFAT |
| 32 | `st_blocks` | u64 | 512-byte block count |
| 40 | `st_mtime` | u64 | unix mtime (0 if unknown) |

Kept minimal + 8-byte-aligned (no packed sub-word fields → no Cyrius struct-padding ambiguity). Reuses POSIX
`st_mode` top-nibble because the kernel's inode layer already uses it; everything else is agnos's own.

### 4.2 `getdents` record (variable length, reclen-delimited)

Packed records back-to-back in the caller's `buf`; advance by `reclen`:

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| 0 | `reclen` | u16 | total record length incl. name + padding (next record starts here) |
| 2 | `type` | u8 | 1=file, 2=dir, 3=symlink, 0=unknown |
| 3 | `namelen` | u8 | name byte length (≤255) |
| 4 | `ino` | u32 | inode (ext2) / 0 |
| 8 | `name[namelen]` | bytes | **not** NUL-terminated; `namelen` is authoritative |
| 8+namelen | pad | — | to the next 8-byte boundary; `reclen` accounts for it |

Compact + 8-byte-record-aligned. Agnos-native (not Linux `dirent64`'s `d_off`/19-byte header).

## 5. Coordination protocol (two-agent)

1. **agnos lands the agnos-side** (1.41.1 stdin → 1.41.3 FS surface), implementing §3 and moving each entry
   to 🔒 in §2 as it ships.
2. **cyrius builds `CYRIUS_TARGET_AGNOS`** (`lib/syscalls_x86_64_agnos.cyr` + the `PP_PREDEFINE` target macro)
   mirroring **this doc** — numbers, the 3→4 arg convention (§1a), the `AO_*` flags (§3.3), and the struct
   layouts (§4). The runtime `_start`/`exit` shim uses agnos `exit`=0, not Linux `60`.
3. **Re-freeze on every change**: whoever changes a number/signature/layout updates §2/§3/§4 here in the same
   change. The kernel is canonical; the doc tracks it; the peer tracks the doc.

## 6. Decisions (resolved — see §0)

O1 (stdin RAW), O2 (`a4 = r10`), O3 (`open(AO_DIRECTORY)` → normal fd), O4 (FAT `stat`/`link` degradation)
were all **settled 2026-05-31 (agnos-side)** and are recorded in **§0** + applied in §1a/§3. No open ABI
decisions remain; the 1.41.x surface is ✅ DECIDED and freezes per-syscall as 1.41.1/1.41.3 implement it.
New questions get appended here until decided, then moved to §0.
