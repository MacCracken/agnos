# AGNOS Syscall Additions — Required for Kybernet

> **Last Updated**: 2026-06-27 (through v1.45.x — surface is now **0–60, 61 syscalls**). Since the v1.44.9 catalogue below (0–42), the **1.45.x net/entropy/clock band** added `getrandom`#45 / `time_unix`#46 / TCP client `sock_connect`#47–`sock_close`#50 / UDP `udp_bind`#51–`udp_unbind`#54 / `icmp_echo`#55 / **server `sock_listen`#56 + `sock_accept`#57** (AGNOS can *accept* inbound TCP — it can *be* a network service) + the file group `lseek`#58 / `flock`#59 / `winsize`#60. The 43–60 band defers to the canonical `ksyscall` dispatch in `syscall.cyr` + the live snapshot in `state.md`; the table below catalogues 0–42. (The 1.43.x graphics/timing/input group `fbinfo`#38 / `blit`#39 / `uptime_ms`#40 / `sleep_ms`#41 / `kbscan`#42 + `execwait`#37, and the v1.44.9 non-blocking `waitpid`#4 poll, are catalogued in the table.)
>
> The 26-call kybernet surface (0–25) was complete at v1.21.0; kybernet (currently v1.2.1) runs on AGNOS as PID 1. The dispatch table has since grown to **43 entries (0–42)** in these rounds:
> - slot **26** `write_boot_checkpoint(byte)` — a CMOS-write diagnostic added during iron-boot bring-up (🩺 not part of the userland shell surface);
> - slot **27** `mmap(length)` (anonymous, 2 MB-granular memory; v1.35.3) + slot **28** `munmap(addr, length)` (its pair; v1.35.4);
> - slots **29–33** + the `open`(7) re-route + the `mkdir`(9)/`rmdir`(10)/`sync`(12) made-real + the **`a4=r10`** 4th-arg ABI extension, all at **v1.41.3** — the FS-syscall buildout for the shell-separation arc (see below);
> - slots **34 `uname` / 35 `sysinfo`** (sovereign sysinfo structs; v1.42.10) + **36 `klog`** (klug log-ring read; v1.42.12) — the 1.42.x sysinfo/klug group; see [`agnos-userland-abi.md`](agnos-userland-abi.md) §3/§4 for the struct/contract detail;
> - slot **37 `execwait(path, pathlen)`** (v1.43.0) — the ring-3 blocking-exec primitive (synchronous `elf_load_from_file` + `exec_and_wait`, caller-resume-context preserved + disjoint second SYSCALL kstack for the nested child); the syscall behind agnoshi's `run` builtin;
> - slots **38 `fbinfo` / 39 `blit` / 40 `uptime_ms` / 41 `sleep_ms` / 42 `kbscan`** — the **1.43.x graphics/timing/input group** behind the first real userland app (FB geometry query, kernel-mediated ring-3→FB pixel copy, monotonic-ms clock, the `sleep_ms` pacing primitive, and a non-blocking keyboard-scancode drain), culminating in **cyrius-doom exec'd from disk in ring 3** (iron-complete, burn 1439 plays DOOM in-game on real Zen, keyboard-driven).
>
> **Semantic change (v1.44.9)**: `waitpid`#4 became a **non-blocking poll** — it returns the child's exit code if the child has exited, or `-2` (WOULD_BLOCK) if it is still alive — so a ring-3 parent can poll a child from ring 3 without holding a blocked-in-kernel frame on the shared syscall kstack. This rides the **1.44.x preemptive-ring-3 arc** (kthread + a `preempt_count` gate, per-process CS/SS in the context switch, preemptive time-slicing of two ring-3 procs each with its own CR3 — QEMU-validated via `scripts/ring3-smoke.sh` + `scripts/thread-smoke.sh`, iron-pending).
>
> **Status**: This doc is the implementation reference for the v1.21.0 kybernet buildout (the tier-by-tier history below) plus the later additions. **The canonical current surface is the `ksyscall` dispatch in `kernel/core/syscall.cyr`** (every `if (num == N)`); the normative interface contract is [`agnos-userland-abi.md`](agnos-userland-abi.md); the live snapshot is [`state.md`](state.md). The 26-call kybernet set was untouched through the entire v1.27.x → v1.34.x arc — security hardening (S1-S13 13/13 at v1.28.0), the Path-C sovereign-struct kernel ABI break (v1.30.0), native xHCI + USB-HID-boot (v1.30.x), the storage stack (v1.31.x), networking (v1.32.x), and the ext2/4 + FAT-family **write** arcs (v1.33.x / v1.34.x) all reused it. The first *new functional* syscalls since v1.21.0 were `mmap` (27, v1.35.3) + `munmap` (28, v1.35.4) — a pure memory facility. The big expansion is **v1.41.3's FS surface** (slots 29–33 + the `open`/`mkdir`/`rmdir`/`sync` upgrades), the syscalls the userland `agnsh` shell (exec'd from disk in ring 3 at v1.41.4) needs to reach the mount-routed VFS now that the interactive shell lives in userland. API expansion stays deliberate.

