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
| 35 | `sysinfo` | buf | len (≥40) | — | — | 0 / -1 | writes the 40-byte counters struct (§4.4) into `buf`: uptime_secs / total+free RAM bytes / procs / cpus. Live snapshot; kernel does the unit conversion. **mihi/iam/chakshu** (1.42.10) |
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
| 61 | `net_config` | field | — | — | — | packed IPv4 / counter / 0 / -1 | non-blocking getter (`field` 0=ip / 1=netmask / 2=gateway / 3=dns_server), packed IPv4 in `rax`; 0 = unset, -1 = bad field. ⭐ **1.56.48 — fields 4..7 are ICMP COUNTERS, not config**: 4=`icmp_tx` (echo requests sent) · 5=`icmp_rx` (replies matching our id+seq) · 6=`icmp_replies_sent` (inbound pings answered) · 7=`icmp_timeouts` (pings that expired). Free-running, monotonic, never reset; written without a lock (`net_handle_icmp` runs from the timer ISR) so a torn read costs one count — **diagnostics only, do not build control flow on them**. ⚠ The `<=0 means fall back` rule of fields 0..3 does NOT apply to 4..7, where `0` legitimately means "nothing sent yet". **Why**: a ring-3 prober could not separate "we never transmitted" from "we transmitted and nothing answered" — `tx>0, rx==0` is a network problem, `tx==0` is a local one. The name stayed `net_config` because this syscall already takes a field selector and already returns -1 for an unknown one, so extending it costs no new number. Like `uptime_ms`#40 — no buffer/SMAP surface. Lets a ring-3 resolver use the on-subnet leased DNS instead of an off-subnet fallback. **taar/yo/dig on-subnet resolver** (1.45.16) |
| 62 | `exec_redirect` | src_fd | dst_fd | — | — | 0 / -1 | arm a ONE-SHOT fd redirect for the NEXT `execwait`#37: the child's writes to `src_fd` (e.g. 1=stdout) route to `dst_fd`'s backend (an open writable file/pipe), so a parent can **capture** a tool's output, then read it back after #37 returns. Both fds in [0,32). Implemented as a save/swap/restore of the global `vfs_table` entry around the run-to-completion child run (no per-proc fd layer needed); cleared after the next #37. NOT applied to the non-blocking `spawn`#3. **cyrius regression capture / shakti session log** (1.46.x; issue `2026-06-15-cyrius-stdlib-missing-syscalls` grp 1 "the high-value one") |
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
| 97 | `chan_op` | op | a1 | a2 | a3 | 0 / −`CH_E_*` | **THE LOCAL-IPC CHANNEL BAND** (1.56.40, bite 4a) — the sovereign replacement for TCP-on-loopback as the display control transport. One number, op-dispatched, in the `#93`/`MDO_OP_SUPPORTED` style that grew a whole arc with no ABI break. **Implemented: `CH_CAPS` (0x00)** → writes `+0` op-support mask · `+4` region pages · `+8` region-reachable(1/0) to `out_uva` (`out_len ≥ 16`). ⛔ The reachable word is a **live probe under the CALLER's CR3**, not a boot-time cache — the 2 MB region is addressed through `DIRECTMAP_BASE` (the only alias every per-proc CR3 mirrors) and its reachability from a spawned client is a **kill criterion** (`planning/ipc.md` §9.9). ⛔ Every other op returns `−CH_E_BADOP` and **its caps bit is clear** — a client negotiates on the mask, so advertising an unimplemented op is how a client "works" against a kernel that cannot serve it. `CH_HANDOFF`(0x0A)/`CH_DIAL`(0x0B) are RESERVED, bits clear; the kernel will never dial. `CH_ENUM` is deliberately absent from v1 (no consumer). ⚠ `#96` is reserved for `fork`. **aethersafha / setu 0.8.0** |
| 98 | `ptrscan` | buf | max | — | — | 16 / 0 / −1 | **THE POINTER BAND** (1.56.42) — NON-BLOCKING drain of **ONE MERGED** pointer sample into `buf` (`max ≥ 16`). Returns **16** on activity, **0** when idle since the last call, **−1** on a bad range or an undersized buffer. Record, little-endian: `+0` s32 dx · `+4` s32 dy (**positive = DOWN**, as HID reports it) · `+8` u32 buttons (current level, bit0 left / bit1 right / bit2 middle) · `+12` u32 buttons_seen (OR since the last drain). ⭐ **A MERGED SAMPLE, NOT A STREAM** — pointer motion is a RELATIVE DELTA, so the kernel folds every report and hands back the sum; a raw stream would push the coalescing hazard into ring 3, where keeping only the last report of a gap **amplifies** motion ~2-3x. ⭐ `buttons_seen` is what lets a click that starts *and finishes* inside one frame survive. ⛔ **MUST NOT share `kbscan #42`'s ring**: dX = 0x01 decodes through the Set-1 table to HID 0x29 = **Escape**, so a one-pixel move on that pipe would quit the compositor — and it also feeds cyrius-doom. ⚠ No 256-iteration spin (that was for PS/2 IRQ1, deleted 1.56.42); one `hid_poll()` drains the ring. **aethersafha `AE-7` (pending `SYS_PTRSCAN` in cyrius)** |
| 99 | `proclist` | buf | max | — | — | count / −1 | **PROCESS ENUMERATION** (1.56.47) — snapshot of the live process table into `buf`; returns the **number of 64-byte records written**, or **−1** on a bad user range or `max < 1`. `buf` must hold `max * 64` bytes. Record, little-endian, one per live slot (dead slots skipped): `+0` u64 pid · `+8` u64 state (1 ready · 2 running · 3 claiming) · `+16` u64 ppid (0 = init) · `+24` u8[32] name (NUL-terminated **basename**, recorded by the ELF loader) · `+56` u64 reserved (always 0). ⭐ **THE FIRST ENUMERATION PRIMITIVE THIS OS HAS HAD.** The ring-3 surface offered `getpid`/`spawn`/`waitpid`/`kill` and there is no procfs, so nothing could answer "what is running?" — a system monitor was not degraded on AGNOS, it was impossible. chakshu rendered its column header and zero rows. ⭐ pid/state/ppid already existed in `proc_table`/`proc_ppid[]` and were merely unreachable; the genuinely new kernel state is the **name** — `struct Process` is pure register state, so a process's only identity was its pid. ⚠ **The reserved field is a decision, not slack**: per-process rss and cpu time are NOT tracked by this kernel and are not invented here; when they are, they land at `+56` and the record size does not change. ⚠ **A snapshot, not a handle** — walked under `preempt_disable`, but a pid may exit before the caller acts; re-probe before signalling. ⚠ Name is NUL-padded to the full 32 bytes so ring 3 cannot read a byte left by a previous occupant of the slot. **cyrius `SYS_PROCLIST` + `sys_proclist` (6.5.x)** |
| 100 | `icmp_echo_ex` | dst_ip | timeout_ms | — | — | RTT ms (≥0) / -1 | ⭐ **`#55` WITH A CALLER-CHOSEN DEADLINE** (1.56.48). Same contract otherwise: sends one echo request, blocks for the matching reply, returns the round-trip time in **milliseconds**, or **-1** on timeout / NIC down. `timeout_ms <= 0` selects the kernel default (~3 s), so it degrades exactly to `#55`; clamped to 60 s so a bad value cannot park a process in the sti-window. Resolution is the 100 Hz tick, so the bound rounds **down** to whole ticks with a **floor of 1** — a sub-10 ms request waits one tick, not zero, because "never wait" is not what a caller asking for 1 ms means. ⛔ **WHY A NEW NUMBER AND NOT AN `a2` ON `#55`**: measured on cyrius 6.5.35, the compiler pops only as many registers as a call site passes, so an unused syscall argument register holds whatever the previous code left there — **not zero**. Widening a live arm would have handed every shipped one-argument caller a garbage bound, presenting as flaky timeouts rather than an ABI break. **Widening a live syscall's arity is not backward compatible on this ABI.** **Unblocks `yo -W` on AGNOS**, which yo accepted on every backend but could not honour here. **cyrius `SYS_ICMP_ECHO_EX` + `sys_icmp_echo_ex` (pending)** |
| 101 | `readdir_at` | path | buf | max | &cursor | count / <0 | ⭐ **`#81` THAT CAN RESUME** (1.56.50). `#81` always starts at the top of the directory and stops at `max`, so a directory with more entries than the caller's buffer is **silently truncated** — indistinguishable from a small directory, which reads as a filesystem fault. `cursor` points at **one i64 the kernel reads AND writes**: in `0` to start, out the byte offset to resume from, or **`-1` when exhausted**. Callers loop `while (cur != -1)`; passing `-1` back returns `0` and changes nothing, so overrunning by one is harmless rather than an infinite restart. ⚠ **The cursor is a BYTE OFFSET into the directory file** — POSIX `telldir`'s cookie, and the only value that survives ext2 directories being a chain of variable-length records; an entry *index* would force a re-walk from the top every call. ⛔ **WHY A NEW NUMBER AND NOT AN `a4` ON `#81`**: the same measured cyrius fact as `#100` — unused syscall argument registers carry stale values, not zero — but sharper here, because this argument is a **pointer the kernel writes through**, so widening `#81` would hand every shipped three-argument caller an arbitrary 8-byte write. Errors: `-1` bad ptr / not ext2, `-2` not found, `-4` not a dir, **`-5` cursor not 4-byte aligned or out of range** (a misaligned offset would parse a record header out of the middle of a filename). **cyrius `SYS_READDIR_AT` + `sys_readdir_at` (6.5.36)** |
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

