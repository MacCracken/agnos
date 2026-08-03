---
name: AGNOS Kernel State
description: Live state only — kernel head, open cut, next bite, pins, flash gate, pointers.
type: state
---

# AGNOS Kernel — Live State

> **⛔ 120-LINE HARD CAP. NOT A LOG.** This file reached **694 lines** by absorbing arc narrative that belongs in [`CHANGELOG.md`](../../CHANGELOG.md), [`planning/gpu.md`](planning/gpu.md), or the burn ledger. Over 120 lines means consolidate: cut prose, never facts. Verify any single item against the live `VERSION` / `cyrius.cyml` before acting. **Last refresh** 2026-08-01.

## TRUE — measured, current

| Field | Value | Source |
|---|---|---|
| Kernel head | **1.56.34 — OPEN** (opened 2026-07-31, HDMI audio) | [`VERSION`](../../VERSION) |
| Previous cut | 1.56.33 closed 2026-07-30, awaiting the user's tag | [`CHANGELOG.md`](../../CHANGELOG.md) |
| `build/agnos` on disk | **1,928,744 B**, 2026-08-01 00:21 — ⛔ **not flashable**, see *Flash gate* | `wc -c build/agnos` |
| Cyrius pin | **6.4.78** | `cyrius.cyml [package].cyrius` |
| Bootloader | gnoboot **0.6.0**; Path C, `RDI = &boot_info`, magic `0x41474E4F`, entry `0x1000a8` | `gnoboot/VERSION` |
| Iron target | archaemenid — Beelink SER NUC, AMD Cezanne APU, 4 CPUs, 64 GB. Build host **is** the target, so no serial channel exists. | — |

**NEXT BITE — the DESKTOP iron burn** (user-directed 2026-08-02). Two commands, one boot: `iam`, then `aethersafha`. `iam` is the arming step — a *completed foreground run* is what used to poison the CPU's syscall stack for the next large binary (see the fix below), so a burn that launches the compositor first tests the easy case. The panel is the readout: crab's dual file panes + the probe window means the whole path works on silicon. Text variant if a photo is inconvenient: `aethersafha --clients` prints `run: exit 95` for both-presented and stops itself after 30 s.
Outcomes: desktop with client windows ⇒ works · chrome but no clients ⇒ the `spawn_path` routing did not hold on iron · `run: exit 142` ⇒ the `#PF` is NOT the kstack bug · box resets ⇒ same fault, kstack fix incomplete.

**LANDED 2026-08-02, QEMU-verified with a control, NOT yet burned — the syscall-kstack restore.** `execwait #37`'s step (h) restored this CPU's SYSCALL kernel stack to the **raw identity VA** `0xF10000 + cpu*0x10000` instead of its direct-map alias, while `syscall_kstack_reserve` and step (f) both use the direct map. Region 7's identity VA (14-16 MB) is inside the user-segment range, so **every completed foreground `run` re-armed the 1.51.x "ark won't run" fault** for any later proc whose image reached past 15.06 MB. `/bin/aethersafha` (14.87 MB) is the first binary large enough to hit it. Control: on the unfixed kernel the armed sequence **triple-faults the machine**; fixed, it reaches 2 clients connected + presented. New harness mode `AE_CLIENTS_MODE=armed` exists precisely because every prior mode launched the compositor as the boot's FIRST command and could not see this. Paired userland change: agnoshi routes the foreground through `spawn_path #43` + a waitpid poll (pipelines and `>` stay on `#37`).

**HDMI audio is PARKED mid-bite, not abandoned** — the CRC null calibration (`MDO_OP_CRCCAL` / `#93` op `0x0A` / `/bin/modeset --crccal`) is still the correct next audio step and is still unbuilt. It goes first *within that arc* because `DONE=1, CRC=0` is equally "2048 zero samples traversed" and "the counter completed and nothing traversed", and the second **inverts which half of the pipe is at fault**; `--crccal` needs no ear, so it is immune to the sink-latched state that made ~24 prior burns un-adjudicable.

Landed for 1.56.34 but **never built, therefore unverified**: `MDO_OP_CRCCAL` + `mdo_crccal()` · `hda_hdmi_feed_running()` (reads `SD_CTL` RUN — the hardware, not the `hda_stream_on` bookkeeping) · `--crccal` + usage · 13 `kprint` length corrections. Required flags for any HDMI-audio calibration burn: `HDA_HDMI` + `HDMI_ATOM` + `GPU_AUDIO_PROBE` + `HDA_TONE`.

### Flash gate

▶ **The 2026-07-31 pause is RESOLVED** (user-directed, 2026-08-02). Today's kernel, harness and staged agnsh are one attributable change set: `check.sh` **23/23**, `sweep.sh` **15/15**. ⚠ The hazard recurs the instant two sessions share this tree again — it is a **worktree** problem, not a one-time event.

