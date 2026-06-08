# AGNOS

> Sovereign operating system kernel. Written in Cyrius. Assembly up. Zero C, zero Rust, zero LLVM.

**Status**: boots to a typeable interactive shell on real AMD hardware (the MVP gate, since v1.30.9). Storage (NVMe / SATA / USB-MS), networking (TCP/IP + DHCP + DNS + NTP + ICMP over a real-iron NIC), and read+write filesystems (ext2/ext4 incl. **ext4 extent allocation** + **JBD2 journaling — crash-safe metadata writes**, FAT12/16/32, exFAT) are all landed — the storage trio, networking, ext4 read+write+extent-alloc, and **exec-from-disk** (a static ELF64 loaded from the filesystem runs in ring 3, 1.40.x) are iron-validated on archaemenid; the FAT-family + JBD2 stacks are QEMU/`fsck`-validated. The headline since is **shell separation** (1.41.x): PID 1 (kybernet) `exec`s `/bin/agnsh` — the userland [agnoshi](https://github.com/MacCracken/agnoshi) shell — in ring 3 off the ext2 root, so the full interactive shell is now a userland binary while the in-kernel `shell()` shrank to a minimal **recovery REPL** (the boot fallback only); FAT/exFAT content-write also reached the syscall ABI (1.41.7). The latest headline is **DOOM rendering on AGNOS** (1.43.6): `cyrius-doom --agnos` exec's from disk in ring 3, loads a 4.2 MB WAD, and blits a 240-colour frame to the framebuffer via two new kernel syscalls (`fbinfo`#38 / `blit`#39) — "agnsh launches DOOM," the **first real userland application** on the OS (QEMU-validated; iron burn pending). The console-font subsystem is **vendored from [kashi](https://github.com/MacCracken/kashi) 1.0.0** (freestanding glyph core consumed via `[deps.kashi]`). Current version in [`VERSION`](VERSION); live capability snapshot in [`docs/development/state.md`](docs/development/state.md).

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

Multi-arch kernel: `kernel/klib/` (3 files — `kstring`, `kfmt`, `ktagged`; freestanding syscall-free stdlib), `kernel/arch/x86_64/` (17 files + `usb/` subdir with 9 xHCI/HID files), `kernel/arch/aarch64/` (9 files), `kernel/core/` (35 files — storage, networking-split-into-8-protocol-files at 1.36.0/.1, filesystem stacks, selftests-split-out at 1.36.2), `kernel/user/` (4 files), plus `kernel/agnos.cyr` orchestrator, `kernel/version.cyr` auto-generated banner module (v1.30.2+), and `kernel/kernel_hello.cyr` smoke test. **External dep**: kashi 1.0.0 freestanding font-data core (`[deps.kashi]` in `cyrius.cyml`; 1.37.5 fold-in).

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
  -> ELF loader (incl. exec-from-disk: ELF64 read off the FS, run in ring 3, 1.40.x)
  -> VFS (mount-namespace routing: FAT/exFAT reachable while ext2 owns "/"), initrd, device drivers
  -> PCI bus; networking: VirtIO-Net + r8169 NIC, IP / ARP / UDP / TCP, DHCP client
  -> storage: NVMe, AHCI/SATA, USB Mass Storage, RAM-disk, VirtIO-blk —
       5-backend block layer (multi-backend probe) + GPT partition parse
  -> filesystems: ext2/ext4 (read + write + extent allocation + JBD2 journaling)
       and FAT12/16/32 + exFAT (read + write)
  -> console-font: kashi 1.0.0 freestanding glyph core (vendored via [deps.kashi])
  -> Native xHCI + USB-HID-boot keyboard driver (Phase 1-5)
  -> SMP infrastructure (APIC, IPI, trampoline, per-CPU stacks)
  -> 34 syscalls 0-33 (signals, epoll, timerfd, pipes, anonymous mmap/munmap,
       + FS syscalls getdents/unlink/rename/link/stat, 1.41.3)
  -> kybernet (PID 1) -> execs /bin/agnsh (userland shell) in ring 3;
       in-kernel shell() is the recovery REPL fallback (1.41.x)
```

## Subsystems (40+)

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
| xHCI Host Controller | Native USB 3.x host controller driver: PCIe discovery, BAR UC remap, controller init (HCRST + R/S + scratchpad + DCBAA + event ring + cmd ring), port enumeration with PORTSC strict-RW1S, Enable Slot + Address Device cmd path, MSI-X table programming. Iron-validated on archaemenid (AMD FCH 1022:1639) — the typeable-shell MVP gate at Attempt 68 / v1.30.9. |
| USB-HID-boot Keyboard | hid_kbd_configure + hid_poll + HID→PS/2 usage translation + kb_buf writer (v1.30.5; lives in kernel/arch/x86_64/usb/) |
| Page Tables | 2MB huge pages, 4GB identity map ceiling, per-process; XHCI BAR strict-UC remap (Repair X) |
| PMM | Bitmap allocator, 4096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Slab allocator, 8 size classes (32-4096B) |
| Process Table | 16 slots, 168B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space. **Exec-from-disk** (1.40.x): `vfs_read_file` slurps a whole ELF off the FS → `elf_load_from_file` → `exec_and_wait` runs it in **ring 3** (SYSCALL/SYSRET/iretq, SMAP STAC/CLAC). Iron-validated on archaemenid (`/bin/prog2`/`/bin/argv` ran ring-3). A malformed-segment validation pre-pass (1.41.6) rejects bad ELFs with zero allocations leaked. |
| Exec / process lifecycle | `run <path>` (kernel recovery shell) + `spawn`(3)/`exec`-via-`sys_spawn` (userland) load + run a ring-3 program and collect its exit code; multi-`run` per boot. Process teardown + **`proc_reap`** (1.40.14) reclaims per-process pages (U/S-bit scan) + proc-table slots on exit, and sweeps any still-open fds (1.41.10). Run-to-completion / single-foreground (preemptive ring 3 is a later arc). |
| VFS | File table, device/memfile/signalfd/epoll/timerfd/pipe types + `VFS_EXT2_DIR` dir-fd (1.41.3) + `VFS_SEC_WFILE` FAT/exFAT write-back fd (1.41.7). **Mount-namespace routing** (1.40.13): verbs/syscalls route by mount-point, so FAT/exFAT are reachable while ext2 owns `/`. Generic per-FS write/dir dispatch (`vfs_*_on`, 1.39.x) reaches FAT32 + exFAT. |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery |
| NIC drivers | **r8169** (RTL8168/8125, real-iron — PCI probe + RX/TX rings; iron-CONNECTED on archaemenid at 1.32.7) + **VirtIO-Net** (legacy PCI, QEMU) |
| IP / ARP / UDP | IPv4, ARP request/reply, UDP send/recv + 8-listener bind table |
| TCP | Client (connect/send/recv/close) + server primitives (listen/bind/accept); SYN/ACK/FIN state machine |
| DHCP client | RFC 2131 DISCOVER → OFFER → REQUEST → ACK; real lease iron-verified on archaemenid (1.32.9) |
| Block layer | 5-backend tag dispatch (NVMe / AHCI / USB-MS / VirtIO-blk / RAM-disk) + multi-backend probe + per-backend FLUSH durability barrier |
| NVMe | Phase 1-5: admin + I/O queues, READ/WRITE, PRP1/PRP2/PRP-list; iron debut Crucial P3 2 TB |
| AHCI / SATA | HBA + per-port bring-up, IDENTIFY, READ/WRITE DMA EXT; iron debut WD Blue SA510 2 TB |
| USB Mass Storage | BBB transport + SCSI (INQUIRY / TUR / READ CAPACITY / READ / WRITE) over xHCI bulk; iron debut Silicon Motion stick |
| RAM-disk / VirtIO-blk | `pmm_alloc`-backed RAM-disk + VirtIO 1.x modern virtio-blk (QEMU) |
| GPT | Header + 16 KB array walk, table-less CRC32, backup-header recovery, type-GUID classifier, `parts` shell cmd |
| ext2 / ext4 | **Read + write + extent allocation + JBD2 journaling**. Read: superblock / BGDT / inode, indirect tree + ext4 extents, 64BIT, dir walk + path resolution. Write: create / write / unlink / mkdir / rmdir / rename / ln / symlink / truncate, metadata_csum, `e2fsck -fn`-clean. Extent alloc (1.37.x): depth-0 → depth-1 grow → multi-leaf → depth-2 grow (the full on-demand grow ladder). JBD2 (1.38.x): journal-SB probe, log reader, replay-on-mount, in-memory transaction lifecycle, write path (3-barrier sync-checkpoint), `put_inode` integration. Iron-validated through 1.37.3 on real NVMe NAND (persist + extent-grow across reboot). |
| JBD2 journaling | New at 1.38.x: when a tx is active, metadata writes route through `ext2_jbd2_log_metadata` → descriptor + data + commit block in the journal log → FLUSH-CACHE barriers between each stage → checkpoint to the FS → SB-clean. Dirty journal at mount triggers replay. Sync-checkpoint model: every commit immediately checkpoints + cleans (no log fill). `jbd2-crash-smoke.sh` validates SIGKILL-at-varied-points → e2fsck-clean on next boot. |
| FAT12/16/32 | **Read + write**: partition-aware multi-backend mount, FAT-chain traversal, create / content / delete / truncate, LFN, subdirectory paths (1.39.9); `fsck.fat -n`-clean. **Content-write now reaches the syscall ABI** (`VFS_SEC_WFILE` write-fd, 1.41.7) — a userland program can write a FAT volume, not just the in-kernel shell. |
| exFAT | **Read + write**: allocation bitmap + typed dir-set (SetChecksum / NameHash) + up-case table (Unicode names) + directory growth + subdirectory paths (1.39.9); `fsck.exfat -n`-clean. Content-write reaches the syscall ABI via `VFS_SEC_WFILE` (1.41.7). |
| FS write safety | ESP-write guard — FAT/exFAT writes refused on the boot ESP partition (firmware territory); data writes go to MSFT-Basic partitions / USB sticks |
| Console font | **kashi 1.0.0** (vendored at 1.37.5): freestanding VGA 8x16 + CGA 8x8 glyph cores; `fb_console.cyr` consumes via `kashi_glyph_ptr`. The stdlib-using kashi library face (PSF1/PSF2 import, runtime registry) lives in `kashi/src/lib.cyr` and never reaches the kernel. |
| Pipes | Circular buffer IPC, read/write ends |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Signals | per-process signals/sigmask, kill, sigprocmask, signalfd |
| Epoll | epoll_create, epoll_ctl, epoll_wait |
| Timerfd | timerfd_create, timerfd_settime |
| Scheduler | Round-robin |
| Shell | **Shell separation (1.41.x).** The full interactive shell is now **agnsh** — the userland [agnoshi](https://github.com/MacCracken/agnoshi) build, exec'd from `/bin/agnsh` in ring 3 off the ext2 root (first userland binary promoted to a system component; locks the permanent kernel↔userland shell boundary). The in-kernel `shell()` shrank to a minimal **recovery REPL** (`kernel/user/shell.cyr` 1149 → 813 LOC at 1.41.9) — the boot fallback only, reached when `/bin/agnsh` is absent/unloadable. Recovery verb set: `help` `cd` `pwd` `ls` `cat` `run` `mv` `rm` `sync` `reboot` + non-write diagnostics (`uptime`/`lspci`/`cpus`/`net`/`parts`/`date`/`clear`/`version`/…). |
| kybernet Init | PID 1: `exec`s `/bin/agnsh` in ring 3 (`kybernet_exec_agnsh`, 1.41.4) and falls back to the in-kernel recovery shell only on load failure. 34 kernel syscalls ready (0-33). |

## Syscalls (34, 0-33)

The FS group (`getdents`/`unlink`/`rename`/`link`/`stat`) + the `open`(7) re-route to the mount-routed VFS + making `mkdir`(9)/`rmdir`(10)/`sync`(12) real landed at **1.41.3** (with the **`a4=r10` ABI extension** — a 4th syscall arg carried in `r10`, used by `rename`/`link`). `mmap`(27)/`munmap`(28) landed earlier (1.35.x).

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
| 26 | write_boot_checkpoint | Write CMOS[0x50] — iron-boot progress marker |
| 27 | mmap | Anonymous zero-filled 2 MB-granular mapping (1.35.x) |
| 28 | munmap | Release an mmap region + free its physical pages (1.35.x) |
| 29 | getdents | Read directory entries (agnos-native dirent records) — ext2; FAT/exFAT follow-on (1.41.3) |
| 30 | unlink | Remove a file (mount-routed: ext2 / FAT / exFAT) (1.41.3) |
| 31 | rename | Rename within one filesystem; uses `a4` for `newlen` (1.41.3) |
| 32 | link | Hard link, ext2-only; uses `a4` (1.41.3) |
| 33 | stat | Fill the 48-byte agnos stat struct from the inode — ext2 (1.41.3) |

> `open`(7) was re-routed at 1.41.3 from initrd-only to the mount-routed VFS (`AO_CREAT`/`AO_TRUNC`/`AO_DIRECTORY` flags via a3, initrd as bare-name fallback); `mkdir`(9)/`rmdir`(10)/`sync`(12) were tier-1 stubs returning 0 and are now real (mount-routed).

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
| **AGNOS** | Cyrius | 40+ subsystems, 34 syscalls (0-33), TCP/IP + DHCP + DNS + NTP + ICMP, real-iron NIC (r8169), full storage stack (NVMe / AHCI / USB-MS / VirtIO-blk + 5-backend block layer + GPT), read+write filesystems (ext2/ext4 incl. extent allocation + **JBD2 crash-safe journaling**, FAT12/16/32, exFAT), SMP, ELF loader + **exec-from-disk** (ring-3 ELF off the FS), ACPI, IOMMU, native xHCI + USB-HID-boot keyboard, sovereign UEFI handoff, vendored kashi 1.0.0 console-font core, **userland shell (agnsh) exec'd in ring 3** + in-kernel recovery REPL |
| xv6 (MIT) | C | 21 syscalls, no networking, no SMP, no real FS |
| seL4 (verified) | C/Isabelle | Microkernel only — no drivers, no FS, no networking |
| MINIX 3 | C | Microkernel + basic drivers |
| Linux (minimal) | C | Barely boots, no drivers |
| Linux (typical) | C | Desktop-ready |

A fully functional kernel with TCP/IP + DHCP + DNS + NTP, a real-iron NIC, a 5-backend block layer (NVMe / AHCI / USB-MS / VirtIO-blk / RAM-disk) + GPT, **read+write+journaled** filesystems (ext2/ext4 incl. ext4 extent allocation + JBD2 crash-safe journaling, FAT12/16/32, exFAT), SMP, signals, epoll, pipes, ACPI/IOMMU, native xHCI / USB-HID-boot keyboard, vendored kashi 1.0.0 console-font core, **exec-from-disk (a static ELF64 read off the filesystem and run in ring 3)**, and a **userland interactive shell (agnsh) exec'd from disk in ring 3** (the in-kernel shell is the recovery fallback) — written entirely in Cyrius. No C, no LLVM, no libc. The storage trio (NVMe / SATA / USB-MS), networking, ext4 read+write+extent-alloc, and exec-from-disk (1.40.x) stacks are iron-validated on real AMD hardware (archaemenid); the JBD2 journaling, FAT-family, and the 1.41.x shell-separation stacks are QEMU/`fsck`-validated with the combined iron burn user-driven.

For live binary sizes per arch (x86_64 + aarch64), per-cut size trajectory, source line counts, test surface, and ecosystem sibling pins, see [`docs/development/state.md`](docs/development/state.md) (refreshed every release). Versions intentionally elided from this table per the lib-doc precedent — the size cells drift faster than the README can be re-cut.

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
│   │   └── usb/             # xhci{,_cmd,_ctx,_port,_regs,_ring}, hid, hid_translate, msc (USB Mass Storage)
│   ├── arch/aarch64/        # boot_data, gic, timer, exceptions, paging, main, stubs, …
│   ├── core/                # pmm, vmm, heap, proc, sched, vfs, syscall, elf, devs, initrd, kprint, main,
│   │                        # boot_finish, selftests (1.36.2 declutter); pci, acpi;
│   │                        # net + net_tcp/dhcp/icmp/dns/ntp/rtc/ingress (8 net files post-1.36.0/.1 split);
│   │                        # r8169 (NIC driver); block, nvme, ahci, virtio_blk, ramdisk, gpt (storage);
│   │                        # ext2 (read+write+extent-alloc+JBD2+getdents/stat/link — 1.31.x → 1.41.x arcs), fatfs, exfat
│   └── user/                # shell (recovery REPL, 813 LOC post-1.41.9), init (kybernet execs /bin/agnsh), test, test_procs
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
│   │   ├── roadmap.md       # Shipped arcs (the at-a-glance ledger) + open items + future slots
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
