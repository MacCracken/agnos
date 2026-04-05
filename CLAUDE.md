# AGNOS — Claude Code Instructions

## Project Identity

**AGNOS** (from Greek *agnosis* — unknowing, the blank slate) — Sovereign operating system kernel.

- **Type**: Bare-metal kernel binary (Cyrius language)
- **License**: GPL-3.0-only
- **Version**: 0.9.0
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

| Subsystem | Status | Functions |
|-----------|--------|-----------|
| Boot (multiboot1, 32→64 shim) | Complete | 2 |
| Serial I/O | Complete | serial_init, serial_putc, serial_print, serial_println |
| GDT | Complete | gdt_init (64-bit flat segments) |
| IDT | Complete | idt_set_gate, idt_init (256 vectors) |
| PIC | Complete | pic_init (ICW1-4, remap to 32+) |
| Timer (PIT) | Complete | timer_isr_build (100Hz, bytecode ISR) |
| Keyboard | Complete | kb_isr_build (scancode ring buffer, ASCII map) |
| Page Tables | Complete | pt_map_2mb, pt_init (16MB identity map) |
| PMM | Complete | pmm_init/set/clear/test/alloc/free (bitmap) |
| VMM | Complete | vmm_map/unmap/is_mapped/alloc_at (2MB pages) |
| Process Table | Complete | proc_create/get_state/set_state (16 slots) |
| Syscalls | Complete | ksyscall: exit(0), write(1), getpid(2) |

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify the Cyrius compiler from this repo — changes go in `../cyrius/`
- Do not add C or assembly files — everything is Cyrius
- Do not skip QEMU verification after kernel changes
- Do not use inline asm without documenting the register contract
