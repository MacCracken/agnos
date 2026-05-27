# AGNOS Kernel Architecture

> **Last Updated**: 2026-05-26 (v1.35.0 cycle)
>
> Multi-arch (x86_64 + aarch64), 28 syscalls, 40+ subsystems. Built with cyrius 6.0.3 (pinned in `cyrius.cyml`). Identity-maps 0–4 GB so QEMU's ACPI tables (~`0x07FE0000`) are reachable. Memory isolation under SMAP verified at boot via `stac`/`clac`-bracketed test (`Memory isolation: PASS` checkpoint, v1.27.1+). **Iron-validated on archaemenid (NUC AMD Zen)**: boot-to-shell MVP cleared at Attempt 68 (1.30.9) with a typeable USB-HID keyboard; the storage stack (NVMe/AHCI/USB-MS), the r8169 NIC + DHCP networking stack, and ext2/4 write all iron-validated since. See [`../development/state.md`](../development/state.md) for the live subsystem rollup + open items.
>
> For live binary sizes per arch, per-cut size trajectory, source line counts, sibling pins, and test surface, see [`../development/state.md`](../development/state.md).

## Boot Sequence

### x86_64

```
UEFI firmware
  -> gnoboot (sovereign UEFI bootloader, PE32+ EFI Application)
    -> Path-C sovereign boot-info struct (magic 0x41474E4F, 80 bytes)
    -> ELF64 multiboot2 kernel mapping + jmp rax handoff
      -> RDI = &boot_info convention (v1.30.0+ ABI break)
      -> Cyrius kernel agnos.cyr orchestrator (sh scripts/build.sh)
        -> Serial I/O (COM1), GDT+TSS, IDT, PIC, Local APIC
        -> Page tables, PMM, VMM, kernel heap
        -> Process table, scheduler, SYSCALL/SYSRET
        -> ELF loader, VFS, initrd, device drivers
        -> PCI scan; storage (NVMe / AHCI / USB-MS / VirtIO-Blk / RAM-disk + 5-backend block layer + GPT)
        -> networking (VirtIO-Net / r8169 GbE + ARP/IPv4/UDP/TCP + DHCP)
        -> filesystems read+write (ext2/ext4, FAT12/16/32, exFAT)
        -> Native xHCI + USB-HID-boot keyboard (Phase 1-5)
        -> SMP init (APIC, IPI, trampoline, per-CPU stacks)
        -> 28 syscalls (signals, epoll, timerfd, pipes, anonymous mmap/munmap)
        -> kybernet (PID 1) -> interactive shell
```

