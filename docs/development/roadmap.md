# AGNOS Kernel Roadmap

> **Current**: v1.31.3 — x86_64 + aarch64, 26 syscalls, **40+ subsystems**, kernel stdlib + ACPI + IOMMU, **sovereign-struct entry (RDI = &boot_info)** via gnoboot v0.4.2, native xHCI + USB-HID-boot keyboard driver, **storage stack** (NVMe Phase 1-5 + AHCI/SATA Phase 1-4 + 3-backend block-layer dispatch + GPT Phase 1-3 with CRC32 + backup-header recovery + type-GUID classifier). **MVP GATE CLEARED ON IRON** — typeable shell on archaemenid at Attempt 68 (1.30.9); NVMe iron debut on Crucial P3 2 TB clean at Attempt 80 (1.31.0). Built with cyrius 5.11.x bedrock pin (toolchain itself is 6.0.1; kernel pin stays at 5.11.64 with back-compat symlinks). Live binary sizes per arch + per-cut size trajectory: [`state.md`](state.md).
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
| **v1.30.0** | **Kernel ABI break — sovereign-struct entry (Path C handoff).** Replaces multiboot2-via-GRUB (Path A, dead) with the gnoboot sovereign UEFI bootloader. Entry contract switches from `RBX = MBI ptr` to `RDI = &agnos_boot_info` (magic `0x41474E4F`). cyrius pin **5.11.43 → 5.11.53**. CI restructure: `qemu -kernel` retired; replaced with `gnoboot + OVMF + qemu-system-x86_64 -cpu max`. Pairs with gnoboot v0.1.0. |
| **v1.30.1–.4** | **xHCI Linux-diff hardening closeout**: XHCI BAR UC remap (Repair X), PORTSC strict-RW1S model, USB-HID Phase 1-3 (PCIe discovery → controller init → port enumeration), four spec gaps closed (H1: PAGESIZE validation; H2: IMAN.IP RW1C clear; H3: IMOD = 0x3E8; H4: USBCMD.HSEE). |
| **v1.30.5** | **Phase 4/5 USB-HID boot keyboard driver landed + Phase 3 silent-absorb arc closed.** `hid_kbd_configure` + `hid_poll` + HID→PS/2 mapping + `kb_buf` writer. Repair (EE) one-line fix to `xhci_portsc_write`'s inner re-mask closed the 13-hypothesis Phase 3 silent-absorb arc (Attempts 32-54 chased the wrong cause). |
| **v1.30.6** | **xHCI cmd-path arc — Repairs FF → QQ bundled (single CHANGELOG entry).** FF (IMAN.IE=1), GG (AMD-Vi disable), HH (doorbell readback), JJ (universal readback), KK (CNR poll), LL (Link TRB cycle), MM (MSI-X FuncMask), NN (ERDP/ERSTBA + CRCR/IMOD reorder per 4-source prior-art convergence), OO (Tier 2 bundle: USBSTS-clear + IMAN.IE-post-R/S + mfence + TRB-readback), QQ (MSI-X Table vector-0 programming — first arc repair tied to a named Linux-implicit divergence). 9-letter ladder closed at OO; QQ staged-not-yet-burned. |
| **v1.30.7** | Pre-MVP-gate version bump (no kernel source delta). |
| **v1.30.8** | iron Attempts 65/66/67: RR falsified, EP0 MPS reconciliation clears HID enumeration. |
| **v1.30.9** | **MVP GATE HIT** — iron Attempt 68: SET_CONFIGURATION + canonical FS interval + ISP → typeable shell on archaemenid. xHCI cmd-path arc closes via cyrius v5.11.64's gvar-init-order fix (not a kernel-side bug). |
| **v1.30.10 → .12** | FB hardening sweep — pitch-aware refresh + WC + PixelFormat guard + true-font swap (VGA 8x16 BIOS ROM replaces hand-drawn CGA 8x8). iron Attempts 69-77; VGA-path legible at 1080p + 1440p. Quiet-Boot legibility residue parked as next-cycle pin. |
| **v1.31.0** | **Storage cycle open + NVMe arc + iron debut.** Production-lean compile gates (`KTEST` / `XHCI_VERBOSE` default off + FB-absent guard + `docs/development/build.md`); NVMe Phase 1-5 (probe + admin queue + I/O queue + R/W + PRP1/2/list dispatch + `block.cyr` 3-backend wrapper); iron debut on Crucial P3 2 TB clean at Attempt 80 (first-try). |
| **v1.31.1** | **GPT layer + AHCI/SATA driver + dual iron debut.** GPT Phase 1-3 (header + full 16 KB array walk + UTF-16LE names + `parts` shell command + `gpt_partition_info(idx)` helper + table-less CRC32 + backup-header recovery + 7-GUID type classifier); AHCI/SATA Phase 1-4 (HBA probe + per-port CL+FIS bring-up + IDENTIFY DEVICE + READ/WRITE DMA EXT + block-layer registration with NVMe-primary policy); AHCI iron debut on archaemenid + WD Blue SA510 2 TB SATA SSD at Attempt 81 (PASS-WITH-CAVEAT — three carry-forward patches landed in 1.31.2 `[Unreleased]`). |
| **v1.31.2** [Unreleased] | **AHCI carry-forward + cyrius pin graduation + USB Mass Storage Phase 1-4 + Phase 2.5 + Phase 2.6 + Phase 2.7 (Attempt 86 burn pending).** AHCI carry-forward triplet (Attempt 82 PASS). cyrius pin 5.11.64 → 6.0.1 (iron-validated same burn). USB MS Phase 1-4 (BBB transport + SCSI INQUIRY/RC10/READ(10)/WRITE(10) + tertiary block_dev registration; QEMU clean; iron debut Attempt 83 PARTIAL — TUR-gate gap). Phase 2.5 device-side hardening (Reset Recovery + 3-retry TUR loop + INQUIRY hoist + REQUEST SENSE; Attempt 84 PARTIAL — recovery executes clean but transport stays wedged). Phase 2.6 controller-side xHCI commands (Reset Endpoint / Stop Endpoint / Set TR Dequeue Pointer + event-ring drain; Attempt 85 FALSIFIED). Phase 2.7 multi-source-converged repair per four-source audit (FreeBSD + OpenBSD + EDK2 + Linux confirmatory): Reset Endpoint CSE tolerance + EP-state-aware Reset Endpoint dispatch + 100ms post-BOT-Reset device stall + Reset Recovery step reorder (device-side first). Built but **Attempt 86 not yet burned**. Detail in [`msc-reset-recovery-prior-art.md` § 9](https://github.com/MacCracken/agnosticos/blob/main/docs/development/msc-reset-recovery-prior-art.md). |

## 1.30.x Arc Recap

The 1.30.x arc is the **kernel-ABI break + hardware-bring-up arc**. It opened with the sovereign-struct entry (v1.30.0, Path-C UEFI handoff via gnoboot), closed Phase 3 USB silent-absorb (v1.30.5, Repair EE), bundled the xHCI cmd-path repairs FF→QQ (v1.30.6), **hit the MVP gate at iron Attempt 68 (v1.30.9)** with the cyrius v5.11.64 gvar-init-order fix that root-caused the silent-absorb across the 9-letter repair ladder, and closed the FB-hardening sweep at v1.30.12 (true-font swap + VGA path legible at 1080p + 1440p; Quiet-Boot residue parked next-cycle). Per-attempt detail in [agnosticos iron-nuc-zen-log](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

| Item | Status | Notes |
|------|--------|-------|
| **Sovereign-struct entry + CI restructure (v1.30.0)** | ✅ shipped | RDI handoff; gnoboot+OVMF CI boot-test. Closed the `qemu -kernel` legacy path. |
| **scheduler-under-UEFI hypothesis** | ✅ resolved | The "page tables at fixed physical 0x1000/0x2000/0x3000 break under UEFI" investigation was superseded by the **2026-05-15 iron-validation milestone** (archaemenid NUC AMD Zen reached kernel CP 0x10, all 17 init checkpoints pass, `sched_active=1` survives, first hlt + timer-driven context switches succeed on real silicon). The pre-1.30.5 QEMU+OVMF stall was a `test_proc_a/b`-shape symptom resolved by Phase 4/5 progression replacing the test stubs with real boot-path procs. |
| **xHCI Linux-diff hardening (H1-H4, v1.30.4)** | ✅ shipped | PAGESIZE validation (xHCI 1.2 §5.4.3), IMAN.IP RW1C clear (§5.5.2.1), IMOD = 0x3E8 (§5.5.2.2), USBCMD.HSEE = 1 (§5.4.1.4). Closes public-beta xHCI spec-compliance debt. |
| **Phase 4/5 USB-HID kbd driver (v1.30.5)** | ✅ shipped | `hid_kbd_configure` + `hid_poll` + HID→PS/2 + `kb_buf` writer. Iron-side: code-complete, dormant on archaemenid until Enable Slot CCE gate clears. QEMU `xhci-pci` is the active validation surface. |
| **Phase 3 silent-absorb (Repair EE, v1.30.5)** | ✅ closed | 13 falsified hypotheses across Attempts 32-54 chasing "controller absorbs PORTSC.PR writes"; root cause was `xhci_portsc_write` inner re-mask `& XHCI_PORTSC_NEUTRAL` stripping the RW1S PR bit. One-line fix in `agnos@41ee6dc`. |
| **xHCI cmd-path arc FF→QQ (v1.30.6)** | ✅ closed | Nine spec-path repairs (FF-OO) falsified Attempts 57-62 on archaemenid. Root cause was traced to a **cyrius-side** kmode gvar-init-order bug (fixed in cyrius v5.11.64) — module-top `var X = INT_LITERAL` read as 0 before init block ran. Iron-validated at Attempt 68 (v1.30.9) — typeable shell. See cyrius issue `2026-05-18-gvar-init-order-zero-reads.md`. |
| **MSI-X audit + BAR memtype audit (2026-05-18)** | ✅ closed | 0 iron burns. MSI-X table programming divergence FOUND (AGNOS never wrote table → Repair QQ candidate). BAR memtype CLEAN. Audit landed before the cyrius root-cause surfaced; superseded as MVP-blocker by Attempt 68. |
| **MVP boot-to-shell gate (v1.30.9, Attempt 68)** | ✅ achieved | Typeable shell on archaemenid Beelink SER AMD Renoir. Closes the closed-beta MVP gate. |
| **FB-hardening sweep + true-font swap (v1.30.10 → .12)** | ✅ closed | VGA-path legible at 1080p + 1440p on iron. Quiet-Boot legibility residue parked as next-cycle pin (`project_amd_zen_scanout_residue`). |
| **`scripts/build.sh` cosmetic cleanup** | 🟠 trivial follow-up | Still prints `multiboot2 (ELF64): OK` + `Boot: pending shim rewrite — see ... path-a-elf64-multiboot2.md`. Both labels are out of date post-1.30.0; should reference Path C. |

## Next cycle — open items not bound to a minor

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | **AHCI iron debut on archaemenid** | ✅ closed | Attempt 81 (2026-05-20) — WD Blue SA510 2 TB SATA SSD enumerated end-to-end, LBA-5 round-trip PASSED on real silicon; PASS-WITH-CAVEAT due to post-RW IDENTIFY hang on registration path. **All three carry-forward patches landed in 1.31.2 `[Unreleased]`** (`ahci_port_wait_idle` quiescence gate / ATA-string right-trim / `AHCI_RW_DEMO` compile gate). |
| 2 | **AMD Zen Quiet-Boot scanout residue** | parked | Next-cycle pin. Resumption options: HUBP `clear_tiling` port OR shadow-buffer FB-console architectural eval. Doesn't block MVP (VGA-path legible). |
| 3 | **USB Mass Storage (BBB + SCSI)** | Phase 1-4 + 2.5 + 2.6 + 2.7 all in 1.31.2 `[Unreleased]`; Attempt 86 burn pending | Third iron-validatable block backend; extends xHCI investment. Multi-source prior art (FreeBSD + OpenBSD + EDK2 + Linux). Iron stick: Silicon Motion `VID=0x090C PID=0x1000`. |
| 4 | **Optical via USB MS (SCSI MMC profile)** | held in 1.31.2 (deferred until USB MS transport unblocked via Attempt 86) | Promoted from previously-punted "1.32.x+ ATAPI/AHCI" slot. ~200 LOC additional over USB MS. **First non-512-B-sector block device on AGNOS.** Iron target: HP external USB Blu-ray on archaemenid (Pitch Black BD-25 loaded). |
| 5 | **RAM-disk backend** | planned 1.31.3 | Pure-RAM `/dev/ram0`-equivalent (~150 LOC over `pmm_alloc` + tag-dispatch). Useful for tests + initrd-style workflows. |
| 6 | **VirtIO-blk modern (1.x)** | planned 1.31.3 | Upgrade existing transitional 0.9.5 `virtio_blk.cyr` to MMIO + feature negotiation (~600 LOC delta). Keeps QEMU as a first-class dev target on modern machine types. |
| 7 | **ext2 read-only** | planned 1.31.4 (displaced from 1.31.3) | Filesystem class, not device class. FAT16 → ext2 unlocks real Linux disks; consumes GPT + block layer. |
| 8 | **Bench-history snapshot in repo** | open | Decide: check in last-released `BENCHMARKS.md` + `bench-history.csv` as a tagged-state reference, or leave CI-only. Original v1.27.1 carry-forward. |
| 9 | **`mmap` (anonymous-only)** | open | Planned #6 split — anonymous mmap is independent of ext2. Adds VMM surface but no fs work. |
| 10 | **Hardware-validation infra** | open | RPi4 / NUC harness on self-hosted runner. Unblocks SMP-AP-wakeup-on-real-hardware. |
| 11 | **SMP AP wakeup on real hardware** | open | QEMU-validated only. Gated on #10. |
| 12 | **`scripts/build.sh` cosmetic banner cleanup** | open | Trivial label refresh for Path-C era. |

Explicitly **NOT** in the near-term queue:
- **Full-binary KASLR (Option A)** — slot pushed beyond 1.31.x; gated on cyrius v6.1.x PIE support (see below). The 1.31.0 slot originally reserved for this was repurposed for the storage arc (NVMe Phase 1-5 + iron debut).
- **Preemptive scheduling (Planned #8)** — deep rewrite of scheduler + IRQ handlers; own-arc.

## Full-Binary KASLR (Option A) — slot TBD on the cyrius v6.1.x PIE track

Reserved for whichever minor lands once cyrius PIE codegen ships. **Originally slotted at 1.31.0**, then pushed back through three slot moves:
1. **1.30.0 → 1.31.0**: 1.30.0 got repurposed for the Path-C sovereign-struct kernel ABI break (architecturally more important + time-pressured by iron-boot MVP).
2. **1.31.0 → 1.32.x+**: 1.31.0 got repurposed for the storage arc (NVMe Phase 1-5 + iron debut + cycle-open production-lean); 1.31.1 carries GPT + AHCI/SATA. The compounded storage-arc velocity made deferring KASLR-Option-A the right call.

Closes the deferred Option A from `proposals/2026-05-11-kaslr-scope.md` — the data-KASLR shipped at 1.28.0 covers ~80% of the security value; Option A closes the last ~20% (gadgets pre-computed against the kernel binary itself, which currently sits at fixed `0x100000`).

**Hard prerequisite**: cyrius v6.1.x PIE codegen support. Filed at [cyrius/proposals/2026-05-11-pie-support.md](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md); slotted on the cyrius v6.x track after v6.0.0 (rename + cleanup arc).

When cyrius PIE lands, KASLR-Option-A work can begin in parallel with whatever 1.3x.y cycle is active. agnos doesn't kludge a hand-rolled relocation table (rejected in both proposals for the same reasons). Actual slot depends on cyrius ship cadence, not agnos's.

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

All 13 items shipped through v1.28.0 (S7 KASLR data-only landed). Track complete. Full audit at [`../audit/2026-04-13-security-audit.md`](../audit/2026-04-13-security-audit.md); per-item implementation history at [`security-hardening.md`](security-hardening.md). Full-binary KASLR (Option A) was originally slotted for v1.31.0 but the slot got repurposed for the storage arc; KASLR-Option-A now sits on the **cyrius v6.1.x PIE track** with slot TBD on agnos's side. See § *Full-Binary KASLR (Option A)* above and [`proposals/2026-05-11-kaslr-scope.md`](proposals/2026-05-11-kaslr-scope.md).

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
