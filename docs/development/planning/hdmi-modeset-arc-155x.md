# Sovereign HDMI modeset arc — own the transmitter, unblock the audio (slotted 1.55.x)

**Thrust P, continued.** The display arc ([`kernel-display-arc-155x.md`](kernel-display-arc-155x.md)) owned the
GOP-lit pipe for scanout (P0–P2, blit#39) and drove the display-audio program to completion (P3). P3's audio
path is now **proven correct end-to-end** — but it is **blocked on one dependency this arc originally deferred
to P6+**: agnos rides the UEFI GOP's **DVI** modeset and never brings the HDMI **transmitter** up itself. This
sub-arc builds exactly that, and only that: the sovereign HDMI **encoder + PHY** bring-up. It is the smallest
slice of a full modeset that makes HDMI audio egress — and the natural first step toward the P6 full modeset.

Sibling docs: [`kernel-display-arc-155x.md`](kernel-display-arc-155x.md) (the parent display arc),
[`hdmi-audio-plan.md`](hdmi-audio-plan.md) (the audio-path first-principles model, now closed).

## Where we are — the audio path is DONE; the modeset is the wall

After ~24 iron burns and a decisive off-agnos experiment, the audio side is **exonerated, not merely
plausible**:

- **A from-scratch Linux userspace driver** (`agnosticos/scripts/agnos-hdmi-linux.py`) reproducing agnos's
  ENTIRE feed (HDA controller + codec verbs + DMA + tone, verbatim from `hda.cyr`), riding amdgpu's cold
  modeset, **PLAYED AUDIBLE SOUND**. So the feed, codec, DMA, and every AFMT/AZ/DIG audio register are correct.
- A **morph test** (replaying agnos's `DIG_MODE 2→3` flip on amdgpu's committed pipe) kept the tone playing —
  so the DIG-leaf flip is innocent too.
- **Source-verified against the real amdgpu headers** (2026-07-17): agnos already writes every audio-clock /
  AFMT / HDMI_CONTROL register byte-correct; `symclk_se` does not exist on DCN 2.1 (added 2024 for
  dcn35/dcn401); the FIFO overflows **with the clocks provably present** — a *link / data-island-acceptance*
  failure, not a clock failure.

**The one thing a live `DIG_MODE 2→3` flip structurally cannot reproduce** is the cold modeset's PHY/encoder
bring-up: on DCN 2.1 that is ATOM `DIGxEncoderControl(SETUP, HDMI, enable_audio=1)` + a real
`TransmitterControl(ENABLE, SIGNAL_TYPE_HDMI)` output edge (`dcn10_link_encoder.c:enable_tmds_output`,
`dce110_hw_sequencer.c:enable_stream`). The GOP ran these as **DVI, audio-off**. agnos reproduces every
downstream MMIO consequence but never re-brings-up the transmitter as HDMI — so the sink's audio receiver is
never armed by a genuine HDMI link event. (agnos's Stage-1 `DIG_ENABLE` bounce is the *wrong lever*: it toggles
the DIG **back-end**, not the **PHY**.)

## ⚠ P5b CORRECTION (2026-07-17) — capture-and-replay is a DEAD END; the transmitter is FIRMWARE

The capture-and-replay thesis below was **falsified by P5b**, source-verified against `dcn_2_1_0_offset.h`:

- The register block P5a isolated as "the RDPCS/DPCS PHY" (abs `0x3D3D–0x3DCE`) is **`mmHUBPREQ3_*` page-flip
  + cursor programming** — a desktop compositor idle-flipping the framebuffer, not PHY lane config. (The
  "cycling per-lane values" were front/back `DCSURF_PRIMARY_SURFACE_ADDRESS` alternation; the ~207× repeat was
  ~207 vblanks.) A P5a mis-identification, caught by header verification before any agnos write.
- The **real** RDPCS/DPCS PHY registers (abs `~0x5DE8–0x5EF0`) got **ZERO writes** in the whole capture.
- Because the genuine HDMI transmitter enable is `link_transmitter_control` → an **ATOM/DMCUB firmware call**;
  its PLL-lock/calibration run *inside* firmware, invisible to any MMIO trace. **There is no transmitter MMIO
  sequence to capture or replay.** The morph corroborates: agnos's DIG flip kept audio on amdgpu's pipe only
  because ATOM had already established the HDMI transmitter state; the flip cannot create it.

**⇒ The blocker is a SUBSYSTEM, not a register.** agnos's HDMI audio is gated on the firmware-driven HDMI
transmitter/encoder setup that the GOP does as DVI at boot and agnos has no way to redo as HDMI. The three real
paths — all P6-class sub-projects, none a burn:
1. **ATOM interpreter** — run the VBIOS's `DIGxEncoderControl`/`TransmitterControl` bytecode (the
   "sovereign-AND-interoperable" path, cf. the anukūlana/Type-3 posture). Bounded (ATOM is a defined VM) but real.
