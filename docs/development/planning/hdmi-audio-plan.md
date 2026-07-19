---
name: HDMI Audio — first-principles model + plan of attack
description: How HDMI audio actually works (cross-system), agnos's exact gap, and the staged MMIO plan to make sovereign HDMI audio play
type: planning
---

# HDMI Audio on AGNOS — the model and the plan

> **▶ CURRENT ENTRY POINT: [`hdmi-modeset-arc-155x.md`](hdmi-modeset-arc-155x.md) + [`../state.md`](../state.md).**
> This doc is the audio-register / first-principles analysis (valuable history — Part 1's HDMI model still
> holds). Its **plan-of-attack conclusion is SUPERSEDED**: the DCN audio register class is now EXHAUSTED
> (byte-for-byte amdgpu, still silent) and the "MMIO-is-sufficient, no ATOM needed" verdict was wrong — the
> blocker resolved to the **firmware-driven HDMI transmitter/encoder bring-up** the GOP does as DVI, now driven
> by a **sovereign ATOM BIOS interpreter** (`kernel/core/atom.cyr`, A2/A3 bit-correct on iron 1.55.23). A4
> (audio) is OPEN; current lead is the DCCG SYMCLKA re-prime. Do not act on the register/edge fixes below
> without checking the modeset arc doc first.

> Built from a 7-angle first-principles review (HDMI spec · discrete TX chips ADV7511/IT66121/SiI9022 ·
> vc4/i915 · AMD DCN/DCE encoder · sink conformance · agnos gap · the DMUB-vs-MMIO question), 2026-07-16.
> **This is a driver-class task, not a research problem.** The register-value class is EXHAUSTED (agnos is
> byte-identical to amdgpu audibly playing on the XB323U). What is left is a small set of *dynamic edges*,
> all reachable by pure MMIO.
> **⚠ SUPERSEDED (1.55.23): "all reachable by pure MMIO / small set of dynamic edges" proved wrong — the edges
> below were burned and stayed silent. The residual is the firmware transmitter bring-up, now driven by the
> sovereign ATOM interpreter (`kernel/core/atom.cyr`). See `hdmi-modeset-arc-155x.md`.**

## Part 1 — how HDMI audio actually works

1. **An HDMI link is a DVI link that steals the blanking.** TMDS is always in one of three periods: Video
   Data (active pixels, 8b/10b), Control (filler), or **Data Island (DIP)** — audio + aux packets, carried
   ONLY in horizontal/vertical blanking, guard-banded, **TERC4-coded** (not 8b/10b), BCH-protected.
   **Audio rides in the blanking as data islands, not on the video.** Video working over HDMI proves nothing
   about audio — DVI and HDMI video are bit-identical.

2. **There is no "I am HDMI" bit on the wire.** DVI vs HDMI is *behavioral*: an HDMI source carves DIPs into
   blanking and fills them; the sink infers "HDMI" by *receiving valid data islands* (above all the AVI
   InfoFrame). No islands → the sink stays in DVI receive mode and has nowhere to route audio. The source is
   *allowed* to send islands because the sink's EDID has the HDMI VSDB (IEEE OUI 0x000C03) — the XB323U has
   it, so that gate is not agnos's blocker.

3. **The packet set for stereo 48 kHz L-PCM** (all sustained, on cadence, in the DIP):
   - **Audio Sample Packet (0x02)** — the PCM. ~12,000 non-empty stereo ASPs/sec. `sample_present` says which
     of 4 subpackets carry data; the B/block-start bit marks IEC-60958 channel-status boundaries. Stereo = Layout 0.
   - **Audio Clock Regeneration (0x01)** — the sink regenerates `128·fs` from the TMDS clock via **N/CTS**:
     `128·fs = f_TMDS·(N/CTS)`. 48 kHz → N=6144; at 241.5 MHz pixel clock → CTS=241500. ≥1/field. HW-measured
     CTS (agnos, amdgpu) is correct-by-construction. **Not the bug.**
   - **Audio InfoFrame (0x84)** — CT/CC/CA metadata, ≥1/2 fields. A sink with ASPs but no AIF **must mute**.
     On DCN the content is HW-generated from the Azalia `CHANNEL_SPEAKER`; the source only sets the SEND bit.
   - **General Control Packet (0x03)** — carries **AVMUTE**. **Many sinks unmute only on an AVMUTE SET→CLEAR
     *edge*, not on a steady-cleared state** (the vc4_hdmi upstream fix).

