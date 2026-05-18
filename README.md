# AGNOS

> Sovereign operating system kernel. Written in Cyrius. Assembly up. Zero C, zero Rust, zero LLVM.

## Quick Start

```sh
# Build for x86_64
sh scripts/build.sh

# Build for aarch64 (cross-compile)
sh scripts/build.sh --aarch64

# Boot in QEMU (x86_64) via gnoboot+OVMF — the v1.30.0 Path-C sovereign
# UEFI handoff replaces the dead multiboot1+`-kernel` flow. The full
# command needs OVMF firmware + a gnoboot-loaded FAT image; the
# gnoboot smoke test runs it end-to-end:
#   git clone https://github.com/MacCracken/gnoboot && cd gnoboot
#   sh tests/ovmf_smoke.sh   # uses -cpu max + OVMF + qemu-system-x86_64
# Iron-boot flow via USB:
#   git clone https://github.com/MacCracken/agnosticos && cd agnosticos
#   sh scripts/install-usb.sh /dev/sdX     # writes gnoboot + agnos
#   sh scripts/install-usb.sh --update     # rebuilds + refreshes existing USB

# Test both architectures
sh scripts/test.sh --all
```

## Architecture

Multi-arch kernel: `kernel/klib/` (3 files — `kstring`, `kfmt`, `ktagged`; freestanding syscall-free stdlib), `kernel/arch/x86_64/` (17 files + `usb/` subdir with 8 xHCI/HID files), `kernel/arch/aarch64/` (9 files), `kernel/core/` (18 files), `kernel/user/` (4 files), plus `kernel/agnos.cyr` orchestrator, `kernel/version.cyr` auto-generated banner module (v1.30.2+), and `kernel/kernel_hello.cyr` smoke test.

The build script wraps `cyrius build` with a `#define ARCH_X86_64` /
`#define ARCH_AARCH64` prepend, since `cyrius build -D NAME` doesn't
propagate into nested `#ifdef` blocks reached via `include`.

```
x86_64 (v1.30.0+ Path-C sovereign UEFI handoff):
  UEFI firmware
    -> gnoboot (sovereign UEFI bootloader, PE32+ EFI Application)
      -> Path-C boot-info struct (magic 0x41474E4F, 80 bytes)
      -> ELF64 multiboot2 kernel mapping + jmp rax handoff
        -> RDI = &boot_info on entry (kernel captures via mbi.cyr)
          -> 64-bit Cyrius kernel (sh scripts/build.sh)

aarch64:
  DTB -> EL2-to-EL1 transition
    -> PL011 UART, GIC, ARM generic timer
      -> 64-bit Cyrius kernel (sh scripts/build.sh --aarch64)

Common:
  -> serial, GDT+TSS/GIC, IDT, PIC/GIC, Local APIC, timer, keyboard
  -> page tables (4 GB identity map ceiling, 2 MB huge pages, per-process)
  -> PMM (bitmap), VMM, kernel heap (slab)
  -> process table, context switch, scheduler, SYSCALL/SYSRET
  -> ELF loader, VFS, initrd, device drivers
  -> PCI bus, VirtIO-Net, IP/UDP stack
  -> Native xHCI + USB-HID-boot keyboard driver (Phase 1-5)
  -> SMP infrastructure (APIC, IPI, trampoline, per-CPU stacks)
  -> 26 syscalls (signals, epoll, timerfd, pipes)
  -> kybernet (PID 1) -> interactive shell
```

## Subsystems (36+)

