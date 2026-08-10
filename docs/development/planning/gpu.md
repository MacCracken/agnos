# AGNOS — GPU

The single GPU document: what is TRUE, what is FALSIFIED, what is OPEN. Nothing else.

> **HARD BUDGET — 700 lines AND 120 KB.** Line count alone is meaningless here: the version this replaced was 1409 lines but 362 KB, because
> its tables ran 257 bytes/line. **If either bound is exceeded the overflow is per-burn measurement, and it belongs in
> `agnosticos/docs/development/prior-art/gpu-display-audio-prior-art.md`, not here.** This file keeps only what a future session needs to
> DECIDE the next bite.

**Rules for this file, so it does not happen again:**
1. **No new GPU arc documents.** Everything GPU goes here.
2. **No cryptic bite IDs.** The old ones — `C2g-1`, `S0`-`S12`, `D0`-`D2`, `P4`, `A4`, `M1`-`M9` — are unreadable six weeks later and made the
     same work look like new work each time it was renamed. Items below are named for **what they deliver**.
3. **Everything maps to a release.** No item exists without a version it ships in.
4. **GPU is not "done" until the release plan below is finished.** Not a phase of it.

**Folded into this file and DELETED 2026-08-01** (rule 1 was written before them and they were created anyway; every number in each that was
checked against the kernel was wrong): `attr-interp-11.md` · `rung17-tri-depth.md` · `edge-cov-9b.md` · `doom-on-agnos-render-blockers.md`.

**Platform:** archaemenid = Beelink SER NUC, AMD Ryzen 7 5800H Cezanne APU — **gfx90c** (GCN5/Vega, IP gfx9.3.0) compute + **DCN 2.1**
display, PCI **`1002:1638`** at **`0000:04:00.0`**, register aperture **BAR5 size `0x80000`**, **3072 MB** VRAM carveout. HDMI audio is a
**separate PCI function `1002:1637` at `04:00.1`**. Panel = Acer XB323U over HDMI. Build host IS the target — no serial, iron-only, QEMU
emulates neither GFX nor DCN.

---

# 1 — WHAT IS TRUE

## 1.1 Shipped

| Thing | Release |
|---|---|
| **Compute** — PSP firmware load · engine start · MEC1 HQD queue · PM4 ring · hand-assembled gfx90c shaders · integer + f64 matmul rosnet-bit-correct from ring 3 | 1.54.x |
| **Display** — read the live pipe · scanout flip · vblank pacing · console geometry fix · 2D via CP-DMA · band `#84`-`#89` | 1.55.x |
| **Shader compositing** — per-pixel alpha · 2-D grids · EXEC bounds guard · glyph expand · coverage · gradient · one-submission batched frame (1.78×, pixel-identical) · the `#92` descriptor ABI | 1.56.x |
| **Capture + blit** — `#90 gpu_readback_shm` (reuse-safe via `clflush`) · `#91 gpu_blit_bb` (overlap-safe) | 1.56.8 |
| **ML on the cores** — rupantara 0.4.1 (f64 `#83`) · tentib 1.0.1 (ternary int `#82`) · attn11 1.14.1 — all **bit-identical vs CPU**, all iron exit 95 | 1.56.8, iron 2026-07-23 |
| **Live-pipe modeset** — `#93`, ops 0x00-0x06: read pipe · OTG lock · VTOTAL retime · the OTG envelope · DIG/BE · transmitter power-cycle | 1.56.9-1.56.15 |
| **3D rasteriser** — textured, filtered, depth-tested, perspective-correct triangles on agnos's own GPU. Ops `0x08`-`0x10`; 18 hand-assembled shaders | 1.56.16-1.56.32 |

**Still cannot:** set a mode from cold on a pipe the firmware never lit · drive a second monitor · get audio out over HDMI.

## 1.2 The ring-3 GPU syscall band is `#82`-`#94` — **THIRTEEN numbers, not the "contiguous #82-#92" every prior doc said**

Verified in `syscall.cyr`'s dispatch, not from a doc. `#95 uptime_us` sits inside the range and is not a GPU call.

| # | Call | # | Call |
|---|---|---|---|
| 82 | `gpu_dispatch` (integer matmul) | 89 | `gpu_caps` |
| 83 | `gpu_dispatch_f64` | 90 | `gpu_readback_shm` |
| 84 | `present` (flip) | 91 | `gpu_blit_bb` |
| 85 | `gpu_fill` | **92** | **`gpu_shader_op(desc_uva, len)`** |
| 86 | `shm_create_gpu` | **93** | **`gpu_modeset_op`** |
| 87 | `gpu_blit_shm` | **94** | **`gpu_recover_op`** |
| 88 | `gpu_fill_rect` | | |

**`#92` is ONE number carrying an array of 64-byte op records with the opcode in the payload.** Adjacent: `#39 blit` (a4 bit40 =
DEFER_PRESENT) · `#40 uptime_ms` · `#71 shm_create` (SYSTEM RAM the GPU cannot reach) · `#72/#73 shm_write/read` · `#95 uptime_us` (rdtsc).

⚠ `#92` collides with Linux x86_64 `chown(path,uid,gid)`: arg1 reads as a user path pointer and arg2 (`len`) decodes as a uid, so a stray
call on Linux is a **metadata write** if the path resolves. The file-level `#ifdef CYRIUS_TARGET_AGNOS` in `lib/syscalls.cyr` is
load-bearing.

## 1.3 The `#92` op table and its field masks

`GPU_OP_SUPPORTED = 0x1FF1F` (ops 0x00-0x04 + 0x08-0x10). `GPU_OP_NOTIMPL_MASK = 0x0000` — every advertised op has a worker. **Verify
against `gpo_field_mask` in `kernel/core/syscall.cyr`, never against this table.**

| Op | Name | mask | Fields |
|---|---|---|---|
| 0x00 | NOP | 0x0003 | op flags |
| 0x01 | BLEND_RECT | 0x0037 | + src_id wh dstxy |
| 0x02 | BLEND_COV | 0x023B | + mask_id wh dstxy color0 |
| 0x03 | GLYPH_1BPP | 0x023B | as 0x02 |
| 0x04 | GRAD_LINEAR | 0x0633 | wh dstxy color0 color1 |
| 0x08 | EDGE_COV | 0x021F | dst_id edge_id wh n_edges\|rule — **dstxy undefined, must be 0** |
| 0x09 | TRI_RGBA | 0xFFFB | everything but reserved dword 2 |
| 0x0A | TRI_LIST | 0x007B | vtx_id wh **dstxy** n_tris |
| 0x0B | TRI_TEX | 0x81FF | tex_id edge_id wh dstxy vtx_id texwh lut_id + n_edges\|rule |
| 0x0C | TEX_LIST | 0x007B | prim_id wh dstxy n_prims |
| 0x0D | DEPTH_CLEAR | 0x0057 | z_handle wh value — dstxy must be 0 |
| 0x0E | TRI_DEPTH | 0x01FF | z_handle vtx_id wh **dstxy** n_tris zwh witness_id |
| 0x0F | TRI_PERSP | 0x00FF | tex_id vtx_id wh **dstxy** n_tris texwh |
| 0x10 | RT_READ | 0x009F | z_handle dst_id wh zwh — dstxy must be 0 |

**⛔ TWO INCOMPATIBLE `dstxy` CONVENTIONS LIVE UNDER `#92`, undocumented until 2026-07-30: op `0x0A` is RECT-LOCAL; ops `0x0E` and `0x0F` are
FRAMEBUFFER-ABSOLUTE.** The absolute side was never exercised because `gputri` passes `dstxy = 0`. Caught by an adversarial audit AFTER the
change set was called burn-ready; modelled at 251,227 of 256,000 px wrong.

**⛔ op `0x0F` RECORDS CANNOT BE LAYERED — the op REPLACES its whole rect.** `tri_persp.s:348-360` selects the background for any uncovered
lane (`v_cndmask_b32 v21, v20, v21, s[28:29]`) then stores **unconditionally** at `:360`. Two records over one rect means record 1 paints
opaque `GPU_TRID_BG` over everything record 0 drew.

**⛔ THE OP-TO-OP PREP-ARENA RACE.** `gpo_execute_all` holds `gpu_batch_active` across the whole `#92` array, and `gpu_blend_cov_run`
early-returns without fencing when batched. **Any op building a per-record prep table at ONE fixed arena slot has record N+1 overwrite
record N before the GPU reads it.** This is the rung-12 root cause AND the mine-cart defect. Fixed by suspend/restore in `0x0A`, `0x0C`,
`0x0E`, `0x0F`.

⛔ **No colour-writing op lets the caller name its destination.** Every one derives `dst_mc` from module globals `gpu_bb_a_mc`/`_b_mc`, and
`gpo_validate`'s reserved sweep rejects anything else — so no userland change can redirect the write. Depth already works the other way
(`gpu_tri_depth` writes Z to a ring-3-named `gpu_rt_handle_mc` in the same dispatch) and shaders already take `dst_mc`/`dst_pitch` as
kernargs, so **the real cost of fixing it is FIELD PLACEMENT**: op `0x09`'s mask is `0xFFFB` — every dword but the reserved one — so no
dword is unclaimed. Either break the same-field-same-dword doctrine knowingly or mint a fresh op code (`0x11`-`0x1F` free, self-advertising
via `#89`). Also missing: any ownership model for the 8 RT handles — `grep` finds no `rt_alloc`/`rt_free`/`rt_owner`, so any process can
name handle 0-7 and read another's through `0x10`.

⛔ `#39 blit` does NOT target the live scanout — `gpu_blit_target()` returns the SAME `gpu_bb_a/b` buffer op `0x0F` draws into. A draw →
readback → blit round trip leaves the un-offset original visible.

## 1.4 GPU tool exit-code vocabulary — a red exit names WHICH oracle fired

| Code | Meaning | Code | Meaning |
|---|---|---|---|
| 83 | no-arg (its own code since 1.56.27) | 92 | off-rate |
| 84 | usage / flag not received | 93 | an ATOM step failed |
| 85 | digest or pixel mismatch | 94 | a ratio check failed |
| 86 | a negative control failed | **95** | **the assertion PASSING — not merely absence of failure** |
| 87 | covered nothing / a sub-case failed | 96 | no live display (QEMU has no DCN) / arm-first |
| 89 | tgid or a case could not run | 98 | latch blocked this boot |
| 91 | shape / reference mismatch | 100 | no measurement emitted |

Also on the modeset tool: 90 = every CPU phase read 0 µs (TSC calibration broken ⇒ VOID) · 88 = BE↔FE · 87 = the kernel predates the `#89`
profile tail ⇒ **a STALE KERNEL was flashed** (`--update-fs` instead of `--update-all`).

## 1.5 The work budget: `GPU_EDGE_WORK_MAX` replaced `GPU_EDGE_CAP` as the knob

`GPU_EDGE_CAP = 256` (raised to the ABI maximum). `GPU_EDGE_WORK_MAX = 67108864` (2^26) on `w*h*n_edges` ≈ 40 ms of the ~100 ms watchdog.
`GPO_E_WORK = 21` is its own reason code.

**Reason it was the wrong knob:** µs-per-edge is **FLAT** — 9.50 / 9.62 / 9.87 / 9.81 / 9.79 / 9.76 / 9.75 marginal µs/edge at `ne` =
4/8/16/32/64/128/256, flat to ~2.6% across a 64× range. Least squares: `cost_us = 28.8 + 0.0005953 * (w*h) * n_edges`, and the 28.8 µs
intercept independently agrees with the crossover sweep's ~28 µs from different data. So cost is linear in `w*h*E`, and the old edge cap
**permitted 4096²×64 at ~639 ms (six times over the watchdog) while forbidding 64²×256 at ~0.65 ms.**

## 1.6 THE COST MODEL — corrected, and the GPU is not the bottleneck

Three-parameter fit across six row-major/col-major pairs:

```
cost = F + a·launched_waves + b·working_waves
a = -5 ns per LAUNCHED wave   (statistically zero — a launched-but-exiting wave is FREE)
b = 36 ns per WORKING wave
F = 264 us fixed, and F is PER-PRIMITIVE  (7.353 us each, measured 1.56.26)
```

`F` decomposed on iron (`gpu-prof-fixed-term-per-primitive-iron-0728.txt`, exit 95): LO n=32 → copyin 0 / validate 2 / build 248 / wait 200
/ cpu 250 µs, grid 32×32, 1024 waves (predicted 1024). HI n=256 → validate 16 / build 1881 / wait 1351 / cpu 1897 µs, grid 256×32, 8192
waves. **CPU(hi)/CPU(lo) = 7.5× against 8.0× if per-PRIMITIVE and 1.0× if per-DISPATCH ⇒ per-primitive.** Build slope 7.29 µs/prim is **117×
the validate slope** — optimising validation would buy ~0.9%.

**⛔ RETRACTED, and why.** The figures **"177 ns per LAUNCHED wave"** and **"row-major cannot draw a DOOM frame — 128,000 waves = 24.5 ms of
a 28.6 ms budget"** are withdrawn. The model behind them was `a·launched + b·working` with **no constant term**, fitted to two points
differing 2% in launched waves and 39% in working waves: two points, two free parameters, **zero degrees of freedom**. The 264 µs of fixed
cost had nowhere to go but the launched coefficient — `1536 × 177 ns ≈ 272 µs ≈ F`. Right arithmetic, unidentifiable parameter reported as a
measurement. At the real 36 ns/working wave the same frame is **4.6 ms**, and col-major is 0.09 ms. Col-major is kept because it is **50×
cheaper**, NOT because row-major is impossible.

**⛔ THE GPU IS NOT THE BOTTLENECK OF A DOOM FRAME. `gpu_tex_prep` on the CPU is, by 52×.** Optimised across three cuts: **7.29 → 4.21 →
2.487 µs/prim** against a **0.79 µs arithmetic floor**. Root cause was not arithmetic but WHERE it writes — `rec_phys` lives in the
UC-mapped GPU arena, and an uncached 32-bit store is not store-buffered: 76 UC stores per primitive at **~85.6 ns each**. Cut 1 narrowed a
40-word zero-fill to 5 (the explicit stores already covered 0..35 contiguously); cut 2 replaced 40 store32s with **20 store64s** — same
bytes, half the transactions. Total `#92` at n=256: 3248 → 1421 µs = **2.29×**. Frame totals: row-major 4.71 CPU + 4.60 GPU = 9.31 ms;
col-major 4.71 + 0.09 = 4.80 ms.

**⛔ The "cached scratch + bulk copy" idea is DEAD — do not attempt it.** `memcpy` (`klib/kstring.cyr:35`) copies its aligned bulk with
`store64`, so building the record in cached memory and copying produces **exactly the same 20 UC transactions plus an extra pass**. The
bottleneck is the COUNT of uncached transactions, not where the bytes come from. The remaining 20 cannot shrink without 128-bit stores,
barred by the FP-free kernel posture.

⚠ The 1.56.28 pre-registered CONTROL FAILED and is logged as a failure: `wait` was required to stay ~5.1 µs/prim for a CPU-only change and
moved to 2.487 (−51%). A global GPU speed-up is ruled out by an independent instrument (gputex's pure-GPU bench unchanged: 32×32 52.0 → 50.0
µs, 256×256 158.0 → 158.2). Most likely memory-controller backlog bleeding into the measured drain window ⇒ **the control was badly
designed, not violated.** ⚠ Also unexplained and not papered over: at 1.56.28 the build and wait deltas from n=32 to n=256 are exactly
equal, both 557 µs (they were 1633/1151 and 943/1136 at the two prior cuts). Needs a third primitive count. **Do not build on it.**

