# AGNOS 1.56.x — the SHADER arc (Thrust S): alpha, translucency, text

> Arc plan. The roadmap's Active section is the condensed pointer; this is the working document.
> Opened 2026-07-22, immediately after 1.55.x (Thrust P — DISPLAY) closed with the CP-DMA 2D path and the
> ring-3 band #84-#89 iron-proven on archaemenid.

Everything that needs **arithmetic per pixel**. CP-DMA is a byte mover with no ALU — it cannot blend, convert
formats, or replicate pixels within a row — so alpha/translucency, anti-aliased coverage, gradients, bitmap
glyph expand, and intra-pixel channel permutation all belong to a compositing **shader**, riding the dispatch
seam 1.54.x already proved. Scope is exactly the "NOT CP-DMA" list in
[`../issues/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md`](../issues/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md).

**Already in hand — do not re-prove.** Hand-assembled gfx90c ISA executing on the CUs; PM4 `DISPATCH_DIRECT`;
kernargs through `COMPUTE_USER_DATA`; a 68-dword ring envelope (pre-dispatch `ACQUIRE_MEM` invalidate →
`SET_SH_REG` config → dispatch → `CS_PARTIAL_FLUSH` drain → post-dispatch TC write-back → `WRITE_DATA` fence);
register-wptr submit, LO-before-HI (no doorbell — see [[reference_agnos_doorbells_dont_deliver_archaemenid]]);
a 100 ms bounded watchdog; ring wrap; and the ring-3 capability-gate pattern (`gpu_matmul_ok` → syscall #82).
`gpu_matmul_run` (`gpu.cyr:1988`) is already 90% of a generic dispatcher — only RSRC2, the kernarg count, the
workgroup size and the grid are hardcoded literals inside it.

**NOT in hand, and it shapes the whole ladder.** Four honest gaps:

1. **No shader has ever written to the scanout back buffer.** Every store to date landed in **UC-mapped arena
   scratch that only the CPU reads**. Shader stores land in **GL2**; the DCN HUBP fetches through DCHUB → SDP →
   the **data fabric** and never traverses GL2. The post-dispatch TC write-back is therefore load-bearing for
   *display visibility* in a way it has never been exercised — and there is **no shader-side L2 writeback on
   gfx90c** (`buffer_wbl2` is UNSUPPORTED on this part; gfx90a has it, gfx90c does not), so the CP packet is the
   only mechanism. **S3 settles this in one burn. Nothing writes to the back buffer ahead of S3.**
2. **agnos has never dispatched a grid other than 1×1×1.** `COMPUTE_PGM_RSRC2` sets no TGID bits, so the
   workgroup id is preloaded into no SGPR. The single largest unproven runtime primitive (S5).
3. **`s_mov_b64 exec,-1` is correct only for an exact 64-lane wave** (`gpu.cyr:1505-1507`). With VM_CONTEXT0
   paging deliberately disabled and no GPU-side isolation at all, a surplus lane's out-of-bounds store lands
   somewhere *real* in the carveout (S6).
4. **One shader slot.** `GPU_SHADER_SUBOFF = 0x14000` is rewritten in place every dispatch — which is exactly
   why the pre-dispatch I$ invalidate exists. A multi-kernel batched frame needs a slot table (S12).

### Standing rules for this arc

Each of these has already cost burns somewhere in the record.

- **Every new shader bite is `#ifdef`-gated with its own `BURN_*` flag in `scripts/burn-prep.sh`**, and the flag
  needs its `build.sh` define line — verify it landed by **`cmp`-ing the two binaries, not by the burn tag**
  ([[feedback_ifdef_bites_name_their_build_flags]]). The six 1.54.x shader self-tests run **ungated at every
  boot** (`main.cyr:908-942`); nothing joins them until it is iron-green.
- **Every ISA dword is `llvm-mc -mcpu=gfx90c` ground truth before it enters `.cyr`.** S0 makes that a sweep gate
  instead of a habit.
- **A dispatch that "completes" proves nothing.** Every oracle carries a lane/workgroup witness separating "no
  store landed" from "stored the wrong value" — the 1.54.17-19 lesson (the `nz` counter in
  `gpu_shader_dispatch2`).
