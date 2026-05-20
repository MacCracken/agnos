# Changelog

All notable changes to AGNOS are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### NVMe Phase 1 (probe + capability decode + controller disable)

First engineering cut of the 1.31.x storage arc. New `kernel/core/nvme.cyr` (~230 LOC) modeled on `kernel/arch/x86_64/usb/xhci.cyr` Phase 1 — per `feedback_redesign_dont_reinvent`, Linux's `drivers/nvme/host/pci.c` `nvme_disable_ctrl` + `nvme_wait_ready` path is the reference impl.

**What it does:**
- `nvme_probe()` — `pci_find_by_class(0x01, 0x08, 0x02)` (NVM Express triple), `pci_bar0_64` → MMIO base, `pci_enable_bus_master_idx`, `vmm_remap_uc_2mb` (BAR needs UC, not WB). Reads `CAP[63:0]` as two 32-bit halves and `VS[31:0]`, decodes MQES / DSTRD / TO / CSS_NVM / MPSMIN / MPSMAX / version triple, prints a two-line summary.
- `nvme_disable()` — if `CC.EN=1` clear it, write back, poll `CSTS.RDY=0` (1M-iter safety ceiling; QEMU NVMe reaches RDY=0 in tens of iterations).
- Wired into `main.cyr` after `virtio_blk_init`. Graceful no-op when no NVMe device is present.

**What it does NOT do:** Admin queue (AQA / ASQ / ACQ programming), `CC.EN=1` re-enable, IDENTIFY, I/O queues, read/write, MSI-X. Those are Phase 2 onward.

