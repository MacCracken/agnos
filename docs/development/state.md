---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-05-18 (v1.30.7 cycle open — 1.30.5 Phase 4/5 USB-HID kbd landed, 1.30.6 xHCI cmd-path arc bundled FF→QQ, iron-validated on archaemenid NUC AMD 2026-05-15 for boot-to-shell MVP except Enable Slot CCE gate, 1.30.7 next-cycle bump 2026-05-18) | **Refresh cadence**: every release, ideally by `scripts/version-bump.sh`. The script only refreshes header date + Version-row + roadmap "Current" line; body prose drifts independently and needs manual sweeps at minor closeouts.
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md). Iron-bring-up per-attempt detail lives in [agnosticos `iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.30.9** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **5.11.59** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-05-18 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Iron-validated** | 2026-05-15 (archaemenid NUC AMD — boot-to-shell MVP cleared the kernel-init layer; xHCI Enable Slot CCE remains the cmd-path gate as of 2026-05-18 — see `iron-nuc-zen-log` § Attempts 56-62) | NUC AMD Attempts 11 / 29 / 55 |

## Open investigation — xHCI Enable Slot CCE silent-absorb (2026-05-18, archaemenid NUC AMD)

The kernel-init layer + Phase 3 USB silent-absorb closeout (Repair EE at v1.30.5) cleared boot-to-shell-on-iron for the MVP gate. The remaining iron-side blocker is **xHCI Enable Slot CMD_COMPLETION_EVENT never posting on AMD FCH 1022:1639** (Beelink SER AMD Renoir). Symptom: `events_seen=0` over the full `XHCI_CMD_TIMEOUT_SPINS` window following the Enable Slot doorbell, while pre-PR drain shows `drained 1 events` — i.e., the event ring posts *some* events (PSC class) but not CCEs.

Status as of 1.30.7 cut: nine spec-path behavioral repairs (FF → OO) burned and falsified across Attempts 57-62; Repair (QQ + QQ'') MSI-X table programming staged but not yet burned. Per-attempt detail and the convergent-prior-art audit live in [agnosticos iron-nuc-zen-log](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) and [`xhci-prior-art-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/xhci-prior-art-audit.md). Bottoming-out path if QQ falsifies: Repair (PP) UC-remap of DMA regions or decouple Phase 4/5 to QEMU code-completion.

### Resolved (historical, kept as audit trail)

- **2026-05-13 RDRAND under default qemu64 CPU**: kernel stalled at `Page tables: 1024MB mapped` because the smoke test missed `-cpu max` (default `qemu64` lacks RDRAND, `pmm_init` → `kaslr_seed` → `rdrand_u64` faulted silently). Real iron supports RDRAND. Fixed in `gnoboot/tests/ovmf_smoke.sh` with `-cpu max`.
- **2026-05-13/14 Timer-driven context switch under UEFI+gnoboot**: traced to `test_proc_a/b` returning into uninitialized stack memory exposed by gnoboot's pre-handoff state. Closed by Phase 4/5 progression (real user procs replaced test stubs in the boot path) and the iron-validation milestone 2026-05-15 which cleared all 17 init checkpoints + `sched_active=1` + first hlt + context-switch loop on real Zen silicon. Iron-validated milestone supersedes this entire hypothesis class.
- **2026-05-17 Phase 3 USB silent-absorb (Repair EE)**: 13-hypothesis arc through Attempts 32-54 chasing a "controller absorbs PORTSC.PR writes" hypothesis. Root cause: `xhci_portsc_write` inner re-mask `& XHCI_PORTSC_NEUTRAL` stripping the RW1S PR bit. One-line fix in `agnos@41ee6dc`. See CHANGELOG [1.30.5] for the narrative.

The full history of these investigations lives in [`CHANGELOG.md`](../../CHANGELOG.md) and the agnosticos iron-nuc-zen-log. This `state.md` section tracks **live** investigation only — historical investigations should resolve here and migrate to CHANGELOG.

---

## Build artifacts

