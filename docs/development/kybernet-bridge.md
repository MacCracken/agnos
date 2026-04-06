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
        cyrb build -D LINUX src/main.cyr build/kybernet
        cyrb build -D AGNOS src/main.cyr build/kybernet-agnos
```

## Syscall Gap Analysis

kybernet uses 27 syscalls. AGNOS has 8. Breakdown:

### Already implemented in AGNOS (6)
| Syscall | AGNOS # | Notes |
|---------|---------|-------|
| read | 5 | Via VFS |
| write | 1 | Via VFS |
| open | 7 | Via initrd |
| close | 6 | Via VFS |
| getpid | 2 | Returns proc_current |
| waitpid | 4 | Busy-wait |

### Trivial stubs (9) — return success, no real implementation needed
| Syscall | Stub behavior |
|---------|--------------|
| getuid | return 0 (root) |
| getgid | return 0 |
| geteuid | return 0 |
| setuid | return 0 (noop) |
| setgid | return 0 (noop) |
| setgroups | return 0 (noop) |
| sync | return 0 (no disk) |
| pause | hlt loop until interrupt |
| reboot | cli; hlt |

### Simple implementations (4)
| Syscall | Implementation |
|---------|---------------|
| dup | Copy VFS fd entry, return new fd |
| mkdir | Create directory entry in VFS (or noop for initrd) |
| rmdir | Remove directory entry (or noop) |
| mount | Register VFS mount point (simplified) |

### Real infrastructure needed (8)
| Syscall | What AGNOS needs |
|---------|-----------------|
| kill | Signal delivery to process (set flag in proc table) |
| sigprocmask | Per-process signal mask in proc table |
| signalfd | Readable fd that yields pending signals |
| epoll_create | Event poll table (array of watched fds) |
| epoll_ctl | Add/remove fd from poll table |
| epoll_wait | Check watched fds, block until event |
| timerfd_create | Timer that fires on fd (use APIC timer tick) |
| timerfd_settime | Set timer interval |

## Implementation Order

### Phase 1: Stubs + simple (13 syscalls)
Add to AGNOS `core/syscall.cyr`: uid/gid stubs, pause, reboot, sync, dup, mkdir, rmdir, mount.
kybernet can boot but won't have signals or events.

### Phase 2: Signals (3 syscalls)
Add `proc_signals` field to process struct. `kill()` sets a bit. `sigprocmask()` controls which
bits are delivered. `signalfd()` creates a VFS fd that reads from the signal queue.

### Phase 3: Event loop (5 syscalls)
Implement a simple poll table in kernel. `epoll_create()` allocates a poll set. `epoll_ctl()`
adds/removes fds. `epoll_wait()` checks all watched fds (poll, not interrupt-driven).
`timerfd_create/settime` creates a fd that becomes readable when timer ticks expire.

### Phase 4: Integration
- Build kybernet with `-D AGNOS`
- Package kybernet ELF in AGNOS initrd
- AGNOS loads kybernet via `elf_load()` + `enter_ring3()`
- kybernet runs as real PID 1 in ring 3

## Syscall Number Mapping

AGNOS will use its own syscall numbers (not Linux's). The `syscalls_agnos.cyr` backend maps:

```
AGNOS syscall table:
 0 = exit          8 = dup
 1 = write         9 = mkdir
 2 = getpid       10 = rmdir
 3 = spawn        11 = mount
 4 = waitpid      12 = sync
 5 = read         13 = reboot
 6 = close        14 = pause
 7 = open         15 = getuid
                  16 = kill
                  17 = sigprocmask
                  18 = signalfd
                  19 = epoll_create
                  20 = epoll_ctl
                  21 = epoll_wait
                  22 = timerfd_create
                  23 = timerfd_settime
```