2. **DMCUB command submission** — drive the DMCUB firmware's transmitter-control command (Cezanne has DMCUB).
   Needs the sovereign DMCUB mailbox path (currently a "DO NOT TOUCH" hazard region).
3. **Full sovereign cold PHY modeset** — reverse-engineer the firmware's PHY bring-up and own it in MMIO. The
   largest, and the true P6 deep end.

The audio path (P3) remains 100% proven-ready and lights up the instant the HDMI transmitter state exists.
**P5c/P5d as written below (implement a captured PHY sequence) are moot** and superseded by this correction.

## ✅ MECHANISM RESOLVED (2026-07-18) — it's DMCUB command submission, and Bite #1 confirmed it

A 4-probe source-verified scoping pass + a free capture re-analysis settled the mechanism:

- **The transmitter enable is a DMCUB command**, not host-ATOM and not SMU. Source: `command_table2.c`
  `transmitter_control_v1_6/v1_7` both branch `if (dmub_srv && debug.dmub_command_table) transmitter_control_dmcub(...)`;
  `dcn21_resource.c debug_defaults_drv` ships `.dmub_command_table = true`; modern `green_sardine_dmcub.bin` ⇒
  `disable_dmcu = true` ⇒ transmitter control routes to the DMCUB, which does the PHY writes **internally, off
  the host bus**. That is why the capture saw zero PHY MMIO.
- **Bite #1 (free, from the existing capture) PROVED it:** `DMCUB_INBOX1_WPTR` (abs 0x6740) advances
  monotonically in **+0x40 (64-byte) steps, 106 commands** during the modeset — the inbox ring in active use.
  No RDPCS/UNIPHY/TMDS host-PHY writes anywhere (only DPP/MPC pixel-pipe). A host-ATOM path would show the PHY
  writes on the bus; it doesn't. **Mechanism = DMCUB, confirmed.**
- **SMU ruled out** (airtight): the Renoir VBIOSSMC enum has no transmitter/DIG/PHY message; agnos already sends
  the only relevant one (`UpdatePmeRestore`). **ATOM interpreter held as insurance** (~2200 Cyrius LOC + VBIOS
  image acquisition) only if the DMCUB proves un-attachable.

**THE LOAD-BEARING COMMAND:** `DIGX_ENCODER_CONTROL(sub_type 0, SIGNAL_TYPE_HDMI)` — it puts the DIG into
*true* HDMI mode with data-island packets, the exact thing agnos's live `DIG_MODE 2→3` bit-flip skips (hence
the chronic AFMT FIFO overflow + stale `HDMI_DB_CONTROL`). Then `DIG1_TRANSMITTER_CONTROL(sub_type 1, ENABLE)`.

### The new bite ladder (T-series — DMCUB inbox submission)

| Bite | What | Gate |
|------|------|------|
| **T1** ✅ | Confirm mechanism = DMCUB (free, from capture). `DMCUB_INBOX1_WPTR` advancing 106×64B; no host PHY writes. | DONE |
| **T2** | **Read-only**: is the GOP's DMCUB attachable? Dump `DMCUB_CNTL.ENABLE`, `DMCUB_SCRATCH*` mailbox-ready/dal_fw bits, the four `DMCUB_INBOX1_*` pointers (VERIFIED offsets only — the DMU region hangs on a blind read). `ENABLE==1 && mailbox_rdy==1` ⇒ **Path A (attach, effort M)**; else ⇒ **Path B (PSP-load fw, L/XL, console-risky)**. | IRON read-only |
| **T3** | Build the inbox submission: 64-byte `dmub_rb_cmd` push at WPTR + doorbell + poll RPTR. First command `DIGX_ENCODER_CONTROL(HDMI)`, then `DIG1_TRANSMITTER_CONTROL(ENABLE)` — payload per the green_sardine `DIG1TransmitterControl` crev (v1_6 vs v1_7; read `BIOS_CMD_TABLE_REVISION` from the dumped VBIOS first). | IRON — console survives |
| **T4** | Audio egresses — the proven-ready payoff. | IRON — **tone from XB323U** |

