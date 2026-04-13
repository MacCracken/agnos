# AGNOS Kernel Roadmap

> **Current**: v1.21.0 — x86_64 + aarch64, 143KB/57KB, 26 syscalls, 33 subsystems, kernel stdlib

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

## Completed (v1.11.0)

| # | Item | Version |
|---|------|---------|
| 23 | VirtIO-blk driver (sector read/write, DMA) | v1.11.0 |
| 24 | FAT16 read-only filesystem | v1.11.0 |
| 25 | TCP stack (connect, send, recv, close) | v1.11.0 |
| 26 | Pipes (circular buffer IPC, VFS type 6) | v1.11.0 |
| 27 | GRUB bootable ISO support | v1.11.0 |

## Completed (v1.21.0)

| # | Item | Version |
|---|------|---------|
| 28 | Kernel stdlib (vendored kstring.cyr, kfmt.cyr) | v1.21.0 |
| 29 | cyrius.toml + .cyrius-toolchain build modernization | v1.21.0 |
| 30 | CI/release uses .cyrius-toolchain (no hardcoded version) | v1.21.0 |
| 31 | Toolchain rename: cyrb→cyrius, cc2→cc3 across all scripts/docs | v1.21.0 |

## Active

| # | Item | Notes |
|---|------|-------|
| 1 | SMP AP wakeup on real hardware | Currently QEMU-validated only |
| 2 | Tagged unions for VFS entry types | ktagged.cyr kernel stdlib |
| 3 | Struct refactor with #derive(accessors) | proc_table, vfs_table, pci_devs |

## Multi-Architecture (Complete)

Multi-arch split complete (v1.1.0). 33 files across `kernel/arch/x86_64/` (14), `kernel/arch/aarch64/` (5), `kernel/core/` (15), `kernel/user/` (3), plus main orchestrator.

Build uses `#ifdef ARCH_<NAME>` + `include`:
```sh
cyrius build -D ARCH_X86_64 kernel/agnos.cyr build/agnos
cyrius build -D ARCH_AARCH64 --aarch64 kernel/agnos.cyr build/agnos-aarch64
```

Arch interface — each arch provides:
- `arch_init()` — hardware init (GDT/IDT/APIC or GIC/UART)
- `arch_timer_init()` — periodic timer
- `arch_serial_putc(c)` / `arch_serial_print(msg, len)`
- `arch_map_page(virt, phys, flags)` — page table manipulation
- `arch_context_switch(old, new)` — register save/restore
- `arch_enter_user(entry, rsp)` — ring transition
- `arch_eoi()` — interrupt acknowledgment
- `arch_wait()` / `arch_halt()` — WFI/HLT abstraction

All Cyrius blockers resolved (Cyrius >= 1.7.0):
1. ~~`include` in kernel mode~~ — **Fixed** v1.6.1
2. ~~`cyrb --aarch64` path resolution~~ — **Fixed** v1.6.1
3. ~~Release tarball missing cc2_aarch64~~ — **Fixed** v1.7.0
4. ~~aarch64 kernel SP setup~~ — **Fixed** v1.6.2
5. ~~aarch64 string fixups~~ — **Fixed** v1.6.2
6. ~~Nested for-loops with var~~ — **Fixed** v1.7.0
7. ~~ifdef in included files~~ — **Fixed** v1.6.5

## Security Hardening (from 2026-04-13 audit)

Priority order. See `docs/audit/2026-04-13-security-audit.md` for full findings.
Implementation details in `docs/development/security-hardening.md`.

| # | Item | Prerequisite | Severity |
|---|------|-------------|----------|
| S1 | ~~**Separate user/kernel page mappings**~~ | Done | HIGH |
| S2 | ~~**Per-CPU TSS + RSP0**~~ | Done | HIGH |
| S3 | ~~**PMM spinlock**~~ | Done | MEDIUM |
| S4 | ~~**Per-process exit codes**~~ | Done | MEDIUM |
| S5 | ~~**Per-connection TCP RX buffers**~~ | Done | MEDIUM |
| S6 | ~~**Stack guard pages**~~ | Done | MEDIUM |
| S7 | **KASLR** — randomize kernel load address; currently fixed at 0x100000, trivial ROP | Boot shim + relocatable binary | MEDIUM |
| S8 | **KPTI (Kernel Page Table Isolation)** — separate user/kernel page tables to mitigate Meltdown; switch CR3 on syscall entry/exit | S1 + SYSCALL handler | MEDIUM |
| S9 | **Spectre v2 mitigations** — set IA32_SPEC_CTRL.IBRS on syscall entry; consider retpoline for indirect calls | SYSCALL handler | MEDIUM |
| S10 | **IOMMU (VT-d)** — restrict DMA targets so VirtIO devices cannot write arbitrary physical memory | PCI + ACPI/DMAR parsing | MEDIUM |
| S11 | ~~**ARP request tracking**~~ | Done | LOW |
| S12 | ~~**TCP window/sequence validation**~~ | Done | LOW |
| S13 | **Stack canaries** — place canary values at stack frame boundaries to detect buffer overflows | Compiler support or manual | LOW |

### Dependency chain

```
S1 (user/kernel page split)
├── S8 (KPTI) ── S9 (Spectre)
└── S6 (guard pages — needs 4KB page support)

S2 (per-CPU TSS)
└── S3 (PMM spinlock)

S4, S5, S7, S10-S13 are independent
```

## Planned

| # | Item | Prerequisite |
|---|------|-------------|
| 5 | Real filesystem (ext2) | Disk I/O |
| 6 | mmap | VMM + filesystem |
| 7 | Shared memory | SMP + VMM |
| 8 | Preemptive scheduling | Timer + SMP stable |
| 9 | USB support | PCI + device driver framework |