- **A new proof uses a FRESH, never-written arena slot**, pre-seeded with a sentinel distinct from both 0 and
  every expected value. Re-using a slot let a stale GL2 line false-PASS a burn at C2g-1.
- **CP-DMA and shaders are in different coherence domains.** CP-DMA is MC-direct (bypasses GL2); shader stores
  are GL2. Mixing them is safe today **only** because the CPU serialises on the done marker. **No bite batches a
  dispatch and a CP-DMA into one submission without an intervening `ACQUIRE_MEM`** until S12 says otherwise.
- **VOP3 and VOP3P take no 32-bit literal on gfx9.** Every selector/mask constant is an `s_mov_b32` (SOP1) first.
  Highest-probability first-burn bug in the packed path.
- **There is no scratch ring.** `RSRC1`'s VGPR/SGPR fields are recounted per kernel; overflowing is *wrong*, not
  slow (`gpu_regs.cyr:1033-1035`).
- **Count `gpu_ring_put` calls, don't trust the comments.** Several say "the 39-dword ring program"; the C2f
  envelope is 50 and `gpu_matmul_run` is 68. `gpu_regs.cyr:1028` still says `v_fma_f64` where the shipped kernel
  uses separate `v_mul_f64` + `v_add_f64`.

### Bite ladder — S lane. Each bite its own cut; iron-only unless marked. Bites may share a burn; the cut is per bite.

