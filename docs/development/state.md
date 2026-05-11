---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-05-11 (v1.27.1 cut) | **Refresh cadence**: every release, ideally by `scripts/version-bump.sh`. If a row above goes stale by more than a minor's worth of work, the row is wrong — fix it or move it.
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.28.3** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **5.10.44** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-05-11 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Last assertion tightened** | `Memory isolation: PASS` | CI `boot-test` job, v1.27.1 |

---

## Build artifacts

Measured under cyrius 5.10.44, `CYRIUS_NO_WARN_SHADOW_LIB=1`, default
DCE behavior. All sizes are from `wc -c` on `build/agnos*` after
`scripts/build.sh` / `scripts/build.sh --aarch64`.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **248,896 B** (~243 KB) | Multiboot1 ELF, entry `0x100060`. Boots under `qemu-system-x86_64 -cpu max`. |
| aarch64 | `build/agnos-aarch64` | **92,216 B** (~90 KB) | Cross-compiled. DTB + EL2→EL1 + PL011 UART + GIC. Compile-tested only — boot harness not yet wired. |

x86_64 size moved 247,752 → 248,896 (+1,144 B) at v1.27.1 from un-gating the
memory-isolation test surface. aarch64 size moved 95,328 → 92,216 (−3,112 B)
at v1.27.0 from the `#ifdef ARCH_X86_64` guards on x86-specific page-table
fns in `proc.cyr` (dead-code dropped under DCE).

---

## Source rollup

| Tree | Files | Notes |
|---|---|---|
| `kernel/` (total) | **49** `.cyr` | 6,306 lines across all kernel sources |
| `kernel/agnos.cyr` | 1 | Main orchestrator — only `#ifdef` + `include` |
| `kernel/kernel_hello.cyr` | 1 | Minimal smoke test |
| `kernel/lib/` | 2 | `kstring.cyr`, `kfmt.cyr` — vendored kernel-safe stdlib |
| `kernel/arch/x86_64/` | 14 | boot_shim, boot_data, serial, gdt, idt, pic, apic, smp, keyboard, paging, io, syscall_hw, ring3, iommu |
| `kernel/arch/aarch64/` | 9 | boot_data, serial, gic, timer, exceptions, keyboard, paging, stubs, main |
| `kernel/core/` | 18 | pmm, vmm, heap, proc, sched, syscall, vfs, devs, initrd, kprint, main, net, virtio_net, virtio_blk, fatfs, pci, acpi, elf |
| `kernel/user/` | 4 | shell, init, test, test_procs |

---

## Subsystem status (35)

All subsystems are **complete** through v1.27.1. The roadmap's "Active" table
is the source of truth for in-flight work; this is the shipped surface.

| Subsystem | Notes |
|---|---|
| Boot (multiboot1, 32→64 shim) | 32-bit ELF entry, long mode transition (x86_64) |
| Boot (aarch64) | DTB, EL2→EL1, PL011 UART, GIC, ARM timer |
| Serial I/O | COM1 `0x3F8` (x86_64), PL011 UART (aarch64) |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default `iretq` handler |
| PIC | 8259A, ICW1–4, remap to INT 32+ |
| Local APIC | MMIO at `0xFEE00000`, timer, IPI |
| GIC | ARM GICv2 interrupt controller (aarch64) |
| Timer | APIC periodic ~100 Hz (x86_64), ARM generic timer (aarch64) |
| Keyboard | PS/2 full US QWERTY (x86_64), UART RX (aarch64) |
| Page Tables | 2 MB huge pages, 16 MB identity map, per-process |
| PMM | Bitmap, 4,096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages |
| Kernel Heap | Slab allocator, 8 size classes (32–4,096 B) |
| Process Table | 16 slots, 168 B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| Scheduler | Round-robin |
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
| Pipes | Circular buffer IPC, read/write ends, VFS type 6 |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Shell | 19 commands |
| kybernet Init | PID 1 |
| Signals | per-process `proc_signals` / `proc_sigmask`, `kill`, `sigprocmask`, `signalfd` |
| Epoll + Timerfd | `epoll_{create,ctl,wait}`, `timerfd_{create,settime}` |

### Syscall surface (26)

