# AGNOS Kernel Architecture

> v1.21.0 — Multi-arch (x86_64 + aarch64), 26 syscalls, 220KB/57KB binary, 106 tests

## Boot Sequence

### x86_64

```
BIOS/UEFI -> GRUB/QEMU multiboot1 loader
  -> 32-bit entry (ELF32, base 0x100000)
    -> Identity page tables (4 levels, 2MB huge pages)
    -> Enable PAE -> set CR3 -> enable LME in EFER -> enable paging
    -> Load 64-bit GDT -> far jump to 64-bit code
      -> Cyrius kernel main() (cyrius build -D ARCH_X86_64)
        -> Serial I/O (COM1), GDT+TSS, IDT, PIC, Local APIC
        -> Page tables, PMM, VMM, kernel heap
        -> Process table, scheduler, SYSCALL/SYSRET
        -> ELF loader, VFS, initrd, device drivers
        -> PCI scan, VirtIO-Net, VirtIO-Blk, IP/UDP/TCP stack
        -> SMP init (APIC, IPI, trampoline, per-CPU stacks)
        -> 26 syscalls (signals, epoll, timerfd, pipes)
        -> kybernet (PID 1) -> interactive shell
```

### aarch64

```
qemu-system-aarch64 -M virt
  -> DTB -> EL2-to-EL1 transition
    -> PL011 UART serial init
    -> GIC interrupt controller init
    -> ARM generic timer init
    -> Cyrius kernel main() (cyrius build -D ARCH_AARCH64 --aarch64)
      -> PMM, kernel heap
      -> Boots to serial output on QEMU -M virt
```

## Memory Map

```
0x000000 - 0x001000  Real-mode IVT (unused)
0x001000 - 0x005000  Page tables (PML4, PDPT, PD, PT)
0x100000 - 0x136000  Kernel code + data (~220KB x86_64)
0x200000 - 0x1000000 Available physical memory (2MB - 16MB)
0xFEE00000           Local APIC MMIO
```

## Subsystem Diagram

```
┌─────────────────────────────────────────────────────────┐
│                   Interactive Shell (19 commands)        │
│  help echo ps free cat uptime lspci cpus net send recv  │
│  tcp pipe blkread ls disk bench test halt               │
├─────────────────────────────────────────────────────────┤
│              kybernet (PID 1 Init)                       │
├─────────────────────────────────────────────────────────┤
│              Syscall Interface (26 syscalls)              │
│  exit(0) write(1) getpid(2) spawn(3) waitpid(4)        │
│  read(5) close(6) open(7) dup(8) mkdir(9) rmdir(10)    │
│  mount(11) sync(12) reboot(13) pause(14) getuid(15)    │
│  kill(16) sigprocmask(17) signalfd(18)                  │
│  epoll_create(19) epoll_ctl(20) epoll_wait(21)          │
│  timerfd_create(22) timerfd_settime(23) umount(24)      │
│  pipe(25)                                               │
├──────────────────┬──────────────────────────────────────┤
│  ELF Loader      │  VFS (device/memfile/signalfd/epoll/  │
│  static ELF64    │       timerfd/pipe)                  │
│  per-process AS  │  Initrd, Device drivers (serial)     │
├──────────────────┼──────────────────────────────────────┤
│  Scheduler       │  PCI Bus (config scan)               │
│  round-robin     │  VirtIO-Net (virtqueues, Ethernet)   │
│  Context Switch  │  VirtIO-Blk (sector R/W, DMA)        │
│                  │  IP/UDP/TCP Stack (ARP, IPv4)         │
│                  │  FAT16 (read-only filesystem)         │
├──────────────────┼──────────────────────────────────────┤
│  Process Table   │  VMM (2MB pages, user-accessible)    │
│  16 slots, 168B  │  Kernel Heap (slab, 8 classes)       │
│  CR3 per-process │  PMM (bitmap, 4096 pages)            │
│  Signals, Epoll  │  Kernel Stdlib (kstring, kfmt)       │
├──────────────────┴──────────────────────────────────────┤
│  SMP (APIC, IPI, trampoline)  │  Page Tables (per-proc) │
│  Timer (APIC ~100Hz)          │  Keyboard (PS/2 QWERTY) │
│  PIC (8259A)  Local APIC      │  IDT (256 vectors)      │
│  GDT (5 seg + TSS)            │  Serial (COM1 0x3F8)    │
├─────────────────────────────────────────────────────────┤
│                  Boot Shim (32->64)                      │
│               Multiboot1 (ELF32, 220KB)                  │
└─────────────────────────────────────────────────────────┘
```

## ISR Model

Interrupt service routines are built as bytecode in data buffers at runtime. This works because the ELF `PT_LOAD` segment has RWX permissions.

Timer ISR saves 9 caller-saved registers (rax, rcx, rdx, rsi, rdi, r8-r11), increments tick counter, sends EOI, restores registers, iretq.

Keyboard ISR reads port 0x60 (scancode), stores in ring buffer, advances head pointer with wrapping, sends EOI. Supports full US QWERTY layout with shift, caps lock, and ctrl modifiers.

## Process Model

Each process has a 168-byte context block containing all general-purpose registers, RIP, RSP, RFLAGS, and CR3. Context switch saves the full register set and swaps CR3 for per-process address spaces.

Ring 3 transition via SYSCALL/SYSRET with MSR configuration. TSS provides RSP0 for kernel stack on ring transitions.

## Networking

PCI bus enumeration discovers VirtIO-Net device. Legacy PCI transport with virtqueues for packet send/receive. Ethernet frames with ARP for address resolution, IPv4 for routing, UDP and TCP for transport. TCP supports connect, send, recv, close with SYN/ACK/FIN state machine.

## Block I/O

VirtIO-Blk driver for sector-level read/write with DMA-safe buffers. FAT16 filesystem reader mounted on boot (read-only, root directory listing, file open/read).