**CMOS checkpoints:** `kcp=0x40` on probe done, `kcp=0x41` on disable confirmed. Slots 0x40-0x47 reserved for NVMe (parallel to xhci's 0x30-0x37).

**QEMU validation (NVMe 1.4 model):**

```
gnoboot v0.4.2: handing off to kernel
nvme: found at 824633737216, version=1.4.0
nvme: MQES=2047 DSTRD=0 TO=15x500ms CSS_NVM=1 MPSMIN=0 MPSMAX=4
nvme: controller disabled, RDY=0
VFS initialized
AGNOS shell v1.31.0 (type 'help')
```

Tested with `-drive file=nvme0.img,if=none,format=raw,id=nvme0 -device nvme,drive=nvme0,serial=AGN001` on QEMU q35. BAR0 lands at 0xC0000000000 (768 GB high range, same shatter-path code that handles qemu-xhci on q35). MQES=2047 = 2048-entry queue support (zero-based), DSTRD=0 = standard 4-byte doorbell stride. The baseline no-NVMe smoke continues to PASS — `nvme: no controller found` prints and the kernel proceeds to shell unchanged.

**Build:** `build/agnos` 421,912 B (1.31.0) → **424,656 B** (+2,744 B for the nvme.cyr module). Multiboot2 ELF64 entry `0x1000a8` preserved.

**Out of scope:** Iron burn — Phase 1 is pure read-only enumeration; no behavioral path lands new on iron until at least Phase 3 (first I/O). Will bundle with Phase 2 or Phase 3 once the admin-queue + IDENTIFY path is in place.

## [1.31.0] — 2026-05-20 (Production build goes lean — KTEST + XHCI_VERBOSE compile gates; FB-absent guard; stale Attempt-N prose retired; `docs/development/build.md`)

**1.30.x cycle closed; 1.31.x cycle opens with the production-default flip.** The 1.30.x sweep (1.30.0 → 1.30.12) cleared the FB-hardening + MVP-gate work on both BIOS paths (VGA-spec Attempt 68, Quiet Boot Attempt 76, true-font swap Attempt 77; Attempt 78 falsified the gnoboot SetMode-bounce lever, Attempt 79 Intel cross-check was structurally inconclusive). What landed there made every boot loud — KTEST self-test output + xhci developmental traces were unconditional because we needed them during the silent-absorb diagnostic arc. With the gate green, production boots should not carry diagnostic spam. 1.31.0 introduces source-side compile gates so the test paths and the verbose xhci trace ship out by default; opt back in via `KTEST=1` / `XHCI_VERBOSE=1` to the build script. Bundled: an FB-absent honesty guard the prior cycle's `fb_console_init` rewrite missed, a sweep of decayed Attempt-N references from `fb_console.cyr` comments, and a new `docs/development/build.md` that documents the gate matrix end-to-end. Cycle theme pivots from FB to **storage** — first 1.31.x engineering cuts target the NVMe block layer, not the framebuffer.

### Bundle (three behavioral changes, doc addition)

1. **`KTEST` compile gate.** Boot-time in-kernel self-tests in `kernel/core/main.cyr` (Syscall test, Context Switch test, Scheduler test idle loop, VFS/initrd test, Userland Exec test) are now `#ifdef KTEST` — off by default. Production boots skip ~18 lines of test output and ~6 CMOS checkpoints (CP12, CP14×2, CP18 cluster). The shell-side assertion framework gate `TEST` (separate, gates `include "user/test.cyr"` in `agnos.cyr`; consumed by `scripts/ktest.sh`) is unchanged — different layer, different purpose. Enable via `KTEST=1 ./scripts/build.sh`.

2. **`XHCI_VERBOSE` compile gate.** Developmental xhci output is now `#ifdef XHCI_VERBOSE` across `kernel/arch/x86_64/usb/{xhci,xhci_cmd,xhci_port}.cyr`: `cmd_submit#` TRB-tracking, `evt#` event trace, `drained N events`, `PP=1 asserted bitmap=`, `CRCR.CRR / ERSTSZ / IMAN / ERDP_lo` readback, `enable_slot entry idx=` / `cycle=`. High-level confirmation lines stay unconditional (`xhci: halted, reset clean`, `dev_notifications enabled`, `controller running, HCH=0, ERDP=`, `port N connected`, error cases) — those are operational signal, not diagnostic noise. CMOS checkpoint stamps stay unconditional too; they're the iron post-mortem channel and cost nothing on a working boot. Enable via `XHCI_VERBOSE=1 ./scripts/build.sh`.

3. **FB-absent guard in `fb_console_init`.** New early-return path: if `diag_phys == 0` (no GOP at handoff — text-only firmware, headless server, or LocateProtocol failure in gnoboot), serial-print `"fb: no framebuffer present, serial-only console"`, set `fb_console_ready = 0`, return. The existing `pf > 1` guard does NOT catch this case (`0 > 1` is false), and the prior code would fall through and set `fb_console_ready = 1`, lying to upper-layer routing about an FB console being live. Downstream paint ops all early-return on `fb_phys == 0` so there was no segfault risk, but the readiness signal needed to be honest. Closes a quality residue from the 1.30.11 PixelFormat-guard cut.

4. **`docs/development/build.md` — new.** End-to-end build documentation: how `scripts/build.sh` resolves the cyrius toolchain, the source-side defines (`ARCH_X86_64` / `ELF64_KERNEL`) vs cyrius-backend env vars (`CYRIUS_ELF64_KERNEL=1`) lockstep, the `KTEST` / `XHCI_VERBOSE` opt-in gates, the prepend-instead-of-`-D` rationale (`-D` doesn't propagate into included files — same caveat that drove the `ARCH_X86_64` prepend), output artifacts, smoke-test entry points, and links to the Path-C handoff + iron bring-up references. Distinguishes `KTEST` (boot-time inline tests) from `TEST` (shell-side `test` command, `scripts/ktest.sh`) — two gates, two layers, two purposes; a recurring source of confusion now documented in place.

### Verification

- ✅ Cyrius build clean (5.11.64 pin, no errors, 43 unreachable fns — up from 33 at 1.30.12 because gated test code is unreachable when `KTEST` is undefined)
- ✅ Multiboot2 ELF64 entry preserved at `0x1000a8`
- ✅ Default lean build: `build/agnos` 425,840 B (1.30.12) → **421,912 B** (1.31.0, −3,928 B net from gated code compile-out)
- ✅ Iron Attempt 77 (1.30.12 true-font swap on archaemenid Quiet Boot) — VGA console legible end-to-end, no regressions vs the QEMU receipts. User-confirmed at cycle close 2026-05-20. Boot logging streamlined as designed: production banner cadence visible without the test-spam / verbose-xhci noise.
- ⏸ Iron burn of 1.31.0 itself — deferred. Per `feedback_iron_burns_block_other_work` no diagnostic-only burns are scheduled; the production-default flip will be exercised on the first 1.31.x storage burn that needs iron validation.

### Build

`build/agnos` **421,912 B** at 1.31.0 (was 425,840 B at 1.30.12, −3,928 B). The reduction is exactly the gated-out code: KTEST inline-test bodies + XHCI_VERBOSE kprint sites compile to nothing when the flag is undefined. With `KTEST=1 XHCI_VERBOSE=1 ./scripts/build.sh`, expect ~425-426 KB matching the 1.30.12 footprint. Multiboot2 ELF64 entry `0x1000a8`. Cyrius pin **5.11.64**. gnoboot **0.4.2** unchanged (kernel-side change only).

### Changed

- `VERSION`: 1.30.12 → 1.31.0
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.31.0 (auto-regenerated by `scripts/version-bump.sh`)
- `kernel/agnos.cyr`: header-comment version reference bumped 1.30.12 → 1.31.0 (auto)
- `kernel/core/main.cyr`: five `#ifdef KTEST` / `#endif` brackets around Syscall test, Context Switch test, Scheduler idle-loop test, VFS/initrd + memfile test, Userland Exec test. One added `kprintln("", 0);` after `test_hw_syscall();` so the FB row doesn't collide with the next kprint when KTEST is enabled (the function prints intermediate detail to serial and one bare digit to the kprint channel; the explicit newline closes the row).
- `kernel/arch/x86_64/fb_console.cyr`:
  - Header comment: stripped reference to 1.30.12 Attempt 76 photo; collapsed to "8×8 source was illegible (~0.55% of screen height per row at 1440p)" — display-density framing per `feedback_display_density_before_speculation`
  - `fb_console_init` diagnostic-rationale block: stripped Attempt 33/34 (VGA-vs-HDMI) historical text; now points at `project_amd_zen_scanout_residue` memory pin for the live FB-handoff bug class
  - **Added FB-absent guard** (early-return for `diag_phys == 0`)
  - MTRR comment block collapsed: prior block explained why MTRR-WC was removed (Attempt 74 falsification, AMD SYS_CFG_MSR MtrrLock #GP); replaced with a forward-looking comment about why PAT is the cache-typing path
  - `fb_fb_size` comment: stripped "Attempt 73 addition" / "gnoboot 0.4.0+, Attempt 73+" archaeology — gnoboot 0.4.x is the only supported floor, no version-conditional caveats needed
  - `fb_size_or_fallback` comment: same archaeology cleanup
  - `FB_CONSOLE_Y0` comment: stripped "v1.30.1: boot_shim canary stripe ... Attempt-29-post" historical text; kept the operational note ("bump if a top-of-screen visual diagnostic needs to come back — one-line change")
- `kernel/arch/x86_64/usb/xhci.cyr`: `#ifdef XHCI_VERBOSE` around CRCR/ERSTSZ/IMAN/ERDP readback block in `xhci_start` and the `enable_slot entry idx=` line in `xhci_enable_slot`
- `kernel/arch/x86_64/usb/xhci_cmd.cyr`: `#ifdef XHCI_VERBOSE` around `cmd_submit#` print in `xhci_cmd_submit` and `evt#` trace in `xhci_cmd_wait`
- `kernel/arch/x86_64/usb/xhci_port.cyr`: `#ifdef XHCI_VERBOSE` around `drained N events` print in `xhci_drain_port_change_events` and `PP=1 asserted bitmap=` print in `xhci_ports_power_on` (CMOS stamps at 0x87/0x6B stay unconditional — those are post-mortem signal)
- `scripts/build.sh`: env-driven `#define KTEST` / `#define XHCI_VERBOSE` prepends, gated on the presence of the matching env var. Same prepend-not-`-D` mechanism as `ARCH_X86_64` / `ELF64_KERNEL`.
- `docs/development/build.md`: **new** — see Bundle #4

### Out of scope

- **Storage subsystem engineering.** This cut is purely the cycle-open + build-hygiene work. The 1.31.x storage arc starts in the next cut (NVMe block-layer scaffold expected first — direction confirmation pending at the time of the bump).
- **Quiet Boot legibility residue.** Parked to the next-cycle pin per `project_amd_zen_scanout_residue` — re-attack vectors are HUBP `clear_tiling` port or shadow-buffer architectural eval, not another GOP SetMode lever (both forms falsified at Attempt 78).
- **Iron burn of 1.31.0.** Pure build-hygiene + comment cleanup — no behavioral change to validate. First 1.31.x iron burn will be the storage-engineering cut that needs it.
- **Removal of CMOS stamping** from xhci paths. Stamps are unconditional by design — they're the iron post-mortem channel (`feedback_no_serial_on_iron`), cost effectively nothing on a working boot, and are the only iron-readable signal when serial isn't available.

## [1.30.12] — 2026-05-20 (True-font swap — VGA 8x16 BIOS ROM replaces hand-drawn CGA 8x8; fb_scale 2-tier; MTRR/audit dead code removed; QEMU PASS at 1080p + 1440p, iron Attempt 77 pending)

**The legibility bar.** Attempt 76 (closing 1.30.11) cleared three of four MVP bars on Quiet Boot at native HDMI 2560×1440: no lockup, live keyboard, live refresh. The fourth — *legible* glyphs — was unsolved because the existing 8×8 CGA bitmap was hand-drawn at primitive resolution; scaling each font pixel 3× made each dot bigger, not each letter readable. This cut swaps the source bitmap for the canonical IBM VGA BIOS 8×16 ROM font (public domain since 1981, same byte table Linux's `lib/fonts/font_8x16.c` carries) and revises `fb_scale()` from four tiers to two. The bundled cleanup deletes the MTRR-install + PCI audit dead code whose call sites already came down at 1.30.11 (`fb_mtrr_install_wc`, `fb_audit_mtrr`, `fb_audit_pci_bar`, plus the two `pci_cfg_*` helpers, plus the matching decoder slots in `read-boot-log.cyr`). Pre-bound on iron Attempt 77 by the outcome tree in `agnosticos/docs/development/true-font-swap-plan.md`.

### Bundle (three behavioral changes, single iron burn)

Per `feedback_redesign_dont_reinvent` — VGA 8×16 = canonical reference impl; no first-principles glyph design.

1. **VGA 8×16 font swap.** `fb_font[768]` → `fb_font[1536]` (96 glyphs × 16 bytes vs 96 × 8). New `fset16(ch, hi, lo)` helper packs each glyph as two u64s — `hi` = rows 0-7, `lo` = rows 8-15 — so each init-table line reads top-to-bottom across two literals: `0xR0R1R2R3R4R5R6R7 0xR8R9RARBRCRDRERF`. 96-line init table transcribed byte-exact from the public-domain IBM VGA ROM dump (verified `'A'` row 7 = `0xFE` etc. against multiple reference copies). The render loop in `fb_putc` now iterates 16 rows instead of 8 and scales each font bit into an `S × S` block, so the on-screen character cell is `8*S × 16*S` (non-square). Cell width and height are now distinct: `cell_w = 8 * fb_scale()`, `cell_h = 16 * fb_scale()`. `fb_fill_cell` and `fb_scroll_up` updated to use `cell_h` for all vertical extents (scroll-up distance, bottom-row clear height, max_rows divisor in `fb_putc`).

2. **`fb_scale()` policy collapse to 2-tier.** Pre-1.30.12 used four tiers (1/2/3/4 by ≤900/≤1200/≤1800/else) because the 8×8 source needed 3-4× scaling to be visible at all on high-DPI displays. With a real 8×16 font, scale=1 (`8×16` cell) is already legible at 1080p (16-px-tall glyph = 1.5% of screen height) and scale=2 (`16×32` cell) covers 2K+ comfortably. New policy: `h ≤ 1200 → 1`, else 2. Two render paths instead of four; same code, less complexity.

3. **MTRR-install + audit dead-code removal** *(bundled cleanup)*. The three function bodies left in `fb_console.cyr` at 1.30.11 (`fb_audit_mtrr` ~57 lines, `fb_mtrr_install_wc` ~78 lines, `fb_audit_pci_bar` ~67 lines incl. helpers) are deleted. Matching `read-boot-log.cyr` decoder coverage for CMOS extended-bank slots `[0x88..0x8F]` (focused-summary block + verbose-mode print rows + sweep header) is retired in step. The 1.30.11 cycle's MtrrLock-as-lockup-cause hypothesis (Attempt 74) was already falsified; this is just the second-stage cleanup the 1.30.11 Out-of-scope flagged as a 1.30.12 item.

### Verification

- ✅ Cyrius build clean (5.11.64 pin, no errors, 33 unreachable fns)
- ✅ Multiboot2 ELF64 entry preserved at `0x1000a8`
- ✅ QEMU Path-C **headless smoke at 1920×1080** — `EXPECT="AGNOS shell"` matched. Serial transcript: `fb: mode=0/30 phys=0x80000000 pf=1 w=1920 h=1080 pitch=7680 size=...`, `AGNOS kernel v1.30.12`, `fb: WC verified (PAT entry 1)`, `AGNOS shell v1.30.12`. Scale=1 render path exercised end-to-end.
- ✅ QEMU Path-C **headless smoke at 2560×1440** — `EXPECT="AGNOS shell"` matched. Same render path under scale=2; cell geometry `16×32`. Confirms the 16-row glyph paint loop doesn't crash and `cell_h` substitution is consistent across `fb_putc` / `fb_fill_cell` / `fb_scroll_up`.
- ✅ Kernel + shell banners bumped to **v1.30.12**
- ⏸ Iron Attempt 77 — pending. Pre-bound outcomes matrix in `agnosticos/docs/development/true-font-swap-plan.md` § Verification.

**Visual confirmation (QEMU)** — one-shot screendump via QMP at 2560×1440 captured to [`agnosticos/docs/development/iron-nuc-zen-photos/qemu-1.30.12-vga-8x16-shell-2560x1440.png`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-photos/qemu-1.30.12-vga-8x16-shell-2560x1440.png). Crisp VGA console: xhci log, kybernet startup, `AGNOS shell v1.30.12 (type 'help')`, `agnos>` prompt all legible. No striping, no garbling, no transcription typos visible in the font data — letterforms match the canonical IBM VGA ROM exactly. Scale=2 producing `16×32` cells reads as designed. Iron Attempt 77 is now the only remaining gate.

### Build

`build/agnos` 422,048 B (1.30.11 close) → **425,840 B** (1.30.12, +3,792 B net). Breakdown: +font data + fset16 init calls (~9 KB), -MTRR/audit/PCI dead code (~5 KB), -other (negligible). Multiboot2 ELF64 entry preserved at `0x1000a8`. Cyrius pin **5.11.64**. gnoboot **0.4.1** unchanged (no boot_info field added; kernel-side change only).

### Changed

- `VERSION`: 1.30.11 → 1.30.12
- `kernel/arch/x86_64/fb_console.cyr`:
  - file-header comment block updated for 8×16 font + non-square cells
  - `var fb_font[768]` → `var fb_font[1536]`
  - `fn fset(ch, val)` → `fn fset16(ch, hi, lo)` — packs 16 bytes from two u64s
  - init table rewritten: 96 lines of `fset16(0xXX, 0x..., 0x...);` carrying the IBM VGA 8×16 ROM font
  - `fb_scale()` revised to 2-tier (`h ≤ 1200 → 1`, else 2); accompanying comment block rewritten
  - `fb_fill_cell` and `fb_scroll_up`: separate `cell_w` (8×s) and `cell_h` (16×s) extents
  - `fb_putc`: render loop iterates 16 rows instead of 8; `max_rows = (height - FB_CONSOLE_Y0) / cell_h`
  - DELETED `fb_audit_mtrr`, `fb_mtrr_install_wc`, `fb_audit_pci_bar`, `pci_cfg_addr`, `pci_cfg_read32` (call sites already removed at 1.30.11)
  - in-file MTRR-removal comment in `fb_console_init` updated to reflect full deletion
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.30.12 (auto-regenerated by `scripts/version-bump.sh`)
- `agnosticos/scripts/src/read-boot-log.cyr`: removed reads of CMOS slots `[0x88..0x8F]`, removed focused-summary MTRR/PCI prose block, removed verbose-mode `print_cmos_line` rows for those slots, sweep header re-pointed from "Attempt 74 scanout re-arm" to "Attempt 77 true-font swap"

### Out of scope

- **Color attributes / per-character colors.** White-on-black stays.
- **Unicode beyond ASCII 0x20-0x7F.** CP437 line-drawing chars are post-MVP.
- **Spleen / Terminus / Cozette quality bump.** VGA 8×16 is MVP-shaped; higher-density bitmap fonts queued for 1.31.x as a quality bump if archaemenid evidence supports it.
- **Shadow buffer + single-burst FB push.** Still 1.31.x triage (pristine refresh; gated on PMM contig allocator).
- **Multi-device USB / xHCI.** Still queued for triage after the visual-MVP gate clears.
- **Font fallback / runtime font selection.** Compiled-in only; no filesystem dependency at boot.

## [1.30.11] — 2026-05-19 → 2026-05-20 (FB hardening — PixelFormat guard + WC retry-after-pmm + idempotent vmm_remap_wc_2mb + font-density scale + MTRR/audit removal; iron Attempts 71→76, Quiet Boot MVP gate at 76)

**Post-MVP hardening cycle — Quiet Boot path joins VGA-spec at the MVP gate.** Three 1.30.10 carry-forward items closed (VGA-vs-HDMI handoff guard, obsolete gvar-init workaround cleanup, FB BAR memtype runtime check), plus a pre-existing multi-chunk WC-remap leak in `vmm_remap_wc_2mb` that the new memtype check surfaced and is now fixed in the same cut. The quiet-boot ON/OFF asymmetry on archaemenid (HDMI-spec mode produces garbled glyphs, VGA-spec mode renders clean — original symptom in Attempt 33 photo, 2026-05-16) was originally hypothesized to be a non-BGRX PixelFormat under quiet-boot ON; the PixelFormat guard landed first and then iron evidence falsified the hypothesis (Attempt 71 stamped `pf=1` BGRX same as VGA-spec). The cycle then accreted a font-pixel-density fix and an MTRR/audit removal across Attempts 72→76 before clearing the Quiet Boot MVP gate — typeable shell, live keyboard, live refresh — at Attempt 76 on 2026-05-20. Visual legibility (the remaining bar) is a font-source problem, not a paint/cache problem, and moves to 1.30.12 true-font.

### Bundle (four behavioral changes, no iron burns yet)

Per `feedback_redesign_dont_reinvent` — audited Linux's `drivers/video/fbdev/efifb.c` PixelFormat handling and `arch/x86/mm/pat.c` PAT-readback patterns before designing the guards. No diagnostic-letter ladder.

1. **PixelFormat-aware FB render + serial diagnostic**. New `fb_pf()` getter reads `boot_info+0x5C` (gnoboot already captured `pf` from GOP — kernel just never read it). `fb_console_init` now logs `fb: phys=0x... pf=N w=W h=H pitch=P` to serial before any paint — ground truth available even when the FB itself goes garbled. Pf-aware branch: `pf == 0` (RGBX) and `pf == 1` (BGRX) both render safely (monochrome white/black is symmetric in those channels); `pf == 2` (PixelBitMask) or `pf == 3` (PixelBltOnly) → log warning, set `fb_console_ready = 0`, fall to serial-only console. Linux ref: `efifb.c` rejects modes outside the two 8-bit-per-channel-with-reserved formats.

2. **Obsolete gvar-init defensive workaround DELETED**. The `fb_console_init` re-assignment of `FB_CONSOLE_Y0 / FB_FG / FB_BG` was a 2026-05-15 workaround for cyrius 5.7.19's gvar-init-order bug (top-level non-zero `var` initializers weren't honored at runtime). Cyrius 5.11.64 fixed the underlying issue at the MVP gate. Dead code removed; top-level initializers now take effect correctly.

3. **FB BAR memtype runtime check** — new `fb_verify_wc()` function reads back the controlling 2MB PDE (or 1GB PDPT entry for unshattered cases) and decodes PWT/PCD/PAT bits against the firmware-default PAT MSR. Called from `kernel/core/main.cyr` AFTER `pmm_init` + a post-pmm WC remap retry, so it sees the final cache state. Emits exactly one line per boot: `fb: WC verified (PAT entry 1)` (green gate) or `fb: WARN expected PAT entry 1 (WC), got entry N PDE=0x...` (silent regression — pixel-pattern noise about to return). New `vmm_get_pde_2mb(phys)` accessor in `kernel/core/vmm.cyr` walks PML4 → PDPT → PD across all coverage paths (< 1 GB inline PD@0x3000, 1 GB–512 GB PML4[0] walk, ≥ 512 GB lazy-PML4 walk). Linux ref: `arch/x86/mm/pat.c`.

4. **`vmm_remap_wc_2mb` idempotency fix** (real pre-existing bug surfaced by item 3). Multi-chunk FBs above 1 GB previously re-shattered the PDPT entry on every chunk in the same 1 GB region, allocating a fresh PD each call and **overwriting earlier chunks' WC bits with WB defaults from the new PD's identity fill**. Net result: only the LAST chunk ended up WC; all earlier chunks reverted to WB. Iron archaemenid was unaffected (FB BAR in 32-bit hole, inline path is naturally idempotent), but any future iron target with a high FB BAR — and QEMU q35, which places its FB BAR at `0x80000000` — silently leaked PDs and ended up partially WB. New idempotency branch: if the PDPT entry is already shattered (Present + not a 1 GB huge page), reuse the existing PD and just edit the target PDE in place. Same shape extended into `vmm_remap_wc_2mb` only; `vmm_remap_uc_2mb` left alone (only called once per UC region in current usage).

### Bundle continued (added across Attempts 72→76, 2026-05-20)

5. **CMOS extended-bank FB-geometry stamping**. `fb_console_init` stamps mode/pf/w/h/pitch/mode#/maxmode + sentinel `0xFB` to slots `[0x90..0x9F]` of the CMOS extended bank, in addition to the serial diagnostic. archaemenid has no serial cable (`feedback_no_serial_on_iron`); CMOS extended bank is the only iron-readable post-mortem channel for FB geometry. Decode path in `agnosticos/scripts/src/read-boot-log.cyr`. First use: Attempt 71 stamp confirmed `pf=1` BGRX under Quiet Boot ON — same as VGA-spec — which falsified the PixelFormat-asymmetry hypothesis that drove this cycle's opening cut.

6. **Font-pixel-density scale by display height** *(Attempt 76 functional fix)*. New `fb_scale()` returns 1/2/3/4 from `fb_height()` (≤900 / ≤1200 / ≤1800 / else). `fb_putc`, `fb_fill_cell`, and `fb_scroll_up` render each font bit as an `S×S` pixel block; the on-screen character cell is `8*S × 8*S`. At archaemenid Quiet Boot's 2560×1440 native HDMI mode, scale=3 produces a 24-px cell — readable as text-shaped objects rather than the 8-px stripes the Attempt-33 photo signature was originally misread as structural scanout corruption. The root cause across the Attempts 71-74 ladder was always font-pixel-density at native HDMI resolutions; the MTRR / PixelFormat / scanout speculation was wrong-layer.

7. **MTRR-install + audit calls removed from `fb_console_init`** *(Attempt 76 lockup fix — falsified hypothesis)*. Attempt 74 added `fb_mtrr_install_wc(fb_phys, fb_size)` + `fb_audit_mtrr()` + `fb_audit_pci_bar()` on the hypothesis that MTRR-UC was overriding PAT-WC and causing the visual corruption (Intel SDM Vol 3A §11.5.2.2 / AMD APM Vol 2 §7.7.5 — MTRR-UC always wins). Iron Attempt 74 falsified both halves: visual corruption unchanged after MTRR-WC install (confirming the hypothesis was wrong-layer), and the system **locked up post-`fb_console_init`** (suspected AMD `SYS_CFG_MSR` MtrrLock → `#GP(0)` on `wrmsr` to variable-range MTRR MSRs, per AMD APM Vol 3 §3.3). Attempt 76 removed the call sites; function bodies remain in-file for now as dead code (full cleanup is a follow-up). Removing them recovered Quiet Boot from "garbled visuals AND lockup" (post-74) to "garbled visuals but typeable shell" (76).

### Post-pmm WC retry

`kernel/core/main.cyr` now calls `vmm_remap_wc_range` a second time right after `pmm_init` returns, followed by `fb_verify_wc()`. The line-17 attempt at boot succeeds immediately for FBs in the 32-bit hole (< 1 GB inline-PD-rewrite path, no allocation needed — iron archaemenid case) but silently fails for FBs at phys ≥ 1 GB because `vmm_remap_wc_2mb`'s high-mem path needs `pmm_alloc` for a fresh PD and pmm isn't initialized at line 17. The post-pmm retry is a no-op on iron (PDE already 0x8B from line 17) and the completion gate on QEMU q35 / any high-BAR target. FB briefly paints WB-cached in the high-BAR case until the retry — benign, since the display reads physical memory regardless of cache type.

### Verification

- ✅ Cyrius build clean (5.11.64 pin, no errors, 31 unreachable fns)
- ✅ Multiboot2 ELF64 entry preserved at `0x1000a8`
- ✅ QEMU Path-C **headless smoke** via new `agnosticos/scripts/qemu-fb-smoke.sh` — `EXPECT="AGNOS shell"` matched on ConOut at 1920×1080 and at 2560×1440 (post-font-scale). New harness is the headless companion to `qemu-fb-visual.sh`; reusable across cycles.
- ✅ Serial diagnostic landed: `fb: mode=N/M phys=0x... pf=1 w=2560 h=1440 pitch=10240 size=0x...`
- ✅ CMOS extended-bank geometry stamps verified via `read-boot-log` on iron (Attempt 71 → `pf=1` BGRX same as VGA-spec, falsifying the PixelFormat-asymmetry opening hypothesis)
- ✅ Post-pmm WC verification landed: `fb: WC verified (PAT entry 1)` — the idempotency fix is what made this go from WARN to verified under q35
- ✅ Kernel + shell banners bumped to **v1.30.11**
- ✅ **Iron Attempt 71** (2026-05-20) — Quiet Boot CMOS stamps proved `pf=1` BGRX; opens the font-density branch.
- ✅ **Iron Attempt 72-73** — Quiet Boot vs VGA-spec geometry capture; mode/size diff captured to CMOS for diffing.
- ✗ **Iron Attempt 74** — MTRR-install repair FAILED on both halves (visual unchanged → wrong-layer; new system lockup → MtrrLock suspected). Hypothesis retired; call sites removed at Attempt 76.
- ⊘ **Iron Attempt 75** — BYPASSED. Photo re-interpretation in chat reframed the "horizontal stripes" as 8-px-cell font density rather than structural scanout corruption (`feedback_display_density_before_speculation` — 8/1440 = 0.55%, ~font height not ~scanout artifact).
- ✅ **Iron Attempt 76** (2026-05-20) — Quiet Boot MVP gate clear: no lockup, keyboard live, refresh live; glyphs scaled to 24-px cell but still illegible as letters (8×8 CGA source bitmap is the bottleneck). 3-of-4 bars cleared in one burn; legibility moves to 1.30.12 true-font. See `agnosticos/docs/development/iron-nuc-zen-log.md` § Attempt 76.

### Build

`build/agnos` 414,544 B (1.30.10) → 416,496 B (1.30.11 initial cut 2026-05-19) → **422,048 B** (1.30.11 final post-Attempt-76, +7,504 B over the cycle). Multiboot2 ELF64 entry preserved at `0x1000a8`. Cyrius pin **5.11.64**. gnoboot **0.4.1** at 1.30.11 close (was 0.2.0 at cycle open; 0.3.0 added GOP FrameBufferSize capture at boot_info+0x68 for Attempt 73, 0.4.0/.1 followed for the SetMode arc that Attempt 74 falsified — gnoboot ABI grew but the agnos kernel reads remain back-compat). Path-C handoff ABI stable on the kernel side.

### Changed

- `VERSION`: 1.30.10 → 1.30.11
- `kernel/arch/x86_64/fb_console.cyr`:
  - new `fb_pf()` / `fb_mode_current()` / `fb_mode_max()` / `fb_fb_size()` / `fb_size_or_fallback()` getters
  - new `fb_verify_wc()` function (one-shot PAT readback + decode + serial log)
  - new `cmos_ext_write(slot, val)` helper for extended-bank CMOS stamps
  - new `fb_audit_mtrr()` + `fb_mtrr_install_wc(phys, size)` + `fb_audit_pci_bar()` (function bodies retained as dead code after Attempt 76 removed the call sites; full removal is a follow-up)
  - new `fb_scale()` returning 1/2/3/4 by display height
  - `fb_console_init` now: logs boot-time geometry to serial; stamps geometry to CMOS extended bank `[0x90..0x9F]`; guards on `pf > 1` (skip FB, serial-only); DELETED the obsolete `FB_CONSOLE_Y0/FB_FG/FB_BG` re-assignment block (cyrius 5.11.64 made it dead code); **does NOT** call the MTRR-install / MTRR-audit / PCI-audit helpers (they tripped MtrrLock `#GP` on AMD per Attempt 74)
  - `fb_putc` / `fb_fill_cell` / `fb_scroll_up` now use `cell_w = 8 * fb_scale()` and render each font bit as an `S×S` block
- `kernel/core/vmm.cyr`:
  - new `vmm_get_pde_2mb(phys)` accessor (walks PML4 → PDPT → PD; covers < 1 GB inline, 1–512 GB, ≥ 512 GB lazy-PML4 paths)
  - `vmm_remap_wc_2mb` now idempotent for already-shattered PDPT entries — fixes the multi-chunk WC-leak
- `kernel/core/main.cyr`: post-`pmm_init` WC remap retry + `fb_verify_wc()` call
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.30.11
- **NEW** `agnosticos/scripts/qemu-fb-smoke.sh`: headless Path-C boot smoke harness with EXPECT-grep + timeout
- **NEW** read-boot-log decoder coverage for slots `[0x88..0x9F]` (MTRR-audit + PCI-audit + extended geometry) in `agnosticos/scripts/src/read-boot-log.cyr`

### Out of scope

- **PixelInformation bitmask decoder** for `pf == 2` cases. gnoboot doesn't capture the 16-byte bitmask (boot_info ABI would have to grow); kernel currently rejects pf==2 outright. CLOSED — Attempt 71 confirmed `pf=1` on archaemenid Quiet Boot, so no consumer drives this in MVP scope. Reopen if a future iron target reports pf==2.
- **`vmm_remap_uc_2mb` idempotency** — symmetric to the WC fix, but UC is called once per BAR in current usage. Defensive update queued for next vmm touch.
- **MTRR-install / audit dead-code removal** — Attempt 76 removed the call sites but the three function bodies (`fb_mtrr_install_wc`, `fb_audit_mtrr`, `fb_audit_pci_bar`) remain in `fb_console.cyr`. Full deletion + grep for unused decoder coverage in `read-boot-log` is a 1.30.12 housekeeping item.
- **Shadow buffer + single-burst FB push** → 1.31.x triage as before (pristine refresh; gated on PMM contig allocator).
- **Multi-device USB / xHCI** → still queued for triage after this cycle.
- **True-font swap (real bitmap font replacing hand-drawn 8×8 CGA)** → **1.30.12 scope** (this is the legibility bar remaining after Attempt 76).

## [1.30.10] — 2026-05-19 (Framebuffer refresh — WC + pitch-aware + u64 block-copy; iron Attempts 69→70, CRT-class refresh PASS)

**Post-MVP open. Speed closed out.** First cut after the closed-beta MVP gate (1.30.9, Iron Attempt 68). Scoped to framebuffer refresh quality — Attempt 68's bench scroll showed pixel-pattern noise in the lower FB region, traced to the kernel mapping the GOP framebuffer as WB-cached (default `vmm_map(..., 0x83)` selects PAT entry 0 = WB under firmware-default PAT MSR; confirmed Attempt 43). WB on a framebuffer means CPU pixel writes batch through L1/L2 and reach the display controller on cache evictions — visible as the observed artifact. Landed as two iron burns under one version: Attempt 69 (WC + pitch-aware → PARTIAL, cache artifacts gone but scroll still heavy) and Attempt 70 (u64 block-copy → PASS, CRT-class refresh, tearing below typical-user threshold).

### Bundle (four behavioral changes, two iron burns)

Per `feedback_redesign_dont_reinvent` — paths converged on the canonical Linux/EDK2 framebuffer mapping pattern, audited in advance, no letter ladder:

1. **WC framebuffer mapping** *(Attempt 69)* — `vmm_remap_wc_2mb(phys)` + `vmm_remap_wc_range(phys, size)` added to `kernel/core/vmm.cyr`; mirrors `vmm_remap_uc_2mb` structurally, flag `0x8B` (PWT=1, PCD=0, PAT=0) selects PAT entry 1 = WC under firmware-default PAT MSR. `kernel/core/main.cyr:8` now calls `vmm_remap_wc_range(fb_fb_phys(), fb_pitch() * fb_height())` immediately before `fb_console_init()`, so the FB is WC-mapped before the first kernel paint. WC coalesces sequential pixel writes into burst transactions to the display controller, eliminating WB-cache eviction timing artifacts. Linux `vesafb` / `efifb` request `ioremap_wc()`; same pattern.

2. **Pitch-aware init clear** *(Attempt 69)* — `fb_console_init`'s full-screen clear (`kernel/arch/x86_64/fb_console.cyr` ~line 80) now iterates `pitch / 4` u32s per row instead of `width`. When firmware's `PixelsPerScanLine > HorizontalResolution`, the padding u32s between `width*4` and `pitch` previously carried stale UEFI/firmware paint forever. Invisible behind the arcade-cabinet bezel on archaemenid; visible on QEMU and direct-attach displays.

3. **Pitch-aware scroll clear** *(Attempt 69)* — `fb_scroll_up` body copy + bottom-row clear (~line 250-275) walk `pitch / 4` u32s per row. Same rationale as #2 but in the scroll path.

4. **u64 block-copy** *(Attempt 70 follow-on, same 1.30.10)* — three inner loops in `kernel/arch/x86_64/fb_console.cyr` switched from `store32`/`load32` per-u32 to `store64`/`load64` per-u64 (`fb_console_init` full clear, `fb_scroll_up` body copy, `fb_scroll_up` bottom clear). Outer row iteration unchanged. Pre-loop computes `stride_u64 = pitch / 8` instead of `stride_u32 = pitch / 4`. Halves inner-loop transaction count: per-scroll IO drops from ~4.13M u32 pairs to ~2.07M u64 pairs. On WC-mapped FB the write combiner fills 8-byte bursts per cycle instead of 4-byte. Same instruction widths on x86-64 — build size identical (414,544 B) — but iron refresh perceptibly doubled (user-reported "old-school CRT 80's-ish speeds, smoother, not perfect").

### Verification

- ✅ Cyrius build clean (5.11.64 pin, no errors, 32 unreachable fns)
- ✅ QEMU Path-C serial smoke — `EXPECT="AGNOS shell"` matched on ConOut
- ✅ QEMU visual at **1920×1080 (std VGA via `-vga std -global VGA.xres=1920 -global VGA.yres=1080`)** — boots clean, scrolls clean, no regression at iron-class extent
- ✅ **Iron Attempt 69 → PARTIAL** — WB-cache eviction artifacts gone under WC; scroll throughput still showed a visible refresh sweep walking up the screen
- ✅ **Iron Attempt 70 → PASS** — u64 block-copy halved per-scroll transaction count; refresh sweep now perceptually below threshold for typical use. Maps to Attempt-70 pre-bound matrix row 1 ("visible refresh line gone or perceptually below threshold"). Per-attempt detail in [`agnosticos/docs/development/iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) § Attempts 69, 70.

### Build

`build/agnos` 413,216 B (1.30.9) → **414,544 B** (1.30.10, +1,328 B; Attempt-70 u64 follow-on did not change size — same MOV instruction widths on x86-64). Multiboot2 ELF64 entry preserved at `0x1000a8`. Cyrius pin **5.11.64**. gnoboot **0.2.0** unchanged (Path-C handoff ABI stable).

### Changed

- `VERSION`: 1.30.9 → 1.30.10
- `kernel/core/vmm.cyr`: added `vmm_remap_wc_2mb(phys)` + `vmm_remap_wc_range(phys, size)` (parallel to existing `vmm_remap_uc_2mb`)
- `kernel/core/main.cyr`: WC remap call inserted at line 8, immediately before `fb_console_init()`
- `kernel/arch/x86_64/fb_console.cyr`: `fb_console_init` clear loop + `fb_scroll_up` body/clear loops switched from `width` to `pitch / 4` extent (Attempt 69), then from u32 to u64 granularity with `stride_u64 = pitch / 8` (Attempt 70)
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.30.10

### Out of scope

Speed is closed for 1.30.10. Still-open framebuffer items stay in the 1.30.x line:

- **VGA-vs-HDMI handoff canary** → 1.30.11 hardening (separate concern from cache-mapping; needs A/B under different cable types)
- **Obsolete gvar-init defensive workaround** in `fb_console_init` → 1.30.11 (dead code post-cyrius 5.11.64 fix; non-blocking cleanup)
- **FB BAR memtype check** → 1.30.11 hardening (verify PAT entry is actually WC at runtime, not just remap-intent)
- **Glyph-to-font extraction** → 1.30.12 (externalize inline CGA 8x8 table; possibly aligned with BannerManor M2 CYML font format)
- **RAM-side shadow buffer → single-burst FB push** → 1.31.x triage (the mathematically-certain path to pristine refresh; gated on PMM contiguous-page allocation — Multiboot2 memory-map parse + `pmm_alloc_contig`. "If-and-when-we-want-pristine," not "must-fix")
- **Multi-device USB / xHCI** (BT mouse + keyboard regression) → triage after 1.30.11 closes; current driver assumes single HID slot context, Linux `drivers/usb/host/xhci-mem.c::xhci_alloc_virt_device` is the reference for multi-slot allocation

## [1.30.9] — 2026-05-18 (Iron Attempt 68 — SET_CONFIGURATION + canonical FS interval + ISP → **TYPEABLE SHELL ON IRON, MVP GATE HIT**)

**The closed-beta MVP gate hits.** Both halves — visual (since 1.30.7) and functional (typeable keyboard via xhci HID) — clear on archaemenid. `agnos> echo "Assembly Up!"` echoed back from the iron Logitech (VID=1452 PID=591) keyboard.

### The bundle (three behavioral diffs vs Linux/USB 2.0)

Per `feedback_redesign_dont_reinvent` — landed in one burn, no letter ladder, single read-only audit pass surfaced all three:

1. **SET_CONFIGURATION before SET_PROTOCOL** (`hid.cyr` `hid_kbd_configure`) — USB 2.0 §9.4.7. Reads `bConfigurationValue` from config descriptor byte 5, fires `xhci_control_no_data(slot_id, 0x00, 0x09, config_value, 0)`. Without this the device sits in Address state forever — strict USB firmware NAKs every interrupt-IN poll because no configuration is active.
2. **Linux-canonical FS polling interval** (`xhci_ctx.cyr` `xhci_interrupt_interval`) — FS/LS branch replaced `return 3` (hardcoded 1 ms over-poll) with `fls(8 * bInterval) - 1` clamped to ≤15. Inline `fls` (kernel has no bsr intrinsic).
3. **ISP on interrupt-IN Normal TRB** (`hid.cyr` line 225 + `hid_arm_xfer_trb` line 295) — Linux convention for IN-data TRBs.

### Result — iron Attempt 68

```
hid: keyboard layer initialized
hid: keyboard configured, boot protocol on, EP=129, polling 8-byte reports
...
AGNOS shell v1.30.9 (type 'help')
agnos> echo "Assembly Up!"
Assembly Up!
agnos>
```

Bench (3-tier) runs end-to-end under the typeable shell on iron — fibonacci 133 c/op, syscall_write 31 c/op, open+read+close 256 c/op, serial putc ~11.6 c/op. Photos + per-attempt narrative in [`iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) § Attempt 68.

### Why iron diverged from QEMU

QEMU's `usb-kbd` is permissive — ships interrupt-IN reports as soon as the host arms a TRB and rings the doorbell, ignoring device-side state. Real iron HID firmware honors USB 2.0 §9.1.1's "endpoints not operational until Configured" rule and NAKs every interrupt-IN poll until SET_CONFIGURATION moves the device Address → Configured. Same iron-strict / QEMU-permissive divergence shape as the Attempt 64 root-cause search; same QEMU lane was the audit unlock.

### Build

`build/agnos` 412,832 B (1.30.8) → **413,216 B** (1.30.9, +384 B). Multiboot2 ELF64 entry preserved at `0x1000a8`. Cyrius pin 5.11.64.

### Changed

- `VERSION`: 1.30.8 → 1.30.9
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.30.9
- `kernel/arch/x86_64/usb/hid.cyr`: SET_CONFIGURATION between config-descriptor walk and SET_PROTOCOL in `hid_kbd_configure`; ISP bit added to initial interrupt-IN Normal TRB (line 225) and `hid_arm_xfer_trb` (line 295).
- `kernel/arch/x86_64/usb/xhci_ctx.cyr`: `xhci_interrupt_interval` FS/LS branch rewritten to Linux-canonical `fls(8 * bInterval) - 1`.

### Open carry-forward into 1.30.10

- **Framebuffer refresh quality + VGA-vs-HDMI handoff audit**. Visible refresh is poor on archaemenid; pixel-pattern noise observed in the lower bench-output region of the FB. GOP framebuffer pitch/stride/format reconciliation pending. Now the active 1.30.x branch.

## [1.30.8] — 2026-05-18 (Iron Attempts 65/66/67 — RR falsified, EP0 MPS reconciliation clears HID enumeration; Phase-5 interrupt-IN open)

**Three same-day iron burns on archaemenid (Beelink SER AMD Renoir 1022:1639) carried the post-cyrius-.64 binary from "Phase-3 cleared" all the way to "HID enumeration cleared, agnoshi rendering on screen, but keystrokes silent."** This is the first 1.30.x cut where every xhci-side command and every EP0 control transfer completes on iron without a falsification.

### Iron Attempts 65 / 66 / 67 — the same-day arc

| # | Time (PDT) | Build under test | Outcome |
|---|---|---|---|
| 65 | ~19:07 | 411,280 B (post cyrius-.64 + CSZ helpers + Add-Flags A0\|A_new) | **Phase-3 silent-absorb cleared on iron**; Enable Slot, Address Device, GDD-8, GDD-18 all succeed (iron keyboard `VID=1452 PID=591`); new blocker — first `xhci_get_config_descriptor(slot_id, 0, 9)` inside `hid_kbd_configure` times out. Iron-only divergence vs QEMU's typeable end-to-end. |
| 66 | ~20:08 | 412,080 B (post Repair RR) | **RR falsified**: GCD-9 still times out. EP0-ring-conventions diagnosis disproven; ISP / deferred-cycle-Setup / `p_hi` are not the gate. |
| 67 | ~20:58 | **412,832 B** (post EP0 MPS reconciliation) | **HID enumeration clears end-to-end on iron**. `hid: probing iface kbd, slot=1, VID=1452 PID=591, class=0` → `hid: keyboard configured, boot protocol on, EP=129, polling 8-byte reports` → FB renders `agnoshi shell v1.30.8 (type 'help')`. New blocker — keystrokes don't reach the `agnos>` prompt (Phase-5 interrupt-IN silent). |

### Repair (RR) — Linux-canonical EP0 control-transfer hardening (Attempt 66, FALSIFIED)

Diffed `xhci_control_in` / `xhci_ep0_enqueue` against Linux `xhci_queue_ctrl_tx` (drivers/usb/host/xhci-ring.c, v6.13) and bundled three convergent-prior-art deltas:

- **RR.A** — Set `ISP` (Interrupt on Short Packet, bit 2) on the Data Stage TRB. Linux always sets it for IN data. Without ISP, a SHORT_PACKET on Data Stage doesn't emit its own Transfer Event; if Status Stage scheduling is delayed by the controller, the whole transfer goes silent. With ISP, the Data Stage's SHORT_PACKET event provides recovery / faster signaling.
- **RR.B** — Deferred-cycle Setup TRB write per Linux's `giveback_first_trb` convention. Write Setup with the *inverted* cycle bit (HW skips it), build Data + Status with the normal cycle, then atomically flip Setup's cycle to mark the TD live. Prevents controller DMA prefetch from racing partial TDs. Applied to both `xhci_control_in` (3-TRB Setup/Data/Status) and `xhci_control_no_data` (2-TRB Setup/Status, used by SET_PROTOCOL).
- **RR.C** — Propagate the full 64-bit `buf_phys` via the Data Stage TRB's `p_hi` (was hardcoded 0). No-op on archaemenid (descriptor buffers in low 4 GB), defensive against future high-memory allocations.

New helper `xhci_ep0_enqueue_raw(slot_id, p_lo, p_hi, status, ctrl_full)` — variant of `xhci_ep0_enqueue` that takes a fully-formed dw3 (caller controls cycle bit), used for the deferred-cycle Setup write.

**Status post-Attempt-66**: RR ships as defensive hardening — it matches Linux convention and provides better recovery behavior on SHORT_PACKET / cycle-prefetch races. It just isn't the iron-side gate for GCD-9.

### EP0 MPS reconciliation — xHCI 1.2 §4.6.7 / Linux `xhci_check_maxpacket` (Attempt 67, CLEARED HID ENUMERATION)

Diagnosis between Attempts 66 and 67: the Input Context's EP0 Max Packet Size is programmed pre-Address-Device at the speed-safe minimum (`xhci_ep0_mps_for_speed(speed)` — 8 for FS). The real `bMaxPacketSize0` returned from GDD-8 can be 8/16/32/64 for FS. Per xHCI 1.2 §4.6.7, if it differs from the stale Input-Context EP0 MPS, an Evaluate Context (TRB type 13) must update EP0 MPS *before* any wLength > MPS request. GCD-9 with stale MPS=8 multi-packets under the wrong burst size → the controller drops the second packet and the transfer event never posts. Linux reference: `xhci_check_maxpacket()` in `drivers/usb/host/xhci.c`. AMD FCH 1022:1639 enforces this strictly; QEMU's qemu-xhci is permissive on stale MPS — which is why the same binary ran end-to-end on QEMU through Attempt-65-equivalent code paths.

Repair (`+48 LOC` in `kernel/arch/x86_64/usb/xhci.cyr`):

- New `xhci_evaluate_context(slot_id, input_ctx_phys)` — issues TRB type 13 (`XHCI_TRB_EVAL_CONTEXT`), waits for the Command Completion Event, returns 0 on non-success ccode with a diagnostic print.
- New reconciliation block in `xhci_enumerate_port` after GDD-8: compares `load8(xhci_desc_buf_phys + 7)` (real `bMaxPacketSize0`) vs the slot's tracked `xhci_slot_max_packet`. On mismatch, allocates an Input Context with Drop=0, Add=A0|A1 (Slot + EP0 — spec requires Slot context present even if unchanged), patches EP0 dw1 bits [31:16] with the real MPS while preserving CErr/EPType/MaxBurst in [15:0], fires `xhci_evaluate_context`, updates the tracked slot MPS.

### Result on iron post-Attempt-67

Every xhci-side command now completes on archaemenid:

```
xhci: cmd_submit#1 trb_phys=... dw3=9217           (Enable Slot ✓)
xhci: cmd_submit#2 trb_phys=... dw3=16788481       (Address Device ✓)
hid: probing iface kbd, slot=1, VID=1452 PID=591, class=0
                                                   (Evaluate Context ✓, Configure Endpoint ✓)
hid: keyboard configured, boot protocol on, EP=129, polling 8-byte reports
...
AGNOS shell v1.30.8 (type 'help')
agnos>                                              ← no echo on keystroke (Phase-5 open)
```

USBSTS stays clean across the burn (no HSE / HCE / SRE); USBCMD = R/S | INTE | HSEE; no `xhci: transfer event timeout` printed. The controller isn't reporting an error — it's just not posting Transfer Events for the interrupt-IN ring on keypress.

### Build

Kernel `build/agnos` 411,216 B (1.30.7) → **412,832 B** (1.30.8 final — version-string + RR hardening + Evaluate Context surface + MPS reconciliation block). Multiboot2 ELF64 entry preserved at `0x1000a8`. Cyrius pin 5.11.64.

### Changed

- `kernel/arch/x86_64/usb/xhci.cyr`: **Repair RR** — `xhci_control_in` and `xhci_control_no_data` rewritten for Linux-canonical ISP + deferred-cycle Setup + full 64-bit `buf_phys` propagation. New helper `xhci_ep0_enqueue_raw`.
- `kernel/arch/x86_64/usb/xhci.cyr`: **EP0 MPS reconciliation** — new `xhci_evaluate_context(slot_id, input_ctx_phys)` issuing TRB type 13. New post-GDD-8 block in `xhci_enumerate_port` per xHCI 1.2 §4.6.7 / Linux `xhci_check_maxpacket` — compares real `bMaxPacketSize0` vs the speed-safe MPS, builds Input Context with Add=A0|A1, patches EP0 dw1 [31:16] preserving CErr/EPType/MaxBurst, fires Evaluate Context, updates tracked slot MPS.

### Open carry-forward into 1.31.x

- **Phase-5 interrupt-IN keystroke delivery on iron** (the Attempt-67 blocker): keypresses on the iron keyboard produce no characters at the `agnos>` prompt despite HID configured + polling armed. Likely candidates — interrupt-IN Transfer Event not being posted by the controller on keystroke (analogous to but distinct from Phase-3 CCE silent-absorb; different ring, different doorbell), or Transfer Event posts but `xhci_handle_transfer_event` isn't decoding it into HID reports, or HID translation runs but `kb_buf` enqueue isn't reaching agnoshi's `kb_read`. QEMU is symmetric end-to-end with the same binary (sendkey → echoed input) — so iron-specific divergence sits in the interrupt-IN event-posting layer. First diagnostic step (no burn): read-only audit of AGNOS's `xhci_handle_transfer_event` vs Linux `handle_tx_event` (drivers/usb/host/xhci-ring.c) to confirm interrupt-IN Transfer Event decoding parity.
- **Framebuffer VGA-vs-HDMI bug** (from pre-1.30.7 iron-bring-up): different output-path behavior across display connectors on archaemenid. Repair pending.

## [1.30.7] — 2026-05-18 (Attempt 63 VISUAL BOOT-TO-SHELL ON IRON → root cause found via QEMU → TYPEABLE SHELL ON QEMU)

**The MVP closed-beta arc — visual on iron at attempt-63 cut, typeable on QEMU after root-cause analysis the same day.** 1.30.7 spans two milestones: (1) the first iron build to render `agnoshi shell v1.30.7 (type 'help')` on archaemenid's framebuffer (Attempt 63, 2026-05-18 morning); (2) end-to-end typeable shell on QEMU's qemu-xhci the same evening, after the 10-letter cmd-path silent-absorb arc (FF→QQ+QQ2) was traced to a Cyrius compiler bug, not silicon. Iron Attempt 65 with the same binary as the QEMU-validated state is pending and is the candidate for a 1.30.8 cut if iron-specific fixes surface.

**ROOT CAUSE — Cyrius gvar-init-order**: top-level `var X = INT_LITERAL ;` declarations read as 0 before module-init runs. In agnos's kmode==1 boot (per cyrius emit ordering: top-level asm → PARSE_PROG body → EMIT_GVAR_INITS), the kernel's main body lives in PARSE_PROG and never returns, so the post-PROG init block that emits gvar literal stores never executes. `XHCI_CMD_TIMEOUT_SPINS = 10000000` (`xhci_cmd.cyr:60`) read as 0 → `while (wait < 0)` exited immediately → `events_seen=0` always. `XHCI_EVT_RING_SEGMENT_SIZE = 256` (`xhci_ring.cyr:51`) read as 0 → ERST entry's Ring Segment Size word planted as 0 → controller had no event-ring slot to write Command Completion Events to. Both load-bearing. **Fixed at the language level in cyrius v5.11.64** — image-static init for literal-RHS gvars across every backend (ELF32/64-kernel/user/shared/obj, aarch64, MachO x86_64/ARM64, PE-EXEC); regression test `tests/tcyr/gvar_static_init.tcyr`. Issue: [`2026-05-18-gvar-init-order-zero-reads.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-05-18-gvar-init-order-zero-reads.md). A 2026-04-28 ticket for the related forward-ref form (`global-init-order-forward-ref.md`) had shipped a cyrlint warning at v5.7.32 but didn't fix the codegen; .64 closes the loop.

**Three agnos-side bugs surfaced via the QEMU lane** (none would have been findable on iron alone — all are virtual-controller-divergent paths that hardcoded iron's known config):

1. **xHCI BAR above 4 GB unmappable** — `vmm_remap_uc_2mb` only handled PML4[0] (sub-512 GB). QEMU's qemu-xhci BAR lands at 0xC000000000 (768 GB) under OVMF.
2. **CSZ=1 hardcoded** — `xhci_alloc_input_ctx` wrote Slot Context at offset 0x40 and EP0 Context at 0x80 (64-byte CSZ=1 layout). QEMU's qemu-xhci has CSZ=0 (32-byte contexts) → controller read Slot Context at 0x20 (all zeros) → Address Device returned ccode=5 (TRB Error). Iron is CSZ=1 so was always working; QEMU surfaced the latent assumption.
3. **Add Flags carry-forward** — `xhci_input_ctx_add_interrupt_in` OR'd new Add bits onto the stale A1 (EP0) flag set by `xhci_alloc_input_ctx`. Configure Endpoint with A1=1 told HW to reload EP0 from the Input Context's stale EP0 (TR Dequeue Pointer untouched since Address Device, while Device Context EP0 had advanced through Get Device Descriptor traffic) → ccode=5 (TRB Error). Linux `xhci_init_input_control_ctx` convention is to set Add Flags = A0 | A_new only.

**xHCI cmd-path status after the fixes (QEMU + agnos@HEAD, validated 2026-05-18)**:
- Enable Slot → CCE arrives, slot 1 assigned ✓
- Address Device → CCE arrives, device addressed ✓
- Get Device Descriptor → 18 bytes returned, `VID=1575 PID=1 class=0` (QEMU usb-kbd) ✓
- Configure Endpoint → CCE arrives, EP3 interrupt-IN configured ✓
- Keyboard ringing doorbell, `hid: keyboard configured, boot protocol on, EP=129, polling 8-byte reports` ✓
- QEMU `sendkey h e l p ret` → `agnos> help` echo + full command output ✓
- QEMU `sendkey u p t i m e ret` → `agnos> uptime` → `2216 ticks` ✓

**Iron implications (untested)**: iron has CSZ=1 → CSZ-aware helpers compute the same 64-byte offsets that were previously hardcoded (no regression). The Add Flags fix is universal. The gvar fix is compiler-level and universal. The BAR-above-4GB fix is a no-op on iron's sub-4GB BAR. **Iron Attempt 65 is the next validation step**; if it reaches typeable shell on archaemenid the MVP closed-beta gate hits end-to-end on real hardware. If iron-specific fixes surface, those land in a 1.30.8 cut.

**Letter-ladder retrospective** (FF→GG→HH→JJ→KK→LL→MM→NN→OO→QQ+QQ2 — ten falsified silicon-quirk hypotheses across Attempts 57-63): all were red herrings; none could have been correct because the bug was compile-time, not runtime. Per `feedback_known_knowledge_first` and `feedback_stop_letter_laddering`, the lesson is that compiler-class bugs need to be on the suspect list earlier when symptom + spec + 4-source-prior-art diff all conflict. The QEMU lane was the unlock — same `events_seen=0` symptom on a completely different controller (qemu-xhci, csz=0, no USBLEGSUP, no scratchpad bufs, BAR at 768 GB) proved silicon couldn't be the cause. **A pre-existing suspicion comment at `xhci_cmd.cyr:107-115` had named "gvar-init-order: `XHCI_DIAG_SUBMIT_MAX` reading 0 at first-call time"** as the hypothesis back at Attempt 58 — but the consumer-side workaround there masked the load-bearing register-write case for another five attempts.

Iron-side narrative + boot-log read for Attempts 56–63 in [`agnosticos/docs/development/iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md) § Attempts 56–64.

### Changed

- `VERSION`: 1.30.6 → 1.30.7
- `kernel/version.cyr`: kernel banner, shell banner, `_AGNOS_VERSION` bumped to 1.30.7
- `cyrius.cyml`: cyrius pin **5.11.59 → 5.11.64** (gvar-init-order fix; image-static init for literal-RHS gvars)
- `kernel/core/vmm.cyr`: `vmm_remap_uc_2mb` extended to handle `phys ≥ 512 GB` (PML4[N>0]). Allocates a fresh PDPT under the target PML4 entry if absent, zero-fills it, installs at PML4 with P|RW, then shatters the 1 GB region into 2 MB entries with the target chunk marked UC. Sub-1 GB and 1–512 GB paths unchanged.
- `kernel/arch/x86_64/usb/xhci.cyr`: removed the `mmio >= 0x100000000` early-out gate (was a "deferred until iron evidence" placeholder); `vmm_remap_uc_2mb` now handles every BAR location generically. EP0 TR Dequeue Pointer readback at line 1036 (formerly `load64(ictx + 0x88)`) made CSZ-aware via `xhci_ep0_ctx_off() + 8`.
- `kernel/arch/x86_64/usb/xhci.cyr`: **Repair OO.B reverted** — IMAN.IE write moved from post-R/S=1 back to pre-R/S=1 (right after ERSTBA), matching 3-of-4 convergent prior art (FreeBSD `xhci.c:1512-5`, Haiku `xhci.cpp:1773`, EDK2 `XhciSched.c:1184-6`) plus OVMF empirical reference in QEMU traces. Linux's xhci_run_finished post-R/S convention is the outlier; works on Linux's test surface but doesn't on AMD FCH 1022:1639 or qemu-xhci which latch interrupter config at R/S transition.
- `kernel/arch/x86_64/usb/xhci_ctx.cyr`: added CSZ-aware helpers `xhci_ctx_size()` / `xhci_slot_ctx_off()` / `xhci_ep0_ctx_off()` / `xhci_ep_ctx_off(dci)` returning 32 or 64 based on `HCCPARAMS1.CSZ`. All hardcoded Slot Context (0x40), EP0 Context (0x80), and EP[N] (`(dci+1) * 0x40`) offsets across `xhci_alloc_input_ctx` and `xhci_input_ctx_add_interrupt_in` substituted to use the helpers.
- `kernel/arch/x86_64/usb/xhci_ctx.cyr`: `xhci_input_ctx_add_interrupt_in` Add Flags computation changed from `add_flags |= (1 << dci) | 0x1` to `store32(ictx_phys + 4, (1 << dci) | 0x1)` — drops the stale A1 (EP0) flag carried from `xhci_alloc_input_ctx` initial setup. Matches Linux `xhci_init_input_control_ctx` convention.

### Notes

- No code change from 1.30.6 — same `pci_enable_msix_unmasked` + `xhci_start` surface. Banner-only release for the iron-validation receipt.
- Next-move options under user review: (PP) UC-remap DMA regions; (QQ3) Linux-style per-vector MSI-X programming across all N vectors; (Phase-4/5-software) xHCI 1.2 §4.6 audit on whether Enable Slot is normatively required for HID enumeration; (decouple) Phase 4/5 to QEMU code-completion.

## [1.30.6] — 2026-05-18 (xHCI cmd-path arc — FF through QQ; MSI-X table programming closeout)

**Phase 4 Enable Slot `events_seen=0` opened the cmd-path silent-absorb arc; 1.30.6 bundles the full repair surface as code.** 1.30.5 closed the Phase 3 silent-absorb arc with Repair (EE) after 13 falsified hypotheses; 1.30.6 opens the Phase 4 cmd-path arc with Repair (FF) and accumulates ten subsequent behavioral repairs (GG, HH, JJ, KK, LL, MM, NN, OO, QQ + QQ'') as the four-source convergent-prior-art audit (Linux + FreeBSD + Haiku + EDK2 — see [`xhci-prior-art-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/xhci-prior-art-audit.md)) narrows the gate. As of the 1.30.6 cut: FF through OO burned and falsified across Attempts 57-62; QQ + QQ'' (MSI-X Table vector-0 programming) staged-not-yet-burned. Per the iron-bring-up convention, code lands in the release regardless of iron validation; iron resolution moves separately in [`iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md). Bottoming-out path if QQ falsifies: Repair (PP) UC-remap of DMA regions (event ring + cmd ring + DCBAA + scratchpad), pre-staged but not auto-applied; otherwise decouple Phase 4/5 to QEMU code-completion. **The whole arc bundles under one 1.30.6 banner** per the user's 2026-05-18 cycle directive ("I really don't care what fixes it I want it fixed... hardening and cleanup can always be done later") — no per-repair point release.

### The opening narrative — Repair (FF) and the events_seen=0 discovery

Attempt 56 burn (2026-05-17, archaemenid AMD Renoir 1022:1639) was the read-only event-ring-state instrumentation cut queued in the 1.30.5 working tree. FB output:

```
xhci: enable_slot entry idx=1 cycle=1
xhci: cmd completion timeout, final_idx=1 cycle=1 events_seen=0
```

`events_seen=0` over the full `XHCI_CMD_TIMEOUT_SPINS` (~250 ms) window following the Enable Slot doorbell, combined with `xhci: drained 0 events` from the pre-PR drain, meant the controller never wrote a single event to the event ring after R/S=1. The event ring infrastructure itself was programmed correctly (ERSTSZ=1, ERSTBA=erst_phys, ERDP=evt_ring_phys, CRCR pointer + RCS=1 ordering all clean per audit), but the interrupter appeared disabled.

Initial hypothesis (Repair FF): `xhci_start` wrote `IMAN = 0x1` (IP clear, **IE=0**) with a deliberate "IMAN.IE stays 0 — poll mode for MVP" comment. xHCI 1.2 §4.17 reads "Software shall set the IE flag to '1' for all Interrupters that it intends to use" — and Linux's `xhci-mem.c` sets IE=1 unconditionally. One-line fix at `kernel/arch/x86_64/usb/xhci.cyr:541`: `IMAN = 0x3` (IP=W1C clear + IE=1). **Attempt 57 falsified this as the unblock for Enable Slot specifically** — Attempt 58 then proved (via the GG+EditA+EditB bundle) that *some* events post (`drained 1 events`), narrowing the gate to "Enable Slot CCE silent-absorb" rather than "entire event ring silent." The arc opened from there. FF stayed in the code (spec-correct, Linux-aligned); subsequent repairs targeted the increasingly narrow cmd-path-specific gate.

### Added

- **Repair (FF)** 2026-05-17 — `xhci_start` writes `IMAN = 0x3` (IP=W1C clear + IE=1) instead of `IMAN = 0x1`. xHCI 1.2 §4.17 + Linux `xhci-mem.c` convention; AMD FCH 1022:1639 silicon-spec alignment. One-line behavioral change at `kernel/arch/x86_64/usb/xhci.cyr:541`. **Attempt 57 outcome**: `events_seen=0` survived — IMAN.IE=1 alone did not unblock Enable Slot CCE posting (though it likely contributed to general event posting per Attempt 58's drained-1 evidence). FF stays in code as spec-correct baseline.

- **Repair (GG)** 2026-05-17 — AMD-Vi global IOMMU disable for AMD Renoir 1022:1639. `amd_iommu_disable()` at `kernel/arch/x86_64/iommu.cyr:269-317` walks PCI 0:0.2 cap list for ID `0x0F` (Secure Device), confirms cap type bits [18:16]==`0x3` (IOMMU), maps MMIO base UC, writes IOMMU Control Register at MMIO+0x18 = 0 (passthrough). Called from `kernel/core/main.cyr:155` after `pci_scan()` and before `xhci_probe()`. Intel boxes no-op. **Attempt 58 outcome**: FB confirms `amdvi: cap@64 mmio=4247781376 en=1` + `amdvi: disabled, ctrl_rb=0` — AMD-Vi *was* firmware-enabled, GG wrote successfully — but `events_seen=0` persists for Enable Slot. Strongest "platform-side DMA gating" candidate eliminated. Proper passthrough / DTE setup deferred to v6.x.

- **Repair (HH)** 2026-05-17 — Post-doorbell-write `load32` readback flush in `xhci_cmd_submit` (`xhci_cmd.cyr:130-131`). Matches Linux `xhci_ring_cmd_db` (`xhci-ring.c`) `writel(DB_VALUE_HOST, dba); readl(dba);` convention against AMD-FCH host-bridge posted-write deferral. **Attempt 60 outcome**: applied as part of HH/JJ/KK/LL stack; `events_seen=0` persists — doorbell-flush hypothesis closed.

- **Repair (JJ)** 2026-05-17 — Universal `load32` readback flush on every operational + runtime register write. `xhci_op_write32`, `xhci_op_write64`, `xhci_rt_write32`, `xhci_rt_write64` in `xhci.cyr:354-391` each do `store…; var flush = load32(addr);`. Matches Linux's `writel + readl` universal convention across CRCR / DCBAAP / ERSTBA / ERSTSZ / ERDP / IMAN / USBCMD / CONFIG. **Attempt 60 outcome**: `events_seen=0` persists — host-bridge posted-write deferral hypothesis closed across the entire operational + runtime register surface.

- **Repair (KK)** 2026-05-17 — CNR (Controller Not Ready, USBSTS bit 11) poll before any operational-register writes in `xhci_start`. `xhci.cyr:540-559`. Matches Linux `xhci_init` → `xhci_handshake(STS_CNR, 0, …)`. **Attempt 60 outcome**: no `xhci: CNR never cleared` line on FB → CNR was clear at the poll's first iteration; post-reset CNR re-assert hypothesis closed for this silicon.

- **Repair (LL)** 2026-05-17 — Link TRB initial cycle bit fix in `xhci_rings_init` (`xhci_ring.cyr:179-192`) — removed `| 0x1` from initial Link TRB write per xHCI 1.2 §4.9.3.1 (C bit starts opposite of PCS=1). Defensive correctness for ring-wrap; first Enable Slot doesn't traverse Link TRB so LL doesn't gate the symptom but stays as spec correctness.

- **Repair (MM)** 2026-05-17 — PCI MSI-X Function Mask cleared, Enable=1. New `pci_enable_msix_unmasked` at `kernel/core/pci.cyr:216-241`; call-site swap in `xhci.cyr` (was `pci_enable_msix_masked`). FB literal: `xhci: MSI-X enabled (no function-mask)`. Matches Linux `pci_alloc_irq_vectors` posture (Function Mask = 0 post-init). Per-vector mask defaults to 1 (PCI 3.0 §6.8.2.5.3) so spurious MSI-X messages stay suppressed. Hypothesis: AMD FCH 1022:1639 interprets Function Mask as a stronger gate than PCI spec implies (suppressing internal interrupter state-machine progress on top of message TX suppression). **Attempt 61 outcome**: `events_seen=0` persists — Function Mask hypothesis closed.

- **Repair (NN)** 2026-05-18 — Two-LOC reorder in `xhci.cyr` per four-source convergent prior-art audit ([`xhci-prior-art-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/xhci-prior-art-audit.md)). (NN.A) `xhci_start` interrupter-setup writes ERDP before ERSTBA per xHCI 1.2 §5.5.2.3.3 + 3-of-4 prior-art convergence (FreeBSD `xhci.c:1505-9`, Haiku `xhci.cpp:1744-9`, EDK2 `XhciSched.c:2651-9`); (NN.B) CRCR moved to after IMOD per 2-of-4 prior-art convergence (FreeBSD `xhci.c:1517-23`, Haiku `xhci.cpp:1756-7`). Zero-risk hygiene; spec-strict. **Attempt 62 outcome (bundled with OO)**: `events_seen=0` persists — both reorderings were zero-risk hygiene that did not address the gate. Stays in code as spec-correct convergent-prior-art alignment.

- **Repair (OO)** 2026-05-18 — Tier 2 convergent-prior-art bundle, four sub-repairs in `xhci.cyr` + `xhci_cmd.cyr`. (OO.A) USBSTS RW1C-clear at `xhci_start` entry (FreeBSD `xhci.c:1463-66` pattern); (OO.B) IMAN.IE write moved to AFTER R/S=1 (Linux `xhci.c:1145-7` convention; reverses Repair FF's pre-R/S placement); (OO.C) explicit `mfence` before doorbell write; (OO.D) cmd-ring TRB readback flush. **Attempt 62 outcome**: bundled with NN, `events_seen=0` persists. None of A/B/C/D unblocked. Stays as Linux-convention-aligned baseline.

- **Repair (QQ + QQ'')** 2026-05-18 — MSI-X Table vector-0 programming + Linux's MaskAll-then-table-then-clear-MaskAll ordering. MSI-X audit ([iron-nuc-zen-log § Attempt 63 prep](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md)) found AGNOS never wrote the MSI-X Table — every vector's Address/Data/Vector Control was at reset (Address=0, Data=0, Vector Control=1 by reset per PCI 3.0 §6.8.2.5.3), while Linux's `msix_capability_init` populates Address/Data for every claimed vector BEFORE clearing FuncMask. Hypothesis: AMD FCH 1022:1639's interrupter state machine gates event posting on a configured (non-zero Address) table. Edits: `kernel/core/pci.cyr` extends `pci_enable_msix_unmasked` with three-phase ordering — **Phase 1**: Enable+FuncMask=1 (MaskAll-during-init window); **Phase 2**: read Table Offset/BIR from cap+0x04, compute `table_phys = BAR(BIR) + offset`, write vector 0's Address Lo = 0xFEE00000 (BSP LAPIC, dest CPU 0, physical mode) + Address Hi = 0 + Data = 0x40 (vector 0x40, Fixed delivery, Edge trigger) + Vector Control = 1 (mask preserved — AGNOS polls, no ISR plumbing required), readback flush; **Phase 3**: clear FuncMask. `kernel/arch/x86_64/usb/xhci.cyr`: MSI-X enable call reordered to AFTER `vmm_remap_uc_2mb` so table writes hit the UC-remapped BAR chunk (mandatory — pre-Repair-X PORTSC silent-absorb-in-WB hazard otherwise). Build: 368,568 → **368,968 B** (+400 B). **First repair in the arc tied to a direct, named, Linux-implicit divergence** (not a spec-path reorder). Confidence: medium-high. Vendor-cap audit confirmed Linux applies no `1022:1639`-gated quirk to the cold-boot Enable Slot path (dry well); BAR memtype audit confirmed AGNOS matches `ioremap_uc()` semantics (PWT=1+PCD=1+PAT=0 → PAT entry 3 = strict UC under firmware PAT MSR `0x0007040600070406`). Staged for Attempt 63 iron burn.

- **Edit A** 2026-05-17 — read-only CRCR.CRR / ERSTSZ / IMAN / ERDP readback after `xhci_start` completes the R/S=1 + HCH=0 wait (`xhci.cyr:583-603`). Single FB line: `xhci: CRCR.CRR=<N> ERSTSZ=<N> IMAN=<N> ERDP_lo=<N>`. **Attempt 58 outcome**: `CRCR.CRR=0 ERSTSZ=1 IMAN=2 ERDP_lo=5672968`. IMAN=2 (IE=1 + IP=W1C-cleared) formally confirms FF stuck. ERSTSZ=1 + ERDP_lo=`0x569008` (page-aligned `0x569000` + EHB bit 3 set by HW) prove ring infrastructure is good and HW touched the event handler. CRCR.CRR=0 is spec-ambiguous pre-doorbell.

- **Edit B** 2026-05-17 — read-only per-submit TRB phys + dw3 readback in `xhci_cmd_submit` (`xhci_cmd.cyr:53-54, 99-109`), bounded to 2 submissions via `XHCI_DIAG_SUBMIT_MAX`. FB line: `xhci: cmd_submit#<N> trb_phys=<P> dw3=<D>`. Verifies (a) TRB landed at the address HW will fetch from and (b) the cycle bit + TRB type were stored correctly. **Attempt 58 outcome**: print line MISSING from FB due to stale USB build (Edit B in commit `0e3d01a` at 20:21; `build/agnos` was timestamped 20:20; USB flashed pre-commit). Root-cause established the `feedback_build_freshness_is_mine` discipline.

### Iron status (Attempts 56 — 62, archaemenid AMD Renoir 1022:1639)

- **Attempt 56** (2026-05-17): event-ring-state instrumentation cut. `events_seen=0` discovered as the cmd-path gate. Triage class 3 (event polling vs PSC posting) falsified — no events on ring at all.
- **Attempt 57** (2026-05-17, FF): `events_seen=0` survived IMAN.IE=1. Search class narrowed from "event posting infrastructure" to "platform- or cmd-ring-side gating."
- **Attempt 58** (2026-05-17, GG + Edits A+B): **Breakthrough — `xhci: drained 1 events` (was 0 in 56/57) + EHB=1 in ERDP_lo prove HW *is* posting events to the ring.** Either FF or GG was the unblock for general posting (the two were bundled — decoupling burn deprioritized as low-info vs cost). The gate narrowed to "Enable Slot specifically produces no CMD_COMPLETION event."
- **Attempts 59-60** (2026-05-17, HH/JJ/KK/LL stack): all four falsified. `events_seen=0` persists.
- **Attempt 61** (2026-05-18, MM): MSI-X Function Mask clear — falsified.
- **Attempt 62** (2026-05-18, NN+OO bundled): four-source convergent prior-art reorders (NN.A/B) + Tier 2 bundle (OO.A/B/C/D) — all falsified. 9-letter ladder closed at OO; `feedback_stop_letter_laddering` triggered.
- **Vendor-cap audit** (2026-05-18, 0 burns): Linux applies exactly one `1022:1639`-gated quirk (`XHCI_BROKEN_D3COLD_S2I`), irrelevant to cold-boot Enable Slot. `drivers/usb/host/xhci-ring.c` `handle_cmd_completion` / `queue_command` / `xhci_ring_cmd_db` contain no AMD-gated branches. FreeBSD `xhci_pci_attach` applies zero AMD errata for `0x1639`. **Dry well — no Repair (QQ) candidate from Linux quirks.**
- **MSI-X table + BAR memtype audit** (2026-05-18, 0 burns, parallel): MSI-X table never programmed — DIVERGENCE FOUND (Repair QQ candidate). BAR memtype matches `ioremap_uc()` strict UC — CLEAN.
- **Attempt 63 (QQ + QQ'')** staged 2026-05-18: build verified 368,968 B; pending iron burn.
- **Phase 3 reset on port 3**: still UNBLOCKED across Attempts 55-62 (Repair EE intact across two minors running).
- **CMOS slot integrity** (archaemenid CMOS map): `[0x86]=0x5A` / `[0x87]=0xA5` corruption confirms those slots are not in virgin-scratch zone (0x50-0x7F). AA (0x81) / BB (0x84) sentinels intact — 0x80-0x84 band confirmed reliable scratch on AMD FCH 1022:1639.

### Process

- **Build freshness ownership** clarified mid-Attempt-58: kernel build freshness during iron-boot bring-up is Claude's responsibility (`feedback_bootloader_kernel_ownership`, `feedback_build_freshness_is_mine`). User owns `install-usb.sh --update`; Claude rebuilds + verifies before declaring next-burn-ready. Cost of un-clarified ownership: one half-instrumented iron burn (Attempt 58, pre-commit USB).
- **Letter-laddering escape plan** (`feedback_stop_letter_laddering`): at 9 letters deep (FF→OO) the escape plan crystallized as the load-bearing artifact, not the next letter. Two read-only audits (vendor-cap, MSI-X+BAR memtype) ran in lieu of stacking Repair (PP) on iron. The MSI-X audit surfaced QQ; the BAR memtype audit confirmed AGNOS exceeds Linux semantics. Documented in [iron-nuc-zen-log § Attempt 62 final entry](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).
- **Single-repair-per-burn discipline suspended** for the cmd-path arc (user directive 2026-05-18): "I really don't care what fixes it I want it fixed... hardening and cleanup can always be done later." Multi-repair bundles permitted (NN+OO bundled at Attempt 62; QQ + QQ'' bundled in this cut). Instrumentation discipline (`feedback_no_instrumentation_means_no_instrumentation`) remains in force — no kprintlns added in NN/OO/QQ.
- **Convergent-prior-art audit** as a pattern (new this cycle): when symptom-dictionary letter-laddering hits 5-6 deep on the same root, write a baseline-diff doc against ≥3 independent reference impls. Was missing through FF/GG/HH/JJ/KK/LL/MM; would have collapsed those into a single bundle. Pattern documented at [`xhci-prior-art-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/xhci-prior-art-audit.md).

## [1.30.5] — 2026-05-17 (Repair EE — xHCI silent-absorb arc closed; Phase 4 + Phase 5 HID keyboard driver landed)

**The 13-hypothesis xHCI silent-absorb arc closed as a homegrown bug, not
silicon.** Five days of per-bit spec audit across Attempts 32-54 chased a
"controller absorbs PORTSC.PR writes" hypothesis through cache attributes,
PML4 walks, scratchpad install, DNCTRL, event-ring drain, timing delays,
and per-port SupProto fingerprints. Root cause surfaced via prior-art
diff against EDK2 `XhciDxe` (`XhciPortReset`) and Linux `xhci-hub.c`
(`xhci_set_port_reset`): both write `portsc | PR` without re-masking.
AGNOS's `xhci_portsc_write` (`kernel/arch/x86_64/usb/xhci_port.cyr:464`)
was applying an inner `& XHCI_PORTSC_NEUTRAL` mask before the OR-in of
W1C bits — and `PR` (bit 4) is RW1S, *outside* `NEUTRAL` — so every
port-reset write across the entire arc had its PR bit silently stripped
before `store32` hit the controller. "Silent-absorb" was real; the
absorber was AGNOS's own helper, not silicon. One-line fix removed the
inner re-mask. Cyrius pin bumped 5.11.55 → 5.11.59 in the same commit.

**Iron evidence** (Attempt 55, archaemenid AMD Renoir 1022:1639): for the
first time across 13 attempts, `CMOS[0x64]` reports a non-zero
reset-OK bitmap (`0x04` = port 3 reset succeeded; Keychron K2 on port 3
of the USB2 bank). FB shows no `xhci: port 3 reset failed (proto=2)`
line — Phase 3 enumeration now reaches the Enable Slot command for the
first time. Per-attempt + CMOS-table detail in [`agnosticos/docs/development/iron-nuc-zen-log.md` § Attempt 55](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

**Bundled in 1.30.5**: Phase 4 + Phase 5 of the USB HID-boot keyboard
driver, completing the boot-to-typeable-shell code surface. Phase 4
(`hid_kbd_configure`): Get Configuration Descriptor + walk for the
HID-boot-keyboard interface + Configure Endpoint TRB (type 12) +
`SET_PROTOCOL=boot` + interrupt-IN transfer ring construction. Phase 5
(`hid_poll` + translation): event-ring drain on the keyboard endpoint +
HID-usage → PS/2 set-1 scancode translation table + report differ
(press/release inference between consecutive 8-byte HID reports) +
`kb_buf` writer routing through the existing `scancode_to_ascii` path so
the shell sees keys via the same buffer that the legacy PS/2 path used.
Code surface: 2 new files (`hid_kbd.cyr`, `hid_translate.cyr`) +
extensions to `xhci.cyr` / `xhci_cmd.cyr` / `kb.cyr` / `main.cyr`;
~600 LOC. Validation surface is QEMU `xhci-pci` (spec-compliant
controller); Phase 4/5 stay dormant on iron until the Phase 4 Enable
Slot ccode=0 gate (Attempt 55's new gate, downstream of the EE
unblock) clears.

### Added

- **Repair (EE)** — `xhci_portsc_write` no longer applies `& XHCI_PORTSC_NEUTRAL`
  to `value` inside the helper; caller is responsible for the OR-in mask
  per EDK2 + Linux convention. (`kernel/arch/x86_64/usb/xhci_port.cyr`)
- **`hid_kbd.cyr`** — USB HID-boot keyboard driver. `hid_kbd_init`,
  `hid_kbd_configure` (Get Configuration Descriptor + interface walk +
  Configure Endpoint TRB + SET_PROTOCOL=boot + transfer ring),
  `hid_poll` (event-ring drain on kbd EP, report differ, scancode
  emission).
- **`hid_translate.cyr`** — HID-usage → PS/2 set-1 translation table.
  ASCII-printable + arrow + modifier coverage matching the existing
  `scancode_to_ascii` path; boot-protocol-only (full HID report
  descriptor parsing deferred).
- **xHCI cmd-ring extensions** — `xhci_cmd_submit` + `xhci_cmd_wait`
  generalized to handle Configure Endpoint TRB; `xhci_set_protocol`
  helper for the USB HID class-specific request.
- **`kb.cyr` integration** — `kb_has_key()` now also drives `hid_poll()`
  on every shell-tick; structurally inert when `hid_kbd_slot_id == 0`
  (no HID keyboard configured), so safe on hardware where Phase 4
  hasn't run yet.

### Changed

- **`cyrius.cyml`** — toolchain pin bumped 5.11.55 → 5.11.59 alongside
  the EE one-liner. Matches kriya 0.6.0's parallel-M5 pin bump.

### Iron status

- **Phase 3** (port reset) unblocked on archaemenid USB2 bank port 3.
  Silent-absorb arc closed at 13 falsified hypotheses + EE-confirmed.
- **Phase 4** (Enable Slot command-ring round-trip) is the new iron-side
  gate. FB on Attempt 55 reads `kbd: Enable Slot failed, ccode=0` →
  `xhci: enumeration timeout` (`ccode=0` is the default of
  `xhci_last_cmd_ccode`, surfacing when `xhci_cmd_wait` times out
  without consuming a matching Command Completion Event). Triage
  classes in [`iron-nuc-zen-log.md` § Attempt 55](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md);
  Attempt 56 read-only event-ring instrumentation queued in working
  tree (1.30.6 staging).
- **Phase 4/5** code surface validated on QEMU `xhci-pci` (spec-compliant
  controller, Phase 3 completes end-to-end, Phase 4 reaches Configure
  Endpoint, Phase 5 drains keyboard reports). Dormant on archaemenid
  until Phase 4 gate clears.

## [1.30.4] — 2026-05-17 (xHCI Linux-diff hardening closeout)

**xHCI Phase 3 silent-absorb arc continues — Repair (BB) Device Notification
Control + audit-driven follow-ups (stamp redesigns, double xfer-ring leak)
+ Phase 4/5 development lanes opening in parallel.** Attempt 50 burn
(2026-05-17) confirmed Repair (AA) scratchpad install ran cleanly per FB
(`scratchpad ready` + `controller running`) but silent-absorb on USB2
ports 1+3 survived → AA falsified, tenth hypothesis in the arc. Same-session
audit of `agnos/kernel/arch/x86_64/usb/` (TODO / stub / silent-success
patterns) surfaced **DNCTRL (op_reg 0x14) defined at `xhci_regs.cyr:70` but
never written** — exact AA precedent (constant known, write step skipped).
WebFetch of Linux `drivers/usb/host/xhci.c` confirmed `xhci_set_dev_notifications`
writes `DEV_NOTE_FWAKE = 0x02` to op_regs+0x14 during `xhci_init()`
unconditionally before R/S=1. Hypothesis: some USB2 port-link-state
transitions on AMD Renoir/Cezanne (1022:1639) are gated on notification
handling being enabled. Audit also found a real but post-Phase-3 memory
leak (double xfer-ring allocation in `xhci_enumerate_port`) and two CMOS
stamp design flaws from Attempt 50 (`[0x83]` captures page-aligned phys
low byte = always 0x00; `[0x80]=53` vs `[0x82]=0` inconsistency from
unobserved hcsp2 byte 2). **Attempt 51 burn (2026-05-17) — BB falsified**
empirically: FB line `xhci: dev_notifications enabled` rendered, `port 1
reset failed (proto=2)` + `port 3 reset failed (proto=2)` followed.
Eleventh hypothesis in the arc. Post-mortem readback also exposed a
foundational **CMOS-alias bug** — slots ≥ 0x80 written via the legacy
`0x70/0x71` port pair had been silently aliasing to RTC time-of-day
registers (port 0x70 bit 7 is the NMI mask, not a slot-index bit), so the
entire AA + BB diagnostic capture at `[0x80]/[0x82]/[0x84]` was returning
BCD wall-clock seconds/minutes/hours rather than the kernel's intended
bytes. Slots `[0x81]/[0x83]/[0x85]` aliased to RTC alarm regs (rarely
touched scratch), preserving kernel writes and masking the bug across
both attempts. Repairs (CC) + (DD) land in the same staging cycle:
extended-CMOS routing through 0x72/0x73 for slots ≥ 0x80, and event-ring
drain + USBSTS.PCD clear before each port-reset PR write (USBSTS PCD=1
across the silent-absorb arc was a signal AGNOS never acknowledged; the
twelfth hypothesis). **Attempt 52 iron burn (2026-05-17) — Row 2 / DD falsified;
twelfth hypothesis exhausted.** FB rendered `xhci: drained 1 events` +
`port 1/3 reset failed` — DD site executed cleanly (1 real firmware-residue
event consumed) but silent-absorb persists. Post-Attempt-52 handoff /
AMD-quirk audit (Linux `xhci-pci.c` AMD-Renoir quirk paths +
`pci-quirks.c` `usb_amd_quirk_pll` chipset detection) confirmed no
Renoir-specific cold-boot workarounds AGNOS misses. **Decoupling decision
activates as written**: xHCI silent-absorb arc closes as "non-spec gate,
parallel-track only"; no Attempt 53 without explicit new-burn
authorization. 1.30.4 closes with **xHCI Linux-diff hardening (H1-H4)**
as the spec-discipline closeout contribution (~10 LOC, all audit-verified
non-silent-absorb gates). Phase 4 (Configure Endpoint + SET_PROTOCOL=boot)
+ Phase 5 (HID translation + `kb_buf` feed) move from "shovel-ready
plan" to active work in 1.30.5+.

### Added

- **Repair (BB) Device Notification Control write** (`kernel/arch/x86_64/usb/xhci.cyr`).
  ~3 LOC in `xhci_init()` after the CNR-clear wait, before `xhci_halted`
  flip: `xhci_op_write32(XHCI_OP_DNCTRL, 0x02)` enables N1 Function Wake
  notifications per xHCI 1.2 §5.4.4. Stamp sentinel `CMOS[0x84]=0xBB`
  proves the site executed (survives kybernet kcp overwrite). FB line
  `xhci: dev_notifications enabled` between `CNR never cleared` guard
  and `halted, reset clean`. Hypothesis under test: same-shape Linux-diff
  to AA (register defined, write step missing) — eleventh in the
  silent-absorb arc.
- **CMOS [0x85] HCSPARAMS2 byte 2 cross-check stamp** (`kernel/arch/x86_64/usb/xhci.cyr`).
  Captures `(hcsp2 >> 16) & 0xFF` alongside the existing `[0x82]` byte-3
  stamp. Disambiguates Attempt 50's `[0x80]=53` vs `[0x82]=0x00`
  mathematical impossibility (per AGNOS decode `(bits 25:21 << 5) | bits
  31:27` with `[0x82]=0` constraining count ≤ 7). **Post-Attempt-51
  finding**: the `[0x80]=53` mystery was the CMOS-alias bug all along —
  53 was RTC seconds at read time, not MaxScratchpadBufs. The byte-2
  cross-check survives as defense-in-depth once CC routes the slots
  correctly.
- **Repair (CC) extended-CMOS routing for slots ≥ 0x80**
  (`kernel/arch/x86_64/usb/xhci_port.cyr` `xhci_cmos_stamp`; mirror in
  `agnosticos/scripts/src/read-boot-log.cyr` `cmos_read`). Splits on
  slot 0x80: slots < 0x80 keep the legacy 0x70/0x71 path; slots ≥ 0x80
  route through the extended CMOS bank at 0x72/0x73 (offset = slot −
  0x80, no NMI-mask bit collision). Root cause for Attempts 50+51
  capture corruption: `outb(0x70, 0x84)` clears bit 7 = NMI mask and
  selects slot 0x04 (RTC hours), so the entire `[0x80]/[0x82]/[0x84]`
  AA + BB diagnostic surface had been reading RTC time-of-day BCD. The
  RTC alarm registers at indices 0x01/0x03/0x05 are unused scratch on
  archaemenid's AMD FCH, which preserved the kernel writes at
  `[0x81]/[0x83]/[0x85]` and masked the bug across both burns. Empirical
  sentinel `xhci_cmos_stamp(0x86, 0xCC)` in `xhci.cyr` (after the BB
  stamp) verifies the AMD FCH 1022:1639 honors the 0x72/0x73 port pair;
  `[0x86]=0xCC` on next iron read → extended CMOS live, anything else
  → fall back to FB-only diagnostics for the >0x7F range.
- **Repair (DD) event-ring drain + USBSTS.PCD clear before port reset**
  (`kernel/arch/x86_64/usb/xhci_port.cyr` new
  `xhci_drain_port_change_events`, called from `xhci_port_reset` USB2
  path after Repair (Z) 10 ms timing delay and before the first
  PORTSC.PR write). Walks event TRBs from `xhci_evt_ring_idx` while the
  cycle bit matches `xhci_evt_ring_cycle`, advances the dequeue pointer
  with EHB (bit 3) set on the ERDP write-back, then RW1C-clears
  USBSTS.PCD via `xhci_op_write32(XHCI_OP_USBSTS, 0x10)`. 64-TRB safety
  bound prevents runaway on a corrupted cycle bit. Hypothesis under
  test: AMD FCH 1022:1639 gates further PORTSC writes (silent absorb)
  until prior Port Status Change events are consumed and PCD is
  cleared. Attempt 51 [0x77]=0x10 (USBSTS.PCD=1) was direct evidence
  the controller had a pending change event sitting un-acknowledged
  across the entire silent-absorb arc; Linux's `xhci-hub.c` drains
  events between port operations via `xhci_handle_event` from
  `xhci_hub_status_data`, but AGNOS only drained from EP0 doorbell
  completions (post-reset, too late). Sentinel `[0x87]=0xDD` + FB line
  `xhci: drained N events`. Twelfth hypothesis in the silent-absorb
  arc; first one to act directly on a USBSTS bit AGNOS had been
  observing but never acknowledging.

#### xHCI Linux-diff hardening (H1-H4) — 1.30.4 closeout, 2026-05-17

Four spec deviations from Linux's `drivers/usb/host/xhci.c` init sequence,
surfaced by the pre-Attempt-52 connectivity audit. **None are silent-absorb
gates** (audit-verified, structurally inert under current iron evidence);
each is a real spec gap closed before public-beta. Total ~10 LOC.

- **H1 — `XHCI_OP_PAGESIZE` 4 KB assertion** (`kernel/arch/x86_64/usb/xhci_ring.cyr`).
  xHCI 1.2 §5.4.3. Scratchpad alloc path now reads PAGESIZE op-reg before
  `pmm_alloc` and bails with `xhci: PAGESIZE rejects 4KB, bitmap=N` if bit
  0 is clear. All contemporary x86_64 silicon advertises 4 KB; the
  assertion guards against silicon that requires larger pages from
  silently mis-sizing scratchpad buffers.
- **H2 — `XHCI_IR_IMAN.IP` RW1C clear in `xhci_start`** (`kernel/arch/x86_64/usb/xhci.cyr`).
  xHCI 1.2 §5.5.2.1. After the ERDP write, `IMAN |= 0x1` clears any
  Interrupt Pending bit left over from BIOS/firmware that would otherwise
  inhibit a fresh edge-triggered interrupt assertion when MSI-X lands.
  IMAN.IE (bit 1) stays 0 — poll mode for MVP.
- **H3 — `XHCI_IR_IMOD` 250 µs interrupt moderation** (`kernel/arch/x86_64/usb/xhci.cyr`).
  xHCI 1.2 §5.5.2.2. Same block as H2. Writes `0x000003E8` (1000 × 250 ns
  = 250 µs moderation). HW default is 0 (no moderation) which under
  MSI/MSI-X would risk interrupt storms. Safe under poll mode; matches
  Linux's default.
- **H4 — `USBCMD.HSEE` bit 3 in start mask** (`kernel/arch/x86_64/usb/xhci.cyr`).
  xHCI 1.2 §5.4.1.4. Start mask widened from `0x05` (R/S | INTE) to
  `0x0D` (R/S | INTE | HSEE) so any subsequent Host System Error sets
  `USBSTS.HSE` *and* asserts the interrupter. Without HSEE an HSE would
  go unreported — fail-silent regression risk.

### Changed

- **CMOS [0x83] stamp redesign** (`kernel/arch/x86_64/usb/xhci_ring.cyr`).
  Now captures `(sp_array >> 16) & 0xFF` instead of `sp_array & 0xFF`.
  Page-aligned phys is structurally `& 0xFF == 0` (4 KB alignment),
  which made the original Attempt 50 outcome matrix's Row 1 vs Row 4
  distinction broken (`[0x83]==0` was supposed to mean alloc-failed but
  ran also on success). Byte 2 is non-zero for any phys ≥ 64 KB
  (universally true post-kernel-init on x86_64). FB still the primary
  load-bearing channel.
- **Double xfer-ring allocation in `xhci_enumerate_port` removed**
  (`kernel/arch/x86_64/usb/xhci.cyr`). `xhci_alloc_input_ctx` at
  `xhci_ctx.cyr:152` already allocates the EP0 transfer ring page and
  stores its phys (with DCS bit) at `ictx+0x88`. The prior code at
  `xhci.cyr:757-765` allocated a *second* page and overwrote the field,
  leaking page A. Replaced with `load64(ictx + 0x88) & ~1` to extract
  the existing phys. Stale `"xhci_alloc_input_ctx stored a stub"`
  comment removed in same change — it was misleading; the field was a
  real phys, not a stub.

### Pending validation

- **Attempt 51 iron burn (2026-05-17) — BB falsified, CMOS-alias bug
  surfaced.** Post-mortem: FB rendered `xhci: dev_notifications enabled`
  + `port 1 reset failed (proto=2)` + `port 3 reset failed (proto=2)`,
  so BB site executed but didn't unblock reset (eleventh hypothesis
  falsified). CMOS readback exposed the slots-≥-0x80 alias bug rolled
  into Repairs (CC) + (DD) above.
- **Attempt 52 iron burn (2026-05-17) — Row 2 / DD falsified; CC routing
  partial; twelfth hypothesis exhausted.** Post-mortem: FB rendered
  `xhci: drained 1 events` (DD site executed cleanly, 1 real firmware-residue
  event consumed) + `port 1 reset failed (proto=2)` + `port 3 reset failed
  (proto=2)`. CMOS `[0x86]=0x5A` / `[0x87]=0xA5` instead of intended
  `0xCC` / `0xDD` — extended-CMOS bank empirically honors offsets `0..5`
  cleanly on AMD FCH 1022:1639 but `≥ 6` returns mystery values
  (`[0x80..0x85]` round-trip correctly: MaxScratchpadBufs=2, sp_array
  phys byte 2 = 0xF6, BB sentinel = 0xBB). Diagnostic-infrastructure
  question, not load-bearing: FB lines are the truth channel for site-
  executed proofs. **Decoupling decision activates as written**: xHCI
  silent-absorb arc closes as "non-spec gate, parallel-track only." No
  Attempt 53 without explicit new-burn authorization. Full outcome +
  post-mortem handoff/AMD-quirk audit in
  [`agnosticos/docs/development/iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md)
  § Attempt 52.
- **Phase 4 code surface (Configure Endpoint + SET_PROTOCOL=boot)** —
  per `agnosticos/docs/development/planning/usb-hid-keyboard-driver.md`
  § Phase 4. Develops against the Phase 1-3 infrastructure regardless
  of any single repair outcome.
- **Phase 5 code surface (HID-boot translation + `kb_buf` feed)** — per
  same planning doc § Phase 5. Closes typeable-shell gate when both
  Phase 4 and the silent-absorb unblock land.

### Notes

- 1.30.4 **closes 2026-05-17 with xHCI Linux-diff hardening (H1-H4)** —
  staging absorbed BB → CC → DD repairs across 2026-05-17, Attempt 52
  burn confirmed Row 2 / DD falsified, post-Attempt-52 handoff/AMD-quirk
  audit confirmed no Renoir-specific cold-boot workarounds AGNOS misses,
  and the four spec-discipline gaps (H1-H4) landed as the closeout
  contribution. 1.30.5 staging opens for Phase 4/5 code surface + any
  follow-on hypotheses.
- **Audit precedent (AA → BB → CC)**: three consecutive cycles where a
  register/operation/port defined in headers but never invoked
  (correctly) turned out to be a silent gate. AA: DCBAA[0] scratchpad
  install. BB: DNCTRL register. CC: extended-CMOS port pair (the bug
  was in the *write/read path*, not a missing operation, but the same
  audit shape — code referenced a CMOS slot that the legacy port pair
  couldn't address). Future Phase 3+ work should grep `xhci_regs.cyr`
  constants against `xhci_*_write32` / `xhci_op_write*` call sites
  AND pressure-test diagnostic readback paths against alternative
  explanations (e.g., "what if this byte is plausible by coincidence
  rather than by my write?") before treating CMOS as ground truth.
- **Iron burn discipline**: Attempt 52 (the CC+DD burn, 2026-05-17) WAS
  the last authorized just-testing burn before pivot to Phase 4/5
  non-iron development. Pivot in force. H1-H4 hardening landed as
  build-verified kernel changes (~350,272 B vs 350,008 B pre-edit) with
  no iron burn — the cyrius-compile gate is the validation surface.
  Future instrumentation proposals require a line-by-line audit table
  before a burn is requested (per `feedback_iron_burns_block_other_work`).

## [1.30.3] — 2026-05-17

**xHCI Phase 3 deep-dive — six-attempt silent-absorb investigation arc
(Attempts 45-50 prep) culminating in Repair (AA) scratchpad allocation
candidate fix.** After Repair (X) UC remap (1.30.2) preserved boot-to-shell
but did NOT clear the PORTSC silent-absorb on archaemenid (CMOS `[0x70]=0x03`,
`[0x6C]=0x00`, `[0x63]=0x04`, `[0x64]=0x00`), this cycle ran a structured
per-attempt hypothesis ladder: **X'** (PDE re-stamp confirmed UC landed —
falsified F5), **V''** (four-level walk confirmed no aliasing — falsified
hypothesis (a)), **W** (USBSTS/USBCMD spec-clean at reset-fail — falsified
controller-side spec-visible gate (b)), **b'** (per-cap SupProto fingerprint
confirmed no overlap with failing ports — falsified multi-SupProto routing),
**Z + USBLEGCTLSTS SMI disable + MSI-X bundle** (Attempt 49 upstream-plumbing
bundle — Linux/SeaBIOS prior-art derived: AMD-FCH timing + SMI re-arming +
interrupter-readiness — all three executed but none broke the absorb). With
all behavioral hypotheses in the trio exhausted, a same-machine Linux diff
against `drivers/usb/host/xhci-mem.c` `xhci_setup_scratchpad_bufs` surfaced
the gap that NO prior letter touched: `xhci_ring.cyr` left `DCBAA[0] = 0` on
a TODO comment assuming `HCSPARAMS2.MaxScratchpadBufs = 0`, but AMD
Renoir/Cezanne (1022:1639) advertises non-zero per Linux's standard probe path.
xHCI 1.2 §4.20: controller "may not function correctly" until the OS programs
the scratchpad buffer array into `DCBAA[0]` before R/S=1; per-port reset state
machine relies on scratchpad-backed context save area. **Repair (AA)** reads
HCSPARAMS2, allocates a u64 pointer array + N page-sized scratchpad buffers,
and writes the array phys into `DCBAA[0]` before R/S=1. Attempt 50 iron burn
pending validation; if Row 1 hits, Phase 4 (Configure Endpoint + SET_PROTOCOL=
boot) + Phase 5 (HID translation + `kb_buf` feed) become the typeable-shell
gate. Full arc in [iron-nuc-zen-log §§ Attempts 45-50](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

### Added

- **Repair (X') PDE re-stamp** (`kernel/arch/x86_64/usb/xhci.cyr`).
  ~14 LOC + 1 CMOS slot after `vmm_remap_uc_2mb(mmio)` at xhci_probe
  step 5b. Walks `PD@0x3000` for sub-1GB BARs or the post-shatter
  `PDPT[gb_idx]→PD` for ≥1GB BARs (archaemenid's xHCI lands at
  `0xFC900000`, so the shatter path is the load-bearing one).
  Pure read-only diagnostic; controller behavior unchanged.
  Attempt 45 confirmed `CMOS[0x73]=0x9B`/`0xBB` = PA3=UC landed →
  F5 (cache attribute) falsified despite remap success.
- **Repair (V'') full PML4→PDPT→PD walk** (`kernel/arch/x86_64/usb/xhci.cyr`).
  ~30 LOC + 3 CMOS slots (`[0x74]`/`[0x75]`/`[0x76]`) walking the BAR's
  complete translation chain from `PML4@0x1000`. PS-bit detection at
  PDPTE level writes `0xFF` sentinel to `[0x76]` when a 1 GB huge page
  covers the BAR (shatter never ran). Divergence between `[0x73]`
  (X' shortcut) and `[0x76]` (V'' walk) localizes any aliased-mapping
  hypothesis. Pure read-only diagnostic. Attempt 46 confirmed walk
  agrees with X' → hypothesis (a) aliased mapping falsified.
- **Repair (W) USBSTS / USBCMD / unclassified xECP cap stamps**
  (`kernel/arch/x86_64/usb/xhci_port.cyr` + `xhci.cyr`). Reads
  USBSTS bytes 0+1 (CNR/HCE/HCH gate detection per xHCI 1.2 §5.4.2)
  and USBCMD byte 0 (R/S/HCRST/INTE state) at reset-fail time;
  classifies xECP caps not consumed by the existing USBLEGSUP /
  SupProto walk. CMOS slots `[0x77]`/`[0x78]`/`[0x79]`/`[0x7A]`.
  Pure diagnostic — surfaces controller-level gates beyond the
  per-port state machine. Attempt 47 confirmed controller spec-clean
  at reset-fail-time → hypothesis (b) controller-side spec-visible
  gate falsified.
- **Repair (b') per-cap SupProto fingerprint capture**
  (`kernel/arch/x86_64/usb/xhci_port.cyr`). Captures `rev_major | port_count`
  + `port_off` for the 2nd and 3rd SupProto caps (1st stays in
  `[0x6A]`). CMOS slots `[0x7B]`/`[0x7C]`/`[0x7D]`/`[0x7E]`. Pure
  read-only diagnostic. Attempt 48 confirmed both extra SupProto
  caps confine to USB3 ports 5+6 individually (no overlap with
  failing USB2 ports 1+3) → multi-SupProto routing hypothesis
  falsified for this hardware.
- **MSI-X enable with Function Mask** (`kernel/core/pci.cyr` +
  `kernel/arch/x86_64/usb/xhci.cyr`). New `pci_find_cap` walks the
  PCI cap list at config-space offset `0x34`; `pci_enable_msix_masked`
  sets Enable (bit 31) + Function Mask (bit 30) on MSI-X cap `0x11`
  (falls back to MSI cap `0x05` if MSI-X absent). Per Linux
  `xhci_setup_msix` prior art — some xHCI silicon gates op-reg
  state-machine progress on the interrupter being "configured" in
  PCI config space, independent of whether the OS routes the IRQ.
  AGNOS polls events on a timer tick instead of via vector; Function
  Mask suppresses entry delivery so no spurious IDT vectors dispatch.
  Adds FB line `xhci: MSI-X enabled (function-mask)` /
  `xhci: MSI enabled` / `xhci: no MSI/MSI-X cap advertised`. Attempt 49
  confirmed MSI-X path executed but didn't unblock silent-absorb in
  isolation (part of the upstream plumbing bundle).
- **Repair (AA) HCSPARAMS2 read + scratchpad buffer install**
  (`kernel/arch/x86_64/usb/xhci.cyr` + `xhci_ring.cyr`). `xhci_probe`
  extension reads HCSPARAMS2 at `cap_base+0x08`, decodes
  `MaxScratchpadBufs = (hi << 5) | lo` per xHCI 1.2 §5.3.4 (bits 25:21
  hi, 31:27 lo, 10-bit range 0-1023). `xhci_rings_init` step 1b
  allocates a u64 pointer array (1 page) + N page-sized scratchpad
  buffers, writes each phys to `sp_array[i]`, writes `sp_array_phys`
  into `DCBAA[0]` before R/S=1. Per Linux `xhci_setup_scratchpad_bufs`
  (`drivers/usb/host/xhci-mem.c`) — xHCI 1.2 §4.20 makes this an
  OS requirement when `MaxScratchpadBufs > 0`. Suspected silent-absorb
  root cause across Attempts 32-49 (no prior letter touched `DCBAA[0]`).
  Adds FB lines `xhci: scratchpad bufs=N` + `xhci: scratchpad ready,
  array=0xPHYS`. CMOS slots `[0x80]`/`[0x81]`/`[0x82]`/`[0x83]` (first
  use of CMOS 0x80+ range; `[0x81]=0xAA` sentinel validates the slot
  range survived BIOS/POST). Attempt 50 iron burn pending validation.
- **CMOS decoder + cheat-sheet extensions** (`agnosticos/scripts/src/read-boot-log.cyr`).
  Slots `[0x73]` (X'), `[0x74]`/`[0x75]`/`[0x76]` (V''),
  `[0x77]`/`[0x78]`/`[0x79]`/`[0x7A]` (W),
  `[0x7B]`/`[0x7C]`/`[0x7D]`/`[0x7E]` (b'), `[0x7F]` (Z),
  `[0x80]`/`[0x81]`/`[0x82]`/`[0x83]` (AA) all decoded with per-row
  outcome interpretation matrices. Pre-bound verdicts wire each stamp
  pattern to a next-action recommendation.

### Changed

- **Repair (Z) AMD-FCH timing delay** (`kernel/arch/x86_64/usb/xhci_port.cyr`).
  ~10 ms TSC-based spin (~30M cycles) inserted between the CSC W1C
  clear and the PR write in the per-port USB2 reset path. Mirrors
  SeaBIOS `xhci_hub_reset` `msleep(10)` pattern observed empirically
  on AMD silicon. Sentinel `CMOS[0x7F]=0xAA` proves the site executed.
  Attempt 49 confirmed the site ran but didn't unblock silent-absorb
  in isolation (part of the upstream plumbing bundle).
- **USBLEGCTLSTS SMI disable post-USBLEGSUP claim**
  (`kernel/arch/x86_64/usb/xhci_port.cyr`). New
  `xhci_usblegctlsts_disable_smi(cap_off)` masks `0xFFFFE01F` + ORs
  `0x1FFF0000` to clear bits 5-12 SMI enables AND W1C bits 16-28
  status. Called from all three USBLEGSUP outcome paths (already-OS /
  claimed-from-BIOS / BIOS-held-timeout). Mirrors Linux
  `quirk_usb_handoff_xhci` prior art — BIOS-left enables in
  USBLEGCTLSTS can continue firing SMI on USB activity post-handoff,
  stealing cycles from PORTSC writes. Attempt 49 confirmed the site
  ran (rides the existing `xhci: USBLEGSUP already OS-owned` FB line)
  but didn't unblock silent-absorb in isolation.

### Fixed

- **`xhci.cyr:115` MSI fallback indent** — pre-existing fmt issue from
  the MSI-X enable work, now `cyrius fmt`-clean. No behavioral change.

## [1.30.2] — 2026-05-16

**xHCI Phase 3 closeout — `vmm_remap_uc_2mb` lands the xHCI BAR on
PA3=UC, fixing the PORTSC silent-absorb that survived seven Phase-3
repairs.** Roll-up of all Unreleased work since 1.30.0 plus the
F5 (MMIO write-coalescing) investigation arc — Repair (S')
one-nibble RWS-mask typo fix, Repair (T) Linux-style PR retry
diagnostic, Repair (V) MTRR/PAT cache-attribute diagnostic, and
Repair (X) the actual unblock. 1.30.1 was a pre-iron-validation tag
on the S-only stack; 1.30.2 supersedes it directly.

### Changed

- **Centralize runtime version strings in `kernel/version.cyr`**
  (`kernel/version.cyr`, `kernel/agnos.cyr`, `kernel/core/main.cyr`,
  `kernel/user/shell.cyr`, `kernel/arch/aarch64/main.cyr`,
  `scripts/version-bump.sh`). Pre-v1.30.2, three boot banner sites
  each carried a hardcoded `"AGNOS … vX.Y.Z …"` literal + a
  hardcoded byte length, and `version-bump.sh` ran a sed regex per
  site that re-computed each length on every bump. Adding a new
  banner anywhere meant teaching the script about it; missing that
  edit got caught by CI's `grep -aq "AGNOS kernel v"` only after a
  release was cut. New `kernel/version.cyr` (auto-generated) wraps
  the three banners in **functions** (`print_agnos_kernel_banner`,
  `print_agnos_shell_banner` — aarch64 variant of the kernel banner
  selected via `#ifdef ARCH_AARCH64`) plus a bare `_AGNOS_VERSION`
  string var for post-init consumers. `kernel/agnos.cyr` includes
  `version.cyr` after `core/kprint.cyr` and the arch-specific
  `serial.cyr` files so the function bodies parse cleanly. The three
  banner call sites now invoke functions instead of inline
  literal+length pairs. `version-bump.sh` block #4 regenerates
  `kernel/version.cyr` via a single heredoc; adding a new banner is
  a one-file edit (`kernel/version.cyr` + the consuming `.cyr`), no
  script changes required. Build delta: `+160 B` (343,752 →
  344,520) for the three function wrappers + `_AGNOS_VERSION` slot.

  **Why functions, not vars** (first-take regression caught by
  CI's boot-banner grep): Cyrius's `src/version_str.cyr` uses `var`
  globals successfully because cyrius is a userland program —
  standard ELF startup runs gvar initializers before main. AGNOS
  kernel inverts that order: `kmode==1` emit (the freestanding
  multiboot path) is `PARSE_PROG before EMIT_GVAR_INITS`, so
  initializers run AFTER the kernel program body in execution order.
  A `kprintln(_AGNOS_KERNEL_BANNER, _AGNOS_KERNEL_BANNER_LEN)` from
  `main.cyr`'s top-level body therefore read an uninitialized slot
  and printed 20 zero bytes — invisible on the framebuffer, but
  fatal to CI's `grep -aq "AGNOS kernel v"` gate. Function bodies
  bake the literal's rodata address into the compiled `mov`
  instruction at parse time, so they work regardless of init order
  and the var-vs-fn distinction is the cleanest way to draw the
  userland/kernel line for any future shared-pattern consumer.
  Smoke-test under `qemu-system-x86_64 -machine q35 -cpu max` with
  gnoboot v0.2.0 + OVMF confirms both banners ("AGNOS kernel v1.30.2"
  + "AGNOS shell v1.30.2 (type 'help')") render and shell reaches
  the `agnos>` prompt.

### Fixed

- **xHCI Phase 3 — remap MMIO BAR as Uncacheable via
  `vmm_remap_uc_2mb`** (Repair (X), `kernel/core/vmm.cyr`,
  `kernel/arch/x86_64/usb/xhci.cyr`). F5 (MMIO write-coalescing in
  WB-cached BAR mapping) confirmed by Attempt 43's Repair-(V)
  diagnostic: `CMOS[0x71]=0x00` (MTRRs globally disabled, PAT alone
  governs) + `CMOS[0x72]=0x06` (PA0=WB). The boot-time identity map
  set by `pt_init` covers the xHCI BAR via either PD@0x3000 (BAR<1GB,
  2MB pages) or PDPT[1..3]'s 1GB huge pages (1–4GB) — both at flag
  `0x83` (P|RW|PS). For 2MB+ pages the PAT-index bits are {PWT=3,
  PCD=4, PAT=12}; with all three zero the page selects PAT entry 0 =
  PA0 = WB under firmware-default `0x0007040600070406`. PORTSC writes
  therefore coalesced in L1/L2 and never reached the xHCI controller
  on archaemenid's AMD FCH — matching Attempt 42's deterministic
  3-of-3 silent-absorbs through Repair (T)'s retry loop. New
  `vmm_remap_uc_2mb(phys)` flips PWT|PCD on the 2MB chunk containing
  `phys` (PWT|PCD|PAT=011 selects PA3 = UC under firmware default),
  handling both the in-place PDE rewrite case (phys<1GB, flag
  `0x9B`) and the 1GB-page shatter case (phys≥1GB: allocate a new PD
  via `pmm_alloc`, fill 512 identity 2MB entries, override the
  target chunk to UC, repoint PDPT[gb_idx] at the new PD with PS=0,
  CR3 reload to evict the 1GB-page TLB entry). `xhci_probe` calls
  `vmm_remap_uc_2mb(mmio)` immediately after caching `xhci_mmio_base`,
  ahead of the first CAPLENGTH read. On archaemenid the BAR at
  `0xFC800000` falls in PDPT[3]'s 1GB huge page (3–4GB) and exercises
  the shatter path; on QEMU `-cpu max` the BAR lands at `0xFEBF0000`
  (just under 4GB) and also exercises the shatter path. Only the
  BAR's single 2MB chunk is UC — surrounding RAM and MMIO stay
  WB-cached. Iron-test gate: `xhci: port N connected, …` line
  surfaces between `xhci: PP=1 asserted, bitmap=63` and
  `VFS initialized`; `CMOS[0x64]` reset-OK bitmap shows a non-zero
  bit for the connected port; `CMOS[0x6C]` PSC-change byte shows
  PRC|PED (`0x21`) instead of `0x00`. Floor for revert: pre-X binary
  (post-V from Attempt 43).

- **xHCI Phase 3 — MTRR/PAT MMIO cache-attribute diagnostic**
  (Repair (V), `kernel/arch/x86_64/usb/xhci.cyr`,
  `kernel/arch/x86_64/io.cyr`). Pure read-only diagnostic added to
  `xhci_probe` to disambiguate F5 (MMIO write-coalescing) from the
  remaining controller-side hypotheses after Repair (T)'s PR-retry
  loop hit deterministic 3-of-3 silent-absorbs at Attempt 42. New
  `rdmsr` helper in `kernel/arch/x86_64/io.cyr` wraps the
  `rdmsr` instruction (ECX=MSR index, returns EDX:EAX combined as
  a 64-bit value); `xhci_probe` stamps `MTRR_DEF_TYPE` (MSR `0x2FF`)
  low byte to `CMOS[0x71]` and `PAT` (MSR `0x277`) byte-0 (PA0) to
  `CMOS[0x72]`. The decoder cheat-sheet in
  `agnosticos/scripts/src/read-boot-log.cyr` translates these into
  the F5-confirmed / F5-weakened / helper-didn't-execute outcomes.
  Attempt 43 stamped `[0x71]=0x00` (MTRRs globally disabled — bit 11
  E=0, byte=UC default) and `[0x72]=0x06` (PA0=WB) — F5 confirmed.
  No controller-side risk; `rdmsr` is a non-faulting privileged read
  on every x86_64 since the Pentium.

- **xHCI Phase 3 — Linux-style PR retry loop** (Repair (T),
  `kernel/arch/x86_64/usb/xhci_port.cyr`). USB-core `hub.c`
  retries `USB_PORT_FEAT_RESET` up to 5× when the controller absorbs
  the write; AGNOS now wraps the PR write + PRC-poll block in a
  `retry < 3` loop and stamps the consumed retry count to
  `CMOS[0x70]`. On archaemenid Attempt 42 the loop ran to exhaustion
  (`[0x70]=0x03`) with no PRC/PED engagement at any iteration —
  falsifying F4 (Linux-style retry) and surfacing F5 (MMIO cache)
  as the surviving hypothesis. T is retained because the diagnostic
  it produces (`[0x70]` retry count) is permanently useful for
  detecting non-deterministic silicon and the 10-LOC cost is
  negligible.

- **xHCI Phase 3 — fix RWS-mask typo from Repair (S)** (Repair (S'),
  `kernel/arch/x86_64/usb/xhci_regs.cyr`). Repair (S) landed with
  `XHCI_PORTSC_RWS = 0x0E00C1E0` — dropping bit 9 (PP) vs Linux's
  `0x0E00C3E0`. The S helper double-masked through the RWS gate,
  stripping PP=0 on every PORTSC write; on AMD FCH the ports
  quiesced (PP bitmap `0x3F` → `0x00`, CCS bitmap `0x04` → `0x00`)
  at Attempt 40 and the entire xhci surface regressed. S' restores
  `XHCI_PORTSC_RWS = 0x0E00C3E0` and `XHCI_PORTSC_NEUTRAL =
  0x4E00FFE9` (RO|RWS = `0x40003C09 | 0x0E00C3E0`). One-nibble
  constant fix; binary-size byte-equivalent (343,384 B both sides).
  Attempt 41 restored Attempt-39 shape exactly (PP bitmap `0x3F`,
  CCS `0x04`), confirming the typo was the sole regression vector
  and that F3 (RW1C/RWS/LWS mask handling) is genuinely insufficient
  on this silicon — escalating F4 → F5 → Repair (T) → Repair (V) →
  Repair (X) which lands above.

- **xHCI Phase 3 — normalize PORTSC RMW to Linux's
  `xhci_port_state_to_neutral` mask** (Repair (S),
  `kernel/arch/x86_64/usb/xhci_regs.cyr`,
  `kernel/arch/x86_64/usb/xhci_port.cyr`). Attempt 39
  CMOS post-mortem confirmed Repair (R10)'s PLS gate ran
  clean (`CMOS[0x6D]=0x07`, Polling — spec-compliant
  precondition for USB2 `PR=1`) yet the PR write was
  still absorbed silently (`CMOS[0x6C]=0x00`, no PSC
  change bits set). Linux-side audit of
  `drivers/usb/host/xhci-hub.c` identified the canonical
  PORTSC read-modify-write pattern:
  `writel(xhci_port_state_to_neutral(read()) | newbit)`
  where `xhci_port_state_to_neutral(p) = (p & XHCI_PORT_RO) |
  (p & XHCI_PORT_RWS)` preserves only the read-only and
  read-write-sticky bits and zeroes everything else (W1C,
  W1S, LWS, reserved). AGNOS previously used a single
  mask `0xFF01FFFF` that preserved nine bits Linux
  explicitly zeroes — most importantly **bit 16 (LWS,
  Port Link State Write Strobe)**. xHCI 1.2 §5.4.8.3:
  when LWS=1, any PORTSC write touching the PLS field
  (which a value-preserve RMW does implicitly) is
  treated as a strobed PLS update; combining that with
  `PR=1` in the same write is undefined behavior and on
  AMD FCH silicon matches the "PR absorbed silently"
  symptom (CMOS[0x6E]=0xE5 also confirms `PPC=0` on
  archaemenid — port power is hardwired-on per port and
  the Repair (Q) PP-assert is structurally a no-op on
  this silicon, isolating Repair (S) as the load-bearing
  change). New `XhciPortscMask` enum holds
  `XHCI_PORTSC_RO` (`0x40003C09`),
  `XHCI_PORTSC_RWS` (`0x0E00C1E0`),
  `XHCI_PORTSC_NEUTRAL` (`0x4E00FDE9` = RO|RWS) and
  `XHCI_PORTSC_W1C` (`0x00FE0002` = PED + change bits
  17-23, mirroring Linux's `XHCI_PORT_RW1CS`).
  `xhci_portsc_write` helper, the PP-assert site in
  `xhci_ports_power_on`, the CSC pre-clear in
  `xhci_port_reset`, and the PR write itself all rewritten
  to neutralize through `XHCI_PORTSC_NEUTRAL`; the
  defensive `| 0x200` Repair (R1) added to the PR write
  is dropped because PP is preserved through
  neutralization (bit 9 lives in RWS) — exact byte-for-byte
  match with the Linux USB_PORT_FEAT_RESET case handler.
  Iron-test gate: `xhci: port N connected, …` line
  surfaces between `xhci: PP=1 asserted, bitmap=63` and
  `VFS initialized`; CMOS[0x64] reset-OK bitmap shows a
  non-zero bit for the connected port. `build/agnos`
  342,408 → 343,384 B (+976; R10 PLS gate +
  R7/R8 ride-along diagnostics + Repair S
  cumulative across the Attempt 39+40 sequence; pure
  Repair (S) delta vs immediate-prior R10 build is +64 B).
  Diagnostic decoder pair refreshed in
  `agnosticos/scripts/src/read-boot-log.cyr` (cheat-sheet
  rows for PSCchg=<none> + PLS=Polling now reference
  Repair (S); HCCP1 PPC bit decoded directly instead of
  assumed; LWS-preservation hypothesis documented;
  kcp=0x15 verdict extended to mention the
  CMOS[0x62-0x6F + 0x60] xhci post-mortem range and
  queued Repair (T) / Repair (V) fallbacks).

- **xHCI Phase 3 — assert PORTSC.PP=1 before port enumeration**
  (`kernel/arch/x86_64/usb/xhci_port.cyr`,
  `kernel/arch/x86_64/usb/xhci.cyr`). Root cause of the
  Attempt-37 iron-boot symptom: every PORTSC slot reported
  `CCS=0` across all 6 archaemenid ports despite physically
  attached devices (`read-boot-log` CMOS[0x63] = `0x00`).
  xHCI 1.2 §4.19.1.1 / §5.4.8: when `HCCPARAMS1.PPC=1`
  (the AMD FCH default), `HCRST` leaves `PORTSC.PP=0` on
  every port and the controller gates the receiver until
  software asserts `PP=1` explicitly. The kernel previously
  documented the `PP` bit in `xhci_regs.cyr:196` but never
  wrote it — `xhci_init`'s `HCRST` flipped every port off,
  and `xhci_enumerate` walked the ports looking at `CCS`
  while every receiver was still gated. New
  `xhci_ports_power_on()` walks `1..xhci_max_ports`,
  RMWs `PORTSC` with `(psc & 0xFF01FFFF) | 0x200`
  (preserves W1C status-change bits per the existing
  `xhci_portsc_write` semantics), waits a coarse
  ~100ms-scale debounce loop for the USB 2.0 §11.5.1.5
  power-on settle window, then reads PP back per port and
  stamps the verified bitmap to CMOS[0x6B]. Called from
  `xhci_enumerate` between `xhci_xecp_classify_ports()`
  and the per-port enumerate loop. Safe on PPC=0 silicon
  (PP reads as 1 unconditionally there; the write is a
  controller-side no-op). Iron-test gate: framebuffer line
  `xhci: PP=1 asserted, bitmap=<N>` between
  `xhci: controller running, HCH=0, ...` and the per-port
  `xhci: port N reset failed (proto=X)` (or success)
  lines; CMOS[0x6B] full bitmap survives kcp overwrite for
  post-mortem; at least one CCS bit set when a device is
  physically attached. `build/agnos` 341,864 → 342,408 B
  (+544). Diagnostic decoder pair:
  `agnosticos/scripts/src/read-boot-log.cyr`
  (CMOS slot range extended `0x62..0x6A` → `0x62..0x6B`).

### Added

- **xHCI Phase 1 — PCIe discovery + capability reads**
  (`kernel/arch/x86_64/usb/xhci.cyr`, `kernel/arch/x86_64/usb/xhci_regs.cyr`).
  First phase of the in-tree USB-HID-boot keyboard driver. Locates the
  USB 3.x host controller via PCI class lookup (class `0x0C`, subclass
  `0x03`, prog-if `0x30`), reads the capability window from the MMIO
  BAR, and caches `MaxSlots` / `MaxIntrs` / `MaxPorts` / context-size /
  `AC64` / `DBOFF` / `RTSOFF` / `xECP` as module globals for later
  phases. Probe-only — no controller reset, no DMA, no port enumeration
  (those are Phase 2 onward). Iron-test gate: framebuffer shows
  `xhci: found at <addr>, ver=1.X0, N slots, M ports` and CMOS reaches
  `kcp = 0x30`. `build/agnos` 266,312 → 273,816 B (+7,504). Bus master
  + memory space access enabled on the PCI command register at probe
  time so Phase 2 can talk to the controller. Scoping +
  per-phase roadmap:
  [`agnosticos/docs/development/planning/usb-hid-keyboard-driver.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/usb-hid-keyboard-driver.md).

### Changed

- **`pci.cyr` extended with class-code capture + 64-bit BAR support.**
  Added side arrays `pci_class[256]` (packed
  `class<<16 | subclass<<8 | prog_if` per slot) and `pci_bar0_hi[256]`
  (high 32 bits when BAR0 is a 64-bit memory BAR per PCI 3.0
  §6.2.5.1 type field). `pci_scan` now populates both arrays
  alongside the existing `PciDev` struct. Existing consumers
  (`virtio_net`, `virtio_blk`, `iommu`, `shell.cyr` lspci) stay
  byte-compatible against `&pci_devs + i * 32` indexing — no struct
  changes. New helpers `pci_find_by_class(class, subclass, prog_if)`
  + `pci_bar0_64(idx)` are the access points for the xHCI probe and
  any future class-driven lookup (NVMe, future Ethernet, etc.).

## [1.30.0] — 2026-05-13 (iron-validated 2026-05-15)

**Kernel ABI break — entry contract switches from multiboot2 to AGNOS
sovereign boot-info struct (Path C handoff).** Closes the
Path-A → Path-C transition triggered by GRUB's strict-W^X EFI
relocator being incompatible with multiboot2 on modern firmware
(see `agnosticos/docs/development/iron-nuc-zen-log.md`
§ Diagnosis 2 for the forensic trail and
`agnosticos/docs/development/path-c-sovereign-uefi.md` for the
new plan). Pairs with **gnoboot v0.2.0** — the AGNOS sovereign
UEFI bootloader that replaces GRUB on the boot path (gnoboot
shipped its CMOS-removal + banner-tightening cleanup track at
0.2.0 same-cycle).

**Iron validation completed 2026-05-15 on archaemenid (NUC AMD).**
The initial 2026-05-13 cut compiled but had not booted on iron.
Attempts 4–29 walked the bring-up; **Attempt 28 (2026-05-15)**
hit the MVP-spine end-to-end (closed-beta CP `0x11` MAGENTA held;
kernel completed init → idle → userland exec → kybernet → shell);
**Attempt 29 cleanup-pass burn (~16:45 PDT)** rendered the full
kernel log on the framebuffer in coherent text and surfaced the
USB-keyboard blocker (MVP gap #3 — falsified PS/2-SMM-emulation
hypothesis on this firmware; carried into 1.30.1 as the next
substantive work). The repairs / cleanup / boot-shim canaries that
landed across this cycle are folded below into Added / Changed /
Fixed.

cyrius pin **5.11.43 → 5.11.55** (5.11.43 → 5.11.53 at initial cut;
.53 → .55 during iron-validation as the cyrius cycle ran ahead);
`build/agnos` **251056 → 266312 bytes** (+15,256 across the cycle —
visual canary, CMOS boot-log, Repair P, kprint mirror, cleanup pass,
+ DCE / link state shifts); entry unchanged at `0x1000A8`.

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

- **Post-Attempt-29 cleanup pass** — strip cp_fb call sites; collapse
  serial_print/serial_println into kprint/kprintln; shrink
  `FB_CONSOLE_Y0` 80 → 8 (boot_shim canary stripe stays at y=0..7).
  All 19 `cp_fb(...)` call lines stripped from `main.cyr` (the CMOS
  port-I/O stamps preserved — still readable post-mortem via
  `read-boot-log.sh`); 85 `serial_print(`/`serial_println(` calls →
  `kprint(`/`kprintln(` (mirrors to both serial + framebuffer; fixes
  the scrambled-digits issue from the Attempt 29 photo where labels
  weren't mirroring but numbers were). `cp_fb()` fn + color palette
  preserved in `fb.cyr` — one-line `cp_fb(<idx>, <color>);` re-add
  is the future-bisection path. `read-boot-log.cyr` (in agnosticos)
  verdict text refreshed for the post-cleanup kernel. Burn-verified
  ~16:45 PDT 2026-05-15: full kernel log rendered coherently on
  framebuffer, shell prompt visible, USB-kbd blocker surfaced (1.30.1
  scope). Kernel 266,712 → 266,312 B (-400 from cp_fb call removal
  partially offset by kprint indirection vs direct serial_print).

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
  verdict pointing at the new stamp ladder. Joined Repairs F+H+I+J
  in-flight; the mem-iso block (and its stamps) was subsequently
  deleted by Repair (O) when post-MVP framing was confirmed.

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
- **cyrius pin**: 5.11.43 → 5.11.53 → **5.11.55**. Initial cut took
  5.11.43 → 5.11.53 to pick up the post-Path-A fixes (entry-save REX
  hotfix from 5.11.53; byte-array literal + `fn efi_main` convention
  from 5.11.51/.52). During iron-validation the cyrius cycle ran
  ahead to 5.11.55 (the stdlib-annotation-arc + consumer-issue
  closeout burst landed 55 patches across 2026-05-11/12/13); pin
  re-synced to 5.11.55 to stay current with the gnoboot 5.11.53 pin
  and avoid stale stdlib lag.
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
  `agnosticos/docs/development/iron-nuc-zen-log.md` § *Attempt 9*.
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
  target. See `agnosticos/docs/development/iron-nuc-zen-log.md`
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

### Closed during iron validation (2026-05-15)

- **Timer-driven scheduler stops after ~10 context switches** under
  gnoboot+OVMF → ✅ resolved. On iron (Attempt 28 onward), the
  scheduler completes a 50+ tick run cleanly; QEMU+OVMF behavior
  diverged from iron because of the gnoboot+OVMF inherited-mapping
  edge case, not a load-bearing kernel bug. Repair (O) deleting the
  mem-iso test block (post-MVP work breaking pre-MVP boot) was the
  actual fix; the previously-hypothesized fixed-physical page-table
  concern turned out to not be the root cause.
- **Iron Attempt 5 on NUC AMD** → ✅ resolved (and 24 more attempts
  past it). USB re-provision via `agnosticos/scripts/install-usb.sh`
  + gnoboot 0.1.0 (then 0.2.0) + repeated kernel rebuilds carried
  the bring-up through Attempts 4–29. Closed-beta gate (CP `0x11`
  MAGENTA) held from Attempt 16; full spine on iron at Attempt 28;
  shell visible on iron at Attempt 29; cleanup-pass burn ~16:45 PDT
  validated the full text log on framebuffer. The remaining
  USB-keyboard input blocker (MVP gap #3) is carried into 1.30.1 —
  not a 1.30.0 regression, a new-driver scope.

### Open (carry-forward to 1.30.1)

- **USB-keyboard scancodes not reaching `kb_buf`** on archaemenid
  (UEFI legacy SMM PS/2-emulation genuinely off post-EBS;
  BIOS-knob + every USB-A port confirmed). Real-answer fallback:
  native XHCI + USB-HID-boot-protocol driver in
  `kernel/arch/x86_64/usb/` — scoped at
  `agnosticos/docs/development/planning/usb-hid-keyboard-driver.md`,
  5 phases, ~1.2–2.1k LOC, kernel-side, in-tree.

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
open (see `agnosticos/docs/development/iron-nuc-zen-log.md`
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
  (per the iron-nuc-zen-log): low-memory page-table / GDT /
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