### 4.3 `uname` struct (64 bytes, 4× 16-byte fixed-width NUL-padded string fields)

Written by syscall 34. Each field is a fixed 16-byte slot, the string copied from a kernel literal and NUL-padded to fill the slot (**not** NUL-terminated-and-variable — read by fixed offset):

| Offset | Field | Width | Value |
|--------|-------|-------|-------|
| 0 | `sysname` | 16 | `"AGNOS"` (kernel name) |
| 16 | `nodename` | 16 | hostname — `kernel_hostname`, default `"agnos"` (no `sethostname` yet) |
| 32 | `release` | 16 | kernel version — `_AGNOS_VERSION` (e.g. `"1.42.10"`) |
| 48 | `machine` | 16 | arch — `"x86_64"` (the aarch64 build would emit `"aarch64"`) |

16 bytes/field is generous headroom (longest current value is `"aarch64"`=7); the 64-byte struct is a clean power of two. Conceptually mirrors Linux `utsname` but renumbered to AGNOS slot 34, with our explicit-(buf,len) + fixed-16 layout instead of Linux's 65-byte FQDN-sized fields.

### 4.4 `sysinfo` struct (40 bytes, 5× u64 little-endian)

Written by syscall 35. The kernel does the unit conversion (ticks→seconds at 100 Hz, pages→bytes at 4 KB) so userland never re-derives:

| Offset | Field | Type | Source |
|--------|-------|------|--------|
| 0 | `uptime_secs` | u64 | `timer_ticks / 100` (100 Hz; nominal, not wall-clock-precise) |
| 8 | `totalram` | u64 | `pmm_total * 4096` (bytes; the kernel-managed page pool) |
| 16 | `freeram` | u64 | `pmm_free_count() * 4096` (bytes) |
| 24 | `procs` | u64 | `proc_count` (live process-table count) |
| 32 | `cpus` | u64 | `cpu_count` (=1 until SMP enumeration lands) |

All-u64 (no sub-word fields → no Cyrius struct-padding ambiguity, same rule §4.1 follows). No Linux `mem_unit` scaling field (AGNOS uses fixed u64 byte counts — no 32-bit overflow), no `_f[]` padding, and no swap/buffer/highmem fields (AGNOS has none — omitted). Future fields append at the tail and bump the minimum `len`; the existing offsets are frozen ABI the moment a consumer reads them.

### 4.5 `klug` read (syscall 36 — variable-length log copy, not a struct)

`klug(buf, len)` copies the unified **klug** kernel-log ring (`core/klug.cyr`, a 16 KB circular byte buffer fed by every `kprint`/`kputc`/`kprintln`) into the user `buf`, **oldest→newest** (chronological). It is not a fixed struct — it returns raw log text and the byte count:

- Returns `min(len, ring_fill)` — the number of bytes written — or `-1` if `is_user_range(buf, len)` fails.
- When `len` < the current ring fill, returns the **newest** `len` bytes (the dmesg tail) so a small buffer still shows the most recent lines.
- The ring wraps at 16 KB (old lines age out); the kernel unwraps oldest→newest so the userland reader always sees chronological order regardless of the wrap point.
- Leveled lines carry an `[I]`/`[W]`/`[E]` prefix (from `klug_info`/`klug_warn`/`klug_err`) — the userland `klug`/`dmesg` tool greps on that prefix (the kernel does **no** filtering: it unifies the log; grep stays userland).

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
