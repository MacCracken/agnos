# AGNOS Kernel Roadmap

> **Current**: v1.27.2 — x86_64 + aarch64, 248KB/92KB, 26 syscalls, 35 subsystems, kernel stdlib + ACPI + IOMMU. Built with cyrius 5.10.44.

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

## Completed (v1.24.0)

| # | Item | Version |
|---|------|---------|
| 32 | Cyrius toolchain bump 3.9.8 → 5.7.19 (skipped cc4 entirely) | v1.24.0 |
| 33 | Manifest migration `cyrius.toml` → `cyrius.cyml` (`${file:VERSION}` templating) | v1.24.0 |
| 34 | Removed `.cyrius-toolchain` — pin lives only in `cyrius.cyml` (kybernet convention) | v1.24.0 |
| 35 | CI install delegates to upstream `install.sh` release asset (no hand-rolled curl/tar) | v1.24.0 |
| 36 | Boot regression fixed via cyrius v5.7.19 kmode emit-order swap (top-level asm before gvar inits) | v1.24.0 |
| 37 | QEMU Boot Test job removed `continue-on-error: true`; asserts on serial banner | v1.24.0 |
| 38 | `-cpu max` documented as required (boot shim sets SMEP+SMAP in CR4) | v1.24.0 |

Binary size delta vs v1.22.0 peak: **−11 KB** (260 KB → 248,720 B). Same source,
cc5's pass-2 dead-code reporter eliminates ~24 KB of unreachable functions.

## Completed (v1.24.1)

| # | Item | Version |
|---|------|---------|
| 39 | H1: comment on `kernel/agnos.cyr` boot-shim include citing cc5 v5.7.19 kmode invariant | v1.24.1 |
| 40 | H2: annotated `kernel/arch/x86_64/boot_shim.cyr` raw asm bytes with mnemonics + 12-step boot sequence header | v1.24.1 |

Comments-only patch, zero behavioral change (kernel binary still 248,720 B,
boots clean under cyrius 5.7.19 + `-cpu max`).

## Completed (v1.25.0)

| # | Item | Version |
|---|------|---------|
| 41 | Identity-map ceiling 16 MB → 4 GB in `pt_init` (PD covers 0–1 GB at 2 MB granularity, PDPT[1..3] hold 1 GB huge pages for 1–4 GB). Closes the latent v1.22.0 ACPI fault — RSDT walk at QEMU's ~0x07FE0000 region now succeeds | v1.25.0 |
| 42 | CI QEMU Boot Test assertion tightened from `grep -q "AGNOS"` (line 1, useless) to `grep -q "Scheduler test done"` (post-ACPI/PCI/IOMMU/scheduler checkpoint) | v1.25.0 |
| 43 | v1.24.2 abandoned — its doc-only edits (README, CLAUDE.md, overview.md) folded into v1.25.0 alongside the kernel fix | v1.25.0 |

Binary: 248,720 B → 248,848 B (+128 B for the extra PD entries +
PDPT writes). Boot output now reaches `"Scheduler test done. Timer
ticks: 154"` past the previous triple-fault point. Closes proposal
[`2026-04-27-acpi-identity-map-ceiling.md`](proposals/archive/2026-04-27-acpi-identity-map-ceiling.md).

## Completed (v1.25.1)

