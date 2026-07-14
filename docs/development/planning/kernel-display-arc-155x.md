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
| **P3b-i** | **Pixel-clock discovery** (read-only) — the HDMI audio DTO's MODULE field **is** the pixel clock in 100 Hz units (`dce_audio.c` `get_azalia_clock_info_hdmi`) and the ACR CTS derives from it, but the DCCG register that would hold it is only populated on a **DP-driven** pipe — this link is HDMI, so it reads 0. Derive instead: **pixel clock = h_total × v_total × refresh**, with the totals read from the OTG and the **refresh measured against the free-running PIT ch0 and snapped to the standard rate**. | IRON — geometry + rate match the standard mode |
| **P3b-ii** | **DVI→HDMI mode change** on the live link (`DIG_MODE` 2→3) — the risky bite: it rewrites the encoder carrying the console. | IRON — console survives, audio packets possible |
| **P3b-iii** | **Audio programming** — DCCG audio DTO → AZ endpoint enable → AFMT/SDP → ACR. Write order is **hardware-enforced** (source/select before module/phase, MODULE before PHASE); a reordered sequence fails **silently**. Closes the 1.53.5 HDA backlog: the codec already streams samples; this programs the DCN side that embeds them. | IRON — tone from the sink |
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
- **Snap the REFRESH, not the finished pixel clock.** The refresh measurement uses only the frame counter and
  the PIT, so it cannot be corrupted by a misread total; snapping it yields an *exact* rate, where snapping
  the pixel clock would let a totals error mis-snap 60 → 59.94 (they are only ~1000 ppm apart) instead of
  failing loudly.
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
