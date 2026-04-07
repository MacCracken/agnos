# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] — 2026-04-06

### Added

#### Multi-Architecture Support
- Split monolithic `kernel/agnos.cyr` into 33 files: `arch/x86_64/` (14), `core/` (15), `user/` (3), main orchestrator
- aarch64 port: PL011 UART serial, GIC interrupt controller, ARM generic timer, keyboard via UART RX, paging stubs
- aarch64 boots to PMM+heap initialization on `qemu-system-aarch64 -M virt`
- Build with `sh scripts/build.sh --aarch64` using `-D ARCH_AARCH64`
- `arch_wait()` / `arch_halt()` abstraction — shared code is asm-free

#### Kybernet Integration
- 17 new syscalls (total 25): dup, mkdir, rmdir, mount, sync, reboot, pause, getuid, kill, sigprocmask, signalfd, epoll_create, epoll_ctl, epoll_wait, timerfd_create, timerfd_settime, umount
- Signal infrastructure: per-process `proc_signals[]` and `proc_sigmask[]`
- VFS types: signalfd (type 3), epoll (type 4), timerfd (type 5)
- agnosys dual backend: kybernet compiles with `-D LINUX` or `-D AGNOS`
- Bridge spec: `docs/development/kybernet-bridge.md` and `docs/development/syscall-additions.md`

#### Benchmarks and CI
- `rdtsc()` cycle-accurate benchmarks: PMM 2041 cy/op, syscall 306 cy/op, heap 2565 cy/op
- `scripts/bench.sh` — automated benchmark runner with `BENCHMARKS.md` and `bench-history.csv`
- `scripts/check.sh` — 11-point project validation (build, tests, docs, version consistency)
- `scripts/version-bump.sh` — automated version management
- CI uses Cyrius installer (`install.sh`) as single source of truth
- SHA256 checksums in release workflow

#### Optimizations
- PMM `next_free` hint: O(1) sequential allocation
- PMM init: 64-byte memset instead of 512 `pmm_set()` calls
- `kmalloc` zeros only requested size, not full slab block
- Dead code removed: `apic_send_ipi()`, unused `kfree()`

### Changed
- CI pinned to Cyrius 1.7.0 (was 1.6.1)
- `test.sh` requires `cyrb` (no `cc2` fallback for multi-file builds)
- aarch64 build no longer needs SP patch trampoline (compiler fixed in Cyrius 1.7.0)

### Fixed
- Port I/O helpers (`inb`/`outb`) had wrong rbp offsets from extra `var p = port` copies
- `slab_grow()` flags `0x03` → `0x83` (correct 2MB page flag)
- Global variable initializers not persisting in kernel mode — explicit init at boot

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
