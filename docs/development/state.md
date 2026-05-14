---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-05-13 (v1.29.0 closeout) | **Refresh cadence**: every release, ideally by `scripts/version-bump.sh`. If a row above goes stale by more than a minor's worth of work, the row is wrong — fix it or move it.
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.30.0** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **5.11.53** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-05-13 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Last assertion tightened** | `KASLR: pmm_next_free=N` varies across two boots | CI `boot-test` job, v1.28.0 (**currently broken — see "Open investigation" below**) |

## Open investigation — timer-driven context switch under UEFI+gnoboot (2026-05-13, iron-confirmed 2026-05-14)

gnoboot v0.1.0 successfully delivers the sovereign boot-info struct
to the kernel via Path C (`RDI = &boot_info`, magic `0x41474E4F`).
**Most of the kernel boot now works under UEFI+gnoboot**; the
remaining stall is specifically in the timer-driven scheduler loop.

### Iron-confirmed 2026-05-14: NUC AMD Attempt 11 reaches CP 0x10 (scheduler armed)

Reflashed kernel (251,312 B ELF64, carries Attempt-8 ltr-slot fix,
Attempt-9 SMP-SIPI gate, current `ce745c7` boot repairs) booted on
archaemenid (Beelink SER, Zen) with all of:

- gnoboot CMOS CP 0x05 / magic 0xCD → all 5 pre-jump checkpoints
  reached, ELF64 mapping + `jmp rax` handoff clean.
- kernel CMOS CP **0x10** / magic 0xAB → `agnos/kernel/core/main.cyr:296`
  reached, written immediately after `sched_active = 1`. Full init
  chain executed: `gdt_init` → `tss_init` → `idt_init` → `pic_init`
  → `apic_init` → `apic_timer_init` → `smp_start_aps` (SIPI gated)
  → `pt_init` → `pmm_init` → `vmm_init` → `heap_init` → `dev_init`
  / `acpi_init` / `pci_scan` → `vfs_init` → `syscall_init` → proc
  creation → `sti` → scheduler activation.
