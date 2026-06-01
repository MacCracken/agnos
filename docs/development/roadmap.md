# AGNOS Kernel Roadmap

> **Current**: v1.40.14 (1.40.x arc closeout — process teardown/reaping + hardening; QEMU-validated, iron re-burn pending). The **whole 1.40.x exec-from-disk + VFS-routing arc is iron-validated** on archaemenid (the `14013_final*` burn: ring-3 exec from disk, FAT shell verbs while ext2 owns `/`, and a clean boot past scheduler activation through to kybernet). Shipped and iron-validated on archaemenid: MVP boot-to-shell (Attempt 68 / 1.30.9), the **storage stack** (NVMe / AHCI/SATA / USB-MS / RAM-disk / VirtIO 1.x + 5-backend block-layer dispatch + GPT), the **networking stack** (r8169 GbE NIC + ARP/IPv4/UDP + TCP incl. server primitives + DHCP — iron-COMPLETE at 1.32.9), and **read+write filesystems** (ext2/ext4 via the 1.33.x WRITE arc; FAT12/16/32 + exFAT via the 1.34.x FAT-family arc — `fsck`/`mtools`-validated, first FAT/exFAT iron burn user-driven/pending), the **1.35.x networking-comms substrate** (DNS + ICMP + TCP-hardening + NTP + `mmap`/`munmap` + RTC clock), the **1.36.x refactor cycle** (byte-identical net.cyr/main.cyr splits), the **big-write own-cycles** (1.37 ext4 extent-allocation · 1.38 jbd2 journaling · 1.39 VFS generic-write lift — all crash-safe + iron-validated), and **1.40.x exec-from-disk + VFS mount routing** (whole arc iron-validated). Done-state detail lives in [`state.md`](state.md) + [`CHANGELOG.md`](../../CHANGELOG.md).
>
> **This file is forward-facing only** — completed arcs are not re-listed here; their history is the CHANGELOG's job. The cyrius-side destinations the network substrate feeds — **TLS** (→ HTTP / `ark`-fetch) and **PIE** (→ full-binary KASLR) — are driven with the cyrius agent, not here.
>
> Live state: [`state.md`](state.md). Per-version history: [`../../CHANGELOG.md`](../../CHANGELOG.md). Language roadmap: `../cyrius/docs/development/roadmap.md`.

## Active / near-term

Open items not yet bound to a specific minor (the active engineering arc is **1.41.x — shell separation**, detailed below).

| Item | Status | Notes |
|------|--------|-------|
| **AMD Zen Quiet-Boot scanout residue** | parked | Doesn't block MVP (VGA-path legible at 1080p + 1440p). Resumption options: HUBP `clear_tiling` port (Linux `drivers/gpu/drm/amd/display/` analog) OR a shadow-buffer FB-console architectural eval (simpledrm-style). Pin: `project_amd_zen_scanout_residue`. |
| **Optical via USB-MS (SCSI MMC profile) / ATAPI** | folds into 1.35.x plug-and-play | HP external USB Blu-ray derps archaemenid at cold boot if plugged pre-power-on (USB hand-off / firmware quirk); hot-add support fixes the cold-plug quirk as a side effect. Alternative iron path: AllInOne internal CD/DVD (likely SATA ATAPI — would revive previously-punted ATAPI/AHCI passthrough). |
| **`mmap` follow-ons** | open | `mmap` (anonymous, 2 MB-granular) shipped at **1.35.3** (syscall 27); `munmap` at **1.35.4** (syscall 28). Remaining follow-ons: 4 KB-granular / partial mapping (needs a 4 KB user-paging level), file-backed mapping (needs the VFS page cache), a vaddr free-list for non-top arena holes. Slot when a consumer's churn demands them. |
| **Bench-history snapshot in repo** | open | Decide: check in last-released `BENCHMARKS.md` + `bench-history.csv` as a tagged-state reference, or leave CI-only. (Original v1.27.1 carry-forward.) |
| **Hardware-validation infra** | open | RPi4 / NUC harness on the self-hosted runner. Unblocks SMP-AP-wakeup-on-real-hardware. |
| **SMP AP wakeup on real hardware** | open (gated on hardware-validation infra) | QEMU-validated only; needs hardware-in-the-loop. Stays open across multiple arcs. |

