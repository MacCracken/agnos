# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Separated kernel to own repository (was in cyrius/kernel/)

## [1.0.0] — 2026-04-05

### Added

#### Core Infrastructure
- Full x86_64 kernel: multiboot1 boot, 32-to-64 shim, serial I/O
- GDT (5 segments + TSS descriptor), IDT (256 vectors), PIC (8259A remap)
- TSS for ring 3 transitions with RSP0

#### Interrupts and Timers
- Local APIC (MMIO at 0xFEE00000, timer, IPI)
- APIC periodic timer at ~100Hz (replaces PIT)
- Keyboard: PS/2, full US QWERTY scancode map, shift/caps/ctrl support

#### Memory Management
- Page tables: 16MB identity map with 2MB huge pages, per-process tables
- Physical memory manager: bitmap allocator (4096 pages, next-free hint)
- Virtual memory manager: map/unmap/alloc with TLB invalidation, user-accessible pages
- Kernel heap: slab allocator, 8 size classes (32-4096B)

#### Process Management
- Process table: 16 slots, 168B context, CR3 per-process
- Context switch: full register save/restore, CR3 switch
- Scheduler: round-robin
- SYSCALL/SYSRET: MSR setup, ring 3 transition, memory isolation
- Syscalls: exit(0), write(1), getpid(2), spawn(3), waitpid(4), read(5), close(6), open(7)

#### Filesystem and Drivers
- ELF loader: static ELF64, per-process address space
- VFS: file table, device/memfile types
- Device drivers: serial char device
- Initrd: flat format, name lookup

#### Networking
- PCI bus: config space scan, device discovery
- VirtIO-Net: legacy PCI, virtqueues, Ethernet frames
- IP/UDP stack: ARP, IPv4, UDP send

#### SMP and Userland
- SMP infrastructure: APIC, IPI, trampoline, per-CPU stacks
- Interactive shell: 12 commands (help, echo, ps, free, cat, uptime, lspci, cpus, net, send, bench, halt)
- kybernet init: PID 1

### Fixed (Phase 10 Audit)
- PMM bounds checking (page >= 4096 guard)
- Process table overflow guard (proc_count >= 16)
- ISR full register save (9 caller-saved regs instead of 3)
- Syscall write: length clamped to 4096, null pointer rejected
- Process state validation in syscall handlers

### Metrics
- Binary: 106KB
- Source: ~2,980 lines, 122 functions
- 27 subsystems
- Boots to interactive shell on QEMU in <100ms
- Benchmarks (QEMU ~1GHz): syscall 306 cycles, PMM alloc+free 2,041 cycles, heap alloc+free 2,565 cycles
