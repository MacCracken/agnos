# AGNOS — Claude Code Instructions

## Project Identity

**AGNOS** (from Greek *agnosis* — unknowing, the blank slate) — Sovereign operating system kernel.

- **Type**: Bare-metal kernel binary (Cyrius language)
- **License**: GPL-3.0-only
- **Version**: 1.0.0
- **Language**: Cyrius (self-hosting, zero external dependencies)
- **Target**: x86_64 + aarch64 (cross-compilation supported)

## Goal

A sovereign kernel written entirely in Cyrius. No C, no Rust, no LLVM. Assembly up. Boots on QEMU via multiboot1. Owns every instruction from power-on to userland.

## Consumers

- kybernet (PID 1 init system) — boots on AGNOS
- AGNOS userland tools — shell, services
- Cyrius language project — proves the language handles kernel code

## Build

Requires the Cyrius toolchain (`cc2`, `cc2_aarch64`, `cyrb`) from the `cyrius` repo.

```sh
# x86_64 (default)
sh scripts/build.sh
# or: ../cyrius/build/cyrb build kernel/agnos.cyr build/agnos

# aarch64 cross-compile
sh scripts/build.sh --aarch64
# or: ../cyrius/build/cyrb build --aarch64 kernel/agnos.cyr build/agnos-aarch64

# Boot on QEMU (x86_64)
qemu-system-x86_64 -kernel build/agnos -serial stdio -display none

# Run tests
sh scripts/test.sh              # x86_64
sh scripts/test.sh --aarch64    # aarch64 (compile test)
sh scripts/test.sh --all        # both architectures
```

## Project Structure

```
agnos/
├── VERSION                  # Single source of truth
├── CLAUDE.md                # These instructions
├── README.md                # Architecture, quick start
├── CHANGELOG.md             # Keep a Changelog format
├── LICENSE                  # GPL-3.0-only
├── kernel/
│   ├── agnos.cyr            # Main kernel source
│   └── kernel_hello.cyr     # Minimal boot test
├── build/                   # Generated binaries (gitignored)
├── docs/
│   ├── architecture/        # System diagrams, subsystem docs
│   └── development/
│       └── roadmap.md       # Kernel-specific roadmap
├── scripts/
│   ├── build.sh             # Build kernel
│   └── test.sh              # Run kernel tests
└── .github/workflows/
    ├── ci.yml               # Build + verify on every push
    └── release.yml          # Tag → build → release
```

## Development Process

### Work Loop

```
1. RESEARCH    — Check vidya for kernel patterns
2. BUILD       — ONE subsystem at a time
3. TEST        — Boot on QEMU after EACH change, check serial output
4. IF BROKEN   — Revert to last known good, apply ONE change
5. AUDIT       — Verify multiboot header, ELF structure, memory map
6. DOCUMENT    — Update roadmap, architecture docs
```

### Task Sizing

- **Small**: Add a syscall, fix a bounds check → batch freely
- **Medium**: New subsystem (e.g., scheduler) → small bites, test after each
- **Large**: Architecture port → plan first, prototype, then implement

## Key Principles

- **Assembly is the cornerstone** — every instruction maps to hardware reality
- **Own every byte** — no libc, no external runtime, no linker scripts
- **Multiboot1 boot** — 32-bit ELF for GRUB/QEMU compatibility
- **Serial console** — all kernel output via COM1 (0x3F8)
- **ISR correctness** — save ALL caller-saved registers (9 regs: rax, rcx, rdx, rsi, rdi, r8-r11)
- **Bounds check everything** — PMM, process table, syscall args
- **Identity map first** — 2MB huge pages, add finer granularity when needed

## Kernel Subsystems

| Subsystem | Status | Description |
|-----------|--------|-------------|
| Boot (multiboot1, 32→64 shim) | Complete | 32-bit ELF entry, long mode transition |
| Serial I/O | Complete | COM1 (0x3F8), init/putc/print/println |
| GDT | Complete | 5 segments + TSS descriptor |
| TSS | Complete | Ring 3 transitions, RSP0 |
| IDT | Complete | 256 vectors, default iretq handler |
| PIC | Complete | 8259A, ICW1-4, remap to INT 32+ |
| Local APIC | Complete | MMIO at 0xFEE00000, timer, IPI |
| Timer (APIC) | Complete | Periodic ~100Hz |
| Keyboard | Complete | PS/2, full US QWERTY, shift/caps/ctrl |
| Page Tables | Complete | 2MB huge pages, 16MB identity map, per-process |
| PMM | Complete | Bitmap, 4096 pages, next-free hint optimization |
| VMM | Complete | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Complete | Slab allocator, 8 size classes (32-4096B) |
| Process Table | Complete | 16 slots, 168B context, CR3 per-process |
| Context Switch | Complete | Full register save/restore, CR3 switch |
| Scheduler | Complete | Round-robin |
| SYSCALL/SYSRET | Complete | MSR setup, ring 3 transition |
| ELF Loader | Complete | Static ELF64, per-process address space |
| VFS | Complete | File table, device/memfile types |
| Device Drivers | Complete | Serial char device |
| Initrd | Complete | Flat format, name lookup |
| PCI Bus | Complete | Config space scan, device discovery |
| VirtIO-Net | Complete | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | Complete | ARP, IPv4, UDP send |
| SMP Infrastructure | Complete | APIC, IPI, trampoline, per-CPU stacks |
| Shell | Complete | 12 commands: help echo ps free cat uptime lspci cpus net send bench halt |
| kybernet Init | Complete | PID 1 |
| Syscalls | Complete | exit(0), write(1), getpid(2), spawn(3), waitpid(4), read(5), close(6), open(7) |

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify the Cyrius compiler from this repo — changes go in `../cyrius/`
- Do not add C or assembly files — everything is Cyrius
- Do not skip QEMU verification after kernel changes
- Do not use inline asm without documenting the register contract
