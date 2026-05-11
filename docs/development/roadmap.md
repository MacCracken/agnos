# AGNOS Kernel Roadmap

> **Current**: v1.28.3 — x86_64 + aarch64, 248KB/92KB, 26 syscalls, 35 subsystems, kernel stdlib + ACPI + IOMMU. Built with cyrius 5.10.44.
>
> Live state: [`state.md`](state.md). Per-version history: [`../../CHANGELOG.md`](../../CHANGELOG.md). Language roadmap: `../cyrius/docs/development/roadmap.md`.

## Shipped (arc summary)

Per-version detail lives in [`CHANGELOG.md`](../../CHANGELOG.md). This is the at-a-glance ledger of which arcs landed what.

| Arc | Headline |
|-----|----------|
| **v1.0.x** | First boot: scheduler (round-robin), kernel heap (slab, 8 classes), VFS, kybernet PID 1, context switch, SYSCALL/SYSRET, ELF loader, device drivers (serial), initrd, PCI bus, VirtIO-Net, IP/UDP, SMP infra (APIC/IPI/trampoline), interactive shell, APIC timer, TSS. |
| **v1.1.x** | Multi-arch split (33 files); aarch64 port (serial, GIC, timer, PMM); +17 syscalls (signals, epoll, timerfd); kybernet dual-backend (Linux + AGNOS); bench harness + CI parity. |
| **v1.11.x** | VirtIO-blk (sector R/W, DMA); FAT16 read-only; TCP (SYN/ACK/FIN state machine); pipes (VFS type 6); GRUB bootable ISO. |
| **v1.21.x** | Kernel stdlib vendored (`kstring.cyr`, `kfmt.cyr`); `cyrius.toml` + `.cyrius-toolchain` build modernization; toolchain rename (`cyrb` → `cyrius`, `cc2` → `cc3`). |
| **v1.24.x** | Cyrius toolchain bump 3.9.8 → 5.7.19 (skipped cc4 entirely); manifest migration `cyrius.toml` → `cyrius.cyml` with `${file:VERSION}` templating; CI install delegates to upstream `install.sh`; boot-shim emit-order regression fixed via cc5 v5.7.19 kmode invariant; `-cpu max` documented as required (SMEP+SMAP in CR4). |
| **v1.25.x** | Identity-map ceiling 16 MB → 4 GB (`pt_init`) — closes the latent ACPI fault at QEMU's `~0x07FE0000` region; per-process PD-copy loop mirrored to `i<511` so kernel data above 16 MB is reachable under per-process CR3; PDPT[1..3] mirror for 1–4 GB; memory-isolation test gated; CI assertion tightened to `Scheduler test done` then `Userland exec complete`. |
| **v1.26.x** | `cr3_load(cr3_val)` helper in `proc.cyr` (stack-relative inline-asm load — replaces the brittle `var x = expr; asm { mov cr3, rax }` pattern); `docs/development/issue/` folder convention introduced; cyrius pin 5.7.19 → 5.7.22 (fmt braces-in-comments fix). |
| **v1.27.x** | Cyrius pin 5.7.22 → 5.10.44 + ecosystem realignment; latent cross-arch `#ifdef` correctness fix in `proc.cyr` (4 x86-only page-table fns); **memory-isolation deeper-fault closed — root cause was SMAP**, fix is `stac`/`clac` brackets, test un-gated, CI assertion tightened to `Memory isolation: PASS`; CLAUDE.md durable-only reshape per first-party-documentation standards; new `docs/development/state.md` (volatile state) + `docs/doc-health.md` (whole-tree currency ledger); `CODE_OF_CONDUCT.md` added. |

## 1.28.x Arc Plan

The 1.27.x arc closed at v1.27.2 with an empty Active table modulo #1 (SMP-on-hardware, hardware-gated) and #7 (`serial_putc` regression — methodology gap). 1.28.x is the **closeout-and-feature** arc: ship the last open Security Hardening item (S7 KASLR) as the headline feature in `.0`, then walk down the remaining Active items in tight focused patches.

| Slot | Item | Source | Status |
|------|------|--------|--------|
| **1.28.0** | **KASLR (data-only)** | Security Hardening S7 | ✅ **Shipped 2026-05-11**. `rdrand_u64` helper, `kaslr_seed`, randomized `pmm_next_free`, two-boot-diff CI assertion. See [`CHANGELOG.md`](../../CHANGELOG.md) v1.28.0 entry. |
| **1.28.1** | **`serial_putc` methodology** | Active #7 | ✅ **Shipped 2026-05-11**. bench-history schema extended with `qemu_version` / `cpu_model` / `host_arch` / `kvm_enabled` / `cyrius_version`. Matched-conditions re-measurement confirmed the regression was QEMU UART-emulation drift, not codegen. Issue archived with full Resolution section. Active #7 closed. |
| **1.28.2** | **VFS tagged unions** | Active #2 | ✅ **Shipped 2026-05-11**. New `kernel/lib/ktagged.cyr` (inline tagged-union helpers, no heap allocation — diverges from cyrius stdlib `lib/tagged.cyr` shape). `VfsType` enum + ktag/kpayload accessor port across `vfs.cyr` + `syscall.cyr`. Boot path validates VFS, memfile, initrd, signalfd/epoll/timerfd, and pipe paths preserved. Active #2 closed. |
| **1.28.3** | **Struct refactor with `#derive(accessors)`** | Active #3 | ✅ **Partially shipped 2026-05-11.** `pci_devs` ported via `#derive(accessors)` (4 fields, clean). `vfs_table` already closed via `ktagged` at v1.28.2 (different mechanism, same goal — magic offsets removed). `proc_table` blocked on cyrius `#derive(accessors)` 16-field cap; filed at [`cyrius/issues/2026-05-11-derive-accessors-16-field-cap.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-05-11-derive-accessors-16-field-cap.md) — **acknowledged upstream and slotted for v5.11.x repair**. 2 of 3 subsystems closed; proc_table follows when agnos picks up the cyrius cap-raise (passive — pin bump only). Also lands a v1.27.x-era hygiene fix in `sched.cyr` (cr3_load helper replaces the pre-v1.26.0 brittle CR3-load pattern at the context-switch site). |

