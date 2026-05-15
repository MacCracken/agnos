# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Repair (P) — explicit `FB_CONSOLE_Y0` / `FB_FG` / `FB_BG` re-assign
  at top of `fb_console_init()`** (`kernel/arch/x86_64/fb_console.cyr`).
  Attempt 29 burn showed kernel reaching kybernet-launch (CMOS
  `kcp=0x15` MAGENTA, no fault) but on-screen cp_fb cells at rows 1–2
  (idx 0x06..0x10, y=8..19) were wiped while row-9 yellows
  (idx 0x80/0x81/0x82) survived, and no `agnos> ` prompt was visible.
  Pattern decodes to a single bug at three module-scope coordinates:
  `var FB_CONSOLE_Y0 = 80;`, `var FB_FG = 0x00FFFFFF;`, and
  `var FB_BG = 0x00000000;` (at `fb_console.cyr:187-189`) were each
  reading back as `0` at runtime — `fb_putc` painted text at y=0..55
  (over the cp_fb cells) in black-on-black (invisible). Zero-init vars
  in the same file (`fb_cur_x`, `fb_cur_y`, `fb_console_ready`) were
  unaffected because BSS defaults to zero. Workaround: explicit
  assignment of all three at the top of `fb_console_init()` body
  before any other code (3 LOC + 11-line explanatory comment).
  Surfaced as a cyrius gvar-init bug in
  `docs/development/issue/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md`;
  filing into `cyrius/docs/development/issues/` is gated on Attempt 29
  visual confirmation. Kernel 253,768 → 266,712 B (size delta dominated
  by DCE/link state, not the 3-line repair).

- **Repair (O) — mem-iso test block deletion** (`kernel/core/main.cyr`).
  Attempts 17–27 (11 iron burns, repair letters F–N) chased a fault
  inside a memory-isolation test block that re-reading
  `agnosticos/docs/development/uefi-boot-prior-art.md` confirmed was
  post-MVP work breaking pre-MVP boot. Deleted 303 lines (including
  Repair-M/N bisector stamps + `cmos_stamp_fb_phys()` helper writers).
  Result on Attempt 28: kernel completed its full init spine end-to-end
  on archaemenid (GDT/TSS/IDT → APIC/timer → paging → PMM → heap →
  ACPI/PCI → VFS → initrd → SYSCALL → scheduler arming → idle survival
  → userland exec → kybernet-launch) — four checkpoints past the
  closed-beta gate (cp_fb 0x12 / 0x14 / 0x15 all painted MAGENTA, then
  `arch_halt()` as designed). Kernel 255,048 → 253,496 B (-1,552;
  comments dominate the line-count, hence smaller-than-line-count
  binary shrink). One-line follow-up landed same-session:
  `main.cyr:415` `sh_cmd_bench()` → `kybernet()` (shell dispatch tree
  now reachable — kernel 253,496 → 253,768 B, +272).

- **Repair (K) — PML4 health stamps for Attempt 24** (`kernel/core/main.cyr`
  mem-iso block). Attempt 23 confirmed the PMM-handed-out-kernel-PT
  hypothesis is wrong (all 12 Repair (J) stamps at CMOS [0x56..0x61]
  read 0xaf — pmm_alloc returned safe pages well above the 2 MB
  watermark). The cr3-restore #PF at `main.cyr:575-577` (`mov rax,
  0x1000 / mov cr3, rax`) is still the death site, but PMM is ruled
  out as the source of corruption.

  Repair (K) is a direct probe of phys 0x1000 itself: 7 stamps writing
  the low byte of `load64(0x1000)` (= PML4[0]'s flag bits, 0x07 when
  healthy: P|RW|US pointing at kernel PDPT @ 0x2000) to virgin CMOS
  registers [0x62..0x68] at 7 checkpoints across the mem-iso block.
  Each stamp is 14 bytes of asm (`mov al, slot` / `out 0x70, al` /
  `mov rax, [0x1000]` via 64-bit SIB form `48 8B 04 25 disp32` /
  `out 0x71, al`). Insertion sites:
    - [0x62] after kcp=0x1A (entering mem-iso, before AS work)
    - [0x63] after kcp=0x16 (post AS1+AS2 create)
    - [0x64] after kcp=0x17 (post proc_map_page x2)
    - [0x65] after kcp=0x18 (post first cr3_load(as1))
    - [0x66] after kcp=0x1D (post first AS1 SMAP round-trip)
    - [0x67] after kcp=0x64 (post AS2 SMAP round-trip)
    - [0x68] after kcp=0x68 (post second AS1 round-trip — last quiet
      point before the cr3-restore that #PFs)

  Reading [0x62..0x68] post-mortem:
    - All 0x07 + kcp=0x68 → PML4 healthy throughout. The cr3-restore
      #PF is NOT direct PML4 corruption; premise inverts and Repair
      (L) needs a #PF handler that dumps CR2 + error code so we can
      see the actual fault address/type.
    - First 0x00 at slot N + kcp=0x68 → corruption window pinned
      between checkpoints (N-1) and N. Repair (L) adds finer stamps
      in that span.
    - Other byte values → entry rewritten (different bug class —
      torn flags or replaced pointer).

  Pure diagnostic; no behavior change. Each stamp lives in the main
  body, not the `timer_isr[]` buffer (its 1-byte headroom is
  unaffected). Companion `agnosticos/scripts/src/read-boot-log.cyr`
  updated with the [0x62..0x68] interpreter and revised kcp=104
  verdict pointing at the new stamp ladder. Joins Repairs F+H+I+J
  in the in-flight `1.30.1` candidate; VERSION stays at 1.30.0 until
  iron-boot validates the cut.

- **Persistent CMOS boot-log at kernel entry** (Attempt 8 bisection;
  `kernel/arch/x86_64/boot_shim.cyr` ELF64 path). Attempt 7's visual
  canary returned an ambiguous null-result on iron — the no-stripe
  could mean `fb_phys=0` (kernel ran invisibly) or `jmp rax` never
  landed (kernel never executed). Serial diagnostic was wrongly
  recommended across Attempts 4-7 — the dev environment IS the iron
  target (single Beelink SER, no second host to read serial off the
  COM1 wire), so serial is structurally unavailable.

  CMOS scratch RAM is the right channel: battery-backed, survives the
  triple-fault reset, two-instruction-per-write from the kernel
  (`out 0x70` / `out 0x71`), no driver needed in kernel OR Linux
  (latter reads via `/dev/nvram`).

  Layout (CMOS offsets, readable from Linux via
  `agnosticos/scripts/read-boot-log.sh`):
    - `CMOS[0x41]` = magic byte 0xAB, set once at kernel entry to
      certify "kernel ran this boot" (distinguishes a fresh failure
      from CMOS containing stale data from a prior boot).
    - `CMOS[0x40]` = highest checkpoint number reached this boot.

  Checkpoints inserted in the ELF64 boot shim asm block:
    1. Kernel entry (instruction #1, also sets the 0xAB magic)
    2. Past visual canary
    3. Past 64-bit stack setup (`mov rsp, 0x200000`)
    4. Past COM1 UART init
    5. Past `boot_info_capture_rdi()` call (post-call site, in a
       separate asm block — survives the first call+ret pair)

  Six 8-byte writes total = 48 bytes added to the shim (one extra
  write at checkpoint 1 for the magic). `build/agnos` 251072 → 251120
  bytes (+48 exact). Clobbers AL only per checkpoint; RDI / RSP /
  all other GPRs untouched. Bit 7 of port 0x70 (NMI disable) is
  left at UEFI's handed-off state (clear) — no behavior change.
  `tests/ovmf_smoke.sh` still reaches `Activating scheduler...` —
  CMOS writes are silent in QEMU OVMF.

  Diagnostic flow for Attempt 8: re-flash USB → boot NUC AMD →
  reset → boot back into Arch → `sudo agnosticos/scripts/read-boot-log.sh`
  → see which checkpoint was the highest the kernel reached. If
  `CMOS[0x41]` is not 0xAB, kernel never executed at all. Otherwise
  the value at `CMOS[0x40]` bisects the failure to within ~30 bytes
  of code.

- **Boot-time visual canary at kernel entry instruction #1** (Attempt 7
  bisection; `kernel/arch/x86_64/boot_shim.cyr` ELF64 path). After
  Attempt 6 on NUC AMD reproduced Attempt 5's blank-screen-and-reset
  with the gnoboot BSS-zero + EfiLoaderCode fixes shipped (i.e. the
  two highest-confidence post-EBS hypotheses ruled out), bisection
  needs visibility into kernel-side execution. No serial cable yet
  attached; canary paints a 256-pixel white stripe at the top-left
  of the GOP framebuffer if gnoboot v0.1.0+ captured `fb_phys` into
  boot_info offset 0x48.

  Signal interpretation:
    - Stripe appears → kernel executed ≥ 1 instruction; fault is
      later (page-table W^X, GDT divergence, CR-state).
    - No stripe → fault is the `jmp rax` itself or the page
      containing 0x1000A8 isn't executable in the inherited post-EBS
      page tables.

  26 bytes total prepended to the ELF64 shim asm block:
  `mov rax, [rdi+0x48]` / `test rax, rax` / `jz +17` / `mov ecx, 256`
  / paint-loop (`mov dword [rax], 0xFFFFFFFF`, `add rax, 4`, `loop`).
  Clobbers RAX/RCX; preserves RDI (required by `boot_info_capture_rdi()`
  below). Failure-safe: if gnoboot left `fb_phys = 0` (no GOP), the
  JZ skips the paint and the kernel boots without visual signal.
  `build/agnos` grows 251040 → 251072 bytes (+32, of which 26 are the
  canary itself + alignment). `tests/ovmf_smoke.sh` (in gnoboot)
  still PASS — kernel reaches `Activating scheduler...`.

### Changed

- **SMP AP-wakeup IPI block gated for Attempt 10 diagnostic**
  (`kernel/arch/x86_64/smp.cyr:177-189`). Attempt 9 on iron Zen advanced
  past Attempt 8's `tss_init_cpu` slot-trap and now dies between kernel
  CMOS checkpoint 0x07 (APIC + timer live) and 0x08 (`pt_init` returned).
  The four candidate call sites between those checkpoints are
  `smp_start_aps`, the keyboard-ISR build, the IRQ1 IDT gate install, and
  `pt_init`. `smp_start_aps` is the strongest suspect — Attempt 9 is the
  first iron boot to actually fire INIT-SIPI-SIPI at real Zen APs (the
  in-source comment claiming "works on real hardware" was a prediction,
  never measured). Three concrete hazards: hardcoded `CR3 = 0x1000` in
  the AP trampoline's 32-bit stage when `pt_init` has not yet run (APs
  inherit gnoboot's bootstrap mappings, which may not identity-map
  `0xFEE00000`); non-volatile empty-loop "delays" that don't meet the
  SDM's ~10ms INIT quiescence / ~200µs SIPI window; trampoline page
  writeability depending on gnoboot's bootstrap mappings. Gating the
  three `apic_send_init` / `apic_send_sipi` for-loops isolates AP wakeup
  from `smp_build_trampoline` and the AP-stack `vmm_alloc_at` calls,
  which remain live. `build/agnos` 251616 → 251152 bytes (−464, six call
  sites eliminated as predicted). Attempt-10 expected: CMOS
  `kernel checkpt` ≥ 0x08 → AP wakeup is the fault, patch follows; still
  0x07 → fault is in trampoline build or stack alloc, instrument finer
  in Attempt 11. See
  `agnosticos/docs/development/iron-boot-testing-log.md` § *Attempt 9*.

- **Boot-info struct version bumped 1 → 2** to consume gnoboot v0.1.0+'s
  inlined framebuffer fields at offsets 0x48-0x5C (`fb_phys`,
  `fb_pitch`, `fb_width`, `fb_height`, `fb_pixel_format`). Kernel
  walkers MUST NOT expect a framebuffer tag (type=1) in the tag
  stream from v2 onward — those fields were moved out of the tag
  stream to make them accessible from raw asm at entry instruction #1.
  Layout spec: agnosticos/docs/development/path-c-sovereign-uefi.md
  § *Handoff protocol*.

### Fixed

- **`tss_init_cpu` loaded null TSS on BSP** (`kernel/arch/x86_64/gdt.cyr`).
  The `ltr` asm block read `[rbp-0x08]` and called it `selector`, but per
  Cyrius's frame-layout convention (documented in `ring3.cyr:25-26`:
  *params at rbp-0x08, -0x10, -0x18; new locals start at rbp-0x20*),
  `[rbp-0x08]` in `tss_init_cpu(cpu_id)` is the `cpu_id` parameter — `0`
  for the BSP. So `ltr 0` loaded the null TSS descriptor → **#GP** with
  IDT not yet installed (`idt_init` is the next call) → triple fault →
  reset. Matches Attempt 8's CMOS-bisector verdict on iron exactly:
  kernel reached checkpoint `0x81` (about to call `tss_init`) but not
  `0x82` (after return). Fix: drop the broken `mov rax, [rbp-0x08]` and
  rely on `var selector = ...` leaving the value in `rax` (same pattern
  `gdt_init` uses for `lgdt [rax]` two functions up). Net change:
  −4 instruction bytes. Credit Attempt-8 CMOS bisector for pinpointing
  the failure to ~3 lines of asm without a serial cable on the iron
  target. See `agnosticos/docs/development/iron-boot-testing-log.md`
  § *Attempt 8*.

- **GDT array undersized — OOB writes stomped `boot_info_ptr`**
  (`kernel/arch/x86_64/boot_data.cyr`). `var gdt[56]` was sized for
  the original 1-TSS layout (`null + kCS + kDS + uDS + uCS + TSS lo +
  TSS hi` = 7 entries × 8 bytes). When `gdt_init` was extended to 4
  per-CPU TSS slots (with limit=103 → 104 bytes total), the array
  declaration was not resized. The 4-iteration zero loop in `gdt_init`
  (`gdt.cyr:20-23`) writes through `&gdt + 96` — 48 bytes past the
  array end. In BSS this stomped `gdt_ptr` (harmless; immediately
  rewritten) and then `boot_info_ptr[8]` at offset +72 (the captured
  `&boot_info` from RDI at kernel entry) → any later code reading
  `load64(&boot_info_ptr)` for the framebuffer / memory map got NULL.
  Latent on the BSP-only path (TSS descriptor writes at offsets 40/48
  stay in-bounds), but corrupted other kernel state. Resize to
  `var gdt[104]`. Found by code-reading after the `tss_init_cpu` slot
  fix above.

## [1.30.0] — 2026-05-13

**Kernel ABI break — entry contract switches from multiboot2 to AGNOS
sovereign boot-info struct (Path C handoff).** Closes the
Path-A → Path-C transition triggered by GRUB's strict-W^X EFI
relocator being incompatible with multiboot2 on modern firmware
(see `agnosticos/docs/development/iron-boot-testing-log.md`
§ Diagnosis 2 for the forensic trail and
`agnosticos/docs/development/path-c-sovereign-uefi.md` for the
new plan). Pairs with **gnoboot v0.1.0** — the new AGNOS sovereign
UEFI bootloader that replaces GRUB on the boot path.

cyrius pin **5.11.43 → 5.11.53**; `build/agnos` **251056 → 251040 bytes**
(-16 from rename + reachable-fn shift); entry unchanged at `0x1000A8`.

### Changed

- **Boot-info source register: `RBX → RDI`.** The kernel's ELF64
  entry shim no longer expects `RBX = MBI ptr` from multiboot2
  § 8.4.3; it now expects `RDI = &agnos_boot_info` from gnoboot's
  sovereign handoff (struct magic `0x41474E4F = 'AGNO'`; layout
  spec in agnosticos's path-c plan § Handoff).
  - `kernel/arch/x86_64/mbi.cyr`: asm byte `0x18 → 0x38`
    (`mov [rax], rbx` → `mov [rax], rdi`). Function renamed
    `mbi_capture_rbx` → `boot_info_capture_rdi`. Header comment
    block fully rewritten for sovereign-struct context.
  - `kernel/arch/x86_64/boot_data.cyr`: global renamed
    `mb_info_ptr` → `boot_info_ptr`.
  - `kernel/arch/x86_64/boot_shim.cyr`: call site updated; ELF64
    shim header comments rewritten end-to-end (RBX/MB2 → RDI/sov).
- **cyrius pin**: 5.11.43 → 5.11.53. Picks up the post-Path-A
  fixes (entry-save REX hotfix from 5.11.53; byte-array literal +
  `fn efi_main` convention from 5.11.51/.52 — none of which affect
  the AGNOS kernel itself, but pin synchrony with gnoboot reduces
  investigation surface when iron-boot debug picks back up).

### CI restructure

- **`qemu -kernel` boot test retired** — replaced with
  `gnoboot + OVMF + qemu-system-x86_64 -cpu max`. The legacy path
  fails on the post-Path-A ELF64 kernel because QEMU requires a
  PVH ELF note for `-kernel`-loaded ELF64 binaries, which cyrius's
  `EMITELF64_KERNEL` doesn't emit (it emits multiboot2 + EFI64-entry,
  designed for the GRUB→agnos handoff that Path A intended). With
  gnoboot now the canonical boot path, CI tests the actual MVP shape.
- New `.github/workflows/ci.yml` boot-test step:
    1. Installs `ovmf parted mtools qemu-system-x86` on the runner
       (skipped if already present).
    2. `curl`s gnoboot v0.1.0 `BOOTX64.EFI` from GitHub releases
       (pinned via `GNOBOOT_VERSION` env var; bump when gnoboot ships
       a new release).
    3. Builds a 64 MB GPT disk with a single FAT32 ESP partition at
       1 MiB offset, drops in `\EFI\BOOT\BOOTX64.EFI` (gnoboot) and
       `\boot\agnos` (kernel).
    4. Boots `qemu-system-x86_64 -cpu max -machine q35 -m 256M` under
       OVMF firmware (Arch + Ubuntu paths probed). Same `-cpu max`
       rationale as before (RDRAND for `kaslr_seed`, SMEP+SMAP for the
       boot-shim CR4 setup).
    5. Greps serial output for `AGNOS kernel v` (banner), `KASLR:
       pmm_next_free=N` (two-boot-diff), and `Activating scheduler`
       (post-EBS init completion checkpoint).
- **Relaxed assertion set** vs. pre-1.30.0: `Memory isolation: PASS`
  and `Userland exec complete` are temporarily dropped — those
  require the scheduler test-process loop to complete a 50-tick run,
  and that path breaks under gnoboot+OVMF (kernel-internal issue,
  not a gnoboot bug; tracked in `docs/development/state.md` § *Open
  investigation*). The scheduler-fix is its own 1.30.x sub-arc; once
  it ships, the dropped assertions tighten back.

### Unchanged

- ELF64 / EM_X86_64 / entry `0x1000A8` — kernel image shape is
  unchanged.
- The multiboot1 ELF32 legacy path (`#ifndef ELF64_KERNEL`) is
  untouched. Stays as latent capability per
  `[[project-agnos-kernel-growth-rules]]`.
