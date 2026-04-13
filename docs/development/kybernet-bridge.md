# Kybernet Bridge Plan

> Make kybernet run on both Linux and AGNOS via a switchable syscall backend.

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

All 25 AGNOS syscalls are implemented (v1.1.0). kybernet can run on AGNOS as PID 1.

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
| open | 7 | Via initrd |

### Tier 2: Stubs + simple (v1.1.0) -- DONE
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| dup | 8 | Return same fd |
| mkdir | 9 | Noop (initrd read-only) |
| rmdir | 10 | Noop |
| mount | 11 | Register VFS mount point |
| sync | 12 | Noop (no disk) |
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

### Integration -- READY
- Build kybernet with `-D AGNOS`
- Package kybernet ELF in AGNOS initrd
- AGNOS loads kybernet via `elf_load()` + `enter_ring3()`
- kybernet runs as real PID 1 in ring 3
- agnosys dual backend: compiles with `-D LINUX` or `-D AGNOS`

## Syscall Number Mapping

AGNOS uses its own syscall numbers (not Linux's). The `syscalls_agnos.cyr` backend maps:

```
AGNOS syscall table (25 syscalls):
 0 = exit          8 = dup           16 = kill
 1 = write         9 = mkdir         17 = sigprocmask
 2 = getpid       10 = rmdir         18 = signalfd
 3 = spawn        11 = mount         19 = epoll_create
 4 = waitpid      12 = sync          20 = epoll_ctl
 5 = read         13 = reboot        21 = epoll_wait
 6 = close        14 = pause         22 = timerfd_create
 7 = open         15 = getuid        23 = timerfd_settime
                                     24 = umount
```
