---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-05-25 PM (**1.33.3 cycle OPEN — ext2/ext4 WRITE dirent recompositions; 1.33.1 + 1.33.2 RELEASED**). The 1.31.x storage arc closed across 1.31.0 → 1.31.7 with five iron debuts (NVMe Crucial P3 / AHCI WD Blue SA510 / USB-MS SMI stick / RAM-disk + VirtIO modern paravirt / ext4 mount on real NVMe NAND) — `[1.31.x]` receipts in `CHANGELOG.md`. The **1.32.x networking arc** (1.32.0 → 1.32.9) closed COMPLETE: kernel TCP/UDP server primitives + DHCP client RFC 2131 + r8169 Phase 1-4 driver, with the hard problem — **r8169 RX of UNICAST frames** — SOLVED at **1.32.7** (RX ring 16→64; delivery capacity, not the MAC filter; `missed` collapsed 176→0, both on-LAN and off-LAN TCP handshakes complete on iron) → **1.32.8** diagnostics-gating + shell-cmd de-hardcoding → **1.32.9 DHCP re-enablement IRON-VERIFIED** (real lease `.142`, `DISCOVER→OFFER→REQUEST→ACK`, gateway MAC hex `d4:6a:…`, `net: L2 OK`). The **1.33.x WRITE arc** (the demo→base maturity exit — state persists across reboots, not just *shown*) opened at **1.33.0** (full mutation set create/write/unlink/mkdir/rmdir + VFS `vfs_write` arm + shell verbs, QEMU `e2fsck -fn`-clean on a feature-stripped image; the W5 iron burn then confirmed the W2 safety gate refuses write on a default `mkfs.ext4` partition by design). **1.33.1 (RELEASED 2026-05-25)**: real **metadata_csum + 64bit write** (7 bites — 64bit BGDT `_hi` writes + CRC32c Castagnoli checksums across SB / group-desc / block+inode bitmaps / inodes / dir-leaf tails), all `e2fsck -fn`-clean on the `metadata_csum,64bit,extent` profile; **🎯 W5 iron burn PASS** (`echo > /persist.txt` → power-cycle → survives in `agnos> ls` on the **unmodified** default partition — photo `1331_After_Reboot`). Build 675,152 B. **1.33.2 (RELEASED)** shipped standalone as a **lockup-hardening cut** (bench/serial stability), prompted by a reported delayed-idle lockup (idle shell, seconds-to-a-minute *after* `bench`): bounded `serial_putc` THR-empty poll (was an uncapped `jz` spin) + `bench` guards for `pmm_alloc()==0` (would clobber physical 0–4095) and the `vfs_create_memfile` fd. Defensive — root cause not iron-confirmed; if the symptom survives, prime suspect is the per-tick `timer_handler`→`do_context_switch` path (`pic.cyr:48-54` documents a prior delayed-idle lockup from a register-save bug when the idle proc is re-selected). See [`#tracker-1332-lockup`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-1332-lockup). **1.33.3 (this cut — OPEN, lean)**: the WRITE dirent recompositions moved from 1.33.2 — **`rename`/`mv`**, **hardlink/`ln`**, **symlink-create/`ln -s`** (all ride W4's dirent insert/remove + inode primitives), plus **`s_state` dirty/clean + `sync` verb**. No WRITE bites yet; bite plan + rubric in [`#tracker-1333-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-1333-cycle). Remaining 1.33.x follow-ons → 1.33.4 (uninit_bg materialization + symlink resolution) / 1.33.5 (fsync barrier); beyond the active 1.33.x line, the full forward plan — additional FS (1.34–1.36) → big-write own-cycles (1.37 extent-alloc / 1.38 jbd2 / 1.39 VFS) → kernel-slimming separations (1.40 font→`kashi` / 1.41 shell→agnoshi) → 1.42 perf band → 1.43–1.45 agnos-2.0 runway (gated on Cyrius), plus the platform/feature decades (1.5x Intel / 1.6x Pi / 1.7x radios WiFi+BT / 1.8x RISC-V) — lives in [`roadmap.md`](roadmap.md) rows 14–22 + § *Platform-target & long-range decade map*. **All ≥1.34.x is speculative plan, not active.** Build **675,472 B** (1.33.2), `test.sh` 4/4 + `ext2-smoke` 5/5. **MVP gate (boot-to-shell with typeable keyboard) green since Attempt 68 / 1.30.9.** The 1.30.x AMD Zen scanout residue (Quiet-Boot legibility) stays parked per `project_amd_zen_scanout_residue`. | **Refresh cadence**: every release, ideally by `scripts/version-bump.sh`. The script only refreshes header date + Version-row + roadmap "Current" line; body prose drifts independently and needs manual sweeps at minor closeouts.
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md). Iron-bring-up per-attempt detail lives in [agnosticos `iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.33.3** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **6.0.1** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-05-25 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Iron-validated** | 2026-05-23 (archaemenid NUC AMD — **MVP gate still green at Attempt 100 / 1.32.3**; storage trio + GPT + ext4 + shell byte-clean across all 1.32.3 burns; **DHCP feature gate carries forward** — chip-level RX filter unblocked at Attempt 100 [BSD/iPXE rewrite; `[0x5E]=0xff` broadcast admitted for first time across 1.32.x arc], OFFER-timeout downstream of `r8169_poll` is the next-cycle work) | NUC AMD Attempts 68 (MVP gate) + 71-77 (FB hardening) + 80 (NVMe) + 81-91 (storage arc) + 92-100 (1.32.x networking arc) |

## Open investigations — DHCP OFFER-timeout downstream of r8169_poll (next-cycle)

The kernel-init layer cleared boot-to-shell-on-iron at Attempt 68 (agnos 1.30.9), and remains green across the 1.31.x storage arc + 1.32.x networking arc — every burn this evening reached `AGNOS shell v1.32.3` byte-clean. **No blockers for the closed-beta MVP gate.** Live investigations (feature-residual carry-forward, not MVP blockers):

- **DHCP OFFER timeout downstream of `r8169_poll`** (new at 1.32.3 close, carry-forward to next-round) — Attempt 100 (BSD/iPXE-shape r8169 rewrite) UNBLOCKED the chip-level RX filter: `[0x5E]=0xff` broadcast first byte admitted for the first time across the entire 1.32.x DHCP arc (`[0x5D]=0x72` confirms BAR bit set, `[0x5A]=0x03` ≥ DISCOVER + REQUEST + retransmit). But `dhcp: OFFER timeout` still in FB. Two candidate root causes, both zero-burn-disambiguable: (a) admitted broadcast was NOT the DHCP OFFER (could be ARP / NetBIOS / mDNS / SSDP / Linux dhclient broadcast on same MAC) — resolvable with `tcpdump -i enp1s0 -nn -X 'port 67 or port 68'` from the Linux side during the next burn to see whether an OFFER appears on the wire at all; (b) OFFER was admitted at chip but lost in AGNOS `udp_recv_from` / `dhcp_init` matcher / xid filter — resolvable via code audit (xid preservation, chaddr compare, port 67 vs 68 filter inversion, `net_handle_udp` listener routing). Per [[feedback_iron_burns_block_other_work]] no next iron burn until (a) or (b) is decided. See [agnosticos `iron-nuc-zen-log.md` § Attempt 100](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) for the full PARTIAL receipt + (c1) vs (c2) disambiguation rubric.
- **AMD Zen scanout residue (Quiet Boot legibility)** — parked at gnoboot 0.4.2 / agnos 1.30.12 with the bug surviving. Two GOP-side SetMode lever variants falsified (Attempt 78 closed the bounce form). Next-cycle resumption options: HUBP `clear_tiling` port (Linux `drivers/gpu/drm/amd/display/` analog) OR architectural eval of a shadow-buffer FB-console model (simpledrm-style). Pin: [`project_amd_zen_scanout_residue`](../../../../.claude/projects/-home-macro-Repos-agnosticos/memory/project_amd_zen_scanout_residue.md). VGA-spec path stays MVP-legible.

### Resolved (historical, kept as audit trail)

- **2026-05-13 RDRAND under default qemu64 CPU**: kernel stalled at `Page tables: 1024MB mapped` because the smoke test missed `-cpu max` (default `qemu64` lacks RDRAND, `pmm_init` → `kaslr_seed` → `rdrand_u64` faulted silently). Real iron supports RDRAND. Fixed in `gnoboot/tests/ovmf_smoke.sh` with `-cpu max`.
- **2026-05-13/14 Timer-driven context switch under UEFI+gnoboot**: traced to `test_proc_a/b` returning into uninitialized stack memory exposed by gnoboot's pre-handoff state. Closed by Phase 4/5 progression (real user procs replaced test stubs in the boot path) and the iron-validation milestone 2026-05-15 which cleared all 17 init checkpoints + `sched_active=1` + first hlt + context-switch loop on real Zen silicon.
- **2026-05-17 Phase 3 USB silent-absorb (Repair EE)**: 13-hypothesis arc through Attempts 32-54 chasing a "controller absorbs PORTSC.PR writes" hypothesis. Root cause: `xhci_portsc_write` inner re-mask `& XHCI_PORTSC_NEUTRAL` stripping the RW1S PR bit. One-line fix in `agnos@41ee6dc`. See CHANGELOG [1.30.5] for the narrative.
- **2026-05-18 xHCI Enable Slot CCE silent-absorb (Repair QQ + cyrius gvar-init-order fix)**: 9-letter spec-path repair ladder (FF→OO) falsified Attempts 57-62 on AMD FCH 1022:1639. Resolution came from the cyrius side: v5.11.64 fixed a kmode init-order bug where `var X = INT_LITERAL` at module scope read as 0 before the init block ran, causing silent-absorb on the cmd-path. Iron-validated at Attempt 68 (1.30.9) — typeable shell on archaemenid → MVP gate hit. See agnosticos `iron-nuc-zen-log` § Attempt 68 + cyrius `issues/2026-05-18-gvar-init-order-zero-reads.md`.
- **2026-05-20 NVMe arc + iron debut**: Phase 1-5 driver shipped under [1.31.0]; iron debut on Crucial P3 2 TB at Attempt 80 was first-try clean. The contrast with xHCI's 5-week / 19-attempt / 9-letter-code path is the structural reading on `feedback_redesign_dont_reinvent`: port from Linux's `drivers/nvme/host/pci.c`, redesign to Cyrius conventions, get a clean iron debut.

The full history of these investigations lives in [`CHANGELOG.md`](../../CHANGELOG.md) and the agnosticos iron-nuc-zen-log. This `state.md` section tracks **live** investigation only — historical investigations should resolve here and migrate to CHANGELOG.

---

## Build artifacts

Measured under cyrius 5.11.59, `CYRIUS_NO_WARN_SHADOW_LIB=1`, default
DCE behavior. All sizes are from `wc -c` on `build/agnos*` after
`scripts/build.sh` / `scripts/build.sh --aarch64`.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **475,096 B** (~464 KB) | ELF64 multiboot2 (Path C — sovereign UEFI boot-info ABI via gnoboot v0.4.2; RDI = `&boot_info`, magic `0x41474E4F`), entry `0x1000a8`. Boots under `qemu-system-x86_64 -cpu max` + OVMF + gnoboot. Iron-validated archaemenid: MVP gate at Attempt 68 (1.30.9); NVMe debut clean at Attempt 80 (1.31.0). |
| aarch64 | `build/agnos-aarch64` | **93,640 B** (~91 KB) | Cross-compiled. DTB + EL2→EL1 + PL011 UART + GIC. Compile-tested only — boot harness not yet wired. The +9 KB delta between x86_64 lines added since 1.30.7 (66 → 475 KB) is x86-only: USB-HID + xHCI cmd-path + FB hardening + NVMe + AHCI + GPT. aarch64 stubs absorb the new symbols with zero LOC delta. |

Size trajectory through 1.31.1 — bookmark cuts only; per-patch detail in CHANGELOG:

| Cut | x86_64 | Delta source |
|---|---|---|
| v1.27.2 (1.28.x arc start) | 248,896 B | — |
| v1.28.0 | 249,152 B (+256) | KASLR (S7) — Security Hardening track closed 13/13 |
| v1.29.1 | 251,312 B (+2,160 over arc) | 1.28.x VFS-tagged-unions + PciDev derive + bench-history schema |
| v1.30.0 | ~266,312 B (+15,000) | **Path-C sovereign UEFI boot-info ABI** — ELF64 + multiboot2 + RDI handoff |
| v1.30.4 | 295,496 B (+29,184) | xHCI Linux-diff hardening — BAR UC remap, PORTSC RW1S, USB-HID Phase 1-3 |
| v1.30.5 | ~360,000 B (+64,504) | Phase 4/5 USB-HID kbd driver + Repair (EE) Phase 3 silent-absorb closeout |
| v1.30.6 | 368,568 B (+8,568) | xHCI cmd-path arc Repairs FF → OO bundle |
| v1.30.7 | 368,968 B (+400) | Repair (QQ + QQ'') MSI-X Table programming (staged) — pre-MVP-gate cut |
| **v1.30.9** | ~395,000 B (+~26,000) | **MVP GATE HIT** — Attempt 68 typeable shell on iron (SET_CONFIGURATION + canonical FS interval + ISP via cyrius v5.11.64 gvar-init-order fix) |
| v1.30.10 → .12 | ~411,000 → 425,840 B (+30,840 over .9) | FB hardening sweep — pitch-aware refresh, WC + PixelFormat guard, true-font swap (VGA 8x16 BIOS ROM replaces hand-drawn CGA 8x8); 1.30.12 closes 1.30.x at `75914e9` |
| **v1.31.0** | **421,912 B** (−3,928 from .12) | **Cycle open** — production-lean: `KTEST` + `XHCI_VERBOSE` compile gates strip diagnostic spam from default builds. Then NVMe Phase 1-5 (probe → admin queue → I/O queue → R/W + PRP-list → `block.cyr` dispatch) lands [Unreleased] same-session + iron debut Attempt 80 (Crucial P3 2 TB) clean. Cycle theme pivots from FB to storage. |
| **v1.31.1** [Unreleased] | **475,096 B** (+34,040 from 1.31.0 storage-arc baseline of 441,056 B with NVMe applied) | **Storage cycle continues** — GPT Phase 1-3 (header probe + full 16 KB array walk + UTF-16LE name extraction + `parts` shell command + `gpt_partition_info(idx)` helper + CRC32 header/array validation + backup-header recovery + 7-GUID type classifier) + AHCI/SATA Phase 1-4 (HBA probe + BAR5 UC remap + CAP/GHC/PI decode + per-port CL+FIS bring-up + ATA IDENTIFY DEVICE + READ/WRITE DMA EXT + block-layer registration with NVMe-primary policy). Code-complete; iron burn awaits §4 patch decision on the audit. |

---

## Source rollup

| Tree | Files | Notes |
|---|---|---|
| `kernel/` (total) | **66** `.cyr` | 15,048 lines across all kernel sources (was 6,306 at v1.30.7 — +8,742 lines for xHCI subsystem + storage stack) |
| `kernel/agnos.cyr` | 1 | Main orchestrator — only `#ifdef` + `include` |
| `kernel/kernel_hello.cyr` | 1 | Minimal smoke test |
| `kernel/klib/` | 3 | `kstring.cyr`, `kfmt.cyr`, `ktagged.cyr` — vendored kernel-safe stdlib |
| `kernel/arch/x86_64/` | 17 | boot_shim, boot_data, fb, fb_console, mbi, serial, gdt, idt, pic, apic, smp, keyboard, paging, io, syscall_hw, ring3, iommu |
| `kernel/arch/x86_64/usb/` | 8 | xhci, xhci_regs, xhci_ring, xhci_cmd, xhci_ctx, xhci_port, hid, hid_translate |
| `kernel/arch/aarch64/` | 9 | boot_data, serial, gic, timer, exceptions, keyboard, paging, stubs, main |
| `kernel/core/` | **22** | pmm, vmm, heap, proc, sched, syscall, vfs, devs, initrd, kprint, main, net, virtio_net, virtio_blk, fatfs, pci, acpi, elf, **nvme, block, gpt, ahci** (last four landed in the 1.31.x storage arc) |
| `kernel/user/` | 4 | shell, init, test, test_procs |
| `kernel/version.cyr` | 1 | Auto-generated banner strings — `scripts/version-bump.sh` regenerates |

---

## Subsystem status (40+)

All subsystems are **code-complete** through v1.31.1. **MVP gate is cleared on iron** — typeable shell at Attempt 68 (1.30.9). The 1.31.x storage arc has shipped a full NVMe driver (iron-validated at Attempt 80), GPT layer (QEMU-validated), and AHCI/SATA driver (QEMU-validated, iron-burn audit drafted). The roadmap's "Active" table is the source of truth for in-flight work; this is the shipped surface.

| Subsystem | Notes |
|---|---|
| Boot (multiboot1, 32→64 shim) | 32-bit ELF entry, long mode transition (x86_64) |
| Boot (aarch64) | DTB, EL2→EL1, PL011 UART, GIC, ARM timer |
| Boot (Path-C sovereign UEFI) | gnoboot v0.4.2 hands off via `RDI = &boot_info` (magic `0x41474E4F`); replaces multiboot2-via-GRUB |
| Framebuffer console | GOP handoff capture, WC remap, pitch-aware u64 block-copy paint, 8x16 VGA BIOS-ROM glyph set (true-font swap at 1.30.12) |
| Serial I/O | COM1 `0x3F8` (x86_64), PL011 UART (aarch64) |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default `iretq` handler |
| PIC | 8259A, ICW1–4, remap to INT 32+ |
| Local APIC | MMIO at `0xFEE00000`, timer, IPI |
| GIC | ARM GICv2 interrupt controller (aarch64) |
| Timer | APIC periodic ~100 Hz (x86_64), ARM generic timer (aarch64) |
| Keyboard (PS/2) | Full US QWERTY (x86_64), UART RX (aarch64) |
| Keyboard (USB-HID via xHCI) | Full Phase 1-5 boot kbd driver — `hid_kbd_configure`, `hid_poll`, HID→PS/2 mapping, kb_buf writer; iron-typeable at Attempt 68 |
| Page Tables | 2 MB huge pages, 4 GB identity map, per-process |
| PMM | Bitmap, 4,096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages, UC + WC remap helpers |
| Kernel Heap | Slab allocator, 8 size classes (32–4,096 B) |
| Process Table | 16 slots, 168 B context, CR3 per-process |
| Context Switch | Full register save/restore, CR3 switch |
| Scheduler | Round-robin |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space |
| VFS | File table, device/memfile/signalfd/epoll/timerfd/pipe types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery, 64-bit BAR support |
| ACPI | RSDP scan, DMAR parsing (VT-d), basic table layout |
| IOMMU (VT-d) | Root/context/IO page tables, DTE registration for device DMA |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames |
| IP/UDP Stack | ARP, IPv4, UDP send/recv |
| TCP Stack | Connect, send, recv, close, SYN/ACK/FIN state machine |
| VirtIO-Blk | Legacy PCI, sector read/write, DMA buffers |
| **NVMe** | Full Phase 1-5 driver — probe + admin queue + I/O queue + R/W DMA + PRP1/PRP2/PRP-list dispatch. Iron-debut clean on Crucial P3 2 TB at Attempt 80 (1.31.0) |
| **AHCI/SATA** | Full Phase 1-4 driver — HBA probe + per-port CL+FIS bring-up + IDENTIFY DEVICE + READ/WRITE DMA EXT. QEMU-validated on q35 ich9-ahci; iron-burn audit drafted (1.31.1 [Unreleased]) |
| **Block-layer dispatch** | `kernel/core/block.cyr` — tag-based 3-backend dispatch (`BLK_VIRTIO` / `BLK_NVME` / `BLK_AHCI`); NVMe overrides virtio; AHCI registers as secondary when NVMe present (1.31.x) |
| **GPT partition parser** | Full Phase 1-3 — header probe + signature decode + full 16 KB array walk + UTF-16LE name extraction + `parts` shell command + `gpt_partition_info(idx)` helper + table-less CRC32 (0xEDB88320) validation + backup-header recovery + 7-GUID type classifier (ESP / MSFT Basic / Linux FS / Linux Swap / Linux LVM / Linux RAID / BIOS Boot) (1.31.1) |
| FAT16 | Read-only, root directory listing, file open/read |
| Pipes | Circular buffer IPC, read/write ends, VFS type 6 |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Shell | 20 commands (added `parts` for GPT in 1.31.1) |
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
What boots on top of it (live versions in [agnosticos `state.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md)):

```
kybernet (PID 1)
├── agnosys      — syscall bindings (Linux x86_64 + aarch64 wrappers)
├── agnostik     — shared types/primitives (error/security/agent/telemetry)
├── argonaut     — service lifecycle, health, seccomp/Landlock, PID-1 harness
│                  (BOOT_MINIMAL mode adds agnoshi as no-deps console service — 1.30.x MVP path)
│   └── libro    — cryptographic audit chain
└── daimon       — agent orchestrator
```

**Single-pin convention retired**: the previous "all on cyrius 5.10.44" stack-pin convention dissolved during the v5.11.x burst (2026-05-11/12/13). agnos itself moved to cyrius 5.11.59 during the Path-A → Path-C ELF64/UEFI-emit transition (forced by Cyrius .29/.30/.31 ELF section-header fix arc). Most other userland repos are at cyrius 5.10.44 bedrock; a 5.11.x leading-edge cluster is forming (sigil, sankoch, agnosys, et al at 5.11.4-5.11.8). Per-repo pin-lag spectrum is tracked in [agnosticos `state.md` § Pin-lag spectrum](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md) — the genesis-repo is authoritative for cross-repo state. **Versions intentionally elided here** to avoid double-bookkeeping; agnosticos's state.md refreshes per repo touch.

---

## Test surface

| Gate | Count | Source |
|---|---|---|
| `scripts/check.sh` | **11/11** PASS | build, test, doc-exists ×6, version-in-kernel, version-in-changelog, binary-size |
| `scripts/test.sh --all` | **7/7** PASS | x86 builds, multiboot ELF, size, kernel_hello builds; aarch64 compiles, size, valid ELF |
| CI `boot-test` (QEMU) | banner + `KASLR: pmm_next_free=N` varies across 2 boots + `Memory isolation: PASS` + `Userland exec complete` | `.github/workflows/ci.yml` `boot-test` job |
| CI `Format check` | 47/47 fmt-clean (1 skip: `kernel/user/shell.cyr` per `#ifdef`-in-fn-body carve-out) | `ci.yml` `check` job |

CI runs on a self-hosted runner labeled `[self-hosted, linux, x64]` for
`boot-test` and `benchmarks` (need QEMU + KVM-class CPU); `build`, `check`,
`test`, `security`, `docs` run on `ubuntu-latest`.

---

## In-flight (roadmap snapshot)

Source: [`docs/development/roadmap.md`](roadmap.md) `## Active` section.

| # | Item | Status |
|---|---|---|
| 1 | AHCI iron debut on archaemenid `sda` | Code-complete (1.31.1 Phase 1-4); QEMU-validated. Awaits §4 `AHCI_RW_DEMO` compile-gate decision per [`ahci-iron-burn-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/ahci-iron-burn-audit.md). |
| 2 | AMD Zen Quiet-Boot scanout residue | Parked next-cycle pin (`project_amd_zen_scanout_residue`). MVP unblocked via VGA-spec path; resumption options are HUBP `clear_tiling` port or shadow-buffer FB-console architectural eval. |
| 3 | SMP AP wakeup on real hardware | QEMU-validated only; needs hardware-in-the-loop infra. Stays open across multiple arcs. |
| 4 | `struct Process` `#derive(accessors)` port | Blocked on cyrius v5.11.x cap-raise — upstream acknowledged the 16-field metadata-table overflow + slotted for repair. Picks up passively at the next cyrius pin bump. |

Recently closed (see [`CHANGELOG.md`](../../CHANGELOG.md)):
- **v1.31.1** [Unreleased] — **Storage cycle continues**: GPT Phase 1-3 + AHCI/SATA Phase 1-4. ~1,440 LOC of new engineering (gpt.cyr + ahci.cyr + block.cyr extension + main.cyr wiring + aarch64 stubs). Iron-burn audit drafted. Awaits §4 patch + tag.
- **v1.31.0** — **Cycle open + NVMe arc + iron debut**: production-lean (`KTEST` + `XHCI_VERBOSE` compile gates default off + FB-absent guard + new `docs/development/build.md`) + NVMe Phase 1-5 (probe + admin queue + I/O queue + R/W + PRP-list + `block.cyr` dispatch) + iron debut on Crucial P3 2 TB at Attempt 80 (first-try clean).
- **v1.30.12** — True-font swap: VGA 8x16 BIOS ROM replaces hand-drawn CGA 8x8; closes 1.30.x FB-hardening sweep at QEMU+iron 1080p / 1440p PASS. iron Attempts 71-77.
- **v1.30.11** — FB hardening: PixelFormat guard + WC retry-after-pmm + idempotent `vmm_remap_wc_2mb` + font-density scale + MTRR/audit removal. Quiet-Boot MVP gate at Attempt 76.
- **v1.30.10** — Framebuffer refresh: WC + pitch-aware + u64 block-copy. iron Attempts 69-70.
- **v1.30.9** — **MVP GATE HIT** at iron Attempt 68: SET_CONFIGURATION + canonical FS interval + ISP → typeable shell on archaemenid. Closeout of the xHCI cmd-path arc via cyrius v5.11.64's gvar-init-order fix.
- **v1.30.8** — Iron Attempts 65/66/67: RR falsified, EP0 MPS reconciliation clears HID enumeration.
- **v1.30.7** — pre-MVP-gate version bump (no kernel source delta).
- **v1.30.6** — xHCI cmd-path arc bundle: Repairs FF → QQ + MSI-X table programming closeout.
- **v1.30.5** — Phase 4/5 USB-HID boot keyboard driver + Repair (EE) Phase 3 silent-absorb one-line closeout.
- **v1.30.4** — xHCI Linux-diff hardening closeout (BAR UC remap, PORTSC strict-RW1S, USB-HID Phase 1-3).
- **v1.30.0** — Sovereign-struct kernel ABI: ELF64 multiboot2, RDI = `&boot_info` Path-C handoff via gnoboot v0.2.0.
- **v1.29.x arc** — Closeout for 1.28.x.
- **v1.28.x arc** — KASLR data-only (S7 closed; Security Hardening track 13/13).
- **v1.27.x arc and earlier** — see archived entries in `CHANGELOG.md`.

---

## Verification hosts

| Host | Purpose | Status |
|---|---|---|
| Self-hosted GH runner (`agnos-runner`) | CI boot-test + benchmarks on real KVM | Active |
| Dev box (Arch, Linux 7.0.3, QEMU 11.0) | Local builds, boot, bench | Active |
| QEMU `-cpu max` x86_64 | Required for boot (boot shim sets SMEP+SMAP in CR4 — `qemu64` default lacks both, triple-faults) | — |
| QEMU `-M virt -cpu cortex-a57` aarch64 | Build target; live boot not yet wired | Compile only |

---

## What changed at v1.31.0 / v1.31.1

[`CHANGELOG.md`](../../CHANGELOG.md) carries the full narrative. The headline moves of the past week:

- **MVP gate hit** at iron Attempt 68 (1.30.9) — typeable shell on archaemenid. Root-cause of the 9-letter xHCI cmd-path repair ladder was traced to a cyrius kmode gvar-init-order bug (fixed in cyrius v5.11.64); see cyrius issue `2026-05-18-gvar-init-order-zero-reads.md`.
- **1.30.x FB-hardening sweep** (1.30.10 → 1.30.12) closed at the true-font swap; VGA path legible at 1080p + 1440p. Quiet-Boot legibility residue parked as next-cycle pin.
- **1.31.x cycle theme pivots from FB to storage**. Production-lean compile gates (`KTEST` / `XHCI_VERBOSE`) ship out diagnostic spam by default.
- **NVMe arc** (Phase 1-5) lands [1.31.0] same-session as the cycle open + iron debut on Crucial P3 2 TB first-try clean (Attempt 80). Build 421,912 → 441,056 B.
- **GPT layer + AHCI/SATA driver** land [1.31.1] same-session. Total 1.31.1 delta: +34,040 B / ~1,440 LOC. Code-complete; iron burn awaits the §4 `AHCI_RW_DEMO` compile-gate decision in the audit.

The systemic refresh discipline: `scripts/version-bump.sh` keeps the header date + Version-table row + `roadmap.md "Current"` line fresh atomically with the bump; body prose (Open Investigation, Build artifacts table extension, Subsystem status, Source rollup, Recently closed bullet list, ecosystem block, In-flight table) needs manual sweep at each minor closeout. This pattern was clarified during the 2026-05-18 doc-staleness audit when the script-fresh header was discovered next to v1.29.0-era body prose; the current sweep (2026-05-20) extends it to the 1.31.x storage-arc shape.
