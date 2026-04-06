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

```
multiboot1 header (32-bit ELF)
  -> 32-bit boot shim (identity page tables, enable long mode)
    -> 64-bit Cyrius kernel
      -> serial, GDT+TSS, IDT, PIC, Local APIC, timer, keyboard
      -> page tables (16MB), PMM (bitmap), VMM, kernel heap (slab)
      -> process table, context switch, scheduler, SYSCALL/SYSRET
      -> ELF loader, VFS, initrd, device drivers
      -> PCI bus, VirtIO-Net, IP/UDP stack
      -> SMP infrastructure (APIC, IPI, trampoline, per-CPU stacks)
      -> kybernet (PID 1) -> interactive shell
```

## Subsystems (27)

| Subsystem | Description |
|-----------|-------------|
| Boot | Multiboot1 -> 32-to-64 shim -> long mode |
| Serial I/O | COM1 (0x3F8), init/putc/print/println |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default iretq handler |
| PIC | 8259A remap to IRQ 32+, mask for timer+keyboard |
| Local APIC | MMIO at 0xFEE00000, timer, IPI |
| Timer | APIC periodic, ~100Hz |
| Keyboard | PS/2, full US QWERTY, shift/caps/ctrl |
| Page Tables | 2MB huge pages, 16MB identity map, per-process |
| PMM | Bitmap allocator, 4096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Slab allocator, 8 size classes (32-4096B) |
| Process Table | 16 slots, 168B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| Scheduler | Round-robin |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space |
| VFS | File table, device/memfile types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | ARP, IPv4, UDP send |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Shell | 12 commands: help echo ps free cat uptime lspci cpus net send bench halt |
| kybernet Init | PID 1 |

## Syscalls

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

## Benchmarks (QEMU ~1GHz)

| Operation | Cycles | Time |
|-----------|--------|------|
| Syscall (getpid) | 306 | ~306ns |
| PMM alloc+free | 2,041 | ~2us |
| Heap alloc+free | 2,565 | ~2.6us |
| Serial putc | 5,922 | ~5.9us |
| Memory write 1MB | 10.9M | ~10.9ms (~91 MB/s) |

## Metrics

- **Binary**: 106KB
- **Source**: ~2,980 lines, 122 functions
- **Subsystems**: 27
- **Boot time**: <100ms on QEMU
- **Dependencies**: Zero (Cyrius compiler only)

## Requirements

- Linux x86_64
- Cyrius compiler (`../cyrius/build/cc2`)
- QEMU (`qemu-system-x86_64`) for testing

## License

GPL-3.0-only
