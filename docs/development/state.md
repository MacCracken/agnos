---
name: AGNOS Kernel State
description: Live state only — kernel head, open cut, next bite, pins, flash gate, pointers.
type: state
---

# AGNOS Kernel — Live State

> **⛔ 120-LINE HARD CAP. NOT A LOG.** This file reached **694 lines** by absorbing arc narrative that belongs in [`CHANGELOG.md`](../../CHANGELOG.md), [`planning/gpu.md`](planning/gpu.md), or the burn ledger. Over 120 lines means consolidate: cut prose, never facts. Verify any single item against the live `VERSION` / `cyrius.cyml` before acting. **Last refresh** 2026-08-11.

## TRUE — measured, current

| Field | Value | Source |
|---|---|---|
| Kernel head | **1.56.43 — CLOSED 2026-08-11. NO CYCLE IS OPEN.** ⛔ Do not open one without the operator naming the number. | [`VERSION`](../../VERSION) |
| Previous cut | **1.56.42 RELEASED 2026-08-10** — PS/2 deleted from the kernel · the USB pointer binding · a process table that NAMES its exhaustion · the covered-console `klug` spill. 1.56.41 before it: the desktop's window management on iron. | [`CHANGELOG.md`](../../CHANGELOG.md) |
| `build/agnos` on disk | 1,980,216 B, 2026-08-11 — **1.56.43 bare, BURNED and PASSED**. ⚠ Any smoke/test run rebuilds it without the burn flags — re-run `burn-prep.sh` before any flash | `scripts/burn/burn-verify.sh` |
| Cyrius pin | **6.4.78** | `cyrius.cyml [package].cyrius` |
| Bootloader | gnoboot **0.6.1** (GOP mode selection — obtains a real 2560x1440 framebuffer); Path C, `RDI = &boot_info`, magic `0x41474E4F`, entry `0x1000a8` | `gnoboot/VERSION` |
| Iron target | archaemenid — Beelink SER NUC, AMD Cezanne APU, **8c/16t (agnos parks APIC id ≥ 4, runs 4)**, 64 GB. Build host **is** the target, so no serial channel exists. | — |

⭐ **RESOLVED 1.56.35 — the `-smp 4` fault was `EFER.NXE` never enabled on the APs** (`smp.cyr:514`; the AP trampoline set LME only, so bit 63 of a paging entry was RESERVED and `proc_map_page_nx` sets it on every W^X data page and user stack). `-smp 4` reaches **connected 2 / presented 2, exit 95**.
⭐⭐⭐ **The desktop arc CLOSED at 1.56.42** and its forward work moved into aethersafha's own roadmap (M6, userland). Per-cut narrative → [`CHANGELOG.md`](../../CHANGELOG.md); burn ledger → agnosticos [`iron-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-log.md). The whole local-IPC channel band (`chan_*` on `#97`, bites 0-11) closed at **1.56.40** — `#97` replaced TCP-on-loopback, stdio rides a channel as a PTY, and pipelines stream byte-exact through a 4080 B ring.

⚠ **Desktop-arc negatives that still stand** — these are the ones a reader will otherwise assume closed: `#98` **RESYNC is not iron-proven** (the ring never overflowed on any burn, so only the DRAIN was exercised); `#91` has no correct consumer and batched `#92` is unreachable; and **no burn has ever measured frame duration**, so there is **no speed claim** from any frame count.

⚠ **`AE_CLIENTS_SMP` defaults to `"1"`** — pass `AE_CLIENTS_SMP=4`; it passes, and 4 is what archaemenid runs. ⛔ **`AE_CLIENTS_MODE=desktop` is FLAKY** (3 runs on one kernel, two opposite failure shapes, and a flake was briefly misattributed to a bite). Do not gate on `desktop` mode until that is understood.

⛔ **Do not over-retract the TCP result.** The operator's ruling is that TCP is the **wrong primitive** for local display IPC — not that it never worked. `aethersafha-clients-test.py` byte-scans the kernel and hard-exits on any selftest hook, and attaches a real NIC for DHCP, so its 2-client connection was never rigged. Erasing it destroys the evidence for the distinction.