## Future minors (slotted)

Each is a feature-class lift in its own right; slot numbers are the intended sequence, not commitments.

| Slot | Item | Notes |
|------|------|-------|
| **1.41.x** | **Shell separation — `agnsh` (agnoshi) becomes the interactive shell, exec'd from disk** — **ACTIVE arc** | The first userland-binary-as-system-component, unlocked by the 1.40.x exec path. Detailed bite ladder + dependencies in the dedicated **§ 1.41.x — Shell Separation Arc** below. Pairs with the 1.40.x exec arc as the kernel-slimming half (font→`kashi` already landed at 1.37.5). |
| **1.42.x** | Kernel performance band | A dedicated make-it-fast cycle once the feature + separation arcs settle. Measurement-first: profile hot paths with the 3-tier `bench` (core / subsystems / integration), tune with `bench` deltas gating each change. Candidate targets: PMM + slab fast paths, scheduler + context-switch cost, syscall entry/exit, block-IO batching, ext2/4 read+write hot loops, `fb_console` scroll. |
| **1.43.x–1.45.x** | **agnos 2.0 — clean refactor / rewrite (HELD)** | Runway reserved for a clean-sheet kernel refactor toward a 2.0, but the slots **do not open until Cyrius ships the language items a clean rewrite needs** (closures, type-system depth, generics, bare-metal-target maturity, module system — the v6.x+ surface). Depends on **Cyrius ship cadence, not agnos's**; Cyrius stays hands-off ([[feedback_cyrius_hands_off]]). Until then these are reserved placeholders; intervening work uses other slots. |

## 1.41.x — Shell Separation Arc (active)