| Subsystem | Description |
|-----------|-------------|
| Boot | UEFI -> gnoboot (sovereign PE32+ EFI Application) -> Path-C sovereign boot-info struct (magic 0x41474E4F) -> ELF64 multiboot2 + RDI=&boot_info handoff (x86_64, v1.30.0+); DTB -> EL2-to-EL1 (aarch64) |
| Serial I/O | COM1 0x3F8 (x86_64), PL011 UART (aarch64) |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default iretq handler |
| PIC | 8259A remap to IRQ 32+, mask for timer+keyboard |
| Local APIC | MMIO at 0xFEE00000, timer, IPI |
| GIC | ARM GICv2 interrupt controller (aarch64) |
| Timer | APIC periodic ~100Hz (x86_64), ARM generic timer (aarch64) |
| Keyboard | PS/2 full US QWERTY + USB-HID-boot via xHCI (x86_64); UART RX (aarch64) |
| xHCI Host Controller | Native USB 3.x host controller driver: PCIe discovery, BAR UC remap, controller init (HCRST + R/S + scratchpad + DCBAA + event ring + cmd ring), port enumeration with PORTSC strict-RW1S, Enable Slot + Address Device cmd path, MSI-X table programming (v1.30.0+ — Phase 1-5 code-complete; iron-side resolution in flight for AMD FCH 1022:1639 Enable Slot CCE gate) |
| USB-HID-boot Keyboard | hid_kbd_configure + hid_poll + HID→PS/2 usage translation + kb_buf writer (v1.30.5; lives in kernel/arch/x86_64/usb/) |
| Page Tables | 2MB huge pages, 4GB identity map ceiling, per-process; XHCI BAR strict-UC remap (Repair X) |
| PMM | Bitmap allocator, 4096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Slab allocator, 8 size classes (32-4096B) |
| Process Table | 16 slots, 168B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space |
| VFS | File table, device/memfile/signalfd/epoll/timerfd/pipe types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | ARP, IPv4, UDP send/recv |
| TCP Stack | Connect, send, recv, close, SYN/ACK/FIN state machine |
| VirtIO-Blk | Legacy PCI, sector read/write, DMA buffers |
| FAT16 | Read-only, root directory listing, file open/read |
| Pipes | Circular buffer IPC, read/write ends |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Signals | per-process signals/sigmask, kill, sigprocmask, signalfd |
| Epoll | epoll_create, epoll_ctl, epoll_wait |
| Timerfd | timerfd_create, timerfd_settime |
| Scheduler | Round-robin |
| Shell | 19 commands: help echo ps free cat uptime lspci cpus net send recv tcp pipe blkread ls disk bench test halt |
| kybernet Init | PID 1, 26 kernel syscalls ready |

## Syscalls (26)

| Number | Name | Description |
|--------|------|-------------|
| 0 | exit | Terminate process |
| 1 | write | Write to file descriptor |
| 2 | getpid | Get process ID |
| 3 | spawn | Create new process |
| 4 | waitpid | Wait for child process |
| 5 | read | Read from file descriptor |
| 6 | close | Close file descriptor |
| 7 | open | Open file |
| 8 | dup | Duplicate file descriptor |
| 9 | mkdir | Create directory |
| 10 | rmdir | Remove directory |
| 11 | mount | Mount filesystem |
| 12 | sync | Sync to disk (noop) |
| 13 | reboot | Reboot system |
| 14 | pause | Pause until signal |
| 15 | getuid | Get user ID (always root) |
| 16 | kill | Send signal to process |
| 17 | sigprocmask | Set signal mask |
| 18 | signalfd | Create signal file descriptor |
| 19 | epoll_create | Create epoll instance |
| 20 | epoll_ctl | Control epoll instance |
| 21 | epoll_wait | Wait for epoll events |
| 22 | timerfd_create | Create timer file descriptor |
| 23 | timerfd_settime | Set timer interval |
| 24 | umount | Unmount filesystem |
| 25 | pipe | Create pipe pair |

## Benchmarks

The CI `benchmarks` job runs the 3-tier kernel bench harness on every
push to `main` (self-hosted runner with QEMU + KVM + OVMF). Per-release
numbers attach to the GitHub Release as `BENCHMARKS.md` +
`bench-history.csv`.

The live harness prints under the `=== AGNOS Benchmarks (3-tier) ===`
header on the QEMU serial console; with the v1.30.0 Path-C handoff the
invocation is now gnoboot + OVMF + `qemu-system-x86_64 -cpu max` (see
`gnoboot/tests/ovmf_smoke.sh` or the agnosticos install/test scripts).
The legacy `-kernel build/agnos` flow was retired with multiboot1.

- **Tier 1** — PMM alloc/free, heap (32 B / 256 B / 4,096 B), 1 MB memwrite
- **Tier 2** — `syscall_getpid` / `getuid` / `write1`, `vfs_open_read_close`
- **Tier 3** — `serial_putc`, end-to-end shapes

`rdtsc`-measured (x86_64). `serial_putc` is dominated by QEMU UART
emulation latency, not codegen — see
[`docs/development/issue/archive/2026-04-27-serial-putc-cc5-regression.md`](docs/development/issue/archive/2026-04-27-serial-putc-cc5-regression.md)
for the methodology caveat (closed at v1.28.1 — kept as audit trail).

## Size Comparison

