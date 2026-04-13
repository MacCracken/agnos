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

Multi-arch kernel: `kernel/arch/x86_64/` (14 files), `kernel/arch/aarch64/` (5 files), `kernel/core/` (15 files), `kernel/user/` (3 files).

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
  -> 25 syscalls (signals, epoll, timerfd)
  -> kybernet (PID 1) -> interactive shell
```

## Subsystems (27)

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
| VFS | File table, device/memfile/signalfd/epoll/timerfd types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | ARP, IPv4, UDP send |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Scheduler | Round-robin |
| Shell | 12 commands: help echo ps free cat uptime lspci cpus net send bench halt |
| kybernet Init | PID 1, 25 kernel syscalls ready |

## Syscalls (25)

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

## Benchmarks (QEMU x86_64, rdtsc)

### Tier 1: Core

| Operation | Cycles |
|-----------|--------|
| PMM alloc+free | 1,304 |
| Heap 32B alloc+free | 1,207 |
| Heap 256B alloc+free | 3,015 |
| Heap 4096B alloc+free | 26,077 |
| Memory write 1MB | 6,133K |

### Tier 2: Subsystems

| Operation | Cycles |
|-----------|--------|
| Syscall (getpid) | 188 |
| Syscall (getuid) | 726 |
| Syscall (write 1B) | 9,725 |
| VFS open+read+close | 5,912 |

### Tier 3: Integration

| Operation | Cycles |
|-----------|--------|
| Serial putc | 7,510 |

## Metrics

- **Binary**: 98KB (x86_64), 43KB (aarch64)
- **Source**: ~3,000 lines across 33 files
- **Syscalls**: 25
- **Subsystems**: 27
- **Architecture**: Multi-arch (kernel/arch/x86_64/ + kernel/arch/aarch64/ + kernel/core/ + kernel/user/)
- **Boot time**: <100ms on QEMU
- **Dependencies**: Zero (Cyrius compiler only)

## Requirements

- Linux x86_64
- Cyrius >= 3.9.8 (`cyrius` build tool from `cyrius` repo)
- QEMU (`qemu-system-x86_64`, `qemu-system-aarch64`) for testing

## License

GPL-3.0-only
