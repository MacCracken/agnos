# AGNOS Syscall Additions — Required for Kybernet

> Spec for implementing the remaining syscalls so kybernet can run on AGNOS as PID 1.

## Current State

**AGNOS kernel** (`kernel/core/syscall.cyr`) implements 8 syscalls:

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

**Kybernet** calls 27 distinct `sys_*` functions. The AGNOS backend (`agnosys/lib/syscalls_agnos.cyr`) maps them to AGNOS syscall numbers 0-23.

## What Needs Adding

### Tier 1: Trivial stubs (return 0) — No kernel infrastructure needed

These can be added as one-liners in `ksyscall()`. Kybernet calls them but AGNOS doesn't need real implementations yet.

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

### Tier 2: Simple implementations — Small kernel additions

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

### Tier 3: Signal infrastructure — New kernel subsystem

Kybernet uses signals for: child process reaping (SIGCHLD), shutdown (SIGTERM/SIGINT), and power management (SIGPWR/SIGHUP).

**New data structures** (add to `core/proc.cyr`):
```cyrius
# Per-process signal state (add to Process struct or separate array)
var proc_signals[16];        # 16 processes x 1 pending signal mask (64-bit)
var proc_sigmask[16];        # 16 processes x 1 blocked signal mask
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

### Tier 4: Event loop — epoll + timerfd

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

| Tier | Syscalls | Effort | Lines | Kernel changes |
|------|----------|--------|-------|---------------|
| 1: Stubs | 8,9,10,12,15,24 (6) | Trivial | ~6 | One-liners in ksyscall |
| 2: Simple | 11,13,14 (3) | Low | ~20 | mount table, reboot asm, pause hlt |
| 3: Signals | 16,17,18 (3) | Medium | ~60 | proc_signals/sigmask arrays, signalfd VFS type, kill/sigprocmask/signalfd dispatch |
| 4: Events | 19,20,21,22,23 (5) | Medium | ~80 | epoll table, timerfd VFS type, polling loop |
| **Total** | **17 new syscalls** | | **~166 lines** | |

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
