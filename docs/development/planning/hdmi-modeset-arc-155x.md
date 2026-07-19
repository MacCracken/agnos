# Sovereign HDMI modeset arc — own the transmitter, unblock the audio (slotted 1.55.x)

## CURRENT STATUS (2026-07-19, HEAD 1.55.24) — read this first

Audio slice of Thrust P (display). **A0–A3 ✅ DONE + PROVEN ON IRON. A4 (audio egress) is OPEN.**

**⚠⚠ RETRACTED 2026-07-19 (same day it was written): "THE DCCG SYMCLK RE-PRIME ARMED THE SINK" IS DOWNGRADED
TO *LOW CONFIDENCE*. Do not build on it.** An adversarial re-audit found three independent falsifiers:

1. **The symbol clock was ALREADY ON — measured, in every silent burn.** agnos's own read-only probe prints
   `gpu: audio probe dig1 fe=1000000 be=101 …` **byte-identically at line 160 of all eight burn logs**. `fe`
   bit24 = `DIG_SYMCLK_FE_ON`, `be` bit8 = `DIG_SYMCLK_BE_ON` (`gpu_regs.cyr:186`, `:456`) — read-only hardware
   **acks**. Both read ON *before* the write, in burns that were silent. A clock cannot be the missing lever
   when the silicon says it was already running. This also refutes the burn profile's own stated premise.
2. **Half the oracle predates the write by five burns and four cuts.** The shutdown release-pop was first heard
   at `audio_re_5` / **1.55.20**, and the identical "amp ARMED and DRIVEN, payload decodes as silence"
   inference was banked at 1.55.21. Its known precondition (`AFMT_RAMP` = 0/0/0/0) was restored at 1.55.21 and
   held through burns 7–10 — so burn 10's pop is the *predicted* consequence of a state that existed three
   burns earlier. **"First time in the arc" was simply wrong.** The other half — "noise floor" — is a new
   *report*, not a new *observation*: **no record anywhere says a noise floor was listened for and not heard on
   burns 7, 8 or 9.** And a noise floor discriminates *amp powered* from *amp muted*, not *sink locked to us*.
3. **Zero instruments moved.** Every dumped register is byte-identical between burn 8 (silent) and burn 10
   ("armed"): `DIG_FE_CNTL 1000100`, `DIG_BE_CNTL 10030200`, `AFMT_CNTL 101`, `AFMT_STATUS 40000010`,
   `HDMI_CONTROL 10019`, `HDMI_DB_CONTROL 1000`, `HDMI_ACR_STATUS_1 1800`. The write is **five blind absolute
   stores** — no pre-read, no readback, no dump row (`gpu.cyr:2985-2989`) — so **there is no evidence any bit
   in any of the five registers changed value at all.**

**★ OPERATOR TESTIMONY, 2026-07-19 — THE LAST SUPPORT IS GONE.** Asked directly whether burns 7/8/9 had an
audible noise floor, the operator answered: ***"there were a few burns in cycle that exposed the noise floor;
but can't recall at which ones."*** ⟹ **the noise floor is NOT unique to burn 10** — it recurs across the
cycle independent of the SYMCLKA write. Combined with falsifier (2) — the pop first heard at `audio_re_5` /
1.55.20 — **BOTH halves of the burn-10 oracle are now known to predate or recur independently of the write.
Nothing observed on burn 10 was new.** On sink-side state between 07-18 and 07-19 the operator reported
*nothing changed* but also *can't recall*, so sink drift stays formally open rather than excluded.

**⟹ POSTURE: `SYMCLKA` is an UNSUPPORTED candidate with no surviving evidence for it. Treat the block as a
NO-OP until a before/after read proves otherwise. Do NOT cite burn 10 as a breakthrough anywhere.** Further demotions worth carrying: the SYMCLKA↔DIG1 mapping is
**self-referential** (the code comment cites the same trace the values were copied from) and names a **DCE-era
PHY, "UNIPHYA", on a DCN 2.1 / RDPCS-DPCS part** — no vendor header was consulted; the block cannot
self-attribute anyway (five writes went out, one was named in the log line, and abs `0x176` — unknown function,
36/36 write-adjacency in the vendor trace — is at least as plausible as `0x159`); and abs `0x15C` is written
**idle** where amdgpu ends it **active**, so if anything in the block had a live effect, the likeliest one was
negative. Code stays in `gpu_hdmi_audio_enable` behind `#ifdef HDMI_DCCG`; `BURN_HDMI_DCCG`.