`exit`(0), `write`(1), `getpid`(2), `spawn`(3), `waitpid`(4), `read`(5),
`close`(6), `open`(7), `dup`(8), `mkdir`(9), `rmdir`(10), `mount`(11),
`sync`(12), `reboot`(13), `pause`(14), `getuid`(15), `kill`(16),
`sigprocmask`(17), `signalfd`(18), `epoll_create`(19), `epoll_ctl`(20),
`epoll_wait`(21), `timerfd_create`(22), `timerfd_settime`(23),
`umount`(24), `pipe`(25).

---

## Ecosystem (userland boot stack)

The kernel itself has zero deps (`[deps] stdlib = []` in `cyrius.cyml`).
What boots on top of it:

```
kybernet (PID 1) v1.2.0
├── agnosys v1.2.5     — syscall bindings (Linux x86_64 + aarch64 wrappers)
├── agnostik v1.2.2    — shared types/primitives (error/security/agent/telemetry)
├── argonaut v1.6.3    — service lifecycle, health, seccomp/Landlock, PID-1 harness
│   └── libro v2.6.2   — cryptographic audit chain
└── daimon v1.2.3      — agent orchestrator
```

All Cyrius 5.10.44 (single-pin stack). **agnosys 1.2.6+ jumped to cyrius
5.11.x**; the stack stays on agnosys 1.2.5 to keep one pin until the
ecosystem migrates together. See [`CHANGELOG.md` 1.27.0](../../CHANGELOG.md)
for the alignment rationale.

---

## Test surface

| Gate | Count | Source |
|---|---|---|
| `scripts/check.sh` | **11/11** PASS | build, test, doc-exists ×6, version-in-kernel, version-in-changelog, binary-size |
| `scripts/test.sh --all` | **7/7** PASS | x86 builds, multiboot ELF, size, kernel_hello builds; aarch64 compiles, size, valid ELF |
| CI `boot-test` (QEMU) | banner + `Memory isolation: PASS` + `Userland exec complete` | `.github/workflows/ci.yml` `boot-test` job |
| CI `Format check` | 47/47 fmt-clean (1 skip: `kernel/user/shell.cyr` per `#ifdef`-in-fn-body carve-out) | `ci.yml` `check` job |

CI runs on a self-hosted runner labeled `[self-hosted, linux, x64]` for
`boot-test` and `benchmarks` (need QEMU + KVM-class CPU); `build`, `check`,
`test`, `security`, `docs` run on `ubuntu-latest`.

---

## In-flight (roadmap snapshot)

Source: [`docs/development/roadmap.md`](roadmap.md) `## Active` section.

| # | Item | Status |
|---|---|---|
| 1 | SMP AP wakeup on real hardware | QEMU-validated only; needs hardware |
| 2 | Tagged unions for VFS entry types | `ktagged.cyr` design pending |
| 3 | Struct refactor with `#derive(accessors)` | proc_table, vfs_table, pci_devs |
| 7 | `serial_putc` benchmark regression (rolling from v1.25.1) | Issue doc recommends defer pending matched-conditions re-measure — methodology gap, not a real bug |

Recently closed (see [`CHANGELOG.md`](../../CHANGELOG.md) and roadmap §
"Completed (v1.27.1)"):
- **v1.27.1** — memory-isolation deeper fault closed (root cause: SMAP); test un-gated; CI assertion tightened
- **v1.27.0** — cyrius pin 5.7.22 → 5.10.44; ecosystem realignment; CI fmt-check fixed for 5.10.x silent `--check` semantics

---

## Verification hosts

| Host | Purpose | Status |
|---|---|---|
| Self-hosted GH runner (`agnos-runner`) | CI boot-test + benchmarks on real KVM | Active |
| Dev box (Arch, Linux 7.0.3, QEMU 11.0) | Local builds, boot, bench | Active |
| QEMU `-cpu max` x86_64 | Required for boot (boot shim sets SMEP+SMAP in CR4 — `qemu64` default lacks both, triple-faults) | — |
| QEMU `-M virt -cpu cortex-a57` aarch64 | Build target; live boot not yet wired | Compile only |

---

## What changed at v1.27.1

See [`CHANGELOG.md`](../../CHANGELOG.md) for the narrative.
Mechanical diff: 12 files modified, 121 added, 23 removed; two issue
docs archived (`memory-isolation-deep.md`, `cr3-load-helper.md`).