The pre-v1.30.0 multiboot1 + 32→64 shim path (GRUB/`qemu -kernel`) is retired. See [`../development/path-c-sovereign-uefi.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/path-c-sovereign-uefi.md) (in agnosticos) for the boot-info ABI design.

### aarch64

```
qemu-system-aarch64 -M virt
  -> DTB -> EL2-to-EL1 transition
    -> PL011 UART serial init
    -> GIC interrupt controller init
    -> ARM generic timer init
    -> Cyrius kernel main() (sh scripts/build.sh --aarch64)
      -> PMM, kernel heap
      -> Boots to serial output on QEMU -M virt
```

## Memory Map

```
0x000000 - 0x001000  Real-mode IVT (unused)
0x001000 - 0x002000  PML4 (boot identity map)
0x002000 - 0x003000  PDPT (1 GB huge pages for 0-4 GB at PDPT[0..3])
0x003000 - 0x004000  PD   (2 MB huge pages for 0-1 GB; per-process variants live elsewhere)
0x100000 - 0x1??000  Kernel code + data (live size in ../development/state.md)
0x200000 - 0x1000000 Available physical memory (2 MB - 16 MB)
0xFEE00000           Local APIC MMIO
0xFED90000+          IOMMU (VT-d) register window when ACPI DMAR is present
```

Live binary size + per-cut trajectory lives in [`../development/state.md`](../development/state.md). Identity-map ceiling extended to 4 GB at v1.25.0 so QEMU's ACPI tables resolve; the per-process PD-copy loop at `proc_create_address_space` mirrors that ceiling into every address space (v1.25.1). The XHCI BAR for AMD FCH 1022:1639 sits below 4 GB and is remapped strict-UC (PWT=1+PCD=1+PAT=0) on top of the identity map per Repair (X) at v1.30.x (kernel/core/vmm.cyr `vmm_remap_uc_2mb`).

## Subsystem Diagram

```
┌─────────────────────────────────────────────────────────┐
│                   Interactive Shell (28 commands)        │
│  help echo ps free cat uptime lspci cpus net send recv  │
│  tcp pipe blkread ls cd pwd disk parts mount bench test  │
│  + ext2/FAT mount/ls/cat/write/rm/mkdir verbs   halt    │
├─────────────────────────────────────────────────────────┤
│              kybernet (PID 1 Init)                       │
├─────────────────────────────────────────────────────────┤
│              Syscall Interface (28 syscalls)              │
│  exit(0) write(1) getpid(2) spawn(3) waitpid(4)        │
│  read(5) close(6) open(7) dup(8) mkdir(9) rmdir(10)    │
│  mount(11) sync(12) reboot(13) pause(14) getuid(15)    │
│  kill(16) sigprocmask(17) signalfd(18)                  │
│  epoll_create(19) epoll_ctl(20) epoll_wait(21)          │
│  timerfd_create(22) timerfd_settime(23) umount(24)      │
│  pipe(25) mmap(27) munmap(28)                           │
│  [26 write_boot_checkpoint = diagnostic]                │
├──────────────────┬──────────────────────────────────────┤
│  ELF Loader      │  VFS (device/memfile/signalfd/epoll/  │
│  static ELF64    │       timerfd/pipe)                  │
│  per-process AS  │  Initrd, Device drivers (serial)     │
├──────────────────┼──────────────────────────────────────┤
│  Scheduler       │  PCI Bus (config scan)               │
│  round-robin     │  Net: VirtIO-Net + r8169 GbE         │
│  Context Switch  │  IP/UDP/TCP + ARP + DHCP client      │
│                  │  Block layer (5 backends): NVMe /    │
│                  │   AHCI / USB-MS / VirtIO-Blk / RAM   │
│                  │  GPT partitions                      │
│                  │  FS read+write: ext2/4, FAT, exFAT   │
├──────────────────┼──────────────────────────────────────┤
│  Process Table   │  VMM (2MB pages, user-accessible)    │
│  16 slots, 168B  │  Kernel Heap (slab, 8 classes)       │
│  CR3 per-process │  PMM (bitmap, 4096 pages)            │
│  Signals, Epoll  │  Kernel Stdlib (kstring, kfmt)       │
├──────────────────┴──────────────────────────────────────┤
│  SMP (APIC, IPI, trampoline)  │  Page Tables (per-proc) │
│  Timer (APIC ~100Hz)          │  Keyboard (PS/2 + USB-HID-boot via xHCI) │
│  PIC (8259A)  Local APIC      │  IDT (256 vectors)      │
│  GDT (5 seg + TSS)            │  Serial (COM1 0x3F8)    │
├─────────────────────────────────────────────────────────┤
│           Path-C sovereign boot-info ABI (v1.30.0+)      │
│      gnoboot (UEFI) → RDI = &boot_info → ELF64 entry     │
└─────────────────────────────────────────────────────────┘
```

## ISR Model

Interrupt service routines are built as bytecode in data buffers at runtime. This works because the ELF `PT_LOAD` segment has RWX permissions.

Timer ISR saves 9 caller-saved registers (rax, rcx, rdx, rsi, rdi, r8-r11), increments tick counter, sends EOI, restores registers, iretq.

Keyboard ISR reads port 0x60 (scancode), stores in ring buffer, advances head pointer with wrapping, sends EOI. Supports full US QWERTY layout with shift, caps lock, and ctrl modifiers.

## Process Model

Each process has a 168-byte context block containing all general-purpose registers, RIP, RSP, RFLAGS, and CR3. Context switch saves the full register set and swaps CR3 for per-process address spaces.

Ring 3 transition via SYSCALL/SYSRET with MSR configuration. TSS provides RSP0 for kernel stack on ring transitions.

Per-process address spaces are created by `proc_create_address_space` (`kernel/core/proc.cyr`, x86-only — guarded by `#ifdef ARCH_X86_64` since v1.27.0). The kernel PD copy (`i<511`) mirrors 0–1 GB of kernel mappings; PDPT[1..3] mirror 1–4 GB. Entry 511 of the kernel PD holds the user-side CR3 stash for KPTI-light. Pages mapped via `proc_map_page` carry `US=1` (`0x87`) for CPL=3 reachability; kernel-mode access from CPL=0 to those pages requires `stac` / `clac` brackets because the boot shim enables SMAP in CR4 (see the v1.27.1 memory-isolation closeout).

## Networking

PCI bus enumeration discovers the NIC: **VirtIO-Net** (QEMU, legacy PCI + virtqueues) or the **r8169** Realtek RTL8111/8168/8169 GbE driver (real iron, RX/TX descriptor rings, iron-validated on archaemenid). On top: Ethernet frames with ARP for address resolution, IPv4 for routing, UDP and TCP for transport. TCP supports connect, send, recv, close with a SYN/ACK/FIN state machine plus listen/accept server primitives. A **DHCP client** acquires a lease (DISCOVER → OFFER → REQUEST → ACK), iron-verified at 1.32.9.

## Block I/O & filesystems

A tag-based **block layer** (`kernel/core/block.cyr`) dispatches to five backends — `BLK_NVME`, `BLK_AHCI` (SATA), `BLK_USB` (USB Mass Storage, BBB+SCSI), `BLK_VIRTIO`, `BLK_RAM` — with NVMe taking primary when present. **GPT** parses the partition table (CRC32 validation + backup-header recovery + type-GUID classification). Filesystems are mounted partition-aware and support **read and write**: ext2/ext4 (1.33.x WRITE arc — create/write/truncate, persist-across-reboot), FAT12/16/32 and exFAT (1.34.x FAT-family arc — LFN, cluster allocator, directory growth, overwrite/truncate/delete). An ESP-write safety guard refuses FAT/exFAT mutation on an ESP-type partition so the boot ESP can't be clobbered.
