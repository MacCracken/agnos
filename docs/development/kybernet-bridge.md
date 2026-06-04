# Kybernet Bridge Plan

> **Last Updated**: 2026-06-04 (1.41.x sweep — kernel surface grew to 0-33; `open`/`mkdir`/`rmdir`/`sync` made real at v1.41.3 and the post-kybernet additions 26-33 listed; the bridge *design* is unchanged since v1.21.0)
>
> Make kybernet run on both Linux and AGNOS via a switchable syscall backend.
>
> **Status**: Plan landed in v1.21.0 (kybernet 1.0.2). kybernet is now at v1.2.1 (1.2.x arc — edge-boot machinery + BOOT_MINIMAL agnoshi service addition 2026-05-11 eve for closed-beta MVP path). The 26 AGNOS syscalls remain the canonical kybernet → AGNOS interface; see [agnosticos `state.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md) for the live sibling pin and [`syscall-additions.md`](syscall-additions.md) for syscall-implementation details.

## Architecture

```
kybernet (PID 1)
    │
    ├── lib/agnosys/syscalls.cyr      # ifdef dispatcher
    │       ├── syscalls_linux.cyr    # Linux x86_64 ABI (current)
    │       └── syscalls_agnos.cyr    # AGNOS kernel ABI
    │
    └── builds with:
        cyrius build -D LINUX src/main.cyr build/kybernet
        cyrius build -D AGNOS src/main.cyr build/kybernet-agnos
```

## Syscall Status

The original **26-call set (0-25)** kybernet's bridge was built against is implemented (v1.21.0); kybernet can run on AGNOS as PID 1. The **kernel syscall surface has since grown to 0-33 (34 calls)** — `mmap`(27)/`munmap`(28) at v1.35.3/.4, then the v1.41.3 FS group (`getdents`(29)/`unlink`(30)/`rename`(31)/`link`(32)/`stat`(33) + the `open`(7) mount-route + `mkdir`(9)/`rmdir`(10)/`sync`(12) made real + the `a4=r10` 4th-arg ABI extension) — the syscalls the **userland `agnsh` shell** needs now that the interactive shell is exec'd from disk in ring 3 (v1.41.4). kybernet itself still uses only its original subset; the full current surface is the per-slot table in [`syscall-additions.md`](syscall-additions.md). The tier tables below are kybernet's bridge set (numbers + names unchanged); the **Notes** column reflects the current kernel implementation.

### Tier 1: Original (v1.0.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| exit | 0 | Terminate process |
| write | 1 | Via VFS |
| getpid | 2 | Returns proc_current |
| spawn | 3 | ELF load + process create |
| waitpid | 4 | Busy-wait |
| read | 5 | Via VFS |
| close | 6 | Via VFS |
| open | 7 | Mount-routed: ext2 / FAT / exFAT, initrd bare-name fallback; gained `AO_*` flags (v1.41.3) |

### Tier 2: Stubs + simple (v1.1.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| dup | 8 | Return same fd |
| mkdir | 9 | Real, mount-routed to ext2 / FAT / exFAT (v1.41.3; was a noop) |
| rmdir | 10 | Real, mount-routed (v1.41.3; was a noop) |
| mount | 11 | Register VFS mount point |
| sync | 12 | Real: flush ext2 metadata + all block devices (v1.41.3; was a noop) |
| reboot | 13 | cli; hlt |
| pause | 14 | hlt until interrupt |
| getuid | 15 | Return 0 (root) |
| umount | 24 | Noop |

### Tier 3: Signals (v1.1.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| kill | 16 | Set bit in proc_signals |
| sigprocmask | 17 | Per-process signal mask |
| signalfd | 18 | VFS fd type=3, reads pending signals |

### Tier 4: Event loop (v1.1.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| epoll_create | 19 | VFS fd type=4, poll table |
| epoll_ctl | 20 | Add/remove fd from watch list |
| epoll_wait | 21 | Poll watched fds, block on hlt |
| timerfd_create | 22 | VFS fd type=5, timer state |
| timerfd_settime | 23 | Set interval in APIC ticks |

### Tier 5: IPC (v1.11.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| pipe | 25 | Create read/write fd pair, 4KB circular buffer |

### Post-kybernet additions (26-33) -- NOT part of the kybernet bridge
Added after the original kybernet set, for iron-boot diagnostics, memory, and the userland `agnsh` shell's FS surface. kybernet does not call these; listed for surface-completeness (canonical detail in [`syscall-additions.md`](syscall-additions.md)).
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| write_boot_checkpoint | 26 | `CMOS[0x50] = byte` — iron-boot progress diagnostic |
| mmap | 27 | Anonymous, zero-filled, 2 MB-granular (v1.35.3) |
| munmap | 28 | Release an mmap region + free its 2 MB pages (v1.35.4) |
| getdents | 29 | Dir-fd readdir → agnos-native dirent records (v1.41.3) |
| unlink | 30 | Remove a file, mount-routed (v1.41.3) |
| rename | 31 | Within one filesystem; `newlen` via `a4=r10` (v1.41.3) |
| link | 32 | Hard link, ext2-only; `a4=r10` (v1.41.3) |
| stat | 33 | Fills the 48-byte agnos stat struct, ext2 (v1.41.3) |

### Integration -- READY
- Build kybernet with `-D AGNOS`
- Package kybernet ELF in AGNOS initrd
- AGNOS loads kybernet via `elf_load()` + `enter_ring3()`
- kybernet runs as real PID 1 in ring 3
- agnosys dual backend: compiles with `-D LINUX` or `-D AGNOS`

## Syscall Number Mapping

AGNOS uses its own syscall numbers (not Linux's). The `syscalls_agnos.cyr` backend maps:

```
AGNOS syscall table — kybernet's original 26-call subset (full surface is 0-33; see syscall-additions.md):
 0 = exit          8 = dup           16 = kill
 1 = write         9 = mkdir         17 = sigprocmask
 2 = getpid       10 = rmdir         18 = signalfd
 3 = spawn        11 = mount         19 = epoll_create
 4 = waitpid      12 = sync          20 = epoll_ctl
 5 = read         13 = reboot        21 = epoll_wait
 6 = close        14 = pause         22 = timerfd_create
 7 = open         15 = getuid        23 = timerfd_settime
                                     24 = umount
                                     25 = pipe
```