Measured under cyrius 5.11.59, `CYRIUS_NO_WARN_SHADOW_LIB=1`, default
DCE behavior. All sizes are from `wc -c` on `build/agnos*` after
`scripts/build.sh` / `scripts/build.sh --aarch64`.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **368,968 B** (~360 KB) | ELF64 multiboot2 (Path C — sovereign UEFI boot-info ABI via gnoboot v0.2.0; RDI = `&boot_info`, magic `0x41474E4F`), entry `0x1000a8`. Boots under `qemu-system-x86_64 -cpu max` + OVMF + gnoboot; iron-validated archaemenid 2026-05-15. |
| aarch64 | `build/agnos-aarch64` | **93,640 B** (~91 KB) | Cross-compiled. DTB + EL2→EL1 + PL011 UART + GIC. Compile-tested only — boot harness not yet wired. |

Size trajectory across the 1.28.x → 1.30.x arcs:

| Cut | x86_64 | aarch64 | Delta source |
|---|---|---|---|
| v1.27.2 (arc start) | 248,896 B | 92,216 B | — |
| v1.28.0 | 249,152 B (+256) | 92,488 B (+272) | KASLR (rdrand_u64, kaslr_seed, sign-mask, probe printout, memory-isolation phys-move) |
| v1.28.1 | 249,152 B (=) | 92,488 B (=) | bench-history schema only |
| v1.28.2 | 249,984 B (+832) | 93,288 B (+800) | ktagged.cyr + VFS port + VfsType enum |
| v1.28.3 | 250,704 B (+720) | 93,288 B (=) | PciDev `#derive(accessors)` (x86-only) |
| v1.29.0 | 250,704 B (=) | 93,288 B (=) | Closeout — doc-only |
| v1.29.1 | 251,312 B (+608) | 93,288 B (=) | NUC AMD iron Attempt-8 ltr-slot fix, Attempt-9 SMP-SIPI gate |
| v1.30.0 | ~266,312 B (+15,000) | 93,288 B (=) | **Path-C sovereign UEFI boot-info ABI**: ELF64 + multiboot2 entry, RDI handoff convention, kernel/version.cyr auto-generated banner module (v1.30.2 cleanup) |
| v1.30.2 → .4 | 273,816 → 295,496 B | 93,288 → 93,288 B | xHCI Linux-diff hardening closeout (XHCI BAR UC remap, PORTSC strict-RW1S model, USB-HID Phase 1-3) |
| v1.30.5 | ~360,000 B | 93,640 B | Phase 4/5 USB-HID boot keyboard driver: `hid_kbd_configure`, `hid_poll`, HID→PS/2 mapping, kb_buf writer; Repair (EE) PORTSC inner-remask fix closed Phase 3 silent-absorb arc |
| v1.30.6 | 367,944 → 368,568 B | 93,640 B | xHCI cmd-path arc Repairs FF → OO (IMAN.IE=1, AMD-Vi disable, doorbell readback, universal readback, CNR poll, Link TRB cycle, MSI-X FuncMask, ERDP/ERSTBA reorder, OO Tier 2 bundle). Iron unresolved as of cut — `events_seen=0` survives all nine. |
| v1.30.7 | **368,968 B** (+400) | **93,640 B** (=) | Repair (QQ + QQ'') MSI-X Table vector-0 programming (first arc repair tied to a named Linux-implicit divergence rather than spec-path reorder); staged-not-yet-burned. |

---

## Source rollup