**✅ THE "TWO-VARIABLE BURN" WORRY IS RESOLVED — AND IT WAS NOT THE CONFOUND.** Burn 10 both added SYMCLKA and
dropped the live ATOM encoder path, which looked uninterpretable. It isn't: **burns `audio_re_3` through `_8`
ran NEITHER ATOM nor SYMCLKA and were ALL silent**, so removing ATOM merely returns the system to a
documented-silent baseline and cannot manufacture a signal that baseline never had. **Burn 10 is "burn 8 +
SYMCLKA" — a one-variable experiment.** The live ATOM run left zero residue (burns 7/8/9/10 report identical
DIG/AFMT/Azalia values, including the one register ATOM transiently cleared). **The real uncontrolled variable
is the ORACLE, not the register:** no ear record at all for burns 7/8/9; unrecorded monitor volume; and **two
uncaptured PHY-blanking burns in the 1.55.23 window tore down and re-established the HDMI link between the
silent baseline and the arming burn** — sink amp/mute/mode state is **sink-latched**, and every agnos
instrument is source-side and cannot see it.

**THE REMAINING GAP — the PAYLOAD is DIGITAL SILENCE (noise floor), not the tone.** The amp is on and receiving
a valid, all-zeros stream. Samples are non-zero at the AFMT formatter (crc 9e490d/7d9f3), HDA DMA runs
(lpib=16984), AZ_LPIB advances — so the sample content is being dropped/zeroed between the formatter and the
wire, OR the feed never fills instance-1's ring audibly. **We crossed from "sink ignores us" to "sink receives
us"; the last mile is the sample content.**

**NEXT STEP (a fresh session starts HERE).**

**⛔⛔ THE PREVIOUSLY-PLANNED "DCCG AUDIO-DTO READ-CLOCK DISCRIMINATOR" IS CANCELLED — IT IS AN ECHO REGISTER.
DO NOT WRITE IT, DO NOT BURN IT.** (Verified 2026-07-19 against `dcn_2_1_0_sh_mask.h` + `dce_audio.c`.) The
plan was "read the DTO0 accumulator/PHASE twice, see whether it advances." **There is no accumulator.**
`DCCG_AUDIO_DTO0_PHASE` and `_MODULE` are each **one 32-bit field bearing the register's own name**
(`…_PHASE__DCCG_AUDIO_DTO0_PHASE_MASK 0xFFFFFFFF`) — numerator/denominator of a fractional divider, pure
config. `dce_aud_wall_dto_setup()` only ever `REG_UPDATE`s them; nothing in amdgpu reads them back. Iron
agrees: `DTO0_PHASE` reads `0x3a980` (240000 = "generate 24.000 MHz") in **every** agnos burn AND on amdgpu's
audibly-playing link. A frozen read proves nothing; a moving read is impossible. **Zero information in either
branch** — exactly the failure mode the echo-vs-answer rule exists to prevent. Structural confirmation: where
AMD *does* have a running DTO accumulator they expose it (`DCCG_GTC_CURRENT`, 0x0063 BASE_IDX 1 — a live
32-bit readback of the GTC DTO count). **The audio DTO has no analogue**; the DCCG audio block is exactly five
registers, all config.

**AND THE QUESTION IT MEANT TO ANSWER IS ALREADY SETTLED — THE READ SIDE DRAINS.** `AFMT_AUDIO_CRC_DONE`
asserts only after `CRC_COUNT` (2048) samples physically traverse the AFMT. Pre-feed both taps read "did not
complete"; post-feed both complete with distinct, non-zero, content-bearing values. The underrun hypothesis is
dead on data already in hand.

**⛔ Do NOT set `DTO2_USE_512FBR_DTO` (bit20) either.** In `dce_aud_wall_dto_setup()` the HDMI branch writes
only `REG_UPDATE_2(DTO0_SOURCE_SEL, src_sel, DTO_SEL, 0)` then MODULE then PHASE — it never touches 512FBR;
only the DP/`else` branch sets it. Iron confirms: the audibly-playing HDMI link reads
`DCCG_AUDIO_DTO_SOURCE = 0x00000000`, all three 512FBR bits clear. Source and silicon agree.