**HDMI audio — ⏸ SHELVED 2026-08-11, not parked mid-bite.** ⛔ The `--crccal` calibration this file previously named as "the correct next step, still unbuilt" **has since been built and run**; it is history, not a plan. Four further burns established that **every source-side observable says PLAYING and there is still no sound**. ⛔⛔ **tap 1 is frozen at `4dc450` across five burns and two different DTO clock values** ⇒ "stuck instrument" now leads over "packetiser emits constant data", and **tap 1 must not be cited as evidence until re-validated** — including in the ~24 silent burns that lean on it. ⚠ Arm 1 unmutes with the FE detached and OTG stopped, so it was never a valid control ⇒ **sequencing is re-opened**. ⛔ **Do not resume by re-running any instrument in the ledger**: everything agnos owns sits at or before the AFMT tap and that half is exhaustively green. This leg needs an oracle that observes the **WIRE**. Full ledger → [`planning/gpu.md`](planning/gpu.md) and the agnosticos burn log.

### Flash gate

▶ **The 2026-07-31 pause is RESOLVED** (user-directed, 2026-08-02). Today's kernel, harness and staged agnsh are one attributable change set: `check.sh` **23/23**, `sweep.sh` **15/15**. ⚠ The hazard recurs the instant two sessions share this tree again — it is a **worktree** problem, not a one-time event.

⛔ **`build/agnos` is only flashable straight out of `scripts/burn/burn-prep.sh`.** Prep deletes the artifact + stamp up front so an abort leaves NOTHING to flash, and any smoke run afterwards rebuilds it as a compile-gated kernel — that is how a DOOM_SELFTEST kernel got flashed on 2026-08-02. `burn-verify.sh` cannot catch a stale-but-self-consistent pair; absence is the only reliable failure mode.

⚠ The **desktop** burn wants a BARE production kernel — no `BURN_SELFTESTS`, no HDMI-audio flag set. The 1.56.34 **HDMI-audio** burn card is a different artifact: `build/agnos` **1,985,728 B** + `/bin/modeset` **41,800 B** (md5 `c16a0f3b…`), and it requires `HDA_HDMI` + `HDMI_ATOM` + `GPU_AUDIO_PROBE` + `HDA_TONE`. Do not mix the two — a string check cannot tell a bare kernel from an `HDMI_ATOM` one, only the size can. For modeset: `exit 95` means the writes went out; it does **not** mean sound came out.

`/.modeset-armed` is an arm-once-per-boot latch that survives reboots **on purpose**, so a wedging modeset cannot re-fire. A latch left by a prior boot blocks every arm of the next one (`exit 98`). Recovery is `rm /.modeset-armed` plus a power cycle — **no reflash is ever needed** for any modeset failure mode.

### Toolchain pin — provenance, not enforcement

`scripts/build.sh` invokes the cyrius wrapper as `"$CYRB" build --no-deps …` — **without `--strict-pin`**. A newer installed `cycc` therefore builds agnos **warn-only** until the pin is bumped, so check `cyrius --version` when provenance matters. For the freestanding kernel the pin is largely **provenance**: the binary has been `cmp`-byte-identical across pin moves (6.3.9 → 6.3.43 both produced `build/agnos` at 1,345,512 B, cmp-proven). Ring-3 consumers, not the kernel binary, are what a pin bump unblocks. Hard floor: `symlink` #63 (agnos 1.51.0) needs `sys_symlink`, which exists only in cyrius ≥ 6.3.6. Cyrius is hands-off; pin lag is often a deliberate hold, not drift.

### CORRECTED — this file previously carried both of these wrong

**`boot_info` is 120 bytes / `0x78`, not 80** (80 was the pre-0.1.0 v1 size). magic `0x41474E4F` @0x00 · version 2 @0x04 · struct_size **120 (0x78)** @0x08 · flags @0x0C · fb_phys @0x48 · fb_pitch @0x50 · fb_width @0x54 · fb_height @0x58 · fb_pixel_format @0x5C · fb_size @0x68 · END @0x70. Framebuffer fields are **inlined at fixed offsets**, not in the tag stream — the boot-shim canary reads `fb_phys` from raw asm at instruction #1.