⛔ **`build/agnos` is only flashable straight out of `scripts/burn/burn-prep.sh`.** Prep deletes the artifact + stamp up front so an abort leaves NOTHING to flash, and any smoke run afterwards rebuilds it as a compile-gated kernel — that is how a DOOM_SELFTEST kernel got flashed on 2026-08-02. `burn-verify.sh` cannot catch a stale-but-self-consistent pair; absence is the only reliable failure mode.

⚠ The **desktop** burn wants a BARE production kernel — no `BURN_SELFTESTS`, no HDMI-audio flag set. The 1.56.34 **HDMI-audio** burn card is a different artifact: `build/agnos` **1,985,728 B** + `/bin/modeset` **41,800 B** (md5 `c16a0f3b…`), and it requires `HDA_HDMI` + `HDMI_ATOM` + `GPU_AUDIO_PROBE` + `HDA_TONE`. Do not mix the two — a string check cannot tell a bare kernel from an `HDMI_ATOM` one, only the size can. For modeset: `exit 95` means the writes went out; it does **not** mean sound came out.

`/.modeset-armed` is an arm-once-per-boot latch that survives reboots **on purpose**, so a wedging modeset cannot re-fire. A latch left by a prior boot blocks every arm of the next one (`exit 98`). Recovery is `rm /.modeset-armed` plus a power cycle — **no reflash is ever needed** for any modeset failure mode.

### Toolchain pin — provenance, not enforcement

`scripts/build.sh` invokes the cyrius wrapper as `"$CYRB" build --no-deps …` — **without `--strict-pin`**. A newer installed `cycc` therefore builds agnos **warn-only** until the pin is bumped, so check `cyrius --version` when provenance matters. For the freestanding kernel the pin is largely **provenance**: the binary has been `cmp`-byte-identical across pin moves (6.3.9 → 6.3.43 both produced `build/agnos` at 1,345,512 B, cmp-proven). Ring-3 consumers, not the kernel binary, are what a pin bump unblocks. Hard floor: `symlink` #63 (agnos 1.51.0) needs `sys_symlink`, which exists only in cyrius ≥ 6.3.6. Cyrius is hands-off; pin lag is often a deliberate hold, not drift.

### CORRECTED — this file previously carried both of these wrong

**`boot_info` is 120 bytes / `0x78`, not 80.** magic `0x41474E4F` @0x00 · version 2 @0x04 · struct_size **120 (0x78)** @0x08 · flags @0x0C · fb_phys @0x48 · fb_pitch @0x50 · fb_width @0x54 · fb_height @0x58 · fb_pixel_format @0x5C · fb_size @0x68 · END tag @0x70. Confirmed against gnoboot's own CHANGELOG (`struct_size 0x78`, unchanged since 0.4.3, which added `fb_size` at 0x68 and moved END 0x68 → 0x70). 80 bytes was the pre-0.1.0 v1 size. Framebuffer fields are **inlined at fixed offsets**, not in the tag stream, because the boot-shim canary reads `fb_phys` from raw asm at instruction #1.

**The AMD-Zen scanout residue is RESOLVED at 1.55.28, not parked.** Root cause was a surface/raster **scale** mismatch, not tiling and not DCC: the firmware leaves an 800×600 surface DCN-scaled to 2560×1440 while `boot_info` reports the **output** geometry, so `fb_console` rendered 2560-wide and smeared. Fix is `gpu_scanout_matchgeom` — read the real viewport (HUBP `0x5EA` = 800×600) and pitch (`0x607` = 832 px) and override `fb_console`'s geometry. **Read-only, no register writes.** Neither parked option (HUBP `clear_tiling` port, simpledrm-style shadow-buffer console) was needed. Residual, accepted by operator decision 2026-07-20: the ~84 boot lines painted before the register aperture maps.

### Sweep timing — actionable, measured 2026-07-23

`scripts/sweep.sh` takes **≈10–11 min and almost all of it is DEAD AIR.** QEMU **never exits on its own** — the kernel boots, prints, halts, and sits until `timeout` kills it — so every run consumes its full `QEMU_TIMEOUT` (57 smoke scripts carry one). Proven by shrinking one: `fp-selftest-smoke` returns "4 passed, 0 failed" **identically** at `QEMU_TIMEOUT` 40 → 15 → 8 → 5 s. The kernel build itself is 1 s. Fix is **harness-only**: run QEMU in the background and poll the serial log for the smoke's own terminal marker, killing on match, with `timeout` kept as the failure backstop. Expected ≈10–11 min → 1–2 min. ⛔ **Do NOT simply shorten timeouts** — that trades dead air for flaky truncation.