**▶ THE REPLACEMENT BURN — cheaper, display-safe, and decisive about what is actually open. ✅ IMPLEMENTED
2026-07-19, PRE-BURN.** Build **only** via `BURN_HDMI_SYMCLK_AB=1 sh scripts/burn-prep.sh` (banner must read
`AGNOS 1.55.24 (HDA_HDMI+HDA_TONE+HDMI_SYMCLK_AB+HDMI_AUDIO_DUMP)`). New surface in `gpu.cyr`:
`gpu_symclk_capture/_report/_apply/_restore` + `gpu_hdmi_acr_nscale()`; `main.cyr` runs the A/B post-`sti`
while the HDA tone streams. Green pre-burn: check 11/0, `cyrius fmt`-stable, kprint lengths verified by the
new `scripts/kprint-len-check.sh` (it caught four off-by-ones in this very bite), and **`cmp`-proven that each
flag changes the artifact** — the ATOM_DRY lesson applied rather than assumed. Rubric + risk in the iron log:
[`#tracker-155x-a4-dccg`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-155x-a4-dccg).

**(A) INSTRUMENT THE SYMCLK BLOCK (free — rides any burn).** Read abs `0x159`/`0x15A`/`0x15B`/`0x15C`/`0x176`
**before and after** the write, print both, and add them as permanent `HDMI_AUDIO_DUMP` rows (the read
primitive `gpu.cyr:87-89` is a pure load). **If the before-values already read `0x000d000d` / `0x000d000a` /
`0x00001111`, the block is a proven no-op and the whole attribution collapses with no further burn.**

**(B) MAKE THE WRITE RUNTIME-TRIGGERED RATHER THAN A BOOT-TIME `#ifdef` — this is the in-burn A/B.** Move the
five stores out of the boot path into a shell/klug subcommand. Boot with the tone running and the write NOT
applied; the operator listens. Then issue it from the shell **in the same boot**; listen again. One flash, one
sink state, one cable, one volume setting, one monitor power cycle — the only thing changing between the two
listening windows is the five stores. That eliminates every confound the 8→10 comparison cannot: sink drift,
unversioned build variation, ATOM, the version boundary. Display-safe (host DCCG only; burn 10 completed to a
shell with a live 2560×1440 scanout).

**(C) THE ONE GENUINELY MOVING INSTRUMENT — `HDMI_ACR_STATUS_0` (0x209C+d).** agnos already reads it, and it
has been quietly reporting a **live hardware measurement** across eight burns: `0x3af5e000` / `0x3af5f000` /
`0x3af60000` = CTS **241502 / 241503 / 241504**, drifting ±1–2 LSB boot to boot, while dead DIGs read
`0x00000000`. agnos never writes those values — its only CTS constant is `0x3AF5C000` (241500), written only in
the F2/F3 sweep profiles, and the default path sets `ACR_SOURCE=0` = HW-measured. **Honest caveat that must not
be skipped:** at N=6144 / Fs=48 kHz, `CTS = f_TMDS·N/(128·Fs)` reduces to *exactly* `f_pixel` in kHz, so
"measured against the audio clock" and "just counting the pixel clock" predict the **same number** — the
current data cannot separate them. Two steps close it: **free, no burn** — add `HDMI_ACR_48_0`/`44_0`/`32_0`
(0x209A / 0x2098 / 0x2096, +d) to the dump; if they read anything other than ~241502 the echo hypothesis dies
outright. **The real discriminator, one register write, display-safe** (ACR affects only the audio
clock-regeneration packet, never TMDS timing): temporarily program `HDMI_ACR_N_48` to **12288** instead of 6144
and re-read CTS. **Doubles to ~483005 ⟹ the audio clock is genuinely in the measurement loop and the read
clock is proven alive at exactly 48 kHz. Stays ~241502 ⟹ pixel-only counter, tells you nothing about audio.**

**⚠ CORRECTION — `DCCG_AUDIO_DTO0_MODULE` DOES NOT MATCH amdgpu**, contrary to what this doc previously said.
Iron reads `0x24d9b2`; amdgpu's constant is `0x24d998` — 26 counts / ~10.8 ppm, because agnos derives MODULE
from the live pixel clock instead of copying the literal. PHASE (`0x3a980`) and SOURCE (`0`) *do* match
exactly. Treat MODULE as an open variable, not an already-matched one.