**The AMD-Zen scanout residue was RESOLVED at 1.55.28** — a surface/raster **scale** mismatch, not tiling and not DCC; fix is `gpu_scanout_matchgeom` (read the real HUBP viewport + pitch, override
`fb_console`; read-only, no register writes). Its last residual — the ~84 lines painted before the aperture maps — is itself closed by 1.56.37's deferred paint. Detail → `planning/gpu.md`.

### Sweep timing — ✅ FIXED 2026-08-05: ~20 min → **395 s**, 16/16

The 2026-07-23 diagnosis was right and sat unfixed: **QEMU never exits on its own**, so every smoke burned its whole `QEMU_TIMEOUT` waiting for nothing. New `scripts/smoke/lib/qemu-dwell.sh` backgrounds QEMU, polls for a marker, then SIGTERMs **and waits for the process to exit** — which is what preserves the "log is complete once QEMU has exited" guarantee `hda-smoke` documents; a bare kill would reintroduce that flush race. The budget is unchanged and still backstops a hung boot. **35 smokes converted.** ⛔ Marker choice is the hazard, and it is structural here, not per-file luck: no sweep gate feeds stdin, so all are boot-phase-only and the shell prompt provably follows anything a selftest printed. A smoke that DRIVES the shell must pass its own last line instead.
⚠ Still on fixed dwells: `hda-smoke` / `hda-dual-smoke` use `-serial file:` (QEMU owns the file) rather than `-serial stdio`, which the helper does not yet cover.
⛔ **Do NOT "fix" a slow gate by shortening its timeout** — that trades dead air for flaky truncation.

## FALSIFIED — do not re-open

