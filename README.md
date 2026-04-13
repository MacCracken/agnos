# AGNOS

> Sovereign operating system kernel. Written in Cyrius. Assembly up. Zero C, zero Rust, zero LLVM.

## Quick Start

```sh
# Build for x86_64
sh scripts/build.sh

# Build for aarch64 (cross-compile)
sh scripts/build.sh --aarch64

# Boot (x86_64) — drops to interactive shell
qemu-system-x86_64 -kernel build/agnos -serial stdio -display none

# Test both architectures
sh scripts/test.sh --all
```

## Architecture

Multi-arch kernel: `kernel/lib/` (2 files), `kernel/arch/x86_64/` (14 files), `kernel/arch/aarch64/` (8 files), `kernel/core/` (17 files), `kernel/user/` (3 files).

```
x86_64:
  multiboot1 header (32-bit ELF)
    -> 32-bit boot shim (identity page tables, enable long mode)
      -> 64-bit Cyrius kernel (cyrius build -D ARCH_X86_64)

aarch64:
  DTB -> EL2-to-EL1 transition
    -> PL011 UART, GIC, ARM generic timer
      -> 64-bit Cyrius kernel (cyrius build -D ARCH_AARCH64 --aarch64)

Common:
  -> serial, GDT+TSS/GIC, IDT, PIC/GIC, Local APIC, timer, keyboard
  -> page tables (16MB), PMM (bitmap), VMM, kernel heap (slab)
  -> process table, context switch, scheduler, SYSCALL/SYSRET
  -> ELF loader, VFS, initrd, device drivers
  -> PCI bus, VirtIO-Net, IP/UDP stack
  -> SMP infrastructure (APIC, IPI, trampoline, per-CPU stacks)
  -> 26 syscalls (signals, epoll, timerfd, pipes)
  -> kybernet (PID 1) -> interactive shell
```

## Subsystems (33)

| Subsystem | Description |
|-----------|-------------|
| Boot | Multiboot1 -> 32-to-64 shim -> long mode (x86_64); DTB -> EL2-to-EL1 (aarch64) |
| Serial I/O | COM1 0x3F8 (x86_64), PL011 UART (aarch64) |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default iretq handler |
| PIC | 8259A remap to IRQ 32+, mask for timer+keyboard |
| Local APIC | MMIO at 0xFEE00000, timer, IPI |
| GIC | ARM GICv2 interrupt controller (aarch64) |
| Timer | APIC periodic ~100Hz (x86_64), ARM generic timer (aarch64) |
| Keyboard | PS/2 full US QWERTY (x86_64), UART RX (aarch64) |
| Page Tables | 2MB huge pages, 16MB identity map, per-process |
| PMM | Bitmap allocator, 4096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Slab allocator, 8 size classes (32-4096B) |
| Process Table | 16 slots, 168B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space |
| VFS | File table, device/memfile/signalfd/epoll/timerfd/pipe types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | ARP, IPv4, UDP send/recv |
| TCP Stack | Connect, send, recv, close, SYN/ACK/FIN state machine |
| VirtIO-Blk | Legacy PCI, sector read/write, DMA buffers |
| FAT16 | Read-only, root directory listing, file open/read |
| Pipes | Circular buffer IPC, read/write ends |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Signals | per-process signals/sigmask, kill, sigprocmask, signalfd |
| Epoll | epoll_create, epoll_ctl, epoll_wait |
| Timerfd | timerfd_create, timerfd_settime |
| Scheduler | Round-robin |
| Shell | 19 commands: help echo ps free cat uptime lspci cpus net send recv tcp pipe blkread ls disk bench test halt |
| kybernet Init | PID 1, 26 kernel syscalls ready |

## Syscalls (26)

| Number | Name | Description |
|--------|------|-------------|
| 0 | exit | Terminate process |
| 1 | write | Write to file descriptor |
| 2 | getpid | Get process ID |
| 3 | spawn | Create new process |
| 4 | waitpid | Wait for child process |
| 5 | read | Read from file descriptor |
| 6 | close | Close file descriptor |
| 7 | open | Open file |
| 8 | dup | Duplicate file descriptor |
| 9 | mkdir | Create directory |
| 10 | rmdir | Remove directory |
| 11 | mount | Mount filesystem |
| 12 | sync | Sync to disk (noop) |
| 13 | reboot | Reboot system |
| 14 | pause | Pause until signal |
| 15 | getuid | Get user ID (always root) |
| 16 | kill | Send signal to process |
| 17 | sigprocmask | Set signal mask |
| 18 | signalfd | Create signal file descriptor |
| 19 | epoll_create | Create epoll instance |
| 20 | epoll_ctl | Control epoll instance |
| 21 | epoll_wait | Wait for epoll events |
| 22 | timerfd_create | Create timer file descriptor |
| 23 | timerfd_settime | Set timer interval |
| 24 | umount | Unmount filesystem |
| 25 | pipe | Create pipe pair |

## Benchmarks (QEMU x86_64, rdtsc)

### Tier 1: Core

| Operation | Cycles |
|-----------|--------|
| PMM alloc+free | 1,467 |
| Heap 32B alloc+free | 1,338 |
| Heap 256B alloc+free | 3,358 |
| Heap 4096B alloc+free | 28,097 |
| Memory write 1MB | 6,976K |

### Tier 2: Subsystems

| Operation | Cycles |
|-----------|--------|
| Syscall (getpid) | 261 |
| Syscall (getuid) | 1,160 |
| Syscall (write 1B) | 6,800 |
| VFS open+read+close | 6,543 |

### Tier 3: Integration

| Operation | Cycles |
|-----------|--------|
| Serial putc | 5,046 |

## Metrics

- **Binary**: 220KB (x86_64), 57KB (aarch64)
- **Source**: ~4,800 lines across 46 files
- **Syscalls**: 26
- **Subsystems**: 33
- **Tests**: 106 kernel assertions (PMM, heap, VFS, proc, syscall, stdlib, initrd)
- **Architecture**: Multi-arch (kernel/lib/ + kernel/arch/x86_64/ + kernel/arch/aarch64/ + kernel/core/ + kernel/user/)
- **Boot time**: <100ms on QEMU
- **Dependencies**: Zero (Cyrius toolchain only, vendored kernel stdlib)

## Size Comparison

| Kernel | Size | Language | Scope |
|--------|------|----------|-------|
| **AGNOS** | **220KB** | Cyrius | 33 subsystems, 26 syscalls, TCP/IP, FAT16, VirtIO, SMP, ELF loader, shell |
| xv6 (MIT) | ~100KB | C | 21 syscalls, no networking, no SMP, no real FS |
| seL4 (verified) | ~30KB | C/Isabelle | Microkernel only — no drivers, no FS, no networking |
| MINIX 3 | ~600KB | C | Microkernel + basic drivers |
| Linux (minimal) | ~1.5MB | C | Barely boots, no drivers |
| Linux (typical) | 10-30MB | C | Desktop-ready |

220KB for a fully functional kernel with TCP/IP, block I/O, filesystem, SMP, signals, epoll, pipes, and an interactive shell — written entirely in Cyrius. No C, no LLVM, no libc.

## Requirements

- Linux x86_64
- Cyrius >= 3.9.8 (`cyrius` build tool from `cyrius` repo)
- QEMU (`qemu-system-x86_64`, `qemu-system-aarch64`) for testing

## License

GPL-3.0-only
