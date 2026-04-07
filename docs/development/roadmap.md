# AGNOS Kernel Roadmap

> **Current**: v1.1.0 — x86_64 + aarch64, 97KB/43KB, 25 syscalls, multi-arch, kybernet-ready

For language roadmap, see `../cyrius/docs/development/roadmap.md`.

## Completed (v1.1.0)

| # | Item | Version |
|---|------|---------|
| 17 | Multi-arch split (33 files) | v1.1.0 |
| 18 | aarch64 port (serial, GIC, timer, PMM) | v1.1.0 |
| 19 | 17 new syscalls (signals, epoll, timerfd) | v1.1.0 |
| 20 | kybernet dual-backend (Linux/AGNOS) | v1.1.0 |
| 21 | Benchmarks + CI parity | v1.1.0 |
| 22 | SP patch trampoline eliminated | v1.1.0 |

## Completed (v1.0.0)

| # | Item | Status |
|---|------|--------|
| 1 | Scheduler | Done — round-robin |
| 2 | Kernel heap | Done — slab allocator, 8 size classes |
| 3 | VFS layer | Done — file table, device/memfile types |
| 4 | Init integration | Done — kybernet as PID 1 |
| 5 | Context switch | Done — full register save/restore, CR3 switch |
| 6 | SYSCALL/SYSRET | Done — MSR setup, ring 3 transition |
| 7 | ELF loader | Done — static ELF64, per-process address space |
| 8 | Device drivers | Done — serial char device |
| 9 | Initrd | Done — flat format, name lookup |
| 10 | PCI bus | Done — config space scan, device discovery |
| 11 | VirtIO-Net | Done — legacy PCI, virtqueues, Ethernet frames |
| 12 | IP/UDP stack | Done — ARP, IPv4, UDP send |
| 13 | SMP infrastructure | Done — APIC, IPI, trampoline, per-CPU stacks |
| 14 | Interactive shell | Done — 12 commands |
| 15 | Local APIC timer | Done — replaces PIT, ~100Hz periodic |
| 16 | TSS | Done — ring 3 transitions, RSP0 |

## Active

| # | Item | Notes |
|---|------|-------|
| 1 | Real disk I/O | AHCI/SATA or VirtIO-blk |
| 2 | TCP | Complete the network stack beyond UDP |
| 3 | SMP AP wakeup on real hardware | Currently QEMU-validated only |
| 4 | Signals | POSIX-style signal delivery to userland |
| 5 | Pipes | IPC between processes |

## Pre-requisite: Multi-Architecture Readiness

Before the aarch64 port, restructure the kernel for multi-arch support.
Currently everything is in a single `kernel/agnos.cyr` (~3000 lines).

**Step 1: Split arch-dependent from arch-independent code**

```
kernel/
├── arch/x86_64/          # Everything with inline asm or x86 hardware
│   ├── boot.cyr          # multiboot shim, GDT, IDT, TSS
│   ├── apic.cyr          # LAPIC, PIC, PIT, timer ISR
│   ├── paging.cyr        # x86 page tables (PML4/PDPT/PD)
│   ├── syscall.cyr       # SYSCALL/SYSRET MSR setup, entry stub
│   ├── smp.cyr           # AP trampoline, IPI
│   └── io.cyr            # inb/outb/inw/outw/inl/outl, serial
├── arch/aarch64/          # ARM64 equivalents (future)
│   ├── boot.cyr          # DTB, EL2→EL1 transition
│   ├── gic.cyr           # GIC-400 interrupt controller
│   ├── paging.cyr        # ARM 4KB granule page tables
│   ├── syscall.cyr       # SVC handler
│   └── uart.cyr          # PL011 UART
├── core/                  # Pure Cyrius, no inline asm
│   ├── proc.cyr          # process table, context layout, scheduler
│   ├── pmm.cyr           # bitmap allocator
│   ├── heap.cyr          # slab allocator
│   ├── vfs.cyr           # VFS + device drivers + initrd
│   ├── net.cyr           # IP/UDP stack (arch-independent)
│   └── syscall.cyr       # syscall dispatch table
├── user/                  # Userland (pure Cyrius)
│   ├── shell.cyr         # shell commands
│   └── init.cyr          # kybernet
└── agnos.cyr             # main: includes arch/<ARCH>/* + core/* + user/*
```

**All blockers resolved** (Cyrius 1.7.0):
1. ~~`include` in kernel mode~~ — **Fixed** v1.6.1
2. ~~`cyrb --aarch64` path resolution~~ — **Fixed** v1.6.1
3. ~~Release tarball missing cc2_aarch64~~ — **Fixed** v1.7.0 (included in x86_64 tarball)
4. ~~aarch64 kernel SP setup~~ — **Fixed** v1.6.2 (compiler emits preamble)
5. ~~aarch64 string fixups~~ — **Fixed** v1.6.2
6. ~~Nested for-loops with var~~ — **Fixed** v1.7.0
7. ~~ifdef in included files~~ — **Fixed** v1.6.5 (multi-pass preprocessor)

Multi-arch split complete (v1.1.0). Build uses `#ifdef ARCH_<NAME>` + `include`:
```sh
cyrb build -D ARCH_X86_64 kernel/agnos.cyr build/agnos
cyrb build -D ARCH_AARCH64 --aarch64 kernel/agnos.cyr build/agnos-aarch64
```

**Step 2: Define arch interface** — each arch must provide:
- `arch_init()` — hardware init (GDT/IDT/APIC or GIC/UART)
- `arch_timer_init()` — periodic timer
- `arch_serial_putc(c)` / `arch_serial_print(msg, len)`
- `arch_map_page(virt, phys, flags)` — page table manipulation
- `arch_context_switch(old, new)` — register save/restore
- `arch_enter_user(entry, rsp)` — ring transition
- `arch_eoi()` — interrupt acknowledgment

## Planned

| # | Item | Prerequisite |
|---|------|-------------|
| 6 | Multi-arch split (see above) | Build script or Cyrius include support |
| 7 | aarch64 port | Multi-arch split complete |
| 8 | Real filesystem (ext2) | Disk I/O |
| 9 | mmap | VMM + filesystem |
| 10 | Shared memory | SMP + VMM |
| 11 | Preemptive scheduling | Timer + SMP stable |
| 12 | USB support | PCI + device driver framework |