Related measured costs: rung-13 texture dispatch = **52.7 µs fixed + 1.58-1.64 ns/px** (≥3680 MB/s, a LOWER bound — texels counted once per
covered pixel while the cache serves repeats) ⇒ **rung 14 is DISPATCH-bound, not bandwidth-bound**, 542-1022 dispatches per 35 Hz frame
before a single pixel. FULLCOV (coverage passes skipped, byte-identical to a 255 mask) cuts the per-pixel SLOPE by 65% (1.59 → 0.55 ns/px):
32×32 56.3 → 27.0 µs, 256×256 159.1 → 62.6 µs. Depth clear (op 0x0D, after the fix): **86.5 µs fixed + 22.7 ps/byte ⇒ 44.1 GB/s** marginal.

## 1.7 The rung ladder — one row per rung

Per-burn measurements live in `agnosticos/docs/development/prior-art/`; the filename column is the pointer.

| Rung | What it proves | Ships | Exit | The one number that closed it | Capture |
|---|---|---|---|---|---|
| 5 | GPU hang is DETECTABLE and the console SURVIVES it | 1.56.16 | 91 | forensic: `rptr 529 wptr 529 hqd_active 1`, `fence expected c2f0d02e saw 0`, breadcrumb NEVER WRITTEN | `gpu-wedge-recovery-arm-console-survival-iron-0725.txt` |
| 6 | the RT region is provably unclaimed | 1.56.17 | 95 | region ends `0x1030000000` = exactly the `top=1030000000` the boot path reports from an INDEPENDENT source | `gpu-rt-arena-audit-rung6-closed-iron-0728.txt` |
| 9b | edge coverage rasterises byte-identically (op `0x08`) | 1.56.17 | 95 | **20 of 20** cases byte-identical to `refraster.cyr`, all negative controls N1-N8 fired | `gpu-edge-coverage-20-of-20-exact-iron-0725.txt` |
| 10 | the CPU/GPU crossover kill-gate — GPU wins early enough for tier-1 to be justified | 1.56.18 | — | crossover **1,751 covered px** unbatched AND batched-16, against a pre-registered ~12,000/~50,000 — **~7× better, in the favourable direction** | `gpu-coverage-bench-cpu-gpu-crossover-iron-0726.txt` |
| 10b | edge cost is linear in `E`, so the cap was the wrong knob | 1.56.19 | — | µs/edge **flat 9.50 → 9.75** across a 64× range | `gpu-coverage-bench-edge-cap-sweep-iron-0726.txt` |
| 11 | exact integer barycentric RGBA (op `0x09`) | 1.56.20 | 95 | 15-case corpus; N13 rounding correction fired **120,684-145,886×**; N14 premul restore **12,096×** | `gpu-tri-corpus-digest-15-cases-iron-0726.txt` |
| 12 | a LIST of overlapping triangles composites (op `0x0A`) — 11 burns | 1.56.21 | 95 | digest **0xfc6f8c42 == reference, 0 px differ** (was 3,188 differ, worst delta 237) | `gpu-tri-rung12-closed-0px-differ-iron-0727.txt` |
| 13 | nearest-neighbour affine texturing (op `0x0B`) | 1.56.21-22 | 95 | RGBA8 **5/5** + IDX8 **5/5** + WRAP **2/2** byte-identical to `texcore` | `gpu-tex-rung13-affine-exact-iron-0727.txt`, `…-wrap-fixed-…` |
| 14/14b | fused `TEX_LIST` (op `0x0C`) + col-major transpose | 1.56.23 | 95 | **1504-1536 waves → 64** (23-24× fewer); byte-identical to 32 individual `0x0B` dispatches AND to a second `0x0C` in the same array | `gpu-tex-rung14-op0c-closed-iron-0727.txt` |
| 15 | integer 4-tap bilinear | 1.56.29 | 95 | frame 0 (1:1 identity) `vs NEAREST` **35 → 0** — the falsified prediction, now confirmed | `gpu-tex-rung15-bilinear-validated-iron-0728.txt` |
| 16 | tile ownership | 1.56.23 | 95 | — | — |
| 17a | depth CLEAR does real work (op `0x0D`) — on a target ring 3 cannot read back, TIME is the only oracle | 1.56.30 | 95 | 800×600×20 = **2,602 µs** vs 4096×2048×20 = **16,958 µs**: bytes ratio 17×, time ratio **6.5×** (the failing burn read 0.0-1.0×) | `gpu-depth-clear-op0d-validated-iron-0729.txt` |
| 17b | the depth TEST runs deterministically with no atomics and no binning (op `0x0E`) — **TD-5 was never needed** | 1.56.30 | 95 | both submission orders byte-identical in colour AND depth, and **0 px** differ from the CPU reference (the failing burn: 0 px across orders, **1024 px** vs the reference) | `gpu-depth-rung17-closed-iron-0729.txt` |
| 18 | per-pixel perspective divide (op `0x0F`) — 4 burns | 1.56.31 | 95 | **0 of 1541** covered px differ from the PERSPECTIVE reference on a corpus where the AFFINE reference differs at **731** | `gpu-persp-rung18-closed-iron-0730.txt` |
| 19 | **the consumer close** — cyrius-mine-cart 0.1.0, the first thing outside this repo's test tree to use the 3D ops | 1.56.32 | 95 | **`DIFFER: 0 of 256000 px`** on a byte compare, not a photograph; 600 frames presented, 0 dropped, twice | `gpu-mine-cart-rung19-closed-0px-differ-iron-0730.txt` |

Shader blobs (dwords — the committed `*_write()` table in `gpu.cyr` is the authority, gated by `shader-blob.sh`): `edge_setup` 58 ·
`edge_cov` **135** · `tri_rgba` **278** (`RSRC1 = 0x002C0187`, 32 VGPRs) · `tex_rgba`/`tex_list` **417** each · `tex_bilin` **584**
(`RSRC1_TEXBI = 0x00AC020B`, 48 VGPRs, resident at `GPU_TEXBI_SHADER_SUBOFF = 0x5D000`) · `tri_depth` **116** · `tri_persp` **196** (`RSRC1
= 0x002C01C7`, 56 SGPRs — the prediction of 48 was wrong).

## 1.8 Iron-proven reference — compute

- **Cold-boot fingerprint** (1.54.1): `rlc=0x0` (RLC off) · `me=0x15000000` (CP-gfx halted) · `mec=0x50000000` (MEC halted) · `psp=0x698e82`
    (PSP alive), GFX block powered.
- **PSP path**: the GPCOM ring comes up from agnos with no vendor driver; `SETUP_TMR status=0x0` ⇒ low kernel physical memory IS
    PSP-DMA-reachable, but the **TMR must live in the VRAM carveout**, placed via the GFXHUB FB-location registers. All CP+MEC ucode loads
    **5/5** (CE/PFP/ME whole-body, MEC1 body+JT split). **There is no MEC2 on gfx9.3.0** — do not go looking. Firmware header:
    `ucode_size_bytes` at `+0x14`, `ucode_array_offset_bytes` at `+0x18`.
- **Engine-start ORDER**: RLC first (`RLC_CNTL` bit0), THEN clear the `CP_ME_CNTL` / `CP_MEC_CNTL` halts.
- **GART is ABSENT.** FB carveout MC range `[0xF400000000, +3GB)`. Compute scratch is addressed through the BIOS FB aperture with **zero page
    tables**, `VM_CONTEXT0` disabled — which designs the VM-fault-storm CPU wedge out of existence. First PM4 fetch with `fault=0` proves it.
- **SUBMIT-SEQUENCE LAW**: write the ring **WPTR LO before WPTR HI** — the CP latches on the HI write.
- **Cache packet**: `GPU_CP_COHER_CNTL_TCWB = 0x00840000` = `TC_WB_ACTION_ENA` (1<<18) **PLUS** `TC_ACTION_ENA` (1<<23), **and bit 23 is the
    L2 INVALIDATE**. Settled against a RADV IB decode on this same Cezanne (`mabda .../radv-triangle.ib.txt:12-27` and `:1649-1656`).
- **gfx90c has NO shader-side L2 writeback** — `buffer_wbl2` is unsupported (gfx90a has it, gfx90c does not). The CP-side post-dispatch TC
    write-back is the ONLY way to make shader stores visible to DCN HUBP.
- **SH compute registers are NOT GRBM-readable on this part.** No plan may propose reading back RSRC1/ RSRC2, USER_SGPR count, TGID enables,
    TIDIG_COMP_CNT, LDS_SIZE or `COMPUTE_TMPRING_SIZE` to verify what the code believes it wrote.
- **Grid dispatch**: `RSRC2 = 0x190` enables TGID_X/TGID_Y; workgroup ids arrive in `s8`/`s9`, the SGPRs immediately after the user SGPRs.
    `s_mov_b64 exec,-1` must be issued FIRST — the SPI hands the wave `exec=0`; the bounds guard is then `v_cmp_lt_u32_e64` + `s_and_b64 exec`.
- **`v_perm_b32` selectors, iron-proven**: RGBX↔BGRX swap `0x03000102` · unpack/repack identity `0x0c010c00` / `0x0c030c02` / `0x06040200` ·
    alpha-byte-3 broadcast `0x0c030c03`. **`v_cvt_pk_u8_f32` CLAMPS NEGATIVE INPUTS TO 0.** VOP3/VOP3P take **no 32-bit literal** on gfx9 —
    every selector must be loaded with an `s_mov_b32` first.
- **CP-DMA** (all three 2D primitives green in one boot, `cpdma-copy-fill-blit-verified-iron-0722.txt`): hardware copy (4 KB, dst==src) · fill
    (4 KB, all=pattern) · blit (8 rows, strides deliberately different 256→320 B, untouched padding asserted ⇒ real per-row stride addressing).
    7-dword PM4 `DMA_DATA` (op 0x50) on the MEC compute ring; MC-direct `SRC/DST_SEL=0` gives CPU-visible DRAM with no `ACQUIRE_MEM`. BYTE_COUNT
    is 26 bits (~64 MiB), so a 32 MB clear fits ONE packet. ⚠ `gpu_cpdma_submit` **masks** an over-large byte count rather than rejecting it —
    silently truncates and reports success.
- **Coherence (S3, all four arms, two burns)**: CP-DMA and shaders are in different coherence domains and BOTH packets are required at EVERY
    transition in EITHER direction. CP-DMA neither snoops GL2 on read nor invalidates on write. Measured negative evidence: **4096-of-4096
    dwords stale** without the post-dispatch write-back. ⚠ **Keep BOTH captures** — the INV=off arm is NOT stable across runs: run 1 read `S3-D
    INV=off new 4096/4096 COHERENT`, run 2 (same 1.56.4) read `new 0/4096 STALE, stale 4096`. (`gpu-shader-coherence-s3-four-arm-iron-0722.txt`
    + `…-inv-off-stale-…`.)
- **Batching (S12)**: one-submission mock frame 107 → 60 µs, **1.78×**, pixel-identical. Residual ~87% fixed cost (60 µs against ~8 µs of real
    traffic) — the remaining wall is SIX per-dispatch whole-L2 invalidates, **not** the fence (which decomposes to ~5.3 µs, against the ~60 µs
    once modelled). Calibration: 12 B/pixel ⇒ a full-screen 1080p blend is ~25 MB, memory-bound not ALU-bound.
- **Arena / RT audit numbers** (repeated verbatim in every rung-17+ burn): `MC_VM_FB_OFFSET raw f70` ⇒ carveout phys base `0xF70000000` via
    `(raw & 0xFFFFFF) << 24`; arena phys `0xFF0000000` mc `0xF480000000` size `0x200000`; highest published slot `0xC0000`, sacrificial slot
    `0x1F0000`; RT region offset `0xb0000000` size `0x10000000`, rt phys `0x1020000000` mc `0xF4B0000000`; live scanout mc `0xF400000000` (= the
    carveout base, i.e. the console framebuffer at offset 0) — **check 7, the only witness agnos did not write.**
- **Arena map (rung 11 onward)**: `GPU_TRI_SHADER_SUBOFF 0x59000` (residency slot 9) · `GPU_TRI_PREP_SUBOFF 0xE0000` (64 records × 128 B) ·
    `GPU_TRI_EDGE_SUBOFF 0xE2000` · `GPU_TRI_COV_SUBOFF 0xE4000` (1 MB, 48 KB clear of the sacrificial slot). ⚠ `GPU_EDGE_PREP_SUBOFF` moved
    `0xD0000` → `0xA8000` at 1.56.19 because `0xD0000` sat INSIDE the S12 snapshot `[0xC0000, 0xE0000)`; with `VM_CONTEXT0` disabled that
    overlap would have stored somewhere REAL, and `check.sh`'s value-only duplicate test is structurally blind to it. Shader slots are
    256-byte-aligned with `COMPUTE_PGM_LO = mc>>8` exact; the previous single slot at `0x14000` sat inside the VM protection-fault SINK page and
    was relocated to a strided table at `0x50000`.
- **Validator bounds (shipped, `syscall.cyr:1020-1022`)**: `GPU_TRI_AREA_MIN = 65536` (2^16), `GPU_TRI_AREA_MAX = 4398046511104` (2^42),
    `GPU_TRI_E_RATIO = 1024`. ⚠ The rung-11 plan claimed 2^32 and 2^53 — **two orders of magnitude out, and a 2^32 floor would have rejected
    most real triangles**; the `"tri: small frame clears the AREA floor"` selftest exists to stop that regressing. `E_RATIO`'s hard ceiling is
    **701,000**, derived from the one-step correction bound (`Q ≤ 765·R` and `Q < 2^29`), so 1024 carries a **685× margin**, and its geometric
    meaning is the maximum frame skew relative to the evaluation rect. Divider normalisation `t = max(0, bitlen64(D255) − 30)`; the corpus
    measures `t ∈ [2, 18]`, not the planned `[10, 31]` (coordinates are bounded at ±2^28 in 16.16, so `2A ~ 2^40` and `t ~ 18` is the ceiling).
- **Exactness, stated so the shortcut is a re-openable decision rather than a mid-bite "fix":** the shipped barycentric is the EXACT
    round-half-up with worst-case error **ZERO**. The obvious `0.16` fixed-point simplification — which saves ~40% of the kernel — puts roughly
    **1 pixel in 43** off by one (invisible on a photo, lethal to a byte-identical oracle); systematic ±1 banding begins at k=11. The honest
    cost of refusing both float and fixed-point is ~408 VALU/px, ~76% of `tri_rgba`, against ~10 VALU for a `v_rcp_f32` + 4 `v_fma_f32`
    interpolator.

## 1.9 Iron-proven reference — display and modeset