| Bite | What | Validate |
|------|------|----------|
| **S0** | **Shader authoring toolchain + CPU reference oracle. HOST ONLY — no burn.** Stand up a host-side gfx90c emitter (recommend lifting mabda's `gfx9_encode.cyr` — 411 lines, zero deps, zero external symbols, its own llvm-mc regression oracle) that emits dwords + RSRC1/RSRC2; paste into `gpu.cyr` as an emitter fn following `gpu_matmul_write_shader(shader_phys)`. Lands the in-kernel `blend_ref_px()` CPU reference every later oracle diffs against, and `scripts/gfx9-asm-check.sh` wired into `sweep.sh`. **BLOCKED on decision D-1.** | HOST — `sh scripts/sweep.sh` green and `gfx9-asm-check.sh` reports every ISA table in `gpu.cyr` byte-identical to `llvm-mc -mcpu=gfx90c`, **including all six already-shipped 1.54.x kernels** (the net proving itself on shipped code is the pass condition) |
| **S1** | **Read-only compute-state probe** (`gpu_shader_state_probe`) — the P0 analog. Decode and print RSRC1/RSRC2 fields, USER_SGPR count, TGID enables, `TIDIG_COMP_CNT`, `LDS_SIZE`, **`COMPUTE_TMPRING_SIZE` (never written by agnos — zero or stale?)**, arena base/MC, slot MCs, `VM_L2_CNTL`. Pure reads. Rides one burn with D0. | IRON — `klug > /f/s1.txt`; decoded fields match the constants the code believes it writes. **The fail that matters: `TMPRING_SIZE` non-zero** ⇒ a stale scratch base is live |
| **S2** | **★ FIRST BLEND — 64-pixel uniform-alpha src-over into a FRESH arena slot.** One workgroup, 64 threads, `DISPATCH_DIRECT 1,1,1`, `exec=-1` (valid: exact wave64), unchanged RSRC1/RSRC2. **Only opcodes that have already executed on this silicon** — `v_and_b32` / `v_lshrrev_b32` / `v_lshlrev_b32` / `v_mul_lo_u32` / `v_add_u32` / `v_mov_b32` / `global_load_dword` / `global_store_dword glc`. No `v_perm`, no VOP3P, no `v_cmp`, no new grid, no new PM4. A failure can only be the blend math or the slot. **BLOCKED on decision D-2.** | IRON — `gpu: shader blend online (64 pixels, bit-correct vs CPU)`; all 64 dwords bit-identical to `blend_ref_px()` over a=0/1/254/255 columns; **separate lane witness `64 of 64 lanes stored`**; endpoints a=0→dst, a=255→src byte-identical. `BURN_SHADER_BLEND64` |
| **S3** | **GL2 ↔ scanout ↔ CP-DMA coherence, characterised in ONE boot.** Re-dispatch S2's kernel 64× (CPU row loop, no new shader work) to paint a 64×64 tile into the **back buffer** — the first shader store to a WC-mapped, DCN-consumed surface. Four arms, same boot: (a) with post-dispatch TC write-back, (b) without, (c) shader-write → CP-DMA-read ± write-back, (d) CP-DMA-write → shader-read ± invalidate. | IRON — a four-cell pass/fail table in `klug` **and** one photo showing arm (a) correct beside arm (b) stale/torn. Expected a=pass · b=FAIL · c=needs write-back · d=needs invalidate; any deviation is a hardware fact worth more than the bite. **CPU-readback visibility and panel visibility scored SEPARATELY** — different consumers, different paths. `BURN_SHADER_COHERE` |
| **S4** | **`v_perm_b32` identity + VOP3P packed blend + the shader-side channel swap.** (i) unpack/repack identity with SGPR-held selectors `0x0c010c00` / `0x0c030c02` / `0x06040200`; (ii) the one-instruction RGBX↔BGRX permutation (`0x03000102`) — the *per-surface* swap D1's crossbar cannot do; (iii) re-express S2's blend in `v_pk_mul_lo_u16` / `v_pk_mad_u16` / `v_pk_add_u16` / `v_pk_sub_u16` / `v_pk_lshrrev_b16`, exploiting that the whole src-over numerator (max 65025) fits a u16 lane with no clamp and no widening. | IRON — three bit-exact comparisons in one burn: unpack→repack ≡ input over 4096 pseudorandom pixels; swap-twice ≡ input while swap-once matches a CPU byte-shuffle; **packed blend ≡ S2's scalar blend on the SAME data** (S2 is the oracle — that is what makes it an isolation test). VALU count printed. `BURN_SHADER_PERM` |
| **S5** | **Grid > 1 workgroup — TGID_X/Y, `RSRC2 = 0x190`, `DIM ≠ 1,1,1`. NO arithmetic.** Pure load→store rect copy over a `(w/64, h, 1)` grid at a **deliberately wave-aligned width** (e.g. 1024 = 16 waves) so no EXEC guard is needed yet. Lands `s8`=tgid_x / `s9`=tgid_y (the SGPRs immediately after the user SGPRs), a new **`gpu_shader_run` sibling** taking rsrc2 + workgroup size + grid as parameters (leave `gpu_matmul_run` byte-identical so the three ML proof paths do not move), and the missing `SET_SH_REG_N8/_N10` headers minted from the formula at `gpu_regs.cyr:948`. Keeps the **proven** 64-bit VGPR-pair addressing; the SADDR form is a later optimisation. | IRON — a 1024×N shader copy **byte-identical to `gpu_cp_dma_blit()`** of the same rect (the iron-proven 2D reference), plus an executed-**workgroup** witness (`16 of 16 workgroups reported`) from per-workgroup sentinel stores, not from the done marker. `BURN_SHADER_GRID` |
| **S6** | **EXEC bounds guard — with a deliberate negative arm.** `s_mov_b64 exec,-1` **first** (the SPI hands the wave exec=0 on this raw non-HWS HQD path), then `v_cmp_lt_u32_e64` + `s_and_b64 exec`. `s_cbranch_execz` alone is **not** the guard — it only skips when all 64 lanes are out, and the 1–63 stragglers are exactly the ones that store past the right edge. | IRON — two arms, same boot, w=**1917**: guarded arm byte-identical to `gpu_cp_dma_blit` **and** the 4 bytes past every row's right edge unmodified; unguarded control arm shows those sentinels **clobbered**. `gpu: exec guard holds (1917 px, 0 of 1440 rows overran)` vs `guard off: 1440 of 1440 rows overran`. ⚠ the negative arm's overrun is aimed at a sacrificial slot, clear of back buffers / PSP TMR / compute arena. `BURN_SHADER_GUARD` |
| **S7** | **Full per-pixel-alpha src-over over a real rect + the `gpu_blend_ok` boot gate.** Alpha from the source's byte 3 via the `0x0c030c03` broadcast; independent src/dst strides absorbed into the two SGPR row bases (y is uniform across the workgroup, so row-base math is all SALU and costs **zero VALU per lane**); **RSRC1 recounted** for a ~24-VGPR high-water. Sets `gpu_blend_ok` from a boot self-test, mirroring how `gpu_matmul_ok` gates #82. | IRON — bit-exact vs the CPU reference over a rect with a=0/1/254/255 columns at a non-multiple-of-64 width, endpoints checked over the **full** rect. `gpu: shader alpha blend online (1917x256, bit-correct vs CPU)`. Photo: a translucent panel over the DOOM window with the CPU blend counter reading **0**. `BURN_SHADER_BLEND` |
| **S8** | **Ring-3 seam — ONE new syscall `#92 gpu_shader_op(desc_uva, len)` + `/bin/gpublend`.** #90/#91 are **reserved** with declared shapes, so #92 is next free. A coverage blit needs five operands and the dispatcher offers four args ⇒ use a **descriptor block** copied in with the proven `proc_copy_from_user` pattern — `{op, src_id, mask_id, wh, dstxy, alpha, flags}` — specified as an **array of ops from day one** so S12's batching is an implementation change, not an ABI break. Structurally modelled on `gpu_blit_shm_sys` (`syscall.cyr:774`): validates the slot, derives MCs in-kernel, **no MC address crosses the ring-3 boundary**, **rejects rather than clips**. `gpu_caps`#89 gains a "shader compositing available" flag bit. **BLOCKED on decision D-3.** | IRON — `run /bin/gpublend` → `run: exit <code>`: #89 probe → #85 clear → #86+#72 seed → **#92 blend** → #84 present, self-validating with a distinct exit code per failure mode (the `gpublit` `exit 97`/`exit 95` discipline that caught #89's cold-probe bug before any compositor consumed the ABI) |
| **S9** | **1bpp glyph expand, transparent background — the highest call-count site in the desktop tree.** The one case where the shader is *structurally* cheaper: the transparent background becomes an **EXEC mask**, so the destination is **never loaded at all** — 4 VALU + 1 store, **zero loads**, vs a CPU conditional store per pixel (~128 bit-tests + ~40 writes per glyph per frame today). Consumes `kashi_glyph_row`; touches nothing inside kashi ([[project_kashi_parallel_split]]). New **op code** on #92, no new syscall number. | IRON — a full CP437 page of the kashi VGA 8×16 font rendered through the shader is **byte-identical** to `fb_console`'s CPU glyph renderer over the same page; `gpu: glyph expand <N> glyphs/sec shader vs <M> CPU`. Photo: a text run over a patterned background with the background visible between strokes. `BURN_SHADER_GLYPH` |
| **S10** | **8-bit coverage-mask blit — the vector text/shape path** (rekha glyph → sadish path → coverage → blit). Effective alpha = coverage, or `src_a·cov/255` when the source is itself translucent. Needs `global_load_ubyte` (assembles on gfx90c, new to the tree); the byte→(c,c) broadcast is one `v_perm_b32`. Fourth pointer pair ⇒ **RSRC1 recounted again**. New op code on #92. | IRON — bit-exact vs the CPU reference over a hand-built 0..255 coverage ramp, **all 256 values exercised, not sampled**. Photo: an anti-aliased circle with no stair-stepping, beside the same circle drawn without coverage as a control. `BURN_SHADER_COVER` |
| **S11** | **Gradient fill — per-pixel lerp + src-over.** `t = (x * dt) >> 16` with `dt` a CPU-computed 16.16 step passed as a kernarg (`v_mul_u32_u24` + `v_lshrrev`; both operands < 2²⁴), then the S7 blend with `a = t`. Two-stop linear gradients cover the theme surfaces. New op code on #92. | IRON — bit-exact vs a CPU reference using the **identical** fixed-point step (the step is exact, so any banding is a formula bug, not dithering). Photo: MUDRA and SHANTA titlebar gradients, no banding. `BURN_SHADER_GRAD` |
| **S12** | **Multi-slot shader residency + ONE-submission compositor frame.** Retires the throughput wall: every dispatch today pays ~68 ring dwords + a whole-cache invalidate + a whole-cache write-back + a CPU busy-spin, and all kernels share the fixed slot at `0x14000`. Give each kernel a 256-byte-aligned resident slot (`COMPUTE_PGM_LO = mc>>8` must stay exact), then batch N ops from one #92 descriptor array into a **single** submission with one `CS_PARTIAL_FLUSH` + one write-back + one fence at the end. **Keep the pre-dispatch invalidate unconditionally** — load-bearing twice over (stale I$ on a rewritten slot, stale GL2 from CP-DMA's MC-direct writes). See decision D-6. | IRON — a full mock frame (background fill · 3 windows with translucent chrome · one AA-text run · one gradient titlebar) composited in **one** submission and **pixel-identical** to the same frame composited op-by-op (S7–S11 oracles chained), with frame time from the existing vblank-pacing counters. Calibration: 12 B/pixel ⇒ a full-screen 1080p blend is ~25 MB — this path is **memory-bound, not ALU-bound**. A batched frame that is *not* faster means the fence was never the wall, and that finding is the deliverable. `BURN_SHADER_BATCH` |

### Bite ladder — D lane (DCN plane). Independent of the S lane; rides along.

| Bite | What | Validate |
|------|------|----------|
| **D0** | **Read-only MPC / HUBPRET probe** — anchor the base and offsets **before any write**, per [[reference_agnos_dcn_hubp_reg_offsets_derived]]. Read MPCC0..5 `TOP_SEL`/`BOT_SEL`/`OPP_ID`/`CONTROL`/`STATUS` (BASE_IDX 2, MPCC stride **0x1B**, MPCC0_TOP_SEL @ **0x1271**), `MPC_OUT0_MUX` @ **0x1385**, `HUBPRET0_HUBPRET_CONTROL` @ **0x066c** (HUBP stride 0xDC), DOMAIN2/DOMAIN3 `PG_STATUS`, OPTC0 underflow @ 0x1aca bit10. Rides S1's burn. Offsets come from the generated `dcn_2_1_0_offset.h`, already **9-for-9** against agnos's iron-proven OTG/HUBP values. | IRON — all **nine** constraints agree: MPCC0 `TOP_SEL==0`, `OPP_ID==0`, `BOT_SEL==0xF`, `MPC_OUT0_MUX==0`, `STATUS` BUSY=1/IDLE=0/DISABLED=0 **and** MPCC1..5 all 0xF with IDLE=1, DOMAIN2/3 power-**gated**, underflow status 0. Six positive + three negative cannot agree by accident. Any disagreement ⇒ D1/D2 do not proceed |
| **D1** | **HUBPRET channel crossbar — RGBX↔BGRX free in hardware**, on the pipe agnos already owns. `CROSSBAR_SRC_ALPHA` [17:16] / `SRC_Y_G` [19:18] / `SRC_CB_B` [21:20] / `SRC_CR_R` [23:22]; amdgpu implements ABGR8888 as exactly ARGB8888 with red/blue bars swapped — the pixel-format value never changes. Two fields, one register, no second plane, no bandwidth change. Apply → hold N OTG frames → **dead-man auto-restore** unless acked. | IRON photo — reds and blues swap on the live console while applied, and 0x066c reads back the saved value after auto-restore; underflow status still 0. ⚠ this covers the **whole-scanout** format case only; a per-client-surface swap during composite is S4. `BURN_HUBP_CROSSBAR` |
| **D2** | **MPCC0 global-alpha RMW — prove agnos owns the blender.** `MPCC_ALPHA_BLND_MODE` [5:4] = **2 (GLOBAL_ALPHA)** + sweep `MPCC_GLOBAL_ALPHA` [23:16], under the OTG master update lock agnos already drives, with a dead-man auto-restore. **Not a desktop feature — an oracle**: it proves base + offsets + field placement + latching + lock semantics at once, with zero new pipes, zero new clocks, zero extra bandwidth and one-register reversibility. **BLOCKED on decision D-4.** | IRON photo — the whole screen fades toward the MPCC background colour as GLOBAL_ALPHA drops, then returns on auto-restore; `MPCC_CONTROL` reads back the saved value; underflow still 0. ⚠ **mode 0 (PER_PIXEL) on the GOP's XRGB surface, where the X byte is 0x00, makes the screen fully transparent = BLACK.** Mode 2 ignores pixel alpha by definition — that is why it is the only mode this bite may use. `BURN_MPC_GALPHA` |

### Deferred with reason — the DCN second plane (its own arc, not a 1.56.x bite)

A real second blended plane is **front-end pipe bring-up**, not a poke: DOMAIN2/DOMAIN3 power-ungate with the
PGFSM status wait → DPPCLK1 DTO + DPP clock enable → HUBP1 clock + VTG bind to OTG0 → **~25 DML-computed
DLG/TTU/RQ deadline registers** (tractable only by cloning HUBP0's live values verbatim — legitimate because
same OTG, same timing, same format, viewport ≤ HUBP0's) → surface config → DSCL bypass + `RECOUT` positioning →
MPCC1 insert → `MPC_OUT0_MUX` retarget, all under the OTG lock. Call it **50–70 register writes and 4–6
iron-testable bites**. Open it as `planning/dcn-plane-arc.md` **after** the shader path proves out.

**The strategic reason it is not a shortcut through 1.56.x:** Renoir/Cezanne gives **4 blendable planes total**
(`num_timing_generator = 4` bounds it, not the 6 MPCC instances), and they are the same 4 pipes a second monitor
would want. A compositor with twenty translucent windows cannot map onto four planes. MPC blending is a fast
path for a *few large surfaces* — wallpaper, one always-on translucent panel, the cursor, one fullscreen window
— and is **complementary to the shader arc, not a substitute**: AA coverage blit, glyph draw and gradients stay
on the shader no matter how well the plane work goes. Two hazards to carry into that doc: a second full-screen
32bpp plane at 2560×1440@60 roughly doubles scanout bandwidth against `DCHUBBUB_ARB_*` watermarks the GOP sized
for **one** plane (mitigate with a window-sized `RECOUT` — HUBP fetch scales with viewport, so a 480×320 panel
adds ~4% of a full plane), and `DOMAIN*_PG_CONFIG` sits at **0x0080 BASE_IDX 2**, numerically colliding with
agnos's existing `GPU_R_OTG_PIXEL_RATE_CNTL = 0x80` at **BASE_IDX 1** — wrong base **power-gates a live pipe**.
Name the new symbols distinctly (`GPU_R_DCPG_DOMAIN0_PG_CONFIG`) and assert the base in the comment.

**Hardware cursor** (`CUR0_MODE` = 2/3, 32bpp ARGB with per-pixel alpha up to 256×256, blended through the same
MPCC path with **no** second HUBP/DPP and **no** DLG/TTU work; `CURSOR_MODE_MONO` with `CURSOR0_COLOR0/1` is
literally the 1bpp→32bpp transparent-background glyph primitive in silicon) stays where the 1.55.x ladder put it
as **P8**, carried forward — its blend value was undersold there, but it is bounded (one per pipe) and does not
displace S9.

### New syscalls this arc

**Exactly one: `#92 gpu_shader_op(desc_uva, len)`** (see S8 and decision D-3). #90 `gpu_readback_shm` and #91
`gpu_blit_bb` are **reserved with declared shapes** in the band ticket, so #92 is next free, and every later
shader operation (glyph, coverage, gradient) rides an **op code inside the descriptor**, not a new number.

Fold the ask into the **existing consolidated ticket** —
[`../issues/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md`](../issues/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md)
— plus its cyrius mirror. Do **not** open a new one; that ticket exists specifically to end the one-at-a-time
pattern. Docstring must carry the Linux collision: **#92 = `chown(path, uid, gid)`** on x86_64 — arg1 is a user
pointer read as a path and arg2 (`len`) decodes as a uid, so it is a **metadata write if the path ever
resolves**. The file-level `#ifdef CYRIUS_TARGET_AGNOS` gate in `lib/syscalls.cyr` stays load-bearing, and
`scripts/agnos-crossbuild-gate.sh` coverage extends to the new row.

### Open decisions — settle these before the bites they block

| # | Decision | Blocks | Recommendation |
|---|----------|--------|----------------|
| **D-1** | Shader authoring path: hand-hex · lift mabda `gfx9_encode.cyr` as a **host-side offline emitter** · vendor the full SPIR-V compiler in-kernel | **S0 ⇒ everything** | **Offline emitter.** The in-kernel compiler is *provably* freestanding-clean (builds and runs standalone with `stdlib = []`; `--agnos` succeeds; byte-identical ISA) but buys nothing: +4,641 LOC (+8.5%), ~80 KB stack per compile, pulls f32/f64 intrinsics into kernel text that is deliberately integer-only today, and **there is no SPIR-V producer anywhere in the ecosystem** — so it would mean shipping SPIR-V blobs instead of ISA blobs. Operator should ratify the mabda-source boundary crossing explicitly |
| **D-2** | `/255` semantics: exact `floor` via `(x + 1 + (x>>8)) >> 8` vs the cheaper `a256` approximation | **S2** (the CPU oracle *is* the bite) | **Exact floor.** aethersafha's `rend_blend` computes `(sr*a + dr*ia)/255` — integer division, i.e. floor — so the exact form makes GPU output **bit-identical to the CPU path that keeps running alongside it** during the transition, and the whole arc's discipline is "bit-exact vs CPU". Its worst case (65280) still fits a u16 lane, so the packed form works. The ~6 extra VALU cost nothing on a memory-bound path. Bank `a256` as a *measured* optimisation later, never as an unremarked default |
| **D-3** | Syscall shape: one descriptor syscall #92 taking an **array of ops** vs one number per op (#92–#95) | **S8** | **Descriptor array.** Four args available, coverage needs five operands; numbers are not free (#90/#91 reserved); four numbers = four cyrius asks against a ticket built to stop exactly that; and specifying an array now makes S12's batching an implementation change rather than an ABI break |
| **D-4** | Is whole-surface translucency an actual MUDRA/SHANTA requirement, or is D2 purely an oracle? | **D2's framing; gates whether the plane arc ever opens** | Ask the designs. One or two large always-on translucent panels ⇒ `MPCC_GLOBAL_ALPHA` is one 8-bit field and nearly free once a second plane exists. Per-window translucency across N windows ⇒ the plane path cannot serve it (4 planes) and D2 stays a pure oracle |
| **D-5** | Does the arc end at the kernel seam or at the desktop? | scope | **Kernel arc closes at S12 + `/bin/gpublend`;** consumer wiring (aethersafha `rend_blend`, sadish raster, dhancha surface, bhumi scanout) is follow-on in those repos with named owners. Precedent: 1.54.x's stated crown **C6 is still open** because it was a consumer item scoped inside a kernel arc. Do not repeat that |
| **D-6** | Prove slot residency by **removing** the pre-dispatch `ACQUIRE_MEM(INV)`? | **S12** | **No.** That invalidate is load-bearing twice — stale I$ on a rewritten shader VA *and* stale GL2 lines when a shader reads bytes CP-DMA just wrote MC-direct. Removing it breaks the mixed-engine case S12 depends on. Add the slot table for batching; keep the invalidate unconditionally |

### ⚠ EXECUTION DIVERGENCE — recorded 2026-07-22, at 1.56.3

**The ladder above is correct as written and is NOT being rewritten.** What follows is the record of how
execution departed from it, so the two can be read against each other. Restored at 1.56.4 (see CHANGELOG).

| Plan bite / row | Status | What actually happened |
|---|---|---|
| **S0** | PARTIAL | `scripts/gfx9-asm.sh` assembles from `.s` via `llvm-mc` and harvests RSRC1/RSRC2 — good, and better than hand-typing. But **the `sweep.sh` check gate never landed**, and the six 1.54.x tables were never byte-verified. The net this bite existed to build does not exist |
| **S1 · D0** | DONE-IRON | Both shipped as reports rather than gates. S1 banked a durable hardware fact: **the SH compute registers are not GRBM-readable on this part** |
| **S2** | DONE-IRON | Shipped, but as **f32 premultiplied**, which is a *third* option D-2 never listed — see D-2 below |
| **S3** | ✅ **DONE-IRON 2026-07-22** (two burns; was NEVER RAN) | Its label was consumed by the grid bite (plan S5). The four-arm coherence table does not exist; the post-dispatch write-back is emitted unconditionally and **no build has ever run without it**. So "the TC write-back is load-bearing for display visibility" remains an *assumption*. ⚠ Arms (c)/(d) are **S12's precondition** — the arc's own standing rule forbids batching a dispatch and a CP-DMA into one submission until S3 says otherwise |
| **S4** | ✅ **DONE-IRON 2026-07-22, first burn** (was NEVER STARTED) | Zero `v_perm_b32` and zero `v_pk_*` in the tree. The RGBX↔BGRX channel swap — which this arc opened by calling **"an unhandled case, not just a slow one"** — is still exactly that |
| **S5** | DONE-IRON | Shipped under the label "S3". Carries the blend rather than a pure copy, and was verified against `blend_ref_px` rather than `gpu_cp_dma_blit`; no per-workgroup sentinel witness (the workgroup evidence is a photo) |
| **S6** | DONE-IRON | Shipped correctly labelled, but at w=**200** with no deliberate **unguarded** control arm. "The guard stopped the overrun" is therefore inferred, not measured |
| **S7** | DONE-IRON | Delivered across two cuts. `gpu_blend_ok` exists but **gates nothing on the runtime path** — and it must not, being self-test-only (see the 1.56.4 note) |
| **S8 / D-3** | ❌ **BUILT THE REJECTED OPTION** | Shipped `#92` blend + `#93` coverage + `#94` glyph — one number per op, verbatim the column D-3 rejected. Restored to the descriptor array at 1.56.4 |
| **S9 · S10 · S11** | BUILT | Shipped as `#94` / `#93` / no-syscall-at-all, and under the labels "S8" / "S7" / "S9". The gradient shipped a working shader with **no kernel-side worker and no ring-3 path** for a full cut |
| **S12** | 🔨 **BUILT 1.56.5, BURN-READY** | Residency half landed 1.56.4; batching half + the pixel-identity oracle landed 1.56.5. `BURN_SHADER_BATCH`. The poll quantum was tightened FIRST (S12a) or the timing would have been unfalsifiable |
| **D1 · D2** | NOT STARTED | HUBP crossbar, MPCC global alpha. Independent of the S lane |

**Two live defects found by the same re-audit** (detail in the CHANGELOG): both coverage call sites passed
11 arguments to a 12-parameter dispatcher — warning in every build since 1.56.3 — and `#92`'s resident
shader plus the done-marker all five kernels poll sat inside the **VM protection-fault sink page**.

**The process lesson, and it is the expensive one:** the deviation was not a judgement call made and
recorded — it was made silently, and the bite renumbering then removed the means of noticing. Per
[[feedback_execute_the_plan_you_wrote]]: **name the bite ID and its governing D-rows before writing code,
and re-open this document before each bite.** A decision row that is not re-read is not a decision.

### Ready to build now (no decision pending)

**Remaining: D1 · D2**, plus the **S12 burn** (code landed at 1.56.5, `BURN_SHADER_BATCH`, not yet run). Once S12 is iron-green the S lane is COMPLETE and the arc meets its stated closing condition. **S4 is CLOSED** — iron-proven first burn 2026-07-22; the RGBX↔BGRX channel swap the arc opened by calling "an unhandled case" is now one VALU op, and `v_cvt_pk_u8_f32` is confirmed to CLAMP negative inputs to 0. **S12 is the arc's stated closing condition.** **S3 is CLOSED — iron-proven 2026-07-22, all four arms conclusive**, so S12's precondition is satisfied: both coherence packets are required at every engine-domain transition, in either direction, and that is now measured (CP-DMA neither snoops GL2 on read nor invalidates it on write). D-1/D-2/D-4 remain unratified — see the CHANGELOG's operator-decision list; none of them block S4.

### Carried out of 1.55.x into this arc

**P4 — scanout-residue clear** and **P6+ — 3D and full modeset** carry forward unchanged; the ATOM interpreter
(`kernel/core/atom.cyr`) remains the P6 cold-modeset foundation. **A4 (HDMI display audio)** is a separate open
thread and is *not* gated by this arc. **C6 (an attn11/tentib layer actually executing on the shader cores)**
remains open from 1.54.x and is a **userland/ML-consumer** item — this arc adds no kernel blocker to it, and the
`gpu_shader_run` sibling introduced at S5 makes the parameterised dispatcher it would want available.