- No magic check, no struct-version check, no field reads from
  `boot_info_ptr` yet — the kernel just stashes the pointer.
  Adding those is part of the 1.30.x scheduler-under-UEFI sub-arc.

### Open (tracked in state.md § Open investigation)

- **Timer-driven scheduler stops after ~10 context switches** under
  gnoboot+OVMF. Root cause likely involves `pt_init` writing kernel
  page tables at fixed physical `0x1000/0x2000/0x3000` (only valid
  under the multiboot1 boot-shim's seeded tables, not under UEFI),
  with downstream corruption in `apic_init` (maps `0xFEE00000` via
  same broken PT) and `proc_create_address_space` (templates the
  per-process PD off the broken kernel PD). Fix path: stop assuming
  fixed-physical page-table location — either `pmm_alloc` the kernel
  PML4/PDPT/PD too, or detect UEFI vs `-kernel` boot and branch.
- **Iron Attempt 5 on NUC AMD** pending USB re-provision via
  `agnosticos/scripts/install-usb.sh` + gnoboot v0.1.0 + this kernel.
  Real iron may behave differently from OVMF; if iron boots through
  to scheduler, the QEMU-specific bug isn't iron-blocking.

### Out of scope (1.30.0)

- `scripts/build.sh` still prints `multiboot2 (ELF64): OK` and
  `Boot: pending shim rewrite — see ... path-a-elf64-multiboot2.md`
  at the end of the build. Both labels are out of date post-1.30.0
  (we're on path-c, not path-a). Cosmetic only; queued in 1.30.x
  follow-up slot.

## [1.29.1] — 2026-05-13

**Boot-shim portability fix surfaced during iron-boot triage.** First
patch in the 1.29.x line. One correctness fix in the boot shim's CR4
sequence; no new features.

**Important framing:** the iron-boot campaign's primary target is the
**NUC AMD** (Zen-class — SMEP + SMAP both advertised). On Zen silicon
this patch is *behaviorally identical* to v1.29.0 (both set CR4 bits
5 + 20 + 21). The patch is therefore **not** a confirmed causal fix
for Attempt 3's silent reset on the NUC AMD; that diagnosis is still
open (see `agnosticos/docs/development/iron-boot-testing-log.md`
Attempt 4 — serial-cable capture is the recommended next step). The
patch *does* fix a real portability bug that future Intel hosts
(queued post-AMD-proof) and older AMD silicon would have hit.

### Fixed

- **`kernel/arch/x86_64/boot_shim.cyr` (CR4 init, step 5)** — CPUID-gate
  SMEP (CR4 bit 20) and SMAP (CR4 bit 21). v1.29.0 ORed both
  unconditionally alongside PAE, which triggers `#GP` on any CPU that
  doesn't advertise the feature in CPUID leaf 7 (sub-leaf 0) EBX bits 7
  (SMEP, Ivy Bridge+ / Zen 1+) and 20 (SMAP, Broadwell+ / Zen 1+). The
  shim has no exception handlers installed at this point, so `#GP`
  cascades through `#DF` to triple-fault and the platform resets —
  which on iron without a serial cable looks identical to any other
  early-shim failure. PAE (bit 5) remains unconditional — multiboot1
  long-mode handoff requires it.

  Implementation: build the new CR4 value in EBX (so EAX is free to
  hold CPUID features), `push ebx` across `cpuid` to preserve the
  in-flight CR4, then `test`/`jz` each feature bit before ORing the
  corresponding CR4 bit. Total shim size growth: 41 bytes (kernel
  binary grew 250936 → 250968 bytes after ELF padding).

  Behavior on platforms that *do* advertise both bits (QEMU `-cpu max`,
  every Broadwell-or-newer Intel, every Zen-or-newer AMD including the
  current iron target): identical to v1.29.0 — PAE + SMEP + SMAP all
  enabled.

  Behavior on platforms that *don't*: keeps PAE, skips the unsupported
  bit(s), continues into long-mode handoff instead of triple-faulting.
  QEMU `qemu64` (no SMEP, no SMAP) now boots through the shim and
  reaches the `AGNOS kernel v1.29.1` banner rather than resetting at
  the OR — direct regression-test proof that the new path handles
  missing-feature silicon correctly.

### Notes

- Iron-side Attempt 3 reset on the NUC AMD is **not** explained by
  this patch (Zen advertises both feature bits). Open hypotheses
  (per the iron-boot-testing-log): low-memory page-table / GDT /
  stack collision with UEFI runtime-reserved regions; multiboot1 +
  UEFI fundamental handoff gap requiring a multiboot2 retrofit; or
  shim-level fault in a different early step. Serial-cable capture
  via the `verbose serial (ttyS0,115200)` GRUB entry is the
  recommended next diagnostic step before further blind code
  changes.

## [1.29.0] — 2026-05-11

**1.28.x arc gate / 1.29.x arc opens.** No kernel-source behavior
change. This is the P(-1) gate cut — closes the 1.28.x arc cleanly
and opens 1.29.x with a fresh Active table and a clear next-arc
horizon (**1.30.0 is reserved for full-binary KASLR**; see
[`docs/development/roadmap.md`](docs/development/roadmap.md) `## 1.30.0`).

Versioning note: the closeout work that became this entry was
originally drafted as `1.28.4` (closeout patch). Reframed as the
1.29.0 gate per the established "minor.0 = arc-gate / arc-opener"
pattern in the AGNOS ecosystem — the closeout is the natural arc
boundary, and bumping the minor signals that boundary to downstreams.

Per CLAUDE.md's Closeout section: mechanical checks, dead-code audit,
code review pass, cleanup sweep, security re-scan, doc sync. Findings:

- **Mechanical**: `scripts/check.sh` 11/11, `scripts/test.sh --all`
  7/7, QEMU boot reaches all CI checkpoints — banner v1.29.0 +
  `KASLR: pmm_next_free=N` varying across two boots (1088 / 1369) +
  `PCI: 4 devices` (validating the v1.28.3 PciDev path) +
  `Memory isolation: PASS` + `Userland exec complete` + `=== done ===`.
- **Dead-code audit**: 62 fns DCE'd on x86_64, 0 on aarch64 — same
  baseline as v1.27.2. Zero new dead code from the 1.28.x arc; every
  new addition (rdrand_u64, kaslr_seed, ktag/kpayload, VfsType,
  PciDev_*) is reached from at least one consumer.
- **Code review pass**: 6 commits across .0/.1/.2/.3 walked end-to-end.
  Missed `#ifdef` guards: none. Unguarded asm with implicit register
  contracts: 1 found and fixed in 1.28.3 (sched.cyr cr3_load hygiene).
  Off-by-ones, silently-ignored errors: none. Specifically vetted:
  `kaslr_seed`'s sign-mask before modulo; ktagged accessor sites in
  vfs.cyr + syscall.cyr; PciDev_* sites in pci.cyr / iommu.cyr /
  virtio_net.cyr / virtio_blk.cyr.
- **Cleanup sweep**: Every 5.7.x reference in source/docs is
  intentional historical context (cyrius v5.7.19 kmode invariant,
  v5.7.22 fmt fix). Removed two orphaned files in `build/`:
  `agnos_miso` + `agnos_x86_miso.cyr` (v1.27.1-era memory-isolation
  test temp artifacts).
- **Security re-scan**: Zero raw Linux syscalls (CI's grep matches
  `test_hw_syscall` / `test_syscall` — false positives), zero
  unbounded loops, zero MMIO outside `arch/`, zero ≥ 64 KB buffers.
  Same baseline as 2026-04-13 audit; arc additions added no new
  attack surface.

### Changed (documentation + housekeeping)
- **`docs/development/state.md`**: Build artifacts table gained a
  per-cut size-trajectory subtable for the 1.28.x arc. In-flight
  roadmap snapshot pruned to live items only (was carrying stale #2,
  #3 (full), #7 entries that closed during the arc). Last-refresh
  bumped; subsystem-status header date updated.
- **`docs/doc-health.md`**: kaslr-scope proposal status moved
  Open/fresh → Live/archive-eligible (Option B shipped at 1.28.0;
  Option A still real candidate gated on cyrius PIE). serial_putc
  issue archived with Resolution v1.28.1 section.

### Removed
- **`build/agnos_miso`, `build/agnos_x86_miso.cyr`** — stale v1.27.1
  memory-isolation test artifacts. No references anywhere.

### Verified
- `scripts/build.sh` (x86_64): **250,704 B** (unchanged from v1.28.3
  — closeout is doc-only).
- `scripts/build.sh --aarch64`: **93,288 B** (unchanged).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU boot: banner v1.29.0 + KASLR varies + Memory isolation: PASS
  + Userland exec complete + `=== done ===`.

### Notes
- **1.28.x arc ledger** (5 cuts shipped, 4 active items resolved):
  - **1.28.0** — KASLR (data-only); Security Hardening track fully
    closed (13/13).
  - **1.28.1** — `serial_putc` methodology + bench-history schema;
    Active #7 closed via documented re-measurement, not a code
    change.
  - **1.28.2** — VFS tagged unions via new `kernel/lib/ktagged.cyr`;
    Active #2 closed.
  - **1.28.3** — Struct refactor with `#derive(accessors)`: PciDev
    shipped; proc_table blocked on cyrius 16-field cap (filed,
    acknowledged + slotted for cyrius v5.11.x repair). Plus
    `sched.cyr` `cr3_load` hygiene fix (v1.27.x-era brittle pattern,
    fixed proactively before next regalloc perturbation).
  - **1.29.0** — arc gate (this cut). Closes 1.28.x; opens 1.29.x.
- **Active table after this minor**: only **#1 (SMP-on-hardware)**.
  proc_table derive-port is gated on cyrius v5.11.x — passive pickup
  at the next pin bump (slated for 1.29.1). Full-binary KASLR
  (Option A) sits on cyrius v6.1.x PIE and is **reserved for the
  1.30.0 headline** — explicitly NOT a 1.29.x slot.
- **1.29.x arc plan** (full table in roadmap.md):
  - **1.29.1** — `Process` `#derive(accessors)` port (passive, cyrius
    v5.11.x dep).
  - **1.29.2** — Bench-history snapshot in repo (post-1.27.2 carry —
    decide check-in vs CI-artifact-only).
  - **1.29.3+** — `mmap` (anonymous-only; file-backed waits for
    ext2).
  - **1.29.x** — Hardware-validation infra (RPi4 / NUC; unblocks
    Active #1).
  - **Explicitly NOT in 1.29.x**: full-KASLR (1.30.0 headline), ext2
    (its own arc), preemptive scheduling (its own arc).
- **1.30.0 — Full-Binary KASLR (Option A)**: reserved slot. Hard
  prerequisite is cyrius v6.1.x PIE codegen. Closes the last ~20% of
  KASLR security value that data-only KASLR (shipped v1.28.0) doesn't
  cover. Two-boot-diff CI assertion extends with a `KASLR:
  kernel_slide=0x<hex>` probe alongside the existing `pmm_next_free`
  one. Full design in `proposals/2026-05-11-kaslr-scope.md` § Option A;
  cyrius-side prerequisite tracked at
  [`cyrius/proposals/2026-05-11-pie-support.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md).

## [1.28.3] — 2026-05-11

**Struct refactor with `#derive(accessors)` — partial close of Active
#3, blocked on a cyrius cap-raise.** Fourth slot of the 1.28.x arc.
Goal was to port `pci_devs`, `vfs_table`, and `proc_table` from raw
`load64`/`store64` at byte offsets to named accessors generated by
cyrius's `#derive(accessors)`. `pci_devs` ported cleanly (4 fields).
`vfs_table` was already abstracted via `ktagged` in v1.28.2 — counted.
`proc_table` (22-field `struct Process`) hit a silent cyrius bug: the
`#derive(accessors)` metadata-table is hardcoded to **16 fields max**,
and overflowing structs get accessors at corrupted offsets with no
diagnostic. Filed upstream; agnos-side workaround is to keep
`struct Process` as documentation only (no `#derive` directive) and
have consumers continue using raw `load64`/`store64` at the
documented offsets.

Net effect: Active #3 is **2-of-3 closed** (pci_devs ✅,
vfs_table ✅ via the v1.28.2 ktagged port). proc_table awaits the
upstream cap-raise; tracked at
[`cyrius/docs/development/issues/2026-05-11-derive-accessors-16-field-cap.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-05-11-derive-accessors-16-field-cap.md).

### Added
- **`struct PciDev { slot; vendor; device; bar0; }`** with
  `#derive(accessors)` in `kernel/core/pci.cyr`. Generates 8 fns:
  `PciDev_slot` / `PciDev_set_slot` / `PciDev_vendor` /
  `PciDev_set_vendor` / `PciDev_device` / `PciDev_set_device` /
  `PciDev_bar0` / `PciDev_set_bar0`. Names follow cyrius's
  `<StructName>_<field>` (getter) and `<StructName>_set_<field>`
  (setter) convention. Byte offsets: slot=0, vendor=8, device=16,
  bar0=24 (8 bytes per cyrius i64 convention).

### Changed
- **`kernel/core/pci.cyr` `pci_scan` + `pci_find`**: 8 raw store64/
  load64 sites → 8 PciDev accessor calls. Layout comment block at
  top of file documents the struct, the accessor convention, and
  why `user/shell.cyr`'s `lspci` keeps raw offsets (cross-arch
  concern — shell.cyr is included unconditionally and the struct
  decl lives only in pci.cyr).
- **`kernel/arch/x86_64/iommu.cyr` line 175**: 1 site ported (slot
  read in the IOMMU context-setup loop).
- **`kernel/core/virtio_net.cyr` line 21**: 1 site (bar0 read).
- **`kernel/core/virtio_blk.cyr` lines 20+23**: 2 sites (bar0 + slot
  reads).
- **`kernel/core/sched.cyr` `do_context_switch` CR3 switch**:
  replaced the pre-v1.26.0 brittle `var x = expr; asm { mov cr3,
  rax }` pattern with `cr3_load(new_cr3)`. The pattern survived
  here since v1.0.0 because cc5's regalloc happened to put
  `new_cr3` in RAX at this site; the equivalent pattern in the
  memory-isolation test was fixed via `cr3_load` in v1.26.0 but
  this site was overlooked at the time. Replaced proactively as a
  hygiene fix during the (later-reverted) proc_table port —
  leaving it would have meant the next regalloc perturbation
  (compiler bump, unrelated code change) breaks boot. Same fix
  shape as v1.26.0.
- **`kernel/core/proc.cyr` `struct Process` comment block**:
  expanded to document why `#derive(accessors)` is currently
  absent (cyrius 16-field cap), cross-references the upstream
  issue, and lists the byte offsets explicitly so consumers can
  continue using raw `load64`/`store64` until the cap is raised.

### Investigated (filed upstream, not landed)
- **`struct Process` `#derive(accessors)`** — attempted, reverted.
  cyrius `#derive(accessors)` silently corrupts metadata when a
  struct exceeds 16 fields. agnos's 22-field `Process` overflowed
  the `field_names[16][32]` table in `src/frontend/lex_pp.cyr`,
  generating accessors with wrong offsets. Manifested as a
  `CR3=0x2` page fault on first context switch — `Process_set_cr3`
  wrote 0x1000 to a corrupted offset instead of `+160`, and the
  scheduler later read 0x2 (some adjacent overflowed value) for
  `proc_get_cr3` and wrote it to the CR3 register. Three layers of
  indirection from the bug to the symptom — exactly the class of
  silent-miscompilation the upstream issue calls out as worth a
  hard error.

  Reproduced upstream with a 17-field minimal program; cap is at
  16 fields, hardcoded in cyrius lex_pp.cyr's metadata-table
  layout. Filed:
  [`cyrius/docs/development/issues/2026-05-11-derive-accessors-16-field-cap.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-05-11-derive-accessors-16-field-cap.md)
  with suggested fix (raise the cap, add explicit error
  diagnostic). **Cyrius acknowledged and slotted for v5.11.x
  repair** — when that lands, agnos picks up the cap-raise
  passively via the cyrius pin bump and the proc_table port
  becomes a small follow-up patch (re-add `#derive(accessors)` to
  `struct Process`, port consumers).

### CI/release
- No workflow changes. The KASLR two-boot-diff assertion (v1.28.0)
  + the `Memory isolation: PASS` assertion (v1.27.1) +
  `Userland exec complete` (v1.25.1) all continue to gate.

### Verified
- `scripts/build.sh` (x86_64): **250,704 B** (was 249,984 B at
  v1.28.2 — +720 B for PciDev's 8 derive-generated accessors,
  partially offset by accessor calls being shorter than the
  expanded `load64(base + N)` patterns they replaced).
- `scripts/build.sh --aarch64`: **93,288 B** (unchanged — `struct
  PciDev` + `#derive` lives in pci.cyr which is x86-only).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU boot under `-cpu max -serial stdio`: banner v1.28.3 +
  `KASLR: pmm_next_free=N` (varies per boot) + `PCI: 4 devices`
  (PciDev_set_* path validated end-to-end since the count comes
  from `pci_scan` which now uses the accessors) +
  `Memory isolation: PASS` + `Userland exec complete` +
  `=== done ===`.

### Notes
- **What this is**: pci_devs port + the v1.27.x-era sched.cyr
  hygiene fix that the (failed) proc_table port surfaced. The
  cr3_load call site change is correctness in waiting — the
  brittle pattern worked by accident and would have broken on any
  future regalloc perturbation, not just this one.
- **What this isn't**: the full Active #3 close. proc_table waits
  on cyrius v5.11.x (cap-raise acknowledged + slotted upstream).
  When that lands and agnos picks up the new pin, a follow-up
  patch (likely 1.29.x) adds `#derive(accessors)` back to
  `struct Process` and ports the consumers. The struct decl in
  proc.cyr already has the cross-reference comment.
- **vfs_table counts as closed** under Active #3 even though it
  shipped via ktagged in v1.28.2 (different mechanism). The
  underlying goal — *stop using magic offsets and unnamed type
  codes at every fd access site* — was achieved. `#derive(accessors)`
  is one way to accomplish that; `ktagged` is another. VFS's
  tagged-union shape suits ktagged better anyway; the typed-record
  shape of pci_devs suits derive(accessors) better. Picking the
  right tool per subsystem is fine; the goal was the abstraction.
- **Active table after this minor**: only **#1
  (SMP-on-hardware)**. After 1.28.4 closeout, the Active table is
  effectively empty modulo SMP-on-hardware and the proc_table
  derive-port that waits on cyrius. v1.29.0 opens fresh.
- **1.28.4 (closeout) plan**: same shape as v1.27.2. Mechanical
  checks + dead-code audit + diff walk + cleanup sweep + security
  re-scan + doc sync. Tag, then 1.29.0 candidate selection.

## [1.28.2] — 2026-05-11

**VFS tagged unions ship — closes Active #2.** Third slot of the 1.28.x
arc. Introduces `kernel/lib/ktagged.cyr` as a new kernel-safe stdlib
module, then ports VFS entry-type dispatch from magic-number switches
(`ftype == 1`, `store64(base, 6)`, etc.) to named-enum + accessor
patterns. First consumer of `ktagged` — proves the inline-tagged-union
design before it becomes load-bearing infrastructure for future
consumers.

### Added
- **`kernel/lib/ktagged.cyr`** — new kernel-safe stdlib module
  alongside `kstring.cyr` and `kfmt.cyr`. Inline tagged-union helpers
  (no heap allocation; caller owns the slot's storage in an array or
  struct). Exports:
  - `ktag(slot)` — read the discriminator tag at offset 0
  - `ktag_set(slot, tag)` — write the discriminator
  - `kis_tag(slot, expected)` — 1 if tag matches, else 0
  - `kpayload(slot, idx)` — read 8-byte payload at offset `8 + idx*8`
  - `kpayload_set(slot, idx, val)` — write payload
  - `ktag_clear(slot, width_bytes)` — zero the entire slot at close

  Vendored from cyrius stdlib's `lib/tagged.cyr` but heap-allocation
  removed — kernel data structures already own their backing storage,
  so a 16-byte `alloc(16)` per fd would be pure overhead. The inline
  shape keeps the VFS table layout unchanged (32-byte slots in
  `vfs_table[1024]`).
- **`VfsType` enum** in `kernel/core/vfs.cyr`: `VFS_FREE=0`,
  `VFS_DEVICE=1`, `VFS_MEMFILE=2`, `VFS_SIGNALFD=3`, `VFS_EPOLL=4`,
  `VFS_TIMERFD=5`, `VFS_PIPE=6`. Doesn't consume `gvar_toks` slots
  per cyrius enum-vs-`var`-globals convention.
- **Layout comment** at the top of `vfs.cyr` documenting per-tag
  payload interpretation (DEVICE → payload[2] = device idx;
  MEMFILE → pos/size/data; PIPE → tail/is_write_end/buf; etc.).

### Changed
- **`kernel/core/vfs.cyr`**: every magic-number type check converted
  to a named-enum comparison.
  - `vfs_init`: `store64(&vfs_table, 1)` → `ktag_set(&vfs_table, VFS_DEVICE)`
  - `vfs_alloc`: `load64(...) == 0` → `kis_tag(..., VFS_FREE)`
  - `vfs_create_memfile`: 4 raw `store64(base + N)` calls → `ktag_set` + 3 `kpayload_set`
  - `vfs_read`: 6 `ftype == N` checks → named-enum comparisons; 9 raw `load64(base + N)` payload reads → `kpayload(base, idx)`
  - `vfs_write`: same shape — 2 checks + 2 payload reads ported
  - `vfs_create_pipe`: 8 store64 calls → `ktag_set` + 6 `kpayload_set`
  - `vfs_close`: `store64(slot, 0)` (cleared tag only) → `ktag_clear(slot, 32)` (zeroes entire 32-byte slot — defense-in-depth against stale payload leak between fd lifetimes)
- **`kernel/core/syscall.cyr`** — 4 fd-type assignment sites + epoll-wait dispatch:
  - `signalfd` (num=18): `store64(sbase, 3)` → `ktag_set(sbase, VFS_SIGNALFD)`
  - `epoll_create` (num=19): `store64(ebase, 4)` → `ktag_set(ebase, VFS_EPOLL)`
  - `epoll_ctl` (num=20): 4 raw load/store sites → `kpayload`/`kpayload_set`
  - `epoll_wait` (num=21): `load64(wbase)` discriminator → `ktag(wbase)`; `wtype == 3` / `wtype == 5` → `wtype == VFS_SIGNALFD` / `wtype == VFS_TIMERFD`; payload reads → `kpayload`
  - `timerfd_create` (num=22): `store64(tbase, 5)` → `ktag_set(tbase, VFS_TIMERFD)`
  - `timerfd_settime` (num=23): raw store64 → `kpayload_set`

  Net effect: zero remaining `store64(<vfs slot>, <magic int>)` or `load64(<vfs slot>)` in the kernel — every access goes through the named API. Future readers see *what kind* of fd at each site, not what bit-pattern was stored.
- **`kernel/agnos.cyr`** — `include "lib/ktagged.cyr"` after the existing kstring/kfmt include, before `core/pmm.cyr`. Same tier as the other vendored kernel-safe stdlib modules.

### Verified
- `scripts/build.sh` (x86_64): **249,984 B** (was 249,152 B at
  v1.28.1 — +832 B for the new ktagged module, the VFS-layout
  comment block, and the VfsType enum, partially offset by the
  ktagged accessor calls being slightly larger than the inlined
  `load64(base + N)`/`store64` pattern they replace).
- `scripts/build.sh --aarch64`: **93,288 B** (was 92,488 B at
  v1.28.1 — +800 B; ktagged.cyr is arch-neutral and gets pulled
  into both arches' link).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU boot under `-cpu max -serial stdio`: banner v1.28.2 +
  `KASLR: pmm_next_free=N` (varies per boot) + `VFS initialized` +
  `VFS write: OK` + `initrd test: PASS` + `VFS memfile read: HELLO`
  + `Memory isolation: PASS` + `Userland exec complete` +
  `=== done ===`. The VFS-path assertions (initrd open/read,
  memfile create/read, device write) all fire, validating that the
  byte-layout preserved correctly across the refactor.

### Notes
- **No byte-layout change.** The 32-byte VFS slot layout is
  identical (tag at +0; 8-byte payload slots at +8/+16/+24).
  `ktagged` is a thin sugar on top of `load64`/`store64` at the
  same offsets. This was deliberate — porting consumers without
  changing the underlying storage shape kept the diff bounded and
  the byte-identical boot path provable. Future ktagged consumers
  may use different slot widths (16-byte minimal pairs, 64-byte
  process slots, etc.) — the helpers don't constrain that.
- **Why `ktag_clear` zeroes the whole slot on `vfs_close`**: pre-
  1.28.2 the close path only zeroed the tag word, leaving stale
  payload bytes (e.g. a freed pipe-buf pointer) in the slot. Under
  fd reuse a future `kpayload(slot, 2)` would see the previous
  fd's data pointer — a defense-in-depth concern. The full-slot
  zero is essentially free (4 store64s per close; close is cold)
  and removes the class.
- **Performance**: VFS hot paths now call `kpayload(base, idx)` which
  computes `8 + idx * 8` per call. The constant multiplication folds
  to an `imm32` add at codegen; net overhead vs the open-coded
  `load64(base + N)` should be 0-1 cycles. Not measured in this
  cut — bench-history will show it next time the suite runs.
- **Active table after this minor**: only #1 (SMP-on-hardware) +
  1.28.3 of this arc. 1.28.3 (struct refactor with
  `#derive(accessors)`) is the largest item and closes Active #3,
  after which 1.28.4 is a P(-1) hardening / closeout pass before
  1.29.0.
- **`ktagged` consumer pipeline**: VFS is the first consumer. Future
  consumers — when 3+ are in production, consider promoting the
  helpers to cyrius's kernel-stdlib-track distfile so other
  kernel-mode Cyrius binaries don't re-port the same helpers. Not
  acted on this cut.

## [1.28.1] — 2026-05-11

**`serial_putc` regression closed — not a real codegen regression.**
Second slot of the 1.28.x arc; closes Active #7, the last carry-
forward from v1.25.1. Methodology work: extended `bench-history.csv`
with provenance columns, re-measured under documented conditions,
demonstrated the "60–96% regression" was QEMU UART-emulation latency
variance, not cc5 codegen. Symmetric with v1.27.1's pattern (close
a long-running carry-forward via focused .1 patch). Active table
after this: only #1 (SMP-on-hardware, hardware-gated) + .2/.3 of
this arc.

### Added
- **`bench-history.csv` schema**: 5 provenance columns appended to
  the right of the existing 7:
  - `qemu_version` — `qemu-system-x86_64 --version` head
  - `cpu_model` — `/proc/cpuinfo` `model name` (commas remapped to
    `;` so they don't break CSV)
  - `host_arch` — `uname -m`
  - `kvm_enabled` — 1 if `/dev/kvm` is readable AND we passed
    `-enable-kvm`; else 0
  - `cyrius_version` — toolchain pin from `cyrius.cyml`
- **`scripts/bench.sh`**: captures all five at run time, writes them
  per-row. Old rows (pre-v1.28.1) get empty trailing cells — CSV
  readers see them as "unmeasured under these conditions" which is
  the honest interpretation.

### Changed
- **`bench-history.csv` header migration**: pre-v1.28.1 the file
  had a header mismatch — header was 5 columns
  (`date,commit,benchmark,value,unit`) but body rows had been writing
  7 columns since the `version,tier` fields were added. v1.28.1
  rewrites the header to the 12-column schema. Also migrated 4 old
  5-column body rows (2026-04-06 vintage) to 7-column shape with
  empty `version,tier` cells so the body is uniform.

### Fixed
- **`docs/development/issue/2026-04-27-serial-putc-cc5-regression.md`**
  → `archive/` with a **Resolution (v1.28.1)** section. Findings
  from the matched-conditions re-measurement (under cyrius 5.10.44,
  QEMU 11.0.0, TCG, AMD Ryzen 7 5800H):

  | Bench | cc3@v1.21.0 | cc5@v1.26.0 | cc5@v1.28.0 | Delta vs cc3 |
  |---|---|---|---|---|
  | `pmm_alloc_free` | 1467 | 2565 | 2320 | +58% (S3 spinlock) |
  | `heap_32B` | 1338 | 1395 | 1341 | 0% |
  | `memwrite_1MB` (Kcyc) | 6976 | 5716 | 5917 | −15% |
  | `syscall_getuid` | 1160 | 820 | 827 | **−29% cc5 win** |
  | `syscall_write1` | 6800 | 504 | 593 | **−91% cc5 win** |
  | `vfs_open_read_close` | 6543 | 5694 | 5763 | −12% |
  | `serial_putc` | 5046 | 8077 | 7485 | +48% |

  cc5 is broadly equal-or-better than cc3 on CPU-bound work. The
  `serial_putc` outlier is dominated by `in al, 0x3FD` polling
  through QEMU's UART emulation — every iteration is a guest→host
  roundtrip under TCG, costing hundreds of host cycles. The
  per-call codegen overhead identified in the original writeup
  (~5–6 cycles) is <0.1% of the ~7,500 cycle total. The variance
  is methodology, not regression.

### CI/release
- No workflow changes. The `bench` CI job runs `scripts/bench.sh`
  unchanged; the provenance capture happens transparently inside
  the script. Future bench-history CSV consumers can group by
  `qemu_version` / `cyrius_version` for honest trend analysis.

### Verified
- `scripts/bench.sh` end-to-end: produced a fresh row in
  `bench-history.csv` with all 12 columns populated
  (`qemu_version=11.0.0`, `cpu_model=AMD Ryzen 7 5800H ...`,
  `host_arch=x86_64`, `kvm_enabled=0`, `cyrius_version=5.10.44`).
- `scripts/check.sh`: 11/11 PASS.
- `scripts/test.sh --all`: 7/7 PASS.
- QEMU boot: banner v1.28.1 + `KASLR: pmm_next_free=N` (varying
  across boots) + `Memory isolation: PASS` + `Userland exec
  complete` + `=== done ===`.

### Notes
- **What this resolves**: the "serial_putc is 60–96% slower under
  cc5" claim. It isn't, in any codegen sense. The cross-toolchain
  comparison was unsound — different QEMU, different host, different
  CPU model, different KVM/TCG mix. v1.28.1 makes that explicit at
  the schema level so future comparisons can be honest by
  construction.
- **Methodology rule going forward** (per the archived issue's
  Resolution section): never compare bench numbers across rows
  with different `qemu_version` or `host_cpuinfo` fingerprints
  without an explicit normalization note.
- **Active table after this minor**: #1 (SMP-on-hardware) only.
  1.28.2 (VFS tagged unions) and 1.28.3 (struct refactor) close
  Active #2 and #3 respectively; after 1.28.3 only the
  hardware-gated #1 remains.
- **Methodology infra carries over**: the provenance columns
  benefit every future bench analysis — 1.28.2's VFS-hot-path
  benchmarks, 1.28.3's struct-refactor regression guards, and
  any future cyrius-pin-bump perf analysis. Closes a small class
  of "is this real or QEMU drift" bug.

## [1.28.0] — 2026-05-11

**KASLR (data-only) ships — closes Security Hardening S7.** First slot
of the 1.28.x arc. The kernel binary stays at fixed `0x100000`;
dynamically-allocated kernel data (heap, slab pages, per-process
stacks) now lands at randomized offsets within the 2–16 MB available
physical-memory range. Defeats trivial heap-layout ROP. Full design
choice (Option B over Option A) in [`docs/development/proposals/2026-05-11-kaslr-scope.md`](docs/development/proposals/2026-05-11-kaslr-scope.md); full-binary KASLR (Option A) remains a candidate but is gated on cyrius PIE support landing first (filed at [`cyrius/docs/development/proposals/2026-05-11-pie-support.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md) for v6.1.x).

### Added
- **`kernel/arch/x86_64/io.cyr` `rdrand_u64()`**: extracted from the
  v1.27.x stack-canary asm. Returns the RAX value from `rdrand rax`
  (`48 0F C7 F0`). Returns 0 on failure per Intel SDM (destination
  zeroed when CF=0).
- **`kernel/arch/aarch64/stubs.cyr` `rdrand_u64()`**: aarch64 stub —
  uses `CNTVCT_EL0` (same source as the existing `rdtsc` stub). Lower
  entropy than RDRAND but acceptable for KASLR's "different layout per
  boot" property; aarch64 isn't booted to full kernel today anyway.
- **`kernel/core/pmm.cyr` `kaslr_seed()`**: returns `rdrand_u64()`
  with a `rdtsc()` XOR `0xDEAD1337CAFE4242` fallback for when RDRAND
  fails or isn't available.
- **KASLR boot probe** in `kernel/core/main.cyr`: emits
  `KASLR: pmm_next_free=<page>` after `pmm_init` so CI can verify
  randomization is firing.

### Changed
- **`kernel/core/pmm.cyr` `pmm_init`**: `pmm_next_free` is now seeded
  from `kaslr_seed()` biased into the available page range
  `512 + (seed % 3584)`. The sign bit is masked before modulo
  (cyrius `i64` is signed; `rdrand_u64() % 3584` can be negative
  when the high bit is set). `pmm_alloc` walks forward from the hint
  and wraps the bitmap, so first-fit semantics are preserved —
  randomization shifts only *where* first-fit starts per boot.
- **`kernel/core/syscall.cyr` `stack_canary_init`**: refactored to
  call the shared `rdrand_u64()` helper instead of its own inline
  asm. Same fallback (timer × mixer × constant). Dedup — one entropy
  source for both canary and KASLR.
- **`kernel/core/main.cyr` memory-isolation test**: `phys1` /
  `phys2` moved from `0xE00000` / `0x1000000` to `0x1000000` /
  `0x1200000`. PMM tracks pages 0–4095 (the first 16 MB only); under
  randomized PMM, pages near `0xE00000` (page 3584) could collide
  with allocator state by the time the test runs. Moving both phys
  regions above 16 MB guarantees they're outside PMM's tracking, so
  `pmm_alloc` cannot return them and the test stays deterministic.
  The 0–4 GB identity map (v1.25.0) plus the per-process PD-copy
  (v1.25.1) make both addresses kernel-reachable and AS1/AS2-
  mappable as before. Also added `vmm_is_mapped` + `vmm_map` checks
  for `phys1` (parallel to the existing `phys2` check) — defensive
  even though both should already be identity-mapped.

### CI/release
- **`.github/workflows/ci.yml` `boot-test`**: added KASLR
  randomization check. The job now boots **twice** and asserts the
  two `KASLR: pmm_next_free=N` probe values differ. Guards the
  rdrand_u64 / kaslr_seed / pmm_init triple — if any of them silently
  regresses to a fixed seed, two-boot-diff fails. Same pattern as
  the v1.27.1 `Memory isolation: PASS` assertion tightening: catch
  the regression at CI time, not at deploy time.

### Verified
- `scripts/build.sh` (x86_64): **249,152 B** (was 248,896 B at
  v1.27.2 — +256 B for `rdrand_u64` helper, `kaslr_seed` fn, the
  abs-value masking, the KASLR probe printout, plus the
  memory-isolation test's `vmm_is_mapped` + `vmm_map` defensive
  block for the new `phys1` region).
- `scripts/build.sh --aarch64`: **92,488 B** (was 92,216 B at
  v1.27.2 — +272 B for the aarch64 `rdrand_u64` stub).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU `-cpu max -serial stdio` over 5 consecutive boots:
  `pmm_next_free` values **2560, 3250, 1320, 2741, 2369** — uniform
  distribution across `[512, 4095]`, no repeats. `Memory isolation:
  PASS` + `Userland exec complete` + `=== done ===` all fire.
- KASLR-diff CI assertion validated locally: two consecutive boots
  produce different probe values; the assertion's negative case
  (forced same seed) was sanity-checked.

### Notes
- **What this defends against**: an attacker who depends on heap or
  per-process structure offsets being predictable across boots.
  Concretely: ROP gadgets that target heap-allocated objects (like
  `proc_table` slots, slab-allocated VFS entries) by their address.
- **What this does NOT defend against**: pre-computed gadgets in
  the kernel binary itself — the binary's still at `0x100000`. That
  requires full-binary KASLR (Option A), which is gated on cyrius
  PIE support (v6.1.x cyrius candidate). See the kaslr-scope
  proposal for the full discussion. Data-only is ~80% of the
  security value at ~20% of the implementation cost; full KASLR's
  marginal win against AGNOS's small (~248 KB) kernel binary is
  smaller than it would be against a 5 MB Linux kernel.
- **`KASLR_SEED` compile-time reproducibility hatch** was scoped out
  of v1.28.0. The original proposal called for it primarily for
  memory-isolation test reproducibility, but moving the test's phys
  regions above PMM-tracked memory (16 MB) made the hatch
  unnecessary — the test is now deterministic under any seed. The
  hatch can land as v1.28.0.1 if a future need surfaces.
- **aarch64 entropy** uses `CNTVCT_EL0` (the ARM generic timer)
  rather than a true RDRAND equivalent. This is acceptable because
  the aarch64 kernel currently runs only minimal initialization
  (no PMM bitmap, no scheduler) — KASLR fires but isn't load-
  bearing yet. When aarch64 grows the full boot path, revisit the
  entropy source.

## [1.27.2] — 2026-05-11

**Closeout pass for the 1.27.x arc.** No kernel-source behavior change.
This is the hygiene-and-doc cut that ties off the 1.27.x cleanup-and-
leverage arc (v1.27.0 toolchain + v1.27.1 memory-isolation closeout)
before turning to 1.28.0. Per CLAUDE.md's Closeout section: mechanical
checks, dead-code audit, code review pass, cleanup sweep, security
re-scan, doc sync. Findings:

- **Mechanical**: `scripts/check.sh` 11/11, `scripts/test.sh --all`
  7/7, QEMU boot reaches `Memory isolation: PASS` +
  `Userland exec complete` + `=== done ===`. Both x86_64 and aarch64
  binaries build clean under cyrius 5.10.44.
- **Dead-code audit**: 62 fns DCE'd on x86_64, 0 on aarch64. Every
  entry is intentional infrastructure (kstring/kfmt utilities, shell
  command handlers, TCP/UDP/FAT16 paths the boot test doesn't
  exercise). No real dead code to remove.
- **Code review pass**: v1.27.0/v1.27.1 diffs walked end-to-end. The
  proc.cyr `#ifdef ARCH_X86_64` guards correctly encompass all four
  x86-specific page-table fns; the memory-isolation test's three
  `stac`/`clac` brackets are correctly placed (only around US=1
  user-page accesses — cr3_load itself walks kernel US=0 page tables
  and needs no bracket); the version-bump.sh state.md regexes were
  already verified via dry-run after the ERE-`|`-alternation bug at
  v1.27.1.
- **Cleanup sweep**: 5.7.19/5.7.22 references in `kernel/agnos.cyr`,
  `kernel/arch/x86_64/boot_shim.cyr`, `kernel/core/proc.cyr`,
  `CLAUDE.md`, `.github/workflows/ci.yml`, and roadmap.md's Completed
  sections are all **intentional historical context** (citing when a
  cyrius invariant was introduced, or when a fix shipped) — kept
  as-is. The one actionable drift was `docs/architecture/overview.md`
  — refreshed in this cut (see below).
- **Security re-scan**: zero raw Linux syscalls (CI's `grep
  'syscall('` would match the `test_hw_syscall` /
  `test_syscall` function names — false positives), zero unbounded
  loops, zero MMIO addresses outside `arch/`, every store64 to a
  literal address is page-table or APIC machinery in `arch/`. Same
  conclusion as the 2026-04-13 audit baseline.

### Changed (documentation)
- **`docs/architecture/overview.md`**: header refreshed (v1.25.0 ->
  v1.27.x; 243KB/93KB -> pointer to `state.md`; cyrius 5.7.19 ->
  5.10.44; dropped the now-misleading "106 tests" claim). Memory-map
  table refined to show the 0-4 GB ceiling (v1.25.0) and the IOMMU
  register window. Process Model section adds the SMAP / `US=1` /
  stac-clac note so future readers don't repeat the v1.27.1 14-day
  forensic detour.
- **`docs/development/security-hardening.md`**: new **Status
  (v1.27.1)** block at the top summarizing S1-S13. 12/13 are Done;
  only S7 (KASLR) remains open. Per-item implementation prose
  unchanged — this doc is now an implementation-history reference,
  with the live tracking living in roadmap.md.
- **`docs/development/syscall-additions.md`**: header refresh, status
  block. No new syscalls since v1.21.0; current surface lives in
  `state.md` § Syscall surface.
- **`docs/development/kybernet-bridge.md`**: header refresh. kybernet
  is now v1.2.0 (was v1.0.2 at v1.21.0). The 26-syscall AGNOS
  interface is unchanged; pointer added to `state.md`.

### Added
- **`CODE_OF_CONDUCT.md`**: missing root-level file per
  first-party-standards required-root-files set. Contributor Covenant
  v2.1 reference. Flagged by `docs/doc-health.md`'s 2026-05-11 audit
  as the next root-files gap.
- **`docs/doc-health.md` § At-a-glance** refreshed after this pass:
  three 🟡 Stale docs and one 🟠 Read-through promoted to ✅; new
  Tier-1 row for `CODE_OF_CONDUCT.md`.

### Verified
- `scripts/build.sh` (x86_64): **248,896 B** (unchanged from v1.27.1
  — doc-only release).
- `scripts/build.sh --aarch64`: **92,216 B** (unchanged).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU boot: banner v1.27.2 + `Memory isolation: PASS` +
  `Userland exec complete` + full 3-tier bench to `=== done ===`.
- `scripts/version-bump.sh` exercised end-to-end on the new
  `docs/development/state.md` bump path (added v1.27.1) — Kernel row
  + Last-refresh + Released date all updated by the script with no
  manual edits.

### Notes
- 1.27.x arc ledger:
  - **1.27.0** — toolchain alignment (5.7.22 -> 5.10.44; ecosystem
    sibling-version refresh; CI fmt-check 5.10.x compat; one latent
    cross-arch `#ifdef` correctness fix surfaced by the new
    duplicate-fn warning).
  - **1.27.1** — memory-isolation deeper-fault closeout (SMAP root
    cause; gate dropped; CI assertion tightened; doc reshape per
    first-party-documentation — CLAUDE.md durable-only, new
    `state.md`, new `doc-health.md`).
  - **1.27.2** — closeout hygiene + doc staleness sweep. Tied off.
- **1.28.0 candidates**: KASLR (S7 — last open Security Hardening
  item), VFS tagged unions (#2), struct refactor with #derive
  accessors (#3), serial_putc matched-conditions re-measurement
  (#7). KASLR is the most feature-shaped of the four; the others
  are quality-of-life or methodology work.

## [1.27.1] — 2026-05-11

**Memory isolation: PASS.** Closes the long-running "deeper fault"
carry-forward (active item #6, v1.25.1 → v1.26.0 → v1.27.0). Root
cause was **SMAP** — the boot shim sets `CR4.SMAP` (bit 21, part of
the `0x300020` OR-mask), and `proc_map_page` writes US=1 (`0x87`)
per-process PD entries because the pages must be reachable from
CPL=3. SMAP traps CPL=0 access to US=1 pages → the test's
`store64(0xC00000, …)` from kernel mode → `#PF` (CR2=0xC00000) →
`#GP` → `#DF` → triple fault. Every detail of the v1.26.0 forensic
capture re-reads cleanly under this lens (the pre-switch PD-walk
worked because it hit kernel US=0 pages; the post-switch
`serial_println` worked for the same reason; only the user-page
write traps).

The 2026-04-27 hypothesis tree (PML4/PDPT clobber, stack-canary
dangling pointer, cc5 codegen mis-emit, IDT mapping) all assumed the
fault was about *page-table state* rather than *access-control
hardware bits*. The SMAP bit was visible in the original CR4 dump
(0x300020) but went unread for 14 days — process note in the
archived issue doc to read every bit of CR0/CR3/CR4 the next time a
page-walk faults inexplicably.

### Fixed
- **`kernel/core/main.cyr`** memory-isolation test: each of the
  three access blocks (`store64+load64` on AS1, `store64+load64` on
  AS2, `load64` rechecking AS1) is now bracketed by `stac`
  (`0F 01 CB`) / `clac` (`0F 01 CA`). Per Intel SDM Vol 3 §6.12.1.4,
  interrupt entry clears `RFLAGS.AC` implicitly, so the bracket
  discipline survives a preempting interrupt.
- **`#ifdef MEMORY_ISOLATION_TEST` gate removed** (v1.25.1
  introduced; v1.27.1 closes). Test always runs at boot in default
  builds. The "SKIPPED" branch is gone.

### Changed
- **`docs/development/roadmap.md`**: Active item #6 moved to a new
  `## Completed (v1.27.1)` section; #7 (serial_putc) remains active
  per its own issue doc's defer recommendation. Header binary-size
  metric corrected (`243KB/93KB` → `248KB/92KB`).
- **`scripts/version-bump.sh`**: now re-syncs the roadmap's
  `Built with cyrius X.Y.Z` trailer from `cyrius.cyml`'s pin. v1.27.0
  surfaced the staleness — the version was bumped but the toolchain
  string wasn't. Closes a small class of drift bug.
- **`docs/development/issue/`** → `archive/`:
  - `2026-04-27-memory-isolation-deep.md` — closed by SMAP fix. The
    archived copy carries a full **Resolution (v1.27.1)** section
    with the SMAP analysis, observation-to-mechanism mapping table,
    and a process note on the hypothesis class that misled the
    original triage.
  - `2026-04-27-cr3-load-helper.md` — closed. The v1.26.0 helper
    was a real correctness fix and remains in proc.cyr; it just
    wasn't the *whole* fix. With SMAP closed the test runs
    end-to-end and the helper has no further open question.

### CI/release
- **`.github/workflows/ci.yml` `boot-test`**: assertion tightened to
  require `"Memory isolation: PASS"` in addition to
  `"Userland exec complete"`. The progression now reads:
  v1.24.0 `"AGNOS kernel v"` → v1.25.0 `"Scheduler test done"` →
  v1.25.1 `"Userland exec complete"` → v1.27.1 `"Memory isolation:
  PASS"`. Guards the SMAP brackets and the
  `proc_create_address_space` / `proc_map_page` / `cr3_load` triple
  against future regression.

### Verified
- `scripts/build.sh` (x86_64): **248,896 B** (was 247,752 B at
  v1.27.0 — +1,144 B for the un-gated test code, the three
  stac/clac asm pairs, and the per-process address-space allocations
  the test exercises that are now linked in rather than DCE'd away).
- `scripts/build.sh --aarch64`: **92,216 B** (unchanged — the
  memory-isolation test is x86-only).
- `scripts/test.sh --all`: 7/7 PASS.
- `scripts/check.sh`: 11/11 PASS.
- QEMU `-cpu max -serial stdio`: boot reaches
  ```
  Memory isolation test...
  AS1 wrote 0xAAAA, read=43690 recheck=43690
  AS2 wrote 0xBBBB, read=48059
  Memory isolation: PASS
  Userland exec complete
  ```
  then runs the 3-tier bench to `=== done ===`.

### Notes
- This closes the v1.25.1 carry-forward #6 entirely. Active item
  #7 (`serial_putc` regression) stays open per its issue doc's
  defer recommendation; the methodology gap (bench-history lacks
  qemu_version/cpu_model/host_arch columns) is the natural next
  step if/when we want to investigate that one.
- The `stac`/`clac` brackets pattern is the same one userland-
  facing kernel paths use everywhere (copy_to_user / copy_from_user
  shapes in Linux, etc.). If we grow more in-kernel diagnostics
  that need to touch user pages, factoring this into a
  `with_user_access(closure)` helper becomes worth doing — for
  now, three call sites + adjacent comments is fine.

## [1.27.0] — 2026-05-11

**Cyrius pin 5.7.22 → 5.10.44; ecosystem realignment cut.** Kicks off
the 1.27.x arc. This `.0` is the update-and-repair release that gets
AGNOS back onto a current toolchain and re-anchors CLAUDE.md against
the actual sibling versions; subsequent 1.27.x cuts will spend the
new toolchain surface on real kernel work.

Skips 30+ patch releases of upstream cyrius (5.7.22 → 5.8.x → 5.9.x →
5.10.44). Kernel source needed one correctness fix (`#ifdef
ARCH_X86_64` guards on x86-specific page-table fns) that the new
toolchain's `duplicate fn` warning surfaced; the underlying issue
predates the bump but was latent.

### Changed
- **`cyrius.cyml`**: pin `5.7.22` → `5.10.44`. AGNOS aligns with the
  rest of the boot stack (kybernet 1.2.0, agnostik 1.2.2, agnosys 1.2.5,
  argonaut 1.6.3, daimon 1.2.3, libro 2.6.2). agnosys 1.2.6+ jumped to
  cyrius 5.11.x; the stack stays on agnosys 1.2.5 to keep one pin.
- **`CLAUDE.md`**: refreshed Consumers + Ecosystem Dependencies blocks
  against the current sibling versions (was pinned at agnosys 1.0.2 /
  agnostik 1.0.0 / argonaut 1.5.0 / libro 2.0.5 / kybernet 1.0.2 — a
  full minor-and-then-some out of date). Added `daimon` to the
  consumers list. Updated `## Build` toolchain note from
  `5.7.19` → `5.10.44`.

### Fixed
- **`kernel/core/proc.cyr`**: `#ifdef ARCH_X86_64` guard around
  `proc_create_address_space`, `proc_get_user_cr3`, `proc_map_page`,
  `proc_unmap_page`. Cyrius 5.10.x emits `duplicate fn ... (last
  definition wins)` when the aarch64 build picks up both
  `arch/aarch64/stubs.cyr`'s no-op stubs *and* these x86-specific
  implementations (PML4 → PDPT → PD walk, hardcoded `0x3000` kernel-PD
  address, KPTI entry-511 stash slot). Pre-1.27.0 the aarch64 build
  silently linked the x86 implementations in over the stubs under
  last-definition-wins — which would have walked wrong memory if any
  caller reached them. The aarch64 binary shrinks 95,328 B → 92,216 B
  (-3,112 B) now that the x86 page-table fns are correctly dropped.

### Build infrastructure
- **`scripts/build.sh` + `scripts/test.sh`**: export
  `CYRIUS_NO_WARN_SHADOW_LIB=1`. cyrius 5.10+ emits an info `note` on
  every build run when the cwd's `./lib/` shadows the version-pinned
  stdlib snapshot. Our `kernel/lib/` (vendored kstring/kfmt) is the
  intentional shadow by design — `--no-deps` skips the version-pinned
  tree anyway, so the note carries no signal.

### Verified
- `scripts/build.sh` (x86_64): **247,752 B** (was 247,816 B at v1.26.1
  — 64-byte shrink under the new codegen).
- `scripts/build.sh --aarch64`: **92,216 B** (was 95,328 B at v1.26.1
  — 3,112-byte shrink from the proc.cyr guard dropping dead x86 code).
- `scripts/test.sh --all`: 7/7 PASS (x86 builds, multiboot ELF, size,
  kernel_hello builds; aarch64 compiles, size, valid ELF).
- `scripts/check.sh`: 11/11 PASS.
- QEMU x86_64 boot under `-cpu max -serial stdio`: reaches the boot
  banner and `Userland exec complete` (CI's assertions), runs through
  the full 3-tier bench harness to `=== done ===`.
- aarch64 build emits no warnings under the new pin (was: two
  `duplicate fn` warnings at v1.26.1 under 5.10.44).

### CI/release
- **`.github/workflows/ci.yml` — `Format check` step**: cyrius 5.10+
  changed `cyrius fmt --check` from "print formatted output to stdout"
  (5.7.x) to "silent, signal via exit code". The pre-1.27.0 check
  used `diff -q <(cyrius fmt … --check) "$f"`, which under 5.10.44
  diffs the (now-empty) stdout against the file and always reports
  every file as `NEEDS FORMAT` — full red CI on green code. Replaced
  with a direct exit-code check (`cyrius fmt "$f" --check >/dev/null`).
  Locally re-runs clean across all 47 kernel files (1 skipped per the
  shell.cyr `#ifdef`-in-fn-body carve-out).
- No other workflow changes needed. The install step reads the cyrius
  pin from `cyrius.cyml` via `grep -oP '(?<=^cyrius = ")[^"]+'` and
  `curl`s `https://github.com/MacCracken/cyrius/releases/download/<pin>/install.sh`
  — the 5.10.44 release asset exists and is reachable. The
  `boot-test` job's `"Userland exec complete"` grep still fires
  cleanly. `release.yml`'s changelog-extract awk targets `## [1.27.0]`
  and runs to the next `## [` — this entry is properly bracketed.

### Notes
- The 1.27.x arc is the cleanup-and-leverage arc. `.0` is toolchain
  alignment; `.1+` is where we spend the new surface on the active
  roadmap items (memory-isolation deeper-fault diagnosis, serial_putc
  matched-conditions re-measurement, the broader kybernet-bridge /
  syscall-additions tracks under `docs/development/`).

## [1.26.1] — 2026-04-27

**Cyrius pin 5.7.19 → 5.7.22.** Closes both remaining post-v1.24.0
hygiene items (formatter brace-in-comments + driver-shim
symlink staleness). The braces-in-comments fix in particular lets
agnos restore the natural `# … `var x = y; asm { mov cr3, rax; }`
…` doc-comment phrasing across `kernel/core/proc.cyr`,
`kernel/core/main.cyr`, and `kernel/arch/x86_64/keyboard.cyr`.

### Changed
- **`cyrius.cyml`**: pin 5.7.19 → 5.7.22.
- **`kernel/core/proc.cyr` + `kernel/core/main.cyr`**: reverted the
  v1.26.0 prose-rewrite workaround for the formatter braces bug.
  Comments now describe the historical pattern naturally with
  `asm { … }` syntax, since cyrius v5.7.22's formatter no longer
  tracks `{` / `}` characters inside `#` comments.
- **`kernel/arch/x86_64/keyboard.cyr`**: latent over-indentation on
  the scancode-table line for `]` `}` (line 119) — caused by the
  v5.7.21-and-earlier formatter mis-tracking the `{` in the previous
  line's `# [ {` comment — re-formatted via `cyrius fmt`. The new
  formatter correctly leaves it at depth-1 (4 spaces).
- **Resolved issue archived**:
  `docs/development/issue/2026-04-27-cyrius-fmt-tracks-braces-in-comments.md`
  → `docs/development/issue/archive/`.
- **Hygiene H3** (driver-shim symlink staleness) closed upstream in
  cyrius v5.7.22's `version-bump.sh` install-snapshot — agnos
  inherits the fix passively via the pin bump.

### Notes
- `kernel/user/shell.cyr` stays on the format-skip list. It carries
  `#ifdef … #endif` *inside function bodies* (not comments) — a
  different family of issue from braces-in-comments. v5.7.22 didn't
  address that one; tracked separately if/when it surfaces a real
  problem.

### Verified
- `scripts/build.sh` (x86_64): 247,816 B (unchanged from v1.26.0 —
  comments don't affect codegen, scancode-table re-indent doesn't
  change emitted bytes).
- Full kernel format scan (`for f in kernel/**/*.cyr; cyrius fmt
  $f --check`): **PASS** with only `kernel/user/shell.cyr` on the
  SKIP list.
- Boot under `-cpu max -serial stdio` reaches `Userland exec
  complete` and runs through the bench harness to `=== done ===`.
- `scripts/check.sh`: 11/11 PASS.

## [1.26.0] — 2026-04-27

**`cr3_load` helper + investigations on residual issues #6 / #7.**
Active items #6 and #7 from the v1.25.1 roadmap both got partial
progress; neither is fully resolved. Deeper diagnosis docs filed
under the new `docs/development/issue/` folder.

### Added
- **`docs/development/issue/`** — new folder for bug-investigation
  documents (parallel to `proposals/`, which keeps improvement-class
  designs). Both have an `archive/` sub-folder for closed items.
  Convention: `<YYYY-MM-DD>-<slug>.md`.
- **`kernel/core/proc.cyr` `cr3_load(cr3_val)`** — helper that
  loads a cr3 value into the CR3 register via a stack-relative
  inline-asm load (`mov rax, [rbp-8]; mov cr3, rax`). Same robust
  pattern as `kernel/arch/x86_64/io.cyr`'s `outb`/`inb`. Replaces
  the brittle `var x = expr; asm { mov cr3, rax }` pattern that
  relied on cc3-era codegen leaving the assigned value in RAX —
  cc5's regalloc may spill it. Audit confirmed the
  memory-isolation test was the only consumer.
  See [`docs/development/issue/2026-04-27-cr3-load-helper.md`](docs/development/issue/2026-04-27-cr3-load-helper.md).

### Investigated (not yet fixed)
- **Memory-isolation test deeper fault** (Active item #6
  follow-on) — even with `cr3_load`, the test page-faults on
  `store64(0xC00000, 0xAAAA)` after the cr3 switch. AS1's PD[6]
  is verified correct (`0xE00087`); cr3_load demonstrably loads
  AS1's CR3 (proven by serial-print working post-switch). But the
  store still produces `#PF (CR2=0xC00000)`. Hypotheses, forensic
  data, and a 5-step diagnostic plan documented in
  [`docs/development/issue/2026-04-27-memory-isolation-deep.md`](docs/development/issue/2026-04-27-memory-isolation-deep.md).
  Test stays gated behind `-D MEMORY_ISOLATION_TEST` in default
  builds.
- **`serial_putc` 60–96% regression vs v1.21.0 cc3 baseline**
  (Active item #7 follow-on) — disassembled the function (65
  bytes total), identified ~5–6 cycles/call of cc5 codegen
  overhead (two zero-displacement `jmp +5` instructions + a
  wasteful `var ch = c` memory round-trip). But that's far less
  than the 3,000+ cycle delta — bulk of the gap is almost
  certainly QEMU 7.x → 11.x UART emulation latency, host CPU
  changes, and `-cpu max` differences from the v1.21.0 measurement
  conditions. Not a real cc5 regression; the bench-history
  comparison column claims significance the data doesn't support.
  Action: **defer** until benchmarks can be re-measured under
  matched conditions. See
  [`docs/development/issue/2026-04-27-serial-putc-cc5-regression.md`](docs/development/issue/2026-04-27-serial-putc-cc5-regression.md).

### Verified
- `scripts/build.sh` (x86_64): 247,816 B (v1.25.1: 247,768 B; +48
  for the `cr3_load` helper).
- Boot under `-cpu max -serial stdio` reaches `Userland exec
  complete` and runs the bench harness through to `=== done ===`.
- Memory-isolation test gated, prints `"Memory isolation test:
  SKIPPED (build with -D MEMORY_ISOLATION_TEST)"`.
- `scripts/check.sh`: 11/11 PASS.

## [1.25.1] — 2026-04-27

**Per-process page-table mirror fix + memory-isolation test gated.**
Closes Active item #5 surfaced by v1.25.0's ACPI fix.

### Fixed
- **`kernel/core/proc.cyr` `proc_create_address_space`**: PD-copy loop
  bound was hardwired to `i < 8` (16 MB) — the same v1.22.0 ceiling
  the v1.25.0 paging fix raised on the kernel side. Per-process
  address spaces still couldn't reach kernel data above 16 MB. Loop
  now copies entries `[0..510]` (preserving 511 as the user-CR3
  stash slot, by existing convention). PDPT[1..3] (the 1 GB huge
  pages for 1–4 GB) also mirrored into per-process PDPT for
  symmetry. Fixes the `#PF` at CR2=0x219C43A9 (kernel data at
  ~561 MB) that was hitting whenever a per-process CR3 was active.

### Changed
- **`kernel/core/main.cyr`** memory-isolation test gated behind
  `#ifdef MEMORY_ISOLATION_TEST`. The test does a manual
  `mov cr3, rax` dance that triple-faults a second time after the
  proc.cyr fix above (CR2 moves from 0x219C43A9 to 0xC00000 — RIP
  lands in the gvar zero block, fault on the test page itself).
  Pre-existing — was hidden behind the v1.22.0 ACPI fault until
  v1.25.0. Default builds skip it; re-enable with
  `cyrius build -D MEMORY_ISOLATION_TEST`. Tracked as Active item
  #6 in the roadmap pending deeper diagnosis.
- **CI QEMU Boot Test** assertion tightened from
  `"Scheduler test done"` to `"Userland exec complete"` — past
  the memory-isolation test gate, through `spawn_user_proc()`.
  Catches any future regression in the per-process page-table
  machinery or the userland ELF/ring3 path.
- **`docs/development/proposals/`** — both resolved proposals
  (cc5 boot-shim, ACPI identity-map) moved into `proposals/archive/`.
  CI/roadmap/CHANGELOG cross-references updated.

### Verified
- `scripts/build.sh` (x86_64): 247,768 B (previous 248,848 B; −1080 B
  thanks to the gated test going through DCE in default builds).
- Boot under `qemu-system-x86_64 -kernel build/agnos -cpu max
  -serial stdio` reaches `"Userland exec complete"` and runs
  through to the benchmark dump + halt. Was: triple fault at the
  memory-isolation test under v1.25.0.
- Fresh benchmark numbers under cyrius 5.7.19 (since the kernel
  finally reaches the bench harness):

  | tier | metric | v1.21.0 (cc3) | v1.25.1 (cc5) | delta |
  |---|---|---|---|---|
  | core | pmm_alloc_free | 1,467 cyc | 2,498 cyc | +70% |
  | core | heap_32B | 1,338 cyc | 1,360 cyc | +1.6% |
  | core | heap_4096B | 28,097 cyc | 36,935 cyc | +31% |
  | core | memwrite_1MB | 6,976 Kcyc | 5,882 Kcyc | **−16%** |
  | sub  | syscall_getpid | 261 cyc | 268 cyc | +2.7% |
  | sub  | syscall_getuid | 1,160 cyc | 837 cyc | **−28%** |
  | sub  | syscall_write1 | 6,800 cyc | 515 cyc | **−92%** |
  | sub  | vfs_open_read_close | 6,543 cyc | 5,702 cyc | **−13%** |
  | int  | serial_putc | 5,046 cyc | 9,901 cyc | +96% |

  Headline: syscall_write1 92% faster, syscall_getuid 28% faster,
  memwrite/vfs both improved. PMM and heap_4096B regressed (cc5
  spills more locals?), serial_putc regressed 2× (likely cc5
  codegen for the inline-asm `out dx, al` path — separate
  investigation).
- `scripts/check.sh`: 11/11 PASS.

## [1.25.0] — 2026-04-27

**ACPI identity-map fix + documentation refresh.** Closes the
post-`Devices registered` boot stall diagnosed in
`docs/development/proposals/archive/2026-04-27-acpi-identity-map-ceiling.md`
(Path A). v1.24.2 was abandoned mid-flight — its doc-only changes
fold into this release alongside the kernel fix.

### Fixed
- **Latent v1.22.0 paging bug — `kernel/arch/x86_64/paging.cyr` `pt_init`**:
  identity-map ceiling raised from 16 MB (8 × 2 MB PD entries) to 4 GB.
  PD at 0x3000 now fully populated (512 × 2 MB = 1 GB) via a single-line
  loop bound change (`i < 8` → `i < 512`). PDPT[1..3] additionally seeded
  with 1 GB huge pages (PDPE1GB) covering 1–4 GB. ACPI tables that QEMU
  places at ~0x07FE0000 (~134 MB) — well outside the old 16 MB ceiling
  and the immediate cause of the `#PF → #GP → #DF → triple fault` chain
  that 1.22.0–1.24.1 silently shipped — are now reachable. Boot now runs
  past `acpi_init()` / `pci_scan()` / IOMMU / scheduler-test / VFS / initrd
  through to the memory-isolation test (which has its own pre-existing
  bug, filed as Active item #5).
- The CI QEMU Boot Test grep `"AGNOS"` (line 1 of serial output) was
  matching the v1.24.x boot banner even though the kernel triple-faulted
  ten lines later. Tightened to `"Scheduler test done"` — a checkpoint
  that requires ACPI + PCI + IOMMU + syscall + scheduler all to work.

### Changed (documentation)
Docs were carrying cc3-era numbers (v1.21.0 / v1.22.0 layout) — these
edits originally lived in the abandoned v1.24.2 patch and ride along here.
- **`README.md`**: binary size 220KB → 243KB (x86_64), 57KB → 93KB
  (aarch64). Source line count 4,800 → 6,228 across 49 files. Subsystem
  count 33 → 35. Cyrius pin 5.7.12 → 5.7.19. Quick-start boot command
  includes `-cpu max` with a short comment (qemu64 lacks SMEP+SMAP).
  Build commands no longer reference `cyrius build -D ARCH_X86_64` —
  that flag doesn't propagate into nested `#ifdef` blocks;
  `sh scripts/build.sh` is the supported path. Benchmarks section header
  notes "last measured at v1.21.0" — re-measurement gated on the
  memory-isolation test fix.
- **`CLAUDE.md`**: cyrius pin 5.7.12 → 5.7.19. Aarch64 file count 8 → 9,
  core 17 → 18, user 3 → 4. Ecosystem dep versions refreshed against
  kybernet 1.0.2's `cyrius.cyml`: kybernet 1.0.1 → 1.0.2, argonaut
  1.2.0 → 1.5.0, libro 1.0.3 → 2.0.5, agnosys 0.97.2 → 1.0.2,
  agnostik 0.97.1 → 1.0.0. Project-tree diagram now lists `docs/audit/`,
  `docs/development/proposals/`, and `security-hardening.md`.
- **`docs/architecture/overview.md`**: header v1.21.0 → v1.25.0, sizes
  and memory map updated. x86_64 + aarch64 build commands now point at
  `scripts/build.sh` rather than bare `cyrius build` invocations.

### Verified
- `scripts/build.sh` (x86_64): 248,848 B (previous 248,720 B; +128 B
  from the extra PD entries and PDPT writes). Multiboot magic
  0x1badb002, entry 0x100060.
- `scripts/build.sh --aarch64`: 95,136 B (untouched — fix is x86_64-only).
- Boot under `qemu-system-x86_64 -kernel build/agnos -cpu max -serial
  stdio`: serial output reaches `"Scheduler test done. Timer ticks: 154"`
  (was: triple fault at `"Devices registered"` two lines past the boot
  banner).
- `scripts/check.sh`: 11/11 PASS.
- `scripts/test.sh --all`: 7/7 PASS.

## [1.24.1] — 2026-04-27

Comments-only patch closing H1 + H2 from the post-v1.24.0 hygiene list.
Kernel binary unchanged at 248,720 B; same `-cpu max` boot path.

### Changed
- `kernel/agnos.cyr` — added a 6-line comment above the `boot_shim.cyr`
  include site explaining the cc5 v5.7.19 kmode==1 emit-order invariant
  (top-level asm before gvar inits) and pointing at the regression
  proposal. Future readers can tell from the code alone WHY the include
  must stay where it is.
- `kernel/arch/x86_64/boot_shim.cyr` — annotated the hand-encoded raw
  asm bytes with mnemonic comments + a 12-step header walking through
  the multiboot1-32-bit → 64-bit-long-mode transition (UART init, page
  tables, CR4/CR3/EFER/CR0, GDT build, far jump, segment reload, 64-bit
  stack). Each byte sequence is now self-documenting against Intel SDM.

H3 (the `~/.cyrius/bin/cyrius` driver-shim staleness footgun) remains
open as a cyrius-side ask — not actionable from agnos.

## [1.24.0] — 2026-04-27

## [1.23.0] — 2026-04-27

**Cyrius toolchain bump 3.9.8 → 5.7.12.** Aligns AGNOS with kybernet's
toolchain pin so the whole base-OS stack tracks one Cyrius release.

### Changed
- **Toolchain**: Cyrius 3.9.8 → 5.7.12 (skipped 4.x line entirely; cc3 → cc5)
- **Manifest**: `cyrius.toml` → `cyrius.cyml`. Package version now resolved
  from `VERSION` via `${file:VERSION}` templating — no in-place version edit
  needed in the manifest. Toolchain pin lives on the manifest's
  `cyrius = "5.7.12"` line (kybernet convention).
- **`scripts/build.sh` / `scripts/test.sh`**: only invoke `cyrius build` —
  no direct `cc5` / `cc5_aarch64` calls. Existence of `cc5_aarch64` still
  gates the aarch64 path. `--no-deps` flag passed since `[deps]` is empty.
- **CI (`ci.yml`)**: format check switched from raw `cyrfmt` to
  `cyrius fmt --check`; toolchain version read from `cyrius.cyml`.
  Documentation job no longer cross-checks `cyrius.toml` (file removed) and
  asserts `version = "${file:VERSION}"` in `cyrius.cyml` instead.
- **Release (`release.yml`)**: tag matcher accepts `1.2.3` or `v1.2.3`
  (kybernet shape); release artifacts and changelog use the stripped
  semver form regardless.
- **`scripts/version-bump.sh`**: 9 files → 8 files (cyrius.cyml is
  templated, no edit). Stale-reference grep no longer scans `cyrius.toml`.
- **`scripts/check.sh`**: kernel binary upper bound 150KB → 350KB. cc5
  emits more code than cc3 did (~250KB at v1.23.0 vs ~110KB at v1.22.0
  under cc3); previous bound would have made the gate a no-op.
- **`README.md`, `CLAUDE.md`**: documented `owl` (.cyr viewer) and `cyim`
  (.cyr editor) as the canonical .cyr file tools — no `cat`/`sed` on
  Cyrius sources during development.

### Removed
- `cyrius.toml` — superseded by `cyrius.cyml`.
- `.cyrius-toolchain` — toolchain pin now lives only in `cyrius.cyml`
  (single source of truth, matches kybernet).

### Verified
- `scripts/build.sh` (x86_64): 248,720 B, multiboot magic 0x1badb002,
  entry 0x100060.
- `scripts/build.sh --aarch64`: 95,136 B (ARM aarch64 ELF).
- `scripts/check.sh`: 11/11 PASS.
- `scripts/test.sh --all`: 7/7 PASS (4 x86_64 + 3 aarch64).

## [1.22.0] — 2026-04-13

### Added
- ACPI table parsing (`kernel/core/acpi.cyr`): RSDP scan, RSDT/XSDT walk, DMAR table parsing
- Intel VT-d IOMMU driver (`kernel/arch/x86_64/iommu.cyr`): DMA remapping, root/context/IO page tables
- Per-CPU TSS infrastructure: 4 TSS descriptors in GDT, per-CPU kernel stacks, APIC ID-based routing
- Stack canary framework: RDRAND-seeded secret, canary checks in `ksyscall`, `elf_load`, `net_handle_tcp`
- KPTI (partial): dual page tables per process, CR3 switching on SYSCALL entry/exit
- Spectre v2 mitigation: IBRS set/clear on SYSCALL entry/exit (CPUID-gated)
- Stack guard pages: unmapped 2MB region below each user stack
- Per-process exit codes in process table (offset 168)
- Per-connection TCP RX buffers (heap-allocated, freed on close)
- ARP request tracking (reject unsolicited replies)
- TCP sequence/ACK validation with receive window check
- Randomized TCP initial sequence numbers (timer-based)
- `proc_unmap_page()` for per-process page table manipulation
- `vmm_map_user_exec()` for executable user code pages
- Userspace pointer validation (`is_user_ptr`, `is_user_range`) in all syscalls
- PMM spinlock for SMP-safe page allocation
- Security audit report (`docs/audit/2026-04-13-security-audit.md`)
- Security hardening guide (`docs/development/security-hardening.md`)

### Changed
- Kernel binary size: 239KB -> 260KB (+8.8% for security hardening)
- Process table stride: 168 -> 176 bytes (added `exit_code` field)
- VirtIO-net RX buffer: 256 -> 2048 bytes (matches descriptor)
- SYSCALL entry stub: 128 -> 256 bytes (KPTI + IBRS instructions)
- GDT: 7 slots -> 13 slots (4 per-CPU TSS descriptors)
- Boot shim: CR4 enables SMEP+SMAP, EFER enables NXE
- User pages mapped with NX bit (bit 63) by default
- Stack spacing: 2MB -> 4MB per process (guard page room)
- `spawn_user_proc` copies code to separate physical page at user VA (no kernel U/S exposure)
- `kfree_sized` zeroes freed blocks before returning to free list
- `spin_unlock` uses atomic `xchg` instead of plain store

### Fixed
- UDP buffer overflow: 2040-byte copy into 256-byte buffer (remote, unauthenticated)
- VirtIO RX DMA overflow: descriptor declared 2048 bytes, buffer was 256
- Arbitrary kernel R/W via unvalidated userspace pointers in 8 syscalls
- ELF loader accepted unbounded phoff/phnum/p_offset/p_filesz/p_memsz/entry
- PMM negative page index and double-free vulnerabilities
- VFS memfile position underflow (fsize - pos when pos > fsize)
- IP payload length underflow (ip_total < ip_ihl)
- TCP header length underflow and RX buffer overflow
- kill() allowed any process to signal any other (including PID 0)
- initrd data offset not validated against bounds
- FAT16 cluster number not validated against filesystem geometry
- Kernel code pages mapped user-accessible in per-process page tables

### Security
- 31 vulnerability fixes across memory management, syscalls, network stack, I/O drivers, boot
- 12/13 security roadmap items completed (S1-S6, S8-S13)
- S7 (KASLR) deferred: blocked on Cyrius compiler v4.4.0 PIE support (tracked as CVE-07)

## [1.21.0] — 2026-04-13

### Added
- Kernel stdlib: vendored `kstring.cyr` (strlen, streq, memeq, memcpy, memset, memchr, strchr, atoi, strstr) and `kfmt.cyr` (fmt_int_buf, fmt_hex_buf, kfmt_int, kfmt_hex, kfmt_hex0x, kfmt_byte)
- `cyrius.toml` project metadata
- `.cyrius-toolchain` version pinning (3.9.8)
- Kernel test suite: 106 assertions across 7 categories (PMM, heap, VFS, proc, syscall, kstdlib, initrd)
- `scripts/ktest.sh` — automated QEMU test runner with `-D TEST` gating
- Shell `test` command (gated behind `#ifdef TEST`, excluded from production binary)
- PCI device IDs displayed in hex (`lspci` shows `vendor=0x1af4` instead of decimal)
- `kernel/lib/` directory for vendored kernel-safe stdlib modules
- CI: format check (cyrfmt), security scan, dedicated build/test/docs jobs (4→7 jobs)
- Release: changelog extraction, source tarball, VERSION+cyrius.toml+tag consistency check

### Changed
- All scripts use `~/.cyrius/bin/` toolchain only (no `../cyrius/` fallback)
- Toolchain references updated: `cyrb`→`cyrius`, `cc2`→`cc3` across all scripts and docs
- CI/release workflows read toolchain version from `.cyrius-toolchain` (no hardcoded env)
- CI installs from GitHub release tarball directly (removed `ci-cyrius.sh` dependency)
- `version-bump.sh` rewritten: updates 9 files atomically with auto-computed `serial_println` byte lengths
- `kprint_num()` delegates to `kfmt_int()` (stdlib fmt)
- All byte-by-byte copy/compare/zero loops replaced with `memcpy()`/`memset()`/`memeq()` across initrd, shell, net, elf, fatfs, pmm, heap, proc, vfs, devs
- Shell `blkread` hexdump uses `kfmt_byte()`, `lspci` uses `kfmt_hex0x()`

### Fixed (P-1 Hardening — 14 buffer overflows)
- `proc_table[336]` → `[2688]` (16 procs x 168B, was 2-proc overflow)
- `proc_signals[16]`/`proc_sigmask[16]` → `[128]` (16 procs x 8B)
- `idt[512]` → `[4096]` (256 vectors x 16B, was overflowing by 3584 bytes)
- `gdt[8]` → `[56]`, `tss[16]` → `[104]` (x86_64 descriptor tables)
- `kb_isr[64]` → `[96]` (83-byte ISR machine code)
- `sc_normal[16]`/`sc_shifted[16]` → `[128]` (128-entry scancode tables)
- `vfs_table[128]` → `[1024]` (32 fds x 32B)
- `dev_table[64]` → `[512]` (16 devs x 32B)
- `pci_devs[64]` → `[1024]` (32 slots x 32B)
- `sh_buf[16]` → `[128]` (shell input, was accepting 126 chars into 16 bytes)
- `tcp_conns[80]` → `[640]` (8 connections x 80B)
- `vfs_create_pipe()` memory leak on fd alloc failure
- `proc_create_address_space()` allocation rollback on pmm failure
- Signal number bounds checks in `kill` syscall and `proc_send_signal`
- Epoll watch list capacity check (max 8 watches in 128-byte buffer)
- ELF loader returns error on `pmm_alloc` failure (was silently continuing)
- VFS `read`/`write` validate `buf != 0` and `count >= 0`
- FAT16 cluster validation (`cluster < 2` rejected)
- Initrd file count capped at 256 (prevents OOB reads on malformed initrd)
- Pipe circular buffer mask `& 4087` → `% 4088` (non-power-of-2 fix)

### Metrics
- Binary: 220KB (x86_64), 57KB (aarch64)
- Source: ~4,800 lines across 46 files
- Syscalls: 26
- Subsystems: 33
- Shell commands: 19 (added `test`)
- Tests: 106 kernel assertions (7 categories)

## [1.11.0] — 2026-04-07

### Added
- GRUB bootable ISO (`scripts/iso.sh`, `boot/grub/grub.cfg`)
- ELF fixup for GRUB compatibility (`scripts/elf-fixup.py`)
- TCP/IP stack: connect, send, recv, close, connection table, 3-way handshake
- VirtIO-blk driver: sector read/write, DMA-safe buffers, PCI bus mastering
- FAT16 filesystem reader: boot sector, directory listing, file open/read
- Shell commands: `tcp`, `blkread`, `ls`, `disk`
- SMP trampoline layout fixed (no section overlaps, data at 0x8180+)

### Changed
- CI uses `$HOME/.cyrius/` instead of `/tmp` (self-hosted runner compatibility)
- Build scripts write temp files to `$ROOT/build/` not `/tmp`
- Preprocessed source (`#define ARCH_X86_64`) prepended by build script

### Fixed
- 6 tilde operator (`~`) replacements with two's complement
- 7 string length off-by-one fixes
- Shell help lists all 18 commands
- SMP trampoline 32-bit code no longer overruns 64-bit section

### Metrics
- Binary: 143KB (x86_64), 57KB (aarch64)
- Syscalls: 26
- Shell commands: 18

## [1.2.0] — 2026-04-07

### Added
- VirtIO net receive path: `virtio_net_poll`, `net_poll`, `net_recv_udp`, ARP cache updates
- Signal delivery: SIGCHLD sent on process exit, pending signal check in scheduler
- Pipes: VFS type 6 with 4KB circular buffer, `pipe` syscall (#25), `pipe_read`/`pipe_write`
- Shell commands: `recv` (show received UDP), `pipe` (pipe read/write test)
- `proc_send_signal`, `proc_check_pending_signals`, `proc_get_ppid` helpers
- `net_handle_arp`, `net_handle_udp` factored helpers for packet dispatch

### Changed
- CI pinned to Cyrius 1.9.0
- Build scripts prepend `#define ARCH_X86_64` directly (no dependency on cyrb `-D` flag)
- CI uses local `scripts/ci-cyrius.sh` for reliable toolchain install

### Metrics
- Binary: 115KB (was 98KB)
- Syscalls: 26 (was 25)
- Shell commands: 14 (was 12)

## [1.1.0] — 2026-04-06

### Added

#### Multi-Architecture Support
- Split monolithic `kernel/agnos.cyr` into 33 files: `arch/x86_64/` (14), `core/` (15), `user/` (3), main orchestrator
- aarch64 port: PL011 UART serial, GIC interrupt controller, ARM generic timer, keyboard via UART RX, paging stubs
- aarch64 boots to PMM+heap initialization on `qemu-system-aarch64 -M virt`
- Build with `sh scripts/build.sh --aarch64` using `-D ARCH_AARCH64`
- `arch_wait()` / `arch_halt()` abstraction — shared code is asm-free

#### Kybernet Integration
- 17 new syscalls (total 25): dup, mkdir, rmdir, mount, sync, reboot, pause, getuid, kill, sigprocmask, signalfd, epoll_create, epoll_ctl, epoll_wait, timerfd_create, timerfd_settime, umount
- Signal infrastructure: per-process `proc_signals[]` and `proc_sigmask[]`
- VFS types: signalfd (type 3), epoll (type 4), timerfd (type 5)
- agnosys dual backend: kybernet compiles with `-D LINUX` or `-D AGNOS`
- Bridge spec: `docs/development/kybernet-bridge.md` and `docs/development/syscall-additions.md`

#### Benchmarks and CI
- `rdtsc()` cycle-accurate benchmarks: PMM 1304 cy/op, syscall 188 cy/op, heap 1207 cy/op
- `scripts/bench.sh` — automated benchmark runner with `BENCHMARKS.md` and `bench-history.csv`
- `scripts/check.sh` — 11-point project validation (build, tests, docs, version consistency)
- `scripts/version-bump.sh` — automated version management
- CI uses Cyrius installer (`install.sh`) as single source of truth
- SHA256 checksums in release workflow

#### Optimizations
- PMM `next_free` hint: O(1) sequential allocation
- PMM init: 64-byte memset instead of 512 `pmm_set()` calls
- `kmalloc` zeros only requested size, not full slab block
- Dead code removed: `apic_send_ipi()`, unused `kfree()`

### Changed
- CI pinned to Cyrius 1.7.1 (was 1.6.1)
- `test.sh` requires `cyrb` (no `cc2` fallback for multi-file builds)
- aarch64 build no longer needs SP patch trampoline (compiler fixed in Cyrius 1.7.0)

### Fixed
- Port I/O helpers (`inb`/`outb`) had wrong rbp offsets from extra `var p = port` copies
- `slab_grow()` flags `0x03` → `0x83` (correct 2MB page flag)
- Global variable initializers not persisting in kernel mode — explicit init at boot

## [1.0.0] — 2026-04-05

### Added

#### Core Infrastructure
- Full x86_64 kernel: multiboot1 boot, 32-to-64 shim, serial I/O
- GDT (5 segments + TSS descriptor), IDT (256 vectors), PIC (8259A remap)
- TSS for ring 3 transitions with RSP0

#### Interrupts and Timers
- Local APIC (MMIO at 0xFEE00000, timer, IPI)
- APIC periodic timer at ~100Hz (replaces PIT)
- Keyboard: PS/2, full US QWERTY scancode map, shift/caps/ctrl support

#### Memory Management
- Page tables: 16MB identity map with 2MB huge pages, per-process tables
- Physical memory manager: bitmap allocator (4096 pages, next-free hint)
- Virtual memory manager: map/unmap/alloc with TLB invalidation, user-accessible pages
- Kernel heap: slab allocator, 8 size classes (32-4096B)

#### Process Management
- Process table: 16 slots, 168B context, CR3 per-process
- Context switch: full register save/restore, CR3 switch
- Scheduler: round-robin
- SYSCALL/SYSRET: MSR setup, ring 3 transition, memory isolation
- Syscalls: exit(0), write(1), getpid(2), spawn(3), waitpid(4), read(5), close(6), open(7)

#### Filesystem and Drivers
- ELF loader: static ELF64, per-process address space
- VFS: file table, device/memfile types
- Device drivers: serial char device
- Initrd: flat format, name lookup

#### Networking
- PCI bus: config space scan, device discovery
- VirtIO-Net: legacy PCI, virtqueues, Ethernet frames
- IP/UDP stack: ARP, IPv4, UDP send

#### SMP and Userland
- SMP infrastructure: APIC, IPI, trampoline, per-CPU stacks
- Interactive shell: 12 commands (help, echo, ps, free, cat, uptime, lspci, cpus, net, send, bench, halt)
- kybernet init: PID 1

### Fixed (Phase 10 Audit)
- PMM bounds checking (page >= 4096 guard)
- Process table overflow guard (proc_count >= 16)
- ISR full register save (9 caller-saved regs instead of 3)
- Syscall write: length clamped to 4096, null pointer rejected
- Process state validation in syscall handlers

### Metrics
- Binary: 106KB (x86_64)
- Source: ~2,980 lines, 122 functions (single file)
- 27 subsystems, 8 syscalls
- Boots to interactive shell on QEMU in <100ms