| Kernel | Language | Scope |
|--------|----------|-------|
| **AGNOS** | Cyrius | 35+ subsystems, 26 syscalls, TCP/IP, FAT16, VirtIO, SMP, ELF loader, ACPI, IOMMU, native xHCI + USB-HID-boot keyboard, sovereign UEFI handoff, shell |
| xv6 (MIT) | C | 21 syscalls, no networking, no SMP, no real FS |
| seL4 (verified) | C/Isabelle | Microkernel only — no drivers, no FS, no networking |
| MINIX 3 | C | Microkernel + basic drivers |
| Linux (minimal) | C | Barely boots, no drivers |
| Linux (typical) | C | Desktop-ready |

A fully functional kernel with TCP/IP, block I/O, filesystem, SMP, signals, epoll, pipes, ACPI/IOMMU, native xHCI / USB-HID-boot keyboard, and an interactive shell — written entirely in Cyrius. No C, no LLVM, no libc.

For live binary sizes per arch (x86_64 + aarch64), per-cut size trajectory across v1.27.x → v1.30.x, source line counts, test surface, and ecosystem sibling pins, see [`docs/development/state.md`](docs/development/state.md) (refreshed every release). Versions intentionally elided from this table per the lib-doc precedent — the size cells drift faster than the README can be re-cut.

## Requirements

- Linux x86_64 (dev box) or aarch64 (cross-compile target)
- Cyrius toolchain — version pinned in [`cyrius.cyml`](cyrius.cyml)
  `[package].cyrius`. Install via [`cyriusly`](https://github.com/MacCracken/cyrius);
  the CI install step does this automatically from the pin.
- QEMU 7.0+ with KVM-class CPU model + OVMF firmware (x86_64):
  - x86_64: `qemu-system-x86_64 -cpu max` (mandatory — gnoboot's UEFI entry sets SMEP+SMAP in CR4 alongside the kernel; `qemu64` default lacks both and triple-faults). OVMF firmware bridges UEFI to QEMU. Smoke test: `gnoboot/tests/ovmf_smoke.sh`.
  - aarch64: `qemu-system-aarch64 -M virt -cpu cortex-a57` (compile-tested; live boot harness not yet wired)

## Project Map

```
agnos/
├── kernel/
│   ├── agnos.cyr            # Main orchestrator (#ifdef + include only)
│   ├── version.cyr          # Auto-generated banner strings (v1.30.2+)
│   ├── kernel_hello.cyr     # Minimal smoke test
│   ├── klib/                # Vendored kernel-safe stdlib (kstring, kfmt, ktagged)
│   ├── arch/x86_64/
│   │   ├── *.cyr            # boot_shim, mbi (Path-C handoff), gdt, idt, pic, apic, smp,
│   │   │                    # paging, ring3, fb / fb_console, iommu, syscall_hw, …
│   │   └── usb/             # xhci{,_cmd,_ctx,_port,_regs,_ring}, hid, hid_translate
│   ├── arch/aarch64/        # boot_data, gic, timer, exceptions, paging, main, stubs, …
│   ├── core/                # pmm, vmm, heap, proc, sched, vfs, net, virtio_{net,blk},
│   │                        # fatfs, pci, acpi, elf, syscall, devs, initrd, kprint, main
│   └── user/                # shell, init, test, test_procs
├── scripts/
│   ├── build.sh             # Multi-arch wrapper around `cyrius build` (emits ELF64 multiboot2)
│   ├── test.sh              # Build assertions (x86_64 / aarch64 / --all)
│   ├── check.sh             # 11-point project validation
│   ├── bench.sh             # Bench harness
│   └── version-bump.sh      # Versions all tracked files atomically (regenerates version.cyr)
├── docs/
│   ├── architecture/        # System overview + non-obvious invariants
│   ├── audit/               # Security audit reports (YYYY-MM-DD-*)
│   ├── development/
│   │   ├── roadmap.md       # Shipped arcs + open items + 1.31.0 KASLR slot
│   │   ├── state.md         # Live state snapshot, bumped every release
│   │   ├── issue/           # Open bug investigations (archive/ for resolved)
│   │   └── proposals/       # Pre-decision design drafts
│   └── doc-health.md        # Doc-currency ledger across the whole tree
└── .github/workflows/
    ├── ci.yml               # build, fmt-check, security, test, boot (OVMF+gnoboot), bench, docs
    └── release.yml          # tag → CI gate → build → CHANGELOG extract → release
```

## License

GPL-3.0-only