> **Kernel-gap tracking (2026-06-15, v1.45.10)**: the cyrius **6.2.7** stdlib-completeness pass enumerated the POSIX primitives the cyrius stdlib composes on that AGNOS's surface (0–55) does *not* provide — `fork`/`dup2`/`execve`-argv/`chdir`, BSD `setsockopt`/`getsockopt`/`shutdown`, IPv4 multicast (IGMP), `fcntl(O_NONBLOCK)`/`epoll_create1`. **None blocks AGNOS**: cyrius peer-splits the module or guards the call site so each missing primitive **fail-closes cleanly** (`-1`/`0`/"unsupported") rather than mis-dispatching — this same pass also resolved the sandhi socket-backend cascade filed 2026-06-14. The one addition with real consumer pull is **fd-redirect + argv/envp on `spawn`#3 / `execwait`#37** (capturing subprocess helpers); the socket-option / multicast groups are gated on Phase-B inbound-TCP / mDNS-QM, neither wanted yet. Full gap map + priorities: [`issues/2026-06-15-cyrius-stdlib-missing-syscalls.md`](issues/2026-06-15-cyrius-stdlib-missing-syscalls.md). The structural Linux↔AGNOS **number-overlap hazard** (a raw Linux syscall number silently mis-dispatches — use the cyrius `sys_*` wrappers) is recorded as decision **O5** in [`agnos-userland-abi.md`](agnos-userland-abi.md). *(Surface note: the "0–42" header below predates the live **1.45.x net/entropy/clock band 45–55** — `getrandom`#45 / `time_unix`#46 / TCP `sock_*` #47–50 / UDP #51–54 / `icmp_echo`#55 — that `dig`/`yo` run on.)*

## Current Surface — 0–42 (43 syscalls)

> Rows 34–42 (`uname`/`sysinfo`/`klog`/`execwait` + the graphics/timing/input group `fbinfo`/`blit`/`uptime_ms`/`sleep_ms`/`kbscan`) are also catalogued in [`agnos-userland-abi.md`](agnos-userland-abi.md) §3.2; the `ksyscall` dispatch in `kernel/core/syscall.cyr` is canonical.

The live `ksyscall` dispatch in `kernel/core/syscall.cyr`. `a1/a2/a3/a4` give argument meaning; `→` is the return (`rax` ≥ 0 on success, `-1`/`0-1` on error — **AGNOS does not use Linux `-errno`**). Argument calling convention is `rdi`/`rsi`/`rdx` for `a1`/`a2`/`a3`, and (since v1.41.3) **`r10` for `a4`** — see the ABI extension note. "🩺" = kernel-diagnostic-only, not part of the userland shell surface; "🔧" = stub (number reserved, returns a constant). Normative contract: [`agnos-userland-abi.md`](agnos-userland-abi.md).