After 1.28.3 the Active table is empty modulo **SMP-on-hardware** (hardware-gated) and the proc_table derive-port residue (cyrius-gated). 1.28.4 is a P(-1) hardening / closeout patch before tagging 1.29.0.

### Carried over (not 1.28.x)

| # | Item | Notes |
|---|------|-------|
| 1 | SMP AP wakeup on real hardware | Currently QEMU-validated only. Needs hardware-in-the-loop infra (RPi4 / NUC harness on the self-hosted runner). Stays open across 1.28.x; closes when the infra lands. |

### Ordering rationale

- **KASLR first (.0)** because it's the most feature-shaped of the four — deserves the headline slot and matches the "the .0 ships the headline" pattern across the AGNOS ecosystem (e.g., 1.27.0 = toolchain alignment, 1.27.1 = memory-isolation closeout).
- **serial_putc next (.1)** because it's the tightest, lowest-risk closeout of a long-running Active item. Symmetric with 1.27.1's pattern (close a long-running carry-forward via focused .1 patch).
- **VFS tagged unions (.2)** before the struct refactor (.3) because `ktagged.cyr` is *new infrastructure* — it should ship first and prove itself in one consumer (VFS) before becoming the substrate for a broader refactor.
- **Struct refactor last (.3)** because its blast radius is largest; doing it after the other items means we apply it to a known-good kernel rather than mixing it with feature work.

This ordering is a recommendation, not a contract — any of .1/.2/.3 can swap if a finding changes the calculus. .0 should stay KASLR (the feature anchor).

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

## Security Hardening (from 2026-04-13 audit)

All 13 items shipped through v1.28.0 (S7 KASLR data-only landed). Track complete. Full audit at [`../audit/2026-04-13-security-audit.md`](../audit/2026-04-13-security-audit.md); per-item implementation history at [`security-hardening.md`](security-hardening.md). Full-binary KASLR (Option A) remains deferred to v1.29.x+ pending cyrius PIE support; see [`proposals/2026-05-11-kaslr-scope.md`](proposals/2026-05-11-kaslr-scope.md).

| # | Item | Status | Severity |
|---|------|--------|----------|
| S1 | Separate user/kernel page mappings | ✅ | HIGH |
| S2 | Per-CPU TSS + RSP0 | ✅ | HIGH |
| S3 | PMM spinlock | ✅ | MEDIUM |
| S4 | Per-process exit codes | ✅ | MEDIUM |
| S5 | Per-connection TCP RX buffers | ✅ | MEDIUM |
| S6 | Stack guard pages | ✅ | MEDIUM |
| S7 | **KASLR** (data-only scope) — randomized `pmm_next_free` per boot; defeats trivial heap-layout ROP. Full binary relocation deferred (cyrius PIE; v1.29.x+). | ✅ (v1.28.0) | MEDIUM |
| S8 | KPTI (Kernel Page Table Isolation) | ✅ (partial — PD entry 0 kept in user tables for ISR; full isolation needs 4 KB pages) | MEDIUM |
| S9 | Spectre v2 mitigations | ✅ (IBRS set/clear on SYSCALL entry/exit) | MEDIUM |
| S10 | IOMMU (VT-d) | ✅ (ACPI DMAR parsing + VT-d root/context/IO page tables) | MEDIUM |
| S11 | ARP request tracking | ✅ | LOW |
| S12 | TCP window/sequence validation | ✅ | LOW |
| S13 | Stack canaries | ✅ (RDRAND-based secret) | LOW |

## Planned (post-1.28.x)

Long-horizon items past the 1.28.x arc. Each is a feature-class lift (1.29.0+ territory).

| # | Item | Prerequisite | Notes |
|---|------|-------------|-------|
| 5 | Real filesystem (ext2) | Disk I/O (have) | FAT16 read-only at v1.11.0 is the floor; ext2 buys actual fs semantics (inodes, journaling deferrable). |
| 6 | mmap | VMM + filesystem | Needs (5) for backing files; anonymous mmap is independent and could ship first. |
| 7 | Shared memory | SMP + VMM | Builds on per-process address spaces. |
| 8 | Preemptive scheduling | Timer + SMP stable | Round-robin is cooperative today; preemptive needs careful interrupt-safe context save/restore. |
| 9 | USB support | PCI + device driver framework | XHCI is the modern path; UHCI/EHCI for legacy. Device-framework refactor would precede. |