- **The link, positively identified**: 2560×1440 CVT reduced-blanking @ 241.50 MHz, **59.9506 Hz**, on **HDMI via DIG1 in DIG_MODE=2 (DVI
    signalling)**. OTG totals read raw **2719×1480** ⇒ real totals **2720×1481**; hblank **160** (CVT-RB's fixed value), vblank **41**. Unique
    on the (h_total, v_total) PAIR — confirmed by a 147-mode brute-force scan.
- **Measured pixel clock** `gpu_pixclk_100hz` = **2415014-2415030** (241.5014-241.503 MHz), 11-13 ppm from the 241.500 MHz CVT step;
    independent windows agree within **7-13 ppm**. Refresh 59950-59951 mHz.
- **TOTALS ENCODING: both `OTG_H_TOTAL` and `OTG_V_TOTAL` hold `total − 1`.** The V write only LOOKS raw. Blank registers carry NO −1: `active
    = BLANK_START_END START − END`. Self-check: 2720 − 2560 = 160 lands exactly on CVT-RB's mandated hblank; a wrong −1 gives 159 and matches no
    standard.
- **Register bases**: SEG1 (BASE_IDX 1) = `0xC0`, SEG2 (BASE_IDX 2) = `0x34C0`; byte address = `(SEG + dword_offset) * 4`. amdgpu ftrace
    prints **BAR5-ABSOLUTE** dword indices — subtract `0x34C0` (BASE_IDX 2) or `0xC0` (BASE_IDX 1) before looking a symbol up. Worked examples:
    abs `0x556F` = DIG0_DIG_BE_CNTL, abs `0x566F` = DIG1_DIG_BE_CNTL (DIG **back end**, NOT PHY). Three independent verifiers nearly mis-decoded
    these.
- **Iron-proven DCN 2.1 offsets** (BASE_IDX 2): `OTG_CONTROL 0x1b41` · `OTG_STATUS 0x1b49` · `OTG_STATUS_FRAME_COUNT 0x1b4c` (the three
    header-validation anchors) · `OTG_H_TOTAL 0x1b2a` · `OTG_V_TOTAL 0x1b2f` · `OTG_H_TIMING_CNTL 0x1b2e` · `OTG_INTERLACE_CONTROL 0x1b44`;
    totals are field `[14:0]`. Block strides: OTG `0x80` · HUBP `0xDC` · MPCC `0x1B` · PIXRATE `0x4` · DIG `0x100` · DPP `0x16B`. Audio block:
    `DIG_FE_CNTL 0x2068` · `DIG_BE_CNTL 0x20af` · `DIG_BE_EN_CNTL 0x20b0` · `AFMT_STATUS 0x20a9` · `HDMI_ACR_STATUS_0 0x209C` · `HDMI_ACR_48_0
    0x209A` · `HDMI_ACR_44_0 0x2098` · `HDMI_ACR_32_0 0x2096`; DCCG audio-DTO `0xab-0xaf` and `DP_DTO_MODULO 0x82` at BASE_IDX 1;
    `DMCUB_INBOX1_WPTR` abs `0x6740`.
- **`DPREFCLK = 598,875,000` (`0x23B21B78`)**, read at `DP_DTO0_MODULO` (BASE_IDX 1 dword `0x82`, abs 322). This read is the hardware anchor
    proving the DCCG BASE_IDX-1 base and offsets are right.
- **The pipe scaler is LIVE.** Firmware leaves an **800×600 surface DCN-scaled to 2560×1440**. HUBP viewport `0x5EA` = `0x02580320` (800×600);
    real pitch `0x607` = **832 px** (800 aligned up to 64); `SCL_MODE 0x0CEC` = 1 (active, not bypass=6). The 1.33× ellipse artifact is exactly
    `(2560/800)/(1440/600)`. gnoboot reads `fb_width` AFTER `SetMode`, so boot_info is not stale — the firmware genuinely chose 800×600.
- **`fb_phys = load64(load64(&boot_info_ptr) + 0x48)`**; pitch `+0x50`, height `+0x58`. Pass gate: the lit HUBP
    `DCSURF_PRIMARY_SURFACE_ADDRESS` equals `fb_phys`.
- **phyid = 1 is MEASURED, not derived. The categorical rule: the DIG that is LIVE with `DIG_MODE != 0` names the phyid.** Per-instance on
    this box: inst 0/2/3/4 read `BE=0x00010000 mode=1 EN=0x00000100 enable=0`; **inst 1 reads `BE=0x10020200 mode=2 FE_SOURCE=0x02 EN=0x00000101
    enable=1`** — exactly one live instance. `phyid=0` causes an **87,292-read poll storm**; `phyid=1` is clean at **21r / 17w / 5d**. ⚠ **ATOM
    `#76` ENABLE resets `DIG_MODE` back to 2 ITSELF** (trace: `r=566f v=10030200` then `w=566f v=10020200`), so an HDMI flip must be
    **re-asserted after `#76`**. amdgpu ftrace could never show this — amdgpu drives the PHY through native `link_enc` code and never calls ATOM
    `#76`.
- **Sovereign ATOM interpreter, iron-proven bit-correct** (1.55.23, DRY build, no MMIO, no amdgpu): `atom: rom=188 cmd=93fa data=94a0`;
    encoder `#4` emitted exactly the oracle's 5 writes with `reads=5 writes=5 delays=2` rc=0; transmitter `#76` exactly the oracle's 17 writes
    with `reads=21 writes=17 delays=5` rc=0. VBIOS from ACPI VFCT: `vid=1002 did=1638 len=55296`, `sig=aa55`, atomhdr 188, MasterCommandTable
    @`0x93fa`. Table indices: `DIGxEncoderControl` #4 (v1_5, 782 B @`0xae4e`), `DIG1TransmitterControl` #76 (v1_6, 262 B @`0xb162`),
    `SetPixelClock` #12 (v1_7), `EnableDispPowerGating`
  #13. The tables branch on `SWITCH` and use `SETPORT` — **parameterised bytecode, NOT a replayable
sequence.** ⚠ Latents cleared for #76/#4 but live for a cold path: the recursion depth cap is 8 vs the amdgpu oracle's 32; each ws slot is a
fixed 512 B while `ws_count` is a u8 (max 255), so a table with `ws_count > 128` overflows into the next depth's slot.
- **ATOM `#12` programs the DTO on this part, NOT a PLL — there was never an instance to derive.** With a complete iron seed: `pll_id` **3-19
    and 255** all run clean producing **BYTE-IDENTICAL** writes — `OTG_PIXEL_RATE_CNTL <- 0` · `DP_DTO_PHASE <- the pixel clock IN HZ` ·
    `OTG_PIXEL_RATE_CNTL <- 0x10` (sets `DP_DTO_ENABLE`) — write 2 verified tracking the target across 241.502/148.5/270.0 MHz
    (`0x0E650730`/`0x08D9EE20`/`0x1017DF80`), with `DPREFCLK × PHASE/MODULO` reproducing it exactly. `pll_id` **0-2 and 25-254 bail with ZERO
    WRITES — a clean return that reads exactly like success** (which is how `phyid=0` survived). **`pll_id` 20-24 STORM and are eliminated on
    evidence** (175k-510k opcodes, 78k-177k reads = the wrong-instance signature), each writing a different PHY/RDPCS instance block on a
    **`0xD8` stride** — five of them, matching the five DIG instances — and calling ATOM table 77. **In that range `pll_id` names a TRANSMITTER
    INSTANCE, and `atom_run_set_pixel_clock()` now REFUSES 20-24 BY NAME** (`pll_id < 3` had admitted every one). ⛔ This RETRACTS the same cut's
    own claim that "#12's blast radius is disjoint from #76's": at `pll_id=20` it writes **22 PHY registers to #76's one**, a superset of the
    command that has blanked this panel twice.
- **⛔ SETTLED BY OPERATOR DECISION: `#12` IS NOT TO BE FIRED AT THE LIVE PIPE.** It sets `DP_DTO_ENABLE`, which on a DTO-off pipe MOVES the
    clock source rather than reprogramming it — and that pipe is the console, already blanked twice by `#76`. A future cold path needs a
    different **TARGET**, and one is measured: **pipe 1 is DARK** — `OTG1_CONTROL` abs `0x5081` = `0x80000300` (MASTER_EN clear) vs pipe 0's
    `0x80011301`.
- **PLL-vs-DTO adjudicated**: `OTG0_PIXEL_RATE_CNTL` (abs dword 320) = 0 means `DP_DTO_ENABLE` is CLEAR, i.e. the DTO is OFF — the CORRECT
    state for a PLL-driven pipe; `DP_DTO0_MODULO` (322) = 598,875,000 is DPREFCLK. Both were once written up as an unexplained mystery: a clean
    positive read backwards.
- **The modeset raster program** (`kernel/core/mode_raster.cyr`, zero burns): fed the published CVT-RB 2560×1440 timing it reproduces **all
    ten** timing registers the firmware left, bit for bit — `H_TOTAL 2719` · `H_BLANK 7342704` · `H_SYNC_A 2097152` · `V_TOTAL 1480` · `V_BLANK
    2491846` · `V_SYNC_A 327680` · both polarities · `H_TIMING_CNTL` · `INTERLACE_CONTROL`. ⛔ **Ten of fourteen, and the other four are named:**
    `VSTARTUP_PARAM` / `VUPDATE_PARAM` / `VREADY_PARAM` / `VTG0_CONTROL` are **DML watermark outputs** (memory clock, HUBP fetch latency, plane
    config — not timing), so no mode description yields them and they must be CARRIED from the inherited snapshot. Found in passing:
    `gpu_regs.cyr`'s `H_SYNC_A` field order was **inverted**, which made this pipe a zero-width hsync.
- **GOP-vs-amdgpu clock-control delta**: the GOP pipe reads `OTG_CLOCK_CONTROL = 65793 (0x10101)` and `OPTC_INPUT_CLOCK_CONTROL = 6`, **not**
    amdgpu's `0x3`. Forcing `0x3` would very likely have left the panel dark on re-enable; writing back the SAVED values is why it relit.
    `V_TOTAL_MIN/_MAX` (`0x1B30`/ `0x1B31`) are **0** on the GOP pipe (amdgpu programs 1480) ⇒ MIN/MAX writes are INERT until the SEL bits are
    set; the raster change lands through `V_TOTAL` alone.
- **The modeset ladder's closing numbers**: the OTG master-update lock engages and the live pipe survives (`lock ack 1`, readback 1480, hold
    120 ms, frames 1683→1694). **The first real modeset**: v_total 1481→1501→1481 at constant pixel clock moved frame-counted refresh **59951 →
    59152 → 59951 mHz**, landing on the prediction to the milliHz — a ~13,300 ppm step against a 12-17 ppm noise floor. **The OTG envelope**:
    `OTG_MASTER_EN` 0 stopped the frame counter (2615→0, `stopped 1`), 1 resumed it (→115), refresh restored exactly. **The transmitter
    power-cycle on the live console link**: ATOM `#76` DISABLE→ENABLE at phyid 1; RDPCSTX1 lane enables stepped DOWN
    `0xd1f000→0xd0e000→0xd0c000→0xd08000→0xd00000` and back UP, perfect round-trip, and the operator kept typing afterwards. **ZERO writes to
    `556F`, UNIPHYA (`5D2D`/`5D2E`) or RDPCSTX0** — the phyid fix validated at the write level. ⭐ The PHY does NOT need a running pixel clock to
    lock: the `#76` cycle ran with the OTG disabled and came back.
- **Latch mechanism** (`/.modeset-armed`): arm-once-per-boot, survives reboots ON PURPOSE so a wedging modeset cannot re-fire. A latch left by
    a previous boot BLOCKS every arm of the next (`previous attempt did not disarm -- SKIPPED`, then exit 98 per arm, before a single register
    is touched). Recovery is **`rm /.modeset-armed`, no reflash**, disarm and re-run in the same boot. It is deliberately NOT auto-cleared at
    boot — too early gives an unbounded, filesystem-invisible re-attempt loop escapable only by reflash; too late costs one `rm`. ⚠
    `modeset_disarm()` was BROKEN until 2026-07-31: it deleted the file, verified it gone, printed `verified good, latch cleared`, and left
    arming dead for the boot two ways (never cleared the boot-lifetime `blocked` flag; zeroed the latch inode without re-creating it). Fixed,
    mutation-tested.
- **`modeset --x` and `run /bin/modeset --x` are IRON-PROVEN IDENTICAL** (both forms in one boot, byte-identical output, same exit 95). Any
    future claim that the prefix matters is false. `rc 0` / `exit 95` means **the writes went out — it does NOT mean sound came out.** Every
    command spills its log to `/klug.txt` as it goes, so even a hang leaves evidence.
- **The `rd`-tag ambiguity, and the addressing bug it caused**: `mdo_rd2` prints BASE_IDX-2-*relative* offsets and `mdo_rd2a` prints
    *absolute* ones under the **same `rd ` tag**, so `m1-decode.py` writes 87 of the seed's 97 entries as relative-labelled-absolute. The M12
    burn printed the pixclk group with the relative prefix and got only 6 registers, reading ZERO at dword 320; switching to `rda` got all 10
    with the correct DPREFCLK values. ⛔ **Decode M1 dumps with `scripts/m1-decode.py`, NEVER by eye** — decoding by eye cost a burn (4294902881
    read as `0xFFFF0A61` when it is `0xFFFF0461`, differing in exactly the field that decides whether the blender runs).
- **OPTC underflow bit10 is PRE-SET AT BOOT on this box.** Every modeset run logs `underflow bit10 1 -> 1` and `pre-existing`. It cannot
    distinguish a fresh underflow from an inherited one ⇒ **a DEGRADED instrument here**; the picture oracle is the operator's eyes. It is also
    STICKY, so latch its entry value or the check is decorative.
- **The three instruments that actually cross the readback/shadow boundary** — every bite must name which one it uses: **I1**
    `OTG_STATUS_FRAME_COUNT` (`0x1B4C + pipe*0x80`, field `[23:0]`, counted scanned frames); **I2** PIT-counted refresh (an **off-GPU** time
    base, the only number in the display stack a register cannot fake); **I3** the ATOM `reads=/writes=/delays=` counters plus the `ATOM_TRACE`
    write log, diffable against `atom-interp.py`. **A readback proves nothing** — twelve mute burns of green gates came from echo registers, and
    on DCN a readback is also a *shadow*.
- **Timebase**: `pit_ch0_read()` is a non-destructive latch read of PIT ch0, left free-running by `pic_init()` as a **mode-2 rate generator,
    divisor 11932**. Mode 3 steps by TWO and breaks the wrap math. **CPUID 0x15/0x16 return zeros on this exact part**, so the TSC route is
    closed for the display timebase. Ring-3 timing uses `#95 uptime_us` (rdtsc, calibrated at boot against 50 ms of live ticks, returning −1
    rather than a plausible 0 when calibration is refused) — **`#40 uptime_ms` is FROZEN inside a foreground `run`**, because such a program
    starts with IF cleared so the timer ISR never fires. That cost two burns.

## 1.10 Iron-proven reference — HDMI audio (PARKED by operator decision 2026-07-31)

- **The AFMT audio CRC is CALIBRATED** (`--crccal`, the last thing won on the way out): `CRC_DONE` is **FLOW-GATED** — N1 stopped: no
    completion · F running: tap0 `0x30872b` tap1 `0x9c4a3a` · N2 stopped: no completion. Every past and future tap reading on this block is now
    interpretable, and the ~24 un-adjudicable burns are explained rather than repeated. Both taps are PCM-content-sensitive; a zero CRC with
    DONE=1 really means 2048 ZERO SAMPLES. The counter is gated **per-tap** (Model A) — proven by the encoder's own mute, which stopped BOTH
    counters dead where the shared-strobe model predicted DONE=1/CRC=0.