**Goal**: move the interactive shell role out of the kernel. Today `kybernet` (PID 1) calls the in-kernel `shell()` (`kernel/user/shell.cyr`, ~1150 LOC) — a ring-0 REPL that polls the keyboard directly (`kb_has_key`/`kb_read_scancode`), prints via `kprint`, and calls `ext2_*`/`vfs_*`/`fatfs_*` kernel functions in-process. The arc makes the **userland `agnsh` binary** (the [agnoshi](https://github.com/MacCracken/agnoshi) repo — AI-native NL shell, ~5 K LOC / 295 KB static, v1.3.x) the interactive shell, **exec'd from disk in ring 3** via the 1.40.x exec path. The in-kernel shell shrinks to a minimal **emergency/recovery fallback**. This is the first userland binary promoted to a system component, and it defines the **permanent kernel↔userland shell boundary** — the kernel-slimming counterpart to the 1.40.x exec arc (font→`kashi` already landed at 1.37.5).

**Why now**: 1.40.x exec-from-disk is iron-validated (a static ELF64 runs in ring 3 off the agnos-fs), and 1.40.14 process teardown means a long-lived userland process won't leak its slot/pages. `agnsh` is the natural first tenant.

**The gap (current → required)**: a ring-3 `agnsh` can reach the kernel *only* through syscalls, but the in-kernel shell uses kernel internals directly. Two concrete surfaces are missing:
1. **Interactive stdin from ring 3.** `read(fd=0)` must return keyboard input the kernel services (today fd 0 → serial, `devs.cyr`). A long-lived interactive ring-3 process needs a **blocking stdin** the kernel drives from the keyboard IRQ — the first interactive extension of the run-to-completion exec model (the kernel enables interrupts in ring 0 while the syscall blocks, returns the byte/line to ring 3).
2. **Real FS syscalls.** `agnsh`'s builtins need `open`/`read`/`write`/`close` (exist) **plus** `getdents`/readdir, `mkdir`, `rmdir`, `unlink`, `rename`, `stat`, `chdir`/`getcwd` — `mkdir`/`rmdir` are tier-1 stubs returning 0 (`syscall.cyr`) and the rest don't exist as syscalls. They wire cleanly to the 1.40.13 mount-routed VFS backends.

**Bite ladder** (sequence, not commitments):
- **1.41.0 — arc open + boundary audit.** Inventory the in-kernel verb surface against the 28-entry syscall table; enumerate the syscall gaps `agnsh` needs; decide what stays in the emergency shell. Audit doc (agnosticos `shell-separation-prior-art.md`). Stage the `agnsh` static build onto the agnos-fs as `/bin/agnsh`.
- **1.41.1 — interactive stdin from ring 3.** Blocking `read(fd=0)` serviced from the keyboard driver (the syscall path enables IRQs in ring 0 while waiting), with backspace/line-edit parity with the in-kernel loop. The dispositive new capability — a userland process reads the keyboard for the first time.
- **1.41.2 — real FS syscalls.** Wire `getdents`/readdir + `mkdir`/`rmdir`/`unlink`/`rename`/`stat`/`chdir`/`getcwd` to the mount-routed VFS; replace the tier-1 stubs. `agnsh`'s filesystem builtins now work in ring 3.
- **1.41.3 — `kybernet` execs `/bin/agnsh`.** PID 1 `run`s the userland shell instead of calling in-kernel `shell()`; on exec failure (missing/corrupt `/bin/agnsh`) it falls back to the in-kernel emergency shell. First boot-to-agnsh-on-disk.
- **1.41.4 — shrink the in-kernel shell to an emergency/recovery shell.** Keep only recovery essentials (`ls`/`cat`/`run`/`reboot` + enough to repair a broken `/bin/agnsh`); the full verb surface + AI/intent features live in `agnsh`. Locks the permanent boundary.
- **1.41.5 — arc-close hardening + the combined iron burn** (`agnsh` interactive on real Zen).

**Dependencies / honest caveats**:
- **Preemptive ring 3 (interrupt-KPTI) is NOT required** for the MVP separation, *as long as* `agnsh` runs its builtins via syscalls (a single long-lived ring-3 process making blocking syscalls fits the run-to-completion model once 1.41.1 lands). It **is** required for `agnsh` to launch *external* binaries (`agnsh` spawning a child program) without the run-to-completion constraint — that's a **follow-on** (ring-3-initiated `spawn`/`waitpid`), not part of this arc.
- **`agnsh`'s AI / intent / `hoosh`-gateway features are out of scope here** — the arc's bar is "agnsh is the interactive shell, from disk, talking to the kernel only via syscalls." LLM wiring (`hoosh`) is its own later arc.
- The in-kernel emergency shell is **permanent**, not transitional — it's the boot fallback when no userland shell is reachable. The boundary (kernel = recovery only; userland = full interactive) does not collapse.

## Deferred (no slot yet — confirm scope before opening)

| Item | Notes |
|------|-------|
| **NTFS read + squashfs read** | Split out of the FAT-family decision (2026-05-26). **NTFS** read — Windows-volume interop; complex on-disk format ($MFT, attribute runs, B-trees), multi-source-audit-heavy. **squashfs** read — compressed read-only FS; leverages `sankoch` (LZ4/DEFLATE/zlib/gzip) decompression in-kernel. Both read-only; each its own minor when slotted. |
| **HTREE indexed directory support (ext4)** | Linear dirent scan suffices for read; HTREE is a performance optimization for huge directories (10k+ entries). Queue when a real consumer needs it. |
| **Full-binary KASLR (Option A)** | Gated on cyrius v6.1.x PIE codegen — see § *Full-Binary KASLR* below. Closes the last ~20% of KASLR value beyond the data-only scope shipped at 1.28.0. |
| **Radios — WiFi + USB Bluetooth** | Proposed as its own decade **1.7x** (see decade map). Expected multi-cycle "super pain": WiFi (firmware + mac80211-equivalent MLME + WPA2/WPA3 supplicant via `sigil`) + USB Bluetooth (HCI-over-USB on the xHCI stack → L2CAP → RFCOMM/GATT). Deliberately late so it inherits a proven IP/TCP/DHCP stack, battle-tested xHCI bulk/interrupt-EP machinery, matured `sigil` crypto, and the post-2.0 cleaner kernel. Confirm whether WiFi and BT split into separate cycles before opening. |

## Explicitly NOT in the near-term queue

- **Preemptive scheduling** — deep rewrite of scheduler + IRQ handlers; round-robin is cooperative today, preemptive needs interrupt-safe context save/restore. Own-arc, no slot.

## Platform-target & long-range decade map

> **Speculative beyond the active line.** Slots ≥1.5x are tentative and shift readily — confirm before opening any. Cross-session directive: memory `hardware-target-version-lines`. The whole ≥1.5x map shifted up one decade vs the original 2026-05-22 plan because the AMD dev line outgrew a single decade.

Each X.Y *decade* carries either a hardware-platform bring-up arc **or** one big cross-cutting feature arc; within a decade the X.Y.Z minors progress through capability classes.

| Decade | Theme | Notes |
|--------|-------|-------|
| **1.3x–1.4x** | **AMD** — primary dev line | archaemenid. MVP → storage → networking → ext2/4 WRITE → FAT-family → 1.35.x comms-substrate → 1.36.x refactor → big-write own-cycles (1.37 extent-alloc + font→`kashi` / 1.38 jbd2 / 1.39 VFS) → 1.40.x exec-from-disk + VFS routing → (active) **1.41.x shell→agnoshi** → 1.42 perf band → 1.43–1.45 held for an agnos-2.0 clean rewrite, gated on Cyrius. |
| **1.5x** | **Intel** platform | templemount (i9) + other Intel HW surfaces. Carries the **i225-V NIC driver** (queued out of the 1.32.x networking arc — separate hardware line). |
| **1.6x** | **aarch64 / Pi** platform | Pi-class hardware; other open-ARM SBCs (BeagleBone / ODROID / Rockchip) likely ride here too. |
| **1.7x** | **Radios — WiFi + USB Bluetooth** *(feature arc, not a platform)* | Own decade because the wireless stack is expected to be a multi-cycle "super pain." Cross-platform. |
| **1.8x** | **RISC-V** platform | RISC-V boards on hand. Shifted from 1.7x when radios claimed that decade. |
| **N/A** | **Apple Silicon** | NOT a kernel-on-iron target — userland-apps (native Cyrius) + VM only; Asahi owns that lane. |

## Full-Binary KASLR (Option A) — slot TBD on the cyrius v6.1.x PIE track

Reserved for whichever minor lands once cyrius PIE codegen ships. The data-KASLR shipped at 1.28.0 covers ~80% of the security value; Option A closes the last ~20% (gadgets pre-computed against the kernel binary itself, which currently sits at fixed `0x100000`).

**Hard prerequisite**: cyrius v6.1.x PIE codegen support. Filed at [cyrius/proposals/2026-05-11-pie-support.md](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md); slotted on the cyrius v6.x track after v6.0.0. When it lands, KASLR-Option-A work can begin in parallel with whatever 1.3x.y cycle is active; actual slot depends on cyrius ship cadence, not agnos's. agnos does **not** hand-roll a relocation table (rejected in `proposals/2026-05-11-kaslr-scope.md`).

**Work surface (when cyrius PIE is available):** boot shim grows ~2× (relocation walk + slid entry), kernel binary rebuilt with `--pie`, slide-aware crash-dump symbolizer, CI assertion rewrite (current `KASLR: pmm_next_free=N` probe stays; new `KASLR: kernel_slide=0x<hex>` probe lands alongside). Two-boot-diff assertion extended to cover the binary base.

**Pre-cyrius prep (no-op until PIE lands):**
- Audit remaining absolute-address assumptions in source (`proc_table` accessors, VFS slots, PciDev offsets already moved to named accessors — pre-existing wins that reduce the audit surface).
- Decide whether the slide range stays at 64 MB (boot-shim-friendly) or grows to full 4 GB (more entropy, more page-table work).
