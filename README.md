# AGNOS

> Sovereign operating system kernel. Written in Cyrius. Assembly up.

## Quick Start

```sh
# Build for x86_64
sh scripts/build.sh

# Build for aarch64 (cross-compile)
sh scripts/build.sh --aarch64

# Boot (x86_64)
qemu-system-x86_64 -kernel build/agnos -serial stdio -display none

# Test both architectures
sh scripts/test.sh --all
```

## Architecture

```
multiboot1 header (32-bit ELF)
  → 32-bit boot shim (identity page tables, enable long mode)
    → 64-bit Cyrius kernel
      → serial console, GDT, IDT, PIC, timer, keyboard
      → page tables (16MB), PMM (bitmap), VMM
      → process table (16 slots), syscall interface
```

## Subsystems

| Subsystem | Description |
|-----------|-------------|
| Boot | Multiboot1 → 32-to-64 shim → long mode |
| Serial | COM1 (0x3F8) output, init/putc/print/println |
| GDT | 64-bit flat code + data segments |
| IDT | 256 vectors, default iretq handler |
| PIC | 8259A remap to IRQ 32+, mask for timer+keyboard |
| Timer | PIT channel 0 at 100Hz, bytecode ISR |
| Keyboard | IRQ1 scancode ring buffer, ASCII translation |
| PMM | Bitmap allocator, 4096 pages (16MB) |
| VMM | 2MB huge page map/unmap with TLB invalidation |
| Processes | 16-slot table, create/state/count |
| Syscalls | exit(0), write(1), getpid(2) |

## Metrics

- **Binary**: 62KB
- **Source**: ~650 lines, 35 functions
- **Boot time**: <100ms on QEMU
- **Dependencies**: Zero (Cyrius compiler only)

## Requirements

- Linux x86_64
- Cyrius compiler (`../cyrius/build/cc2`)
- QEMU (`qemu-system-x86_64`) for testing

## License

GPL-3.0-only