- **Samples demonstrably reach the encoder output**: arm 2 read tap0 `0x42f0bf` / tap1 `0x9c4a3a` once the codec feed was restarted. ⇒ **the
    fault is DOWNSTREAM of the AFMT output tap** — packetisation onto the link, the transmitter/PHY, or the sink.
- **⛔ The defect that made every modeset-path arm silent was OURS**: `gpu_hdmi_audio_enable()` stops the codec DMA and the only restart was
    the BOOT path, which `MODESET_AUDIO` suppresses — so the arms unmuted over a stopped DMA. Fixed (feed-start is the terminal op of the
    unmute).
- **⛔⛔ THE STANDING FINDING A RESUMPTION STARTS FROM: the sink REJECTS agnos's HDMI signalling outright.** `DIG_MODE`=3 ⇒ no signal for the
    whole run; `DIG_MODE`=2 ⇒ the panel relights every time, everything else identical. A dropped link cannot carry audio, so that is likely
    upstream of the entire audio question.
    **⛔⛔⛔ FALSIFIED 2026-08-10 BY OUR OWN CAPTURE — DO NOT RESUME FROM THIS BULLET.** It is kept, struck,
    because it stated the premise a resumption was told to start from, and a deleted premise gets
    re-derived. `DIG_MODE`=3 **is achieved and it HOLDS**; see the capture-read below.

### ⚖ AUDIT 2026-08-10 (agnos 1.56.43, ZERO burns) — what survives the park, and the one thing that must be settled first

Ordered by how much it changes the next action.

1. ⛔⛔ **THE RECORD CONTRADICTS ITSELF ON THE EXACT QUESTION A RESUMPTION STARTS FROM.** Two load-bearing
   claims about `DIG_MODE`=3, on the same sink, cannot both be unconditionally true:
   - the **standing finding** (above): *"`DIG_MODE`=3 ⇒ **no signal** for the whole run"*;
   - the **2026-07-14 green screen**, labelled in §1.10 as *"this arc's single most load-bearing positive
     result"*: *"**DIG_MODE=3 took**, the DIP engine runs, the AVI egresses, the sink treats the link as
     HDMI."*

   A panel rendering **GREEN/PINK is a lit panel decoding a signal**; *"no signal for the whole run"* is the
   absence of one. ⇒ Either the sink accepts HDMI mode under conditions the pessimistic run did not have, or
   one of the two is misattributed.
   **This is not academic — it decides which arc gets resumed.** Parked pointing at the pessimistic claim, a
   resumption hunts a link-mode rejection the other result says does not exist, while the gap this document
   already flags goes unexamined: *"AVI InfoFrames and Audio Sample Packets come from DIFFERENT generators
   … so 'AVI egresses' does NOT prove 'ASPs egress'."* If DIG_MODE=3 does take, **that** sentence is the
   whole remaining question.
   ✅ **SETTLED THE SAME DAY, FROM THE CAPTURES, ZERO BURNS — and the pessimistic claim LOSES.**
   `prior-art/dcn-modeset-m9-audio-arm-iron-0724.txt` records the whole sequence, twice (once per arm):

   ```
   208: modeset: transmit -- DIG_MODE 2 -> 3 (HDMI signalling live; audio arm)
   281: atom w=566f v=10030200            <- ENABLE writes it, still mode 3
   284: atom w=566f v=10020200            <- ATOM #76 reverts it to mode 2 by itself
   333: modeset: transmit -- DIG_MODE re-asserted to 3 after #76 (ATOM reset it to 2)
   339: modeset: transmit -- DIG_MODE 2 -> 3        (arm 1 final)
   488: modeset: transmit -- DIG_MODE 3 -> 3        (arm 2 — it was ALREADY 3)
   ```

   ⭐⭐⭐ **`DIG_MODE 3 -> 3` at line 488 is the whole answer: mode 3 was set, ATOM knocked it down, agnos
   re-asserted it, and it HELD across the rest of the run into the second arm.** The panel did not go away —
   the operator ran both arms and captured `klug` afterwards. ⇒ **The sink does not reject agnos's HDMI
   signalling.** The link has been in HDMI mode on agnos since 2026-07-24.
   ⭐ Corroborating both directions: amdgpu-playing writes `0x566f = 0x10030200` (mode 3) four times in
   `amdgpu-hdmi-modeset-writes-0717.txt`, and every known-good dump reads `DIG1_DIG_BE_CNTL 0x10030200`;
   agnos's *inherited GOP* state is `0x10020200` (mode 2), which is what the arc kept measuring before the
   flip existed. **The green-screen result is consistent with the captures; the "no signal" claim is not.**

   ⚠⚠ **AND NOTE WHICH RUN PROVED IT: M9 — the retracted null experiment.** Its *ear* result is void and
   stays void (both arms fed digital silence). Its **register trace is a different oracle** — direct MMIO
   readbacks — and is untouched by that retraction. ⇒ **Scope a retraction to the evidence it actually
   killed.** M9's audio conclusion was worthless; M9's `DIG_MODE` trace is the thing that unblocks the arc,
   and it sat unread for two weeks inside a capture labelled "null". [[feedback_retract_the_evidence_not_the_mechanism]]

   ⚠ **Neither prose claim was ever written into the burn ledger.** The green screen has no entry and no
   capture; "no signal for the whole run" has no entry either. Both lived only as summary sentences here,
   and the arc was parked pointing at whichever one got written last. **A finding that is not in the ledger
   cannot be adjudicated later** — which is this repo's own standing rule, applied to a *conclusion* rather
   than a burn.

2. ✅ **The leg's code survived nine cycles of desktop work, intact.** Every symbol the parked playbook
   needs is present and still referenced: `MDO_OP_CRCCAL` + `mdo_crccal()` (`syscall.cyr`),
   `hda_hdmi_feed_running()` (`hda.cyr`), `gpu_hdmi_audio_enable` / `gpu_hdmi_preflight` (`gpu.cyr`), the
   `--audio-pre` / `--audio-post` / `--crccal` arms (`tests/gpu/modeset.cyr`), and **`CRCCAL_REQUIRE` is
   still asserted at prep time** in `burn-prep.sh`. Nothing needs rebuilding to resume.

3. ✅ **The PS/2 excision did NOT break the audio feed** — worth checking, because `pic.cyr` is the file
   that arc rewrote and it names `HDA_TONE`. `hda_stream_service()` is called from the **timer ISR** as a
   polled drain (`pic.cyr:73`, *"polled, no IRQ, like the NIC drain"*), so `pic_init`'s 0xFC→**0xFF** mask
   cannot reach it. The refill path is intact.

4. ⭐ **The native-modeset arc did NOT invalidate the transmitter findings, and this was the real risk.**
   1.56.36/37/38 rewrote the display bring-up *after* the audio work was parked, so every register reading
   this leg reasoned about was taken in a different boot state. **It does not matter, and the 2026-08-10
   capture proves it with no burn spent**: the link is reported **identically before and after** the modeset
   — `display link 2560x1440 total 2720x1481 blanking 160x41` at both line 123 (pre) and line 165 (post) —
   at `pixel clock 241503 kHz`, the same 241.5 MHz the whole arc reasoned about. What native changed is the
   **SCANOUT SURFACE** (800x600 pitch 832 → 2560x1440 pitch 2560, scaler bypassed); the **LINK was always
   native** because the panel is. ⇒ Every transmitter / PHY / CTS / ACR finding in §2.3 stands unamended.

5. ⚠ **The Audio InfoFrame is driven, so "the sink mutes because no AIF arrives" is NOT a free explanation.**
   The physical model above requires AIF 0x84 (*"a sink receiving ASPs with no AIF MUST MUTE"*), and
   `gpu.cyr` does set `AFMT_AUDIO_INFO_UPDATE` on `AFMT_INFOFRAME_CONTROL0` at three sites and gates on
   `AFMT_AUDIO_INFO0 == STEREO`. ⚠ But every `HDMI_*`/`AFMT_*` packet register is **inert while
   `DIG_MODE==2`** (§ the exhausted-classes table), so this says nothing until item 1 is settled — it only
   removes a candidate that would otherwise look attractive on resumption.

**⇒ VERDICT after the capture-read (2026-08-10, zero burns): THE LEG IS UNBLOCKED, AND THE QUESTION HAS
CHANGED.**

- ⛔ **RETIRED as a candidate: "the sink rejects HDMI signalling."** Falsified by our own M9 capture. The
  link runs `DIG_MODE`=3 and holds it. **Do not spend a burn on link mode.**
- ⇒ **THE REMAINING QUESTION IS THE ONE THIS DOCUMENT ALREADY WROTE DOWN**: *"AVI InfoFrames and Audio
  Sample Packets come from DIFFERENT generators … so 'AVI egresses' does NOT prove 'ASPs egress'."* The link
  is HDMI, the AVI is honoured, the samples reach the AFMT output tap — and no ASP has ever been shown to
  leave the encoder. **That gap, not the link, is the arc.**
- ⭐ **The three surviving candidates should be re-scoped accordingly.** (a) sequencing and (b) a write that
  does not latch both now mean *within the packet path*, not *within link bring-up*; (c) the bare-metal
  environment is unchanged. The register-poke class stays exhausted.
- ⚠ **The parked playbook's value has shifted.** Its flag set, blinded-band protocol, negative control and
  one-boot rule all still stand and must be carried. But `--crccal` calibrates the **AFMT output tap**,
  which is already known-good and already proven flow-gated — so it measures upstream of where the question
  now lives. **A resumption should instrument ASP EGRESS, not re-calibrate the tap.**
- **THE REQUIRED FLAG SET for any HDMI-audio burn, discovered one burn at a time:** `HDA_HDMI` (gates the instance-1 HDA controller probe —
    without it there is no HDMI controller, no codec, nothing to bind to) **+ `HDMI_ATOM`** (gates the `gpu_hdmi_audio_enable` CALL SITE) **+
    `GPU_AUDIO_PROBE`** (the ONLY thing that sets `gpu_audio_dig`; unset ⇒ it stays −1 ⇒ silent refusal forever, whatever the hardware does) **+
    `HDA_TONE`** (fills the PCM ring with a ~375 Hz triangle instead of silence). ⛔ **Every HDMI-audio burn since 1.56.25 would have been VOID
    without `GPU_AUDIO_PROBE`** — the probe ran on every boot until it was gated, and nothing added the new flag to the arms that depend on it.
    Evidence: one grep counting `hda: found` across the archive — 2 in the 07-18 captures, 2 in the 07-24 M9 capture, **1 in every capture from
    07-24 onward**. A compiled-out probe leaves NO TRACE in the log.
- **⚠ A STRING CHECK DOES NOT DISCRIMINATE a bare kernel from an `HDMI_ATOM` one** — `gpu_hdmi_audio_*` and its literals ARE emitted in a bare
    kernel (unreachable, not eliminated; this tree does not run DCE). Only the **BUILD SIZE** discriminates: bare **1,926,416 B** vs
    `HDMI_ATOM=1` **1,965,624 B**, a **+39 KB** delta; the three-flag build is **1,969,096 B**.
- **`gpu_hdmi_preflight()` has SEVEN refusal points and the FOUR early returns are SILENT.**
- **The blinded ear protocol**: arm 1 (`--audio-pre`) sweeps 300→600 Hz; arm 2 (`--audio-post`) sweeps 1000→1400 Hz — non-overlapping, an
    octave and a half apart. **The question is "LOW or HIGH?", never "did you hear it?"** A listener hearing nothing cannot name a band, so the
    report is self-authenticating in a way yes/no never is. Do not read the band table to the operator before the burn — the bands ARE the
    blinding. ⛔ **All audio arms must run in ONE BOOT** (one cable, one volume, one power-cycle bracket): sink amp/mute/mode state is
    SINK-LATCHED and every agnos instrument is source-side.
- **The audio clock is ALIVE and in the measurement loop**: programming `HDMI_ACR_N_48` 6144 → 12288 moved measured CTS **241502 → 483006 →
    241502, exactly 2×**, while tracking the pixel clock to 11 ppm. `HDMI_ACR_48_0/44_0/32_0` all read 0 alongside, so `HDMI_ACR_STATUS_0` is a
    genuine measurement, not an echo. CTS arithmetic: `CTS = f_TMDS·N/(128·Fs)`; at N=6144 / Fs=48 kHz this reduces to exactly `f_pixel` in kHz
    — a single unmodified CTS read cannot distinguish "measured against the audio clock" from "counting the pixel clock", which is why the
    N-doubling test exists.
- **Register-offset audit, zero burns**: **105 of 105** audio-block offsets in `gpu_regs.cyr` match Linux v6.6 `dcn_2_1_0_offset.h` +
    `dce_11_0_d.h` exactly, 0 mismatches, every `_BASE_IDX` correct. Headers fetched raw via `curl` — **not** WebFetch, whose summariser garbles
    hex. Two near-misses that are NOT bugs, recorded so they are not re-flagged: `AUDIO_ENABLE_STATUS = 0x6B` is
    `ixAZALIA_F0_AUDIO_ENABLE_STATUS`, a function-level `F0_AUDIO_*` register (a grep for the `_CODEC_` infix misses it — read-only diagnostic,
    not a gate); `GPU_AZ_IX_SINK_INFO0 = 0x3A` is correct 0-based, no off-by-one.
- **HDMI physical model** (durable, nowhere else in agnos/docs): an HDMI link is a DVI link that steals the blanking. Audio and aux packets
    ride ONLY in blanking, guard-banded, TERC4-coded, BCH-protected ⇒ **video working over HDMI proves nothing about audio, because DVI and HDMI
    video are bit-identical.** There is no "I am HDMI" bit on the wire — the sink infers it by receiving valid data islands (above all the AVI
    InfoFrame). Required packet set for stereo 48 kHz L-PCM: Audio Sample Packet 0x02 (~12,000 non-empty stereo ASPs/sec) · Audio Clock
    Regeneration 0x01 (`128·fs = f_TMDS·N/CTS`; 48 kHz ⇒ N=6144; at 241.5 MHz ⇒ CTS=241500; ≥1/field) · Audio InfoFrame 0x84 (≥1 per 2 fields —
    **a sink receiving ASPs with no AIF MUST MUTE**) · General Control Packet 0x03 (AVMUTE; many sinks unmute only on a SET→CLEAR EDGE).
- **⭐ The 2026-07-14 green-screen, this arc's single most load-bearing positive result**: when agnos briefly wrote amdgpu's YCbCr AVI bytes
    the panel came up GREEN/PINK. **A sink can only mis-decode RGB-as-YCbCr if it is receiving, parsing, and HONORING agnos's AVI InfoFrame** ⇒
    DIG_MODE=3 took, the DIP engine runs, the AVI egresses, the sink treats the link as HDMI. ⚠ But AVI InfoFrames and Audio Sample Packets come
    from DIFFERENT generators (AVI = the generic-packet SEND engine; ASPs = the AFMT draining its FIFO), so "AVI egresses" does NOT prove "ASPs
    egress".
- **Sink audibility SETTLED by ear 2026-07-15**: the XB323U DOES emit sound over HDMI under amdgpu, verified with a stimulus the listener
    could not have guessed (three short 880 Hz beeps, pause, one 300→3000 Hz rising sweep, twice) played to `hw:0,7` and only then described;
    the operator's report matched. Twelve prior burns had ASSUMED this. **Consequence: agnos's silence is agnos's bug.**