- **First positive framebuffer signal on iron**: white canary stripe
  painted at top-left from `boot_shim.cyr:200-206` ELF64 shim asm.
  `[rdi+0x48]` (fb_phys from gnoboot's GOP capture in boot-info v2)
  was non-null AND the kernel-side asm wrote 256 white pixels
  successfully. Retroactively flips the iron Attempt 7 Case-A
  diagnosis: framebuffer **is** reachable from kernel-side under
  UEFI+gnoboot+ELF64 on this Zen iron.
- did NOT reach kernel CP 0x11 (`main.cyr:309`, written after the
  50-iteration `while (idle_count < 50) { arch_wait(); }` idle loop
  completes). Reset between scheduler arm and post-loop CP write.

**Iron confirms the QEMU+UEFI investigation independently.** Different
firmware (AMI BIOS vs. OVMF), different memory layout (real Zen vs.
emulated), same fault site (post-`sched_active=1` idle/timer loop).
The hypothesis below — `test_proc_a/b` returning into uninitialized
stack memory exposed by gnoboot's pre-handoff state — is now backed
by iron evidence as well as QEMU.

**MVP-relevant.** The kernel-init layer of the AGNOS MVP closed-beta
gate is cleared on iron. All 17 init checkpoints pass. Boot-to-shell
on hardware blocks only on the scheduler dispatching a runnable user
task (kybernet PID 1 / agnoshi).

Iron-side bisector + fix plan: see Attempt 12 in
`agnosticos/docs/development/iron-boot-testing-log.md` (finer CMOS
checkpoints around the post-`sched_active=1` loop + the `if (0 == 1)`
→ `while (1 == 1)` patch on `test_proc_a/b` as the cheapest of the
three fix paths below).

### Resolved 2026-05-13: RDRAND under default qemu64 CPU

Initial diagnosis said the kernel stalled at `Page tables: 1024MB mapped`.
Root cause was the gnoboot smoke test missing `-cpu max` (the default
`qemu64` lacks RDRAND, and `pmm_init` → `kaslr_seed` → `rdrand_u64`
faults silently). agnos's old CI explicitly used `-cpu max` for the
same reason (CR4 SMEP/SMAP on the legacy `-kernel` path). Real iron
(NUC AMD / Zen) supports RDRAND natively, so this is a QEMU-only
config issue.

Fixed in `gnoboot/tests/ovmf_smoke.sh` by adding `-cpu max` to the
QEMU invocation.

### Open: timer-driven context switch broken — deeper than test_proc alone

Investigation 2026-05-13: hypothesised the root cause was test_proc_a/b
returning into uninitialized stack memory. Tried the minimal fix —
adding `while (1 == 1) { arch_wait(); }` after the `if (0 == 1)`
body so the procs never return. Build clean, but result was **worse**:
not even the first hlt returned post-`sched_active = 1` (vs. 10 hlts
returning on the unfixed baseline). Reverted the change.

Conclusion: the kernel-side issue isn't just test_proc returning;
there are multiple latent interactions between gnoboot's
pre-handoff state and the kernel's scheduler/page-table/APIC code
that need focused agnos work, not a probe-and-quick-fix. Likely
involves at least:

- `pt_init` writing kernel-PML4/PDPT/PD at fixed physical
  `0x1000/0x2000/0x3000` (works under `-kernel` because the boot
  shim seeded them; broken under UEFI because UEFI's actual page
  tables are elsewhere and `0x1000-0x4000` is just random memory).
- `apic_init` mapping `0xFEE00000` via the same `0x1000`-area page
  tables that aren't the active CR3.
- Per-process page tables built off the (broken) kernel PD at
  `0x3000`, so context switches to per-proc CR3 may corrupt or
  cycle in unexpected ways.

### Recommendation

Ship agnos CI restructure with **relaxed assertions** (banner +
KASLR + `Activating scheduler`), file a focused agnos sub-arc for
the scheduler-under-UEFI work, and let iron Attempt 5 (different
firmware, different memory layout) speak independently.

### Open (earlier): timer-driven context switch breaks after ~10 iterations

With `-cpu max` in the smoke test, the kernel boots through all 17
init checkpoints (PMM, KASLR, VMM, Heap, ACPI, PCI, VFS, SYSCALL,
processes, interrupts enabled) and reaches `Activating scheduler...`.
DBG-probe bisection (since reverted) showed:

- ✓ Idle loop entered (`DBG: sched_active=1, entering idle`).
- ✓ First hlt returns (`DBG: first hlt returned`) — timer ISR fires
  + handler runs + apic_eoi works + iretq returns to idle loop.
- ✓ 10 hlts done (`DBG: 10 hlts done`) — at least 10 timer-driven
  context switches complete successfully.
- ✗ Iteration 50 never reached, even with 60s QEMU timeout. So
  somewhere after the 10th-or-so iteration, the cycle breaks.

The break is **not** a hard fault (no exception dump from OVMF, no
silent reset) — it's the timer-context-switch cycle stopping.

Likely root cause: `test_proc_a` and `test_proc_b` in
`kernel/user/test_procs.cyr` are *2-instruction noops* in the
default build. The `if (0 == 1) { serial_print("A"); arch_wait(); }`
body never runs; the fn just `return 0;` immediately. (`bench.sh`
patches the `if` to `while (1 == 1)` at build time for the bench
mode — making the procs busy-loops — but standard `scripts/build.sh`
doesn't.) After test_proc_a's `ret`, RSP pops a return address from
**uninitialized stack memory** (`stack_a + 0x4000`-relative). Under
`-kernel`, that memory was somehow consistently zero or otherwise
benign; under UEFI+gnoboot, after some iterations it lands on an
address that breaks the timer-context-switch cycle (typically by
disabling interrupts, masking the APIC LVT, or jumping into
unmapped space without a #PF cascade).

This is a **latent agnos kernel bug** (test_proc_a/b should never
have been usable in a context-switch loop given their fast
`return 0;` shape), exposed by gnoboot's different pre-handoff
memory contents. Fixes:

1. **Make test_proc_a/b real busy-loops in the default build** —
   the `if (0 == 1)` → `while (1 == 1)` patch that bench.sh does
   at build time should be the *default* shape; the fast-exit
   shape is what bench needs to escape, not what tests need.
2. OR: **wrap test_proc fns with a busy loop** in `proc_create_full`
   so any returning process bounces back into a halt loop instead
   of popping garbage off its own stack.
3. OR: **switch to dedicated kernel threads** that explicitly
   `arch_wait()` in a loop, retiring `test_proc_a`/`test_proc_b`.

Slot: agnos 1.30.x, probably as a small follow-up patch. Not iron-
boot-blocking — iron Attempt 5 doesn't care about the scheduler
test_procs; if the kernel boots far enough on iron to print its
banner + reach the scheduler-test point, MVP is cleared.

**Not a gnoboot issue** — handoff is verified correct. Documented
here as the agnos investigation handoff.

---

## Build artifacts

Measured under cyrius 5.10.44, `CYRIUS_NO_WARN_SHADOW_LIB=1`, default
DCE behavior. All sizes are from `wc -c` on `build/agnos*` after
`scripts/build.sh` / `scripts/build.sh --aarch64`.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **250,704 B** (~245 KB) | Multiboot1 ELF, entry `0x100060`. Boots under `qemu-system-x86_64 -cpu max`. |
| aarch64 | `build/agnos-aarch64` | **93,288 B** (~91 KB) | Cross-compiled. DTB + EL2→EL1 + PL011 UART + GIC. Compile-tested only — boot harness not yet wired. |

Size trajectory across the 1.28.x arc:

| Cut | x86_64 | aarch64 | Delta source |
|---|---|---|---|
| v1.27.2 (arc start) | 248,896 B | 92,216 B | — |
| v1.28.0 | 249,152 B (+256) | 92,488 B (+272) | KASLR (rdrand_u64, kaslr_seed, sign-mask, probe printout, memory-isolation phys-move) |
| v1.28.1 | 249,152 B (=) | 92,488 B (=) | bench-history schema only (no kernel-source change) |
| v1.28.2 | 249,984 B (+832) | 93,288 B (+800) | ktagged.cyr + VFS port + VfsType enum + layout comment |
| v1.28.3 | 250,704 B (+720) | 93,288 B (=) | PciDev `#derive(accessors)` (x86-only) |
| v1.29.0 | 250,704 B (=) | 93,288 B (=) | Closeout — doc-only changes, no kernel source delta |

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

All subsystems are **complete** through v1.29.0. The roadmap's "Active" table
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
| 1 | SMP AP wakeup on real hardware | QEMU-validated only; needs hardware-in-the-loop infra (RPi4 / NUC). Stays open across multiple arcs. |
| 3 | `struct Process` `#derive(accessors)` port | Blocked on cyrius v5.11.x cap-raise — upstream acknowledged the 16-field metadata-table overflow + slotted for repair. Picks up passively at the next cyrius pin bump. |

Recently closed (see [`CHANGELOG.md`](../../CHANGELOG.md)):
- **v1.29.0** — closeout pass for the 1.28.x arc (this cut)
- **v1.28.3** — struct refactor: `PciDev` `#derive(accessors)` ✅; `vfs_table` counted (ktagged in v1.28.2); `proc_table` blocked (filed upstream). Active #3 partially closed. Plus a v1.27.x-era hygiene fix in `sched.cyr` (cr3_load helper for the CR3-load brittle pattern)
- **v1.28.2** — VFS tagged unions via new `kernel/lib/ktagged.cyr`. Active #2 closed
- **v1.28.1** — `serial_putc` methodology: bench-history provenance schema; matched-conditions re-measure showed the "regression" was QEMU drift. Active #7 closed
- **v1.28.0** — KASLR (data-only); Security Hardening track fully closed (13/13)
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

## What changed at v1.27.1

See [`CHANGELOG.md`](../../CHANGELOG.md) for the narrative.
Mechanical diff: 12 files modified, 121 added, 23 removed; two issue
docs archived (`memory-isolation-deep.md`, `cr3-load-helper.md`).
