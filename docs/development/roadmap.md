# AGNOS Kernel Roadmap

> **Current**: v1.30.3 — x86_64 + aarch64, ~245KB/91KB, 26 syscalls, 35 subsystems, kernel stdlib + ACPI + IOMMU, **sovereign-struct entry (RDI = &boot_info)** via gnoboot v0.1.0. Built with cyrius 5.11.55.
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
| **v1.28.x** | **KASLR (data-only)** — Security Hardening **track fully closed (13/13)**: `rdrand_u64` helper, `kaslr_seed`, randomized `pmm_next_free`, two-boot-diff CI assertion. **`serial_putc` methodology**: bench-history provenance schema (qemu_version / cpu_model / host_arch / kvm_enabled / cyrius_version) — matched-conditions re-measure showed the "regression" was QEMU UART-emulation drift, not codegen. **VFS tagged unions** via new `kernel/lib/ktagged.cyr` (inline tagged-union helpers, no heap alloc). **Struct refactor** (partial): `PciDev` `#derive(accessors)` ✅, `vfs_table` counted (ktagged port), `proc_table` blocked on cyrius v5.11.x cap-raise (16-field metadata-table overflow filed upstream, acknowledged + slotted). `sched.cyr` `cr3_load` hygiene fix (replaces v1.27.x-era brittle CR3-load pattern). 1.29.0 is the arc gate. |
| **v1.29.x** | Cyrius pin **5.10.44 → 5.11.x**; `Process` `#derive(accessors)` port (passive — landed at pin bump); minor follow-ups on the 1.28.x carry-forward. Gate cut at v1.29.1 ahead of the Path A→C transition. |
| **v1.30.0** | **Kernel ABI break — sovereign-struct entry (Path C handoff).** Replaces multiboot2-via-GRUB (Path A, dead) with the gnoboot sovereign UEFI bootloader. Entry contract switches from `RBX = MBI ptr` (multiboot2 § 8.4.3) to `RDI = &agnos_boot_info` (magic `0x41474E4F = 'AGNO'`, layout in agnosticos's path-c plan). `kernel/arch/x86_64/mbi.cyr` asm byte `0x18 → 0x38`; `mbi_capture_rbx → boot_info_capture_rdi`; `mb_info_ptr → boot_info_ptr`. cyrius pin **5.11.43 → 5.11.53**. **CI restructure**: `qemu -kernel` retired (ELF64 has no PVH note; QEMU rejects); replaced with `gnoboot + OVMF + qemu-system-x86_64 -cpu max` boot-test. Pairs with gnoboot v0.1.0. |

## 1.30.x Arc Plan — scheduler-under-UEFI + iron Attempt 5

The 1.30.0 kernel ABI break was the gate cut; 1.30.x is the **stabilization arc** that follows. Two known open items, both surfaced post-handoff under gnoboot+OVMF.

| Slot | Item | Source | Notes |
|------|------|--------|-------|
| **1.30.0** | **Sovereign-struct entry + CI restructure** | this arc opener | ✅ shipped. RDI handoff; gnoboot+OVMF CI boot-test; CI asserts banner + KASLR two-boot-diff + `Activating scheduler`. |
| **1.30.x** | **scheduler/page-table breakage under UEFI** | [state.md § Open investigation](state.md#open-timer-driven-context-switch-broken--deeper-than-test_proc-alone) | gnoboot delivers cleanly; kernel reaches `Activating scheduler` then 10 context switches succeed; cycle breaks. Suspected: `pt_init` writes to fixed-physical `0x1000/0x2000/0x3000` (only valid under multiboot1's seeded shim, NOT under UEFI); `apic_init` maps `0xFEE00000` via same broken page tables; per-process PT templates corrupted. Fix path: stop assuming fixed-physical page-table location — `pmm_alloc` the kernel PML4/PDPT/PD too, or detect UEFI vs `-kernel` boot and branch. Once fixed, re-tighten CI back to `Memory isolation: PASS` + `Userland exec complete`. |
| **1.30.x** | **Iron Attempt 5 on NUC AMD** | [agnosticos iron-nuc-zen log](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) | gnoboot v0.1.0 + agnos v1.30.0 USB re-provision via `agnosticos/scripts/install-usb.sh`. Real iron may behave differently from OVMF (NUC AMD Zen has RDRAND natively; APIC routing differs; different memory layout). If iron boots through to scheduler, the QEMU-OVMF-specific bug may not apply. If iron also stalls, the kernel fix is critical for closed-beta MVP. |
| **1.30.x** | **Cosmetic cleanup** | follow-up | `scripts/build.sh` still prints `multiboot2 (ELF64): OK` + `Boot: pending shim rewrite — see ... path-a-elf64-multiboot2.md`. Both labels are out of date post-1.30.0; should reference Path C. Trivial. |

Order within 1.30.x is **iron-first**: Attempt 5 is the cheapest signal (~30 min reboot vs. hours of kernel debugging), and its outcome shapes scheduler-fix priority. If iron passes, scheduler-fix gets normal-priority slot. If iron also stalls, scheduler-fix becomes the iron-unblock.

## 1.29.x Arc Plan

The 1.28.x arc closed at v1.29.0 (the gate cut — closeout findings from the 4-slot arc captured there). 1.29.x is a **scoped-feature arc**: pick up the cyrius v5.11.x dependency (proc_table derive port lands passively at pin bump) and walk down the longer-horizon "Planned" items in focused patches. **1.30.0 is reserved for full-binary KASLR (Option A)**; the 1.29.x arc explicitly does *not* try to do that — it builds the runway.

| Slot | Item | Source | Notes |
|------|------|--------|-------|
| **1.29.0** | **1.28.x closeout gate** | this arc opener | ✅ shipped. Closes the 1.28.x arc cleanly, opens 1.29.x. |
| **1.29.1** | **`Process` `#derive(accessors)` port** | Active #3 residue | Passive — depends on cyrius v5.11.x cap-raise landing first. Once the cyrius pin bump arrives, re-add `#derive(accessors)` to `struct Process` + port consumers (proc.cyr wrappers, sched.cyr save/restore, main.cyr exec_pid load). Small follow-up. |
| **1.29.2** | **Bench-history snapshot in repo** | post-1.27.2 carry | Decide: check in last-released `BENCHMARKS.md` + `bench-history.csv` as a tagged-state reference (matches what `release.yml` already attaches as release artifact), or leave the CI artifact as the only source. Small operational item; resolvable in one cut. |
| **1.29.3+** | **`mmap` (anonymous-only)** | Planned #6 (split) | Anonymous mmap is independent of ext2; can ship without a real filesystem. Adds VMM surface but no fs work — reasonable next bite after the small items. File-backed mmap waits for ext2 (post-1.30). |
| **1.29.x** | **Hardware-validation infra** | Active #1 unblock | RPi4 / NUC harness on the self-hosted runner. Unblocks SMP-AP-wakeup-on-real-hardware (Active #1). Cross-cuts CI work, not kernel work — slottable any time. |

Order beyond 1.29.1 is loose — the arc shape will firm up as we ship. Notable items that are **explicitly NOT in 1.29.x**:

- **Full-binary KASLR (Option A)** — pushed from 1.30.0 to **1.31.0** (the 1.30.0 slot got repurposed for the Path C sovereign-struct kernel ABI break). Still gated on cyrius v6.1.x PIE support. See [`proposals/2026-05-11-kaslr-scope.md`](proposals/2026-05-11-kaslr-scope.md) and [cyrius/proposals/2026-05-11-pie-support.md](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md).
- **ext2 (Planned #5)** — too big for a sub-patch slot; would consume an entire minor. Deferred to its own arc (1.32.x candidate; could move earlier if mmap shows the need urgently).
- **Preemptive scheduling (Planned #8)** — deep rewrite of scheduler + IRQ handlers. Same reasoning as ext2: own-arc territory. The v1.28.3 `sched.cyr` `cr3_load` hygiene is one prerequisite already in place.

### Carried over (not 1.29.x)

| # | Item | Notes |
|---|------|-------|
| 1 | SMP AP wakeup on real hardware | QEMU-validated only. Closes once hardware-validation infra lands (a 1.29.x candidate slot — but the kernel-side AP-wakeup work itself is post-infra). |

## 1.31.0 — Full-Binary KASLR (Option A)

Reserved slot for the major-minor headline (pushed back from 1.30.0 — that slot got repurposed for the sovereign-struct kernel ABI break, which is more architecturally important and time-pressured by the iron-boot MVP). Closes the deferred Option A from `proposals/2026-05-11-kaslr-scope.md` — the data-KASLR shipped at 1.28.0 covers ~80% of the security value; Option A closes the last ~20% (gadgets pre-computed against the kernel binary itself, which currently sits at fixed `0x100000`).

**Hard prerequisite**: cyrius v6.1.x PIE codegen support. Filed at [cyrius/proposals/2026-05-11-pie-support.md](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md); slotted on the cyrius v6.x track after v6.0.0 (rename + cleanup arc).

If cyrius PIE arrives during 1.30.x, 1.31.0 work can begin in parallel with late 1.30.x slots. If cyrius PIE doesn't arrive in time, 1.31.0 holds — agnos doesn't kludge a hand-rolled relocation table (rejected in both proposals for the same reasons). 1.31.0's exact slot depends on cyrius's actual ship cadence, not agnos's.

**Work surface (when cyrius PIE is available):** roughly per the original kaslr-scope proposal § "Option A" — boot shim grows ~2× (relocation walk + slid entry), kernel binary rebuilt with `--pie`, slide-aware crash-dump symbolizer, CI assertion rewrite (current `KASLR: pmm_next_free=N` probe stays; new `KASLR: kernel_slide=0x<hex>` probe lands alongside). Two-boot-diff assertion extended to cover the binary base.

Pre-cyrius prep (no-op until PIE lands, but useful to think about):
- Audit any remaining absolute-address assumptions in source (we already moved `proc_table` accessors, VFS slots, PciDev offsets to named accessors — those are pre-existing wins that reduce the audit surface).
- The 1.30.x scheduler-under-UEFI investigation (above) will surface every fixed-physical-address assumption in `pt_init` / `apic_init` / `proc_create_address_space` — much of that audit ends up being a prerequisite for KASLR too.
- Document the slide-aware debug pattern in CLAUDE.md's Architecture Notes ahead of the implementation.
- Decide whether the slide range stays at 64 MB (boot-shim-friendly) or grows to full 4 GB (more entropy, more page-table work).

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

All 13 items shipped through v1.28.0 (S7 KASLR data-only landed). Track complete. Full audit at [`../audit/2026-04-13-security-audit.md`](../audit/2026-04-13-security-audit.md); per-item implementation history at [`security-hardening.md`](security-hardening.md). Full-binary KASLR (Option A) is **slotted for v1.31.0** (pushed from v1.30.0, which got repurposed for the Path C sovereign-struct ABI break) pending cyrius v6.1.x PIE support; see [`proposals/2026-05-11-kaslr-scope.md`](proposals/2026-05-11-kaslr-scope.md).

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

## Planned (post-1.31.0)

Long-horizon items past the 1.31.0 cut. Each is a feature-class lift in its own right.

| # | Item | Prerequisite | Notes |
|---|------|-------------|-------|
| 5 | Real filesystem (ext2) | Disk I/O (have) | FAT16 read-only at v1.11.0 is the floor; ext2 buys actual fs semantics (inodes, journaling deferrable). |
| 6 | mmap | VMM + filesystem | Needs (5) for backing files; anonymous mmap is independent and could ship first. |
| 7 | Shared memory | SMP + VMM | Builds on per-process address spaces. |
| 8 | Preemptive scheduling | Timer + SMP stable | Round-robin is cooperative today; preemptive needs careful interrupt-safe context save/restore. |
| 9 | USB support | PCI + device driver framework | XHCI is the modern path; UHCI/EHCI for legacy. Device-framework refactor would precede. |