## FALSIFIED — do not re-open

- **Sequencing is NOT eliminated.** The M9 burn (1.56.15) that "eliminated" it was a **null experiment** — both arms streamed digital silence (no `HDA_TONE`, no ring-3 feed), so a healthy, entirely believable log was produced by a zero-filled ring. Retracted; sequencing is re-open.
- **L1 (Linux-userspace discriminator) returned VOID**, 2026-07-24/25 — positive-control arm D was silent with all four validity conditions verified, so it carries **zero** information. Never write it up as "sequencing exonerated". Structural cause: the two writes agnos performs routinely (`OTG_MASTER_EN` → 0, and the `FE_SOURCE_SELECT` BE↔FE bracket) each hard-wedge the APU from userspace.
- **The GOP-side `SetMode` lever, both forms** — same-mode re-arm (gnoboot 0.4.1, Attempt 74) and different-mode bounce (gnoboot 0.4.2, Attempt 78). AMD Zen UEFI elides both; no flicker on VGA or HDMI.
- **The tiled/DCC scanout thesis** (OSDev #57150) — survived two months as the last standing hypothesis and was still wrong. See the correction above.
- **Path A (ELF64 + multiboot2 via GRUB on UEFI)** — dead 2026-05-13; GRUB's `grub_relocator64_efi_boot` self-patches its own `.text` under strict W^X. gnoboot replaced it. Do not revive by patching GRUB.
- The HDMI-audio dead-end corpus (DCCG symbol-clock lead · the register-poke class · sample magnitude · AFMT RAMP · the offset axis, 105/105 · the DMCUB T-series · `phyid = 0`) lives in [`planning/gpu.md`](planning/gpu.md). **Surviving candidates: (b) a write that does not latch · (c) the bare-metal environment.**

## OPEN

- **1.56.34 HDMI audio** — the one open cut. Next bite above.
- **Order once the tree is clear**: build → `check.sh` → `sweep.sh` → the in-boot A/B listening harness. That harness needs a **negative control in the same boot**, and its arms must be blinded by **tone band**, never by removing the tone (arms ~an octave and a half apart: LOW for `--audio-pre`, HIGH for `--audio-post`, so the operator reports *which*, not yes/no, and a null is real data). All audio arms run in ONE boot — a cross-boot comparison cannot control the sink's latched amp/mute state.
- **`modeset-tool-smoke` mask collision — already CLOSED in-tree.** The 1.56.34 op-mask change moves `MDO_OP_SUPPORTED` 639 → **1663** (un-armed) and 1023 → **2047** (armed); `scripts/smoke/modeset-tool-smoke.sh` already asserts 1663/2047 (only a stale `639` remains in a comment at line 94). agnosticos `state.md` still lists this as an open collision — it is not.
- **The STAGE-1 imitation-edge removal** is a restructure, not a deletion — that block also holds the AVMUTE unmute and the FIFO drain arming. It follows the instrument work, with a burn, never blind.
- **SDMA** — parked with a known resume state, an agnos **setup gap** and not a hardware limit (Linux drives SDMA on this box). Resume state: `rptr 0 wptr 44 cnt 266269 base 4102029824 halt 0 cap 0 cntl 262146`. Detail in [`planning/gpu.md`](planning/gpu.md).
- **aarch64** — compile-only, no boot harness, **not gated** (test.sh/check.sh/CI are x86-only). Its own future arc (decade 1.6x), not maintained in lockstep.

## Pointers — the content lives at these, not here

- **GPU / display / HDMI audio** — every register, burn result and falsified hypothesis: [`planning/gpu.md`](planning/gpu.md). *The* single GPU document; no new GPU arc docs.
- **Burns** — agnosticos [`iron-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-log.md), the consolidated burn ledger (⚠ being created by the 2026-08-01 doc consolidation; until it lands the burns are in `iron-nuc-zen-log.md` + `-mvp.md` + `-mvp2.md`). Measured captures in agnosticos `docs/development/prior-art/` — those `.txt` files are irreplaceable iron evidence, reference them, never edit them.
- **Syscall ABI**, per-call contract — [`agnos-userland-abi.md`](agnos-userland-abi.md). **Build flags** and compile gates — [`build.md`](build.md).
- **Per-cut narrative and size trajectory** — [`CHANGELOG.md`](../../CHANGELOG.md). **Milestones** — [`roadmap.md`](roadmap.md). **Ecosystem-wide state** — agnosticos `state.md`.

`scripts/version-bump.sh` refreshes the header date and the Version row atomically with the bump; the body is a manual sweep at each closeout. If a section here starts telling a story, it belongs in one of the pointers above.
