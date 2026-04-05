# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Separated kernel to own repository (was in cyrius/kernel/)

## [0.9.0] — 2026-04-05

### Added
- Full x86_64 kernel: multiboot1 boot, 32-to-64 shim, serial I/O
- GDT (64-bit flat segments), IDT (256 vectors), PIC (8259A remap)
- PIT timer at 100Hz with bytecode ISR
- Keyboard interrupt with scancode ring buffer and ASCII translation
- Page tables: 16MB identity map with 2MB huge pages
- Physical memory manager: bitmap allocator (4096 pages)
- Virtual memory manager: map/unmap/alloc with TLB invalidation
- Process table: 16 slots, create/get_state/set_state
- Syscall interface: exit(0), write(1), getpid(2)

### Fixed (Phase 10 Audit)
- PMM bounds checking (page >= 4096 guard)
- Process table overflow guard (proc_count >= 16)
- ISR full register save (9 caller-saved regs instead of 3)
- Syscall write: length clamped to 4096, null pointer rejected
- Process state validation in syscall handlers

### Metrics
- Binary: 62KB
- Source: ~650 lines, 35 functions
- Boots on QEMU in <100ms