4. **The irreducible bring-up (discrete chips + vc4 + i915 + pre-DMUB AMD DCE all do the same, as part of a
   modeset — never as a live poke):** (a) bring the port up and let TMDS settle / link-train FIRST; audio is
   downstream of a *freshly-active* link; (b) hold the audio path in reset, program clock/N-CTS/format/
   channel-status/InfoFrame, release on a clean **edge**; (c) SW writes N, HW derives CTS; (d) send AVI +
   Audio InfoFrame continuously; (e) schedule ASPs, **clear AVMUTE LAST** (SET during setup → CLEAR when
   ready = the edge the sink waits for). Discrete chips hide this behind one HDMI-mode bit that triggers an
   internal PHY transition + output bounce; **AMD exposes that same transition as the `DIG_ENABLE`
   output-enable edge** (MMIO equivalent of ATOM `TransmitterControl(ENABLE, HDMI)`).

## Part 2 — agnos's exact gap

agnos ports the **entire source-side recipe correctly** — DIG_MODE=3, HDMI_CONTROL keepout/packet-gen,
DCCG audio DTO (SEL=0), the AZ endpoint (clock-ungate → CHANNEL_SPEAKER+HDMI_CONNECTION → AUDIO_ENABLED →
slot map → the `dce_aud_az_configure` descriptors), AFMT clock, AVI + Audio InfoFrame SEND, ACR N=6144/
AUTO_SEND, 60958 channel status, SAMPLE_SEND. Against the amdgpu-audibly-playing capture the DIG1 audio set
is **byte-identical** (only deliberate/benign diffs: RGB-vs-YCbCr AVI, ~11 ppm CTS, the FIFO-overflow symptom).

**Proof the sink IS in HDMI mode and IS parsing agnos's islands:** the 2026-07-14 green-screen — when agnos
briefly wrote amdgpu's *YCbCr* AVI bytes, the panel came up green/pink. A sink can only mis-decode RGB-as-YCbCr
if it is receiving, parsing, and honoring agnos's **AVI InfoFrame**. So DIG_MODE=3 took, the DIP engine runs,
the AVI egresses, the sink treats the link as HDMI. **"Still pure DVI, no islands" is refuted.**

**But the AVI and the audio-sample packets are different generators.** AVI = the generic-packet SEND engine
(CPU payload + SEND bit). ASPs = the AFMT draining its FIFO, gated on SAMPLE_SEND + ACR + DIP scheduling.
**"AVI egresses" does not prove "ASPs egress."** agnos's only egress instrument — the `AFMT_AUDIO_CRC` — is
inadequate: **tap1 is frozen at `0xd97638` across EVERY probe** (initial enable and sweep profiles 14/15
alike — it reads static IEC-60958 framing, not audio), and the CRC is **amplitude-blind** (the 1.55.17 −48 dB
sign-folded packing bug lit it identically to a correct tone). agnos has *no* proof that real audio-sample
packets leave the encoder.

**The gap = two DYNAMIC EDGES a live DIG_MODE flip skips, plus a content blind spot:**
1. the **DIG_ENABLE output-enable edge** (sink link event → re-arms its audio receiver);
2. the **AVMUTE SET→CLEAR edge** (the unmute many sinks require);
3. unverified whether the HDMI-path PCM is correct amplitude/sign (separate controller from the working analog).

## The DMUB question — resolved: MMIO is sufficient

> **⚠ SUPERSEDED (1.55.23): "no firmware seam needed — no DMUB, no ATOM" was wrong.** The audio-block *is* pure
> MMIO, but audio egress is gated on the **HDMI transmitter/encoder bring-up the GOP ran as DVI**, which is
> firmware (ATOM/VBIOS) work. agnos now runs the vendor's own VBIOS transmitter bytecode via a sovereign ATOM
> BIOS interpreter (`kernel/core/atom.cyr`, A2/A3 bit-correct on iron). ATOM turned out to be exactly the seam.

