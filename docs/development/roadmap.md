# AGNOS Kernel Roadmap

> **Current**: v1.0.0 — x86_64 kernel, 106KB, boots to interactive shell with networking and SMP

For language roadmap, see `../cyrius/docs/development/roadmap.md`.

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

## Planned

| # | Item | Prerequisite |
|---|------|-------------|
| 6 | aarch64 port | Cyrius Phase 9 complete |
| 7 | Real filesystem (ext2) | Disk I/O |
| 8 | mmap | VMM + filesystem |
| 9 | Shared memory | SMP + VMM |
| 10 | Preemptive scheduling | Timer + SMP stable |
| 11 | USB support | PCI + device driver framework |
