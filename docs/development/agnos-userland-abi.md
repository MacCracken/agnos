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
| **O5** | **The number space deliberately overlaps Linux's — consumers MUST use the cyrius `sys_*` wrappers, never a raw Linux syscall number.** | AGNOS's compact `0–55` surface reuses numbers that mean something *different* in the Linux x86-64 ABI (we adopt their *register* convention, not their numbers — see O2). A raw, unguarded `syscall(<linux-number>, …)` in stdlib does **not** fail to compile on AGNOS — it **silently mis-dispatches**: Linux `read`#0 = AGNOS `exit` (the process *terminates*); `socket`#41 = `sleep_ms`; `shutdown`#48 = `sock_send`; `setsockopt`#54 = `udp_unbind`; `getsockopt`#55 = `icmp_echo` (blocks the caller up to ~3 s); `poll`#7 = `open`. This is structural, not a per-module bug — any future stdlib code hand-rolling a Linux number is a latent landmine. cyrius **6.2.7**'s stdlib-completeness pass routes all socket/io through the portable `sys_*` wrappers + the tagged-fd socket adapter and fail-closes the rest, so nothing mis-dispatches today. Full mis-dispatch table + the missing-call inventory: [`issues/2026-06-15-cyrius-stdlib-missing-syscalls.md`](issues/2026-06-15-cyrius-stdlib-missing-syscalls.md). |

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
| 0 | `exit` | code | — | — | (no return) | ends the calling process through the **one death chain** (1.57.7 S7, `proc_death`): every per-process resource is released (flock, snd, shm, channels, the scanout, TCP/UDP, the keyboard line, the raw-disk arm it armed, spawn arms, its fg cell), then it becomes a zombie its parent reaps (`#99` state 7) — or, when its parent incarnation is gone, it frees its own fd table + address space at once (orphan self-reap). The parent's wait sees `code & 0xFF` (§4.9). Never returns to ring 3. **shell** |
| 1 | `write` | fd | buf | len | bytes / -1 | `vfs_write`; fd 1/2 → console. ⛔ **ON A PIPE fd THIS IS A SHORT WRITE, AND THE RETRY IS THE CALLER'S OBLIGATION** (*ipc bites 10/11*, 1.56.39-40): the ring is `PIPE_RING` = 4080 bytes, and `pipe_write` stops at `(write_head - read_tail) >= PIPE_RING` rather than wrapping and overwriting as it did before. A caller that writes `len` and assumes `len` was taken **silently loses the tail**. Loop on the returned count. This contract was not written down here until 1.56.54, while the kernel had behaved this way since 1.56.40. **shell** |
| 2 | `getpid` | — | — | — | pid | returns `proc_current`. **shell** |
| 3 | `spawn` | elf_addr | elf_size | — | pid / -1 | loads an **in-memory** ELF (not a path). See §5 exec note. ⚠ **1.57.6: consumes the caller's `CH_ENDOW`#97 endowment** (placement runs in `proc_create_user`, which the in-memory loader reaches) **and clears it on every return**, failure included, so an arm can never survive a failed `#3` into the caller's next child. It does **not** consume `#62` redirects — those stay armed for the caller's next `#43`/`#37`. Return value unchanged (-1). ⭐ **1.57.7 (S7):** a caller with a **pending kill cannot create a child** (the call fails; the caller never observes it — it ends at its syscall exit); a child created by a **tree-stopped** caller is born stop-pending. The child's parent identity is (pid, epoch). ⭐ **1.57.7 (S8):** returns −1 when two PT_LOADs share a 2 MB page (the loader refuses the overlap; a blind second PDE store leaked the first frame) and when the image (distinct PT_LOAD pages + 1 stack page, × 512) exceeds the caller's effective memory cap for its next child; **consumes the caller's `spawn_limits`#107 arm on every return** (unlike the other arms, #3 consumes it too). |
| 4 | `waitpid` | pid | — | — | exit_code / -2 / -1 | ⛔ **NON-BLOCKING POLL, THREE-VALUED — this row said "busy-waits until `state==0`" and a two-valued return until 1.56.55, and both halves were wrong.** It does not block: it returns the child's `exit_code` if the child is dead, **-2 (WOULD_BLOCK)** if it is still alive, and **-1** if `pid` is out of range, is the caller itself, or is not the caller's child (`proc_may_reap` — only the parent, or init as the orphan reaper). ⭐ **1.57.7 — `WAIT_BLOCK`: `arg1 = 0x100 \| pid` (pid 0..15) BLOCKS the caller until that child exits; `0x1FF` = any child.** No new number: the range was free (`arg1 >= proc_count`, ≤ 16, has always answered −1, which is also what a pre-1.57.7 kernel answers — a caller can probe). The return values are the poll form's (the lifecycle step's status encoding applies to both; they share one body, `waitpid_poll`). **−1 at once** when the target is not the caller's child or the caller has no children; **−2 only when the caller cannot block** — before the scheduler runs (an `execwait`#37 child blocks like any process since S3b) — and (the lifecycle step) while a kill is being delivered. The waiter leaves its CPU in a real BLOCKED state (#99 state 6); every exit path (exit#0, the fault kill) stores state 0 and THEN wakes the parent. Re-validation: a target reaped and recycled by someone else while the caller waits answers −1 (`proc_may_reap` is re-run on every wake), never a stranger's status. No deadline (a child that never exits keeps its parent waiting). Mechanism: `docs/architecture/blocking-waits.md`. ⭐ **`pid < 0` IS WAIT-ANY** (1.56.54): scan for any dead child of the caller, reap the LOWEST, return its code; **-2** while children live, **-1** when there are none. That `-2`/`-1` split is the contract every fork-model server loop depends on, and `#96 fork` was blocked on it. ⚠ **A reaped child stops being a child** (1.56.55) — both reap doors clear `proc_ppid`, so a second wait-any never re-matches an already-collected row. Before that fix the parent re-reaped the same non-top slot forever and never saw its other children. **shell, `tests/fork/forker.cyr`** ⭐ **1.57.7 (S7) — THE WAIT STATUS (D2, §4.9):** a reaped child reads `code & 0xFF` for an exit, `128 + vector` for a fault (142), `0x100 | sig` for a death by signal (SIGKILL **265**, S8's SIGXCPU 280) — every value ≥ 0, so a child that called `exit(-2)` no longer reads as "still running" (254). WAIT_BLOCK shares the encoding. **−2 also covers DYING (4) and STOPPED (5)** (no WUNTRACED). **Children are epoch-validated** (`proc_is_child_of`: ppid AND the parent incarnation recorded at birth) — a recycled parent slot does not inherit its predecessor's orphans, and a process whose parent is gone reaps itself at its death. **1.57.7 (S8):** status **280** = `0x100 \| SIGXCPU(24)` is the CPU cap (`spawn_limits`#107). |
| 5 | `read` | fd | buf | len | bytes / **-1** / **-2** | `vfs_read`. **fd 0 = stdin** — the keyboard (§3.1). ⭐ **1.57.7 (S3d) — fd 0 keyboard, `a4 == 0`, BLOCKS ONLY THE CALLER until a whole line** (Path 2: a real wq wait woken by the HID producer). **ONE reader per line**: a second blocking reader waits until the first returns its line. The NB form (`a4 != 0`) answers **−2 without draining** while another live process owns the line, and itself owns the line while its partial line (**−3**) is live. Refused contexts (pre-scheduler, preempt-held kernel callers; no ring-3 process since S3b) keep the CPU-holding read. Returns **−1 only when a lifecycle signal aborts the wait** (S7). ⛔ **ON A PIPE fd, AN EMPTY RING RETURNS `-2` (WOULD_BLOCK) WHILE ANY WRITER IS STILL OPEN, AND `0` ONLY ONCE EVERY WRITER HAS CLOSED** (*ipc bites 10/11*, 1.56.39-40). That split is what lets a reader tell **"nothing yet"** from **"end of stream"**; before it, a consumer that out-ran its producer read 0 and quit early. `-2` is the kernel's established WOULD_BLOCK value, shared with the channel band and the cooked-line read. ⚠ **A reader that treats every non-positive return as EOF terminates early; one that treats `-2` as fatal fails a healthy pipe.** ⚠ **The writer MUST close** — an unclosed write end means the reader never sees 0 and can spin forever. This row said `bytes / -1` until 1.56.54, four cuts after the kernel changed. **shell** |
| 6 | `close` | fd | — | — | 0 / -1 | `vfs_close`. **shell** |
| 7 | `open` | name | namelen | — | fd / -1 | **currently `initrd_open` ONLY** (can't reach the agnos-fs). 1.41.3 re-routes — see §5. **shell** |
| 8 | `dup` | fd | — | — | fd | 🔧 stub: returns `a1` unchanged. |
| 9 | `mkdir` | path | pathlen | — | 0 | 🔧 stub → 0. 1.41.3 makes it real. **shell** |
| 10 | `rmdir` | path | pathlen | — | 0 | 🔧 stub → 0. 1.41.3 makes it real. **shell** |
| 11 | `mount` | — | — | — | 0 | 🔧 stub (no-op). |
| 12 | `sync` | — | — | — | 0 | 🔧 stub → 0. 1.41.3 wires to `vfs_sync`. **shell** |
| 13 | `reboot` | magic1 | magic2 | cmd | (no return) / **-1** | `power_sys` (`core/power.cyr:381`). **a4 = `arg`, unused** — read via `ksyscall_a4_get()`, so this is one of the four-argument calls §0/O? covers. **a1 = `0x50575231` ("PWR1"), a2 = `0x50575232` ("PWR2")** — a fail-closed token, not cargo-cult: cyrius exposed #13 as a *nullary* `sys_reboot()`, so every already-compiled caller of the old form delivers garbage in rdi/rsi/rdx, and without a token the first one to run would halt or reset the box at random. It is also the deliberate, permanent privilege gate (`getuid` is hardcoded 0 by ruling — agnosticos `planning/identity-and-authorization-model.md`, 2026-05-12 — so a uid check would be a gate that is always open). **a3 = `cmd`: 1 = halt (stop the CPU, box stays powered — matches Linux `LINUX_REBOOT_CMD_HALT`), 2 = power off (ACPI S5), 3 = reboot (platform reset).** Returns **-1** on a magic mismatch or an unrecognised `cmd`, and **does not return** for any valid one. ⚠ **This row read `— — — / (halts) / serial_println + arch_halt` until 1.56.60** — the pre-1.55.25 stub, five minors stale; `roadmap.md:32` had already filed the identical sentence as FALSIFIED but fixed only the roadmap. ⛔ **`scripts/check/syscall-abi-check.sh` CANNOT SEE THIS CLASS OF DRIFT** — by its own header it checks number sets, doc==cyrius names, and kernel dispatch-comment names; argument and semantics columns are out of scope by design, so `state.md`'s "syscall ABI GREEN: 105/105/105" is a *count* passing over wrong *content*. **agnsh** (`reboot`/`poweroff`/`halt`), **shell** (same three, added 1.56.60) |
| 14 | `pause` | — | — | — | 0 | ⭐ **1.57.7 — YIELDS OR PARKS in the kernel** (S3.4 + S3.6): it yields to a READY process (the voluntary switch, `int 0xE0`); otherwise ONE hlt — a designated CPL0 **preempt point** (IF=1, preempt_count 0; ≤ 1 interrupt period, **not charged** to the caller) — then offers the CPU once more, so a `pause` poll-backoff loop donates its CPU when anything else is READY and does not spin a core when nothing is. The hlt follows the flag → `mfence` → scan → `sti;hlt` halt protocol, so a wake that lands meanwhile ends it (the S3.8 0xE1 kick). Only when the context is REFUSED (before the scheduler, preempt-held kernel code, a borrowed CR3 — never a ring-3 process after the scheduler starts: since S3b-F2 an `execwait`#37 child is an ordinary scheduled process, and INV-FG-1's tripwire latches `fg: IF=0 ring-3 caller …` if a caller's saved RFLAGS ever lacks IF) does it fall to the legacy preempt-held single `hlt`. In-kernel `ksyscall(14)` (KSTACK_SELFTEST mode 5) takes the same park-then-yield body. Returns 0. |
| 15 | `getuid` | — | — | — | 0 | 🔧 stub (always root=0). |
| 16 | `kill` | pid | sig (\| `KILL_TREE` 0x100) | — | 0 / -1 / -2 | ⭐ **1.57.7 (S7) — THE LIFECYCLE (process-lifecycle.md, §4.9).** **9 ENDS** the target (it never appears to `signalfd`): through the one death chain, status 265; **19 STOPS** it (#99 state 5; −1 when the target cannot be stopped: not a user process, its parent waits on it in `#37`/kmain's foreground wait, or its parent incarnation is gone); **18 CONTINUES** it (and still sets bit 18); **0 PROBES** (authorization only, no bit); any other 1..63 sets a pending bit (**no default action — SIGTERM included**, D3). 9/18/19 on kmain, the idles or a kthread → −1; a dead or dying target → 0 and nothing changes (a zombie keeps its status). **`sig \| 0x100` = KILL_TREE**: the root and every epoch-validated descendant in one snapshot (child-only AUTHORITY, descendants-only REACH — D4; no process-group/session reach); a tree STOP that had to skip ≥ 1 member returns **−2** (the root and the other members are stopped; e.g. a `#37` foreground child keeps running). Any other bit above 7 (or a negative sig) → −1. Authority: self, an epoch-valid direct child, or init (kmain). A kill of a `#37` waiter also kills its foreground child. Latency: immediate when the target is off-CPU in ring 3 (claimed); ≤ one 10 ms tick while it runs in ring 3 (unpinned); at the end of its current syscall; at once when it is blocked in a kernel wait (the wait is interrupted). A stopped keyboard reader keeps the keyboard line. |
| 17 | `sigprocmask` | how | set_ptr | oldset_ptr | 0 / -1 | how: 0=BLOCK, 1=UNBLOCK. ptrs ≥ 0x200000. |
| 18 | `signalfd` | fd | mask_ptr | flags | fd / -1 | allocates a `VFS_SIGNALFD`. ⭐ **1.57.7 (S7):** reading a signalfd clears ONE bit **atomically** (`lock and`; every setter ORs atomically) — a racing read could erase a bit another CPU set mid-read before. 9 and 19 never appear (they are transitions, not bits); 18 does. `epoll_wait`#21 readiness never reports 9/19. |
| 19 | `epoll_create` | — | — | — | fd / -1 | allocates a `VFS_EPOLL` (8-watch list). |
| 20 | `epoll_ctl` | epfd | op | fd | 0 / -1 | op: 1=ADD, 2=clear. max 8 watches. |
| 21 | `epoll_wait` | epfd | events_ptr | max | nready | event rec = `{u32 mask; u64 data}` @ 12 B stride; `max`≤16. **A POLL**: returns nready, **0 when nothing is ready; it never waits** (the "hlt if none ready" this row said has been false since 1.56.40). |
| 22 | `timerfd_create` | — | — | — | fd / -1 | allocates a `VFS_TIMERFD`. |
| 23 | `timerfd_settime` | fd | flags | val_ptr | 0 / -1 | `val_ptr`→`{u64 interval_sec; _; u64 initial_sec}` (24 B); ticks = sec×100. |
| 24 | `umount` | — | — | — | 0 | 🔧 stub → 0. |
| 25 | `pipe` | fds_ptr | — | — | 0 / -1 | writes 2× u64 fds at `fds_ptr` (16 B, ≥0x200000). `vfs_create_pipe`. ⛔ **STREAMING SINCE 1.56.39-40, NOT STORE-AND-FORWARD.** The ring is **4080 bytes** (`PIPE_RING`) and is no longer wrap-and-overwrite: a full ring **short-writes** (see #1) and an empty one returns **`-2`** while a writer is open (see #5). ⇒ Producer and consumer may now run CONCURRENTLY, which is the point of the change — but the caller owes two things it did not owe before: **retry on a short write**, and **close the write end** so the reader can reach EOF. ⭐ **1.57.6 — BUFFER LIFETIME: THE LAST REFERENCE ANYWHERE.** The 4 KB buffer is freed only when **no fd slot in any table** still names it — the caller's two ends, every copy a child inherited (`#43`/`#37`/`#3`/`fork`#96), every redirect (`#62`; since 1.57.7 a `#37` redirect lives only in the child's table, which dies at its reap — there is no backup copy any more) — not on the creator's second close as before. A child still holding an inherited or redirected end therefore keeps the pipe alive after its parent closes both ends (through 1.57.5 it then read and wrote a FREED block that the next `kmalloc(4096)` handed to an unrelated pipe or TCP ring — a cross-process leak). Reaping a child releases its references too. Nothing changes for a caller that closes what it opened; a reader still sees EOF once every **live** write end is closed. |
| 26 | `write_boot_checkpoint` | byte | — | — | 0 | 🩺 writes `CMOS[0x50]=byte&0xFF` (iron-boot progress marker). |
| 27 | `mmap` | length | — | — | base_vaddr / 0 | anonymous, zero-filled, **2 MB-granular**; `0` = MAP_FAILED. ⭐ **1.57.7 (S8):** a mapping **never lands on a live one** (fork copies low pages while the low cursor is global and LIFO-rewound: a span with any present page is skipped), so a small request may return a **HIGH-arena VA (≥ 128 GB)** when the low arena is exhausted or its next span collides. Returns **0 when the mapping would take the caller past its memory cap** (`spawn_limits`#107 or inherited; footprint = #99's RSS, checked before the free-RAM count). |
| 28 | `munmap` | addr | length | — | 0 / -1 | frees an mmap region (2 MB-granular, LIFO vaddr reclaim). |

**Notes for the cyrius peer**: `epoll`/`signalfd`/`timerfd`/`sigprocmask`/`pipe` pass small fixed-layout
structs through user pointers — mirror the exact byte offsets above (they're agnos-native, **not** the Linux
`struct epoll_event`/`itimerspec` layouts). `dup`/`getuid`/`mount`/`umount` are stubs — the peer may expose
them but must not rely on real behavior.

## 3. ✅ DECIDED — 1.41.x additions + changes (not yet implemented; the shell-separation surface)

These are the agnos-side bites (1.41.1 stdin, 1.41.3 FS). The spec is **decided** (§0 settled O1–O4) and
mirror-able; both agents code to it, and each row **moves to 🔒 FROZEN (update §2) as the kernel lands it**.

### 3.1 Changed behavior (same numbers)

- **🔒 `read`(5) on `fd 0` → keyboard stdin** (**IMPLEMENTED 1.41.1**; line discipline + echo **1.41.15**; **blocks
  only the caller 1.57.7**). When `fd==0` is still the console device, the kernel returns a WHOLE LINE incl. the
  trailing `\n` (or a short line if the caller's `len` fills first). **Line discipline = canonical-lite (O1)** — the
  kernel **echoes** printable bytes via `kputc` (serial + GOP framebuffer), handles **backspace** as `BS SP BS`,
  terminates on newline, and Ctrl-D at line start returns **0** (EOF; mid-line it delivers the bytes so far);
  `kb_shift`/`kb_ctrl` are reset on entry. Keys arrive one way on both substrates: xHCI HID → `hid_poll` (the MSI-X
  ISR, the BSP tick, every poll) → `hid_kb_push` → `kb_buf`; since 1.57.7 each keyboard TRB has its own report slot,
  so a key pressed and released inside one interrupts-off stretch is no longer lost.
  ⭐ **1.57.7 (Path 2, S3d) — THE READ BLOCKS ONLY ITS CALLER.** With nothing buffered the reader leaves its CPU in a
  real BLOCKED wait (woken by `hid_kb_push`, 100 ms backstop); every other process runs while the operator types.
  **ONE READER PER LINE**: the first blocking reader owns the next line; a second waits until the first has returned
  its line. The non-blocking form (`a4 != 0`) returns **−2** (nothing buffered) — *without draining* while another
  live process owns the line — or **−3** (a partial line is buffered here, and this reader keeps the line until it
  completes), or the line. A dead owner's line is reclaimed. **Refused contexts** (before the scheduler, preempt-held
  kernel callers; an `execwait`#37 child blocks like any process since S3b) keep the CPU-holding read: preemption held for
  the whole line, one IF=1 `hlt` per wait step, never a busy spin — so the observable result is identical.
  *(History: 1.41.1 polled with IF masked — QEMU-only; 1.41.14 used IRQ1+`sti`; 1.41.15 made it whole-line + echoed
  after the `14114` stuck-shift collapse; until 1.57.7 every read suspended preemption for the whole line and spun
  one core, which is what froze background jobs at an idle prompt.)* **NB — observable syscall numbers/arg-passing
  are unchanged, so the cyrius peer is unaffected.** Other fds keep the `vfs_read` path.
- **`open`(7) → mount-routed** (1.41.3). Re-route from `initrd_open`-only to `vfs_resolve_mount` →
  `ext2_open` (inode-wise) or `vfs_open_on` (FAT/exFAT), with `initrd` as the bare-name fallback. **Gains a
  flags arg** (a3) — see 3.3. Opening a **directory** returns a dir-fd usable by `getdents` (29). ⭐ **Two
  kernel-owned names are intercepted BEFORE the mount table** — `/fonts/default.ttf` and its provenance alias,
  the embedded TrueType face (1.57.2): see **§3.5**.
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
| 37 | `execwait` | path | pathlen | env blob (opt, 1.44.19) | env len (a4=r10) | child exit code / -1 | ⭐ **1.57.7 (S3b) — A BLOCKING WAIT.** Loads a static ELF64 from the ext2 root (the same load half as `#43`: the line form, ≤ `SPAWN_LINE_MAX` = 127 bytes, ≤ 16 tokens — more is REFUSED, never dropped; env blob FALLBACK-ONLY as before) and runs it as an **ordinary scheduled IF=1 process** — time-sliced, on any CPU; it may yield, fork, spawn, wait, block (`sleep_ms`, `flock`, the keyboard …) and **nest** `#37` (bounded only by the 16-slot table). The **caller BLOCKS in the kernel** (#99 state 6) and every other process keeps running; it wakes when the child exits and gets the child's exit code. **-1**: any launch failure (`#43`'s `-SPAWN_E_*` codes fold to -1 — a child may `exit(-2)`), a caller that cannot block, **-1 before the scheduler is live** (boot selftests only), and **-1 if the child could only get the GLOBAL fd table** (the D11 kmalloc fallback: a concurrent child there would share proc 0's fds). Armed `#62` redirects (up to 4, arm order, each `dst` read from the child's current table) apply **into the child's private table, with no restore** — the table dies with the child at its reap. **Every return clears the caller's whole spawn-arm state** (`#62` set + `CH_ENDOW` + PTY flag), as in 1.57.6. Kill/stop of a waiting caller or its child: per the lifecycle step (S7). Until 1.57.7 the child ran OUT OF BAND (pinned to the caller's CPU, IF=0, never scheduled, the caller's resume context in per-CPU cells, one nest level): it could not be preempted, yield, block or nest, and it starved its CPU. Mechanism: `docs/architecture/foreground-exec.md`. **agnsh `>` redirects and pipelines** (agnoshi ≥ 1.9.x run plain commands through `#43`) ⭐ **1.57.7 (S7):** returns the child's **wait status** (§4.9). If the CALLER is killed while waiting, its child is killed too (SIGKILL, even when the caller died of S8's SIGXCPU) and the caller never returns; the child cannot be stopped while its parent waits on it (a tree stop of the caller returns −2). ⭐ **1.57.7 (S8):** −1 when two PT_LOADs share a 2 MB page or the image exceeds the caller's effective memory cap for its child (both folded from −5/−7); consumes the caller's `spawn_limits`#107 arm on every return. A **CPU-capped caller is NOT refused** (D22): its child is capped like any other, and a CPU-cap death returns **280**. |
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
| 95 | `uptime_us` | — | — | — | — | µs / −1 | ⭐ **MICROSECOND monotonic clock, readable with INTERRUPTS DISABLED** (rdtsc-backed; microseconds since the END of calibration, not since boot). ⭐ **1.57.6 — the calibration reference is the ACPI PM timer** when the FADT advertises one (3.579545 MHz fixed hardware, bracketed samples, the median of 5 ~10 ms windows, 3 agreeing within 0.5%), **else (no usable PM timer) live LAPIC ticks, whose 100 Hz reload is itself measured against the PM timer when the early probe found one (1.57.7), or against the PIT** (median of 3 lost-tick-screened windows, agreeing within 2%). Through 1.57.5 it was one 50 ms window of live ticks, which a host CPU quota biased: daimon measured `8319` for a true `3192` at `CPUQuota=50%` (every #95 deadline stretched 2.6×) and a refusal at 25%. The PM timer needs no interrupt delivery, so a throttle only lengthens its window. ⛔ **−1 IS PERMANENT for the boot once production ring 3 runs (kybernet onward)**: the kernel calibrates right after `sti` and makes exactly one more attempt immediately before the scheduler arms (before kybernet); nothing calibrates after that, so this clock never turns valid mid-run on a different epoch. (Only a `TSC_SELFTEST` kernel runs ring 3 between the two attempts — its `/bin/tscp` probe — so only there can a program see −1 and later a valid clock.) A consumer may therefore LATCH its fallback to `uptime_ms`#40 — but on a refused boot that is the tick clock, a degraded fallback, not an equivalent one (see #40). Each refusal is logged with the measured range (`tsc: <tier> REFUSED -- k of n windows usable; measured a..b cycles/us`). A refused first attempt ends `tsc: calibration REFUSED -- one more attempt before userland`; only a refused second attempt ends `tsc: calibration REFUSED -- uptime_us#95 returns -1 for the rest of this boot`, and a successful one prints the usual `tsc: N cycles per microsecond (...)` line after `tsc: second calibration attempt before userland`. ⛔ **Through 1.57.6 `uptime_ms`#40 could not be used by a foreground `run` program**: such programs start with `IF` cleared, so the timer ISR never fires and a tick-driven `#40` is **frozen for the program's entire duration** — that cost two iron burns on the 3D arc's rung-10 gate. Since 1.57.7 `#40` rides the same calibrated TSC (see #40) and is frozen there only on a boot whose calibration refused. `#95` needs no interrupts. Returns **−1** when calibration was refused — never a plausible-looking 0, because a tool that cannot tell "no clock" from "0 µs elapsed" is exactly the failure this replaces. ⚠ **LINUX COLLISION:** `#95` = `umask(mask)`; non-destructive, and the file-level `#ifdef CYRIUS_TARGET_AGNOS` gate is the barrier. |
| 94 | `gpu_recover_op` | arm | — | — | — | 95 / −ve | 3D arc RUNG 5 — the GPU hang/recovery battery. ⛔ The arms that **wedge** the GPU are COMPILED OUT without `GPU_RECOVER`, so a production kernel cannot be asked to hang itself; the **recovery** half is always present, because a shipping kernel must survive a hang it did not ask for. ⭐ Arm D established that **the console survives a dead GPU**. **`/bin/gpuwedge`** |
| 40 | `uptime_ms` | — | — | — | — | ms | monotonic milliseconds since boot, returned in `rax`. No args, no fault surface. **ring-3 timing / DOOM** (1.43.5) ⭐ **1.57.7 — milliseconds of the calibrated TSC since boot** (`uptime_ms_base` + (rdtsc − `tsc_base`) / (`tsc_per_us` × 1000), continuous with ticks × 10 at the calibration instant): it **advances while the BSP runs `IF=0`** (since S3b only the pre-scheduler boot selftests: a foreground `run` and every `#37` child are scheduled IF=1 processes now) and under a host CPU quota (tsc-smoke T10: +200 ms across a 200 ms `IF=0` busy window). **`timer_ticks` × 10 only while/where calibration refused** (#95 = −1): then it is driven by BSP timer ticks only, one per DELIVERED tick with no catch-up — it stops while the BSP runs `IF=0` and LOSES ticks a hypervisor coalesces while it throttles a busy vCPU; since 1.57.7 the 100 Hz reload is measured against the ACPI PM timer (PIT fallback on PM-less boxes), so an idle guest's tick tracks real time even under a quota (tsc-smoke `TSC_QUOTA=25`: reload 10000220 vs 10000236 unthrottled, median tick period 10000 µs). So the "#95 answers −1, fall back to #40" path is still a DEGRADED clock, not an equivalent one. |
| 41 | `sleep_ms` | ms | — | — | — | 0 / −1 | ⭐ **1.57.7 — BLOCKS ONLY THE CALLER** (state 6 in #99) until `sched_clock_us` reaches now + `ms`; every other process runs meanwhile, and a CPU with nothing to run halts IF=1 in its idle. The sleep lasts **≥ `ms` as measured by `uptime_us`#95** (TSC mode) — in practice up to one 10 ms tick longer, because deadlines expire at the first tick at or after them; in tick mode (TSC calibration refused) it is `ms` + up to one tick of padding, and tick-mode deadlines advance only with BSP ticks, so they stall while the BSP runs a long IF=0 syscall. `ms < 0` → −1, `0` → 0 at once, capped at 1 h. **Callers that cannot block keep the old CPU-holding tick loop**: before the scheduler starts (DOOM's pacing, exec-smoke's `/bin/timetest` — both byte-identical), preempt-held kernel code (an `execwait`#37 child blocks like any process since S3b). That loop waits for a deadline in `uptime_ms`#40, so it lasts **≥ `ms` as `uptime_ms`#40 measures it** (1.57.7 S1b: #40 is the calibrated TSC, so that is ≥ `ms` by `#95` too, up to one tick longer; on a refused boot it is `ceil(ms/10)` BSP tick edges, which as `#95` would measure it can end up to one tick early). Before S1b the loop counted tick edges against a polled-PIT reload: `sleep_ms(300)` measured 282.5 ms by #95 under TCG. There is **no "pace without yielding" call**: a caller that must hold its CPU spins on `uptime_us`#95. Until 1.57.7 every caller held its CPU for the whole sleep (`preempt_disable` + sti/hlt) and starved everything else on it (issue 2026-09-23-sleep-ms-holds-the-cpu). **ring-3 timing / DOOM** (1.43.5) |
| 42 | `kbscan` | buf | max | — | — | count | NON-BLOCKING raw-scancode drain into `buf` (up to `max`) for ring-3 input (games need key up/down, not cooked lines). ⚠ It drains `kb_buf` **without regard to cooked-line ownership** (1.57.7): a raw-scancode consumer such as DOOM owns the keyboard by convention. Bounded `hid_poll` window; `preempt_disable()`-gated IF-window. **cyrius-doom** (1.43.x) |
| 43 | `spawn_path` | path (line) or argv blob | len (bits 0-15) \| flags | env blob (opt, 1.44.19) | env len (a4=r10) | pid / −`SPAWN_E_*` | NON-BLOCKING from-disk spawn: loads a static ELF64 from the ext2 root (with argv + optional envp) and creates a **READY ring-3 proc the scheduler picks up**, returning its pid IMMEDIATELY — the caller stays live and reaps it via non-blocking `waitpid`(4). spawn(3)'s shape (copy → boot CR3 → `elf_load_from_file` → restore caller CR3) with no blocking machinery. The kernel half of agnsh `&`. ⭐ **1.57.6 — flags, codes, clean tables, per-process arms (full contract: §4.8).** a2 bit 16 **`SPAWN_F_ARGV`** (0x10000): a1 is `argv0\0argv1\0…argvN\0`, 2..1024 B with the NULs, 1..16 entries, argv[0] (1..255 B) is the path — arguments may contain spaces or be empty. Bit 17 **`SPAWN_F_CLEANFD`** (0x20000): the child's fd table is 0/1/2 (after redirects) + the `#62` redirect srcs + the placed `CH_ENDOW` endowment, nothing else. Bits ≥ 18 → −6. Returns pid ≥ 0 or −`SPAWN_E_*`: **−2 NOPROC** (16-slot table full — retry later), **−3 NOMEM** (also: the child could only get the GLOBAL fd table — the D11 kmalloc fallback; refused for EVERY `#43` since 1.57.7, operator OQ-7 — a legacy child used to run unredirected there, sharing proc 0's fds), **−4 NOENT** (missing, not a regular file, unreadable, no ext2 root), **−5 NOEXEC** (not an ELF64 this kernel loads), **−6 ARGS**; −1 is reserved for "anything else" and no 1.57.6 path produces it. The line form (flags = 0) is unchanged except that **more than 16 tokens is REFUSED (−6)** instead of silently dropped, and its env stays FALLBACK-ONLY; with any flag set a non-zero a3 whose blob fails the gate is refused (−6). **Every return clears the caller's whole spawn-arm state** (`#62` set, `CH_ENDOW` endowment, PTY flag) — before 1.57.6 four refusals cleared nothing and the endowment survived every failure. Backward compatibility: every consumer tests `pid < 0`; any a2 ≥ 65536 returned −1 before (`len > 127`). **agnsh `&`** (1.44.x) ⭐ **1.57.7 (S7):** a caller with a **pending kill cannot create a child** (the call fails; the caller never observes it — it ends at its syscall exit); a child created by a **tree-stopped** caller is born stop-pending. The child's parent identity is (pid, epoch). ⭐ **1.57.7 (S8):** **−5** when two PT_LOADs share a 2 MB page; **−7 `SPAWN_E_LIMIT`** when the image does not fit the effective memory cap (deterministic — never retry); consumes the caller's `spawn_limits`#107 arm on every return. |
| 44 | `sched_yield` | — | — | — | — | 0 | ⭐ **1.57.7 — AN IN-KERNEL YIELD THAT PARKS** (S3.4 + S3.6): it switches to another READY process when one exists (the voluntary switch: `int 0xE0` → the same `do_context_switch` the timer uses; the caller is resumed later, possibly on another CPU); with nothing else READY — keep-current keeps a RUNNING caller, so a plain yield would be a no-op — it **parks the CPU for one hlt** (a designated preempt point; ≤ 1 interrupt period; **not charged**) and offers the CPU once more, so **a poll+yield loop does not spin a core**. Returns 0. Dispatched only via the ring-3 SYSCALL entry stub (not `ksyscall`). The old abandon-frame yield's `ew37_busy`/IF=0 refusals are gone, and since S3b-F2 no ring-3 caller is ever refused (an `execwait`#37 child is an ordinary scheduled process; INV-FG-1's tripwire latches `fg: IF=0 ring-3 caller …` if a caller's saved RFLAGS lacks IF); only kernel contexts (before the scheduler, preempt held, a borrowed CR3) get the successful no-op. ⚠ At -smp > 1 a peer RUNNING on another CPU is not READY here: a yield "towards" it parks this CPU (the ping-pong bench `yield_peer` at -smp 4 measures that). rdx/rsi/rdi/r8–r10 hold handler leftovers, as after every syscall (the abandon-frame used to zero them). agnsh's bg-poll loop yields after unproductive polls. **agnsh `&`** (1.44.16) |
| 45 | `getrandom` | buf | len | flags | — | bytes / 0 (len≤0) / -1 | Zen **RDRAND**, the sole entropy source — never blocks, never short-returns. `flags` accepted and ignored (there is no blocking pool). ⛔ RDRAND zeroes its destination on transient failure, so the kernel retries 10× per qword then whitens from the monotonic timer rather than ever handing back a zeroed buffer. **tls_native** (nonces / key material / GCM IV) |
| 46 | `time_unix` | — | — | — | — | unix seconds UTC / 0 | RTC/CMOS wall clock; `0` when the RTC is mid-update. ⚠ Distinct from `uptime_ms`#40 — that one is monotonic-since-boot for frame pacing, this is the absolute clock TLS cert-validity windows need. **tls_native** |
| 47 | `sock_connect` | dst_ip | dst_port | src_port | — | conn_id 0..7 / -1 | client TCP open. ⭐ **1.57.7 (S6): BLOCKS ONLY THE CALLER** — other processes run while it waits (a real wait, woken by the SYN-ACK, a RST or retransmit exhaustion). The ~8 s ceiling is measured ONCE from entry and never reset by a wake. -1 on RST, timeout, table full, or a duplicate EXPLICIT 4-tuple (an auto-assigned port that collides tries the next). **whirl, setu (retiring — see `planning/ipc.md` §10)** **1.57.7:** may return a conn whose peer already sent FIN (CLOSE_WAIT); #49 then yields the data and -1. A slot recycled under the wait is never returned. An auto-assigned port is unique across CPUs. ⭐ **1.57.7 OWNED:** the connection belongs to the caller's incarnation (pid + epoch); every other process gets -1 from #48/#49/#50/#57/#106 on it (fork/spawn children, a recycled pid). When the owner exits or faults the kernel sends one FIN and releases it. A connection that dies (RST, retransmit exhaustion) **keeps its id until the owner closes it** — close what you open. Any 127.0.0.0/8 destination completes (source 127.0.0.1; the reply comes from the address dialled). A live duplicate 4-tuple gives -1. |
| 48 | `sock_send` | conn_id | buf | len | — | bytes (≤len) / -1 | client TCP send. ⭐ **1.57.7 (S6): BLOCKS ONLY THE CALLER, STREAM-CORRECT.** One segment in flight at EVERY entry: a call that finds an earlier segment still unACKed waits for it first; every segment is sent from the kernel's held copy. Returns `len` when every byte is ACKed; the **committed count (possibly 0) after ~8 s with no ACK progress** (D6 — the in-flight chunk counts as committed); the committed count if the conn dies after something was committed; -1 when nothing was committed and the conn is gone. A zero-window peer that keeps answering is never declared dead (persist). ⚠ **Consumers that ignore the count truncate**: sandhi `src/server/mod.cyr` single-shot `sock_send` (465, 492-493, 512, 547, 582-584, 591), cyrius `lib/ws_server.cyr` (119, 226-227). ⚠ **Write-all loops that treat 0 as fatal abort a live, merely stalled connection**: sandhi `_sandhi_server_plain_write_all` (server/mod.cyr:2325-2333), `sandhi_conn_send_all` (http/conn.cyr:878-886), cyrius `_tn_sock_write_all` (lib/tls_native_conn.cyr:576-584) — 0 means "no progress yet": retry under your own deadline. ✓ daimon `daimon_write_all` already does (its 512 B / 1 ms pacing is obsolete on ≥ 1.57.7). **1.57.7:** allowed in CLOSE_WAIT (after the peer's FIN we may still send: HTTP/1.0 and `shutdown(SHUT_WR)` clients). `-1` if the conn is neither ESTABLISHED nor CLOSE_WAIT at entry; stops early (returns bytes so far) if the slot is closed or recycled. ⭐ **1.57.7 OWNED:** -1 when the id is not the caller's (kernel-owned conns included), checked before anything else (a non-owner gets -1 even for `len <= 0`). A fork child's inherited tagged fd is inert. |
| 49 | `sock_recv` | conn_id | buf | maxlen | — | bytes / 0 / -1 | ⛔ **INVERTED FROM LINUX: `0` = WOULD_BLOCK, `-1` = EOF.** Reading it the Linux way turns "nothing yet" into "connection closed". **1.57.7:** `-1` also once the peer's FIN has been received and every byte before it has been read (CLOSE_WAIT, empty ring). Before 1.57.7 a peer-closed stream answered `0` forever. Data always comes before EOF; a live empty conn still answers 0. ⭐ **1.57.7 OWNED:** -1 when the id is not the caller's (kernel-owned conns included), checked before anything else (even for `maxlen <= 0`); a non-owner's -1 reads as EOF — fail-closed. |
| 50 | `sock_close` | conn_id \| listen_id | — | — | — | 0 / -1 | closes either kind of slot; on a LISTEN slot it also reaps children (1.45.6). **1.57.7:** from CLOSE_WAIT sends our FIN. ⭐ **1.57.7 (S6) GRACEFUL CLOSE:** from ESTABLISHED or CLOSE_WAIT our FIN is **retransmitted until ACKed**; the slot is then KERNEL-HELD (never the caller's: the id is invalid for the caller at once, a second #50 is -1) until the FIN is ACKed and the peer's FIN arrives, or ~47 s of retransmits, or 8 s after the ACK (FIN_WAIT_2), or a claim needs the slot (a held FIN slot never blocks a new connection or listener). A close while a #48 chunk is still unACKed (D6 return, a kill mid-send) keeps that chunk and sends the FIN at its end, so the peer still gets the bytes #48 counted, then EOF (1.57.7 ENDFIX). No TIME_WAIT. On a LISTEN slot, un-accepted children in ESTABLISHED/CLOSE_WAIT get a RST and SYN_RCVD ones are dropped; the reap is atomic with the listener's release. ⭐ **1.57.7 OWNED:** -1 when the id is not the caller's; a second close of the same id returns -1. A fork child's inherited tagged fd is inert: cyrius `sys_close` on it no longer FINs the parent's connection. The owner's #50 on a dead (RST'd) conn releases its held slot (0). |
| 51 | `udp_bind` | port | — | — | — | listener_id 0..7 / -1 | ⭐ **1.57.7 OWNED** by the caller's incarnation; released at exit or fault. The receive buffer is a boot-pool buffer (no heap on bind/unbind). |
| 52 | `udp_send` | dst_ip | (sport<<16)\|dport | buf | len (a4) | bytes / 0 / -1 | uses **a4** — §1a. ⭐ **1.57.7:** returns the **frame length** the driver or the loopback queue accepted (payload + 42) — before 1.57.7 a loopback send returned 0. ⚠ -1 when `src_port` is a UDP port bound by **another** owner (kernel ports included; Linux EADDRINUSE). Unbound source ports are unchanged. |
| 53 | `udp_recv` | listener_id | buf | maxlen | addr_out (a4) | bytes / 0 (none) / -1 | non-blocking; `0` means nothing queued. Uses **a4**. ⭐ **1.57.7:** -1 for a listener that is not the caller's (checked before the range checks and the poll). |
| 54 | `udp_unbind` | listener_id | — | — | — | 0 / -1 | ⭐ **1.57.7:** -1 for a listener that is not the caller's, and for an already-free id (was 0). |
| 55 | `icmp_echo` | dst_ip | — | — | — | RTT ms (≥0) / -1 | ⭐ **1.57.7 (S6): BLOCKS ONLY THE CALLER** (up to ~3 s); concurrent pingers each get their own reply (per-process reply slots); the RTT is measured on the µs clock and returned at 1 ms resolution (10 ms when #95 is -1). ⛔ **ARITY FROZEN AT ONE ARGUMENT** — the caller-chosen deadline lives at `#100`, NOT in an `a2` here. Unused syscall argument registers are not zeroed by cyrius (it pops only as many as the call passes), so reading `a2` would hand every already-shipped one-arg caller a garbage bound. **dig / net-tools** |
| 56 | `sock_listen` | port | — | — | — | listen_id 0..7 / -1 | merges bind+listen, **non-blocking** (1.45.5). ⚠ Whoever binds a port first holds it (one listener per port, whatever the class). **1.57.7:** the duplicate-port check is atomic with the slot claim (no two LISTEN slots on one port across CPUs). Backlog is table-wide: at most 4 SYN_RCVD, and passive children never take the last free slot of the 8, so at least one slot always remains for a non-passive claim (connect or listen). Beyond that a SYN is dropped and the peer retransmits. ⭐ **1.57.7 ADDRESS CLASSES + OWNER:** `arg1 = port (bits 0-15, 1..65535) \| class << 32 (bits 32-39)`; bits 16–31 and 40–63 MUST be 0; class 0 = ANY (net_ip **and** 127/8, new in 1.57.7), class 1 = LOOPBACK (admits only SYNs addressed to 127.0.0.0/8, which can only originate on this host because the wire drops 127/8 — the bind(127.0.0.1) equivalent: a local dial to net_ip is refused); -1 for a bad port, a non-zero reserved bit, class > 1, a duplicate port of either class, or a full table; peer constant `SOCK_LISTEN_LOOPBACK = 0x100000000`; compat: every pre-1.57.7 value decodes to class 0 byte-for-byte; the flagged form fails closed (-1) on an older kernel. The listener and every connection it accepts are owned by the caller. |
| 57 | `sock_accept` | listen_id | — | — | — | conn_id / -1 | **non-blocking**; `-1` covers both WOULD_BLOCK and a bad id (1.45.5). ⚠ Returns the raw `conn_id`, not a VFS fd — accepted sockets are therefore **not** epoll-able (the 1.49.4 fd bridge was partially reverted at 1.53.9). **1.57.7:** wire handshakes complete in interrupt context: a SYN, its ACK and any data are served by the timer/NIC drain with no poller, so a server that waits between polls (`pause`, `sleep_ms`) sees the connection on its next #57 (issue 2026-09-23). Also returns a child whose peer already sent FIN (CLOSE_WAIT): read its data, then #49 answers -1. #57's `net_poll` still drives the loopback queue. ⭐ **1.57.7:** -1 also when the listener is not the caller's (before the poll); the accepted connection is owned by the listener's owner; see #106 for the peer address. |
| 58 | `lseek` | fd | offset | whence | — | new pos / -1 | whence `0`=SET / `1`=CUR / `2`=END. |
| 59 | `flock` | fd | op | — | — | 0 / −1 / −2 | inode-keyed **advisory** lock; op SH=1 / EX=2 / UN=8 (+NB=4). ⭐ **1.57.7 — SH/EX WITHOUT `LOCK_NB` WAIT** (only the caller blocks, state 6 in #99; no timeout; no FIFO fairness — every release wakes every waiter on the inode and they race). `LOCK_NB` → −1 at once when contended. **−2 = the lock table is full** (16 slots; never waits). A **blocking conversion (SH↔EX) drops the caller's old lock first**, as flock(2) does — so a blocking conversion that ends in −1 (a signal abort, the lifecycle step, or an unblockable retry) has already dropped it; a failed `LOCK_NB` conversion keeps it. A caller before the scheduler runs gets `LOCK_NB` semantics (the child of an in-flight `execwait`#37 did too until 1.57.7 S3b-F2; it blocks like any process now — D5's IF=0 clause is superseded, D22). −1 also covers: a bad fd, not an ext2 file, a bad op. ⚠ **The lock owner is the PID, not the open file** (flock(2) ties it to the open-file description; agnos has no OFD layer — a fork child gets COPIES of the fd entries). A `fork` child that locks through an inherited fd while its parent holds the lock therefore WAITS, and deadlocks if the parent then WAIT_BLOCKs on it; a two-lock cycle parks both processes until the lifecycle step's SIGKILL. Released at close, exit and fault kill; each release wakes the inode's waiters. Until 1.57.7 every contended call returned −1 and the kernel comment promised a ring-3 caller that poll-spins, which no caller did (issue 2026-09-23-flock-never-waits-and-no-caller-spins). **agora** (PU shared-world door games), libro/patra |
| 60 | `winsize` | — | — | — | — | (cols<<16)\|rows / -1 | console character grid from the live framebuffer, packed in `rax`: `cols = fb_width()/(8·scale)`, `rows = (fb_height()−FB_CONSOLE_Y0)/(16·scale)`, 8×16 glyph (mirrors `fb_putc`'s cell math); `-1` if the FB isn't up. No args, no buffer (like `uptime_ms`#40) → no pointer/SMAP surface. Lets a ring-3 TUI size to the real console instead of a hardcoded 80×24. **darshana `tty_winsize` on agnos → kii/cyim/chakshu** (1.45.13) |
| 61 | `net_config` | field | — | — | — | packed IPv4 / counter / 0 / -1 | non-blocking getter (`field` 0=ip / 1=netmask / 2=gateway / 3=dns_server), packed IPv4 in `rax`; 0 = unset, -1 = bad field. ⭐ **1.56.48 — fields 4..7 are ICMP COUNTERS, not config**: 4=`icmp_tx` (echo requests sent) · 5=`icmp_rx` (replies matching our id+seq) · 6=`icmp_replies_sent` (inbound pings answered) · 7=`icmp_timeouts` (pings that expired). Free-running, monotonic, never reset; ⭐ 1.57.7 (S6): maintained under `icmp_lock` (consistent across CPUs) — still **diagnostics only, do not build control flow on them**. ⚠ The `<=0 means fall back` rule of fields 0..3 does NOT apply to 4..7, where `0` legitimately means "nothing sent yet". **Why**: a ring-3 prober could not separate "we never transmitted" from "we transmitted and nothing answered" — `tx>0, rx==0` is a network problem, `tx==0` is a local one. The name stayed `net_config` because this syscall already takes a field selector and already returns -1 for an unknown one, so extending it costs no new number. Like `uptime_ms`#40 — no buffer/SMAP surface. Lets a ring-3 resolver use the on-subnet leased DNS instead of an off-subnet fallback. **taar/yo/dig on-subnet resolver** (1.45.16) ⭐ **FIELDS 8-11 ADDED 1.56.59** (telemetry §1 + §2): **8** `tx_packets` · **9** `rx_packets` · **10** `tx_bytes` · **11** `rx_bytes`. Counted at `nic_send`/`nic_poll` (`core/r8169.cyr`) — the one seam r8169 and virtio-net share — so the numbers mean the same thing on iron and under QEMU, and loopback is excluded by construction (it never reaches those functions). **Monotonic since boot, never reset.** Only a transfer the driver ACCEPTED is counted. ⚠ **Extended rather than minted, and that is the point**: `sys_net_config(field)` already passes an arbitrary field id, so a consumer reads these with **no cyrius peer and no toolchain change** — they shipped the day the kernel did. |
| 62 | `exec_redirect` | src_fd \| op<<8 | dst_fd | — | — | 0 / -1 | arm a ONE-SHOT fd redirect for the **caller's next child** (`spawn_path`#43 or `execwait`#37 — not `spawn`#3): the child's writes to `src_fd` (e.g. 1=stdout) route to `dst_fd`'s backend (an open writable file/pipe), so a parent can **capture** a tool's output, then read it back after #37 returns. ⭐ **1.57.7 (S3b): `execwait`#37 applies it into the child's private table, which dies with the child — nothing is restored; a `#37` or `#43` child that could only get the global fd table is refused.** Both fds in [0,32). ⛔ **THIS SENTENCE DESCRIBED A KERNEL THAT NO LONGER EXISTS, AND IT WAS THE SHIPPED CONTRACT UNTIL 1.56.54.** It read: *"Implemented as a save/swap/restore of the **global** `vfs_table` entry … NOT applied to the non-blocking `spawn`#3."* Both clauses are false since *ipc bites 10/11* (1.56.39-40): fd tables are **per-process** (`vfs_fd_table_of`), `#37` resolves the CHILD's table rather than swapping a global, and `spawn_redirect_apply` applies the redirect to `spawn_path`#43 between `proc_set_ring3` and `proc_set_state`. A consumer authored against the old text would expect a redirect on `#43` to be ignored — it is not — and would reason about a global table that per-process fds replaced. ⭐ **1.57.6 — PER-PROCESS, MULTI-PAIR, ACTUALLY ONE-SHOT.** a1 = `src | op<<8`: **op 0** (a1 in [0,32) — every pre-1.57.6 caller) REPLACES the caller's set with this one pair, exactly as before; **op 1 `REDIR_ADD`** (0x100\|src) adds a pair or re-points an already-armed src, at most 4 — −1 when full, or when src is the fd the caller's **armed** `CH_ENDOW` endowment will land on; **op 2 `REDIR_CLEAR`** (exactly 0x200; a2 ignored) empties the set → 0; any other a1 → −1 (every a1 ≥ 32 was −1 before, so no working call changes meaning). Pairs apply **in arm order**, each `dst` read from the CHILD's current table, so `(1 ← w)` then `ADD (2 ← 1)` is shell `2>&1`. The arm belongs to the **calling process** (it was per-CPU, so a preempted caller's redirect could be consumed by another process's spawn on the same CPU) and is consumed by that process's next `#43` or `#37` (both: applied into the child's private table — `#37` restored it around the run until 1.57.7); **every `#43`/`#37` return clears it**, success or refusal — this row promised that before 1.57.6 while it was false for every `#37` refusal and four `#43` refusals. `spawn`#3 does not consume redirects. A pair whose src is the fd a channel endowment was just placed on is skipped (the endowment wins). Fresh processes and `fork`#96 children start with no arms. **cyrius regression capture / shakti session log** (1.46.x; issue `2026-06-15-cyrius-stdlib-missing-syscalls` grp 1 "the high-value one") |
| 63 | `symlink` | target | targetlen | linkpath | linkpathlen (a4) | 0 / -1 | create a symbolic link `linkpath` whose contents are the **TEXT** `target` (NOT resolved as a path — may point at a nonexistent/relative target, so `target` is a bounded user buffer 1..one-ext2-block, not `sc_path_ok`'d). ext2-only (symlinks need inodes; FAT/exFAT → -1); parent+basename via `vfs_ext2_parent`, work by `ext2_symlink` (fast<60 inline / slow=one block, e2fsck-clean). The **ark v2 / agnova prerequisite** (1.51.x DO-FIRST) — `ark_pkg_install` pass-2 creates `.so → .so.N`. ⚠ **TWO-SIDED**: ring 3 can't call it until cyrius adds the matching `sys_symlink`#63 peer (`lib/syscalls_x86_64_agnos.cyr` has `sys_link` but no `sys_symlink`) — cyrius is hands-off, flagged to the user. **ark/agnova** (1.51.0) |
| 70 | `readlink` | path | pathlen | buf | buflen (a4) | bytes / -1 | symlink **introspection** peer of #63: read the **TEXT** target of the symbolic link at `path` into `buf`, returning the target byte length (**not** NUL-terminated, ≤ `buflen`) or -1. The FINAL path component is resolved **NO-FOLLOW** (`ext2_path_lookup_ex` `follow_last=0`) so it reads the LINK, not its target — mid-path symlinks still resolve. -1 when: `path` absent, the final component is not a symlink (`ext2_readlink`'s `0xA000` mode check), the target exceeds `buflen`, or the mount isn't ext2. `buf` is a bounded user range (`is_user_range(buf,buflen)`), like stat's `statbuf`. Next free number after the audio band (#64-69). ⚠ **TWO-SIDED** like #63: needs the cyrius `sys_readlink`#70 peer (hands-off — issue `2026-07-08-cyrius-agnos-sys-readlink-peer`; hapi meanwhile calls it by local number). **hapi status/reconcile** |
| 64 | `snd_open` | — | — | — | — | slot 0..3 / -1 | HDA output stream. Auto-released on proc-exit. ⚠ **Output only** — `snd_open` has no direction argument and the input stream descriptors enumerated at probe are never armed. **mishran, tonegen** |
| 65 | `snd_config` | slot | rate | fmt | — | 0 / -1 | `rate`=48000; `fmt`=(bits<<8)\|ch, e.g. `0x1002` = 16-bit stereo. |
| 66 | `snd_write` | slot | buf | frames | flags (a4) | frames / -1 | **a4 bit 0 = O_NONBLOCK** (copies what fits, may return 0 = WOULD_BLOCK). ⭐ **1.57.7 (S3d): the blocking form BLOCKS ONLY THE CALLER** — it copies what fits and waits (a real BLOCKED state) until the DAC consumes, woken from the BSP tick; cap `frames/480 + 300` ticks (as µs on the scheduler clock); **returns the frames written** (< `frames` at the cap or on an S7 signal). A refused context (pre-scheduler, preempt-held; no ring-3 process since S3b) keeps the old `preempt_disable; sti; hlt` loop, same result. |
| 67 | `snd_close` | slot | — | — | — | 0 / -1 | |
| 68 | `snd_drain` | slot | — | — | — | 0 | ⭐ **1.57.7 (S3d): blocks ONLY THE CALLER until play-out** (a real BLOCKED state woken by the DAC), **1 s cap**; a refused context keeps the old preempt-held loop. Returns 0. |
| 69 | `snd_avail` | slot | — | — | — | free frames / -1 | non-blocking. |
| 71 | `shm_create` | size | — | — | — | id (≥1) / -1 | kernel-owned COPY-based shared buffer, 1-based id (`0` is reserved for "inline"). ⛔ **The page is SYSTEM RAM and the GPU cannot reach it at all** (bus-master is off by design) — a GPU composite from a `#71` buffer is impossible, not merely slow; use `shm_create_gpu`#86. ⚠ `SHM_MAX = 16` slots and `shm_create` calls `pmm_alloc_2mb()` **unconditionally regardless of requested size**. ⚠ **No owner field** — any process may read, write or free any live slot (`shm_slot_valid` checks bounds and a non-zero phys only). **aethersafha, mishran** |
| 72 | `shm_write` | id | user_src | size | — | 0 / -1 | |
| 73 | `shm_read` | id | user_dst | size | — | 0 / -1 | |
| 74 | `shm_free` | id | — | — | — | 0 / -1 | ⚠ **Unauthenticated** — see the owner note on `#71`. |
| 75 | `blk_enum` | buf | cap | — | — | count / -1 | registered block devices. **agnova** (installer) |
| 76 | `blk_open` | tag | mode | — | — | handle / arm-ack (0) / -1 | `mode` 1 = RW and is **capability-gated** (armed by a magic value, not merely requested). |
| 77 | `blk_read` | h | lba | buf | nsec (a4) | nsec / -1 | uses **a4** — §1a. |
| 78 | `blk_write` | h | lba | buf | nsec (a4) | nsec / -1 | ⛔ **GATED** — arm via the `blk_open` magic first. Uses **a4**. |
| 79 | `blk_info` | h | out | — | — | 0 / -1 | Writes a **16-byte** record to `out`, both u64 LE: `capacity_lbas` @0, `lba_bytes` @8. ⚠ **`lba_bytes` IS THIS HANDLE'S STRIDE, not the active backend's — corrected 1.56.60.** It previously stored the module-global `blk_lba_bytes` (whichever backend is live), so on a secondary device the documented recipe in §4.4 — multiply sectors by this field — produced an **8x byte-rate error** with an active NVMe at 4096 and a registered virtio at 512. The 1.56.52 per-tag sweep reached `blk_read_sys`/`blk_write_sys`/`blk_enum_sys` and missed this arm. Reported by chakshu v0.9.9. ⚠ **512 is not a safe consumer default**: `blk_lba_bytes_ok` admits 4096 and only virtio hardcodes 512. ⚠ `capacity_lbas` is still reported **only for the ACTIVE backend** and reads 0 for any other registered handle — a known gap, not a claim of zero capacity. |
| 80 | `blk_close` | h | — | — | — | 0 / -1 | |
| 81 | `readdir` | path | buf | max | — | count / <0 | path-based directory read. ⚠ agnos `#81`; the same number is `fchdir` on Linux — a raw `syscall(81,…)` written from Linux habit silently changes meaning. |
| 96 | `fork` | — | — | — | — | child pid (parent) / 0 (child) / -1 | ⭐ **A SECOND PROCESS RESUMING AT THE CALLER'S OWN FORK SITE** (1.56.54, corrected 1.56.55). The child continues at the parent's post-SYSCALL RIP, on a private COPY of the parent's address space, with `rax == 0`; the parent gets the child's pid. Full copy, **not CoW** — agnos has no write-fault unshare path — via `proc_dup_address_space` over PD[1..510] plus the high-arena PDPT, reusing `proc_map_page`/`_nx`/`_hi` so the `0x87` user bits, NX bit 63 and the KPTI entry-511 stash stay in one place. The child inherits a copy of the parent's fd table (`vfs_fd_inherit`), so an accepted socket survives into the child — the entire point for a fork-per-connection server. ⛔ **DISPATCHED FROM THE RING-3 ENTRY STUB** (`arch/x86_64/syscall_hw.cyr`), **not** `ksyscall`, for the same reason as `#44` and `#14`: the child's resume context comes from the **caller's own syscall frame** at the top of its kernel stack (`sc_frame_get`/`SCF_*`, 1.57.7 — until then a per-CPU capture, `pcpu_sc_entry_regs`, overwritten by the next syscall on that CPU), which exists only on a path reached from the entry stub. ⭐ **1.57.7 — the child's RFLAGS ALWAYS has IF set**: a forked child is an ordinary scheduled process even when its parent runs IF=0 (a foreground `run` child); fork-smoke's foreground-parent arm checks it. A `ksyscall(96)` from in-kernel code would fork a child resuming at whatever ring-3 code last made a syscall, so it refuses a caller on the kernel CR3 (`src_cr3 == 0x1000` → -1). ⚠ **This row did not exist until 1.56.55** and its absence was not caught, because `scripts/check/syscall-abi-check.sh` scans only `kernel/core/syscall.cyr` for the kernel number set — so kernel, doc and cyrius all agreed by mutual absence. The gate's `ENTRY_STUB_ONLY` map now carries 96. ⚠ **TWO-SIDED** like `#63`/`#70`/`#102`: needs the cyrius `SYS_FORK = 96` peer before ring 3 can call it by name — filed as [cyrius `issues/2026-08-30-agnos-sys-fork-96-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-fork-96-peer.md). Ring 3 can call it by raw number meanwhile, which is what `tests/fork/forker.cyr` does. **Consumer: `agora`** (fork-per-connection BBS, `src/main.cyr` `sys_fork()`). ⭐ **1.57.7 (S7):** a caller with a **pending kill cannot create a child** (the call fails; the caller never observes it — it ends at its syscall exit); a child created by a **tree-stopped** caller is born stop-pending. The child's parent identity is (pid, epoch). ⭐ **1.57.7 (S8):** the child inherits the parent's **caps** (memory + CPU, starting at 0 ticks) but **not its `spawn_limits`#107 arm**, and continues the parent's **high-arena cursor** (a fresh cursor started at the floor, on the copied high pages). |
| 97 | `chan_op` | op | a1 | a2 | a3 | 0 / −`CH_E_*` | **THE LOCAL-IPC CHANNEL BAND** (1.56.40, bite 4a) — the sovereign replacement for TCP-on-loopback as the display control transport. One number, op-dispatched, in the `#93`/`MDO_OP_SUPPORTED` style that grew a whole arc with no ABI break. **Implemented: `CH_CAPS` (0x00)** → writes `+0` op-support mask · `+4` region pages · `+8` region-reachable(1/0) to `out_uva` (`out_len ≥ 16`). ⛔ The reachable word is a **live probe under the CALLER's CR3**, not a boot-time cache — the 2 MB region is addressed through `DIRECTMAP_BASE` (the only alias every per-proc CR3 mirrors) and its reachability from a spawned client is a **kill criterion** (`planning/ipc.md` §9.9). ⛔ Every other op returns `−CH_E_BADOP` and **its caps bit is clear** — a client negotiates on the mask, so advertising an unimplemented op is how a client "works" against a kernel that cannot serve it. `CH_HANDOFF`(0x0A)/`CH_DIAL`(0x0B) are RESERVED, bits clear; the kernel will never dial. `CH_ENUM` is deliberately absent from v1 (no consumer). ⚠ `#96` is reserved for `fork`. ⚠ **This row's "Implemented: `CH_CAPS`" is the bite-4a text:** MINT/SEND/RECV/CLOSE/ENDOW (ops 1-5, `CH_OP_SUPPORTED` = 0x3F) have been implemented since 1.56.40 — `kernel/core/syscall.cyr` is authoritative. ⭐ **`CH_ENDOW` (op 5) — 1.57.6:** `CH_ENDOW(fd)` → the child fd it will land on; the arm now belongs to the **calling process** (it was per-CPU and could land in ANOTHER process's child) and is consumed by that process's next child creation — `#43`, `#37` **or `#3`** (the old text said "the next `#43` child"). **`CH_ENDOW(-1)` disarms** the pending endowment and its PTY flag → 0 (was −`CH_E_BADFD`). `CH_CLOSE` of the armed endpoint disarms it. Placement re-checks that the spawner **still owns** the endpoint and that the channel is the **same incarnation** (`chan_epoch`) it armed, so a closed-and-re-minted endpoint can never move into the spawner's child. The fd CH_ENDOW picks is never an armed `#62` redirect src. Every `#43`/`#37` return (and every `#3` return) clears the arm. **aethersafha / setu 0.8.0** |
| 98 | `ptrscan` | buf | max | — | — | 16 / 0 / −1 | **THE POINTER BAND** (1.56.42) — NON-BLOCKING drain of **ONE MERGED** pointer sample into `buf` (`max ≥ 16`). Returns **16** on activity, **0** when idle since the last call, **−1** on a bad range or an undersized buffer. Record, little-endian: `+0` s32 dx · `+4` s32 dy (**positive = DOWN**, as HID reports it) · `+8` u32 buttons (current level, bit0 left / bit1 right / bit2 middle) · `+12` u32 buttons_seen (OR since the last drain). ⭐ **A MERGED SAMPLE, NOT A STREAM** — pointer motion is a RELATIVE DELTA, so the kernel folds every report and hands back the sum; a raw stream would push the coalescing hazard into ring 3, where keeping only the last report of a gap **amplifies** motion ~2-3x. ⭐ `buttons_seen` is what lets a click that starts *and finishes* inside one frame survive. ⛔ **MUST NOT share `kbscan #42`'s ring**: dX = 0x01 decodes through the Set-1 table to HID 0x29 = **Escape**, so a one-pixel move on that pipe would quit the compositor — and it also feeds cyrius-doom. ⚠ No 256-iteration spin (that was for PS/2 IRQ1, deleted 1.56.42); one `hid_poll()` drains the ring. **aethersafha `AE-7` (pending `SYS_PTRSCAN` in cyrius)** |
| 99 | `proclist` | buf | max | — | — | count / −1 | **PROCESS ENUMERATION** (1.56.47) — snapshot of the live process table into `buf`; returns the **number of 64-byte records written**, or **−1** on a bad user range or `max < 1`. `buf` must hold `max * 64` bytes. Record, little-endian, one per live slot, plus one per exited-but-unreaped child as state 7 (1.57.7 S7 — its name, ppid and final ticks kept, rss 0); a record count equals the slots in use, except an orphan in the instant before its self-reap: `+0` u64 pid · `+8` u64 state (1 ready · 2 running · 3 claiming · **6 blocked in a kernel wait** — 1.57.7, `sleep_ms`/`waitpid` WAIT_BLOCK/`flock`, and since S3d the keyboard read, `snd_write`/`snd_drain`; 1.57.7 S7: **4 DYING** (transient) · **5 STOPPED** · **7 ZOMBIE** — an exited, unreaped child, report-only: the table cell stays 0) · `+16` u64 ppid (0 = init) · `+24` u8[32] name (NUL-terminated **basename**, recorded by the ELF loader) · `+56` u64 reserved (always 0). ⭐ **THE FIRST ENUMERATION PRIMITIVE THIS OS HAS HAD.** The ring-3 surface offered `getpid`/`spawn`/`waitpid`/`kill` and there is no procfs, so nothing could answer "what is running?" — a system monitor was not degraded on AGNOS, it was impossible. chakshu rendered its column header and zero rows. ⭐ pid/state/ppid already existed in `proc_table`/`proc_ppid[]` and were merely unreachable; the genuinely new kernel state is the **name** — `struct Process` is pure register state, so a process's only identity was its pid. ⚠ **The reserved field is a decision, not slack**: per-process rss and cpu time are NOT tracked by this kernel and are not invented here; when they are, they land at `+56` and the record size does not change. ⚠ **A snapshot, not a handle** — walked under `preempt_disable`, but a pid may exit before the caller acts; re-probe before signalling. ⚠ Name is NUL-padded to the full 32 bytes so ring 3 cannot read a byte left by a previous occupant of the slot. **cyrius `SYS_PROCLIST` + `sys_proclist` (6.5.x)** ⛔ **`+56` IS SPLIT AS TWO u32 HALVES (1.56.59): low @+56 = cpu ticks, high @+60 = rss pages.** It previously read "reserved — room to add rss/utime", which promised TWO fields for ONE slot: the record is exactly 64 B with `name[32]` at +24..+55, so +56 is the final 8 bytes and whichever field shipped first would have taken the whole u64 and forced the other to a new number. Split while the value is still 0 and nothing reads it. A u64 zero-check still means "neither present", so consumers written against the old wording keep working. ⭐ **`+56` LOW u32 IS NOW LIVE — per-process CPU time in 100 Hz ticks** (1.56.59, telemetry §4; one tick = 10 ms, the same unit `uptime_ms`#40 reports in, so a consumer differences two samples exactly as it does Linux jiffies). Charged in the timer ISR to `proc_current_get()` on **every CPU** — deliberately outside the BSP-only gate that guards `timer_ticks`, because each CPU runs a different process and must charge its own. Zeroed at `proc_alloc_slot`, NOT at reap: clearing at exit would let a monitor sampling between exit and reap see a live process with 0 ticks. Saturates at 2^32-1 rather than wrapping — a wrap gives a negative delta and a nonsense CPU%. ⛔ **HALTED TIME IS EXCLUDED AS OF 1.56.60, AND IT WAS NOT AT 1.56.59.** The tick is skipped when the core is parked in `arch_wait()` (the `hlt` every blocking wait funnels through — `sleep_ms`#41's loop, `kbd_read_blocking`, the idle loop, the net polls), tracked per-CPU in `cpu_in_halt[]`. Before that the quantity was *"share of wall-clock ticks while this slot was current, INCLUDING halted"*, which equals CPU utilisation only for a process that never blocks: `sleep_ms`#41 halted with the caller still current (`preempt_disable`, so `do_context_switch` early-returns), so **a process asleep in a syscall accrued at wall-clock rate and a monitor rendered it at 100%**. (1.57.7: `sleep_ms`#41, `waitpid` WAIT_BLOCK and `flock`#59 now BLOCK — a blocked process (state 6) is not current and accrues no ticks at all; the halt exclusion still matters for the waits that keep the legacy preempt-held loop — and since 1.57.7 (S3d) halted time also includes the idle step and the `#14`/`#44` park (a process parked in `#44` is current but its halted ticks are not charged). ⭐ 1.57.7 (S3b): kernel-launched children (kmain's `run`, kybernet's agnsh) and `#37` children are ordinary scheduled processes and accrue ticks; a `#37` caller or kmain waiting for its child shows state 6.) chakshu v0.9.9 built the CPU% column on this, measured it, and backed the column out. ⚠ Halted time is charged to **nobody** — it is the box being idle, and inventing an owner for it is what produced the wrong number. ⚠ Still a sampling model, not exact: the flag is set just before the `hlt` and cleared just after, so at most one tick per wait can be mis-charged, bounded and in the conservative direction. ⭐ **The HIGH u32 is per-process RSS in 4 KiB pages** (1.56.59, telemetry §5) — **computed**, not accounted: `proc_rss_pages` walks the process's page directory and counts PDEs that are **present AND user**, 512 pages (2 MB) each. ⛔ **The US bit is the entire discriminator**: `proc_create_address_space` fills PD[0..7] kernel-identity and PD[8..63] identity-**supervisor** (`0x83`, no US), so a walk without it reports ~258 MB of kernel window as every process's RSS. Measured: a live process shows `present=129 user=3`. ⚠ Incremental accounting at `proc_map_page` **cannot** work — the ELF loaders map every segment into the new `cr3` before `proc_set_cr3` binds it to a slot, so every charge is dropped. Both halves are written with ONE `store64` so they cannot tear, and both saturate rather than wrap. ⚠ **1.57.6 — an exited, UNREAPED child is not listed but still holds its slot:** agnos has no zombie state (exit#0 leaves the row at state 0 for its parent's `waitpid`), `#99` skips state-0 rows, and `proc_alloc_slot` will not reuse a state-0 row whose parent is alive. So a caller can count fewer records than there are slots in use; `spawn_path`#43's **−2 (`SPAWN_E_NOPROC`)** is the authoritative "table full" answer. ⭐ **1.57.7 (S8):** the `+60` RSS half now **includes the high arena** (PDPT[128..511]) — the same walk the memory cap measures. A foreign walk can return a stale count for a process dying mid-walk, but never dereferences outside the page-table pool. |
| 100 | `icmp_echo_ex` | dst_ip | timeout_ms | — | — | RTT ms (≥0) / -1 | ⭐ **`#55` WITH A CALLER-CHOSEN DEADLINE** (1.56.48). Same contract otherwise: sends one echo request, blocks for the matching reply, returns the round-trip time in **milliseconds**, or **-1** on timeout / NIC down. `timeout_ms <= 0` selects the kernel default (~3 s), so it degrades exactly to `#55`; clamped to 60 s. ⭐ **1.57.7 (S6): BLOCKS ONLY THE CALLER, like #55.** The bound is **never early** and expires at the first timer tick at or after it (≤ ~10 ms late plus wake latency); the RTT is at 1 ms resolution (was: rounded down to whole ticks with a floor of 1). ⛔ **WHY A NEW NUMBER AND NOT AN `a2` ON `#55`**: measured on cyrius 6.5.35, the compiler pops only as many registers as a call site passes, so an unused syscall argument register holds whatever the previous code left there — **not zero**. Widening a live arm would have handed every shipped one-argument caller a garbage bound, presenting as flaky timeouts rather than an ABI break. **Widening a live syscall's arity is not backward compatible on this ABI.** **Unblocks `yo -W` on AGNOS**, which yo accepted on every backend but could not honour here. **cyrius `SYS_ICMP_ECHO_EX` + `sys_icmp_echo_ex` (pending)** |
| 101 | `readdir_at` | path | buf | max | &cursor | count / <0 | ⭐ **`#81` THAT CAN RESUME** (1.56.50). `#81` always starts at the top of the directory and stops at `max`, so a directory with more entries than the caller's buffer is **silently truncated** — indistinguishable from a small directory, which reads as a filesystem fault. `cursor` points at **one i64 the kernel reads AND writes**: in `0` to start, out the byte offset to resume from, or **`-1` when exhausted**. Callers loop `while (cur != -1)`; passing `-1` back returns `0` and changes nothing, so overrunning by one is harmless rather than an infinite restart. ⚠ **The cursor is a BYTE OFFSET into the directory file** — POSIX `telldir`'s cookie, and the only value that survives ext2 directories being a chain of variable-length records; an entry *index* would force a re-walk from the top every call. ⛔ **WHY A NEW NUMBER AND NOT AN `a4` ON `#81`**: the same measured cyrius fact as `#100` — unused syscall argument registers carry stale values, not zero — but sharper here, because this argument is a **pointer the kernel writes through**, so widening `#81` would hand every shipped three-argument caller an arbitrary 8-byte write. Errors: `-1` bad ptr / not ext2, `-2` not found, `-4` not a dir, **`-5` cursor not 4-byte aligned or out of range** (a misaligned offset would parse a record header out of the middle of a filename). **cyrius `SYS_READDIR_AT` + `sys_readdir_at` (6.5.36)** |
| 103 | `statfs` | path | pathlen | buf | — | 0 / -1 | ⭐ **VOLUME CAPACITY FOR A PATH** (1.56.56). Fills a **32-byte** record, all u64 LE: `f_bsize` @0 (bytes per FS block), `f_blocks` @8 (total), `f_bfree` @16 (free), `f_bavail` @24 (free minus the filesystem`s reservation, clamped at 0). Total bytes = `f_blocks * f_bsize`; the kernel reports blocks, userland does the multiply. ⛔ **THE RECORD SIZE IS FROZEN ABI** — the call is 3-arg with no length parameter (like `stat`#33`s hardcoded 48), so there is no room to grow it later; a wider record needs a new number. ⚠ **PATH-BASED, not fd-based**, matching `stat`#33 — a caller need not open a descriptor to read a number. ⚠ **Why a new number and not a flag on #33**: a 4th argument rides `ksyscall_a4` = r10, which the entry stub sets from whatever r10 held at the call — garbage for every existing 3-arg caller, not 0. The same measured fact #100/#101/#102 all cite. ⭐ **All three backends answer it since 1.56.57** — ext2 from its live superblock counter, FAT by scanning the FAT for raw zero entries, exFAT by popcounting the allocation bitmap. `f_bsize` is the backend`s allocation unit (ext2 block / FAT or exFAT cluster). See §4.7 for the per-backend table and costs. ⭐ **The free count is LIVE, not a mount-time snapshot** — the allocator maintains `s_free_blocks_count`, and the gate asserts it DROPS after a write, which a constant-returning implementation cannot do. ⚠ **TWO-SIDED**: needs the cyrius `sys_statfs`#103 peer before ring 3 can call it by name — filed as cyrius [`issues/2026-09-01-agnos-sys-statfs-103-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-09-01-agnos-sys-statfs-103-peer.md), the third of three in that gap alongside `#96 fork` and `#102 lstat`. **Consumer: crab** (M6 sidebar VOLUMES capacity bars). |
| 104 | `mountlist` | buf | max | — | — | count / -1 | ⭐ **THE MOUNT TABLE, ENUMERATED** (1.56.59). Copies the live `{prefix -> backend}` table to ring 3. **80-byte** records, all-u64 header per §4.1: `backend` @0 (**FsBackend** — 1 ext2 · 2 FAT · 3 exFAT; 0 `FS_NONE` is never emitted), `prefixlen` @8 (1..64), `prefix` @16 (**64 bytes, NUL-PADDED** — a consumer must not assume the tail is meaningful). `max` is a RECORD count, and the arm validates it with `is_user_array`, not `is_user_range(buf, max * 80)` — the product wraps, which is verbatim the `#99` defect fixed at 1.56.51. Errors: `-1` bad pointer, wrapping `max`, or `max < 1`. ⭐ **FILED BY crab, AND IT IS AN ENUMERATION BECAUSE A PROBE CANNOT ANSWER IT.** `statfs`#103 answers *is this string mounted*; it cannot answer *are these two the same volume*. `vfs_mount_init` (`core/vfs.cyr:396`) gives an ext2-less boot the SAME backend under BOTH `/` and its `/mnt/...` prefix — its own comment calls them "harmless redundant aliases", harmless to routing but one volume listed twice in a sidebar. The backend id travelling with the prefix is what distinguishes them. ⚠ **A NEW NUMBER, NOT A WIDENING OF `mount`#11**: #11 takes no arguments in this table, and unused argument registers carry STALE values rather than 0 (the `#100`/`#101` rule), so widening it would hand every shipped caller an arbitrary pointer. ⛔ **NO LOCK, AND THAT IS ONLY SAFE WHILE #11 AND #24 ARE NO-OPS** — the table is written once by `vfs_mount_init` and immutable after. The day `mount` becomes real, this arm needs `fs_spin_lock` or it hands ring 3 a torn prefix. Boot-gated by `scripts/harness/mountlist-test.py` + `tests/mountlist/mlist.cyr` (exit 95). |
| 102 | `lstat` | path | pathlen | statbuf | — | 0 / -1 | ⭐ **`stat`#33 THAT DOES NOT FOLLOW THE FINAL SYMLINK** (1.56.53). Same 48-byte struct (§4.1), same failure shape; the only difference is `ext2_path_lookup_ex(..., follow_last=0)` — the lookup mode `readlink`#70 introduced, whose own ABI note above anticipated this exact reuse. Mid-path symlinks still resolve. ext2-only (`FS_EXT2` or -1: FAT/exFAT cannot represent a symlink, and succeeding there would be a surface #33 does not have). ⛔ **MINTED OFF AN IRON BURN, and the consequence was blunter than the roadmap predicted.** That row read *"lstat — blocked on a consumer (kriya `ln -s`, or ark install layouts)"*; the 2026-08-30 validation burn instead produced **two root-filesystem entries that could be listed but neither stat'd nor removed** — `/sl_s` (a slow symlink whose 70-byte target does not exist) and `/lp` (a deliberate self-referential ELOOP link), both leftover `EXT2_WRITE_SELFTEST` fixtures that the bare burn kernel never cleans up. Every `ls` and every `rm` printed `operation not permitted`, five times in one capture. ⭐ **`unlink`#30 was never the problem** — it resolves the parent and calls `ext2_unlink(parent, basename)`, which refuses only directories, and the selftest's own cleanup removes both fixtures happily. What failed is that kriya's `rm` is written to **never** follow a symlink and classifies every operand with `fs_lstat_at` first, which on agnos routed to path-based #33 and followed the link into nothing. kriya's own source says so: *"agnos has no lstat peer at all … agnos roadmap carries `lstat` as unslotted-pending-a-consumer; **this is that consumer**."* ⇒ A correct no-follow userland could not be correct on agnos. ⛔ **WHY A NEW NUMBER AND NOT A FLAG ON #33**: a 4th argument rides `ksyscall_a4` = **r10**, which the entry stub sets unconditionally from whatever r10 held at the call — so it is **garbage** for every existing 3-argument caller, not 0. A flag there would break #33 for every current consumer. Same measured cyrius fact #100 and #101 both cite. ⚠ **TWO-SIDED** like #63 and #70: needs the cyrius `sys_lstat`#102 peer before ring 3 can call it by name — filed in the **cyrius** repo as [`issues/2026-08-30-agnos-sys-lstat-102-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-lstat-102-peer.md). ⛔ **agnos does not modify cyrius**, so the syscall-ABI gate reads `kernel 102 · abi-doc 102 · cyrius 101` and stays red until that peer lands — the same one-sided state `#63` and `#70` shipped in. Ring 3 can call it by raw number meanwhile. **kriya `rm`/`ls`, whirl, ark install layouts** |
| 106 | `sock_peer` | conn_id | — | — | — | (peer_ip<<16)\|peer_port / -1 | ⭐ **THE REMOTE ADDRESS OF A CONNECTION THE CALLER OWNS** (1.57.7). `ip = r >> 16` (the ip4() form), `port = r & 0xFFFF` (host order); a live peer is always ≥ 0x10000. -1: bad id, not yours, CLOSED, LISTEN. One packed return, so no torn (ip, port) pair. Because the wire drops 127/8 and our own address as a SOURCE (the martian filter), `ip >> 24 == 127` or `ip == net_config#61(0)` identifies a local client unforgeably. A NEW NUMBER, not a widening of #57: `a2` of #57 is a stale register in every shipped one-argument caller. a2..a4 never read. ⚠ cyrius `SYS_SOCK_PEER` pending (the ABI gate is red for #106 only until the peer lands). |
| 107 | `spawn_limits` | mem_pages | cpu_ms | — | — | 0 / -1 | ⭐ **ONE-SHOT RESOURCE CAPS FOR THE CALLER'S NEXT CHILD** (1.57.7, S8). A **per-process** arm consumed by the caller's next `spawn`#3 / `execwait`#37 / `spawn_path`#43 on **every** return (success, failure or refusal); re-arming **replaces both fields**; `(0, 0)` disarms; a refused call leaves the earlier arm **unchanged** (both arguments are validated before any store). **Units + ranges:** `mem_pages` = the child's mapped user memory in 4 KiB pages (#99's RSS unit), 0 = none, `0 ≤ a1 ≤ 2^36`, enforced at **2 MB = 512-page granularity** (the loader refuses an image of (distinct PT_LOAD pages + 1) × 512 over it: #43 −7, #3/#37 −1; `mmap`#27 returns 0 past it); `cpu_ms` = the child's CPU budget, 0 = none, `0 ≤ a2 ≤ 2^40`, stored as ceil(ms/10) 100 Hz ticks; at the cap the child dies by **SIGXCPU, wait status 280**. **Inheritance:** the child's cap = `min(creator's own cap, arm)` — an arm can only **lower**; the child's own spawns inherit its effective caps; `fork`#96 copies the caps, never the arm. **Not counted:** shm#71 buffers, #86 GPU slots, channel rings, pipe buffers, page tables, kernel stacks. **Accounting limits (honest):** budgets are **per process** — each child (fork included) starts at 0 ticks, so a capped agent can hand work to a fresh child; 10 ms granularity, sampled at the tick; blocked, stopped and halted time is not CPU time; **kernel time is under-charged while a syscall runs IF=0** (pending ticks coalesce into one at SYSRET); a pinned capped process would die at syscall exit rather than at the tick (none exists: only kmain's children are pinned, and they are uncapped). **A new number, not a widening:** #43's four registers are all used, and #3/#37 need it too. **Probe:** `#107(0, 0)` returns 0 on a supporting kernel and −1 before 1.57.7 (an unknown number). a3/a4 ignored. No authority check (it restricts only the caller's own future children). |

**37 `execwait` is IMPLEMENTED (1.43.0), and a BLOCKING WAIT since 1.57.7 (S3b)** — the ring-3 blocking-exec primitive that lets a userland shell launch an on-disk program (agnoshi's `>` redirects and pipelines; plain `run` goes through `#43`). It used to run the child out of band through `exec_and_wait`, snapshotting the caller's resume context into per-CPU cells (and, until 1.57.6, a second syscall kstack). Since S3b there is no resume-context snapshot and no second stack: the caller sleeps in the kernel on its own stack (WK_CHILD) while the child runs as an ordinary scheduled process, and wakes when the child's death stores state 0 and wakes it. `EXEC_SELFTEST`'s `/bin/exwv` and `/bin/envprop` (post-scheduler) and `scripts/smoke/fg-smoke.sh` gate it. `docs/architecture/foreground-exec.md`.

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
| `AO_NOFOLLOW` | `0x1000` | ⭐ **refuse if the FINAL component is a symlink** (1.56.53) — returns -1 rather than following it, closing the check-then-write TOCTOU that `readlink`#70 could only detect. Routes to `ext2_path_lookup_ex(..., follow_last=0)`. Mid-path symlinks still resolve, matching POSIX `O_NOFOLLOW` and `#70`. ext2 only in effect: FAT/exFAT cannot represent a symlink, so the flag is trivially satisfied there. ⚠ **This row was missing until 1.56.55** — the flag shipped two cuts earlier and reached no doc and no cyrius constant, so ring 3 could not name the thing that had been built for it. ✅ The cyrius peer shipped in **6.6.4** (`lib/syscalls_x86_64_agnos.cyr` `AO_NOFOLLOW = 0x1000` / `AO_EXCL = 0x2000`; `lib/io.cyr` maps `O_NOFOLLOW`/`O_EXCL`/`O_DIRECTORY` onto them). |

### 3.5 🔒 Kernel-owned paths — the `/fonts` namespace (1.57.2)

> **Not a syscall row — a PATH contract on three existing rows.** `open`#7, `stat`#33 and `lstat`#102
> each ask `kfont_path_index()` (`kernel/core/kfont.cyr`) *after* their pointer/length validation and
> the relative→absolute normalisation, and *before* `vfs_resolve_mount` — so two names never reach the
> mount table. No number was minted, so the cyrius peer needs nothing and `syscall-abi-check` stays
> green. **Filed by crab** ([`issues/archived/2026-09-13-no-proportional-face-on-the-target.md`](issues/archived/2026-09-13-no-proportional-face-on-the-target.md));
> operator ruling 2026-09-13: **rekha** is the answer and the face is **kernel-embedded, kashi-style**.
> Invariants behind the contract: [`../architecture/kernel-font-namespace.md`](../architecture/kernel-font-namespace.md).

| Name (absolute, exact bytes) | len | What it is |
|---|---|---|
| `/fonts/default.ttf` | 18 | **the stable name — code against this one** |
| `/fonts/LiberationSans-Regular.ttf` | 33 | the SAME bytes; the real name documents provenance |

**Matching is an exact length + byte compare on the absolute path.** No wildcard, no trailing garbage,
no prefix match: `/fonts/nope.ttf`, `/fonts/default.ttf/`, `/fonts` and `/fonts/` are all **-1** —
⛔ **nothing here answers as a directory**, so `open(AO_DIRECTORY)` + `getdents` on `/fonts` do not
enumerate the face. A client opens it **by name**.

| Verb | On either name | Notes |
|---|---|---|
| `open`#7 | fd / **-1** | `a3` must carry **none** of `AO_WRONLY` `0x1` · `AO_RDWR` `0x2` · `AO_CREAT` `0x100` · `AO_TRUNC` `0x200` · `AO_DIRECTORY` `0x800` (kernel mask `0xB03`) — any one set is **-1**, no fallthrough to disk. Bits outside the mask (`AO_APPEND`, `AO_NOFOLLOW`, `AO_EXCL`) are not tested: `AO_RDONLY` with them set still opens; `AO_EXCL` only means something with `AO_CREAT`, which refuses. The fd is a **`VFS_MEMFILE`** over the kernel's verified copy — O(1), no per-open copy, one of the 32 fd slots like any other. |
| `read`#5 | bytes / **0** | Sequential from offset 0. Returns `min(len, remaining)`; **`0` at EOF** (never `-2` — this is not a pipe). The whole face is **410,820 bytes** (`= 6 × 65536 + 17604`); a 64 KB-request loop sees six full reads, one short one, then 0. ⚠ **A pre-1.57.2 kernel, or one whose verify failed, never gets here: `open` is already -1.** |
| `write`#1 | **-1** | `vfs_write` has no memfile arm. |
| `lseek`#58 | **-1** | `#58` repositions `VFS_EXT2_FILE` only. ⇒ **No rewind, no random access**: read the face front-to-back in one pass; to start over, `close` and `open` again. |
| `close`#6 | 0 | frees the slot; the face is untouched. |
| `stat`#33 / `lstat`#102 | 0 / **-1** | §4.1 struct: `st_mode` **`0x8124`** (regular file, `0100444` octal — read-only for everyone), `st_nlink` **1**, `st_size` **410820**, `st_ino` / `st_blocks` / `st_mtime` **0** (no inode, no disk). `lstat` is identical: nothing here is a symlink. |
| `statfs`#103 | **-1** on a root without the file | ⚠ **NOT intercepted** — routes to the mount table like every other verb, and `#103` requires the path to resolve on its backend. It says nothing about the face. |
| `mountlist`#104 | — | ⛔ **`/fonts` is NOT a mount and never appears here.** `vfs_mount_init` / `FsBackend` are untouched. `tests/mountlist/mlist.cyr:33` refuses backend ids `> 3`, and crab's VOLUMES sidebar draws a capacity bar per row — a font namespace is not a volume, and giving it a backend id would put a phantom disk in every client's sidebar. |

⚠ **SHADOWING, and it is the contract, not a bug.** The intercept covers `open`/`stat`/`lstat` of the
**two names only**. `getdents`#29, `readdir`#81/`#101`, `mkdir`#9, `unlink`#30, `rename`#31,
`statfs`#103 and everything else still route through the mount table and see the disk. So on a root
filesystem with no `/fonts` directory, listing `/fonts` fails while `open("/fonts/default.ttf")`
succeeds — and on a root that *does* carry a `/fonts/default.ttf`, the kernel's face wins for those
three verbs and the on-disk file is reachable only through the verbs that are not intercepted.

**Provenance (what the bytes are).** **Liberation Sans Regular, version 2.1.5, UNMODIFIED** —
410,820 bytes, sha256 `baccc64becc3eb7d104b7c84d99f5314a0a1f896e2b3ea6c2f22fc08d2003bee`, FNV-1a-64
`0xbb32949696578ce6`, `sfntVersion 0x00010000`, 19 tables including `glyf` and `cmap` (`glyf`
outlines, which is what `rekha_font_open` accepts; the format-4 BMP `cmap` requirement is rekha's to
assert). Licensed **SIL Open Font License 1.1** (Copyright (c) 2012 Red Hat, Inc., Reserved Font Name
*Liberation*; digitized data copyright (c) 2010 Google Corporation). The licence text is
`../rekha/fonts/LICENSE-LiberationFonts` and **MUST travel with any redistribution of these bytes** —
the OFL permits bundling with GPL software; it does not permit dropping the notice. The bytes reach the
kernel as rekha 0.3.8's generated `fonts/face_data.cyr` (101 string-literal chunks of 4 KB), cat'd into
the prepped source by `scripts/build.sh` exactly as kashi's `src/font_data.cyr` is.

**The face is exposed ONLY after a boot-time hash check, and `open` returning -1 is a real state.**
`kfont_init` (called from `core/main.cyr` after `cr3_load(0x1000)`, inside the own-PML4 build) copies
the chunks into one 2 MB region and runs `rekha_face_default_verify` — FNV-1a-64 of the assembled
buffer against the generator's hash of the source `.ttf`. Only a match sets `kfont_ready`; every other
outcome leaves all three arms answering **-1** as if the feature had never shipped, and prints why:

| Boot line | Meaning |
|---|---|
| `kfont: /fonts/default.ttf 410820 bytes OK` | verified; the namespace is open (the number is the verified length, printed live) |
| `kfont: face verify FAILED - not exposed` | the assembled bytes do not hash to the source — **closed**; the 2 MB region stays allocated |
| `kfont: no 2 MB region - face not exposed` | `pmm_alloc_2mb_run(1)` returned 0 — closed |
| *(no line)* | a `BOOTCR3_KEEP_GNOBOOT_CR3` build never calls `kfont_init` (no direct map in its boot context) — closed |

⛔ **Why the verify is more than defensive — it has already caught one compiler defect:** cyrius 6.6.3
emitted a string literal of **≥ 65536 bytes read from its second byte on alternate literals**, silently
(`rc=0`, byte count intact, content wrong) — found by exactly this hash while generating the face,
**fixed in cyrius 6.6.4** (a 16-bit length packed into the literal's pool offset; re-measured at 1.57.4:
a single 410,820-byte literal compiles byte-exact), filed as cyrius
[`issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md).
rekha keeps its 4 KB chunks; the kernel still refuses to hand out bytes it has not hashed — the next defect of this class is caught the same way.

⭐ **What a client does.** `open` one of the two names read-only; on **-1, fall back to the bitmap
face (kashi)** and carry on — the guard shape crab's issue already recommended (`if (flen > 0) { … }`)
is the right one, *provided the client then measures on QEMU rather than observing that the host build
compiles*: the same guard is what makes a missing face **quiet**. Read to EOF in one pass (no `lseek`),
`close`, and hand the buffer to `rekha_font_open`. A client that wants its own proof hashes what it got
against `0xbb32949696578ce6`, as the gate does. Do not `statfs` the path, do not list `/fonts`, and do
not expect it in `mountlist`.

**Gate:** `scripts/smoke/kfont-smoke.sh` (in `scripts/sweep.sh`) + `tests/kfont/kfont.cyr` — a real
ring-3 process exec'd from disk opens the face by name, reads all 410,820 bytes through `read`#5,
requires FNV-1a-64 `== 0xbb32949696578ce6` (⭐ **the oracle is the hash, not the length**), checks the
sfnt header and `glyf`+`cmap`, probes **each** refused flag bit individually, refuses `/fonts/nope.ttf`
and `/fonts`, checks `stat`#33 and `lstat`#102 field-for-field, and confirms the alias name serves the
same bytes. **Exit 95**; 80–94 / 96–97 name the failing step. Six mutants (corrupted copy, dropped and
narrowed flag mask, wrong `st_mode`, deleted `lstat` intercept, a ring-3 `#PF`) each fail it.

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

**Per-device disk block (+104..+199), added 1.56.59.** `+104 + tag*16 + 0` sectors read, `+8` sectors written. ⚠ **Indexed by the RAW `BLK_*` tag with slot 0 deliberately wasted** — `blk_reads_by_tag[6]` reserves index 0 (`BLK_NONE`) and uses 1..5, so a consumer reads `+104 + tag*16` with the **same tag `blk_enum`#75 handed it**, no `-1` adjustment to get wrong. 16 bytes of padding is a cheap price for removing an off-by-one from every consumer. ⚠ **Sectors, not bytes**: a byte figure needs the per-device LBA size, which can be 4096 — multiply by `blk_info`#79's reported size. ⛔ **THE COUNTERS MISSED EVERY MULTI-SECTOR TRANSFER UNTIL 1.56.60, i.e. essentially all filesystem I/O.** This text used to read *"this layer moves exactly one sector per call"* and that was false: the only increment sites were `blk_read_on`/`blk_write_on` (the SINGLE-sector calls), while `blk_read_sectors_on`, `blk_write_sectors_on` and the two `*_sectors_direct` fast paths bypassed them — and `ext2_read_block`/`ext2_write_block`, the universal FS block primitives, call exactly those. On a 4096-byte-block ext2 root over NVMe every FS block is 8 sectors and takes the single-command fast path, so **both counters stayed frozen at their boot-probe value for the life of the boot** and a monitor differencing them reported 0 B/s through a heavy copy. Reported by chakshu v0.9.9, which held `disk: n/a` rather than render it. Counting now happens per-branch at each bypassing path (never at the top of a function whose fallback loops through `blk_*_on`, which would double-count). Monotonic since boot, never reset; an unregistered device legitimately reports 0.

⛔ **This band was `blkstats`#105 and THE NUMBER HAS BEEN WITHDRAWN.** It was minted, filed upstream and shipped as a cyrius peer in 6.5.44 before an audit of the whole syscall surface found it never needed a number: a closed 5-value tag enum over flat by-tag arrays is exactly a fixed-size tail block. `blk_info`#79 was correctly ruled out (fixed arity, no length) and the test stopped there instead of continuing to #35. Removed rather than left standing, because **a needless syscall number is permanent surface** — every consumer, every ABI gate and every peer carries it forever. The cyrius removal is filed.

**Per-core block (+40..+103), added 1.56.59.** `+40 + cpu*16 + 0` user, `+8` kernel, 4 CPUs — the hard kernel-wide cap `pcpu_cpu()` enforces. Split by the **privilege of the interrupted context** in the timer ISR, i.e. Linux's `%us`/`%sy`, computed the same way and exact rather than sampled. Monotonic since boot, never reset.

⛔ **The length tiers are 40 / 104 / 200 and each gates its band independently** — a caller passing 40..103 gets exactly the 40-byte struct, 104..199 gets the per-core band and NOT the disk band, 200+ gets both — the arm sizes ONE `is_user_range` from the caller's length before any store, so the extension is all-or-nothing and never a partial write with an error return.

⛔⛔ **There is no `idle` field, and that is the honest answer rather than an omission.** agnos has no single idle loop: `arch_wait()` (a bare `hlt`) is called from ~a dozen polling waits — DHCP retry, `sleep_ms`#41's legacy loop (1.57.7: #41 otherwise BLOCKS its caller, and a blocked process is not current), `kbd_read_blocking`, the NIC drain — so a CPU halted inside a blocking syscall is **indistinguishable at the tick boundary** from one doing real kernel work. Both are ring 0. ⇒ `cpuN_kern` means **"system + halted"**, not "busy-system"; compute utilisation as `user / (user + kernel)`.

✅ **THE WRAPPER LANDED — DO NOT HAND-ROLL A RAW `syscall(35, …)` FOR THE TAIL.** This paragraph said a length-taking overload was still pending upstream, and it was stale from **cyrius 6.5.45** onward: `lib/sys.cyr` exports `fn sys_sysinfo_n(out, len)` plus the named band accessors `sysinfo_cpu_user` / `sysinfo_cpu_kern` / `sysinfo_blk_read` / `sysinfo_blk_write`, and that file is byte-identical from 6.5.45 through 6.6.1. ⛔ As written, the old text sent the next consumer to compute band offsets by hand, which is precisely how a band gets read off by one — chakshu v0.10.1 reported being misdirected by it. `fn sys_sysinfo(out)` still exists, arity 1 and hardcoded to 40; it is the OLD form, not the only form. ⇒ Contrast `net_config`#61, whose peer `fn sys_net_config(field)` genuinely forwards an arbitrary id: its fields 8-11 reached consumers the same day with nothing upstream. **The two are not symmetric, and this doc said they were until an audit caught it.**

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
| `0` | `argc` (≤ 16 — the tokenizer cap, `SPAWN_ARGC_MAX`; it read "≤ 8" until 1.57.6) |
| `8 + i*8` | `argv[i]` → string VA (i = 0 .. argc-1) |
| `8 + argc*8` | argv NULL terminator |
| `8 + (argc+1+j)*8` | **`envp[j]`** → `"KEY=VALUE"` string VA (j = 0 .. envc-1) |
| `8 + (argc+1+envc)*8` | envp NULL terminator |
| `8 + (argc+2+envc)*8` | auxv `AT_NULL` type (0) |
| `8 + (argc+3+envc)*8` | auxv `AT_NULL` val (0) |

The `KEY=VALUE` and argv strings live higher in the stack page (`ELF_INIT_STR` 0x1FF200 .. 0x200000, 3584 B; the control block starts at `ELF_INIT_BLOCK` 0x1FF000 and `rsp` = stack base + 0x1FF000 — these read `0x3100..0x4000` / `0x3008` until 1.57.6, offsets from before the block moved to the top of the 2 MB stack page). Worst case: 1024 B of argv (the `#43` `SPAWN_F_ARGV` blob; the line form is ≤ 127 B) + 1024 B of env = 2048 B, gated by `scripts/check/check-initstack.sh`. **envp (1.43.2):** the kernel stages a uniform default — `envp[0]="HOME=/"`, `envp[1]="PWD=/"` — on every exec (was an empty envp NULL pre-1.43.2). **cyrius half:** `getenv()`'s agnos branch reads `envp[j] = load64(_agnos_init_rsp + 8 + (argc+1+j)*8)` and walks `KEY=VALUE` to NULL — the language-work the cyrius agent owns. Per-process env propagation (threading a caller-supplied env through `execwait`) is a kernel follow-on.

**Per-process env wire format (1.44.19, #37 + #43):** `a3` = user pointer to a flat NUL-separated
`KEY=VALUE\0KEY=VALUE\0` blob, `a4` (= r10) = blob byte length. Caps: **<=1024 bytes, 1..16
entries**, every entry `KEY=...` with `=` at index >=1, trailing NUL required. The caller env
**REPLACES** the default (never merges); `a3==0` (or ANY validation failure) falls back to the
uniform default — **fallback-only, never -1**, because legacy 3-arg callers deliver garbage a3/a4
(the cyrius `syscall()` builtin pops exactly N arg registers; old-agnsh-on-new-kernel is the normal
ESP-only deployment). The kernel copies the blob via a fault-proof page-table walk of the caller's
CR3 (garbage pointers are rejected, not dereferenced). The 16-entry cap is load-bearing: the pointer
array `[ELF_INIT_BLOCK+8, ELF_INIT_STR)` must hold argc (≤ 16) + 3 + envc slots; the combined bound is
enforced in the loader's env loop and gated by `check-initstack.sh`. Consumers: build within the caps
client-side (an oversized blob silently degrades to the default env). ⚠ **1.57.6: in `#43`'s FLAGGED
forms (§4.8) a non-zero a3 whose blob fails the gate is REFUSED (−6)** — the fallback-only rule is kept
only where 2-arg callers can leave garbage in a3/a4 (the unflagged line form, and `#37`).

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

### 4.8 `spawn_path`#43 flags + error codes (1.57.6)

Issues `2026-09-23-spawn-path-args-cannot-contain-spaces`, `-spawn-path-failure-gives-no-reason`,
`-child-inherits-every-fd-and-spawn-arms-leak`. Kernel: `spawn_path_sys` + `spawn_fd_shape`
(`kernel/core/syscall.cyr`), the per-process arms in `kernel/core/proc.cyr`. Invariants:
`docs/architecture/spawn-and-fd-lifetime.md`.

**a2 = len | flags.** Every a2 ≥ 65536 returned −1 before 1.57.6 (`len > 127`), so no previously
working call changes meaning.

| bits | name | meaning |
|---|---|---|
| 0-15 | length | line form: ≤ 127 B (`SPAWN_LINE_MAX`); `SPAWN_F_ARGV`: 2..1024 B (`SPAWN_ARGV_MAX`), NULs included |
| 16 | `SPAWN_F_ARGV` (0x10000) | a1 = `argv0\0argv1\0…argvN\0`: last byte NUL, 1..16 entries (`SPAWN_ARGC_MAX`, = NUL count), argv[0] 1..255 B and is the path opened; later entries may contain spaces or be empty. Copied with the fault-proof page-walking copy. More than 16 entries is **refused**, never truncated. |
| 17 | `SPAWN_F_CLEANFD` (0x20000) | the child's fd table is fds 0/1/2 (after redirects) + every armed `#62` redirect **src** + the placed `CH_ENDOW` endowment; every other slot is zeroed before the child becomes READY (a raw zero of the child's COPY — the parent's fds, sockets and write-back files are untouched). A CLEANFD child that could not get a private fd table is torn down unrun (−3). Combines with `SPAWN_F_ARGV`. |
| ≥ 18 | — | must be 0, else −6 |

**Env (a3/a4).** flags == 0: FALLBACK-ONLY, unchanged (a bad or garbage blob → the default env; 2-arg
callers leave garbage in rdx/r10). Any flag set: a3 == 0 → the default env; a non-zero a3 whose blob fails
the §4.6 gate → **−6**.

**The line form (flags == 0)** is unchanged — "PATH arg arg", split on spaces, no quoting — except that
**more than 16 tokens is REFUSED (−6)**: the 17th argument used to vanish silently. `execwait`#37 refuses
the same line with −1.

**Return: pid ≥ 0, or a negated code** (the `CH_E_*` convention):

| code | name | meaning |
|---|---|---|
| −1 | `SPAWN_E_OTHER` | reserved for "anything else"; no 1.57.6 path produces it |
| −2 | `SPAWN_E_NOPROC` | the 16-slot process table is full — retry once a child is reaped. Deliberately agnos's WOULD_BLOCK value. ⚠ An exited, unreaped child is listed by `proclist`#99 as state 7 (1.57.7 S7); this code remains the authoritative 'table full' answer (an orphan can hold its slot for the instant before it self-reaps). Found only after the whole ELF is loaded (the slot is allocated last), so back off rather than spin. |
| −3 | `SPAWN_E_NOMEM` | out of page-table / 2 MB pages, or a CLEANFD child got no private fd table |
| −4 | `SPAWN_E_NOENT` | the executable is missing, not a regular file (a directory), unreadable (a short read), or there is no ext2 root |
| −5 | `SPAWN_E_NOEXEC` | not an ELF64 this kernel will load: < 64 B or > 16 MB, magic/class, entry < 0x400000, phdr bounds, a PT_LOAD out of bounds, W^X (a PF_W\|PF_X segment), or two PT_LOADs sharing a 2 MB page (1.57.7 S8) |
| −6 | `SPAWN_E_ARGS` | bad a2 (negative, unknown flag, length out of range), a path range the caller does not own, an empty path, a bad argv blob, more than 16 tokens/entries, or (flagged forms only) a bad env blob |
| −7 | `SPAWN_E_LIMIT` | the image does not fit the effective memory cap (`spawn_limits`#107 or inherited); **retrying never helps** — raise the cap (1.57.7 S8; unlike −3, which is back-pressure) |

Every consumer surveyed tests `pid < 0` (daimon, agnoshi, aethersafha, crab, puka, mishran, mirshi,
`tests/chan`); a failed pid passed to `waitpid`#4 lands in the same wait-any arm for −2..−7 as for −1.

**Spawn arms (1.57.6).** The `#62` redirect set and the `CH_ENDOW`#97 endowment are **per-process**:
armed by, and consumed only by, the arming process's next child creation. **Every `#43` and `#37`
return clears the caller's whole arm state, success or refusal**; `spawn`#3 consumes (and on failure
clears) the endowment only. `CH_ENDOW(-1)` and `#62` `REDIR_CLEAR` (0x200) disarm explicitly;
`CH_CLOSE` of the armed endpoint disarms it. Recycled slots and `fork`#96 children start with none.
**The limits arm (1.57.7, S8)** — `spawn_limits`#107 — is per-process too, but it is consumed by `#3`, `#37` **and**
`#43` on every return (at one site, the syscall exit), is not inherited across `fork`#96, and is reset on slot recycle.

**Recipes.**
- Capture stdout + stderr of a child that sees nothing else: `pipe(o)`, `pipe(e)`, `#62(1, o_w)`,
  `#62(0x100|2, e_w)`, `#43(blob, len | SPAWN_F_ARGV | SPAWN_F_CLEANFD, env, envlen)`, close `o_w`/`e_w`,
  read `o_r`/`e_r` to EOF (−2 = "nothing yet", yield).
- `2>&1`: `#62(1, w)` then `#62(0x100|2, 1)`.
- Hand the child one specific fd: `#62(0x100|N, myfd)` = "my `myfd` is the child's fd N" (with CLEANFD,
  the only extra fd it gets).
- On an error path between arming and spawning: `#62(0x200, 0)`, `#97(CH_ENDOW, -1)` and `#107(0, 0)`.

### 4.9 Process lifecycle: wait status, signals, states (1.57.7, S7)

**Wait status** (`waitpid`#4 both forms, `execwait`#37): an exit → `code & 0xFF` · a ring-3 fault → `128 + vector`
(a #PF = 142) · a death by signal → `0x100 | sig` (SIGKILL = 265; S8's SIGXCPU = 280). The kernel's raw exit code
(kmain's `run: exit N`) keeps `128 + sig` (137) for a kill. The helpers the cyrius peer should ship (replacing the
hard-0 stubs in `lib/syscalls_x86_64_agnos.cyr`): `WIFEXITED(s) = (s & 0x100) == 0`, `WEXITSTATUS(s) = s & 0xFF`,
`WIFSIGNALED(s) = (s & 0x100) != 0`, `WTERMSIG(s) = s & 0xFF`.

**kill#16**: 9 ends · 19 stops · 18 continues (+ bit 18) · 0 probes · other 1..63 = a pending bit, no default
action. `KILL_TREE = 0x100` reaches every epoch-validated descendant; a tree STOP that skipped a member returns −2.

| state (`#99` +8) | meaning |
|---|---|
| 1 / 2 / 3 | ready / running / claiming (birth in progress) |
| 4 | DYING — claimed by a killer, or an orphan reaping itself (transient) |
| 5 | STOPPED (`kill 19`; resumed by `kill 18` exactly where it stopped — ring 3, the syscall exit, or inside a kernel wait with the same absolute deadline) |
| 6 | BLOCKED in a kernel wait |
| 7 | ZOMBIE — exited, not yet reaped (report-only; never stored) |

**Latency of a kill**: immediate when the target is off-CPU in ring 3 · ≤ one 10 ms tick while it runs in ring 3
(unpinned) · at the end of its current syscall · at once when it is blocked in a kernel wait. Mechanism:
`docs/architecture/process-lifecycle.md`.

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