**⚠ TWO QUESTIONS FOR THE OPERATOR — they cost nothing and may close the case outright:** *did burns 7/8/9
have a noise floor?* and *did the monitor volume change between 07-18 and 07-19?*

**Better-evidenced omissions than SYMCLKA ever was** (open items, from the ground-truth trace): abs `0x052`
bracket (`0x110` open / `0x010` close) encloses amdgpu's **entire** audio-enable block and agnos does not write
it at all — ⚠ but see the DO-NOT below, bit8 is a pipe hold; and abs `0x101` is likewise never written by
agnos. Also on record: agnos emits `0x176` once vs amdgpu's 36/36 per-write cadence.

**⛔ DO NOT WRITE abs `0x52`** — the analysis (high conf) found bit8 is a pipe hold/soft-reset bracket around
the WHOLE pipe; latching it risks blanking the working scanout. It is NOT an audio lever. `IEC-60958 non-audio`
was RULED OUT (channel status normal: L=1/R=2). The FEED is EXONERATED (instance-1's ring genuinely carries
the −0.8 dBFS triangle). Retrieve the full synthesis from `wf_253879c6-6eb/journal.jsonl` (`synthesize` result)
if more detail is needed.

**FALLBACK (only if the payload path dead-ends):** the full HDMI modeset (`SetPixelClock` #12 + transmitter #76
+ OTG re-commit) wrapped in a **self-recovering OTG-frame-count watchdog** — but the transmitter #76
POWER-CYCLES the PHY and blanks the pipe (it's DMCUB/opaque for amdgpu, host-ATOM #76 for agnos), so this is
the risky last resort, not the current lead.

**Process lesson (cost two burns):** a new `#ifdef` mode-flag needs its `build.sh` define line, and you verify
it landed by **`cmp`-ing the two binaries**, not by trusting the burn tag — `ATOM_DRY` was a silent no-op for
two burns (both "live" and "dry" built byte-identical and drove the PHY, blacking the display twice).

**Interpreter (A2/A3), the strategic prize — already in hand:** `gpu_vbios_acquire` (gpu.cyr) + the ~700-line
Cyrius ATOM interpreter (`kernel/core/atom.cyr`) run the vendor's own VBIOS bytecode BIT-CORRECT on iron (the
1.55.23 DRY trace matches the `atom-interp.py` oracle exactly). It IS the P6 cold-modeset foundation.

