# Kernel display arc — push PIXELS through the silicon (slotted 1.55.x)

**Thrust P of the GPU program.** The compute half (Thrust C, the 1.54.x arc) is COMPLETE — sovereign
gfx90c compute is proven end-to-end on iron: firmware-load → engines → GPUVM → CP/MEC queue → PM4 →
hand-assembled shaders → multi-thread → kernargs → loop → **integer + f64 matmul, rosnet-bit-correct**,
exposed to ring 3 via `gpu_dispatch`/`gpu_dispatch_f64` (#82/#83). This arc is the **other half: PIXELS** —
own the GOP-lit **DCN 2.1** display pipe, then accelerate 2D.

Sibling doc: [`kernel-gpu-arc-154x.md`](kernel-gpu-arc-154x.md) (the compute arc + the original two-thrust
framing). This doc is the display thrust, formally opened as its own **1.55.x** minor arc.

## Thesis — own the lit pipe, don't reprogram it

The UEFI VBIOS GOP already lit the display: the boot console is visible on the user's monitor (DP output 2).
So the display pipe, PLL, DP transmitter, and link-training are **already running**. We do NOT do a mode-set
(that's the deep end, P6+). We **own the live pipe**: re-point the scanout surface for tear-free flips, pace
on vblank, embed audio into the live stream, and clear scanout residue. Everything reads/writes DCN 2.1
registers through the BAR5 aperture already mapped at F0. No firmware, no clock reprogram — until P6.

Why this matters: today `blit`#39 CPU-memcpys into the live scanout (tears; single-buffered), and display
audio is silent (the 1.53.5 HDA HDMI/DP work reaches the codec but the DCN audio path is unprogrammed).

## Bite ladder — each bite is its own cut; NO auto-run (user burns). Iron-only (QEMU emulates no DCN).

| Bite | What | Validate |
|------|------|----------|
| **P0** | **Read-only live-pipe probe** (`gpu_display_probe`): DCN 2.1 register-base table (OTG/HUBP/DCCG) + walk OTG to the GOP-lit pipe + read its HUBP surface address/pitch/format. **Pass gate: lit HUBP `DCSURF_PRIMARY_SURFACE_ADDRESS` == kernel `fb_phys`** (the scanout buffer gnoboot handed off). Zero-hang-risk (read-only). **The 1.55.0 arc-opening cut.** | IRON — `klug > /f/p0.txt` |
| **P1** | Double-buffer / tear-free flip — re-point HUBP `DCSURF_PRIMARY_SURFACE_ADDRESS` to a second buffer; wire kernel-mediated double-buffer into `blit`#39. Needs P0's HUBP surface register proven. | IRON FB photo — no tearing |
| **P2** | Vblank pacing — poll OTG scan position; flip-on-vblank so P1's re-point lands in blank. | IRON — clean present cadence |
| **P3a** | **Display-audio state probe** (read-only) — resolve every open question before writing an audio register. **DONE (iron 1.55.8/1.55.9).** Results: the link is **HDMI on DIG1 in DIG_MODE=2 (DVI)**; DMCUB is **not** in the path; the **AZ window is awake and correctly addressed** (index-writeback discriminator) so **no SMU PME mailbox is needed**; the audio DTOs are unprogrammed. | IRON — done |
| **P3b-i** | **Pixel-clock discovery** (read-only) — the HDMI audio DTO's MODULE field **is** the pixel clock in 100 Hz units (`dce_audio.c` `get_azalia_clock_info_hdmi`) and the ACR CTS derives from it, but the DCCG register that would hold it is only populated on a **DP-driven** pipe — this link is HDMI, so it reads 0. Derive instead: **pixel clock = h_total × v_total × refresh**, totals from the OTG, refresh **measured** against the free-running PIT ch0. **DONE (iron 1.55.11).** `gpu_pixclk_100hz` = **2415030** (241.503 MHz, 13 ppm off the 241.500 MHz standard). 1.55.10 snapped the refresh to a table and iron falsified it (176 ppm error); 1.55.11 deleted the snap. | IRON — **PASS**: `link 2560x1440 total 2720x1481 blanking 160x41` · `windows agree within 12 ppm` · `241503 kHz, 13 ppm from the 241500 kHz step` |
| **P3b-ii** | **DVI→HDMI mode change** on the live link (`DIG_MODE` 2→3). **BUILT 1.55.12** (gated on `HDA_HDMI`). **Its "rewrites the encoder" framing was WRONG and overstated the risk**: every `HDMI_*` register is **inert while `DIG_MODE==2`**, so the whole HDMI config is staged at zero risk and the flip is a one-field **RMW** commit of an already-verified context (`dcn10_link_encoder_setup` is one `REG_UPDATE` — no PHY/PLL/OTG, so it cannot move the clock or timing). The three real black-screen paths (deep colour/scrambling, AVMUTE, non-24bpp-RGB) are **gates inside the writer**, not a separate burn. | IRON — console survives |
| **P3b-iii** | **Audio programming** — DCCG audio DTO → AZ endpoint enable → AFMT/SDP → ACR. Write order: **source/select (`DTO0_SOURCE_SEL` + `DTO_SEL`) before MODULE and PHASE** is hardware-enforced (AMD's `dce_audio.c` warning) and a violation fails **silently**; **MODULE before PHASE** merely matches AMD's observed order and is **not** documented as required — write it that way, but never debug against it as if it were a constraint. Full derivation + provenance in `gpu_regs.cyr`'s P3 header. Closes the 1.53.5 HDA backlog: the codec already streams samples; this programs the DCN side that embeds them. | IRON — tone from the sink |
| **P4** | Scanout-residue clear (Quiet-Boot legibility) via the P1 re-point primitive — clean first paint. | IRON photo |
| **P6+** | **The deep end** (likely a follow-on arc): 3D path (RADV-derived GFX-ring blits, needs the C1/C2 ring machinery) + full mode-set (DCN mode-set / DP link-training / DMCUB). In the ambition, not this arc's core. | IRON |

Ordering: P0 is read-only and can ride a burn immediately (it only needs F0's BAR5 map, already done). P1→P2→P4
build on P0's HUBP surface register. P3 (audio) is independent of the flip chain — it needs the DCCG/AZ/AFMT
path, and can proceed once P0 has the DCN base + register-access model proven. P6+ deferred.

## Target hardware (verified at F0/C0 on archaemenid; re-verify each DCN read at P0)

| Facet | Value |
|-------|-------|
| iGPU | AMD Cezanne (Ryzen 7 5800H) — DCN 2.1 display, gfx90c compute |
| PCI | `1002:1638` function 0; register BAR5 (MMIO, UC-mapped at F0) |
| Display | DCN 2.1, **GOP-lit linear FB**; the display is on **HDMI** — physically, per the operator (the cable in the box is the ground truth). **The old "DP output 2" note in this table was WRONG** and cost a detour. Iron-confirmed at P3a (1.55.8): `DP_DTO0_ENABLE`=0, `DP_VID_STREAM_ENABLE`=0 ⇒ not DP-SST; the live encoder is **DIG1**, and it is in **DIG_MODE=2 (DVI)** — legal on an HDMI sink, but DVI signaling carries **no audio and no infoframes** |
| FB phys | `fb_phys = load64(load64(&boot_info_ptr) + 0x48)` (pitch +0x50, height +0x58) — the P0 pass-gate |
| DCN base | `GPU_BASE_DCN_1` in `gpu_regs.cyr` (verify at P0 — the DCN 2.1 register segment) |

## Prior-art (multi-source per [[feedback_redesign_dont_reinvent]] — re-derive, don't trust one table)

- **Linux amdgpu DC `dcn21/`** (+ `dcn20/` reused, `dce_audio.c`) — PRIMARY: HUBP surface-flip
  (`dcn20_hubp.c` `hubp2_program_surface_flip_and_addr`), OTG/OPTC vblank (`dcn20_optc.c`), the DCCG-audio +
  AFMT/SDP display-audio sequence (`dce_audio.c`, `dcn21` DCCG).
- **Register defs**: `dcn/dcn_2_1_0_offset.h`, `dcn_2_1_0_sh_mask.h`, `renoir_ip_offset.h`.
- **DCN block docs**: https://docs.kernel.org/gpu/amdgpu/display/dcn-blocks.html (OTG/HUBP/DPP/MPC/OPP/DIO chain).

The P0 register table (OTG_CONTROL + HUBP surface registers, bases + per-instance strides) is derived
adversarially (multi-lens) and iron-validated read-only before any write bite.

### The link, positively identified (iron 1.55.10)

**2560x1440 CVT reduced-blanking @ 241.50 MHz, 59.9506 Hz.** Registers read `raw 2719x1480` → totals
**2720x1481** (hblank **160** = RB's fixed value, vblank **41**). Independently re-derived clean-room from the
CVT-RB algorithm, and a 147-mode brute-force scan found it the **unique** match on the (h_total, v_total) pair.

- ⚠ **Neither total identifies a mode alone.** 2720 also fits 2560x1080 and 2560x1600 at every rate (RB's fixed
  160 hblank pins only the active *width*); 1481 also fits 1920x1440@60 and 3440x1440@60. **Always key on the
  pair.**
- **59.9506 Hz is the standard's own value**, not PLL error or drift — it is what the floor() to the 0.25 MHz
  clock step leaves behind. Nothing should "correct" it toward 60.000.
- **SSC is on DPREFCLK but NOT on the TMDS pixel clock**: DPREFCLK measured 598.875 MHz (0.1875% downspread),
  yet the pixel clock measured 241.502 — *above* nominal 241.500. A downspread pixel clock would read ~241.05.
- **241.5 MHz at DIG_MODE=2 is not a contradiction.** 241.5 MHz exceeds single-link *DVI's* 165 MHz ceiling,
  but this is DVI **signalling** on an HDMI physical link (7.245 Gbps = 71% of HDMI 1.4's 10.2 Gbps ceiling) —
  consistent with `DP_DTO0_ENABLE`=0 and the absence of display audio. Do not gate anything at 165 MHz.

### ⚠ `fb_width()` / `fb_height()` ARE NOT THE SCANOUT GEOMETRY (iron 1.55.10)

The firmware left an **800x600 GOP surface on a 2560x1440 link** — **the DCN pipe scaler is live**. gnoboot
reads fb_width from `Mode->Info->HorizontalResolution` *after* `SetMode`, so boot_info is **not stale**; the
firmware genuinely chose 800x600. **Anything in this arc that derives timing, pixel clock or vblank period from
fb_width/fb_height is reading the wrong plane of the pipe** — that was 1.55.10's guard bug, which passed only
because 2720 > 800. Use `OTG_H/V_BLANK_START_END` (active = START − END; programmed with **no −1**, so
convention-free).

**Confirmed from hardware at 1.55.11**: the blank registers report the link active as **2560x1440**, not
800x600 — so the surface and the raster genuinely differ and the pipe scaler is engaged. The *mechanism* is
still unread: upscaling (DSCL stretching 800x600 into the raster) fits, but so does **centring with DSCL in
bypass** (an 800x600 island with black borders); the console photo favours upscaling. To settle it:
`DSCL0_SCL_MODE` 0x0CEC (DSCL_MODE[2:0], 6 = bypass) · `SCL_HORZ_FILTER_SCALE_RATIO` 0x0CF1 (ratio = raw /
2^24) · `RECOUT_SIZE` 0x0D03 (DPP stride 0x16B). **This does not block P3b** — DSCL sits upstream of
OTG/DIG/PHY, so the link clock is untouched by any scaling.

**Geometry closure is now the totals' independent witness.** The blank registers carry **no -1**, so
`active = START - END` is convention-free; `h_total - h_active = 2720 - 2560 = 160` lands exactly on CVT-RB's
mandated hblank, where a wrong -1 would give 159 and match no standard. The `blanking 160x41` log line is
therefore a self-check on the totals decode on every boot — not a decoration.

### P3b-i pixel-clock derivation — settled facts (do NOT re-litigate)

Read out of `dcn_2_1_0_offset.h` / `_sh_mask.h` / `dcn10_optc.c` / `dce_audio.c` directly, not from memory.
Cezanne reuses Renoir's DCN 2.1, and the header's `OTG_CONTROL`=0x1b41 / `OTG_STATUS`=0x1b49 /
`OTG_STATUS_FRAME_COUNT`=0x1b4c match our three **iron-proven** values exactly — three independent
confirmations that this header describes this part before trusting any new offset from it.

- **Both totals hold `total - 1`.** `optc1_program_timing`: `/* CRTC_H_TOTAL = vesa.h_total - 1 */` and, on
  the line *before* the `OTG_V_TOTAL` write, `v_total = patched_crtc_timing.v_total - 1;`. The V write
  *looks* raw — the asymmetry is only apparent, and reading the write site without the preceding line is a
  trap. It is a counter-wrap value, i.e. a hardware convention every firmware obeys, not a driver choice.
- `apply_front_porch_workaround()` clamps **`v_front_porch` only** — it never touches a total.
- **Offsets** (all `BASE_IDX 2`, stride 0x80): `OTG_H_TOTAL` 0x1b2a · `OTG_V_TOTAL` 0x1b2f ·
  `OTG_H_TIMING_CNTL` 0x1b2e · `OTG_INTERLACE_CONTROL` 0x1b44. Totals are `[14:0]`.
- **dcn21 has NO `OTG_H_TIMING_DIV_MODE` field** (zero hits in its `_sh_mask.h`) — only `DIV_BY2` bit0. The
  dcn10 code's DIV_MODE branch is for later parts; bit0 is the whole story here.
- **`get_azalia_clock_info_hdmi`: `audio_dto_module = actual_pixel_clock_100Hz`, `phase = 24*10000`.** So
  P3b-i's output feeds `DTO0_MODULE` directly, and **Fs never enters** (already a settled P3a fact).
- **🔴 DO NOT SNAP AT ALL — the measured value IS the answer.** (1.55.10 snapped the refresh; **iron falsified
  it**; corrected in 1.55.11 after a 16-agent adversarial verification. The reasoning is preserved here
  because the instinct to snap is strong and keeps coming back.)
  - **Refresh is not a round number on PC modes.** VESA CVT quantises the **pixel clock** to a 0.25 MHz step
    (241.6992 → 241.50 by *floor*); the refresh (59.9506 Hz) is the **leftover**. Round-refresh is a **CEA/TV**
    property. 1.55.10's table snapped to **59.94 — a television rate on a PC monitor** — turning a **7.5 ppm**
    measurement into a **176 ppm** answer.
  - **Snapping the pixel clock to the 0.25 MHz grid is WORSE, not better.** On this link the **wrong** totals
    decode (raw 2719x1480) lands **+0.08 ppm** from a grid step while the **correct** decode lands **+7.5 ppm**
    — the bug fits the grid **75x better than the truth**. A grid cannot tell *correct* from *plausible*; it
    would launder a register-decode bug into a confident exact number. Also: CVT-**RBv2** uses a **0.001 MHz**
    step (modern VRR panels are off-grid), legacy DMT 25.175/28.322 are off-grid, and a `/1.001` grid is
    **−27.7 ppm** from this clock ⇒ ambiguous.
  - **There is no PLL to read.** amdgpu has no PHY-PLL read-back on the HDMI path (`get_pixel_clk_frequency_100hz`
    reads the DP DTO — the register that reads 0 here); dividers come from ATOM BIOS tables, and divider math
    returns the un-spread **centre** while frame-counting returns the **average** — and the average is what the
    audio DTO wants. **The measurement is more correct than the register.**
- **Accuracy is not the constraint.** The DTO module and the ACR CTS derive from the **same** believed clock, so
  any error is self-consistent — the sink recovers the source's actual rate, no drift, no under/overrun, only an
  absolute pitch offset. Even 176 ppm = **0.3 cents** (JND ~5 cents) and passes IEC 60958-3 Level II (±1000 ppm)
  5.7x over. Delete the snap because it can be **catastrophically wrong on an unlisted mode**, not because it
  was audible.
- **Gate the axis where a gate can fire.** The 500 ppm snap tolerance was **dead code** across [59.94, 60]
  (candidates ~1000 ppm apart, gate at the half-spacing ⇒ something always matched). Use **cross-window
  agreement** (>200 ppm spread ⇒ refuse; iron ~17 ppm) + a wide 5–600 MHz band. **Do NOT gate at DVI's 165 MHz**
  — this link legitimately runs 241.5 MHz at DIG_MODE=2.
- **Compute from the raw tick count**, never a rounded mHz refresh (±0.5 mHz print quantum ≈ 8 ppm at 60 Hz).
- **When we reach ACR: use HW auto-CTS** (`HDMI_ACR_AUTO_SEND` / `ACR_CONT`) — the hardware measures CTS off the
  real TMDS and real audio clock, so the derived pixel clock never enters the ACR path at all.
- **The timebase already existed.** `pit_ch0_read()` (apic.cyr) is a non-destructive latch read of ch0, which
  `pic_init()` leaves free-running as a **mode-2** rate generator (divisor 11932); `pic_mask_pit()` masks
  IRQ0 at the 8259 but never touches the counter. Mode 2 decrements by **one** per tick and reloads after
  exactly `divisor` ticks — mode 3 would step by two and break the wrap math. No new timebase was needed, and
  **CPUID 0x15/0x16 return zeros on this exact part** so the TSC route was closed anyway.
- **The GPU probes run with IF=0** (no `sti` anywhere before them in the boot path — "Interrupts enabled" is
  ~2000 lines later), so no ISR and no scheduler can perturb a window. **SMI is the only contaminant**, it can
  only ever *add* time, and only an SMI landing **on a window endpoint** biases anything (one mid-window
  delays the polling, not the two clocks being compared) — hence several short windows, keep the shortest.
- **Refuse rather than mis-snap.** A silently-wrong DTO module is inaudible to test but wrong forever. Every
  plausible fault (a misread total ~1300 ppm, a missed PIT wrap ~3%, a non-standard mode) lands far outside
  the 500 ppm tolerance, while a correct read lands within tens of ppm — so the tolerance is itself the
  check on the whole derivation.

## Harness

- **Iron-only** — QEMU emulates no AMD DCN. Read-only bites (P0) ride the first burns; `gpu_display_probe`
  runs at boot after the compute probes and no-ops cleanly when the GPU/DCN is absent (QEMU) or FB not GOP-lit.
- Logs read like a real driver ([[feedback_kernel_logs_plain_no_codes]]): `gpu: display pipe 0 live (surface
  matches framebuffer)`, never codes/tags/hex-dumps on the normal path.
- Readout via `klug > /f/*.txt` for probe state; FB photo for the visible bites (P1/P2/P4).

## Risks / open questions (resolve in bite order; honest, not hidden)

1. **DCN register base** — is `GPU_BASE_DCN_1=0x0C0` the correct DCN 2.1 segment for register access on Renoir?
   P0's first job is to prove the base by reading a known register (e.g. an OTG that must be enabled on the
   lit pipe) and sanity-checking. Biggest iron-risk value; double-check first.
2. **OTG↔HUBP pipe mapping** — on a single-display GOP config it's likely identity (pipe 0), but P0 should be
   robust: read all HUBP surface addresses and match `fb_phys` rather than assume the mapping.
3. **Read hang-safety** — reads of registers behind a gated DISPCLK/DPPCLK domain or in an unpowered pipe
   (OTG1-3 may be off) could hang. P0 guards by reading OTG_CONTROL first and only touching HUBP for enabled
   pipes. Confirmed read-only-safe on the GOP-lit pipe before any write bite.
4. **DMCUB** — expected NOT needed for lit-pipe flips/audio (P1/P2/P3). If P3 proves DMCUB-gated, document +
   proceed with the rest.
5. **Surface-address units** — the HUBP surface register may hold a shifted/aligned value; reconstruct the
   byte address correctly before the `fb_phys` compare (resolved in P0's derivation).

## Non-goals (this arc)

- Full DCN mode-set / DP link-training / DMCUB firmware (P6+, likely a follow-on arc).
- Other vendors/arches; a GL/VK API surface; the NVIDIA leg.
- HDMI-first audio (DP first; HDMI ACR/CTS is a P3 follow-on).

## Pointers

- Compute arc (sibling, COMPLETE): [`kernel-gpu-arc-154x.md`](kernel-gpu-arc-154x.md).
- Iron log: `iron-nuc-zen-log.md` — P0 tracker written at cut; `#tracker-153x-hdmi` is the display-audio (P3)
  handoff.
- agnosticos state.md (display-arc current scope) + roadmap (§ *agnos 1.55.x — Kernel display arc*).
- DCN 2.1: [block docs](https://docs.kernel.org/gpu/amdgpu/display/dcn-blocks.html) ·
  [Phoronix Renoir DCN 2.1](https://www.phoronix.com/news/AMD-Renoir-DCN-2.1-Patches).