- **Pre-DMUB AMD proves it.** DCE8/10/11 (GCN, no display microcontroller) does HDMI audio 100% via REG_UPDATE.
- **DCN2.1's audio block is still pure MMIO** (`enc1_se_*`, no `dc_dmub_srv`). DMUB owns PSR/ABM/idle, not AFMT.
  The ftrace "zero DIG/AFMT writes during playback/modeset" = the block is configured ONCE at modeset then
  emits islands autonomously per-frame — steady-state autonomy, not a firmware hand-off.
- **The ATOM `TransmitterControl(ENABLE)` is CPU-interpreted MMIO** whose register effect is the `DIG_ENABLE`
  rising edge — exactly the MMIO agnos can do.
- **Conclusion: no firmware seam needed.** No DMUB, no ATOM. The template is the pure-MMIO `enc1_se_*` sequence
  agnos already implements + the output-enable edge.

## Part 3 — staged plan

### Stage 0 — a REAL egress instrument (do before trusting any burn)
Every burn has been un-adjudicable (tap1 frozen + amplitude-blind, no on-die wire observer). Get an oracle:
1. **USB HDMI capture dongle (~$15, MS2109/MS2130-class, UVC+UAC).** agnos HDMI-out → dongle → any Linux box →
   `arecord`/`ffmpeg` the UAC endpoint. Sink-independent ground truth: does agnos emit HDMI audio at all, and is
   the tone correct? Converts "listen and guess" into measured pass/fail.
2. **AVMUTE-honor test (zero hardware):** with GC_SEND|GC_CONT on, SET `HDMI_GC.AVMUTE`=1 alone and watch the
   panel — if it visibly blanks, the GCP island reaches the sink and its mute logic is live (which makes the
   Stage-1 clear-edge meaningful).

### ROOT CAUSE FOUND (2026-07-16, iron-confirmed signature) — feed-before-drain

> **⚠ SUPERSEDED (1.55.23): this was NOT the root cause.** The drain-before-feed reorder shipped and iron
> stayed silent; the DCN audio register class was subsequently exhausted (byte-for-byte amdgpu, still silent).
> Feed/codec/magnitude/FIFO-ordering all EXONERATED. The real blocker is the firmware HDMI transmitter
> bring-up (ATOM interpreter). Keep the FIFO-phase analysis as reference; do not treat the fix as the answer.

Stage-1 (the edges) burned and stayed silent, but the operator's two observations settled it: the **analog
jack plays the same tone perfectly** (PCM/HDA/DMA all good — content ruled out) and the **screen visibly
blanked** during the `DIG_ENABLE` drop (the sink *did* get a real link event and still played nothing). That
isolated the fault to one thing — **the AFMT audio FIFO fills but never drains audio sample packets** — and a
focused deep-dive nailed the mechanism:

**`hda_stream_arm` sets `SD_RUN` on the HDMI stream (tag 3) during the HDA block — seconds before
`gpu_hdmi_audio_enable` opens the AFMT drain (`AFMT_AUDIO_SAMPLE_SEND`).** So the GPU HDMI codec free-runs PCM
into the AFMT FIFO with the read side closed: the write pointer laps a never-drained FIFO (`AFMT_STATUS` bit24
`AUDIO_FIFO_OVERFLOW` latches early), and when `SAMPLE_SEND` finally opens the read pointer is **permanently
out of phase** — the IEC-60958 formatter clocks out **null cells**. That is the exact iron signature:
`AFMT_AUDIO_CRC` tap0 (FIFO input) full of real PCM, **tap1 (formatter output) = silence**, bit24 chronic.
amdgpu never hits it: ALSA `prepare()` configures the drain and `trigger(START)` starts the feed **last**,
into an empty FIFO with pointers coherent. Stage-1 failed because it cycled only the *reader*, never the feed.

**THE FIX (shipped): drain-before-feed ordering.** `hda_hdmi_feed_stop()` / `hda_hdmi_feed_start()` (hda.cyr)
clear/set `SD_RUN` on instance 1. `gpu_hdmi_audio_enable` calls `_stop` at the top (all encoder-audio setup
runs against a quiesced FIFO), arms the drain on the empty FIFO (overflow-ack → AVMUTE-clear → `SAMPLE_SEND`
0→1), and `main.cyr` calls `_start` as the **true terminal op, after `hda_hdmi_bind_single`** (which re-issues
`SET_STREAM_FMT` and would re-glitch the phase if the feed were already running). Verify: **tap1 goes
non-zero** (was "silence") and **`AFMT_STATUS` → `0x40000010`** (bit24 clear, matching amdgpu) — plus the ear.

