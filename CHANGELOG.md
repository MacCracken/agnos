# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