| # | Item | Version |
|---|------|---------|
| 44 | `proc_create_address_space()` PD-copy loop bound `i<8` → `i<511` (mirrors kernel's 1 GB identity map into per-process page tables). Same shape as v1.25.0's pt_init fix, different file | v1.25.1 |
| 45 | PDPT[1..3] mirrored into per-process PDPT so kernel data above 1 GB is reachable from per-process CR3 too | v1.25.1 |
| 46 | Memory-isolation test gated behind `#ifdef MEMORY_ISOLATION_TEST` (skipped in default builds) — surfaces a deeper cr3-dance fault that needs separate diagnosis | v1.25.1 |
| 47 | CI QEMU Boot Test assertion tightened to `"Userland exec complete"` (past the memory-isolation gate, through `spawn_user_proc`) | v1.25.1 |
| 48 | Resolved proposals archived to `docs/development/proposals/archive/` | v1.25.1 |

Binary: 248,848 B → 247,768 B (−1080 B; gated test code goes
through DCE in default builds). Boot now reaches the benchmark
harness and halts cleanly.

## Completed (v1.26.0)

| # | Item | Version |
|---|------|---------|
| 49 | `kernel/core/proc.cyr` `cr3_load(cr3_val)` helper using stack-relative inline-asm load (same pattern as `outb`). Replaces the brittle `var x = expr; asm { mov cr3, rax }` pattern in the memory-isolation test | v1.26.0 |
| 50 | `docs/development/issue/` folder convention introduced (parallel to `proposals/`); bugs go in `issue/`, improvements go in `proposals/`. Both have `archive/` sub-folders | v1.26.0 |
| 51 | Investigation docs filed for residual #6 (memory-isolation deep fault) and #7 (serial_putc benchmark regression) — neither fully resolved, both have detailed forensics + next-step plans | v1.26.0 |

Binary: 247,768 B → 247,816 B (+48 B for the `cr3_load` helper).
Boot still passes the `Userland exec complete` CI checkpoint.

## Completed (v1.27.1)

| # | Item | Version |
|---|------|---------|
| 52 | Memory-isolation deeper-fault root cause: **SMAP**. `proc_map_page` writes US=1 (`0x87`) per-process PD entries; boot shim's `CR4=0x300020` enables SMAP; kernel-mode `store64` to US=1 page → `#PF` → `#GP` → `#DF` → triple fault. Test now uses `stac`/`clac` brackets around each user-page access | v1.27.1 |
| 53 | `MEMORY_ISOLATION_TEST` `#ifdef` gate removed; test always runs in default builds and asserts `Memory isolation: PASS` | v1.27.1 |
| 54 | CI QEMU Boot Test assertion tightened to require `"Memory isolation: PASS"` (in addition to `"Userland exec complete"`) | v1.27.1 |
| 55 | `version-bump.sh` now re-syncs the roadmap's `Built with cyrius X.Y.Z` trailer from `cyrius.cyml`, closing a stale-string class of bug surfaced in v1.27.0 | v1.27.1 |
| 56 | Resolved issue docs archived: `memory-isolation-deep.md` (closed by SMAP fix), `cr3-load-helper.md` (its v1.26.0 fix was sufficient — test now works fully end-to-end) | v1.27.1 |

## Active

| # | Item | Notes |
|---|------|-------|
| 1 | SMP AP wakeup on real hardware | Currently QEMU-validated only |
| 2 | Tagged unions for VFS entry types | ktagged.cyr kernel stdlib |
| 3 | Struct refactor with #derive(accessors) | proc_table, vfs_table, pci_devs |
| 7 | **`serial_putc` benchmark regression vs v1.21.0** (rolling from v1.25.1 #7) | Disassembled — only ~5–6 cycles/call of real cc5 codegen overhead. Bulk of the 3,000+ cyc/op delta is almost certainly QEMU 7.x → 11.x UART-emulation noise + host-CPU drift between bench runs. Filed as [`issue/2026-04-27-serial-putc-cc5-regression.md`](issue/2026-04-27-serial-putc-cc5-regression.md) recommending **defer** pending matched-conditions re-measurement. |

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
| S8 | ~~**KPTI (Kernel Page Table Isolation)**~~ | Done (partial — PD entry 0 kept in user tables for trampoline/ISR; full isolation needs 4KB pages) | MEDIUM |
| S9 | ~~**Spectre v2 mitigations**~~ | Done (IBRS set/clear on SYSCALL entry/exit; retpoline deferred to compiler) | MEDIUM |
| S10 | ~~**IOMMU (VT-d)**~~ | Done (ACPI RSDP/RSDT/DMAR parsing + VT-d root/context/IO page tables + DMA restricted to first 16MB) | MEDIUM |
| S11 | ~~**ARP request tracking**~~ | Done | LOW |
| S12 | ~~**TCP window/sequence validation**~~ | Done | LOW |
| S13 | ~~**Stack canaries**~~ | Done (RDRAND-based secret, manual in ksyscall/elf_load/net_handle_tcp) | LOW |

### Dependency chain

```
S1 (user/kernel page split)
├── S8 (KPTI) ── S9 (Spectre)
└── S6 (guard pages — needs 4KB page support)

S2 (per-CPU TSS)
└── S3 (PMM spinlock)

S4, S5, S7, S10-S13 are independent
```

## Hygiene (post-v1.26.1)

H1 shipped in v1.24.1, H2 shipped in v1.24.1, H3 closed upstream
in cyrius v5.7.22 and inherited by agnos via the v1.26.1 pin bump.
No open hygiene items.

## Planned

| # | Item | Prerequisite |
|---|------|-------------|
| 5 | Real filesystem (ext2) | Disk I/O |
| 6 | mmap | VMM + filesystem |
| 7 | Shared memory | SMP + VMM |
| 8 | Preemptive scheduling | Timer + SMP stable |
| 9 | USB support | PCI + device driver framework |