| Tree | Files | Notes |
|---|---|---|
| `kernel/` (total) | **49** `.cyr` | 6,306 lines across all kernel sources |
| `kernel/agnos.cyr` | 1 | Main orchestrator — only `#ifdef` + `include` |
| `kernel/kernel_hello.cyr` | 1 | Minimal smoke test |
| `kernel/klib/` | 3 | `kstring.cyr`, `kfmt.cyr`, `ktagged.cyr` — vendored kernel-safe stdlib (renamed from `kernel/lib/` to dodge cyrius wrapper's `./lib/` shadow contract) |
| `kernel/arch/x86_64/` | 14 | boot_shim, boot_data, serial, gdt, idt, pic, apic, smp, keyboard, paging, io, syscall_hw, ring3, iommu |
| `kernel/arch/aarch64/` | 9 | boot_data, serial, gic, timer, exceptions, keyboard, paging, stubs, main |
| `kernel/core/` | 18 | pmm, vmm, heap, proc, sched, syscall, vfs, devs, initrd, kprint, main, net, virtio_net, virtio_blk, fatfs, pci, acpi, elf |
| `kernel/user/` | 4 | shell, init, test, test_procs |

---

## Subsystem status (35+)

All subsystems are **code-complete** through v1.30.7. Phase 4/5 USB-HID keyboard driver landed v1.30.5; the xHCI Enable Slot CCE gate (see "Open investigation" above) is the only iron-side blocker for the boot-to-shell MVP. The roadmap's "Active" table is the source of truth for in-flight work; this is the shipped surface.

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
| 1 | xHCI Enable Slot CCE silent-absorb on AMD FCH 1022:1639 | **Iron-side, archaemenid**. Nine spec-path repairs FF→OO falsified Attempts 57-62; Repair (QQ + QQ'') MSI-X table programming staged at 1.30.7 cut, not yet burned. Bottoming-out: Repair (PP) UC-remap DMA regions OR decouple Phase 4/5 to QEMU. |
| 2 | SMP AP wakeup on real hardware | QEMU-validated only; needs hardware-in-the-loop infra (RPi4 / NUC). Stays open across multiple arcs. |
| 3 | `struct Process` `#derive(accessors)` port | Blocked on cyrius v5.11.x cap-raise — upstream acknowledged the 16-field metadata-table overflow + slotted for repair. Picks up passively at the next cyrius pin bump. |

Recently closed (see [`CHANGELOG.md`](../../CHANGELOG.md)):
- **v1.30.7** — version bump for next-cycle work (no kernel source delta beyond the bump itself)
- **v1.30.6** — xHCI cmd-path arc bundle: Repairs FF (IMAN.IE=1) → GG (AMD-Vi disable) → HH (doorbell readback) → JJ (universal readback) → KK (CNR poll) → LL (Link TRB cycle) → MM (MSI-X FuncMask) → NN (ERDP/ERSTBA + CRCR/IMOD reorder) → OO (Tier 2 convergent-prior-art bundle) → QQ (MSI-X Table programming, staged in this cut). 13-entry consolidated CHANGELOG covering the whole arc.
- **v1.30.5** — Phase 4/5 USB-HID boot keyboard driver: `hid_kbd_configure` + `hid_poll` + HID→PS/2 mapping + `kb_buf` writer. Repair (EE) PORTSC inner-remask one-line fix closed the 13-hypothesis Phase 3 silent-absorb arc.
- **v1.30.4** — xHCI Linux-diff hardening closeout (BAR UC remap, PORTSC strict-RW1S, USB-HID Phase 1-3)
- **v1.30.0** — Sovereign-struct kernel ABI: ELF64 multiboot2, RDI = `&boot_info` Path-C handoff via gnoboot v0.2.0; kernel/version.cyr auto-generated banner module at v1.30.2
- **v1.29.0** — closeout pass for the 1.28.x arc
- **v1.28.x arc** — KASLR data-only (Option B, S7 closed), VFS tagged unions, PciDev derive, bench-history schema, sched.cyr cr3_load helper. Security Hardening track fully closed 13/13 at v1.28.0.
- **v1.27.x arc** — see archived entries in `CHANGELOG.md`

---

## Verification hosts

| Host | Purpose | Status |
|---|---|---|
| Self-hosted GH runner (`agnos-runner`) | CI boot-test + benchmarks on real KVM | Active |
| Dev box (Arch, Linux 7.0.3, QEMU 11.0) | Local builds, boot, bench | Active |
| QEMU `-cpu max` x86_64 | Required for boot (boot shim sets SMEP+SMAP in CR4 — `qemu64` default lacks both, triple-faults) | — |
| QEMU `-M virt -cpu cortex-a57` aarch64 | Build target; live boot not yet wired | Compile only |

---

## What changed at v1.30.6 / v1.30.7

[`CHANGELOG.md`](../../CHANGELOG.md) carries the full narrative. The 1.30.6 entry was consolidated from a Repair-FF-only stub plus an accumulating [Unreleased] section into a single comprehensive arc-bundle covering Repairs FF through QQ — the "xHCI cmd-path arc — FF through QQ; MSI-X table programming closeout" entry dated 2026-05-18. 1.30.7 is a version bump for the next cycle (empty CHANGELOG placeholder until work accumulates). Per-attempt iron narrative continues in [agnosticos `iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

The systemic refresh discipline: `scripts/version-bump.sh` keeps the header date + Version-table row + `roadmap.md "Current"` line fresh atomically with the bump; body prose (Open Investigation, Build artifacts table extension, Recently closed bullet list, ecosystem block, In-flight table) needs manual sweep at each minor closeout. This pattern was clarified during the 2026-05-18 doc-staleness audit when the script-fresh header was discovered next to v1.29.0-era body prose.
