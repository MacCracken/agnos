# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.22.0] — 2026-04-13

## [1.21.0] — 2026-04-13

### Added
- Kernel stdlib: vendored `kstring.cyr` (strlen, streq, memeq, memcpy, memset, memchr, strchr, atoi, strstr) and `kfmt.cyr` (fmt_int_buf, fmt_hex_buf, kfmt_int, kfmt_hex, kfmt_hex0x, kfmt_byte)
- `cyrius.toml` project metadata
- `.cyrius-toolchain` version pinning (3.9.8)
- PCI device IDs displayed in hex (`lspci` shows `vendor=0x1af4` instead of decimal)
- `kernel/lib/` directory for vendored kernel-safe stdlib modules

### Changed
- All scripts use `~/.cyrius/bin/` toolchain only (no `../cyrius/` fallback)
- Toolchain references updated: `cyrb`→`cyrius`, `cc2`→`cc3` across all scripts and docs
- CI/release workflows read toolchain version from `.cyrius-toolchain` (no hardcoded env)
- CI installs from GitHub release tarball directly (removed `ci-cyrius.sh` dependency)
- `kprint_num()` delegates to `kfmt_int()` (stdlib fmt)
- `initrd_build_test()` uses `memcpy()` for string literals (was 40+ `store8()` calls)
- `initrd_name_match()` uses `memeq()` (was manual byte loop)
- `sh_streq()` uses `memeq()` (was manual byte loop)
- `eth_build()`, `arp_request()`, `udp_build()`, `tcp_send_pkt()` use `memcpy()`/`memset()` (were byte loops)
- `net_copy_buf()` delegates to `memcpy()`
- `elf_load()` segment copy uses `memcpy()` + BSS zero uses `memset()`
- `fatfs_match_name()` uses `memset()` for pad + `memeq()` for compare
- Shell `blkread` hexdump uses `kfmt_byte()`
- README.md metrics updated (143KB, 46 files, 26 syscalls, 33 subsystems)
- Roadmap updated with v1.11.0 and v1.21.0 completions
- CONTRIBUTING.md install instructions point to `install.sh`

### Metrics
- Binary: 143KB (x86_64), 57KB (aarch64)
- Source: ~4,800 lines across 46 files
- Syscalls: 26
- Subsystems: 33
- Shell commands: 18

## [1.11.0] — 2026-04-07

### Added
- GRUB bootable ISO (`scripts/iso.sh`, `boot/grub/grub.cfg`)
- ELF fixup for GRUB compatibility (`scripts/elf-fixup.py`)
- TCP/IP stack: connect, send, recv, close, connection table, 3-way handshake
- VirtIO-blk driver: sector read/write, DMA-safe buffers, PCI bus mastering
- FAT16 filesystem reader: boot sector, directory listing, file open/read
- Shell commands: `tcp`, `blkread`, `ls`, `disk`
- SMP trampoline layout fixed (no section overlaps, data at 0x8180+)

### Changed
- CI uses `$HOME/.cyrius/` instead of `/tmp` (self-hosted runner compatibility)
- Build scripts write temp files to `$ROOT/build/` not `/tmp`
- Preprocessed source (`#define ARCH_X86_64`) prepended by build script

### Fixed
- 6 tilde operator (`~`) replacements with two's complement
- 7 string length off-by-one fixes
- Shell help lists all 18 commands
- SMP trampoline 32-bit code no longer overruns 64-bit section

### Metrics
- Binary: 143KB (x86_64), 57KB (aarch64)
- Syscalls: 26
- Shell commands: 18

## [1.2.0] — 2026-04-07

### Added
- VirtIO net receive path: `virtio_net_poll`, `net_poll`, `net_recv_udp`, ARP cache updates
- Signal delivery: SIGCHLD sent on process exit, pending signal check in scheduler
- Pipes: VFS type 6 with 4KB circular buffer, `pipe` syscall (#25), `pipe_read`/`pipe_write`
- Shell commands: `recv` (show received UDP), `pipe` (pipe read/write test)
- `proc_send_signal`, `proc_check_pending_signals`, `proc_get_ppid` helpers
- `net_handle_arp`, `net_handle_udp` factored helpers for packet dispatch

### Changed
- CI pinned to Cyrius 1.9.0
- Build scripts prepend `#define ARCH_X86_64` directly (no dependency on cyrb `-D` flag)
- CI uses local `scripts/ci-cyrius.sh` for reliable toolchain install

### Metrics
- Binary: 115KB (was 98KB)
- Syscalls: 26 (was 25)
- Shell commands: 14 (was 12)

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
- `rdtsc()` cycle-accurate benchmarks: PMM 1304 cy/op, syscall 188 cy/op, heap 1207 cy/op
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
- CI pinned to Cyrius 1.7.1 (was 1.6.1)
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
- Binary: 106KB (x86_64)
- Source: ~2,980 lines, 122 functions (single file)
- 27 subsystems, 8 syscalls
- Boots to interactive shell on QEMU in <100ms