- **Sequencing is NOT eliminated.** The M9 burn (1.56.15) that "eliminated" it was a **null experiment** — both arms streamed digital silence (no `HDA_TONE`, no ring-3 feed), so a healthy, entirely believable log was produced by a zero-filled ring. Retracted; sequencing is re-open.
- **L1 (Linux-userspace discriminator) returned VOID**, 2026-07-24/25 — positive-control arm D was silent with all four validity conditions verified, so it carries **zero** information. Never write it up as "sequencing exonerated". Structural cause: the two writes agnos performs routinely (`OTG_MASTER_EN` → 0, and the `FE_SOURCE_SELECT` BE↔FE bracket) each hard-wedge the APU from userspace.
- **The GOP-side `SetMode` lever as a way to move the SCANOUT** — same-mode re-arm (gnoboot 0.4.1, Attempt 74) and different-mode bounce (gnoboot 0.4.2, Attempt 78). Neither produced flicker on VGA or HDMI. ⛔ **CORRECTED 2026-08-03 — the reason is not "AMD Zen UEFI elides `SetMode`".** That sentence stood here and was wrong: gnoboot 0.6.1's `SetMode` demonstrably **worked**, and the firmware allocated a real 2560×1440 framebuffer (`fb: … phys=0xd0000000 size=0xe10000`). What `SetMode` does not do is touch DCN — it is **GOP-scoped**, which is all UEFI ever promised. The earlier "elided" reading came from a burn where the `fb:` line was serial-only and this box has no serial, so the GOP side was invisible. **What survives: no fourth `SetMode` variant — the lever is finished.** Native resolution is a kernel-side DCN write (`MDO_OP_NATIVE`), not a bootloader trick.
- **The tiled/DCC scanout thesis** (OSDev #57150) — survived two months as the last standing hypothesis and was still wrong. See the correction above.
- **Path A (ELF64 + multiboot2 via GRUB on UEFI)** — dead 2026-05-13; GRUB's `grub_relocator64_efi_boot` self-patches its own `.text` under strict W^X. gnoboot replaced it. Do not revive by patching GRUB.
- The HDMI-audio dead-end corpus (DCCG symbol-clock lead · the register-poke class · sample magnitude · AFMT RAMP · the offset axis, 105/105 · the DMCUB T-series · `phyid = 0`) lives in [`planning/gpu.md`](planning/gpu.md). **Surviving candidates: (b) a write that does not latch · (c) the bare-metal environment.**

## OPEN

- ⚠ **Carried from 1.56.43's HID work** — the first two need a boot **with the mouse attached** ([card](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-15643-hid), [issue](issues/2026-08-11-hid-drain-rearm-and-isr-console-lock.md)): the **mouse** half of the one-shot deferral is QEMU-proven and mutation-tested but not iron-proven (the keyboard half is); whether the composite keyboard's **phantom mouse interface** is genuinely mute — ⛔ the 2026-08-11 burn is **not** evidence either way, since no mouse report appeared but nothing shows a media key was pressed, and a keypress leaves no trace unless it produces output; and `hid_recover_halted()` is **reachable, not validated** — an injected completion code is fabricated in software, so the controller never halts and the body early-outs, meaning its Reset/Set-TR-Dequeue pair has executed nowhere.
- ⚠ **`klug.cyr:19-21` states a falsehood that costs log forensics.** It claims the kernel stops feeding the ring at the kybernet handoff; `devs.cyr:71` feeds it for **every** console-bound ring-3 byte. ⇒ **Printing the log re-appends it to itself and ages the boot out.** `run /bin/klug > /f.txt` is required, not merely convenient.
- ⚠ **MSI-X is armed one call before the last EP0 control transfers** (`main.cyr:542` vs `msc_enumerate()` at `:553`); a keystroke in that window is dropped and costs a TRB. Boot-probe window only — NVMe takes `blk_active` on this box. The comment at `:537-540` justifying the deferral names "the control transfers above", but `msc_enumerate` is below.
- **`cyim` cannot be built for agnos** (its LSP calls `sys_waitpid` with Linux arity plus `fork`/`execve`/`dup2`), so `/bin/cyim` in the rootfs is frozen at an old build and `stage-tools.sh --build` reports it every run. Needs a capability gate.
- **SDMA** — parked with a known resume state, an agnos **setup gap** and not a hardware limit (Linux drives SDMA on this box). Resume state: `rptr 0 wptr 44 cnt 266269 base 4102029824 halt 0 cap 0 cntl 262146`. Detail in [`planning/gpu.md`](planning/gpu.md).
- **The STAGE-1 imitation-edge removal** is a restructure, not a deletion — that block also holds the AVMUTE unmute and the FIFO drain arming. It follows the instrument work, with a burn, never blind.
- **aarch64** — compile-only, no boot harness, **not gated** (test.sh/check.sh/CI are x86-only). Its own future arc (1.6x), not maintained in lockstep.
- **`modeset-tool-smoke` mask** — `MDO_OP_SUPPORTED` is **`0xE7F` = 3711** (un-armed) / **`0xFFF` = 4095** (armed); bit 11 = `MDO_OP_NATIVE`, in BOTH values because it carries no audio content and must exist in a plain kernel. The smoke asserts both directions.

⭐ The larger backlog — syscalls, filesystems, platforms, the 2.0 refactor — lives in [`roadmap.md`](roadmap.md), not here.

## Pointers — the content lives at these, not here

- **GPU / display / HDMI audio** — every register, burn result and falsified hypothesis: [`planning/gpu.md`](planning/gpu.md). *The* single GPU document; no new GPU arc docs.
- **Burns** — agnosticos [`iron-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-log.md), the consolidated burn ledger (⚠ being created by the 2026-08-01 doc consolidation; until it lands the burns are in `iron-nuc-zen-log.md` + `-mvp.md` + `-mvp2.md`). Measured captures in agnosticos `docs/development/prior-art/` — those `.txt` files are irreplaceable iron evidence, reference them, never edit them.
- **Syscall ABI**, per-call contract — [`agnos-userland-abi.md`](agnos-userland-abi.md). **Build flags** and compile gates — [`build.md`](build.md).
- **Per-cut narrative and size trajectory** — [`CHANGELOG.md`](../../CHANGELOG.md). **Milestones** — [`roadmap.md`](roadmap.md). **Ecosystem-wide state** — agnosticos `state.md`.

`scripts/version-bump.sh` refreshes the header date and the Version row atomically with the bump; the body is a manual sweep at each closeout. If a section here starts telling a story, it belongs in one of the pointers above.