| # | Name | a1 | a2 | a3 | a4 | → | Landed | Notes |
|---|------|----|----|----|----|---|--------|-------|
| 0 | `exit` | code | — | — | — | (no return) | v1.0.0 | resumes kernel via `kernel_resume` |
| 1 | `write` | fd | buf | len | — | bytes / -1 | v1.0.0 | `vfs_write`; fd 1/2 → console; FAT/exFAT content-write via the `VFS_SEC_WFILE` write-fd at **v1.41.7** (was ext2/pipe/device-only before) |
| 2 | `getpid` | — | — | — | — | pid | v1.0.0 | returns `proc_current` |
| 3 | `spawn` | elf_addr | elf_size | — | — | pid / -1 | v1.0.0 | loads an **in-memory** ELF (not a path) |
| 4 | `waitpid` | pid | — | — | — | exit_code / -1 / **-2** | v1.0.0 (**non-blocking poll v1.44.9**) | was a busy-wait until `state==0`; since **v1.44.9** a **non-blocking poll** — returns the child's exit code if it has exited, **`-2` (WOULD_BLOCK)** if still alive, `-1` on a bad pid. Reaps the in-memory-spawned child on exit. Lets a ring-3 parent poll from ring 3 without a blocked-in-kernel frame on the shared syscall kstack |
| 5 | `read` | fd | buf | len | — | bytes / -1 | v1.0.0 | `vfs_read`; **fd 0 = blocking keyboard stdin, RAW** since **v1.41.1** (`kbd_read_blocking`; no kernel echo) |
| 6 | `close` | fd | — | — | — | 0 / -1 | v1.0.0 | `vfs_close`; v1.41.11 surfaces the write-fd flush rc |
| 7 | `open` | name | namelen | flags | — | fd / -1 | v1.0.0 (re-route **v1.41.3**) | **mount-routed** (`vfs_resolve_mount` → ext2 / FAT / exFAT, initrd bare-name fallback) since v1.41.3; gained the **flags** arg (a3) — see `AO_*` below. Write-access → a write-back fd (v1.41.7) |
| 8 | `dup` | fd | — | — | — | fd | v1.1.0 | 🔧 returns `a1` unchanged |
| 9 | `mkdir` | path | pathlen | — | — | 0 / -1 | v1.1.0 (**real v1.41.3**) | stub → 0 until v1.41.3; now real, mount-routed (`ext2_mkdir` / `vfs_mkdir_on`) |
| 10 | `rmdir` | path | pathlen | — | — | 0 / -1 | v1.1.0 (**real v1.41.3**) | stub → 0 until v1.41.3; now real, mount-routed (`ext2_rmdir` / `vfs_rmdir_on`) |
| 11 | `mount` | — | — | — | — | 0 | v1.1.0 | 🔧 no-op |
| 12 | `sync` | — | — | — | — | 0 | v1.1.0 (**real v1.41.3**) | stub → 0 until v1.41.3; now `ext2_sync` + `blk_flush` |
| 13 | `reboot` | — | — | — | — | (halts) | v1.1.0 | `serial_println` + `arch_halt` |
| 14 | `pause` | — | — | — | — | 0 | v1.1.0 | `arch_wait` (one hlt) |
| 15 | `getuid` | — | — | — | — | 0 | v1.1.0 | 🔧 always root=0 |
| 16 | `kill` | pid | sig | — | — | 0 / -1 | v1.1.0 | pid 0 protected, self/child only |
| 17 | `sigprocmask` | how | set_ptr | oldset_ptr | — | 0 / -1 | v1.1.0 | how: 0=BLOCK, 1=UNBLOCK |
| 18 | `signalfd` | fd | mask_ptr | flags | — | fd / -1 | v1.1.0 | allocates a `VFS_SIGNALFD` |
| 19 | `epoll_create` | — | — | — | — | fd / -1 | v1.1.0 | allocates a `VFS_EPOLL` (8-watch list) |
| 20 | `epoll_ctl` | epfd | op | fd | — | 0 / -1 | v1.1.0 | op: 1=ADD, 2=clear. max 8 watches |
| 21 | `epoll_wait` | epfd | events_ptr | max | — | nready | v1.1.0 | event rec = `{u32 mask; u64 data}` @ 12 B stride; `max`≤16 |
| 22 | `timerfd_create` | — | — | — | — | fd / -1 | v1.1.0 | allocates a `VFS_TIMERFD` |
| 23 | `timerfd_settime` | fd | flags | val_ptr | — | 0 / -1 | v1.1.0 | `val_ptr`→`{u64 interval_sec; _; u64 initial_sec}` (24 B) |
| 24 | `umount` | — | — | — | — | 0 | v1.1.0 | 🔧 no-op |
| 25 | `pipe` | fds_ptr | — | — | — | 0 / -1 | v1.11.0 | writes 2× u64 fds at `fds_ptr` (16 B); `vfs_create_pipe` |
| 26 | `write_boot_checkpoint` | byte | — | — | — | 0 | iron-boot bring-up | 🩺 writes `CMOS[0x50]=byte&0xFF` |
| 27 | `mmap` | length | — | — | — | base_vaddr / 0 | **v1.35.3** | anonymous, zero-filled, **2 MB-granular**; `0` = MAP_FAILED |
| 28 | `munmap` | addr | length | — | — | 0 / -1 | **v1.35.4** | frees an mmap region (2 MB-granular) |
| 29 | `getdents` | dir_fd | buf | bufsize | — | bytes / 0 (end) / -1 | **v1.41.3** | emits agnos-native dirent records (`reclen`u16/`type`u8/`namelen`u8/`ino`u32/`name`) from a `VFS_EXT2_DIR` fd; ext2 (FAT/exFAT dir-fd is a follow-on). `agnsh`'s `ls` |
| 30 | `unlink` | path | pathlen | — | — | 0 / -1 | **v1.41.3** | mount-routed: ext2 via `vfs_ext2_parent` → `ext2_unlink`; FAT/exFAT → `vfs_delete_on`. `agnsh`'s `rm` |
| 31 | `rename` | old | oldlen | new | newlen | 0 / -1 | **v1.41.3** | within one filesystem (uses **a4** for `newlen`); cross-FS refused; ext2 (`ext2_rename`) + FAT/exFAT (`vfs_rename_on`). `agnsh`'s `mv` |
| 32 | `link` | target | targetlen | linkpath | linkpathlen | 0 / -1 | **v1.41.3** | hard link (uses **a4**), **ext2-only** (`ext2_link`); FAT/exFAT → -1 (O4 — no inodes/hard links). `agnsh`'s `ln` |
| 33 | `stat` | path | pathlen | statbuf | — | 0 / -1 | **v1.41.3** | fills the 48-byte agnos stat struct (`st_mode`/`nlink`/`size`/`ino`/`blocks`/`mtime`) via `ext2_fill_stat`; FAT/exFAT → -1 for now (O4 follow-on). `agnsh`'s `ls -l` |
| 34 | `uname` | buf | len | — | — | 0 / -1 | **v1.42.10** | writes the 64-byte identity struct (4× 16-byte NUL-padded fields: `sysname`/`nodename`/`release`/`machine` from `_AGNOS_VERSION`/`kernel_hostname`). Static boot-time identity. (sysinfo ABI; abi §3.2) |
| 35 | `sysinfo` | buf | len | — | — | 0 / -1 | **v1.42.10** | writes the 40-byte counters struct (5× u64 LE: `uptime_secs`/`totalram`/`freeram`/`procs`/`cpus`). Live volatile snapshot; kernel does the tick→sec / page→byte conversion |
| 36 | `klog` | buf | len | — | — | bytes / -1 | **v1.42.12** | copies the unified klug log ring (`core/klug.cyr`) into the user buffer oldest→newest; when smaller than the log, returns the **newest `len` bytes** (the dmesg tail). Reads only `klug_buf` |
| 37 | `execwait` | path | pathlen | — | — | exit_code / -1 | **v1.43.0** | ring-3 **blocking-exec** primitive: loads a static ELF64 from the active ext2 root, runs it to completion in ring 3, returns its exit code. The first `exec_and_wait` from a live ring-3 SYSCALL frame; the syscall behind agnoshi's `run` builtin |
| 38 | `fbinfo` | buf | len | — | — | 0 / -1 | **v1.43.x** | writes the 24-byte framebuffer-geometry struct (6× u32 LE: `width`/`height`/`pitch`/`bpp=32`/`pixel_format` 0=RGBX/1=BGRX/`flags` bit0=FB present). `fb_phys` is deliberately NOT exposed — pixels reach the FB only through `blit`(#39) |
| 39 | `blit` | src | w | h | dstxy+scale | 0 / -1 | **v1.43.x**, scale **v1.44.20** | kernel-mediated ring-3→FB **pixel copy**: copies a w×h block of 32bpp pixels (packed w*4/row) to the FB at a4 = `(scale<<32)\|(dst_y<<16)\|dst_x`. **a4[39:32] = INTEGER SCALE** (0/1 = 1:1; each px → scale×scale block; scale>16 or w*scale>8192 → -1). Dest rect (w·scale × h·scale) **clipped** to FB bounds; raw copy (no format conversion). Callers MUST use the explicit 4-arg syscall form (a4 high bits are consumed now). The only ring-3 path to the framebuffer |
| 40 | `uptime_ms` | — | — | — | — | ms | **v1.43.x** | monotonic milliseconds since boot in `rax` (no buffer, like `getpid`#2); `timer_ticks * 10` at 100 Hz. The ring-3 frame clock for cyrius-doom (`DG_GetTicksMs`) |
| 41 | `sleep_ms` | ms | — | — | — | 0 / -1 | **v1.43.x** | blocks the caller ~`ms` ms by halting until the 100 Hz timer reaches the target (rounds up to whole ticks). The **pacing primitive** (`DG_SleepMs`) and the only way a ring-3 loop (IF=0) lets time pass |
| 42 | `kbscan` | buf | max | — | — | count | **v1.43.x** | **non-blocking** raw Set-1 scancode drain (make + break, incl. `0xE0` prefixes) for ring-3 game loops (cyrius-doom's `input_poll`); copies up to `max` scancodes buffered since the last call, returns the count. The up/down-aware, never-blocking counterpart to `read`#5 |

### `open` flags (a3) — agnos-native bits (v1.41.3)

Access mode in the low 2 bits, modifiers above. **AGNOS values, not Linux's.** From `agnos-userland-abi.md` §3.3:

| Flag | Value | Meaning |
|------|-------|---------|
| `AO_RDONLY` | `0x0` | read only (default) |
| `AO_WRONLY` | `0x1` | write only |
| `AO_RDWR` | `0x2` | read+write |
| `AO_CREAT` | `0x100` | create if absent (subsumes `touch`) |
| `AO_TRUNC` | `0x200` | truncate to zero on open (with CREAT = `echo >`) |
| `AO_APPEND` | `0x400` | seek to end on each write (TODO — not yet honored) |
| `AO_DIRECTORY` | `0x800` | must be a directory (returns a dir-fd for `getdents`) |

`create` is **not** a separate syscall — file creation is `open(7)` with `AO_CREAT`. `chdir`/`getcwd` are **intentionally not syscalls**: CWD is userland-owned (`agnsh` tracks its own and passes absolute paths to every syscall).

### `a4 = r10` — 4th-argument ABI extension (v1.41.3, decision O2)

`rename`(31) and `link`(32) are inherently 4-arg. v1.41.3 grew the syscall ABI from 3 args to 4, putting the 4th in **`r10`** (the natural 4th-arg register — `SYSCALL` clobbers `rcx`, which is exactly why Linux picks `r10`; AGNOS adopts the *register*, not Linux's numbers). The entry stub (`kernel/arch/x86_64/syscall_hw.cyr`) preserves the user's `r10` into `r9` as its first instruction (before the CR3-switch scratch clobbers `r10`); `r9` arrives as `syscall_handler`'s SysV 6th arg and is stashed into a new `ksyscall_a4` global that `rename`/`link` read. **`ksyscall`'s 4-arg signature and its in-kernel callers are unchanged** — the change is additive, so 3-arg syscalls are byte-identical in behavior; only `rename`/`link` read the 4th.

## Historical State (v1.21.0 kybernet buildout)

**AGNOS kernel** (`kernel/core/syscall.cyr`) implemented the 26-call kybernet surface below (slots 0–25, all tiers complete) by v1.21.0; the later additions (26–33) are catalogued in the table above.

### Original 8 (v1.0.0):

| # | Name | Signature | Implementation |
|---|------|-----------|---------------|
| 0 | exit | exit(code) | Set process state=halted, kernel_resume if saved |
| 1 | write | write(fd, buf, len) | VFS write dispatch |
| 2 | getpid | getpid() | Return proc_current |
| 3 | spawn | spawn(elf_addr, size) | ELF load + process create |
| 4 | waitpid | waitpid(pid) | Busy-wait until process state=0 |
| 5 | read | read(fd, buf, len) | VFS read dispatch |
| 6 | close | close(fd) | VFS close |
| 7 | open | open(name, namelen) | initrd_open |

**Kybernet** calls 27 distinct `sys_*` functions. The AGNOS backend (`agnosys/lib/syscalls_agnos.cyr`) maps them to AGNOS syscall numbers 0-25.

## Implementation Details

### Tier 1: Trivial stubs (return 0) -- DONE

One-liners in `ksyscall()`. Kybernet calls them but AGNOS doesn't need real implementations.

| # | Name | Signature | Stub behavior | Why stub is OK |
|---|------|-----------|--------------|----------------|
| 8 | dup | dup(fd) | Return fd (noop) | Console redirect, not critical |
| 9 | mkdir | mkdir(name, len) | Return 0 | Initrd is read-only |
| 10 | rmdir | rmdir(name, len) | Return 0 | No writable FS |
| 12 | sync | sync() | Return 0 | No disk to sync |
| 15 | getuid | getuid() | Return 0 (root) | Single-user system |
| 24 | umount | umount(target, flags) | Return 0 | No real mounts |

**Implementation**: Add to `ksyscall()` in `kernel/core/syscall.cyr`:
```cyrius
if (num == 8) { return arg1; }           # dup: return same fd
if (num == 9) { return 0; }              # mkdir: noop
if (num == 10) { return 0; }             # rmdir: noop
if (num == 12) { return 0; }             # sync: noop
if (num == 15) { return 0; }             # getuid: root
if (num == 24) { return 0; }             # umount: noop
```

### Tier 2: Simple implementations -- DONE

| # | Name | Signature | Implementation | Kernel changes |
|---|------|-----------|---------------|---------------|
| 11 | mount | mount(src, tgt, fstype) | Register mount point in VFS | Add mount table to `core/vfs.cyr` (array of {path, type}) |
| 13 | reboot | reboot(cmd) | cli; hlt or reset | Add to `ksyscall`, inline asm `cli; hlt; jmp $` |
| 14 | pause | pause() | hlt loop until signal | `while (no_pending_signal) { hlt; }` — initially just hlt once and return |

**Implementation for reboot** in `ksyscall()`:
```cyrius
if (num == 13) {
    serial_println("AGNOS: reboot", 13);
    asm { cli; hlt; 0xEB; 0xFE; }
    return 0;
}
if (num == 14) {
    asm { hlt; }  # pause until interrupt
    return 0;
}
```

**Implementation for mount**: Add a `mount_table` global array in `core/vfs.cyr`:
```cyrius
var mount_table[64];  # 8 mounts x 8 bytes (just store the target path pointer)
var mount_count = 0;

fn vfs_mount(target) {
    if (mount_count >= 8) { return 0 - 1; }
    store64(&mount_table + mount_count * 8, target);
    mount_count = mount_count + 1;
    return 0;
}
```

### Tier 3: Signal infrastructure -- DONE

Kybernet uses signals for: child process reaping (SIGCHLD), shutdown (SIGTERM/SIGINT), and power management (SIGPWR/SIGHUP).

**New data structures** (add to `core/proc.cyr`):
```cyrius
# Per-process signal state (add to Process struct or separate array)
var proc_signals[128];       # 16 processes x 8 bytes (64-bit pending signal mask)
var proc_sigmask[128];       # 16 processes x 8 bytes (64-bit blocked signal mask)
```

| # | Name | Signature | Implementation |
|---|------|-----------|---------------|
| 16 | kill | kill(pid, sig) | Set bit in target process's pending signals: `proc_signals[pid] |= (1 << sig)` |
| 17 | sigprocmask | sigprocmask(how, set, oldset) | Modify `proc_sigmask[current]`: SIG_BLOCK (OR), SIG_UNBLOCK (AND NOT), SIG_SETMASK (assign) |
| 18 | signalfd | signalfd(fd, mask, flags) | Create a VFS fd (type=3=signalfd) that, when read, returns the next pending signal number matching the mask. `vfs_read` for type=3: scan `proc_signals[current] & mask`, return signal number, clear bit. |

**Implementation for kill**:
```cyrius
if (num == 16) {
    # kill(pid=arg1, sig=arg2)
    if (arg1 >= proc_count) { return 0 - 1; }
    var mask = load64(&proc_signals + arg1 * 8);
    store64(&proc_signals + arg1 * 8, mask | (1 << arg2));
    return 0;
}
```

**Implementation for sigprocmask**:
```cyrius
if (num == 17) {
    # sigprocmask(how=arg1, set=arg2, oldset=arg3)
    var old = load64(&proc_sigmask + proc_current * 8);
    if (arg3 != 0) { store64(arg3, old); }
    var new_mask = load64(arg2);
    if (arg1 == 0) { new_mask = old | new_mask; }         # SIG_BLOCK
    if (arg1 == 1) { new_mask = old & (~new_mask); }      # SIG_UNBLOCK
    # arg1 == 2: SIG_SETMASK, new_mask already correct
    store64(&proc_sigmask + proc_current * 8, new_mask);
    return 0;
}
```

**Implementation for signalfd**:
```cyrius
if (num == 18) {
    # signalfd(fd=arg1, mask=arg2, flags=arg3)
    # Create a new VFS entry of type 3 (signalfd)
    # data field stores the signal mask
    var idx = vfs_alloc();
    if (idx < 0) { return 0 - 1; }
    var base = &vfs_table + idx * 32;
    store64(base, 3);           # type = signalfd
    store64(base + 8, 0);      # pos (unused)
    store64(base + 16, 0);     # size (unused)
    store64(base + 24, load64(arg2));  # data = signal mask
    return idx;
}
```

**Update `vfs_read`** to handle type=3 (signalfd):
```cyrius
if (ftype == 3) {
    # Signalfd read: return pending signal matching mask
    var sigmask = load64(base + 24);
    var pending = load64(&proc_signals + proc_current * 8);
    var matched = pending & sigmask;
    if (matched == 0) { return 0; }  # no pending signals
    # Find lowest set bit (first pending signal)
    for (var s = 1; s < 32; s = s + 1) {
        if ((matched & (1 << s)) != 0) {
            # Clear the signal
            store64(&proc_signals + proc_current * 8, pending & ~(1 << s));
            # Write signalfd_siginfo (128 bytes on Linux, we use 8 bytes: just signo)
            store32(buf, s);
            return 4;
        }
    }
    return 0;
}
```

### Tier 4: Event loop -- DONE

Kybernet's event loop uses epoll to wait on signalfd + timerfd simultaneously.

**New data structures**:
```cyrius
# Epoll instance: array of watched {fd, events, token} entries
var epoll_table[64];     # 8 epoll instances x 8 watched fds (simplified)
var epoll_count = 0;
```

| # | Name | Signature | Implementation |
|---|------|-----------|---------------|
| 19 | epoll_create | epoll_create(flags) | Allocate an epoll instance (index into epoll_table). Return epoll fd via VFS (type=4). |
| 20 | epoll_ctl | epoll_ctl(epfd, op, fd, event) | Add/remove fd from epoll's watch list. Store {fd, events} pair. |
| 21 | epoll_wait | epoll_wait(epfd, events, max, timeout) | Poll all watched fds. For signalfd: check proc_signals. For timerfd: check timer expiry. Write matching events to `events` buffer. Block (hlt) if no events and timeout != 0. |
| 22 | timerfd_create | timerfd_create(clockid, flags) | Create VFS fd (type=5=timerfd) with associated timer state. |
| 23 | timerfd_settime | timerfd_settime(fd, flags, new, old) | Set timer interval. Store {interval_ticks, next_fire_tick} in VFS entry data. |

**Implementation for epoll_create**:
```cyrius
if (num == 19) {
    # Create VFS fd of type=4 (epoll)
    var idx = vfs_alloc();
    if (idx < 0) { return 0 - 1; }
    var base = &vfs_table + idx * 32;
    store64(base, 4);        # type = epoll
    store64(base + 8, 0);   # watched fd count
    # Allocate watch list (use kmalloc for 8 entries x 16 bytes)
    var wlist = kmalloc(128);
    store64(base + 24, wlist);
    return idx;
}
```

**Implementation for epoll_ctl**:
```cyrius
if (num == 20) {
    # epoll_ctl(epfd=arg1, op=arg2, fd=arg3, event=... via stack)
    var ebase = &vfs_table + arg1 * 32;
    var wlist = load64(ebase + 24);
    var wcount = load64(ebase + 8);
    if (arg2 == 1) {  # EPOLL_CTL_ADD
        var ev_events = load32(arg3);  # event struct: {u32 events, u64 data}
        var ev_data = load64(arg3 + 4);
        store64(wlist + wcount * 16, arg3);       # fd (actually arg3 is event ptr... fix needed)
        store64(wlist + wcount * 16 + 8, ev_data);
        store64(ebase + 8, wcount + 1);
    }
    return 0;
}
```

**Implementation for epoll_wait** (simplified polling):
```cyrius
if (num == 21) {
    # epoll_wait(epfd=arg1, events=arg2, max=arg3)
    var ebase = &vfs_table + arg1 * 32;
    var wlist = load64(ebase + 24);
    var wcount = load64(ebase + 8);
    var found = 0;
    # Check each watched fd for readiness
    for (var i = 0; i < wcount; i = i + 1) {
        var wfd = load64(wlist + i * 16);
        var wdata = load64(wlist + i * 16 + 8);
        var wbase = &vfs_table + wfd * 32;
        var wtype = load64(wbase);
        var ready = 0;
        if (wtype == 3) {  # signalfd: ready if pending signals match mask
            var mask = load64(wbase + 24);
            var pending = load64(&proc_signals + proc_current * 8);
            if ((pending & mask) != 0) { ready = 1; }
        }
        if (wtype == 5) {  # timerfd: ready if timer expired
            var next_fire = load64(wbase + 16);
            if (timer_ticks >= next_fire) { ready = 1; }
        }
        if (ready == 1) {
            if (found < arg3) {
                # Write epoll_event: {u32 events=EPOLLIN, u64 data=wdata}
                store32(arg2 + found * 12, 1);       # EPOLLIN
                store64(arg2 + found * 12 + 4, wdata);
                found = found + 1;
            }
        }
    }
    if (found == 0) { asm { hlt; } }  # block until interrupt if no events
    return found;
}
```

**Implementation for timerfd**:
```cyrius
if (num == 22) {
    # timerfd_create
    var idx = vfs_alloc();
    if (idx < 0) { return 0 - 1; }
    var base = &vfs_table + idx * 32;
    store64(base, 5);        # type = timerfd
    store64(base + 8, 0);   # interval (in timer ticks)
    store64(base + 16, 0);  # next fire tick
    store64(base + 24, 0);  # expiry count
    return idx;
}
if (num == 23) {
    # timerfd_settime(fd=arg1, flags=arg2, new_value=arg3)
    var base = &vfs_table + arg1 * 32;
    # new_value is itimerspec: {interval_sec, interval_nsec, initial_sec, initial_nsec}
    var interval_sec = load64(arg3);
    var initial_sec = load64(arg3 + 16);
    # Convert seconds to timer ticks (~100 ticks/sec)
    store64(base + 8, interval_sec * 100);
    store64(base + 16, timer_ticks + initial_sec * 100);
    return 0;
}
```

## Summary

The kybernet buildout (26-call surface, slots 0–25 = 8 original + 18 new) is fully implemented. Slots 26–42 were added later — see the **Current Surface** table above for the complete 0–42 (43-syscall) list with per-slot landing versions.

| Tier | Syscalls | Status |
|------|----------|--------|
| 1: Stubs | 8,9,10,12,15,24 (6) | DONE (v1.1.0) — `mkdir`(9)/`rmdir`(10)/`sync`(12) **made real at v1.41.3** |
| 2: Simple | 11,13,14 (3) | DONE (v1.1.0) |
| 3: Signals | 16,17,18 (3) | DONE (v1.1.0) |
| 4: Events | 19,20,21,22,23 (5) | DONE (v1.1.0) |
| 5: IPC | 25 (1) | DONE (v1.11.0) |
| 6: Diagnostic | 26 `write_boot_checkpoint` (1) | DONE (iron-boot bring-up) |
| 7: Memory | 27 `mmap`, 28 `munmap` (2) | DONE (v1.35.3 / v1.35.4) |
| 8: FS surface | 29 `getdents`, 30 `unlink`, 31 `rename`, 32 `link`, 33 `stat` (5) + `open`(7) re-route + `a4=r10` | DONE (v1.41.3) |
| 9: Sysinfo / klug | 34 `uname`, 35 `sysinfo`, 36 `klog` (3) | DONE (v1.42.10 / v1.42.12) — QEMU-validated, iron-pending |
| 10: Graphics / timing / input | 37 `execwait`, 38 `fbinfo`, 39 `blit`, 40 `uptime_ms`, 41 `sleep_ms`, 42 `kbscan` (6) | DONE (v1.43.x) — **iron-complete** (burn 1439 plays cyrius-doom in ring 3 on Zen) |

> **Semantic change beyond the tiers**: `waitpid`#4 became a **non-blocking poll** at **v1.44.9** (returns exit code, or `-2`=WOULD_BLOCK if the child is alive) — part of the **1.44.x preemptive-ring-3** arc (kthread + `preempt_count` gate, per-process CS/SS, two ring-3 procs time-sliced each with its own CR3). QEMU-validated (`ring3-smoke.sh` + `thread-smoke.sh`), iron-pending.

## Files to modify

1. **`kernel/core/syscall.cyr`** — add all new `if (num == N)` cases
2. **`kernel/core/vfs.cyr`** — add types 3 (signalfd), 4 (epoll), 5 (timerfd) to `vfs_read`
3. **`kernel/core/proc.cyr`** — add `proc_signals[16]` and `proc_sigmask[16]` arrays

## Test plan

After implementing each tier:
1. `sh scripts/build.sh` — kernel compiles
2. `sh scripts/test.sh` — regression tests pass
3. Boot on QEMU, verify shell still works
4. Build kybernet with `-D AGNOS`, package as ELF in initrd
5. AGNOS loads kybernet, kybernet boots → signals work → event loop runs