**Build flags / burns (all in `build.sh` + `burn-prep.sh`):** `HDMI_DCCG` (the current lead) · `HDMI_ATOM`
(runs the interpreter, encoder-only by default) · `ATOM_RUN_TRANSMITTER` (opt-in the pipe-blanking #76, OFF) ·
`ATOM_DRY` (interpreter dry-run, no MMIO) · `ATOM_TRACE` · `ATOM_HALT`. Capture tool:
`agnosticos/scripts/capture-amdgpu-modeset-clock.sh`. Iron keepers indexed in `prior-art/README.md`.

---

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

## ⛔ SUPERSEDED (2026-07-18) — "MECHANISM = DMCUB command submission" (the T-series, Path A/B)

> **Superseded by the T2 host-ATOM pivot in the next section.** T2's read-only burn found the GOP's DMCUB
> **held in reset, no ring, no fw** (dormant at boot). DMCUB is an OS-driver-loaded thing; the boot-native
> transmitter path is **host-ATOM**, not DMCUB. The whole T-series (T1–T4, Path A "attach the live ring" /
> Path B "PSP-load the fw blob") is retired — replaced by the A-series ATOM interpreter. Kept for the
> mechanism analysis (DMCUB inbox anatomy) only; **do not implement the T-ladder.**

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

## ✅ T2 RESULT + PIVOT (2026-07-18) — DMCUB is DORMANT; the boot-native path is host-ATOM → build an interpreter

**T2 burn (audio_re_8, read-only):** `CC_DC_PIPE_DIS=0x10000` (block present), **`DMCUB_CNTL=0x20000`
(SOFT_RESET set, ENABLE clear → held in reset, NOT running)**, `SCRATCH0=0` (no fw), `INBOX1 base/size/wptr/
rptr all 0` (no ring). Verdict: **NOT attach-ready.** The display is up yet the DMCUB never ran ⇒ **the GOP
brought the transmitter up via HOST-ATOM** (the DMCUB is an OS-driver-loaded thing; at boot it is always
dormant, firmware modesets go through host-ATOM). So agnos's boot-inherited world is host-ATOM.

**PIVOT: don't build Path B (load the DMCUB — needs the fw blob + a console-risky soft-reset). Do what the
box does at boot — host-ATOM.** It produces host-MMIO writes (visible/debuggable), needs no firmware load and
no reset (zero console risk), and is the sovereign-AND-interoperable path (run the vendor's own bytecode).

**VBIOS acquired + parsed** (`sudo cat /sys/kernel/debug/dri/1/amdgpu_vbios`, 54KB, saved `vbios.rom`):
atomfirmware layout; MasterCommandTable @0x93fa. **Transmitter = command-table index 76, `v1_6`, 262B
bytecode** (@0xb162). Also present: `DIGxEncoderControl` #4 v1_5 (@0xae4e, 782B), `SetPixelClock` #12 v1_7,
`EnableDispPowerGating` #13. **Disassembly: the tables branch on `SWITCH` (parameter dispatch) + use `SETPORT`
(indirect I/O) within ~9 bytes ⇒ parameterized control-flow bytecode, NOT a linear replayable sequence.**

### The A-series bite ladder (sovereign ATOM interpreter)

| Bite | What | Gate |
|------|------|------|
| **A0** ✅ | VBIOS acquired + transmitter table located (#76 v1_6) + disassembled → interpreter required. | DONE |
| **A1** ✅ | **Python ATOM interpreter built + dry-run validated** (`scripts/atom-interp.py`, 1461 lines, verbatim line-for-line port of amdgpu `atom.c` — all 41 `atom_op_*`, 127-entry `opcode_table[]`, all 8 address spaces + `ATOM_WS_*` specials + IIO). Dry-run of `DIG1TransmitterControl(ENABLE, HDMI, phyid=0)` **steps to EOT clean, no desync, 239 opcodes, 21 reads / 17 writes / 5 delays** — and the writes land in **UNIPHYA (0x55xx) + RDPCS/DPCS (0x5Dxx–0x5Exx)** with 5/200/200/5/10µs PHY power sequencing = EXACTLY the RDPCS/DPCS block P5b named as the real transmitter PHY (abs ~0x5DE8). Cross-validates the whole arc. Default dry-run (no HW); `--live` mmaps BAR5. **Residual uncertainty is PARAMS not engine:** phyid (default 0=UNIPHYA, from object-info path0 HDMI→enum_id 1; phyid-sensitive, +0x400/inst), digfe_sel (0x02?), hpdsel (0) — confirm on iron; symclk=24150/lanenum=4/digmode=HDMI/action=ENABLE exact. | DONE (dry-run) |
| **A2** ✅ | **VBIOS acquisition in agnos** — `gpu_vbios_acquire()` (gpu.cyr) parses the ACPI VFCT table, verifies VendorID=0x1002, copies the ATOM image to a 2 MB page, checks the 55aa sig, sets `gpu_vbios_va/len`. Moved OUT of the `#ifdef HDMI_AUDIO_DUMP` guard so it's always compiled (the interpreter needs it). | **DONE — iron-proven (1.55.23)** |
| **A3** ✅ | **Port the interpreter to Cyrius** — `kernel/core/atom.cyr` (~600 lines), faithful port of `atom-interp.py`: VBIOS readers, all operand-decode tables, address spaces (REG via `gpu_mmio+idx*4` bounded <0x20000, PS/WS/FB/ID/IMM), get_src_int / put_dst / get_dst on a single global cursor `atom_ip`, structural 127-entry dispatch, recursive `execute_table_locked` (depth ≤8). Cyrius dialect: **no chained `else if`** (sequential `if`s on a fixed selector), sibling `var` hoisted, `^0xFFFFFFFF` for NOT, 1M-step cap replaces the Python wall-clock loop-guard, REPEAT/SAVEREG/RESTOREREG→clean abort. Runs the two tables in `atom_hdmi_transmitter_bringup()`, wired in `main.cyr` before `gpu_hdmi_audio_enable()`, gated `#ifdef HDMI_ATOM`. Instrumented: r/w/delay counters (vs the 21/17/5 oracle) + `#ifdef ATOM_TRACE` per-write trace + `#ifdef ATOM_DRY` safe mode (reads→0, writes traced-not-applied). | **DONE — iron-proven bit-correct (1.55.23)**: the DRY trace = encoder #4 5 writes + transmitter #76 21 reads / 17 writes / 5 delays, matching the atom-interp.py oracle exactly, no amdgpu |
| **A4** | **OPEN — audio egress.** Iron findings: live transmitter #76 **blanks the GOP pipe non-recoverably** (power-cycles the PHY: writes 556F/5E03/5DF0); encoder-only #4 is **display-safe but silent** (exonerated). **LEAD → the DCCG SYMCLKA re-prime: burn `BURN_HDMI_DCCG`** — write abs `0x159 = 0x000d000d`, the HDMI symbol clock agnos omits (DIG1→UNIPHYA phyid=0; amdgpu's HDMI-on-DIG1 sets it, AVI at `0x564d`); display-safe, host-visible. **Fallback if silent:** full HDMI modeset (`SetPixelClock` #12 + transmitter #76 + OTG re-commit) under a self-recovering OTG-frame-count watchdog. | IRON — **tone from XB323U** |

**Strategic upside:** the ATOM interpreter unlocks the ENTIRE VBIOS command surface (SetPixelClock, power
gating, DP, full modeset) — it IS the P6 cold-modeset foundation, not just the HDMI-audio unblock. Effort
**L/XL**, but bounded (ATOM is a ~50-opcode defined VM) and de-risked Python-first. The DMCUB Path B is
retained only as a fallback if the interpreter proves intractable (it won't — it's the vendor's own logic).

**A3 adversarial audit (2026-07-18, 6-dimension + per-finding-verify workflow):** 10 findings raised, **1
confirmed** (severity low, latent): `atom_op_div32` used Cyrius's SIGNED `/` on a 64-bit dividend that goes
negative when `divmul1`'s MSB is set → diverges from the oracle's unsigned divide. **FIXED** with bit-by-bit
unsigned division (running remainder stays < src < 2^32, so every compare/shift is positive-safe). DIV32 is
**not used by the transmitter #76 / encoder #4 tables**, so the A4 audio path was unaffected either way — but
the interpreter is the P6 foundation, so it's kept a faithful port. The 9 false alarms were deliberate
documented divergences (unimpl→abort, dropped wall-clock loop-guard, PLL/MC-not-wired) or A4-safe latents.
**Two A4-safe latents to revisit when extending the interpreter for P6** (both cleared for the transmitter
path, which nests ≤4 deep with ws ≤8 dwords): (1) the recursion **depth cap is 8** vs the oracle's 32 — bump
the cap AND the ws-pool level count together if a P6 table nests deeper; (2) each ws slot is a fixed **512 B
(128 dwords)** but `ws_count` is a u8 (max 255) — a table with `ws_count > 128` would overflow its slot into
the next depth's; size slots to 1024 B (256 dwords) before running any table with a large workspace.

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

## ⛔ SUPERSEDED — capture-and-replay bite ladder (P5a–P6)

> **Superseded by the P5b correction + the A-series ATOM interpreter.** P5a's captured "PHY sequence" was a
> mis-identified page-flip/cursor block; the real transmitter enable is firmware bytecode, not a replayable
> MMIO trace. P5c/P5d (implement a captured sequence) are moot. Kept for the P5a capture provenance and the
> risk/constraint carry-forwards only. **The live plan is the A-ladder above.**

### Bite ladder — each its own cut; user burns; iron-only (QEMU emulates no DCN/PHY)

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

**HDMI audio plays out the XB323U speakers on iron**, driven by agnos's sovereign HDMI transmitter bring-up —
now the sovereign **ATOM interpreter** (`kernel/core/atom.cyr`) running the vendor's own VBIOS bytecode
(supersedes the original "no ATOM" constraint; an interpreter of a defined VM is bounded + interoperable, the
anukūlana/Type-3 posture), with the console surviving — closing the display-audio backlog opened at 1.53.5 and
delivering the first sovereign HDMI-with-audio output. The interpreter is then the seed for the P6 full modeset.