**Effort: M** if T2 shows a mailbox-ready GOP DMCUB (Path A: reuse the live ring); **L/XL** if agnos must
PSP-load `renoir_dmcub.bin` itself (Path B: INST_CONST/BSS FB windows, `DMCUB_REGION3_CW*`, reset-release, own
ring — a multi-cycle subsystem, and the reset tears down the GOP's DMCUB on a single-console box). Biggest
risk = the firmware-load blocker; T2's read-only probe decides it before any commit.

## Thesis (SUPERSEDED — see P5b correction above) — own the transmitter, without ATOM, by capture-and-replay

The GOP already runs the **pixel PLL** (241.503 MHz, measured at P3b-i) and the **OTG** (timing, scanning) —
agnos reuses both unchanged. This arc adds only the **encoder + PHY** re-bring-up in HDMI mode. Two hard
constraints shape the whole approach:

1. **No ATOM.** `DIGxEncoderControl` / `TransmitterControl` are ATOM bytecode in the VBIOS. agnos has no ATOM
   interpreter and will not grow one (a bytecode VM is the opposite of sovereign). We replicate their **MMIO
   effects** directly.
2. **Do not derive PHY registers blind.** The UNIPHY/DCIO PHY register map is large, undocumented in the public
   headers beyond offsets, and **writing the wrong one hangs the machine** — a lesson already paid for (a blind
   read-sweep of the OTG/DCCG blocks locked archaemenid on 2026-07-17). So we **capture what amdgpu's ATOM
   actually writes** during a DVI→HDMI transition and replay the isolated transmitter/encoder subset. Measure,
   then write — the method that carried the whole arc.

The payoff is proven-ready: the moment the transmitter comes up as HDMI, the already-correct audio path
egresses. And the transmitter bring-up is the foundation the P6 full modeset needs anyway.

## Bite ladder — each its own cut; user burns; iron-only (QEMU emulates no DCN/PHY)

| Bite | What | Validate |
|------|------|----------|
| **P5a** | **CAPTURE the transmitter bring-up (Linux, safe). ✅ DONE (2026-07-17).** ftrace `amdgpu_device_wreg` (NOT `dc_wreg` — that fired 0×; amdgpu drives these via the raw MMIO path, which is where ATOM's writes land) across an HDMI unplug/replug. **Result:** the transmitter/PHY block is **BASE_IDX 2, DCN offsets ~0x86D–0x90E** (87 regs) — the **RDPCS/DPCS combo-PHY**, which agnos touches NONE of. A ~16-reg group at 0x89D–0x8B0 is an **indexed per-lane loop** (cycling values in 0x8A6/0x89E); a 0x80/82/8C/8E cluster toggles bit8 (output/clock enable). Audio DIG/AFMT/AZ all match agnos. Artifacts: `docs/development/prior-art/amdgpu-hdmi-modeset-writes-0717.txt` (raw) + `…-transmitter-phy-seq-0717.txt` (isolated PHY sequence). | LINUX — **PASS**: PHY bring-up captured + isolated |
| **P5b** | **DERIVE the sovereign sequence (verified offsets).** Cross the P5a capture with `dcn_2_1_0_offset.h` / `dcn10_link_encoder.c` / `dcn10_stream_encoder.c` to build the minimal ordered MMIO sequence for: encoder HDMI SETUP (the DIG side of `DIGxEncoderControl`) + PHY output DISABLE→ENABLE edge (`TransmitterControl`). **Every offset verified against the header, not derived.** Add constants to `gpu_regs.cyr` with a provenance header. No agnos writes yet. | REVIEW — every write has a header-verified offset + a capture line backing it |
| **P5c** | **IMPLEMENT `gpu_hdmi_transmitter_bringup` (iron).** Add the P5b sequence to agnos: reuse the running PLL/OTG, reconfigure the DIG encoder for HDMI, and drive a **real PHY output disable→enable edge** (the genuine TMDS-loss/re-lock link event the sink needs). Call it in `gpu_hdmi_audio_enable` in place of the Stage-1 `DIG_ENABLE` back-end bounce. Gated on `HDA_HDMI`; the default kernel never touches the PHY. **Console will blank during the PHY edge and must re-lock** (like the GOP flip). | IRON — console survives the PHY edge and re-locks |
| **P5d** | **VALIDATE audio (iron, the payoff).** With the transmitter genuinely HDMI-committed, the proven-ready audio path egresses. Confirm by ear (operator) + the AFMT instruments (`tap0/tap1`, `AFMT_STATUS` bit24 should now settle, the sink's audio receiver armed by a real link event). This is the cut that closes the display-audio backlog opened at 1.53.5. | IRON — **tone from the XB323U speakers** |
| **P6** | **The deep end (follow-on arc, NOT this sub-arc).** Full sovereign modeset from cold: pixel PLL program + OTG timing program + DIG + PHY, so agnos owns the pipe without any GOP inheritance — the foundation for multi-display, mode changes, and the desktop arc. P5 is the transmitter slice of this; P6 generalizes it. | IRON |

Ordering: strictly P5a → P5b → P5c → P5d. P5a/P5b are safe (Linux capture + paper derivation); the risk lives
in P5c (the first sovereign PHY write on iron). P6 is explicitly out of scope here — this sub-arc unblocks
audio with the minimum transmitter bring-up, and hands P6 a verified PHY sequence to build on.

## Key facts & constraints (carry-forward)

- **Reuse, don't reprogram, the PLL + OTG.** GOP's pixel clock (241.503 MHz) and OTG timing are running and
  correct (P3b-i). This arc touches only the encoder + PHY. Do **not** reprogram clocks/timing — that is P6 and
  it is where the real hang risk lives.
- **The PHY edge is the load-bearing act.** The sink arms its audio receiver on a genuine HDMI link event
  (TMDS-loss → re-lock as HDMI). agnos's prior `DIG_ENABLE` (DIG back-end) bounce blanks the screen but does
  **not** drive the PHY, so it is not the event the sink needs. The real transmitter disable→enable is.
- **No blind GPU register access — reads OR writes.** Gated-clock domains hang on read (proven 2026-07-17);
  wrong PHY writes hang harder. Only header-verified offsets in known-ungated domains, only via the P5a→P5b
  capture-then-verify path. **Never a range sweep.**
- **The audio path is frozen and correct.** No more audio-register changes are warranted — every one is
  byte-matched to amdgpu-playing. If P5d is still silent, the fault is in the P5c transmitter sequence, not the
  audio program. Do not re-open the audio registers.
- **Instruments already in place:** `AFMT_AUDIO_CRC` tap0/tap1 (content-sensitive), `AFMT_STATUS` bit24, the
  `HDMI_AUDIO_DUMP` block, and the operator's ear (the only egress oracle — HDMI is transmit-only).
- **Bench available for P5a/P5b:** `agnosticos/scripts/` — `agnos-hdmi-linux.py` (the proven-audible feed repro,
  now the reference for "audio works given a committed pipe"), `poke-dcn-audio.py` (live-path perturbation by
  ear), `dump-dcn-audio.py` (read-only capture; `--pipe` hard-disabled after the lockup). Requires
  `amd_iommu=off` + `modprobe.blacklist=snd_hda_intel` to match agnos's raw-DMA / free-codec environment.

## Risk register

- **P5c PHY write hangs the console (medium/high, mitigated).** Mitigation: P5a/P5b make every write a
  *replay of a captured amdgpu write at a header-verified offset*, not a guess; iron-burn-gated + `HDA_HDMI`-only,
  so the default/MVP kernel never risks it and recovery = reflash.
- **Capture doesn't cleanly isolate the transmitter writes (low/medium).** amdgpu's modeset writes a lot;
  mitigation: diff a DVI→HDMI transition against a no-op, and cross-reference against the named amdgpu functions
  (`enable_tmds_output`, `hdmi_set_stream_attribute`) to label each write.
- **The MMIO effects of ATOM aren't fully MMIO-reducible (low).** Some ATOM steps touch SMU/PMFW, not just DCN
  MMIO. Mitigation: the audio-clock DTO + AZ + AFMT are already proven sufficient on the audio side; the PME
  wake (`gpu_smu_msg`) path already exists in agnos for the one known SMU touch.

## Definition of done

**HDMI audio plays out the XB323U speakers on iron**, driven by agnos's sovereign HDMI transmitter bring-up
(no ATOM, no GOP-DVI inheritance for the encoder/PHY), with the console surviving the PHY edge — closing the
display-audio backlog opened at 1.53.5 and delivering the first sovereign HDMI-with-audio output. The verified
PHY sequence is then the seed for the P6 full modeset.
