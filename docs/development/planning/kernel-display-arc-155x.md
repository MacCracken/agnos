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
| **P3** | **Display-audio egress** — DCCG audio DTO + AZ endpoint + AFMT/SDP on the lit stream. **DP first** (the user's display is DP output 2; simpler than HDMI). HDMI ACR/CTS after. Closes the 1.53.5 HDA backlog: the codec already sends samples + broadcasts to every digital pin; this programs the DCN side that embeds them. | IRON — tone from the display's speakers |
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