> **⚠ SUPERSEDED (1.55.23): Stages 1–3 below (DIG_ENABLE edge, AVMUTE SET→CLEAR edge, PCM-content re-check, HPD
> bounce) were all pursued and did NOT produce sound; the audio register/edge class is exhausted. Stage 4
> (ATOM interpreter), dismissed here as "likely unnecessary", became the actual path — A2/A3 are done and
> iron-proven. Read the stages as history; the live plan is `hdmi-modeset-arc-155x.md` A4.**

### Stage 1 (superseded) — the cold output-enable + AVMUTE edge (kept as the link event) ✅ IMPLEMENTED
Rewrote the tail of `gpu_hdmi_audio_enable` (gpu.cyr) to, after all staging: SET AVMUTE + close the tap →
drop `DIG_ENABLE` → **hold ~120 ms** (14/15 held microseconds) → raise `DIG_ENABLE` + poll `DIG_SYMCLK_BE_ON`
→ settle → re-latch CS + re-open SAMPLE_SEND → hold ~50 ms → **CLEAR AVMUTE last** (the SET→CLEAR edge). All
MMIO; the DIG_ENABLE toggle is iron-proven recoverable (14/15 booted through it). **Verify by the Stage-0
oracle, not just the ear.**
- **Falsify:** dongle shows correct tone leaving agnos but XB323U still silent → the sink needs a real
  UNIPHY/HPD event (Stage 3). Dongle shows garbled/DC/low tone → Stage 2. tap1 still frozen + silent → the
  edge didn't re-arm the drain; iterate the down-window / re-arm order.

### Stage 2 — verify HDMI-path PCM content (cheap, console-safe)
Dump the 32-bit container words the **HDMI** HDA ring holds after refill (separate controller/stream from the
working analog path — a packing/sign/level bug there is invisible to both the CRC and analog success). Confirm
the sample is sign-correct, full-scale, in [31:16]. Run the CRC probe N× in one boot under a live tone — if
tap1 is invariant, the payload is a fixed pattern (points upstream).

### Stage 3 — force a real sink link event (console-risky; only if 1–2 confirm correct egress but sink silent)
HPD bounce (drive the DCN HPD line low→high so the sink re-reads EDID + re-inits its audio receiver), then if
needed cycle the UNIPHY/DCIO PHY transmitter power with DIG_MODE=3 latched (mabda's gfx9 PM4 path + atombios
`TransmitterControl` as register prior art). Stage a proven restore path; keep burn-isolated.

### Stage 4 — minimal ATOM interpreter (durable fallback; likely unnecessary)
Only if the MMIO edge provably cannot latch DIP scheduling. Report-7 argues strongly it is not needed.
> **⚠ SUPERSEDED (1.55.23): this became the ACTUAL path, not a fallback.** The MMIO edges could not egress
> audio and the register class was exhausted, so agnos built a sovereign ~700-line Cyrius ATOM BIOS interpreter
> (`kernel/core/atom.cyr`) that runs the vendor's VBIOS transmitter/encoder bytecode — A2/A3 done and
> bit-correct on iron. "Report-7 argues it is not needed" was wrong.

## Bottom line
Stop reflashing register-value hypotheses (that class is empty). **MMIO is sufficient; the fix is the
`DIG_ENABLE` output-enable edge + the AVMUTE SET→CLEAR edge** — the two dynamic events amdgpu's cold modeset
produces and agnos's live flip skips. Stage 1 is implemented and shipped on the enable path; the next burn
tests it (ideally with the Stage-0 dongle as adjudicator).

> **⚠ SUPERSEDED (1.55.23): the bottom line is inverted.** MMIO was NOT sufficient — the `DIG_ENABLE` +
> AVMUTE edges shipped and stayed silent, and the DCN audio register class is now exhausted. The blocker
> resolved to the firmware HDMI transmitter bring-up, now driven by the sovereign ATOM interpreter
> (`kernel/core/atom.cyr`, A2/A3 iron-proven). Current audio lead (A4) = the DCCG SYMCLKA re-prime. Live
> plan: [`hdmi-modeset-arc-155x.md`](hdmi-modeset-arc-155x.md).