- **The ALSA device↔pin map on this box is not sequential and not the pin nid** — derive from `pcmNp/info` id: `hw:0,3` = HDMI 0 = pin 0x03
    cvt 0x02 · **`hw:0,7` = HDMI 1 = pin 0x05 cvt 0x04 = the XB323U** · `hw:0,8` = HDMI 2 = pin 0x07 · `hw:0,9` = HDMI 3 = pin 0x09. ELD and pin
    presence are **DYNAMIC** — they vanish when the panel sleeps, so a capture is only valid with the display awake; `codec_cvt_nid` reads 0x0
    when idle and 0x4 once a stream is bound (a binding indicator, not static topology).
- **Capture gotchas that cost real time**: `ffmpeg -f lavfi -i sine` emits MONO and an HDMI pin **REFUSES a 1-channel stream** (`cannot set
    channel count to 1`) — `-ac 2` is mandatory, and this looks like a hardware finding and is not one. PipeWire is not usable on this box
    (WirePlumber claims no ALSA cards, alsa-utils absent) — play straight to ALSA via ffmpeg. `/proc/asound` is world-readable and
    `/dev/snd/pcmC0D7p` carries an ACL, so the codec half needs no sudo; the BAR5 half does.
- **The shutdown release pop is the arc's ONLY sink-side instrument** (agnos cuts power with the amp still energised; Linux tears the path
    down first). ⛔ Do not enable `BURN_AUDIO_TEARDOWN` / `gpu_hdmi_audio_disable` anywhere in this arc without deliberate intent — a clean
    teardown destroys it. Exposed side-bite, never closed: **agnos has no orderly audio teardown.**
- **DMCUB is DORMANT at boot**: `CC_DC_PIPE_DIS 0x10000` (block present) · `DMCUB_CNTL 0x20000` (SOFT_RESET set, ENABLE clear) · `SCRATCH0 0`
    (no firmware) · `INBOX1 base/size/wptr/rptr all 0` (no ring). The display is up yet the DMCUB never ran ⇒ **the GOP brought the transmitter
    up via HOST-ATOM.** DMCUB is an OS-driver-loaded thing; agnos's boot-inherited world is host-ATOM. `symclk_se` does not exist on DCN 2.1
    (added 2024 for dcn35/dcn401).

## 1.11 DOOM-on-agnos: the render blockers, all resolved

Carried from `doom-on-agnos-render-blockers.md`. DOOM renders (cyrius-doom 0.28.2 `--agnos`, 2026-06-08).

- **PMM 2 MB pool 16 MB → 128 MB**: `pmm_total = 32768`, `pmm_alloc_2mb`/`pmm_count_2mb_free` scan regions `r=1..63`, `pmm_page_valid` ceiling
    32768. The **4 KB allocator is UNCHANGED at `4095`-down** so page tables and slabs stay in 4-16 MB. ⚠ The earlier "enlargement breaks exec"
             conclusion was a **harness artifact** — `exec-smoke.sh` needs the kernel pre-built with `EXEC_SELFTEST=1` and the runs had built it plain,
             so the selftest never ran and every gate "failed".
- **Per-process CR3 must map the whole PMM range**: `proc_create_address_space` also maps **PD[8..63] = 16-128 MB as identity-SUPERVISOR 2 MB
    pages**. Without it `sys_mmap`'s identity-address `memset` on a phys ≥16 MB faults ring-0 #PF → #DF (`qemu -d int`: `e=0002 cpl=0
    CR2=0x011f0000`).
- **The "first-mmap RIP=0" bug was never a first-mmap or SYSRET bug** — it was the user stack living in the kernel identity-mapped range.
    Stacks at `0x800000 + pid*0x400000` put **pid ≥ 2 at ≥16 MB**, inside the identity-SUPERVISOR pool; `proc_map_page` then overrode that PD
    slot, breaking the identity map for that VA, so a later `memset` wrote the **live ring-3 stack** and the next `ret` jumped to RIP=0. Fix:
    stacks moved to `0x3FC00000` (PD[510]), mmap ceiling dropped to `0x3FA00000`, plus an explicit `invlpg` after the PDE store. It hid because
    doom-smoke ran doom via the in-kernel `run` (lower pid ⇒ stack below 16 MB).
- **Keyboard input**: `kbscan`#42 — a **non-blocking** drain of up to `max` raw Set-1 scancodes (make + break, incl. `0xE0` prefixes) from
    `kb_buf`. Opens a bounded IRQ1 window with no `hlt` so a poll never stalls a frame. cyrius-doom decodes make/break into **persistent**
    `key_state`.
- **"Walls batch as textured quads" is REFUTED** — `tests/gpu/doomwall.cyr` measures 4096/4096 px wrong at a 1.5× depth ratio, because
    `ty_step = 1/depth` is a hyperbola in screen x. **Batch by DISPATCH, never by geometry.** A single column IS bit-exactly an op `0x0B` quad
    (`doomcol`, 7/7).

# 2 — WHAT IS FALSIFIED

Each was tested and killed. Iron burns block the operator's only dev machine; re-opening one of these wastes a burn. **This is the
highest-value section in the file.**

## 2.1 Compute, shader and 3D

| Killed | What killed it |
|---|---|
| "The BIOS/PSP leaves usable CP/MEC/RLC ucode resident, so agnos can skip the firmware load" | iron 1.54.1: `rlc=0x0`, `me=0x15000000`, `mec=0x50000000` — RLC off, both halted, no ucode |
| "Compute needs gfx9 GPUVM per-VMID page tables (PTE/PDE + TLB flush)" | GART ABSENT; zero-page-table addressing through the FB aperture proven end-to-end (`fault=0` on the first PM4 fetch). Building them is dead work AND re-introduces the VM-fault-storm CPU wedge the design excludes |
| "The BAR2 posted doorbell advances the queue wptr" | iron 1.54.12: it did not; register-wptr submit works and is what every bite uses. ⚠ The broader "doorbells can't deliver on this hardware" is ALSO wrong — Linux drives SDMA on this exact box, so it is an agnos SETUP gap |
| "`ACQUIRE_MEM` with `TCWB` is write-BACK, not invalidate" | RADV IB decode: `0x00840000` carries `TC_ACTION_ENA` = **L2 INVALIDATE**. The highest-cost doc error in the arc — it is the root cause of the S3 arm-D design, which primed L2 with a dispatch whose own trailing packet invalidated the lines it had just populated, making both sub-arms unfalsifiable and wasting the 1.56.4 burn |
| "The gfx90c ISA / the shader itself is wrong" (C2f, 3 burns) | the kernel was correct throughout; the defect was the **WPTR LO-before-HI** submit order. Blaming the ISA before byte-confirming the submit sequence cost two burns |
| "CPU-pre-seed a buffer (UC) and use the read-back as the oracle" | the CPU read back only a **stale-L2 ghost** of the previous value, so the test could not distinguish zero-waves from a wrong store address. Always dispatch into a fresh, never-CPU-touched slot |
| "The per-dispatch fence is the throughput wall" (S12) | batching to one submission gave only 1.78× and the frame stayed ~87% fixed cost. The wall is the six per-dispatch whole-L2 invalidates |
| "Coverage needs LDS + `ds_read/write_b64` + a bitonic sort" (9b design A1) | the DS format has **zero** functions in mabda's encoder, no agnos shader has ever issued a DS instruction, and no shipped `RSRC2` sets `GRANULATED_LDS_SIZE` (`gpu_regs.cyr:1088,1097,1108,1113` all zero). SH registers are not readable, so a wrong LDS allocation has **NO ORACLE** — and A1's proposed self-witness (write slot 0, read it back) tests round-trip, not allocation size. A1's central "LDS is forced, not chosen" is FALSE: an LDS-free per-lane form verified **221/221** |
| "A 30-iteration restoring divider is sufficient" (9b design A1) | its seed invariant `R = P>>30 < d` fails once `\|bx−ax\| ≥ 2^30` — **inside** the region where `cpuref` is still well-defined. Raising the trip count does not fix it, and the iteration count derives from a validator guard **that does not exist**, so relaxing that guard later would silently corrupt output with no fault |
| "An 8×8 tile dispatch mapping" (9b design A2, SB-8) | contradicts every shipped 2-D consumer, all of which use `gx=(w+63)/64, gy=h` |
| "Two `DISPATCH_DIRECT`s chained in one submission" (9b design A2) | agnos has never done it; replaced by two sequential `gpu_blend_cov_run` calls with **zero new PM4** |
| "Ship A3 (staged-and-stopped) as the rung" (9b design A3) | a dead end for all of Phase II: it puts i64 raster math and a 256-entry insertion sort into `gpu.cyr`, which this file forbids verbatim, and it biases rung 10's kill gate toward a **FALSE KILL**. ⭐ Kept from A3 and still true: `min(acc, 65536)` before the ×255, and "the fragment **multiset**, not the covered length, is the spec" |
| "RGBX↔BGRX permutation is an unhandled case" | handled twice over: FREE in the HUBPRET crossbar for the whole scanout, ONE `v_perm_b32` per surface |
| "One syscall number per shader op" (S8/D-3) | shipped as #92/#93/#94 verbatim the column D-3 had rejected, then restored to the single `#92` array. The array wins: only four dispatcher args but a coverage blit needs five operands, and it makes batching an implementation change rather than an ABI break |
| "`cmp` of the two binaries proves the `#ifdef` flag landed" | `cmp` proves they DIFFER, not that the difference is the code under test. This tree does not run DCE, so a marker in an always-compiled function verifies nothing — which is how `*SCANOUT_REGDUMP*` shipped matching on a string outside its own `#ifdef` |
| "`s_cbranch_execz` alone is the right-edge bounds guard" | it only skips when ALL 64 lanes are out of bounds; the 1-63 straggler lanes are precisely the ones that store past the edge. ⚠ Never proven with the planned negative arm — S6 shipped at w=200 with no unguarded control, so "the guard stopped the overrun" is INFERRED |
| "Vendor a SPIR-V compiler in-kernel" | actually built, provably freestanding-clean, and buys nothing: +4,641 LOC (+8.5%), ~80 KB stack per compile, pulls f32/f64 intrinsics into deliberately integer-only kernel text, and **there is no SPIR-V producer anywhere in the ecosystem** |
| **rung 11: clamp `E_i` to `[0, 2A]`** — the graft all three judges independently called "the best single idea" | the clamp is inert only where all `E_i ≥ 0`, i.e. **inside the frame** — and a triangle does not contain its own bounding box. At the gradient rect's last pixel the unclamped sum is exactly right while the clamped one gives **≈192 instead of 0**. The individual `E_A` goes negative while the SUM stays correct, and that cancellation is exactly what the clamp destroys |
| **rung 12: "overlap ORDER is the first suspect"** | the tool printed that line twice and was wrong both times. Every one of the 6 triangles was EXACT ALONE; probe P3 (a bare `0x08` coverage dispatch after a rendered rect) exonerated the coverage pass; probe P2 (an n=2 whose second triangle covers nothing) **still lost 1,711 px**, exonerating blending and overlap entirely. The defect was work done once per CALL that must be done once per TRIANGLE — the prep-arena race |
| **rung 12: "suspect the EMISSION"** (twice) | both times the defect was in **THIS TOOL's reference** — the instrument was feeding the reference the wrong coverage. `trimodel` proves the algorithm and two assemblers agree on the code; **the instrument is not above suspicion** |
| **rung 10's pre-registered crossover** (~12,000 unbatched / ~50,000 batched px) | measured **1,751 for both** — wrong by ~7×, in the favourable direction. A crossover above a real frame's coverage would have killed the tier-1 justification for rungs 11-12; it did not |
| **rung 17: three of four depth-clear predictions** | 32 MB cost LESS than 2× the time of 1.92 MB (bytes 17× vs time ~0) ⇒ the op-0x0D worker was a **no-op** even though both clears returned 0. A zero return proves only that the syscall returned; the target is kernel-owned and unreadable from ring 3, so **TIME is the only oracle** |
| **"cost is the grid you launch, not the pixels you shade"** / "an exiting wave is not free" | refuted by a third data point at 24× fewer waves: **a = −5 ns/launched (zero), b = 36 ns/working** — which is why ragged is cheaper than uniform at the same launch count |
| **`v_rcp_f32` for the perspective divide** (rung 18), despite the plan prescribing it | its own risk column admitted "the CPU reference must use the same approximation", which makes the reference **a MODEL OF THE HARDWARE** — the shared-premise structure that had already cost rungs 15 and 17 a burn each. Replaced by an exact 56-iteration restoring divide. The same reasoning retired `v_rcp_f32` from the rung-9b raster kernel |
| **`SHADER_COV=1` alone** | a **silent no-op** — `gpu_shader_cov_test` early-returns unless `gpu_blend_ok == 1`, which is set only by `gpu_shader_blend_test` under `SHADER_BLEND`. Cost one burn arm. `build.sh` now **hard-fails** on the combination, negative-tested against the exact flag set that produced it |
| **"`gpuwedge --audit` is read-only"** | despite its own READ-ONLY banner it audited and then fired an **UNGUARDED WRITE**. Renamed `--slot-audit`. A capture is read-only if the CODE is read-only, not if the banner says so |
| **"recovery corrupts the GPU"** — the reading of arm C-after | ⚠ **UNTESTED, not observed.** Arm C ran while the GPU was **still wedged** (`hqd_active 1`) because R-4 had already given up; C's failure is a consequence of B's, not independent evidence |

**⛔ A GREEN ORACLE ON A SHARED PREMISE PROVES NOTHING — paid for with a burn TWICE.** At **rung 15**, BILINEAR was 5/5 byte-exact against
the reference while both sides used `floor(u)` instead of `floor(u−0.5)`; only the **discrimination gate** — the one measurement NOT
compared against the reference — caught it. The algebra is convention-free: for texel *i*'s centre at *i+c*, ANY *c*, correct nearest =
`floor(u−c+0.5)` and correct linear taps = `floor(u−c)`, differing by exactly 0.5 for every *c*; AGNOS shipped both as `floor(u)`, a
difference of zero, so **"a different but self-consistent convention" was never available** (3 adversarial refuters, 0 of 3 could refute).
Worse, `bigate` G2 and `texgate` GATE 10a probed **exact integers**, which `tex_uv_at` (always +32768 for the pixel centre) can never emit
at any integer scale — evidence collected on the null set of the error, with 10a *asserting* the bug. At **rung 17**, colour and z agreed at
**0 px across both submission orders** while differing from the CPU reference at **1024 px** in both: **a wave-uniform kernarg misread is
DETERMINISTIC, so no order or determinism test can see one.** ⇒ **At least one gate must test an EXTERNAL invariant.** ⛔ The rung-15 fix was
NOT folded into `gpu_tex_prep`'s `mu`/`mv`: `limu = (tw*65536 − mu)*a2` is derived FROM `mu`, so biasing `mu` shifts the out-of-domain
predicate by half a texel, and `mu` is shared with op `0x0C`.

## 2.2 Display

