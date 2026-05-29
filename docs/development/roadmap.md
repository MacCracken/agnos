# AGNOS Kernel Roadmap

> **Current**: v1.39.3. Shipped and (mostly) iron-validated on archaemenid: MVP boot-to-shell (Attempt 68 / 1.30.9), the **storage stack** (NVMe / AHCI/SATA / USB-MS / RAM-disk / VirtIO 1.x + 5-backend block-layer dispatch + GPT), the **networking stack** (r8169 GbE NIC + ARP/IPv4/UDP + TCP incl. server primitives + DHCP — iron-COMPLETE at 1.32.9), and **read+write filesystems** (ext2/ext4 via the 1.33.x WRITE arc; FAT12/16/32 + exFAT via the 1.34.x FAT-family arc — `fsck`/`mtools`-validated, first FAT/exFAT iron burn user-driven/pending). The **1.35.x line** then added the networking-comms substrate (DNS + ICMP + TCP-hardening + NTP), **anonymous `mmap`/`munmap`** (syscalls 27/28, 1.35.3–1.35.4), the **RTC boot clock** (1.35.5 — local wall clock from CMOS, NTP refines), a **TTL-aware DNS cache** (1.35.6), and an **arc-close hardening pass** (1.35.7 — ingress IP-length clamp). Done-state detail lives in [`state.md`](state.md) + [`CHANGELOG.md`](../../CHANGELOG.md).
>
> **This file is forward-facing only** — completed arcs are not re-listed here; their history is the CHANGELOG's job.
>
> **1.35.x networking-comms arc — COMPLETE** (all RELEASED): **1.35.0** docs sweep + DNS + ICMP · **1.35.1** TCP hardening (B0–B4: in-order ring + retransmit/RTO + MSS/segmentation + peer-window) · **1.35.2** NTP/SNTP (the kernel's first wall clock). The reliable-stream + name-resolution + wall-clock substrate is now in place. The next destinations — **TLS** (→ HTTP / `ark`-fetch) and **PIE** (→ full-binary KASLR) — are **cyrius-side** (PIE codegen + stdlib TLS, days-to-weeks; the user drives them with the cyrius agent). Legacy virtio-net back-burnered (known TX gap); plug-and-play / hot-add still a candidate.
>
> Live state: [`state.md`](state.md). Per-version history: [`../../CHANGELOG.md`](../../CHANGELOG.md). Language roadmap: `../cyrius/docs/development/roadmap.md`.

## Active / near-term

The 1.35.x cycle theme plus open items not yet bound to a specific minor.

| Item | Status | Notes |
|------|--------|-------|
| **1.35.x networking-comms arc** | ✅ COMPLETE (1.35.0–1.35.2) | DNS + ICMP + TCP-hardening (B0–B4) + NTP all RELEASED — the AGNOS-side comms runway is done. The next big destinations, **TLS** (→ HTTP / `ark`-fetch) and **full-binary KASLR**, are **cyrius-gated** (stdlib TLS / PIE codegen, days-to-weeks); until they land, near-term agnos work is the open items below. |
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
| **1.36.x** | **Refactor ops** (pre-heavy-items cleanup) — planned targets COMPLETE | The dedicated refactor cycle before the heavy big-write arcs; *structural* changes only, kept separate from the 1.35.7 arc-close hardening. Two refactors landed, every cut byte-identical: **(1) `net.cyr` split** (1.36.0 TCP → `net_tcp.cyr`; 1.36.1 app-protocols + ingress → per-protocol files) — `net.cyr` 2019 → 272 LOC, 8 focused files; record: agnosticos [`refactor-net-cyr-split.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/refactor-net-cyr-split.md). **(2) `main.cyr` selftest extraction** (1.36.2) — boot self-tests → `selftests.cyr`, kybernet launch → `boot_finish.cyr`; `main.cyr` 1661 → 1244 LOC. `ext2.cyr` split deferred to 1.39.x (VFS arc); `shell.cyr` to 1.41.x — both stay deferred until those subsystems are next touched. |
| **1.37.x** | ext4 **extent ALLOCATION** + **`kashi` fold-in arc-close** — COMPLETE | Extent-tree split + `ee_len` / `ee_start_hi` accounting; adds the extent **write** path on top of the existing reader + bitmap allocator so AGNOS can grow `EXTENTS_FL` inodes. Bites: **1.37.0 depth-0 append** (extend-last + insert into inline root ≤ 4, `ext2_write_at` routing) · **1.37.1 depth 0→1 grow** (`grow_indepth` spills the root into a leaf block + node checksum) · **1.37.2 multi-leaf** (`add_sibling_leaf`: up to 4 leaves under the inline root) · **1.37.3 depth-2 grow** (`grow_indepth2` spills the root's 4 index entries into an INDEX block — completes the 0→1→2 ladder; **iron-validated Iron Attempt 1373 boot-1 PASS + host `e2fsck -fn /dev/nvme0n1p2` clean**) · **1.37.4 selftest idempotency fix** (skip-PASS when `/extseed.dat` is already at `eh_depth==2` from a prior boot) · **1.37.5 arc-close — vendor `kashi` 0.6.0** (retired the inline 96-glyph VGA 8x16 tables in `fb_console.cyr`; consumes kashi's freestanding font-data core via `[deps.kashi] path="../kashi"`. Pulls forward both the planned 1.38.0 kashi-consumption AND the 1.40.x font-separation in the same motion). Every cut gated on `e2fsck -fn` clean on a default `mkfs.ext4` image; iron burn dispositive at 1.37.3/.4. Audit + design: agnosticos [`ext4-extent-alloc-prior-art.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/ext4-extent-alloc-prior-art.md). |
| **1.38.x** | jbd2 **journaling** | Crash-safety beyond the 1.33.x ordered-write story (ext2 has none by design). A major own-cycle. The kashi-consumption that was previously booked at 1.38.0 landed at 1.37.5 instead (see row above), so 1.38.x opens with jbd2 as the headline. |
| **1.39.x** | **VFS generic-write layer** | The `ext2_*` → `vfs_*` write lift promoted to its own cycle. FAT (1.34.x) is the second writable filesystem — the concrete trigger that earns the abstraction (abstract-on-demand, per the `block.cyr` dispatch precedent). Shell write-verbs (`touch`/`rm`/etc. across FSes) land here rather than as throwaway per-FS verbs. |
| **1.40.x** | *(formerly: console-font separation → `kashi`)* — **DONE at 1.37.5, slot freed** | The kashi fold-in shipped at 1.37.5 as the arc-close of the extent-allocation cycle, so this slot is open. Next-feature candidate TBD (a kernel-slimming continuation if more separations surface, or absorbed by 1.41.x agnoshi-shell separation). |
| **1.41.x** | Shell separation — **agnoshi** ingests the main shell | Split `kernel/user/shell.cyr` into (a) a minimal in-kernel emergency/recovery shell (boot fallback) and (b) the full interactive role, which **agnoshi** (userland AI shell, already the BOOT_MINIMAL console) owns. Defines the kernel↔userland shell boundary. Pairs with 1.40.x as the kernel-slimming arc. |
| **1.42.x** | Kernel performance band | A dedicated make-it-fast cycle once the feature + separation arcs settle. Measurement-first: profile hot paths with the 3-tier `bench` (core / subsystems / integration), tune with `bench` deltas gating each change. Candidate targets: PMM + slab fast paths, scheduler + context-switch cost, syscall entry/exit, block-IO batching, ext2/4 read+write hot loops, `fb_console` scroll. |
| **1.43.x–1.45.x** | **agnos 2.0 — clean refactor / rewrite (HELD)** | Runway reserved for a clean-sheet kernel refactor toward a 2.0, but the slots **do not open until Cyrius ships the language items a clean rewrite needs** (closures, type-system depth, generics, bare-metal-target maturity, module system — the v6.x+ surface). Depends on **Cyrius ship cadence, not agnos's**; Cyrius stays hands-off ([[feedback_cyrius_hands_off]]). Until then these are reserved placeholders; intervening work uses other slots. |

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
| **1.3x–1.4x** | **AMD** — primary dev line | archaemenid. MVP → storage → networking → ext2/4 WRITE → FAT-family → (active) **1.35.x catchup-tidbits** → big-write own-cycles (1.37 extent-alloc / 1.38 jbd2 / 1.39 VFS) → kernel-slimming separations (1.40 font→`kashi` / 1.41 shell→agnoshi) → 1.42 perf band → 1.43–1.45 held for an agnos-2.0 clean rewrite, gated on Cyrius. |
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
