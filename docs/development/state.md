---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-05-27. **1.35.7 RELEASED — arc-close hardening (pass 1)** (security: `net_poll` now clamps the attacker-controlled IPv4 total-length to the actually-received frame via `ip_safe_payload_len` — closes a forged-length over-read that let ICMP echo reflect stale bytes / UDP+TCP over-read `net_rx_pkt`; non-structural, no valid-traffic change; `hardening-smoke.sh` green + icmp/tcp/dns/ntp smokes no-regression; audit agnosticos [`arc-close-hardening-1-35.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/arc-close-hardening-1-35.md)). Refactor ops are reserved for 1.36.x. **1.35.6 RELEASED — DNS cache** (8-entry TTL-respecting positive cache + TTL extraction; `dns_cache_find`/`dns_cache_put`; lwIP-style evict-soonest; repeated `ping`/`ntp <host>` no longer re-query; `dns-smoke.sh` 3/3 incl. `dns: cache PASS`; audit agnosticos [`dns-stub-resolver-prior-art.md` § 9](https://github.com/MacCracken/agnosticos/blob/main/docs/development/dns-stub-resolver-prior-art.md)). Multi-A/CNAME + retransmit were already shipped at 1.35.0; this was the cache gap. **1.35.5 RELEASED — RTC boot clock** (reads the CMOS RTC at boot to seed a wall clock with no network — `civil_to_unix` + `rtc_read_unix`; `date` shows `[RTC]`/`[NTP]`; NTP refines/overrides; `rtc-smoke.sh` green; audit agnosticos [`rtc-boot-clock-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/rtc-boot-clock-prior-art.md)). Cycle also moved the kernel cyrius pin **6.0.1 → 6.0.3** after a byte-identical kernel A/B. **1.35.4 RELEASED — `munmap`** (syscall 28; releases an anonymous region + returns its physical 2 MB pages to the PMM via `proc_unmap_page` + `invlpg` + `pmm_free_2mb`; LIFO arena reclaim; `mmap-smoke.sh` 2/2; closes the mmap/munmap pair). **1.35.3 RELEASED — anonymous `mmap`** (syscall 27, 2 MB-granular zero-filled memory into the caller's address space; new `pmm_alloc_2mb` contiguous allocator; audit agnosticos [`mmap-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/mmap-prior-art.md)). The first new *functional* syscalls since v1.21.0 — pure memory facilities, no socket/crypto surface. **1.35.2 RELEASED — NTP/SNTP** (the kernel's first wall clock from a one-shot SNTP query; `ntp` + `date` verbs). **1.35.1 RELEASED — TCP hardening** B0–B4 (in-order receive ring + retransmit/RTO + MSS/segmentation + peer-window; the minimal SYN/ACK/FIN machine is now a reliable, flow-controlled stream). **1.35.0 RELEASED** — the catchup-tidbits cut: a full docs sweep + **DNS stub resolver** (`dns` verb; `dns-smoke.sh` green, live `example.com` via SLIRP; audit agnosticos [`dns-stub-resolver-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/dns-stub-resolver-prior-art.md)) + **ICMP echo / ping** (`ping` verb, pingable + `icmp_ping`; `icmp-smoke.sh` green — hermetic checksum + live gateway round-trip). The planned AGNOS-side comms order (DNS → ICMP → TCP-hardening → NTP) is **COMPLETE**; TLS + PIE are the cyrius-side next destinations (days-to-weeks). Legacy virtio-net back-burnered (known TX gap); plug-and-play / hot-add still a candidate. **Last release: agnos 1.35.7.** The **1.34.x FAT-family arc** ([`roadmap.md`](roadmap.md) row 21) shipped FAT12/16/32 + exFAT read+write across **1.34.0–1.34.6** (FAT read+write → exFAT read+write → write parity → LFN/truncate → directory growth → exFAT Unicode names → ESP-write guard) — all RELEASED + `fsck`-clean in QEMU. **Only the user-driven FAT/exFAT iron burn remains** (the arc's first iron touch — the guard makes it brick-safe; plan in agnosticos `#tracker-1341-cycle`). Production build **828,464 B** (~828 KB; the 1.35.x arc added DNS + ICMP + TCP-hardening + NTP + mmap/munmap + RTC + DNS-cache + ingress hardening since the ~799 KB 1.34.6 cut); `test.sh` 4/4 + `check.sh` 11/11 (binary-size sanity ceilings at 1.2 M), ext2 + FAT + exFAT + dns + icmp + tcp + ntp + mmap + rtc + hardening smokes green. **MVP gate (boot-to-shell with typeable keyboard) green on archaemenid since Attempt 68 / 1.30.9.** **Closed arcs (history → [`CHANGELOG.md`](../../CHANGELOG.md) + the iron-log, not here):** storage backends + GPT + ext2/4 read (1.31.x), networking incl. r8169 unicast-RX + DHCP iron-verified (1.32.x), ext2/4 WRITE incl. the W5 demo→base iron burn + fsync barrier (1.33.x). **Forward plan beyond 1.34.x** — big-write own-cycles (1.37 extent / 1.38 jbd2 / 1.39 VFS) → kernel-slimming (1.40 font→`kashi` / 1.41 shell→agnoshi) → 1.42 perf → 1.43–1.45 agnos-2.0 runway, + platform decades (1.5x Intel / 1.6x Pi / 1.7x radios / 1.8x RISC-V) — lives in [`roadmap.md`](roadmap.md). 1.30.x AMD Zen scanout residue stays parked per `project_amd_zen_scanout_residue`. | **Refresh cadence**: every release, ideally via `scripts/version-bump.sh` (it refreshes the header date + Version row + roadmap "Current" line; body prose needs a manual sweep at minor closeouts — like this one).
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md). Iron-bring-up per-attempt detail lives in [agnosticos `iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.35.7** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **6.0.3** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-05-27 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Iron-validated** | 2026-05-25 (archaemenid NUC AMD — **MVP gate green since Attempt 68 / 1.30.9**; **1.32.x networking arc iron-COMPLETE**: r8169 unicast-RX solved at 1.32.7 + DHCP real lease `.142` iron-verified at 1.32.9; storage trio + GPT + ext4 + shell byte-clean). The 1.33.x ext2/4-WRITE + 1.34.x FAT-family arcs are QEMU/`fsck`-validated; their final-bite iron burns stay user-driven (pending). | NUC AMD Attempts 68 (MVP gate) + 71-77 (FB) + 80-91 (storage arc) + 92+ (networking arc — DHCP iron-verified 1.32.9) |

## Open investigations

The kernel cleared boot-to-shell-on-iron at Attempt 68 (agnos 1.30.9) and stays green; the 1.31.x storage + 1.32.x networking arcs are iron-COMPLETE (DHCP real lease iron-verified at 1.32.9, agnosticos [`#tracker-1329-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-1329-cycle)). **No MVP blockers.** One live item:

- **AMD Zen scanout residue (Quiet Boot legibility)** — parked at gnoboot 0.4.2 / agnos 1.30.12 with the bug surviving. Two GOP-side SetMode lever variants falsified (Attempt 78 closed the bounce form). Next-cycle resumption options: HUBP `clear_tiling` port (Linux `drivers/gpu/drm/amd/display/` analog) OR architectural eval of a shadow-buffer FB-console model (simpledrm-style). Pin: [`project_amd_zen_scanout_residue`](../../../../.claude/projects/-home-macro-Repos-agnosticos/memory/project_amd_zen_scanout_residue.md). VGA-spec path stays MVP-legible.

### Resolved (historical, kept as audit trail)

- **2026-05-13 RDRAND under default qemu64 CPU**: kernel stalled at `Page tables: 1024MB mapped` because the smoke test missed `-cpu max` (default `qemu64` lacks RDRAND, `pmm_init` → `kaslr_seed` → `rdrand_u64` faulted silently). Real iron supports RDRAND. Fixed in `gnoboot/tests/ovmf_smoke.sh` with `-cpu max`.
- **2026-05-13/14 Timer-driven context switch under UEFI+gnoboot**: traced to `test_proc_a/b` returning into uninitialized stack memory exposed by gnoboot's pre-handoff state. Closed by Phase 4/5 progression (real user procs replaced test stubs in the boot path) and the iron-validation milestone 2026-05-15 which cleared all 17 init checkpoints + `sched_active=1` + first hlt + context-switch loop on real Zen silicon.
- **2026-05-17 Phase 3 USB silent-absorb (Repair EE)**: 13-hypothesis arc through Attempts 32-54 chasing a "controller absorbs PORTSC.PR writes" hypothesis. Root cause: `xhci_portsc_write` inner re-mask `& XHCI_PORTSC_NEUTRAL` stripping the RW1S PR bit. One-line fix in `agnos@41ee6dc`. See CHANGELOG [1.30.5] for the narrative.
- **2026-05-18 xHCI Enable Slot CCE silent-absorb (Repair QQ + cyrius gvar-init-order fix)**: 9-letter spec-path repair ladder (FF→OO) falsified Attempts 57-62 on AMD FCH 1022:1639. Resolution came from the cyrius side: v5.11.64 fixed a kmode init-order bug where `var X = INT_LITERAL` at module scope read as 0 before the init block ran, causing silent-absorb on the cmd-path. Iron-validated at Attempt 68 (1.30.9) — typeable shell on archaemenid → MVP gate hit. See agnosticos `iron-nuc-zen-log` § Attempt 68 + cyrius `issues/2026-05-18-gvar-init-order-zero-reads.md`.
- **2026-05-20 NVMe arc + iron debut**: Phase 1-5 driver shipped under [1.31.0]; iron debut on Crucial P3 2 TB at Attempt 80 was first-try clean. The contrast with xHCI's 5-week / 19-attempt / 9-letter-code path is the structural reading on `feedback_redesign_dont_reinvent`: port from Linux's `drivers/nvme/host/pci.c`, redesign to Cyrius conventions, get a clean iron debut.
- **2026-05-25 networking arc close (r8169 unicast-RX → DHCP)**: the 1.32.3 `dhcp: OFFER timeout` was NOT a DHCP-layer bug — it was the r8169 RX ring dropping clean unicast frames for want of a free descriptor (16-deep ring). Fixed at **1.32.7** (RX ring 16→64; `missed` 176→0; on-LAN + off-LAN TCP handshakes complete on iron), DHCP re-enabled at **1.32.9** with a real lease `.142` iron-verified. The whole 1.32.x networking arc is COMPLETE. agnosticos [`#tracker-1329-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-1329-cycle) + CHANGELOG [1.32.x].

The full history of these investigations lives in [`CHANGELOG.md`](../../CHANGELOG.md) and the agnosticos iron-nuc-zen-log. This `state.md` section tracks **live** investigation only — historical investigations should resolve here and migrate to CHANGELOG.

---

## Build artifacts

Sizes from `wc -c` on `build/agnos*` after `scripts/build.sh`, cyrius 6.0.3, default DCE.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **828,464 B** (~809 KB, at 1.35.7) | ELF64 multiboot2 (Path C — sovereign UEFI boot-info ABI via gnoboot v0.4.2; RDI = `&boot_info`, magic `0x41474E4F`), entry `0x1000a8`. Boots under `qemu-system-x86_64 -cpu max` + OVMF + gnoboot. Iron-validated on archaemenid: MVP gate Attempt 68 (1.30.9), storage trio Attempts 80/81/87, ext4 victory lap 90/91, networking arc through Attempt ~100 (DHCP iron-verified 1.32.9). |
| aarch64 | `build/agnos-aarch64` | deferred — separate work area | Compile-only, no boot harness; **not gated** (test.sh/check.sh/CI are x86-only). During first-primary-kernel buildup the **AMD x86 line (archaemenid) is the one and only kernel** — aarch64 bring-up (incl. stub parity) is its own future arc (decade 1.6x), not maintained in lockstep here. x86 is the only build the target line depends on. |

Per-cut size trajectory + deltas live in [`CHANGELOG.md`](../../CHANGELOG.md) (the at-a-glance ledger — this is current truth, not a log). Bookmarks: ~249 KB (1.28.x) → **~395 KB v1.30.9 MVP gate** → 1.31.x storage arc → 1.32.x networking → 1.33.x ext2/4 write → 1.34.x FAT-family → 798,936 B (1.34.6) → 1.35.x comms (DNS/ICMP/TCP/NTP) + mmap/munmap + RTC + DNS-cache + ingress hardening → **828,464 B (1.35.7)**.

---

## Source rollup

| Tree | Files | Notes |
|---|---|---|
| `kernel/` (total) | **71** `.cyr` | ~26,922 lines across all kernel sources (the 1.31.x storage, 1.32.x networking, 1.33.x ext2/4-write, and 1.34.x FAT-family arcs since the v1.30.x MVP-gate era) |
| `kernel/agnos.cyr` | 1 | Main orchestrator — only `#ifdef` + `include` |
| `kernel/kernel_hello.cyr` | 1 | Minimal smoke test |
| `kernel/klib/` | 3 | `kstring.cyr`, `kfmt.cyr`, `ktagged.cyr` — vendored kernel-safe stdlib |
| `kernel/arch/x86_64/` | 17 | boot_shim, boot_data, fb, fb_console, mbi, serial, gdt, idt, pic, apic, smp, keyboard, paging, io, syscall_hw, ring3, iommu |
| `kernel/arch/x86_64/usb/` | 9 | xhci, xhci_regs, xhci_ring, xhci_cmd, xhci_ctx, xhci_port, hid, hid_translate, msc (USB Mass Storage) |
| `kernel/arch/aarch64/` | 9 | boot_data, serial, gic, timer, exceptions, keyboard, paging, stubs, main |
| `kernel/core/` | **26** | pmm, vmm, heap, proc, sched, syscall, vfs, devs, initrd, kprint, main, pci, acpi, elf; **net, virtio_net, r8169** (networking); **block, nvme, ahci, virtio_blk, ramdisk, gpt** (storage); **ext2, fatfs, exfat** (filesystems) |
| `kernel/user/` | 4 | shell, init, test, test_procs |
| `kernel/version.cyr` | 1 | Auto-generated banner strings — `scripts/version-bump.sh` regenerates |

---

## Subsystem status (40+)

All subsystems are **code-complete** through 1.34.6 (1.35.0 cycle just opened). **MVP gate cleared on iron** — typeable shell at Attempt 68 (1.30.9). Since then: the **1.31.x storage arc** (NVMe / AHCI / USB-MS / RAM-disk / VirtIO-blk + 5-backend block layer + GPT + ext2/ext4 read) closed with iron debuts at Attempts 80/81/87/90/91; the **1.32.x networking arc** (TCP/UDP server primitives + DHCP + r8169 NIC) is iron-COMPLETE (DHCP lease verified 1.32.9); the **1.33.x ext2/4 WRITE arc** is iron-validated (persist-across-reboot); the **1.34.x FAT-family arc** (FAT12/16/32 + exFAT read+write + ESP-write guard) is QEMU/`fsck`-validated. The README § Subsystems is the full enumeration; the roadmap's arc ledger is the at-a-glance index; this table is the shipped-surface detail.

| Subsystem | Notes |
|---|---|
| Boot (multiboot2, 32→64 shim) | 32-bit ELF entry, long mode transition (x86_64) |
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
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames (QEMU NIC) |
| **r8169 NIC** | Realtek RTL8111/8168/8169 GbE driver — RX/TX descriptor rings (64/RX, TX-split mask), unicast filter, iron-validated on archaemenid (RX isolated-construction fix 1.32.7) |
| IP/UDP Stack | ARP, IPv4, UDP send/recv |
| TCP Stack | Connect, send, recv, close, SYN/ACK/FIN state machine + **server primitives** (listen/accept) |
| **DHCP client** | DISCOVER → OFFER → REQUEST → ACK lease acquisition; iron-verified lease on archaemenid (1.32.9) |
| VirtIO-Blk | Legacy PCI, sector read/write, DMA buffers |
| **NVMe** | Full Phase 1-5 driver — probe + admin queue + I/O queue + R/W DMA + PRP1/PRP2/PRP-list dispatch. Iron-debut clean on Crucial P3 2 TB at Attempt 80 (1.31.0) |
| **AHCI/SATA** | Full Phase 1-4 driver — HBA probe + per-port CL+FIS bring-up + IDENTIFY DEVICE + READ/WRITE DMA EXT. QEMU-validated on q35 ich9-ahci; iron-validated on archaemenid (Attempt 87) |
| **Block-layer dispatch** | `kernel/core/block.cyr` — tag-based 5-backend dispatch (`BLK_VIRTIO` / `BLK_NVME` / `BLK_AHCI` / `BLK_USB` / `BLK_RAM`); NVMe overrides virtio; AHCI/USB register as secondary when NVMe present (1.31.x) |
| **GPT partition parser** | Full Phase 1-3 — header probe + signature decode + full 16 KB array walk + UTF-16LE name extraction + `parts` shell command + `gpt_partition_info(idx)` helper + table-less CRC32 (0xEDB88320) validation + backup-header recovery + 7-GUID type classifier (ESP / MSFT Basic / Linux FS / Linux Swap / Linux LVM / Linux RAID / BIOS Boot) (1.31.1) |
| **USB Mass Storage** | `usb/msc.cyr` — Bulk-Only Transport, SCSI READ/WRITE(10), block-layer backend (`BLK_USB`) |
| **RAM-disk** | `core/ramdisk.cyr` — in-memory block backend (`BLK_RAM`) for test/seed images |
| **ext2 / ext4** | Read **and write** — inode/block-group walk, directory ops, file create/write/truncate; persist-across-reboot iron-validated (1.33.x WRITE arc, Attempts 90/91) |
| **FAT12 / FAT16 / FAT32** | Read **and write** — cluster-chain walk, LFN (read + spanning-append write), file create/overwrite/truncate/delete, cluster allocator; `fsck.fat` + `mtools` validated (1.34.x) |
| **exFAT** | Read **and write** — 32-bit FAT, allocation bitmap, up-case table (RLE), typed dir-sets (File / Stream-Ext / File-Name), SetChecksum/NameHash; root extension + spanning-append; `fsck.exfat` validated (1.34.x) |
| **FS-write safety guard** | Refuses FAT/exFAT writes on ESP-type GPT partitions (boot ESP protection); `FAT_ALLOW_ESP_WRITE` compile-override for QEMU test images (1.34.6) |
| Pipes | Circular buffer IPC, read/write ends, VFS type 6 |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Shell | 28 commands (storage/FS/net arcs added `parts`, mount/ls/cat/write/rm/mkdir over the FS backends, net diagnostics) |
| kybernet Init | PID 1 |
| Signals | per-process `proc_signals` / `proc_sigmask`, `kill`, `sigprocmask`, `signalfd` |
| Epoll + Timerfd | `epoll_{create,ctl,wait}`, `timerfd_{create,settime}` |

### Syscall surface (28 functional + 1 diagnostic = 29 dispatch entries)

`exit`(0), `write`(1), `getpid`(2), `spawn`(3), `waitpid`(4), `read`(5),
`close`(6), `open`(7), `dup`(8), `mkdir`(9), `rmdir`(10), `mount`(11),
`sync`(12), `reboot`(13), `pause`(14), `getuid`(15), `kill`(16),
`sigprocmask`(17), `signalfd`(18), `epoll_create`(19), `epoll_ctl`(20),
`epoll_wait`(21), `timerfd_create`(22), `timerfd_settime`(23),
`umount`(24), `pipe`(25), **`mmap`(27)**, **`munmap`(28)**.

Slot **26** is `write_boot_checkpoint(byte)` — a CMOS-write diagnostic from
iron-boot bring-up, not part of the functional set. The 26-call kybernet
surface (0–25) was complete at v1.21.0; `mmap` (27, **1.35.3**) + `munmap`
(28, **1.35.4**) — anonymous, 2 MB-granular — are the first new *functional*
syscalls since. They add a pure memory facility, not socket/crypto surface —
the attack-surface story stays anchored on the **absence** of AF_ALG / socket
/ `splice`, not on a fixed table size.

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

**Single-pin convention retired**: the old "all on one cyrius pin" stack convention dissolved during the v5.11.x burst (2026-05-11/12/13); each repo now pins independently. **agnos is on cyrius 6.0.3** (6.0.1 → 6.0.3 at 1.35.5, 2026-05-27, after a byte-identical kernel A/B — 6.0.1 and 6.0.3 emit the same `build/agnos` to the bit, CI green on both; 6.0.1 had graduated from 5.11.64 mid-1.31.x). The per-repo pin-lag spectrum is tracked in [agnosticos `state.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md) — the genesis repo is authoritative for cross-repo state. **Sibling versions intentionally elided here** to avoid double-bookkeeping.

---

## Test surface

| Gate | Count | Source |
|---|---|---|
| `scripts/check.sh` | **11/11** PASS | build, test, doc-exists ×6, version-in-kernel, version-in-changelog, binary-size |
| `scripts/test.sh --all` | **7/7** PASS | x86 builds, multiboot ELF, size, kernel_hello builds; aarch64 compiles, size, valid ELF |
| CI `boot-test` (QEMU) | banner + `KASLR: pmm_next_free=N` varies across 2 boots + `Memory isolation: PASS` + `Userland exec complete` | `.github/workflows/ci.yml` `boot-test` job |
| CI `Format check` | all kernel sources fmt-clean (1 skip: `kernel/user/shell.cyr` per `#ifdef`-in-fn-body carve-out) | `ci.yml` `check` job |

CI runs on a self-hosted runner labeled `[self-hosted, linux, x64]` for
`boot-test` and `benchmarks` (need QEMU + KVM-class CPU); `build`, `check`,
`test`, `security`, `docs` run on `ubuntu-latest`.

---

## In-flight (roadmap snapshot)

Source: [`docs/development/roadmap.md`](roadmap.md) `## Active` section.

| # | Item | Status |
|---|---|---|
| 1 | **1.35.x networking-comms — COMPLETE** | **1.35.1** TCP hardening B0–B4 (`tcp-smoke.sh` 4/4, `tcp-listen-smoke.sh` 2/2 — in-order ring + retransmit/RTO + MSS/segmentation + peer-window; reliable flow-controlled stream) + **1.35.2** NTP/SNTP (kernel's first wall clock; `ntp`/`date` verbs; `ntp-smoke.sh` parse PASS) — both **RELEASED**. The planned comms order DNS → ICMP → TCP-hardening → NTP is **done**. Audits: [`tcp-hardening-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/tcp-hardening-prior-art.md) + [`ntp-sntp-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/ntp-sntp-prior-art.md). Next (cyrius-side, days-to-weeks): TLS + PIE. Legacy virtio-net back-burnered; plug-and-play a candidate. |
| 2 | AMD Zen Quiet-Boot scanout residue | Parked next-cycle pin (`project_amd_zen_scanout_residue`). MVP unblocked via VGA-spec path; resumption options are HUBP `clear_tiling` port or shadow-buffer FB-console architectural eval. |
| 3 | SMP AP wakeup on real hardware | QEMU-validated only; needs hardware-in-the-loop infra. Stays open across multiple arcs. |
| 4 | `struct Process` `#derive(accessors)` port | Was blocked on a cyrius cap-raise (16-field metadata-table overflow); revisit against the current cyrius 6.0.3 pin — picks up passively when the field-table cap is confirmed lifted. |

Recently closed — arc bookmarks only; per-cut detail in [`CHANGELOG.md`](../../CHANGELOG.md):
- **1.35.7 — arc-close hardening (pass 1)** (latest): `ip_safe_payload_len` clamps the IPv4 total-length at `net_poll` to the received frame — kills a forged-length over-read across ICMP/UDP/TCP. Non-structural (refactor → 1.36.x). `hardening-smoke.sh` green + icmp/tcp/dns/ntp no-regression. Pass-2 candidates in the audit doc.
- **1.35.6 — DNS cache**: 8-entry TTL-respecting positive cache (`dns_cache_find`/`_put`, lwIP-style evict-soonest) + TTL extraction; repeated lookups stop re-querying. `dns-smoke.sh` 3/3. (multi-A/CNAME + retransmit were already in the 1.35.0 stub.)
- **1.35.5 — RTC boot clock**: CMOS RTC read (`rtc_read_unix`) + `civil_to_unix` seed a local wall clock at boot (`date` `[RTC]`/`[NTP]`); NTP refines. Also moved the kernel cyrius pin 6.0.1 → 6.0.3 (byte-identical A/B). `rtc-smoke.sh` green.
- **1.35.4 — `munmap`**: syscall 28 + the inverse of mmap (PD-walk → `proc_unmap_page` + `invlpg` → `pmm_free_2mb`) + LIFO arena reclaim. Closes the mmap/munmap pair. `mmap-smoke.sh` 2/2.
- **1.35.3 — anonymous `mmap`**: syscall 27 + `pmm_alloc_2mb` 2 MB-contiguous allocator; 2 MB-granular zero-filled memory into the caller's address space. First new functional syscall since v1.21.0. (Was the roadmap `mmap (anonymous-only)` open item.)
- **1.35.0–1.35.2 — networking-comms arc**: DNS stub resolver + ICMP/ping + TCP hardening (B0–B4) + NTP/SNTP. The reliable-stream + name-resolution + wall-clock substrate for TLS. All RELEASED + smokes green.
- **1.34.x — FAT-family arc**: FAT12/16/32 + exFAT read **and write** (LFN, cluster allocator, root extension, spanning-append, overwrite/truncate/delete) + ESP-write safety guard (1.34.6). `fsck.fat` / `fsck.exfat` / `mtools` validated.
- **1.33.x — ext2/4 WRITE arc**: file create/write/truncate on ext2/ext4; persist-across-reboot iron-validated (Attempts 90/91).
- **1.32.x — networking arc**: TCP/UDP server primitives + DHCP client + r8169 NIC; iron-COMPLETE (DHCP lease verified 1.32.9; r8169 RX fix 1.32.7).
- **1.31.x — storage arc**: NVMe (iron Attempt 80) + GPT + AHCI/SATA (iron Attempt 87) + USB-MS + RAM-disk + 5-backend block layer + ext2/ext4 read.
- **1.30.x — MVP gate**: typeable shell on archaemenid at Attempt 68 (1.30.9) + FB-hardening sweep (true-font swap 1.30.12).
- **1.27.x – 1.29.x and earlier**: Path-C sovereign UEFI ABI (1.30.0), KASLR / Security Hardening 13/13 (1.28.x), VFS tagged-unions (1.29.x) — see archived `CHANGELOG.md` entries.

---

## Verification hosts

| Host | Purpose | Status |
|---|---|---|
| Self-hosted GH runner (`agnos-runner`) | CI boot-test + benchmarks on real KVM | Active |
| Dev box (Arch, Linux 7.0.3, QEMU 11.0) | Local builds, boot, bench | Active |
| QEMU `-cpu max` x86_64 | Required for boot (boot shim sets SMEP+SMAP in CR4 — `qemu64` default lacks both, triple-faults) | — |
| QEMU `-M virt -cpu cortex-a57` aarch64 | Build target; live boot not yet wired | Compile only |

---

## Refresh discipline

[`CHANGELOG.md`](../../CHANGELOG.md) carries the full per-cut narrative; this file is current-truth + pointers, **not a log**. Arc-level summary lives in the "Recently closed" block above.

`scripts/version-bump.sh` keeps the header date + Version-table row + `roadmap.md "Current"` line fresh atomically with the bump. Body prose (Build artifacts sizes, Source rollup counts, Subsystem status table, In-flight table, Recently-closed bookmarks) needs a **manual sweep at each minor closeout** — the script touches the header, not the body. This pattern was established during the 2026-05-18 doc-staleness audit (script-fresh header found next to v1.29.0-era body prose); the 1.35.0 cycle-open sweep (2026-05-26) brought the body forward from its frozen 1.31.1 shape through the 1.32.x networking / 1.33.x ext2-4-write / 1.34.x FAT-family arcs.