| Killed | What killed it |
|---|---|
| "The display is on DP output 2" | `DP_DTO0_ENABLE`=0 and `DP_VID_STREAM_ENABLE`=0 ⇒ not DP-SST; the live encoder is DIG1 in DIG_MODE=2 and the cable is HDMI. **There is no DP output on this part** — HDMI audio was the whole audio effort |
| "Snap the measured refresh to a standard-rate table" | built, IRON FALSIFIED, deleted. It snapped to **59.94 Hz — a television rate on a PC monitor** — turning a 7.5 ppm measurement into a **176 ppm** answer. CVT quantises the PIXEL CLOCK to a 0.25 MHz step; 59.9506 Hz is the LEFTOVER. Nothing should ever "correct" it toward 60.000 |
| "Snap the pixel clock to the 0.25 MHz CVT grid instead" | killed analytically on this link's own data: the **WRONG** totals decode lands **+0.08 ppm** from a grid step while the **CORRECT** decode lands **+7.5 ppm** — **the bug fits the grid 75× better than the truth.** A grid launders a register-decode bug into a confident exact number. **DO NOT SNAP AT ALL** |
| "The 500 ppm snap tolerance gates the derivation" | **dead code** across [59.94, 60] — the candidates are ~1000 ppm apart and the gate sat at the half-spacing, so something ALWAYS matched. A gate must sit on an axis where it can fire |
| "Derive timing / pixel clock / vblank from `fb_width()`/`fb_height()`" | those are the **800×600 SURFACE** plane, not the 2560×1440 RASTER plane, with a live scaler between. The guard passed only by accident because 2720 > 800 |
| "Either OTG total identifies the mode alone" | brute-force scan: **2720** also fits 2560×1080 and 2560×1600 at every rate; **1481** also fits 1920×1440@60 and 3440×1440@60. Only the PAIR is unique |
| "Read the pixel clock out of a register" | the DCCG register holding the audio DTO MODULE is only populated on a **DP-driven** pipe; this link is HDMI so it reads **0**. Divider math returns the un-spread CENTRE while frame-counting returns the AVERAGE — and the average is what the audio DTO wants. **The measurement is more correct than the register** |
| "The DVI→HDMI `DIG_MODE` 2→3 flip is a high-risk burn" | overstated: every `HDMI_*` register is **inert while `DIG_MODE==2`**, so the config stages at zero risk and the flip is a one-field RMW. ⚠ But a LIVE poke is not a modeset |
| "Gate anything at DVI's 165 MHz ceiling" | this link legitimately runs 241.5 MHz at DIG_MODE=2 — DVI *signalling* on an HDMI physical link, 7.245 Gbps = 71% of HDMI 1.4's ceiling. A 165 MHz gate would falsely refuse a correct read |
| "SDMA is the right primitive for 2D acceleration" | 2D landed via **CP-DMA on the compute ring**. SDMA is PARKED after six burns, all TIMEOUT at `rptr 0`, with a known resume state: `sdma halt 0 idle 1 rptr 0 wptr 44 cnt 266269 cap 0 cntl 262146` — `cntl 0x40002` proves AUTO_CTXSW latched (scheduling was not the gate) and `cap 0` proves the doorbell never reached the engine. **An agnos SETUP gap, not a hardware limit** |
| **"The Quiet-Boot banded glyphs are a tiled or DCC-compressed scanout surface"** (OSDev #57150) — survived two months as the last standing hypothesis and was STILL WRONG | the real cause was a **surface/raster SCALE mismatch**: the firmware leaves an 800×600 surface DCN-scaled to 2560×1440 while boot_info reports the OUTPUT, so `fb_console` rendered 2560-wide and smeared. Fix = read viewport `0x5EA` + pitch `0x607` and override the console geometry, **READ-ONLY, no register writes**. Neither parked remedy (a HUBP `clear_tiling` port, a simpledrm-style shadow buffer) was needed. ⚠ Along the way, writing the "correct" pitch 2560 to `0x607` under the OTG lock **BLACKED THE PIPE AND HUNG THE BOX** |
| **GOP-side `SetMode` in BOTH shapes** — same-mode re-arm (gnoboot 0.4.1) and different-mode bounce (0.4.2) | neither produced any visible mode-switch flicker on VGA or HDMI. **AMD Zen UEFI elides both call shapes.** Never re-propose a GOP-side SetMode workaround on AMD iron |
| **The D lane's first four burns** | ⚠ FOUR OF FIVE were lost to the HARNESS, not to register work: (a) a hold on a bounded vblank poll collapsed a 4 s display window to ~50 ms; (b) **TWO burns whose stimulus was an ACHROMATIC console — every pixel `0x00FFFFFF` or `0x00000000`, R==G==B, so ANY colour permutation is the IDENTITY.** Those two could not have shown a change no matter how correct the register work was. That is arithmetic, not bad luck; (c) a register decoded by eye |

## 2.2b NATIVE RESOLUTION — `MDO_OP_NATIVE` (#93 op `0x0B`) — BUILT 2026-08-03, awaiting its first burn

**Every input was measured before a line was written.** This section is now the record of what shipped,
plus the two things the burn has to answer.

### What the 2026-08-03 read-only burn established

- **A native 2560x1440 framebuffer ALREADY EXISTS**, allocated by the firmware after gnoboot 0.6.1's
  GOP `SetMode`: `fb: w=0xa00 h=0x5a0 pitch=0x2800 phys=0xd0000000 size=0xe10000 mode=0x1`.
  `0xe10000` = 14,745,600 = exactly 2560x1440x4. **No allocation and no pitch invention is needed.**
- **DCN was NOT reprogrammed by that SetMode.** HUBP still reads viewport `0x5EA` = `0x02580320`
  (800x600) and pitch `0x607` = 832 px, and upscales to the 2560x1440 link. GOP moves the GOP surface;
  it does not touch DCN. That is the whole bug.
- ✅ **RESOLVED — the missing `0x60A` was an artifact of the DUMP, not a mystery in the hardware.**
  `gpu_scanout_regdump` (`gpu.cyr`) skips zero values to keep the klug ring small. The surface sits at
  MC `0xF4_00000000`, so the low half reads **0** (skipped) and `0x60B` reads `0xF4` = **244** (printed)
  — which is exactly `fb_base + (fb_phys - BAR0)` for `fb_phys == BAR0 == 0xd0000000`, the transform
  `gpu_display_probe` has used since 1.55.1. ⇒ **The surface base does not move**, and the address write
  in the op is a same-value write. It still reads and reconciles first (`MDO_E_SURFADDR` on a value it
  cannot account for), because "the address is where I think it is" is a thing to verify on the day.

### What shipped

Runtime op behind the `/.modeset-armed` latch (`modeset_arm` site **11**), never a boot-time write: a
bad write costs one reboot and the latch stops it re-firing into a loop. Envelope mirrors
`mdo_recommit()`. Guards → save the HUBP group → `OTG_MASTER_EN=0` → `DSCL_MODE`→bypass, viewport,
pitch, surface address → `OTG_MASTER_EN=1` → verify → rollback on failure → `fb_set_geom` +
`fb_console_clear`. Registers, encodings, `MDO_E_*` reasons and tool exit codes are in the 1.56.36
CHANGELOG entry and not duplicated here.

⛔ **`SCL_MODE` bypass and the pitch move in ONE envelope.** Writing pitch 2560 to `0x607` with the
scaler still active blacked the pipe and hung the box (§2.2). Source geometry and scaler mode are one
atomic fact, which is also why the op refuses (`MDO_E_RASTER`) unless the target **equals** the link's
active raster — with DSCL bypassed, source and raster must match exactly, and a target that does not is
a scaled mode wearing a bypass.

### Two corrections this implementation made to the spec that preceded it

- ⛔ **The target must come from `boot_info`, NEVER from `fb_width()`/`fb_height()`/`fb_pitch()`.** The
  first draft of this section said to guard on `fb_width()==2560`. Those accessors return the **P4
  geometry override** once `gpu_scanout_matchgeom` has run — i.e. **800x600**, the very state being
  corrected. That guard would have read "already native" on the broken pipe and refused forever.
- **Check the frame-count STOP before reprogramming, not after.** `mdo_recommit` checks at the end
  because every one of its writes is same-value and harmless on a live pipe. These writes are not: a
  pitch change on a scanning pipe is precisely what hung this box. If the disable did not take, the op
  puts `MASTER_EN` back and leaves the HUBP untouched (`MDO_E_NOSTOP`, tool exit 89).

### Oracle — and the instrument that cannot serve as one

The **panel**. ⚠ The OTG frame counter free-runs off the PLL, so it advances on a black screen exactly
as it does on a good one (the M6 finding). A green `exit 95` means the ENVELOPE survived — stopped,
reprogrammed, relit, counter moving — and says nothing about whether there is a picture. Both the
kernel's success line and the tool's say so in as many words. Capture with `run /bin/klug > native.txt`,
then disarm with `rm /.modeset-armed`.

⛔ **BURN ORDER: `modeset --native` FIRST, THEN THE DESKTOP.** `fbinfo` (#38) and `blit` (#39) re-read
`fb_width()`/`fb_height()`/`fb_pitch()` on **every** call, so the kernel side follows this op the instant
`fb_set_geom` runs. A **compositor sizes its surfaces once**, at startup, from the `fbinfo` it read then
— so running `--native` under a live desktop leaves it blitting an 800x600 buffer into a 2560x1440
scanout: a small picture in the corner, which looks exactly like this op failing when it in fact
succeeded. That is a burn spent on a false negative, and the tool now prints the warning on success.

### The one named risk, so a bad burn is adjudicable

**The DLG/TTU/RQ deadline registers are NOT touched.** The firmware's DML computed them for an 800x600
fetch; a 2560x1440 fetch is ~7.7x the per-frame bytes (1.92 MB → 14.7 MB, ~115 MB/s → ~885 MB/s at
60 Hz). The **bandwidth** is trivial for this UMA part; the **urgency scheduling** may not be. So the
expected failure mode, if there is one, is a **HUBP underflow — a corrupt or black panel on a pipe whose
frame counter is happily advancing.** ⇒ If the burn shows that, the next bite is **cloning HUBP0's DLG
group**, NOT re-litigating the geometry. The op logs `underflow <before> -> <after>` for exactly this
reason. ⚠ OPTC bit10 is already set at boot on this iron (§M6/D1), so a `0 -> 1` delta is the only form
of that instrument worth reading.

### What must NOT happen

- ⛔ No boot-time native modeset until the op has succeeded on iron at least once.
- ⛔ No fourth GOP `SetMode` variant. That lever is finished: it does exactly what UEFI promises
  (moves the GOP surface) and nothing more (does not touch DCN).
- ⛔ Never index `GPU_R_DSCL_SCL_MODE` by a DPP instance stride — that stride is not anchored on this
  silicon. Pipe 0 only, which the op guards and which is archaemenid's only lit pipe anyway.

## 2.3 HDMI audio — the exhausted classes

| Killed | What killed it |
|---|---|
| **The DCCG SYMCLK lead** (abs `0x159`/`0x15A`/`0x15B`/`0x15C`, `0x176`) | TWO independent kills. (1) **REGISTER IDENTITY** — abs `0x159`-`0x15C` are `DPPCLK0..3_DTO_PARAM` and `0x176` is `DPPCLK_DTO_CTRL`, display-pipe clock DTO parameters, NOT symbol-clock enables; the real `SYMCLKA_CLOCK_ENABLE` is abs `0x160`, and amdgpu writes **ZERO SYMCLK registers anywhere in the 11,582-entry modeset capture**. (2) **BEHAVIOURAL** — an in-boot A/B ran window A (all zeros) against window B (`159=0xd000d 15a/15b/15c=0xd000a 176=0x1111`) twice: **the writes demonstrably LANDED and the sound was unchanged.** Corroborating: abs `0x159` reads 0 on a LIT, WORKING display, and the symbol clock was already ON in every silent burn (`fe=1000000 be=101` byte-identical at line 160 of all eight logs) |
| "Burn 10 showed the SYMCLK write ARMED the sink (pop + noise floor)" | retracted the day it was written and then fully killed three ways: the clock was already on; the shutdown pop was FIRST HEARD five burns and four cuts BEFORE the write; and ZERO instruments moved (burn 8 silent and burn 10 "armed" are byte-identical on seven registers). Operator testimony removed the last support — the noise floor RECURS independent of the write |
| **AFMT RAMP** | values programmed and confirmed in the dump (`0xffffff` / `0x7fffff` / 1 / 1) — still silent **AND the shutdown release pop DISAPPEARED**, i.e. non-zero envelope values actively WORSEN DCN 2.1. Reverted. NEVER RE-PROPOSE |
| **Sample MAGNITUDE** | driven at **−0.8 dBFS** (amplitude 30000) with the full SINE/SQUARE/SAW/TRIANGLE + 220-990 Hz sweep battery — still silent. Exonerated |
| **"The ATOM ENCODER setup is the missing step"** | an encoder-setup-only run (`transmitter SKIPPED`, `encoder rc=0`, `reads=5 writes=5 delays=2`, `HDMI bringup OK`) was display-SAFE and **STILL SILENT**, with the register file **byte-identical to the silent baseline** |
| **The register-OFFSET axis** ("the silence is a mislabelled offset, the `0x607` class of bug") | an independent audit returned **105/105 correct, 0 mismatch**, every BASE_IDX right, including every transmission-gating register the hypothesis named. ⚠ Note WHY the earlier byte-identical diff could not have caught it: `dump-dcn-audio.py` hardcodes the SAME offsets as `gpu_regs.cyr` and reads them on both sides, so a mislabelled offset reads the same wrong register on both and byte-matches invisibly |
| **The whole REGISTER-POKE class** | every AFMT control register is byte-identical to a working amdgpu and the audio is still silent — and at 1.55.26 the last three diverging registers were made byte-identical too (`DCCG_AUDIO_DTO0_MODULE` `0x24d9b2`→`0x24d998`, `HDMI_ACR_STATUS_0` `0x3af5e000`→`0x3af5c000`, `ACR_48/44/32_0` 0→`0x3af5c000`), the kernel logged `acr cts programmed (241500, amdgpu-match)`, **and the sink was STILL SILENT with tap1 reading silence.** ⚠ Direction matters: it made things WORSE. **Register-value equality with a working driver does not produce sound** |
| "Copy amdgpu's CTS literal to avoid divergence" | backwards reasoning — amdgpu wrote 241500 because **amdgpu's own clock was 241500**; agnos's is 241503 kHz. A CTS that does not match the actual TMDS clock breaks the sink's regeneration ⇒ null cells, which is exactly what zeroed tap1 |
| **The entire AUDIO-CLOCK hypothesis class** | the N-doubling test: CTS **241502 → 483006 → 241502, exactly 2×**, tracking the pixel clock to 11 ppm. A stalled read clock cannot produce that |
| **`AFMT_STATUS` bit24 "the FIFO is overflowing"** | **`0x40000010` in ALL ELEVEN iron captures, byte-identical to amdgpu WHILE AUDIBLY PLAYING** (`0x41000010` is amdgpu MUTED). False, and always was. The kernel explicitly logs `AFMT drain steady after feed (bit24 clear)` in every 0716-0720 burn |
| "The payload is digital silence / something zeroes the samples" | calibrated tap identity: digital silence reads exactly `0x000000` at BOTH taps, and burn 11 read `tap0=249f2f tap1=b9b93c`. Content survives to the last observable stage — **do not hunt a zeroing bug** |
| "Feed-before-drain FIFO phase is THE root cause" (declared iron-confirmed) | the reorder shipped and **both** predicted instruments flipped exactly as forecast — tap1 went non-zero for the first time and bit24 cleared — **AND IT WAS STILL SILENT.** Necessary, not sufficient. The bug was real; the diagnosis of it as the root cause was wrong |
| **The whole Azalia / codec / HDA-link / DMA / converter / stream-tag class** | all UPSTREAM of tap 0, and tap 0 carries real samples. **The exoneration is FINAL, not provisional.** Independently: a from-scratch Linux userspace driver reproducing agnos's ENTIRE feed verbatim from `hda.cyr` played AUDIBLE SOUND |
| **AVMUTE holding the sink muted** | `HDMI_GC = 4` on agnos vs `0x00000004` on amdgpu-playing, `HDMI_ACTIVE_AVMUTE = 0` on both. Ruled out free. Separately, the cold output-enable + AVMUTE SET→CLEAR edge shipped and burned SILENT — **and the SCREEN VISIBLY BLANKED during the DIG_ENABLE drop, so the sink received a genuine link event and still played nothing** |
| **The IEC-60958 framing reading of the CRC taps** | if either tap read framing, its CRC would be NON-ZERO over an all-zero stream (the `AFMT_60958_*` registers are programmed non-zero and byte-identical on both paths). Digital silence read exactly `0x000000`. `CRC_SOURCE` selects a STAGE, not a channel — a channel selector already exists at `CH_SEL [15:12]` and was 0 in every run |
| **The DMCUB T-series** (Path A attach-the-live-ring / Path B PSP-load-the-firmware) | the GOP's DMCUB is HELD IN RESET with no ring and no firmware, yet the display is up. The entire T1-T4 ladder is retired — DO NOT IMPLEMENT IT |
| **Capture-and-replay the PHY bring-up MMIO sequence** (P5a-d) | ⛔ **`amdgpu-hdmi-transmitter-phy-seq-0717.txt` is NOT what its own header claims.** It is HUBPREQ0/HUBPREQ3 **PAGE-FLIP** traffic — every offset decodes to `DCSURF_*_SURFACE_ADDRESS`/`FLIP_CONTROL`, the recurring `0xb2f00000`/`0xb2000000`/`0x000000f4` are framebuffer addresses, and the ~207× repeat was ~207 vblanks. The REAL RDPCS/DPCS registers got **ZERO writes** in the whole capture. **⛔ NEVER REPLAY IT** — doing so writes framebuffer addresses and flip control into the live scanout HUBP. The file is kept as a capture with its header known wrong |
| **"The sovereign cold HDMI transmitter bring-up is the missing piece"** | matched read-only captures: the PHY/RDPCS block is **BYTE-IDENTICAL** between agnos-inherited-DVI and amdgpu-HDMI-playing — every `RDPCSTX0/1`, `UNIPHYA/B`, `CHANNEL_XBAR`. As predicted for a 241.5 MHz link (below HDMI's 340 MHz scrambling threshold), DVI and HDMI use the SAME PHY |
| **"The SMU/PMFW gates the transmitter"** | airtight: the Renoir VBIOSSMC message enum contains no transmitter/DIG/PHY message, and agnos already sends the only relevant one |
| **`phyid = 0`** | it came from a best-effort VBIOS object-info derivation (`enc_enum − 1`) carrying its own `[TODO confirm on iron]`, hardcoded at `atom.cyr:971`. Replaying `#76` against the iron snapshot showed **87,292 reads vs 21**. Derived-not-measured cost a burn |
| `DTO2_USE_512FBR_DTO` (bit20) · `DIG_STEREOSYNC_GATE_EN` · the DCCG audio-DTO read-clock discriminator | source and silicon agree the HDMI branch never touches 512FBR (the playing link reads `DCCG_AUDIO_DTO_SOURCE = 0`); agnos ALREADY writes STEREOSYNC_GATE and gets no audio; and **there is no DTO accumulator** — `DTO0_PHASE`/`_MODULE` are pure config, `0x3a980` in EVERY agnos burn AND on amdgpu's playing link. Zero information in either branch — a textbook echo register |

**⛔⛔ M9 "SEQUENCING IS ELIMINATED" IS RETRACTED — THE 2026-07-24 M9 BURN WAS A NULL EXPERIMENT.** Both arms streamed **digital silence** (no
`HDA_TONE`, no ring-3 feed ⇒ both fed a zero-filled ring), and "both silent" was recorded as the falsification of the sequencing candidate.
**Sequencing is RE-OPENED.** ⭐ Three of the four consecutive information-free experiments were FLAG omissions and one was a STIMULUS
omission, **and the stimulus one is worse — every flag omission at least printed a refusal naming a precondition, while a silent ring prints
a complete, healthy, entirely believable log.** Nothing downstream can tell it from a hardware answer, which is why it survived three cuts
and became a "dead lead". ⛔ **Blind an ear-oracle arm by tone BAND, never by removing the tone.**

**⛔ L1 RETURNED VOID.** The amdgpu-blacklisted Linux-userspace discriminator ran 2026-07-24/25 (zero agnos burns) and **arm D — the POSITIVE
CONTROL, which unmutes both before AND after the transmitter edge — was SILENT with all four validity conditions independently verified**:
feed actually running (`feed_start lpib_advanced=True lpib=4768`), ATOM edge actually ran (`#4 ret=0`; `#76 DISABLE ret=0 r=30 w=23`; `#76
ENABLE ret=0 r=74 w=45`), audio actually played (requested 6,000,000 µs, actual 6,000,351 µs), link actually in HDMI mode (`W 0x566F <-
0x10030200`, readback mode=3, restored to 2). **A positive control that cannot sound means the harness cannot carry audio, so the P-vs-Q
comparison carries NO information.** ⛔ **NEVER record L1 as "sequencing did not matter". L1 said L1 CANNOT ANSWER.** All 12 blinded windows
across arms P/Q/D/N0/N1 reported `nothing`.

**L1's three positive findings, which are durable:** (1) **ATOM `#4` and `#76` EXECUTE FROM LINUX USERSPACE** — a real PHY DISABLE→ENABLE
power cycle from userspace with the box surviving, overturning the premise that the edge would have to be a hand-rolled `DIG_BE_CNTL` flip.
(2) **agnos's display-pipe bracket is NOT REPLAYABLE from Linux userspace** — both halves wedge independently: `OTG_MASTER_EN → 0` is a HARD
APU WEDGE (abs dword 20481, `W 0x80011300` from `0x80011301`, readback `0x80001300`, box died before the next MMIO read — **and it
reproduced with fbcon UNBOUND, falsifying "the console was scanning it out"**), and the `FE_SOURCE_SELECT` BE↔FE teardown is a HARD APU
WEDGE (died on the third write with the GPU already returning the bus-error pattern `0xEF0CFC55`). `DIG_MODE` 2→3 alone with routing
untouched SURVIVES. ⇒ **userspace can only run a strict SUBSET of agnos's program, and the dropped parts are plausibly exactly the parts
that matter.** (3) It produced the FIRST GOP-DVI register dump the arc ever had, and closed X-7: `HDMI_CONTROL` on DIG1 reads `0x00010011` —
a value never previously read because `gop-dvi-dump.py:52` omitted `+ DIG*0x100` and printed DIG0 under a DIG1 label.

**⛔ THE CAPTURE-DONGLE PROPOSAL IS PERMANENTLY REJECTED. DO NOT RE-DERIVE IT** — an agent read it in this file and relayed it to the
operator, correctly enraging him. (1) **Prohibited**: nothing that adds a box to the signal path, and no hardware-purchase suggestions. (2)
**Technically void**: agnos has **zero isochronous USB endpoint support** (`grep -riE 'isoch|isoc' kernel/` returns nothing; `xhci_ctx.cyr`
configures interrupt-IN and bulk only) and UVC/UAC both mandate isochronous — **the machine under test cannot enumerate the instrument.**
(3) **Unnecessary**: the operator is a lifetime pro-audio engineer; his ear IS the oracle. **The adjudication problem was never a missing
instrument — it was running burns without a negative control in the same boot.** The answer is no, and it was no the last three times.

# 3 — STANDING IRON HAZARDS

Writes that blank, black or wedge the box. Each has already cost a burn somewhere.

- **⛔ THE APERTURE-POISON HAZARD.** Reading register **`0x5FA5`** returns `0xFFFFFFFF`, **and every read after it for the rest of the boot
    also returns `0xFFFFFFFF`.** Non-fatal, but every later register in that boot is VOID (the next command read `OTG_INTERLACE_CONTROL` as
    garbage and called a progressive pipe "interlaced"). ⇒ **"every offset is one the command demonstrably reads" is TRUE AND NOT SUFFICIENT — a
    dry run over a snapshot says what the bytecode WOULD read, not what is SAFE to touch. Reachability must be established PER-REGISTER on
    iron.** This is what the 206-register wide dump cost.
- **⛔ NO BLIND GPU REGISTER ACCESS — READS OR WRITES, NEVER A RANGE SWEEP.** A blind read-sweep of the OTG/DCCG blocks **LOCKED archaemenid**
    on 2026-07-17. Gated-clock domains hang on READ; wrong PHY writes hang harder. Named, header-verified offsets in known-ungated domains only,
    printed **progressively** so a hang localises to the last console line. The one proven exception is the `0x5Dxx`/`0x5Exx` PHY/RDPCS **read**
    domain — that licenses nothing else. The DMU/DMCUB region hangs on a blind read.
- **⛔ ATOM transmitter `#76` RUN LIVE BLANKS THE GOP PIPE NON-RECOVERABLY.** It power-cycles the PHY (writes `556F`, `5E03`, `5DF0`). **Both
    PHYs are powered at boot, so there is NO "safe" phyid.** It stays behind `ATOM_RUN_TRANSMITTER` (default OFF). It has already blanked this
    display twice. Encoder-only `#4` is display-safe (and exonerated as silent). **`#12` at `pll_id` 20-24 is strictly worse — 22 PHY registers
    to `#76`'s one — and is refused by name.**
- **⛔ DO NOT WRITE abs `0x52`.** Analysis found bit8 is a pipe hold / soft-reset bracket around the WHOLE pipe (`0x110` open / `0x010` close
    in amdgpu's trace); latching it risks blanking the working scanout. It is NOT an audio lever, despite being one of the better-evidenced
    omissions in agnos's program.
- **⛔ `DOMAIN*_PG_CONFIG` sits at offset `0x0080` BASE_IDX 2 and NUMERICALLY COLLIDES with `GPU_R_OTG_PIXEL_RATE_CNTL = 0x80` at BASE_IDX 1.
    Writing with the wrong base POWER-GATES A LIVE PIPE.** Name any new symbol distinctly and assert the base in the comment. (Same class:
    `0x0140`/`0x0141`/`0x0142` are valid ONLY on BASE_IDX 1; on BASE_IDX 2 they are negative offsets.)
- **⛔ Anchor before you write. NEVER write a DERIVED DCN offset on the live pipe.** The `0x607` precedent: the arithmetically-correct pitch
    written to a mislabelled offset **under the OTG lock** produced HUBP underflow → black box → wedge (`0x607` is
    `DCSURF_SURFACE_EARLIEST_INUSE_C`; the real pitch is `0x603`, and the whole HUBP block was wrong because offsets were **DERIVED by counting
    from one anchor** while the audio block was right because each was looked up **BY NAME**). The `0x1275` precedent: a wrong offset that read
    a **plausible 0** (`MPCC_SM_CONTROL`, a real register at a valid address) instead of all-ones. Plausible ≠ correct.
- **⛔ Index every DCN access by `gpu_display_pipe`.** Both D-lane tests wrote `HUBPRET0`/`MPCC0`/`OPTC0` as **bare** offsets — those constants
    name instance 0 — while correctly striding the surface register two lines away. Harmless on a pipe-0 boot, wrong the moment a modeset
    touches another pipe.
- **⛔ `MPCC_ALPHA_BLND_MODE` mode 0 (PER_PIXEL) on the GOP's XRGB scanout, where the X byte is `0x00`, makes the whole screen fully
    transparent = BLACK.** Only mode 2 (GLOBAL_ALPHA) may be used against it.
- **⛔ SILENT-FAILURE ORDERING**: writing `DTO0_MODULE` or `DTO_PHASE` before `DTO0_SOURCE_SEL`/`DTO_SEL` fails **silently** —
    hardware-enforced. No error, no log, just no audio.
- **⛔ NEVER remove the pre-dispatch `ACQUIRE_MEM` invalidate.** Load-bearing twice: stale I$ on a rewritten shader VA, AND stale GL2 when a
    shader reads bytes CP-DMA just wrote MC-direct. **The precedent for removing an "obviously safe" cache op is EIGHT BURNS.**
- **⛔ There is NO GPU-side isolation** — `VM_CONTEXT0` paging is deliberately disabled, so a surplus lane's out-of-bounds store lands
    somewhere REAL in the carveout. Any deliberately-unguarded negative arm must aim at the sacrificial slot (`0x1F0000`), clear of the back
    buffers, the PSP TMR and the compute arena.
- **⛔ Every proof must use a FRESH, never-written slot pre-seeded with a sentinel distinct from both 0 and every expected value.** Re-using a
    slot let a stale GL2 line FALSE-PASS a burn.
- **⛔ A dispatch that "completes" proves nothing, and neither does the done marker.** Every oracle needs a lane/workgroup witness separating
    "no store landed" from "stored the wrong value".
- **⛔ There is NO scratch ring**, and **`RSRC1` IS HARVESTED MECHANICALLY — NEVER HAND-COUNTED.**
    `llvm-objcopy -O binary --only-section=.rodata <obj>`, then read **byte 48** (`RSRC1`) and **byte 52** (`RSRC2`). Verified by assembling
    probe descriptors and reproducing three shipped constants exactly: 56/22 → `0x002C00CD` (`RSRC1_EDGE`) · 48/64 → `RSRC1_TEXBI` ·
    32/48 → `RSRC1_TRI`.
    **The granting rule no hand count contains:** `granted_sgpr = roundup8(next_free_sgpr + 6)`, where **+6 = VCC(2) + XNACK(4)** — gfx90c
    is an APU, so the triple reserves XNACK.
    **⛔ DEMONSTRATED, not hypothetical.** A hand-derivation of `edge_cov`'s `RSRC1` gave `0x002C008D` (SGPR field 2 = 24 granted) against
    the real `0x002C00CD` (field 3 = 32) — exactly 22 + 2, a count that remembered VCC and had no way to know about XNACK. Not an
    arithmetic slip; a rule a hand count cannot hold. **Under-granting the SGPR file corrupts the VCC carry chain in the address arithmetic
    and lanes write the WRONG PIXELS — a plausible wrong picture, no fault, and NO ORACLE FIRES.** There is no oracle for OVER-declaration
    either. A 48-VGPR kernel under a 32-VGPR declaration likewise does not fault, it aliases high VGPRs — so the slot and the descriptor
    must be selected from ONE flag.
- **⛔ A negative control is vacuous unless its corpus can FAIL it.** "All of N1-N8 fired" is not the claim that matters; these two floors are:
    **N3** needs ≥3 cases with ≥1000 non-zero reference bytes, because "fully outside" and "zero-area" both have all-zero correct answers —
    a **dead shader that writes only zeroes passes them byte-exactly**. **N4** needs ≥1 reference byte strictly between 0 and 255, or a
    binary non-antialiased rasteriser passes the whole axis-aligned subset. These floors are the burn-preventing half of the control set.
- **⛔ A test whose oracle is a human looking at the screen must NEVER be a boot self-test** — boot cannot ask a human anything, and a blank
    from a ring-3 tool costs a **power-button hold** where a boot self-test costs a **reflash**. Five D-lane flashes would have been one. **No
    modeset write runs from boot.**
- **⛔ A new `#ifdef` mode-flag needs its `build.sh` define line, verified by `cmp` PLUS a `verify_marker` row naming a string INSIDE the
    flag's own `#ifdef` PLUS the NEGATIVE check that the string is ABSENT from a bare build.** `ATOM_DRY` was a **silent no-op for TWO burns** —
    the flag existed in `burn-prep.sh` with no `build.sh` define, so "DRY" built byte-identical to LIVE, drove the PHY and blacked the display
    **twice**. ⚠ Still live: `burn-prep.sh` has no row for `ATOM_RUN_TRANSMITTER`, `ATOM_TRACE` or `ATOM_HALT` — the transmitter flag being the
    one where absence-when-expected and presence-when-unexpected are **both** destructive.
- **⛔ Cyrius `var X[N]` units differ by scope** — module-global = N×u64, function-local = N bytes. This has reached iron twice;
    `check-array-sizing.sh` was green on one of them because it only sees stores written directly to the named array, not an array passed BY
    ADDRESS to a function that writes it.
- **⛔ Cyrius WARNS rather than errors on arity.** The 1.56.3 coverage proof is VOID: both call sites passed 11 args to a 12-parameter
    dispatcher, so `RSRC1` was whatever `gx` happened to be and `done_phys` was undefined — making the function's first statement a **wild
    kernel store**. Same class: N15 called a 4-argument function with three, and because it compares the reference against itself, **both halves
    were equally wrong and the control PASSED VACUOUSLY through every burn to date**.
- **⛔ `gpu_ring_put` never wrapped** — it appended at `gpu_arena_phys + (wptr << 2)` with a monotonic unmasked cursor. The PQ is 64 KB, so a
    repeatedly-called ring producer walks off the end and scribbles the rptr-report and EOP slots that follow the ring in the arena.
- **⛔ A ring-3 divide by zero HARD-LOCKED the kernel** — vector 0 (#DE) was among the deliberately-not-installed set, so the bare-`iretq`
    default returned straight to the faulting `idiv` forever with interrupts enabled. Vector 0 now joins both the installed set and the ring-3
    kill set; mutation-calibrated.
- **⛔ RECOVERY IS WORSE THAN THE HANG.** R-2 (dequeue + re-map) and R-3 (MEC halt/un-halt) **never cleared `CP_HQD_ACTIVE`**, and after the
    ladder ran the ARM-C negative control (integer matmul, previously bit-correct) FAILED. **R-4 — `gpu_wedged=1`, GPU syscalls refuse, console
    survives on the CPU blit path — must be the DEFAULT on any ambiguity.** ⭐ The console and shell DO remain alive on a dead GPU: the operator
    kept typing and `klug` wrote the file with `gpu_wedged=1 recover_rung=4`. agnos can DETECT a GPU hang and SURVIVE it; it CANNOT CLEAR one. ⚠
    "Recovery corrupts the GPU" remains **UNTESTED** — see §2.1.
- **⛔ Do not over-read a single amdgpu snapshot.** `HDMI_CONTROL` bit3 differs between two **audibly playing** captures (0716 vs 0720), so it
    cannot gate audio.
- **⛔ The operator's ear is the ONLY egress oracle — permanently, not provisionally** (HDMI is transmit-only; there is no on-die wire
    observer). It is confounded by sink-latched state. **The fix for an un-adjudicable burn is a NEGATIVE CONTROL IN THE SAME BOOT, not a better
    instrument.**
- **⛔ WebFetch GARBLES HEX.** The offset audit used raw `curl` for the canonical headers for exactly this reason.

# 4 — WHAT IS OPEN

Remaining work only. Nothing that has shipped appears here.

| Cut | Deliverable | Burns |
|---|---|---|
| **1.56.33** ▶ | **MODESET — the COLD case, item 7's true residual.** Lighting a pipe the firmware never lit. **DONE, zero burns:** the `phyid` gate restated as *derived from silicon, not equal to a number*; the watchdog's restore widened **6 → 20 of 20** registers (it had restored 6 of what its own save captured — sound for every shipped rung, and **exactly wrong for a cold path because the missing fourteen ARE the raster program**); and `mode_raster.cyr` reproducing 10 of 14 registers bit-for-bit from published CVT-RB. **REMAINING: cold OTG bring-up inside the widened watchdog**, carrying `VSTARTUP`/`VUPDATE`/`VREADY`/`VTG0` from the inherited snapshot (no mode description yields them), with `mdo_wait_frame_stop`'s oracle **INVERTED** — the counter must *start*, and there is no prior count to compare. ⛔ Its TARGET must be **pipe 1** (dark, `OTG1_CONTROL 0x80000300`), never the live console. ⛔ **The PLL instance is still underived and `#12` did not close it** — `pll_id` 3-19 are byte-identical on the snapshot. Next candidates: the VBIOS object/PLL-assignment data tables, or amdgpu's `dc` PLL-selection logic. **NOT another sweep of the same command.** | 1-2 |
| **1.56.34** ⏸ | **HDMI AUDIO — PARKED BY OPERATOR DECISION 2026-07-31. Do not re-open without an explicit ask.** State on parking: the CRC is calibrated, samples demonstrably reach the encoder output, the fault is **downstream of the AFMT output tap**, and **the sink rejects agnos's HDMI signalling outright** (`DIG_MODE`3 = no signal, `DIG_MODE`2 = relights). Surviving candidates: **(b) a write that does not latch** · **(c) the bare-metal environment** · **(a) sequencing, RE-OPENED** now that M9 is retracted as a null experiment. ⛔ **Do NOT resume with another register sweep — that class is exhausted.** Any resumption carries the four-flag set, a negative control in the same boot, and the blinded band protocol. It also carries the imitation-edge removal: a hand-rolled `DIG_ENABLE` drop + 120 ms hold + AVMUTE cycle still runs in a DEFAULT build for a hypothesis the record killed — but the enclosing block also holds the AVMUTE unmute and the FIFO drain arming, so it is a restructure, not a deletion. | 2-4 |
| **1.56.35** | **The measured invalidate hoist.** S12 showed the batched frame is ~87% fixed cost — six per-dispatch whole-L2 invalidates, not the fence. Hoist ONE to the head of an all-shader batch. Needs its own oracle; the precedent for removing an "obviously safe" cache op is eight burns. Last because it is pure perf and the most expensive per unit of value. | 1-2 |
| **1.56.36** ▶ | **NATIVE RESOLUTION — `MDO_OP_NATIVE` (#93 op `0x0B`). BUILT, awaiting its first burn (§2.2b).** Retargets HUBP0 from the firmware's upscaled 800×600 surface to the full-size one gnoboot 0.6.1's GOP `SetMode` already obtained, with `DSCL_MODE` → bypass, inside `mdo_recommit`'s envelope and its own rollback. All inputs measured; the last open question (the absent `0x60A`) closed as a **dump artifact** — `gpu_scanout_regdump` skips zeros and the surface sits at MC `0xF4_00000000`, so the low half really is 0. **REMAINING: one iron burn, run BEFORE the desktop starts** (a live compositor cached the old geometry and would draw small in the corner — a false negative). ⛔ The expected failure mode is a **HUBP underflow from untouched DLG/TTU deadlines**, not a geometry error: if the panel is corrupt or black while the frame counter advances, the next bite is **cloning HUBP0's DLG group**, not re-litigating the registers. | 1 |
| **1.56.36** ▶ | **CONSOLE HARDWARE PAN — `MDO_OP_PAN` (#93 op `0x0C`). BUILT, awaiting its first burn.** The native burn succeeded and made the console slower, by arithmetic: `fb_scroll_up` flushes `pitch × height` per scrolled LINE, which went from ~2.0 MB at 800×600 to **~14.7 MB of WC stores** at 2560×1440. The pan moves the console into a double-height agnos-owned VRAM buffer (`GPU_FB_PAN_OFF`, 512 MB into the carveout — **its own region**, never the A/B back buffers, so console panning and full-screen page flips cannot contend for the address register) and scrolls by writing `DCSURF_PRIMARY_SURFACE_ADDRESS` one text row down: **one register write + 160 KB** per line, one full-frame reset per **90** lines, ~30× less traffic. ⭐ **No latch, and no new mechanism** — a live surface-address write with no OTG envelope is exactly what `gpu_blit_present` does every frame for DOOM. ⚠ Found and closed pre-burn: `gpu_display_restore_console` handed the scanout back to the FIRMWARE surface, which with the pan armed would leave the console painting into the pan buffer while the hardware scanned elsewhere — an **invisible console** the moment the operator quit the desktop. **REMAINING: one iron burn; the oracle is scrolling text, not the exit code.** | 1 |
| **deferred** | **Second monitor / DCN second plane** — ratified as a real MUDRA/SHANTA requirement, opens after the cold modeset. Scope: DOMAIN2/DOMAIN3 power-ungate with PGFSM status wait → DPPCLK1 DTO + DPP clock enable → HUBP1 clock + VTG bind → ~25 DML-computed DLG/TTU/RQ deadline registers (**tractable only by cloning HUBP0's live values verbatim** — same OTG, same timing, same format, viewport ≤ HUBP0's) → surface config → DSCL bypass + RECOUT → MPCC1 insert → `MPC_OUT0_MUX` retarget, all under the OTG lock. ~50-70 register writes, 4-6 iron bites. ⚠ Renoir gives exactly **4 blendable planes** (bounded by `num_timing_generator = 4`, not the 6 MPCC instances) and they are the same 4 a second monitor wants, so MPC blending is a fast path for a few large surfaces, never a substitute for the shader path. ⚠ A second full-screen 32bpp plane at 2560×1440@60 roughly DOUBLES scanout bandwidth against `DCHUBBUB_ARB_*` watermarks the GOP sized for ONE plane; mitigation is a window-sized `RECOUT`. | — |
| **next** | ⭐ **THE INITIAL SCANOUT — the boot console's first ~87 lines (operator-requested 2026-08-03).** The banding covers boot lines 1..~87 for one reason: agnos paints from line 1 at **boot_info's** geometry (2560x1440, pitch 10240) while DCN is still scanning the firmware's **800x600 pitch-832** surface and upscaling it, so 2560-wide rows are read as 832-px rows and smear. At ~line 88 the register aperture maps, `gpu_scanout_matchgeom` overrides to 800x600 and clears, and everything after is legible. ⛔ **The old note in the `deferred` row below is now STALE** — it framed this as "cannot read the real geometry yet" and offered (1) an early PCI-find or (2) a gnoboot pre-EBS read. Both are still possible, but a third option opened when `MDO_OP_NATIVE` went iron-green: **do the native modeset at boot, right after the aperture maps, and defer FB painting until then**, replaying the klug ring (which already holds every early line) so nothing is visually lost. That makes boot_info TRUE rather than working around its being false, and it **retires `gpu_scanout_matchgeom`'s override entirely**. ⚠ It is a boot-time modeset, so it must sit behind the `/.modeset-armed` latch — the constraint "no boot-time native modeset until the op has succeeded on iron at least once" (§2.2b) is now SATISFIED (three burns), but the latch is what keeps a bad one from looping. | 2-3 |
| **deferred** | **Hardware cursor** — `CUR0_MODE` = 2/3, 32bpp ARGB per-pixel alpha up to 256×256, through the same MPCC path with **no second HUBP/DPP and no DLG/TTU work**. Optional polish; a software cursor works. · **SDMA ring-up** (parked with a known resume state, §2.2). · **Native-resolution console** — the residual banding is the ~84 boot lines agnos paints BEFORE the register aperture maps at ~log-line 85, so it cannot read the real geometry yet; fix options by risk are (1) PCI-find the GPU and read viewport `0x5EA` before `fb_console_init`, or (2) gnoboot reads the DCN viewport pre-EBS and writes real geometry into boot_info. | — |
| **open bite** | **Caller-named colour destination** — the one thing a *non-contending* windowed GPU client actually needs (§1.3). A windowed client is NOT kernel-blocked today; what is blocked is drawing without sharing the compositor's mid-frame back buffer. Zero shader change — `gpu_blend_cov_run` already passes `dst_mc`/`dst_pitch` as kernargs, and `gpu_tri_depth` already resolves a ring-3-named handle. The real cost is field placement plus an ownership model for the 8 RT handles. **Not scheduled against the rows above; it competes with none of them.** | — |
| **follow-on** | **Surface the GPU in `iam`/`mihi`** at arc close — agnos drives the iGPU natively, so `iam` should show `GPU: AMD …`. Two parts: fix `ai-hwaccel/src/detect/platform.cyr:41`'s hardcoded Linux `syscall(89)` readlink → agnos `sys_readlink` **#70** (4-arg) — this is the `mirshi: ENOSYS agnos#89` bug, and it must be fixed in the dep repo, **never band-aided in mirshi** — then a sovereign GPU-identity path (caps `#89`/`#93` report geometry, not identity) → mihi → iam. Cross-repo consumer task, not a kernel blocker. | — |

## How to work

1. **This file is THE single GPU document.** Live state: agnos `docs/development/state.md`. Per-burn CONFIRM/FALSIFY tracker: agnosticos
     `docs/development/iron-nuc-zen-log.md`. Per-burn measurement: agnosticos `docs/development/prior-art/`.
2. **Every bite gets a CONFIRM/FALSIFY rubric in the tracker BEFORE the operator flashes**, and it must **state the two pictures in writing:
     "if X is true the screen/number shows ___, if false ___." If they are the same, redesign.** Engineer the negative outcome to name its own
     cause — the `#90`/`#91` walk was 84→76→51→95→95, each burn decisive. One item per burn.
3. **One boot with COMPETING ARMS beats one hypothesis per burn** — it eliminates sink drift, build variation and the version boundary at once.
4. **⚠ Do not use `gpu.cyr` line numbers — `grep -n '^fn <name>(' kernel/core/gpu.cyr`.** The previous citation list here was **~3,300 lines
     stale** while its own warning said "~60", which is the worse failure: a reader who trusts "~60" scrolls a screen, finds unrelated code, and
     concludes the map is imprecise rather than useless. `atom.cyr` anchors are exact.
5. **Verify at the source. Where this document and the kernel disagree, the kernel is right** and the doc gets fixed in the same change. The
     two cleanest wins in the arc came from reading code first: `f64v_fmadd` = SSE2 `mulpd+addpd` (unfused ⇒ f64 GPU == CPU bit-exact) and
     `#82`'s MAC = `v_mul_lo_u32` + `v_add_u32` (two's-complement ⇒ signed integers work). Both would have been wrong guesses.
6. **Build/flash (all Claude's; the operator only flashes):** `scripts/burn/burn-prep.sh` → `scripts/burn/burn-verify.sh` → operator runs
     `install-media.sh --update` (kernel, ESP-only) / `--update-fs` (`/bin` only) / **`--update-all`** — required for every burn carrying a
     ring-3 tool, and `--update` has already failed to carry `/bin` twice.
7. **The premise-audit gate**: if one bug has consumed 3+ rounds of stamp-and-bisect without resolving, STOP and grep the docs tree. Triggers:
     a bisector ladder with more entries than the function has lines; each repair narrowing the death WINDOW without changing the death STAGE;
     instrumentation that follows from no hypothesis.
8. **The operator owns ALL git.** Cyrius is hands-off except filing issues under `docs/development/issues/`.
