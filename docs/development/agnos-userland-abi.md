# AGNOS Userland↔Kernel Syscall ABI — Contract

> **⚠ OPEN cyrius-side blocker (2026-06-03):** the *syscall* peer (`lib/syscalls_x86_64_agnos.cyr`)
> is complete + verified, but the higher-level cyrius stdlib modules **`lib/args.cyr` and
> `lib/io.cyr` have no `CYRIUS_TARGET_AGNOS` branch** — so `agnsh`'s startup `args_init()` hits a
> `ud2` → `#UD` in ring 3 and boot-to-agnsh (1.41.4) can't complete. The kernel exec path is
> proven correct. Full diagnosis + fix direction:
> [`issues/2026-06-03-cyrius-agnos-stdlib-args-io-gap.md`](issues/2026-06-03-cyrius-agnos-stdlib-args-io-gap.md).
>
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
| **O1** | **stdin = canonical-lite** — `read(fd=0)` blocks until Enter, **echoes** printable bytes + handles backspace, returns the line incl. its trailing `\n`. *(Revised 1.41.15; originally RAW + no-echo.)* | RAW was settled assuming the QEMU `hid_poll` model (polled, IF-independent). On **iron** keystrokes arrive only via IRQ1 and ring 3 runs **IF=0 between syscalls** (`ring3.cyr` sets RFLAGS=0x002), so RAW byte-by-byte is *structurally impossible* — any scancode arriving while `agnsh` is in userland is lost (the `14114` "Command: D" stuck-shift collapse). A continuous-IF whole-line read is the only shape that types on iron, and once the read is line-buffered echo must be kernel-side (the shell can't see chars until the line completes) — so the kernel mirrors the proven in-kernel recovery shell's echo loop. A richer `agnsh` line editor (`completion.cyr`) that needs raw keystrokes returns when the future multithreading arc lets ring 3 run IF=1 + safe preemption; O1 reverts to RAW then. Observable syscall numbers unchanged → no cyrius peer change. |
| **O3** | **`open(AO_DIRECTORY)` returns a normal fd** that `getdents` (29) consumes. | Reuse the `vfs_table` slot model + a dir tag — matches the existing fd plumbing; no separate dir-handle type. |
| **O4** | **FAT/exFAT `stat`/`link` degrade gracefully.** `stat` fills `st_ino=0` + size/type from the dirent; `link` is ext2-only (returns -1 on FAT). | Inherent — FAT has no inodes or hard links. `ls -l` on FAT shows size/type, ino 0. |
| **O5** | **The number space deliberately overlaps Linux's — consumers MUST use the cyrius `sys_*` wrappers, never a raw Linux syscall number.** | AGNOS's compact `0–55` surface reuses numbers that mean something *different* in the Linux x86-64 ABI (we adopt their *register* convention, not their numbers — see O2). A raw, unguarded `syscall(<linux-number>, …)` in stdlib does **not** fail to compile on AGNOS — it **silently mis-dispatches**: Linux `read`#0 = AGNOS `exit` (the process *terminates*); `socket`#41 = `sleep_ms`; `shutdown`#48 = `sock_send`; `setsockopt`#54 = `udp_unbind`; `getsockopt`#55 = `icmp_echo` (blocks ~3 s); `poll`#7 = `open`. This is structural, not a per-module bug — any future stdlib code hand-rolling a Linux number is a latent landmine. cyrius **6.2.7**'s stdlib-completeness pass routes all socket/io through the portable `sys_*` wrappers + the tagged-fd socket adapter and fail-closes the rest, so nothing mis-dispatches today. Full mis-dispatch table + the missing-call inventory: [`issues/2026-06-15-cyrius-stdlib-missing-syscalls.md`](issues/2026-06-15-cyrius-stdlib-missing-syscalls.md). |

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
| 1 | `write` | fd | buf | len | bytes / -1 | `vfs_write`; fd 1/2 → console. ⛔ **ON A PIPE fd THIS IS A SHORT WRITE, AND THE RETRY IS THE CALLER'S OBLIGATION** (*ipc bites 10/11*, 1.56.39-40): the ring is `PIPE_RING` = 4080 bytes, and `pipe_write` stops at `(write_head - read_tail) >= PIPE_RING` rather than wrapping and overwriting as it did before. A caller that writes `len` and assumes `len` was taken **silently loses the tail**. Loop on the returned count. This contract was not written down here until 1.56.54, while the kernel had behaved this way since 1.56.40. **shell** |
| 2 | `getpid` | — | — | — | pid | returns `proc_current`. **shell** |
| 3 | `spawn` | elf_addr | elf_size | — | pid / -1 | loads an **in-memory** ELF (not a path). See §5 exec note. |
| 4 | `waitpid` | pid | — | — | exit_code / -2 / -1 | ⛔ **NON-BLOCKING POLL, THREE-VALUED — this row said "busy-waits until `state==0`" and a two-valued return until 1.56.55, and both halves were wrong.** It does not block: it returns the child's `exit_code` if the child is dead, **-2 (WOULD_BLOCK)** if it is still alive, and **-1** if `pid` is out of range, is the caller itself, or is not the caller's child (`proc_may_reap` — only the parent, or init as the orphan reaper). A real blocking wait needs per-proc kernel stacks first (the shared syscall stack means another syscall would clobber a blocked-in-kernel frame), so the caller spins. ⭐ **`pid < 0` IS WAIT-ANY** (1.56.54): scan for any dead child of the caller, reap the LOWEST, return its code; **-2** while children live, **-1** when there are none. That `-2`/`-1` split is the contract every fork-model server loop depends on, and `#96 fork` was blocked on it. ⚠ **A reaped child stops being a child** (1.56.55) — both reap doors clear `proc_ppid`, so a second wait-any never re-matches an already-collected row. Before that fix the parent re-reaped the same non-top slot forever and never saw its other children. **shell, `tests/fork/forker.cyr`** |
| 5 | `read` | fd | buf | len | bytes / **-1** / **-2** | `vfs_read`. **fd 0 = stdin** — see §5 (currently → serial; 1.41.1 makes it the keyboard). ⛔ **ON A PIPE fd, AN EMPTY RING RETURNS `-2` (WOULD_BLOCK) WHILE ANY WRITER IS STILL OPEN, AND `0` ONLY ONCE EVERY WRITER HAS CLOSED** (*ipc bites 10/11*, 1.56.39-40). That split is what lets a reader tell **"nothing yet"** from **"end of stream"**; before it, a consumer that out-ran its producer read 0 and quit early. `-2` is the kernel's established WOULD_BLOCK value, shared with the channel band and the cooked-line read. ⚠ **A reader that treats every non-positive return as EOF terminates early; one that treats `-2` as fatal fails a healthy pipe.** ⚠ **The writer MUST close** — an unclosed write end means the reader never sees 0 and can spin forever. This row said `bytes / -1` until 1.56.54, four cuts after the kernel changed. **shell** |
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
| 25 | `pipe` | fds_ptr | — | — | 0 / -1 | writes 2× u64 fds at `fds_ptr` (16 B, ≥0x200000). `vfs_create_pipe`. ⛔ **STREAMING SINCE 1.56.39-40, NOT STORE-AND-FORWARD.** The ring is **4080 bytes** (`PIPE_RING`) and is no longer wrap-and-overwrite: a full ring **short-writes** (see #1) and an empty one returns **`-2`** while a writer is open (see #5). ⇒ Producer and consumer may now run CONCURRENTLY, which is the point of the change — but the caller owes two things it did not owe before: **retry on a short write**, and **close the write end** so the reader can reach EOF. |
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

- **🔒 `read`(5) on `fd 0` → blocking keyboard stdin** (**IMPLEMENTED 1.41.1**; **IRQ1 mechanism corrected
  1.41.14**; **line discipline + echo 1.41.15**). When `fd==0`, the kernel blocks until **Enter**, drains the
  whole line under one continuous interrupt-enabled window, and returns the bytes incl. the trailing `\n` (or a
  short line if the caller's `len` fills first). **Line discipline = canonical-lite (O1, revised 1.41.15)** —
  the kernel **echoes** printable bytes via `kputc` (serial + GOP framebuffer), handles **backspace** as
  `BS SP BS`, and terminates on newline; `kb_shift`/`kb_ctrl` are reset on entry. This is the in-kernel recovery
  shell's input loop, lifted into the syscall. **Mechanism**: `sti` for the whole-line read so the **IRQ1
  handler (`kb_isr`) fills `kb_buf`** — the keystroke producer on real hardware. Holding IF=1 across the entire
  line (not per-byte) is the load-bearing change: every make/break is processed in-window, so a shift-release is
  never stranded across the ring-3 IF=0 gap (`ring3.cyr` enters ring 3 with RFLAGS=0x002; SYSRET restores it).
  The 1.41.14 per-byte read returned after the first char, and that IF=0 inter-byte gap dropped shift-release
  breaks → `kb_shift` latched → `d`→`D`, every line collapsing to a single stuck char (the `14114` "Command: D"
  burn). Preemption is suspended (`sched_active=0`) around the window so the timer ISR can't context-switch the
  non-reentrant syscall (it still EOIs + advances `timer_ticks`). `kb_has_key()` additionally drains the xHCI
  HID ring via `hid_poll()` — the QEMU producer. Busy-poll, no `hlt`, so a blocked read spins one core
  (single-foreground model). **NB — observable syscall numbers/arg-passing are unchanged (the *line discipline*
  changed, not the call shape), so the cyrius peer is unaffected.** *(History: the original 1.41.1 spec polled
  `hid_poll()` with IF MASKED — QEMU-only; 1.41.14 fixed that to IRQ1+`sti`; 1.41.15 made it whole-line +
  echoed after the `14114` stuck-shift collapse.)* Other fds keep the `vfs_read` path.
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
| 34 | `uname` | buf | len (≥64) | — | — | 0 / -1 | writes the 64-byte identity struct (§4.3) into `buf`: sysname/nodename/release/machine. Static boot-time identity. **mihi/iam** (1.42.10) |
| 35 | `sysinfo` | buf | len (≥40) | — | — | 0 / -1 | writes the 40-byte counters struct (§4.4) into `buf`: uptime_secs / total+free RAM bytes / procs / cpus. Live snapshot; kernel does the unit conversion. **mihi/iam/chakshu** (1.42.10) ⭐ **EXTENDED AT +40 (1.56.59, telemetry §8): per-core CPU accounting**, behind a bumped minimum length of **104**. Layout `+40 + cpu*16 + 0` = **USER** ticks, `+40 + cpu*16 + 8` = **KERNEL** ticks, 4 CPUs, 100 Hz. Split by the **privilege of the interrupted context** in the timer ISR (read the CS the hardware frame saved at frame+128, test the RPL) — Linux's `%us`/`%sy`, exact rather than sampled. Monotonic since boot, never reset. ⛔ **A caller passing len=40 is BYTE-IDENTICAL to before** — the larger range is validated only when the caller asked for it, so a 40-byte caller cannot get a spurious -1. That is what makes this an append rather than an ABI break; preserve it. ⭐ **APPENDED RATHER THAN MINTED, deliberately.** This was first built as `cpustat`#106 and moved here: a new number is a cross-repo ask on the cyrius peer — a language-agent cycle, a cyrius release, and a re-pin of every sibling wanting one toolchain version. reaching the tail needs a raw `syscall(35, buf, 104)` today — the peer `fn sys_sysinfo(out)` hardcodes 40, so a wrapper consumer needs a length-taking overload upstream (**number-free**, no ABI-gate row, but not nothing). See §4.4. ⛔⛔ **NO `idle` FIELD, AND THAT IS THE HONEST ANSWER.** `arch_wait()` (a bare `hlt`) is called from ~a dozen polling waits, so a CPU halted in a blocking syscall is indistinguishable at the tick boundary from one doing kernel work — both are ring 0. The kernel field is **"system + halted"**, not "busy-system"; compute `user/(user+kernel)`. |
| 36 | `klug` | buf | len | — | — | bytes / -1 | copies the unified **klug** kernel-log ring (§4.5) into `buf`, oldest→newest; when `len` < the log fill, returns the **newest** `len` bytes (dmesg tail). Returns bytes written. **klug/dmesg tool** (1.42.12) |
| 37 | `execwait` | path | pathlen | env blob (opt, 1.44.19) | env len (a4=r10) | child exit code / -1 | loads a static ELF64 from the ext2 root, runs it to completion **in ring 3**, returns the child's exit code. Synchronous `elf_load_from_file` + `exec_and_wait` (no preemption); the FIRST such exec from a live ring-3 syscall frame, so the handler preserves the caller's resume context (H1) + runs the child on a disjoint second SYSCALL kstack (H2). `execwait` passes only the program path (no caller-supplied argv); the kernel stages a uniform default envp (`HOME=/`, `PWD=/`) on every exec as of **1.43.2** — see §4.6. **agnsh `run`** (1.43.0) |
| 38 | `fbinfo` | buf | len (≥24) | — | — | 0 / -1 | writes the 24-byte framebuffer geometry struct (width / height / pitch / bpp / fmt) into `buf`. The ring-3 query before a `blit`. **cyrius-doom / fbtest** (1.43.4) |
| 39 | `blit` | src | w | h | dstxy `+`scale `+`defer | 0 / -1 | copies a `w`×`h` block of 32bpp pixels from `src` (packed `w*4`/row) to the framebuffer at (dx,dy); `a4` = `(defer[40]<<40)\|(scale[39:32]<<32)\|(dy[31:16]<<16)\|dx[15:0]`. `scale` 0/1 = 1:1 (byte-identical), ≥2 = integer block scale via a 32 KB src-major rowbuf; dst rect clipped to FB. Memory-safety gate `w*scale ≤ 8192`; `scale > 16` rejects. **`defer` (a4 bit40, P7 1.55.x):** 0 = auto-present after the blit (every existing caller, byte-identical); 1 = blit into the back buffer but DON'T flip — a compositor accumulates windows across many deferred blits, then calls `present`#84 once. THE ring-3 FB path (`fb_phys` stays unexposed). **cyrius-doom** (1.43.4; scale 1.44.20; defer 1.55.x) |
| 84 | `gpu_present` | — | — | — | — | 1 / 0 | **P7 (1.55.x)** — flip the accumulated double-buffer back buffer to the scanout, tear-free + vsync-paced. The explicit half of the blit/present split (pairs with `blit`#39's `defer` bit): a compositor blits its windows deferred, then calls this ONCE to show the frame. `1` = presented; `0` = nothing to present (double-buffer not armed / direct-FB path — the deferred blits already hit the live FB). **aethersafha** |
| 85 | `gpu_fill` | color | — | — | — | 0 / -1 | **P9 (1.55.x)** — GPU-clear the blit back-buffer to a 32-bit xRGB8888 `color` via a **CP-DMA** fill (a PM4 `DMA_DATA` constant-fill on the compute ring — offloads a full-screen clear off the CPU); pairs with `present`#84 to show it. `0` = filled; `-1` = no usable display (QEMU / no pipe) or the fill failed. Ring-3 names only the color — the kernel targets the back buffer, so no MC address crosses the boundary (same discipline as `blit`#39). Arms the double-buffer lazily. **aethersafha / compositor clears** |
| 82 | `gpu_dispatch` | a | b | c | — | 0 / -1 | integer compute dispatch on the MEC ring — the ring-3 seam onto the sovereign GPU compute path (`a`/`b` operand shm slots, `c` result slot). The first syscall that let ring 3 run a shader at all; every op below stands on it. **tentib / ML** (1.54.x) |
| 83 | `gpu_dispatch_f64` | a | b | c | — | 0 / -1 | the f64 peer of `#82`, rosnet-bit-correct against the CPU. **rosnet / ML** (1.54.x) |
| 86 | `shm_create_gpu` | size | — | — | — | id / -1 | GPU-VISIBLE peer of `shm_create`#71: the page comes from the GPU **carveout**, so it has an MC address the CP-DMA engine can read. ⛔ A `#71` page is system RAM and the GPU **cannot reach it at all** (bus-master is off by design) — a GPU composite from a `#71` buffer is impossible, not merely slow. Same `shm_write`#72 / `shm_read`#73 / `shm_free`#74 afterwards. `-1` when there is no carveout (QEMU) — the caller falls back to `#71` + the CPU path. **aethersafha / gpu-test** |
| 87 | `gpu_blit_shm` | id | wh | dstxy | — | 0 / -1 | GPU-composite a client surface from its carveout shm slot straight into the blit back buffer. Replaces BOTH the shm→userland read and the per-pixel composite — the pixels never leave GPU-visible memory. `wh=(h<<16)\|w`, `dstxy=(dy<<16)\|dx`. Pair with `#85` + `#84`. **aethersafha** |
| 88 | `gpu_fill_rect` | color | wh | dstxy | — | 0 / -1 | the RECT peer of `gpu_fill`#85 — the window-chrome primitive (~10 per window per frame, formerly per-pixel on the CPU). REJECTS off-screen rects rather than clipping; the compositor owns clipping and queries its bounds from `#89`. **aethersafha** |
| 89 | `gpu_caps` | buf | len (≥32) | — | — | 0 / -1 | capability + **back-buffer** geometry probe (8× u32, 32 B). ⚠ These are the bounds a compositor must clip to before `#87`/`#88`/`#92`, and they are NOT what `fbinfo`#38 reports — `#38` describes the CONSOLE framebuffer. Also reports armed-ness and the carveout slot budget, and carries the **op-support mask** a caller must consult before issuing any `#92` op code. **aethersafha** |
| 90 | `gpu_readback_shm` | id | wh | srcxy | — | 0 / -1 | the INVERSE of `#87`: GPU-copy a rect OUT of the back buffer into the client's carveout slot — the screen-capture / read-pixels primitive. ⚠ Without it a compositor reading its own shm sees **STALE** pixels, because the composited frame lives in the kernel's GPU back buffer, not the client page. ⚠ **LINUX COLLISION:** `#90` = `chmod(path,mode)`, a metadata WRITE; the file-level `#ifdef CYRIUS_TARGET_AGNOS` gate in `cyrius/lib/syscalls.cyr` is the barrier off-agnos. |
| 91 | `gpu_blit_bb` | srcxy | wh | dstxy | — | 0 / -1 | GPU rect COPY **within** the back buffer (move a window, scroll a region), one CP-DMA per row, overlap-safe (downward moves copy bottom-up). ⚠ **LINUX COLLISION, and this one is load-bearing:** `#91` = `fchmod(fd,mode)`, and `srcxy=(0,0)` packs to fd 0 = stdin, so an off-agnos call would plausibly **SUCCEED**. The `#ifdef CYRIUS_TARGET_AGNOS` gate is the only barrier. **aethersafha** |
| 92 | `gpu_shader_op` | desc_uva | len (bytes) | — | — | 0 / packed −ve | **THE shader-compositing seam.** ONE number, an ARRAY of 64-byte op records, the operation selected by an op code INSIDE the payload (arc decision D-3) — new ops need no new syscall number. No pointer and no MC address appears in a record: sources are named by shm slot id and resolved in-kernel. **Validates EVERY op before dispatching ANY**, so a rejected batch draws NOTHING, and rejects rather than clips. Sources must be PREMULTIPLIED (`c ≤ a`). `len` is a BYTE length, not an op count — a future kernel with a wider record rejects a v1 caller on `len % stride`, where an op count would have passed and misparsed silently. Returns `0`, or `-((idx<<8)\|reason)` naming the failing op; `-1` still means "no GPU here". **Op codes and reasons: §3.4.** ⚠ **LINUX COLLISION:** `#92` = `chown(path,uid,gid)`, a metadata WRITE, and `arg1` is now a real user VA ≥ `0x200000`, so off-agnos the call would get a READABLE path pointer and could plausibly succeed. **aethersafha / sadish** |
| 93 | `gpu_modeset_op` | desc_uva | len (bytes) | — | — | 0 / packed −ve | **THE MODESET SEAM** (MD-4). Same record-array shape as `#92`, deliberately a DIFFERENT number: modeset is a distinct capability class from compositing. Write ops sit behind the **H2 arm-once latch** (`/.modeset-armed`) — the kernel never auto-disarms, and a blocked boot refuses. ⚠ **LINUX COLLISION:** `#93` = `fchown(fd,uid,gid)`; `arg1` is a userland VA so a stray off-agnos call is ~always `EBADF`. **`/bin/modeset`** |
| 95 | `uptime_us` | — | — | — | — | µs / −1 | ⭐ **MICROSECOND monotonic clock, readable with INTERRUPTS DISABLED** (rdtsc-backed, calibrated at boot against the live 100 Hz tick). ⛔ **`uptime_ms`#40 CANNOT be used by a foreground `run` program**: such programs start with `IF` cleared (only `/bin/agnsh` gets `IF=1`), so the timer ISR never fires and `#40` is **frozen for the program's entire duration** — anything timing itself with it measures zero. That cost two iron burns on the 3D arc's rung-10 gate. `#95` needs no interrupts. Returns **−1** when calibration was refused — never a plausible-looking 0, because a tool that cannot tell "no clock" from "0 µs elapsed" is exactly the failure this replaces. ⚠ **LINUX COLLISION:** `#95` = `umask(mask)`; non-destructive, and the file-level `#ifdef CYRIUS_TARGET_AGNOS` gate is the barrier. |
| 94 | `gpu_recover_op` | arm | — | — | — | 95 / −ve | 3D arc RUNG 5 — the GPU hang/recovery battery. ⛔ The arms that **wedge** the GPU are COMPILED OUT without `GPU_RECOVER`, so a production kernel cannot be asked to hang itself; the **recovery** half is always present, because a shipping kernel must survive a hang it did not ask for. ⭐ Arm D established that **the console survives a dead GPU**. **`/bin/gpuwedge`** |
| 40 | `uptime_ms` | — | — | — | — | ms | monotonic milliseconds since boot, returned in `rax` (from `timer_ticks` @ 100 Hz). No args, no fault surface. **ring-3 timing / DOOM** (1.43.5) |
| 41 | `sleep_ms` | ms | — | — | — | 0 | block the caller ~`ms` ms by halting until the 100 Hz timer (capped 1 h). An IF-window syscall — `preempt_disable()`-gated (1.44.1) so the shared kstack stays serial under preemption. **ring-3 timing / DOOM** (1.43.5) |
| 42 | `kbscan` | buf | max | — | — | count | NON-BLOCKING raw-scancode drain into `buf` (up to `max`) for ring-3 input (games need key up/down, not cooked lines). Bounded `hid_poll` window; `preempt_disable()`-gated IF-window. **cyrius-doom** (1.43.x) |
| 43 | `spawn_path` | path | pathlen (≤127) | env blob (opt, 1.44.19) | env len (a4=r10) | pid / -1 | NON-BLOCKING from-disk spawn: loads a static ELF64 from the ext2 root (with argv + optional envp) and creates a **READY ring-3 proc the scheduler picks up**, returning its pid IMMEDIATELY — the caller stays live and reaps it via non-blocking `waitpid`(4). spawn(3)'s shape (copy → boot CR3 → `elf_load_from_file` → restore caller CR3) with no blocking machinery. The kernel half of agnsh `&`. **agnsh `&`** (1.44.x) |
| 44 | `sched_yield` | — | — | — | — | 0 | voluntary end-of-slice from ring 3 (abandon-frame): donates the remainder of the timer slice to the next ready proc, returns 0 when re-scheduled. Dispatched only via the ring-3 SYSCALL entry stub (not `ksyscall`); guarded on sched_active/preempt/ew37_busy/IF=0/non-ready-next. agnsh's bg-poll loop yields after unproductive polls. **agnsh `&`** (1.44.16) |
| 45 | `getrandom` | buf | len | flags | — | bytes / 0 (len≤0) / -1 | Zen **RDRAND**, the sole entropy source — never blocks, never short-returns. `flags` accepted and ignored (there is no blocking pool). ⛔ RDRAND zeroes its destination on transient failure, so the kernel retries 10× per qword then whitens from the monotonic timer rather than ever handing back a zeroed buffer. **tls_native** (nonces / key material / GCM IV) |
| 46 | `time_unix` | — | — | — | — | unix seconds UTC / 0 | RTC/CMOS wall clock; `0` when the RTC is mid-update. ⚠ Distinct from `uptime_ms`#40 — that one is monotonic-since-boot for frame pacing, this is the absolute clock TLS cert-validity windows need. **tls_native** |
| 47 | `sock_connect` | dst_ip | dst_port | src_port | — | conn_id 0..7 / -1 | client TCP open. ⛔ **BLOCKS ~8 s with preempt DISABLED** — it starves the peer it is waiting on, which is why a retry loop around it is strictly worse (200 tries stretched a 30 s budget to 72 s with zero connections). Do not add one. **whirl, setu (retiring — see `planning/ipc.md` §10)** |
| 48 | `sock_send` | conn_id | buf | len | — | bytes (≤len) / -1 | client TCP send. **BLOCKS.** |
| 49 | `sock_recv` | conn_id | buf | maxlen | — | bytes / 0 / -1 | ⛔ **INVERTED FROM LINUX: `0` = WOULD_BLOCK, `-1` = EOF.** Reading it the Linux way turns "nothing yet" into "connection closed". |
| 50 | `sock_close` | conn_id \| listen_id | — | — | — | 0 / -1 | closes either kind of slot; on a LISTEN slot it also reaps children (1.45.6). |
| 51 | `udp_bind` | port | — | — | — | listener_id 0..7 / -1 | |
| 52 | `udp_send` | dst_ip | (sport<<16)\|dport | buf | len (a4) | bytes / 0 / -1 | uses **a4** — §1a. |
| 53 | `udp_recv` | listener_id | buf | maxlen | addr_out (a4) | bytes / 0 (none) / -1 | non-blocking; `0` means nothing queued. Uses **a4**. |
| 54 | `udp_unbind` | listener_id | — | — | — | 0 / -1 | |
| 55 | `icmp_echo` | dst_ip | — | — | — | RTT ms (≥0) / -1 | **BLOCKS ~3 s** (fixed kernel bound). ⛔ **ARITY FROZEN AT ONE ARGUMENT** — the caller-chosen deadline lives at `#100`, NOT in an `a2` here. Unused syscall argument registers are not zeroed by cyrius (it pops only as many as the call passes), so reading `a2` would hand every already-shipped one-arg caller a garbage bound. **dig / net-tools** |
| 56 | `sock_listen` | port | — | — | — | listen_id 0..7 / -1 | merges bind+listen, **non-blocking** (1.45.5). ⚠ Gates only on duplicate-bind, so whoever binds a port first owns it — there is no other authority check. |
| 57 | `sock_accept` | listen_id | — | — | — | conn_id / -1 | **non-blocking**; `-1` covers both WOULD_BLOCK and a bad id (1.45.5). ⚠ Returns the raw `conn_id`, not a VFS fd — accepted sockets are therefore **not** epoll-able (the 1.49.4 fd bridge was partially reverted at 1.53.9). |
| 58 | `lseek` | fd | offset | whence | — | new pos / -1 | whence `0`=SET / `1`=CUR / `2`=END. |
| 59 | `flock` | fd | op | — | — | 0 / -1 | inode-keyed **advisory** lock; op SH=1 / EX=2 / UN=8 (+NB=4). Released at reap. **agora** (PU shared-world door games) |
| 60 | `winsize` | — | — | — | — | (cols<<16)\|rows / -1 | console character grid from the live framebuffer, packed in `rax`: `cols = fb_width()/(8·scale)`, `rows = (fb_height()−FB_CONSOLE_Y0)/(16·scale)`, 8×16 glyph (mirrors `fb_putc`'s cell math); `-1` if the FB isn't up. No args, no buffer (like `uptime_ms`#40) → no pointer/SMAP surface. Lets a ring-3 TUI size to the real console instead of a hardcoded 80×24. **darshana `tty_winsize` on agnos → kii/cyim/chakshu** (1.45.13) |
| 61 | `net_config` | field | — | — | — | packed IPv4 / counter / 0 / -1 | non-blocking getter (`field` 0=ip / 1=netmask / 2=gateway / 3=dns_server), packed IPv4 in `rax`; 0 = unset, -1 = bad field. ⭐ **1.56.48 — fields 4..7 are ICMP COUNTERS, not config**: 4=`icmp_tx` (echo requests sent) · 5=`icmp_rx` (replies matching our id+seq) · 6=`icmp_replies_sent` (inbound pings answered) · 7=`icmp_timeouts` (pings that expired). Free-running, monotonic, never reset; written without a lock (`net_handle_icmp` runs from the timer ISR) so a torn read costs one count — **diagnostics only, do not build control flow on them**. ⚠ The `<=0 means fall back` rule of fields 0..3 does NOT apply to 4..7, where `0` legitimately means "nothing sent yet". **Why**: a ring-3 prober could not separate "we never transmitted" from "we transmitted and nothing answered" — `tx>0, rx==0` is a network problem, `tx==0` is a local one. The name stayed `net_config` because this syscall already takes a field selector and already returns -1 for an unknown one, so extending it costs no new number. Like `uptime_ms`#40 — no buffer/SMAP surface. Lets a ring-3 resolver use the on-subnet leased DNS instead of an off-subnet fallback. **taar/yo/dig on-subnet resolver** (1.45.16) ⭐ **FIELDS 8-11 ADDED 1.56.59** (telemetry §1 + §2): **8** `tx_packets` · **9** `rx_packets` · **10** `tx_bytes` · **11** `rx_bytes`. Counted at `nic_send`/`nic_poll` (`core/r8169.cyr`) — the one seam r8169 and virtio-net share — so the numbers mean the same thing on iron and under QEMU, and loopback is excluded by construction (it never reaches those functions). **Monotonic since boot, never reset.** Only a transfer the driver ACCEPTED is counted. ⚠ **Extended rather than minted, and that is the point**: `sys_net_config(field)` already passes an arbitrary field id, so a consumer reads these with **no cyrius peer and no toolchain change** — they shipped the day the kernel did. |
| 62 | `exec_redirect` | src_fd | dst_fd | — | — | 0 / -1 | arm a ONE-SHOT fd redirect for the NEXT `execwait`#37: the child's writes to `src_fd` (e.g. 1=stdout) route to `dst_fd`'s backend (an open writable file/pipe), so a parent can **capture** a tool's output, then read it back after #37 returns. Both fds in [0,32). ⛔ **THIS SENTENCE DESCRIBED A KERNEL THAT NO LONGER EXISTS, AND IT WAS THE SHIPPED CONTRACT UNTIL 1.56.54.** It read: *"Implemented as a save/swap/restore of the **global** `vfs_table` entry … NOT applied to the non-blocking `spawn`#3."* Both clauses are false since *ipc bites 10/11* (1.56.39-40): fd tables are **per-process** (`vfs_fd_table_of`), `#37` resolves the CHILD's table rather than swapping a global, and `spawn_redirect_apply` applies the redirect to `spawn_path`#43 between `proc_set_ring3` and `proc_set_state`. A consumer authored against the old text would expect a redirect on `#43` to be ignored — it is not — and would reason about a global table that per-process fds replaced. Cleared after the next `#37`. **cyrius regression capture / shakti session log** (1.46.x; issue `2026-06-15-cyrius-stdlib-missing-syscalls` grp 1 "the high-value one") |
| 63 | `symlink` | target | targetlen | linkpath | linkpathlen (a4) | 0 / -1 | create a symbolic link `linkpath` whose contents are the **TEXT** `target` (NOT resolved as a path — may point at a nonexistent/relative target, so `target` is a bounded user buffer 1..one-ext2-block, not `sc_path_ok`'d). ext2-only (symlinks need inodes; FAT/exFAT → -1); parent+basename via `vfs_ext2_parent`, work by `ext2_symlink` (fast<60 inline / slow=one block, e2fsck-clean). The **ark v2 / agnova prerequisite** (1.51.x DO-FIRST) — `ark_pkg_install` pass-2 creates `.so → .so.N`. ⚠ **TWO-SIDED**: ring 3 can't call it until cyrius adds the matching `sys_symlink`#63 peer (`lib/syscalls_x86_64_agnos.cyr` has `sys_link` but no `sys_symlink`) — cyrius is hands-off, flagged to the user. **ark/agnova** (1.51.0) |
| 70 | `readlink` | path | pathlen | buf | buflen (a4) | bytes / -1 | symlink **introspection** peer of #63: read the **TEXT** target of the symbolic link at `path` into `buf`, returning the target byte length (**not** NUL-terminated, ≤ `buflen`) or -1. The FINAL path component is resolved **NO-FOLLOW** (`ext2_path_lookup_ex` `follow_last=0`) so it reads the LINK, not its target — mid-path symlinks still resolve. -1 when: `path` absent, the final component is not a symlink (`ext2_readlink`'s `0xA000` mode check), the target exceeds `buflen`, or the mount isn't ext2. `buf` is a bounded user range (`is_user_range(buf,buflen)`), like stat's `statbuf`. Next free number after the audio band (#64-69). ⚠ **TWO-SIDED** like #63: needs the cyrius `sys_readlink`#70 peer (hands-off — issue `2026-07-08-cyrius-agnos-sys-readlink-peer`; hapi meanwhile calls it by local number). **hapi status/reconcile** |
| 64 | `snd_open` | — | — | — | — | slot 0..3 / -1 | HDA output stream. Auto-released on proc-exit. ⚠ **Output only** — `snd_open` has no direction argument and the input stream descriptors enumerated at probe are never armed. **mishran, tonegen** |
| 65 | `snd_config` | slot | rate | fmt | — | 0 / -1 | `rate`=48000; `fmt`=(bits<<8)\|ch, e.g. `0x1002` = 16-bit stereo. |
| 66 | `snd_write` | slot | buf | frames | flags (a4) | frames / -1 | **a4 bit 0 = O_NONBLOCK.** Blocking form spins `preempt_disable; sti; hlt` until ring space frees. |
| 67 | `snd_close` | slot | — | — | — | 0 / -1 | |
| 68 | `snd_drain` | slot | — | — | — | 0 | blocks until play-out, ~1 s cap. |
| 69 | `snd_avail` | slot | — | — | — | free frames / -1 | non-blocking. |
| 71 | `shm_create` | size | — | — | — | id (≥1) / -1 | kernel-owned COPY-based shared buffer, 1-based id (`0` is reserved for "inline"). ⛔ **The page is SYSTEM RAM and the GPU cannot reach it at all** (bus-master is off by design) — a GPU composite from a `#71` buffer is impossible, not merely slow; use `shm_create_gpu`#86. ⚠ `SHM_MAX = 16` slots and `shm_create` calls `pmm_alloc_2mb()` **unconditionally regardless of requested size**. ⚠ **No owner field** — any process may read, write or free any live slot (`shm_slot_valid` checks bounds and a non-zero phys only). **aethersafha, mishran** |
| 72 | `shm_write` | id | user_src | size | — | 0 / -1 | |
| 73 | `shm_read` | id | user_dst | size | — | 0 / -1 | |
| 74 | `shm_free` | id | — | — | — | 0 / -1 | ⚠ **Unauthenticated** — see the owner note on `#71`. |
| 75 | `blk_enum` | buf | cap | — | — | count / -1 | registered block devices. **agnova** (installer) |
| 76 | `blk_open` | tag | mode | — | — | handle / arm-ack (0) / -1 | `mode` 1 = RW and is **capability-gated** (armed by a magic value, not merely requested). |
| 77 | `blk_read` | h | lba | buf | nsec (a4) | nsec / -1 | uses **a4** — §1a. |
| 78 | `blk_write` | h | lba | buf | nsec (a4) | nsec / -1 | ⛔ **GATED** — arm via the `blk_open` magic first. Uses **a4**. |
| 79 | `blk_info` | h | out | — | — | 0 / -1 | |
| 80 | `blk_close` | h | — | — | — | 0 / -1 | |
| 81 | `readdir` | path | buf | max | — | count / <0 | path-based directory read. ⚠ agnos `#81`; the same number is `fchdir` on Linux — a raw `syscall(81,…)` written from Linux habit silently changes meaning. |
| 96 | `fork` | — | — | — | — | child pid (parent) / 0 (child) / -1 | ⭐ **A SECOND PROCESS RESUMING AT THE CALLER'S OWN FORK SITE** (1.56.54, corrected 1.56.55). The child continues at the parent's post-SYSCALL RIP, on a private COPY of the parent's address space, with `rax == 0`; the parent gets the child's pid. Full copy, **not CoW** — agnos has no write-fault unshare path — via `proc_dup_address_space` over PD[1..510] plus the high-arena PDPT, reusing `proc_map_page`/`_nx`/`_hi` so the `0x87` user bits, NX bit 63 and the KPTI entry-511 stash stay in one place. The child inherits a copy of the parent's fd table (`vfs_fd_inherit`), so an accepted socket survives into the child — the entire point for a fork-per-connection server. ⛔ **DISPATCHED FROM THE RING-3 ENTRY STUB** (`arch/x86_64/syscall_hw.cyr`), **not** `ksyscall`, for the same reason as `#44` and `#14`: the child's resume context comes from `pcpu_sc_entry_regs`, which is valid only on a path reached from the entry stub. A `ksyscall(96)` from in-kernel code would fork a child resuming at whatever ring-3 code last made a syscall, so it refuses a caller on the kernel CR3 (`src_cr3 == 0x1000` → -1). ⚠ **This row did not exist until 1.56.55** and its absence was not caught, because `scripts/check/syscall-abi-check.sh` scans only `kernel/core/syscall.cyr` for the kernel number set — so kernel, doc and cyrius all agreed by mutual absence. The gate's `ENTRY_STUB_ONLY` map now carries 96. ⚠ **TWO-SIDED** like `#63`/`#70`/`#102`: needs the cyrius `SYS_FORK = 96` peer before ring 3 can call it by name — filed as [cyrius `issues/2026-08-30-agnos-sys-fork-96-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-fork-96-peer.md). Ring 3 can call it by raw number meanwhile, which is what `tests/fork/forker.cyr` does. **Consumer: `agora`** (fork-per-connection BBS, `src/main.cyr` `sys_fork()`). |
| 97 | `chan_op` | op | a1 | a2 | a3 | 0 / −`CH_E_*` | **THE LOCAL-IPC CHANNEL BAND** (1.56.40, bite 4a) — the sovereign replacement for TCP-on-loopback as the display control transport. One number, op-dispatched, in the `#93`/`MDO_OP_SUPPORTED` style that grew a whole arc with no ABI break. **Implemented: `CH_CAPS` (0x00)** → writes `+0` op-support mask · `+4` region pages · `+8` region-reachable(1/0) to `out_uva` (`out_len ≥ 16`). ⛔ The reachable word is a **live probe under the CALLER's CR3**, not a boot-time cache — the 2 MB region is addressed through `DIRECTMAP_BASE` (the only alias every per-proc CR3 mirrors) and its reachability from a spawned client is a **kill criterion** (`planning/ipc.md` §9.9). ⛔ Every other op returns `−CH_E_BADOP` and **its caps bit is clear** — a client negotiates on the mask, so advertising an unimplemented op is how a client "works" against a kernel that cannot serve it. `CH_HANDOFF`(0x0A)/`CH_DIAL`(0x0B) are RESERVED, bits clear; the kernel will never dial. `CH_ENUM` is deliberately absent from v1 (no consumer). ⚠ `#96` is reserved for `fork`. **aethersafha / setu 0.8.0** |
| 98 | `ptrscan` | buf | max | — | — | 16 / 0 / −1 | **THE POINTER BAND** (1.56.42) — NON-BLOCKING drain of **ONE MERGED** pointer sample into `buf` (`max ≥ 16`). Returns **16** on activity, **0** when idle since the last call, **−1** on a bad range or an undersized buffer. Record, little-endian: `+0` s32 dx · `+4` s32 dy (**positive = DOWN**, as HID reports it) · `+8` u32 buttons (current level, bit0 left / bit1 right / bit2 middle) · `+12` u32 buttons_seen (OR since the last drain). ⭐ **A MERGED SAMPLE, NOT A STREAM** — pointer motion is a RELATIVE DELTA, so the kernel folds every report and hands back the sum; a raw stream would push the coalescing hazard into ring 3, where keeping only the last report of a gap **amplifies** motion ~2-3x. ⭐ `buttons_seen` is what lets a click that starts *and finishes* inside one frame survive. ⛔ **MUST NOT share `kbscan #42`'s ring**: dX = 0x01 decodes through the Set-1 table to HID 0x29 = **Escape**, so a one-pixel move on that pipe would quit the compositor — and it also feeds cyrius-doom. ⚠ No 256-iteration spin (that was for PS/2 IRQ1, deleted 1.56.42); one `hid_poll()` drains the ring. **aethersafha `AE-7` (pending `SYS_PTRSCAN` in cyrius)** |
| 99 | `proclist` | buf | max | — | — | count / −1 | **PROCESS ENUMERATION** (1.56.47) — snapshot of the live process table into `buf`; returns the **number of 64-byte records written**, or **−1** on a bad user range or `max < 1`. `buf` must hold `max * 64` bytes. Record, little-endian, one per live slot (dead slots skipped): `+0` u64 pid · `+8` u64 state (1 ready · 2 running · 3 claiming) · `+16` u64 ppid (0 = init) · `+24` u8[32] name (NUL-terminated **basename**, recorded by the ELF loader) · `+56` u64 reserved (always 0). ⭐ **THE FIRST ENUMERATION PRIMITIVE THIS OS HAS HAD.** The ring-3 surface offered `getpid`/`spawn`/`waitpid`/`kill` and there is no procfs, so nothing could answer "what is running?" — a system monitor was not degraded on AGNOS, it was impossible. chakshu rendered its column header and zero rows. ⭐ pid/state/ppid already existed in `proc_table`/`proc_ppid[]` and were merely unreachable; the genuinely new kernel state is the **name** — `struct Process` is pure register state, so a process's only identity was its pid. ⚠ **The reserved field is a decision, not slack**: per-process rss and cpu time are NOT tracked by this kernel and are not invented here; when they are, they land at `+56` and the record size does not change. ⚠ **A snapshot, not a handle** — walked under `preempt_disable`, but a pid may exit before the caller acts; re-probe before signalling. ⚠ Name is NUL-padded to the full 32 bytes so ring 3 cannot read a byte left by a previous occupant of the slot. **cyrius `SYS_PROCLIST` + `sys_proclist` (6.5.x)** ⛔ **`+56` IS SPLIT AS TWO u32 HALVES (1.56.59): low @+56 = cpu ticks, high @+60 = rss pages.** It previously read "reserved — room to add rss/utime", which promised TWO fields for ONE slot: the record is exactly 64 B with `name[32]` at +24..+55, so +56 is the final 8 bytes and whichever field shipped first would have taken the whole u64 and forced the other to a new number. Split while the value is still 0 and nothing reads it. A u64 zero-check still means "neither present", so consumers written against the old wording keep working. ⭐ **`+56` LOW u32 IS NOW LIVE — per-process CPU time in 100 Hz ticks** (1.56.59, telemetry §4; one tick = 10 ms, the same unit `uptime_ms`#40 reports in, so a consumer differences two samples exactly as it does Linux jiffies). Charged in the timer ISR to `proc_current_get()` on **every CPU** — deliberately outside the BSP-only gate that guards `timer_ticks`, because each CPU runs a different process and must charge its own. Zeroed at `proc_alloc_slot`, NOT at reap: clearing at exit would let a monitor sampling between exit and reap see a live process with 0 ticks. Saturates at 2^32-1 rather than wrapping — a wrap gives a negative delta and a nonsense CPU%. ⭐ **The HIGH u32 is per-process RSS in 4 KiB pages** (1.56.59, telemetry §5) — **computed**, not accounted: `proc_rss_pages` walks the process's page directory and counts PDEs that are **present AND user**, 512 pages (2 MB) each. ⛔ **The US bit is the entire discriminator**: `proc_create_address_space` fills PD[0..7] kernel-identity and PD[8..63] identity-**supervisor** (`0x83`, no US), so a walk without it reports ~258 MB of kernel window as every process's RSS. Measured: a live process shows `present=129 user=3`. ⚠ Incremental accounting at `proc_map_page` **cannot** work — the ELF loaders map every segment into the new `cr3` before `proc_set_cr3` binds it to a slot, so every charge is dropped. Both halves are written with ONE `store64` so they cannot tear, and both saturate rather than wrap. |
| 100 | `icmp_echo_ex` | dst_ip | timeout_ms | — | — | RTT ms (≥0) / -1 | ⭐ **`#55` WITH A CALLER-CHOSEN DEADLINE** (1.56.48). Same contract otherwise: sends one echo request, blocks for the matching reply, returns the round-trip time in **milliseconds**, or **-1** on timeout / NIC down. `timeout_ms <= 0` selects the kernel default (~3 s), so it degrades exactly to `#55`; clamped to 60 s so a bad value cannot park a process in the sti-window. Resolution is the 100 Hz tick, so the bound rounds **down** to whole ticks with a **floor of 1** — a sub-10 ms request waits one tick, not zero, because "never wait" is not what a caller asking for 1 ms means. ⛔ **WHY A NEW NUMBER AND NOT AN `a2` ON `#55`**: measured on cyrius 6.5.35, the compiler pops only as many registers as a call site passes, so an unused syscall argument register holds whatever the previous code left there — **not zero**. Widening a live arm would have handed every shipped one-argument caller a garbage bound, presenting as flaky timeouts rather than an ABI break. **Widening a live syscall's arity is not backward compatible on this ABI.** **Unblocks `yo -W` on AGNOS**, which yo accepted on every backend but could not honour here. **cyrius `SYS_ICMP_ECHO_EX` + `sys_icmp_echo_ex` (pending)** |
| 101 | `readdir_at` | path | buf | max | &cursor | count / <0 | ⭐ **`#81` THAT CAN RESUME** (1.56.50). `#81` always starts at the top of the directory and stops at `max`, so a directory with more entries than the caller's buffer is **silently truncated** — indistinguishable from a small directory, which reads as a filesystem fault. `cursor` points at **one i64 the kernel reads AND writes**: in `0` to start, out the byte offset to resume from, or **`-1` when exhausted**. Callers loop `while (cur != -1)`; passing `-1` back returns `0` and changes nothing, so overrunning by one is harmless rather than an infinite restart. ⚠ **The cursor is a BYTE OFFSET into the directory file** — POSIX `telldir`'s cookie, and the only value that survives ext2 directories being a chain of variable-length records; an entry *index* would force a re-walk from the top every call. ⛔ **WHY A NEW NUMBER AND NOT AN `a4` ON `#81`**: the same measured cyrius fact as `#100` — unused syscall argument registers carry stale values, not zero — but sharper here, because this argument is a **pointer the kernel writes through**, so widening `#81` would hand every shipped three-argument caller an arbitrary 8-byte write. Errors: `-1` bad ptr / not ext2, `-2` not found, `-4` not a dir, **`-5` cursor not 4-byte aligned or out of range** (a misaligned offset would parse a record header out of the middle of a filename). **cyrius `SYS_READDIR_AT` + `sys_readdir_at` (6.5.36)** |
| 103 | `statfs` | path | pathlen | buf | — | 0 / -1 | ⭐ **VOLUME CAPACITY FOR A PATH** (1.56.56). Fills a **32-byte** record, all u64 LE: `f_bsize` @0 (bytes per FS block), `f_blocks` @8 (total), `f_bfree` @16 (free), `f_bavail` @24 (free minus the filesystem`s reservation, clamped at 0). Total bytes = `f_blocks * f_bsize`; the kernel reports blocks, userland does the multiply. ⛔ **THE RECORD SIZE IS FROZEN ABI** — the call is 3-arg with no length parameter (like `stat`#33`s hardcoded 48), so there is no room to grow it later; a wider record needs a new number. ⚠ **PATH-BASED, not fd-based**, matching `stat`#33 — a caller need not open a descriptor to read a number. ⚠ **Why a new number and not a flag on #33**: a 4th argument rides `ksyscall_a4` = r10, which the entry stub sets from whatever r10 held at the call — garbage for every existing 3-arg caller, not 0. The same measured fact #100/#101/#102 all cite. ⭐ **All three backends answer it since 1.56.57** — ext2 from its live superblock counter, FAT by scanning the FAT for raw zero entries, exFAT by popcounting the allocation bitmap. `f_bsize` is the backend`s allocation unit (ext2 block / FAT or exFAT cluster). See §4.7 for the per-backend table and costs. ⭐ **The free count is LIVE, not a mount-time snapshot** — the allocator maintains `s_free_blocks_count`, and the gate asserts it DROPS after a write, which a constant-returning implementation cannot do. ⚠ **TWO-SIDED**: needs the cyrius `sys_statfs`#103 peer before ring 3 can call it by name — filed as cyrius [`issues/2026-09-01-agnos-sys-statfs-103-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-09-01-agnos-sys-statfs-103-peer.md), the third of three in that gap alongside `#96 fork` and `#102 lstat`. **Consumer: crab** (M6 sidebar VOLUMES capacity bars). |
| 104 | `mountlist` | buf | max | — | — | count / -1 | ⭐ **THE MOUNT TABLE, ENUMERATED** (1.56.59). Copies the live `{prefix -> backend}` table to ring 3. **80-byte** records, all-u64 header per §4.1: `backend` @0 (**FsBackend** — 1 ext2 · 2 FAT · 3 exFAT; 0 `FS_NONE` is never emitted), `prefixlen` @8 (1..64), `prefix` @16 (**64 bytes, NUL-PADDED** — a consumer must not assume the tail is meaningful). `max` is a RECORD count, and the arm validates it with `is_user_array`, not `is_user_range(buf, max * 80)` — the product wraps, which is verbatim the `#99` defect fixed at 1.56.51. Errors: `-1` bad pointer, wrapping `max`, or `max < 1`. ⭐ **FILED BY crab, AND IT IS AN ENUMERATION BECAUSE A PROBE CANNOT ANSWER IT.** `statfs`#103 answers *is this string mounted*; it cannot answer *are these two the same volume*. `vfs_mount_init` (`core/vfs.cyr:396`) gives an ext2-less boot the SAME backend under BOTH `/` and its `/mnt/...` prefix — its own comment calls them "harmless redundant aliases", harmless to routing but one volume listed twice in a sidebar. The backend id travelling with the prefix is what distinguishes them. ⚠ **A NEW NUMBER, NOT A WIDENING OF `mount`#11**: #11 takes no arguments in this table, and unused argument registers carry STALE values rather than 0 (the `#100`/`#101` rule), so widening it would hand every shipped caller an arbitrary pointer. ⛔ **NO LOCK, AND THAT IS ONLY SAFE WHILE #11 AND #24 ARE NO-OPS** — the table is written once by `vfs_mount_init` and immutable after. The day `mount` becomes real, this arm needs `fs_spin_lock` or it hands ring 3 a torn prefix. Boot-gated by `scripts/harness/mountlist-test.py` + `tests/mountlist/mlist.cyr` (exit 95). |
| 102 | `lstat` | path | pathlen | statbuf | — | 0 / -1 | ⭐ **`stat`#33 THAT DOES NOT FOLLOW THE FINAL SYMLINK** (1.56.53). Same 48-byte struct (§4.1), same failure shape; the only difference is `ext2_path_lookup_ex(..., follow_last=0)` — the lookup mode `readlink`#70 introduced, whose own ABI note above anticipated this exact reuse. Mid-path symlinks still resolve. ext2-only (`FS_EXT2` or -1: FAT/exFAT cannot represent a symlink, and succeeding there would be a surface #33 does not have). ⛔ **MINTED OFF AN IRON BURN, and the consequence was blunter than the roadmap predicted.** That row read *"lstat — blocked on a consumer (kriya `ln -s`, or ark install layouts)"*; the 2026-08-30 validation burn instead produced **two root-filesystem entries that could be listed but neither stat'd nor removed** — `/sl_s` (a slow symlink whose 70-byte target does not exist) and `/lp` (a deliberate self-referential ELOOP link), both leftover `EXT2_WRITE_SELFTEST` fixtures that the bare burn kernel never cleans up. Every `ls` and every `rm` printed `operation not permitted`, five times in one capture. ⭐ **`unlink`#30 was never the problem** — it resolves the parent and calls `ext2_unlink(parent, basename)`, which refuses only directories, and the selftest's own cleanup removes both fixtures happily. What failed is that kriya's `rm` is written to **never** follow a symlink and classifies every operand with `fs_lstat_at` first, which on agnos routed to path-based #33 and followed the link into nothing. kriya's own source says so: *"agnos has no lstat peer at all … agnos roadmap carries `lstat` as unslotted-pending-a-consumer; **this is that consumer**."* ⇒ A correct no-follow userland could not be correct on agnos. ⛔ **WHY A NEW NUMBER AND NOT A FLAG ON #33**: a 4th argument rides `ksyscall_a4` = **r10**, which the entry stub sets unconditionally from whatever r10 held at the call — so it is **garbage** for every existing 3-argument caller, not 0. A flag there would break #33 for every current consumer. Same measured cyrius fact #100 and #101 both cite. ⚠ **TWO-SIDED** like #63 and #70: needs the cyrius `sys_lstat`#102 peer before ring 3 can call it by name — filed in the **cyrius** repo as [`issues/2026-08-30-agnos-sys-lstat-102-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-lstat-102-peer.md). ⛔ **agnos does not modify cyrius**, so the syscall-ABI gate reads `kernel 102 · abi-doc 102 · cyrius 101` and stays red until that peer lands — the same one-sided state `#63` and `#70` shipped in. Ring 3 can call it by raw number meanwhile. **kriya `rm`/`ls`, whirl, ark install layouts** |

**37 `execwait` is IMPLEMENTED (1.43.0)** — the ring-3 blocking-exec primitive that lets a userland shell launch an on-disk program. It is the syscall behind agnoshi's gated `run` builtin (un-gated at agnoshi 1.4.4 by flipping `RUN_EXECWAIT_READY` + routing `process_agnos.cyr`'s `run()` through `syscall(37, path, len)`). Reuses the proven recovery-shell exec path; the novelty is being invoked from a *live ring-3 syscall frame*, handled by snapshotting the caller's resume-context globals + swapping to a disjoint second syscall kstack (`0x3D0000`) for the nested child. `EXEC_SELFTEST`'s `/bin/exwv` gates the full ring-3-caller path.

**34 `uname` / 35 `sysinfo` are IMPLEMENTED (1.42.10)** — the sovereign sysinfo surface for the native system-info tools. Split (identity vs counters) so a monitor like `chakshu` can poll `sysinfo` repeatedly without re-copying the static strings; each struct is single-shaped (all-string / all-u64) to avoid mixed-width padding. Both reject `is_user_range(buf,N)==0` or `len<N`. Kept *out* of the kernel deliberately: CPU brand string (userland CPUID), GPU manifest (userland PCI), distro (rootfs `/etc/os-release`), load-avg/swap (no native source). Userland calls them via the raw `syscall(34/35, buf, len)` builtin (no cyrius stdlib change required).

**70 `readlink` is IMPLEMENTED** — the ring-3 symlink-introspection primitive that closes the gap
`symlink`#63 opened: a program could *create* a link but never *see* one, because `stat`#33 follows
symlinks (including the final component) and there was no `lstat`/`readlink`. #70 reuses the in-kernel
`ext2_readlink` (fast-inline / slow-block target read), gated by a new **no-follow-final-component**
path lookup: `ext2_path_lookup` grew an `_ex(path, len, follow_last)` core, and #70 calls it with
`follow_last=0` so the trailing symlink resolves to *its own* inode instead of its target (every prior
caller uses the `follow_last=1` wrapper, byte-unchanged). Chosen over an `lstat`/`AT_SYMLINK_NOFOLLOW`
variant of #33 because `readlink` alone gives a symlink manager BOTH what it needs — detect (success vs
-1) **and** the target text to byte-compare — in one call, without a second stat struct; the no-follow
lookup it introduces is exactly what a future `lstat` would reuse if a consumer ever needs no-follow
*type* classification. First consumer: **hapi** (the GNU-stow-equivalent) `link_probe` status/reconcile.

`create` is **not** a separate syscall — file creation is `open(7)` with the `AO_CREAT` flag (§3.3),
subsuming `touch` (CREAT) and `echo >` (CREAT|TRUNC). `chdir`/`getcwd` are **not** in the ABI: **CWD is
userland-owned** — `agnsh` tracks its own CWD and passes **absolute paths** to every syscall.

### 3.4 `gpu_shader_op` #92 — op codes and record layout

> Added at 3D-arc **rung 9a** (2026-07-25). The plan flagged that this surface was undocumented while
> the arc was about to add op codes to it (`gpu.md`, adversarial item 6) — this section closes that.

A `#92` call passes an **array** of 64-byte records. Every dword is `u32` little-endian; **dword `i`
lives at byte offset `i*4`**.

| dword | byte | name | meaning |
|---|---|---|---|
| 0 | 0 | `op` | the op code (table below). Capped at `0x1F` — the code IS its bit index in `#89`'s support mask. |
| 1 | 4 | `flags` | ⛔ **Nothing is accepted here yet, on purpose.** A non-zero flags word is REJECTED. A flag that is accepted and ignored is how a caller silently gets behaviour it did not ask for. |
| 2 | 8 | `src_id` / `dst_id` | source shm slot (`BLEND_RECT`), or destination mask slot (`EDGE_COV`) |
| 3 | 12 | `mask_id` / `edge_id` | coverage or glyph mask slot; the edge-array slot for `EDGE_COV` |
| 4 | 16 | `wh` | `(h<<16)\|w` |
| 5 | 20 | `dstxy` | `(dy<<16)\|dx` — framebuffer destination. ⛔ **Not defined by `EDGE_COV`** (see below). |
| 6–8 | 24–32 | reserved | `srcxy` / `src_pitch` / `mask_pitch`, reserved for "0 = derive" |
| 9 | 36 | `color0` / `n_edges\|rule` | premultiplied colour; for `EDGE_COV`, `(rule<<16)\|n_edges` |
| 10 | 40 | `color1` | gradient end stop |
| 11–15 | 44–60 | reserved | must be zero |

⭐ **The rule that makes the reserved dwords safe to fill in later:** *every dword an op does not define
MUST be zero.* A v1 caller physically cannot ship garbage in a field a future kernel will read, so
`srcxy` / `src_pitch` / `mask_pitch` can gain meaning with no ABI break.

| op | name | defines | source slot | notes |
|---|---|---|---|---|
| `0x00` | `NOP` | `op flags` | — | no geometry, no slot, no shader arm |
| `0x01` | `BLEND_RECT` | `op flags src_id wh dstxy` | `w*4*h` | src-over alpha blend, premultiplied |
| `0x02` | `BLEND_COV` | `op flags mask_id wh dstxy color0` | `w*h` | 8bpp coverage × uniform colour |
| `0x03` | `GLYPH_1BPP` | `op flags mask_id wh dstxy color0` | `((w+7)/8)*h` | 1bpp bitmap expand |
| `0x04` | `GRAD_LINEAR` | `op flags wh dstxy color0 color1` | — | two-stop vertical gradient, reads zero source bytes |
| `0x08` | `EDGE_COV` | `op flags dst_id edge_id wh n_edges\|rule` | `n_edges*16` | **the rasteriser** — 3D arc rung 9 |

⛔⛔ **THIS OP TABLE STOPS AT `0x08`, AND THE KERNEL HAS SHIPPED THROUGH `0x10` — NINE OPS ARE UNDOCUMENTED HERE.** `syscall.cyr` declares `0x09 TRI_RGBA`, `0x0A TRI_LIST`, `0x0B TRI_TEX`, `0x0C TEX_LIST`, `0x0D DEPTH_CLEAR`, `0x0E TRI_DEPTH`, `0x0F TRI_PERSP` and `0x10 RT_READ`, and `GPU_OP_SUPPORTED = 0x1FF5F` advertises every one of them to ring 3. **`0x09` is shipped AND BURNED on iron.** The reason table below has the same hole: it ends at `20`, while the kernel defines through `29` — `21 GPO_E_WORK`, `22 GPO_E_AREA`, **`23 GPO_E_FRAME`**, `24 GPO_E_TRILIST`, `25 GPO_E_TEXSLOT`, `26 GPO_E_TEXDIM`, `27 GPO_E_LUTSLOT`, `28 GPO_E_MIXMODE`, `29 GPO_E_NOTIMPL`. ⇒ **A ring-3 author reading this file will conclude `0x08` is the last op and that a `23` return is undefined.** ⚠ This is the same shape as the `#96 fork` row that was missing until 1.56.55 — a shipped surface with no normative row — and it is recorded here rather than silently backfilled because writing nine op contracts from the source is its own piece of work, not a release-eve edit. Until then the source of truth for `0x09`-`0x10` is `kernel/core/syscall.cyr` (`gpo_validate*`) and the `#92` ABI battery, which asserts 177 cases across ops `0x01`-`0x10`.

**`EDGE_COV` (`0x08`) in detail.** An edge array (four `i32` in **16.16** per edge: `x0,y0,x1,y1`) plus a
winding rule, rasterised to an **8bpp coverage mask** in a second carveout slot. A triangle is a 3-edge
closed path; nothing about the kernel is triangle-specific.

- ⛔ **`dstxy` is NOT defined by this op** and must be zero. `EDGE_COV` never touches the framebuffer —
  it rasterises into a mask whose origin IS `(0,0)`. Placement is a separate `BLEND_COV` record.
  *(This is a deliberate deviation from the plan's provisional field list in `gpu.md` §op-table, which
  showed `dstxy`. Accepting a coordinate and ignoring it is the exact failure the `flags` rule refuses.)*
- ⛔ **Vertex transform stays on the CPU in ring 3** (arc decision TD-4) — the kernel receives
  SCREEN-SPACE edges.
- ⭐ **COORDINATE DOMAIN — every endpoint must satisfy `|x|,|y| ≤ 2^28`** (4096 px in 16.16, the
  same 4096 as `GPU_COV_MAX_DIM`). Violations return `GPO_E_COORD` (20), a **distinct** code from
  `GPO_E_DIM` because "your geometry is out of range" and "your mask is out of range" have
  different fixes. ⛔ This is not a style check — it is **the domain on which byte-identity to the
  CPU reference is defined at all**, and both ends need it: the reference computes
  `(bx−ax)·(sy−ay)` in i64, which **overflows** for ABI-legal i32 coordinates, so above roughly
  `M·d ≈ 2^63` the oracle has no defined value; and the shader's divider is exact iff
  `|bx−ax| < 2^31`. The bound is *measured*, not asserted — `tests/gpu/edgemodel.cyr`'s gate 3
  falsifies it on purpose (15 of 4000 cases differ above `2^31`). At `±2^28` the divider keeps two
  bits of margin and the reference five. **The bound is INCLUSIVE.**
- `n_edges` ∈ `[3, 256]`. **2 edges is a REJECT, not an empty result**: two edges cannot enclose area, so
  it would rasterise to a silent all-zero mask — indistinguishable from a dead shader, the one confusion
  this rung cannot afford.
- Mask dimensions cap at 4096 per side. A **reject**, never a clamp.
- The edge slot and the destination slot must be **different slots** (`GPO_E_ALIAS`).

**Failure encoding.** The call returns `0`, or a packed negative naming WHICH op failed and why:

```
e = 0 - rc ;  idx = e >> 8 ;  reason = e & 0xFF
```

`reason` is always ≥ 1, so a valid failure never encodes as 0, and `GPO_E_NOGPU` at idx 0 encodes as
exactly `-1` — which keeps every pre-existing `if (rc == -1)` caller working unchanged.

| reason | name | scope | meaning |
|---|---|---|---|
| 1 | `NOGPU` | call | GPU / display unavailable |
| 2 | `BADOP` | op | unknown, reserved, or not implemented in this kernel |
| 3 | `BADSLOT` | op | slot invalid/free, or PMM-backed (`#71`) so the GPU cannot read it |
| 4 | `SLOTSIZE` | op | source does not fit its slot under this op's stride rule |
| 5 | `BOUNDS` | op | rect off-screen — REJECT, never clip |
| 6 | `DIM` | op | `w < 1`, `h < 1`, or over the per-side cap |
| 7 | `ARM` | op | the shader could not be made resident |
| 8 | `DISPATCH` | op | the dispatch watchdog expired (pass 2 only) |
| 11 | `DESC` | call | bad `desc_uva` / `len`, or the copy-in failed |
| 12 | `RESERVED` | op | a reserved dword or an undefined flag bit was non-zero |
| 13 | `UNPROVEN` | call | the dispatch envelope is unproven on this boot |
| 15 | `BATCH` | call | the batch's single completion fence never retired. ⚠ `idx` is 0 and **carries no meaning** — with one submission there is one marker, so the failing op is not identifiable and reporting an index would be a fabrication. |
| 16 | `EDGEBUF` | op | edge slot too small for `n_edges`, or `n_edges` out of range |
| 17 | `DSTSLOT` | op | destination mask slot invalid/free/PMM-backed/too small |
| 18 | `RULE` | op | winding rule is neither `NONZERO` (0) nor `EVENODD` (1) |
| 19 | `ALIAS` | op | edge slot and destination mask slot are the same slot |
| 20 | `COORD` | op | an edge endpoint lies outside `±2^28` — outside the domain on which byte-identity to the CPU reference is defined |

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
| `AO_APPEND` | `0x400` | seek to end on each write. ⛔ **DECLARED IN THE ABI, HONOURED BY NO BACKEND** — the ext2 open path never tests `0x400` and the FAT/exFAT arm says so outright (`syscall.cyr`: *"AO_TRUNC is implicit (whole-file replace); AO_APPEND TODO"*). ⚠ **THE BIT IS NEVERTHELESS TAKEN AND IS SET AT RUNTIME TODAY**: cyrius `lib/io.cyr` bridges Linux `O_APPEND` to `0x400` on every append-open, and `lib/io.cyr` compensates for the missing kernel half with an explicit `lseek(SEEK_END)`. ⇒ **Do not mint a new flag on `0x400`.** A 2026-08-31 request proposed exactly that for `AO_EXCL`, reading the kernel (where nothing tests the bit) rather than this table; it would have turned every existing append-open into `EEXIST`. Next free bit is **`0x2000`**. |
| `AO_DIRECTORY` | `0x800` | must be a directory (for `getdents`) |
| `AO_EXCL` | `0x2000` | ⭐ **with `AO_CREAT`, refuse a final component that ALREADY resolves** (1.56.56) — POSIX `O_EXCL`, completing the check-then-write pair `AO_NOFOLLOW` opened. ⛔ **Returns -1, NOT -17**: §1`s return convention has no `-errno`; a caller wanting `EEXIST` translates in its own wrapper. Without `AO_CREAT` the bit is ignored, as POSIX leaves it undefined there. ⚠ **Evaluated BEFORE `AO_TRUNC`** — this is load-bearing, not an implementation detail: checked afterwards, an `AO_CREAT\|AO_TRUNC\|AO_EXCL` open would zero the file and *then* refuse it, destroying exactly what the flag protects. The selftest asserts the surviving size, not just the refusal. ⚠ Routes to `ext2_path_lookup_ex(..., follow_last=0)`, so a symlink at the final component is a refusal **even when it dangles**. FAT/exFAT answer it too, via `fatfs_create`/`exfat_create`s existing-name refusal — whose return value is discarded without this flag, because `touch <existing>` depends on that. **Consumer: crab** (copy/move overwrite guard). |
| `AO_NOFOLLOW` | `0x1000` | ⭐ **refuse if the FINAL component is a symlink** (1.56.53) — returns -1 rather than following it, closing the check-then-write TOCTOU that `readlink`#70 could only detect. Routes to `ext2_path_lookup_ex(..., follow_last=0)`. Mid-path symlinks still resolve, matching POSIX `O_NOFOLLOW` and `#70`. ext2 only in effect: FAT/exFAT cannot represent a symlink, so the flag is trivially satisfied there. ⚠ **This row was missing until 1.56.55** — the flag shipped two cuts earlier and reached no doc and no cyrius constant, so ring 3 could not name the thing that had been built for it. The cyrius peer is still owed. |

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

### 4.3 `uname` struct (64 bytes, 4× 16-byte fixed-width NUL-padded string fields)

Written by syscall 34. Each field is a fixed 16-byte slot, the string copied from a kernel literal and NUL-padded to fill the slot (**not** NUL-terminated-and-variable — read by fixed offset):

| Offset | Field | Width | Value |
|--------|-------|-------|-------|
| 0 | `sysname` | 16 | `"AGNOS"` (kernel name) |
| 16 | `nodename` | 16 | hostname — `kernel_hostname`, default `"agnos"` (no `sethostname` yet) |
| 32 | `release` | 16 | kernel version — `_AGNOS_VERSION` (e.g. `"1.42.10"`) |
| 48 | `machine` | 16 | arch — `"x86_64"` (the aarch64 build would emit `"aarch64"`) |

16 bytes/field is generous headroom (longest current value is `"aarch64"`=7); the 64-byte struct is a clean power of two. Conceptually mirrors Linux `utsname` but renumbered to AGNOS slot 34, with our explicit-(buf,len) + fixed-16 layout instead of Linux's 65-byte FQDN-sized fields.

### 4.4 `sysinfo` struct (200 bytes, 25× u64 little-endian — was 40 / 5× until 1.56.59)

Written by syscall 35. The kernel does the unit conversion (ticks→seconds at 100 Hz, pages→bytes at 4 KB) so userland never re-derives:

| Offset | Field | Type | Source |
|--------|-------|------|--------|
| 0 | `uptime_secs` | u64 | `timer_ticks / 100` (100 Hz; nominal, not wall-clock-precise) |
| 8 | `totalram` | u64 | `pmm_total * 4096` (bytes; the kernel-managed page pool) |
| 16 | `freeram` | u64 | `pmm_free_count() * 4096` (bytes) |
| 24 | `procs` | u64 | `proc_count` (live process-table count) |
| 32 | `cpus` | u64 | `cpu_count` — enumerated CPUs. ⚠ The old note "=1 until SMP enumeration lands" is stale: it landed (`smp_sched_aps` / `smp_wake_enabled`), so this reports genuinely usable parallelism |
| 40 | `cpu0_user` | u64 | 100 Hz ticks whose interrupted CS was **ring 3** |
| 48 | `cpu0_kern` | u64 | 100 Hz ticks whose interrupted CS was **ring 0** |
| 56 | `cpu1_user` | u64 | — |
| 64 | `cpu1_kern` | u64 | — |
| 72 | `cpu2_user` | u64 | — |
| 80 | `cpu2_kern` | u64 | — |
| 88 | `cpu3_user` | u64 | — |
| 96 | `cpu3_kern` | u64 | — |

| 104 | `blk0_read` | u64 | reserved — `BLK_NONE`, always 0 |
| 112 | `blk0_write` | u64 | reserved, always 0 |
| 120 | `blk1_read` | u64 | cumulative sectors READ, `BLK_VIRTIO` |
| 128 | `blk1_write` | u64 | cumulative sectors WRITTEN, `BLK_VIRTIO` |
| 136 | `blk2_read` / `blk2_write` @144 | u64 | `BLK_NVME` |
| 152 | `blk3_read` / `blk3_write` @160 | u64 | `BLK_AHCI` |
| 168 | `blk4_read` / `blk4_write` @176 | u64 | `BLK_USB_MS` |
| 184 | `blk5_read` / `blk5_write` @192 | u64 | `BLK_RAMDISK` |

**Per-device disk block (+104..+199), added 1.56.59.** `+104 + tag*16 + 0` sectors read, `+8` sectors written. ⚠ **Indexed by the RAW `BLK_*` tag with slot 0 deliberately wasted** — `blk_reads_by_tag[6]` reserves index 0 (`BLK_NONE`) and uses 1..5, so a consumer reads `+104 + tag*16` with the **same tag `blk_enum`#75 handed it**, no `-1` adjustment to get wrong. 16 bytes of padding is a cheap price for removing an off-by-one from every consumer. ⚠ **Sectors, not bytes**: this layer moves exactly one sector per call, and a byte figure needs the per-device LBA size, which can be 4096 — multiply by `blk_info`#79's reported size. Monotonic since boot, never reset; an unregistered device legitimately reports 0.

⛔ **This band was `blkstats`#105 and THE NUMBER HAS BEEN WITHDRAWN.** It was minted, filed upstream and shipped as a cyrius peer in 6.5.44 before an audit of the whole syscall surface found it never needed a number: a closed 5-value tag enum over flat by-tag arrays is exactly a fixed-size tail block. `blk_info`#79 was correctly ruled out (fixed arity, no length) and the test stopped there instead of continuing to #35. Removed rather than left standing, because **a needless syscall number is permanent surface** — every consumer, every ABI gate and every peer carries it forever. The cyrius removal is filed.

**Per-core block (+40..+103), added 1.56.59.** `+40 + cpu*16 + 0` user, `+8` kernel, 4 CPUs — the hard kernel-wide cap `pcpu_cpu()` enforces. Split by the **privilege of the interrupted context** in the timer ISR, i.e. Linux's `%us`/`%sy`, computed the same way and exact rather than sampled. Monotonic since boot, never reset.

⛔ **The length tiers are 40 / 104 / 200 and each gates its band independently** — a caller passing 40..103 gets exactly the 40-byte struct, 104..199 gets the per-core band and NOT the disk band, 200+ gets both — the arm sizes ONE `is_user_range` from the caller's length before any store, so the extension is all-or-nothing and never a partial write with an error return.

⛔⛔ **There is no `idle` field, and that is the honest answer rather than an omission.** agnos has no single idle loop: `arch_wait()` (a bare `hlt`) is called from ~a dozen polling waits — DHCP retry, `sleep_ms`#41, `kbd_read_blocking`, the NIC drain — so a CPU halted inside a blocking syscall is **indistinguishable at the tick boundary** from one doing real kernel work. Both are ring 0. ⇒ `cpuN_kern` means **"system + halted"**, not "busy-system"; compute utilisation as `user / (user + kernel)`.

⚠ **Reaching +40..+103 needs a raw `syscall(35, buf, 104)` today.** The cyrius peer is `fn sys_sysinfo(out)` — arity 1, length hardcoded to 40 — so a wrapper consumer cannot see the tail until a length-taking overload lands upstream. That is a **number-free** ask (no new syscall, no ABI-gate row), but it is not nothing. ⇒ Contrast `net_config`#61, whose peer `fn sys_net_config(field)` genuinely forwards an arbitrary id: its fields 8-11 reached consumers the same day with nothing upstream. **The two are not symmetric, and this doc said they were until an audit caught it.**

All-u64 (no sub-word fields → no Cyrius struct-padding ambiguity, same rule §4.1 follows). No Linux `mem_unit` scaling field (AGNOS uses fixed u64 byte counts — no 32-bit overflow), no `_f[]` padding, and no swap/buffer/highmem fields (AGNOS has none — omitted). Future fields append at the tail and bump the minimum `len`; the existing offsets are frozen ABI the moment a consumer reads them.

### 4.5 `klug` read (syscall 36 — variable-length log copy, not a struct)

`klug(buf, len)` copies the unified **klug** kernel-log ring (`core/klug.cyr`, a **64 KB** circular byte buffer fed by every `kprint`/`kputc`/`kprintln`) into the user `buf`, **oldest→newest** (chronological). It is not a fixed struct — it returns raw log text and the byte count:

- Returns `min(len, ring_fill)` — the number of bytes written — or `-1` if `is_user_range(buf, len)` fails.
- When `len` < the current ring fill, returns the **newest** `len` bytes (the dmesg tail) so a small buffer still shows the most recent lines.
- The ring wraps at **64 KB** (old lines age out); the kernel unwraps oldest→newest so the userland reader always sees chronological order regardless of the wrap point.
  - ⚠ **This said 16 KB in three places until 1.56.58 and had been wrong since the ring was raised.** `core/klug.cyr` declares `var klug_buf[8192]` — module scope, so N×u64 = **65536 bytes** — and the userland reader pins the same number (`klug/src/klug.cyr`, `KLUG_RING_BYTES = 65536`, asserted in its test suite). The two must move in lockstep or the tool pulls only its own buffer's worth of the tail.

**Line format (1.56.58).** Every **kernel-origin** line is prefixed with a fixed-width **15-byte** uptime field in Linux `printk` shape — `[    4.123456] ` — built by `klog_build_prefix` (`core/kprint.cyr`): `[`, seconds right-aligned in 5 columns and **space**-padded, `.`, microseconds in 6 columns **zero**-padded, `]`, one space. Time is measured from the first statement of the boot body; lines emitted before the timebase calibrates read `[    0.000000]`, as Linux does for its own pre-timekeeping lines.

- ⛔ **RING-3 OUTPUT IS NOT PREFIXED, AND MUST NOT BECOME SO.** `kprint` is also the userland stdout/stderr path (fd 0/1/2 are `VFS_DEVICE` 0 → `vfs_write` → `dev_write` → `serial_dev_write` → `kprint`), so the kernel raises `klog_raw_depth` around that write and those bytes pass through **byte-exact**. Every program's output, every pipe stage and every harness that parses program text depends on it.
- The prefix is emitted only at a true **beginning of line**. `klog_at_bol` tracks every byte — raw ring-3 bytes included — so a kernel line arriving while a program has written a partial line does not inject a field mid-line.
- Consumers that anchor on a kernel line must accept the field as **optional**: `^\(\[[^]]*\] \)\{0,1\}` in BRE, `^(\[[^]]*\] )?` in ERE. Both prefixed and bare lines exist in the same log.

**Severity tags.** Leveled lines carry an `[I]`/`[W]`/`[E]` tag from `klug_info`/`klug_warn`/`klug_err`, **after** any uptime field. The kernel does **no** filtering — it unifies the log; grep stays userland.

- ⛔ **A production kernel emits ZERO leveled lines today.** All three of `klug_info`/`klug_warn`/`klug_err`'s call sites are inside `#ifdef EXEC_SELFTEST` (`core/main.cyr`), which is off in every shipping build — so `klug -w`/`-e` legitimately match nothing. The userland tool says so on stderr since klug 0.1.6 rather than printing nothing and exiting 0, because "no warnings" and "no lens" are otherwise the same output. Adopting the leveled API across the kernel is open work, not a documented state.

### 4.6 exec init stack — argv + envp (1.43.2)

`elf_load_from_file` builds a standard SysV process init stack; `rsp` at entry points at `argc`. cyrius's agnos runtime captures it as `_agnos_init_rsp` (`args_agnos.cyr`). Layout (each slot a u64):

| offset from rsp | contents |
|-----------------|----------|
| `0` | `argc` (≤ 8) |
| `8 + i*8` | `argv[i]` → string VA (i = 0 .. argc-1) |
| `8 + argc*8` | argv NULL terminator |
| `8 + (argc+1+j)*8` | **`envp[j]`** → `"KEY=VALUE"` string VA (j = 0 .. envc-1) |
| `8 + (argc+1+envc)*8` | envp NULL terminator |
| `8 + (argc+2+envc)*8` | auxv `AT_NULL` type (0) |
| `8 + (argc+3+envc)*8` | auxv `AT_NULL` val (0) |

The `KEY=VALUE` and argv strings live higher in the stack page (`0x3100..0x4000`). **envp (1.43.2):** the kernel stages a uniform default — `envp[0]="HOME=/"`, `envp[1]="PWD=/"` — on every exec (was an empty envp NULL pre-1.43.2). **cyrius half:** `getenv()`'s agnos branch reads `envp[j] = load64(_agnos_init_rsp + 8 + (argc+1+j)*8)` and walks `KEY=VALUE` to NULL — the language-work the cyrius agent owns. Per-process env propagation (threading a caller-supplied env through `execwait`) is a kernel follow-on.

**Per-process env wire format (1.44.19, #37 + #43):** `a3` = user pointer to a flat NUL-separated
`KEY=VALUE\0KEY=VALUE\0` blob, `a4` (= r10) = blob byte length. Caps: **<=1024 bytes, 1..16
entries**, every entry `KEY=...` with `=` at index >=1, trailing NUL required. The caller env
**REPLACES** the default (never merges); `a3==0` (or ANY validation failure) falls back to the
uniform default — **fallback-only, never -1**, because legacy 3-arg callers deliver garbage a3/a4
(the cyrius `syscall()` builtin pops exactly N arg registers; old-agnsh-on-new-kernel is the normal
ESP-only deployment). The kernel copies the blob via a fault-proof page-table walk of the caller's
CR3 (garbage pointers are rejected, not dereferenced). The 16-entry cap is load-bearing: the envp
pointer array (`0x3008+(argc+3+envc)*8`) must stay below the 0x3100 string base. Consumers: build
within the caps client-side (an oversized blob silently degrades to the default env).

### 4.7 `statfs` struct (32 bytes, 4× u64 little-endian)

Written by syscall **103**. The kernel reports **blocks**, not bytes — userland does the multiply, so
the record never has to guess a unit. Total bytes = `f_blocks * f_bsize`; free bytes = `f_bfree * f_bsize`.

| Offset | Field | Type | Source (ext2) |
|--------|-------|------|---------------|
| 0 | `f_bsize` | u64 | `ext2_blocksize` — bytes per FS block (1024 / 2048 / 4096), set at mount from `s_log_block_size` |
| 8 | `f_blocks` | u64 | `s_blocks_count` @ superblock+4 — total blocks in the filesystem |
| 16 | `f_bfree` | u64 | `s_free_blocks_count` @ superblock+12 — **live**, maintained by the allocator on every block alloc/free |
| 24 | `f_bavail` | u64 | `f_bfree - s_r_blocks_count` (@ superblock+8), **clamped at 0** |

All-u64 (no sub-word fields → no Cyrius struct-padding ambiguity, the same rule §4.1 and §4.4 follow).

⭐ **`f_bfree` is a live count, not a mount-time snapshot.** It is read from the resident superblock the
block allocator maintains, so it moves as the filesystem is written. That is the whole point for the
filed consumer — a capacity bar that never changes is a lie. The selftest asserts it: it writes a file
and requires the count to DROP, which a constant-returning implementation cannot satisfy.

⚠ **`f_bavail` is clamped for a real reason, not defensively.** A filesystem may legitimately run below
its reservation (`s_free_blocks_count < s_r_blocks_count`), and an unclamped subtraction would hand ring
3 a negative i64 that a progress meter renders as full or absurd.

⛔ **THE RECORD SIZE IS FROZEN ABI, AND UNUSUALLY SO.** `statfs` is 3-arg (`path`, `pathlen`, `buf`) with
**no length parameter** — the kernel validates a hardcoded 32 bytes, exactly as `stat`#33 validates a
hardcoded 48. So unlike §4.3/§4.4, whose contract is "future fields append at the tail and bump the
minimum `len`", **this record cannot grow**: there is no `len` for a caller to raise and no way for the
kernel to tell an old caller from a new one. A wider record needs a **new syscall number**. Four fields
is what the consumer asked for; adding a fifth later is not a compatible change.

⭐ **ALL THREE BACKENDS ANSWER IT as of 1.56.57.** `vfs_resolve_mount` routes the path; each backend
fills the same record, and `f_bsize` is that backend`s allocation unit — an ext2 **block**, a FAT or
exFAT **cluster** — so `f_blocks * f_bsize` is the volume size on all three.

| backend | `f_blocks` | `f_bfree` | cost |
|---|---|---|---|
| ext2 | `s_blocks_count` | `s_free_blocks_count`, **maintained live by the allocator** | O(1), no disk read |
| FAT | `fatfs_count_of_clusters` | **full FAT scan** counting raw `0` entries | one block read per FAT sector |
| exFAT | `exfat_cluster_count` | **allocation-bitmap scan**, popcounting zero bits | one block read per 512 B of bitmap |

⛔ **NEITHER FAT NOR exFAT KEEPS A FREE COUNT, AND FAT`s HINT IS UNUSABLE BY agnos`s OWN DESIGN.**
FAT32 has an FSInfo free-cluster hint, but `fat_fsinfo_mark_unknown` stamps it `0xFFFFFFFF` from twelve
mutation sites — agnos declares it stale rather than maintaining it, so reading it back would be
reading our own "unknown" marker. exFAT has no such field at all; allocation state exists only in the
bitmap. Both therefore scan, and both refuse (`-1`) on a read error rather than reporting a guess.
⚠ **`f_bavail == f_bfree` on FAT and exFAT** — neither format has a reservation concept. Only ext2`s
can differ, and only when `s_r_blocks_count` is non-zero.
⚠ The FAT scan reads **raw** FAT entries and must: `fat_get_entry` maps end-of-chain to `0`, so
counting zeros through it would report every file`s last cluster as free.

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
