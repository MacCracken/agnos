# Rung 17 `tri_depth` — build plan (derived 2026-07-28, adversarially verified)

> **Status (2026-07-29)**: **B0–B7 LANDED — zero burns**, `host-gpu-oracles.sh` 8/8 exit 95,
> `check.sh` 21/21, ABI battery **136/136**, `edge-abi-smoke` 18/18, prep selftest **256/256**.
> Next bite is **B8** — `tri_depth.s`, the blob. Its four pins must not be re-opened at transcription
> time, and §3's register map is written down BEFORE any instruction is.
>
> ⛔ **B5 did not land as specified.** It asked for `GPU_OP_SUPPORTED` bit 14 with a `GPO_E_NOTIMPL`
> worker; that advertises a non-working op through `#89`, which 1.56.24 forbids. Resolved with
> `GPU_OP_NOTIMPL_MASK` — see §1.6. ⚠ Also measured there: **`GPU_TRID_Z_MAX` is necessary but not
> sufficient**, because the corner bound binds far below it at any useful rect size.
>
> ⭐ **B4 landed as D10/D11 with in-file falsification.** All three external assertions passed on
> their first run, which is precisely when "the gate is right" and "the gate is inert" look the same;
> `M-D10` (sample at the pixel corner instead of its centre — the rung-15 half-pixel class) moves
> **92 px**, so D10 demonstrably sees the defect it exists for.
> ⛔ **The shader is B8, not "what's left"** — `state.md` briefly said "REMAINING: (2) the shader",
> which collapsed seven bites into one; corrected.
>
> ⚠ **Four numbers in this document did not survive being measured**, all in the same direction —
> a frame or a bound that names a property and cannot witness it. Each is corrected inline where it
> appears: the PRECISION span (§6.3.1, sensitivity is **not monotone** — span 1 flips zero), the
> OFF-ORIGIN parameters (§6.3.3, x=700 leaves `|KC|` **inside** an i32), the QUAD gate's number
> (§6.3.2, `D3` collides with the shipped determinism gate), and the residue magnitude argument
> (§4.2, `KX` **always** fits under the corner bound; the `dstxy` fold cancels position exactly).
>
> B0/B3 also found four defects this document did not predict: `depthmodel` evaluated `zn` **only
> inside the triangle** while the shader is predicated and evaluates every lane; A4 bounded the
> numerator against **2^32-1 rather than 2^31-1**, so a value that sign-restores negative would have
> passed A4 while failing the compare it feeds; the winding normalisation §2.5 asks for is **dead
> code on every frame in the tree** (both corpus triangles wind positive, areas 2688 and 2704); and
> the `v_max_i32` clamp is **unwitnessable by output diffing** by construction, so it needs a fire
> counter rather than a mutation.
>
> Produced by a 4-lens investigation + 3 adversarial attackers over the shipped tree. ⚠ Numbers
> attributed to agents are **not** independently verified unless marked MEASURED-BY-MAINTAINER below.
>
> ⛔⛔ **THE HEADLINE: four seams were decided twice, oppositely — and THREE OF THE FOUR WRONG PICKS
> PASS THE RUNG'S OWN ORACLE.** That is the same shape as rung 15's half-texel offset and rung 6's
> checks 1-6: a gate that agrees with itself. Read section 0 before writing a line.
>
> **MEASURED BY MAINTAINER** (`depthmodel` M2c, in-tree and reproducible): a **one-ULP** z error on
> one triangle moves order-independence by **1 px out of 507** while moving the direct
> reference-diff by **217**. ⇒ order-independence is a ~200x less sensitive detector of divide error
> than the reference comparison, and on iron z is not readable at all. **The divide needs its own
> gate.** An agent claimed the stronger result (orderdiff exactly 0 for a dropped correction); that
> specific number was NOT reproduced here and should be re-measured before being relied on.

---

# RUNG 17 — `tri_depth` BUILD PLAN

Kernel 1.56.30 · target gfx90c / archaemenid · build flag `GPU_OP_TRI_DEPTH`

**Four seams were decided twice, oppositely, across the investigations. Each is pinned below with one answer. Do not re-open them at transcription time — three of the four wrong picks pass the rung's own oracle.**

---

## 0. THE FOUR PINS (read these first)

| Seam | PINNED | Wrong pick's symptom |
|---|---|---|
| **Depth compare** | **UNSIGNED `v_cmp_lt_u32`.** z is provably in `[0, 2^24-1]`; validator requires `zclear >= 2^24`. Far value stays `0xFFFFFFFF` — what `gpudepth.cyr:77` already burns. | `v_cmp_lt_i32` + `0xFFFFFFFF` = `-1` = nearest ⇒ nothing ever draws ⇒ both orders byte-identical ⇒ **oracle GREEN on a blank frame.** |
| **Loop shape** | **UNBINNED.** TD-5 (`gpu.md:1031`) says *"no atomics, NO BINNING PASS"*. Every tile walks the whole contiguous 64-byte prep array. No `TILE_SUBOFF`, no `PAIRS_SUBOFF`, no kernel binner. A `GPO_E_WORK` cap makes the cost bounded. | A kernel binner + a contiguous-walking shader = triangles in tiles they do not touch ⇒ reads as a rung-16 binning defect or as order-dependence ⇒ **TD-5 escalation for a 3-line prep bug.** |
| **Bounds guard** | **NONE. `exec` stays `-1` for the whole kernel.** Validator requires `w % 8 == 0 && h % 8 == 0 && dx % 8 == 0 && dy % 8 == 0` (`GPO_E_ALIGN`). | inv-3's prologue guard makes every edge tile show witness dropouts — byte-identical to the S1 per-lane-dropout signature the witness exists to detect. Without either, the last tile row stores past the back buffer, and `VM_CONTEXT0` is disabled so that write lands somewhere real. |
| **Composition** | **REPLACE, not composite.** `0x0E` initialises colour to `bg` and z to `zclear` in VGPRs and stores unconditionally. It **erases** its `wh` rect. It never reads the render target or the z buffer. | Calling it "composites, exactly as `0x0A` does" ⇒ first iron frame shows the depth draw wiping the 2D draw ⇒ read as a store-address bug. And reading z at tile entry is the CP-DMA(MC-direct)→GL2 stale-line transition plan-S3 arm D measured 4096-of-4096. |

Two consequences worth stating: **`0x0D` is NOT a prerequisite of `0x0E`** (the shader clears in-register), and **N `0x0E` records cannot share one z buffer in v1**. Say both in the ABI comment.

---

## 1. ABI

### 1.1 New op, not a flag

`var GPU_OP_TRI_DEPTH = 0x0E;`

Decisive argument, and it is the only one that needs stating: **`gpo_field_mask` takes only `op`** (`syscall.cyr:1310`). Op `0x0A`'s dword 2 must be zero; `0x0E` needs an RT handle there, where `0` is *legal*. Under a flag, a dword's legality becomes flags-dependent, which forces `gpo_field_mask(op, flags)` and rewrites the generic reserved-dword loop in `gpo_validate` for **every op in the file** — to add one. Same argument one level down for the per-triangle `+36/+40/+44`.

Blob is new and mandatory (`tri_depth.s`), never an edit to `tri.s`/`edge_cov.s`/`tex*.s`. Unanimous rung-14b/15 precedent.

### 1.2 `#92` record — `gpo_field_mask(GPU_OP_TRI_DEPTH) = 0x01FF`

```
dw  byte  field        note
 0   +0   op           = 0x0E
 1   +4   flags        gpo_flags_known -> 0
 2   +8   z_handle     RT handle 0..GPU_RT_HANDLES-1   (same dword as 0x0D)
 3  +12   vtx_id       #86 slot, per-triangle records  (same dword as 0x0A)
 4  +16   wh           h<<16|w   — DRAW rect, both multiples of 8
 5  +20   dstxy        dy<<16|dx — both multiples of 8
 6  +24   n_tris       (same dword as 0x0A)
 7  +28   zwh          zh<<16|zw — DEPTH extent (same dword as 0x0B's texwh)
 8  +32   witness_id   #86 slot for the lane witness; 0 = no witness
 9..15    RESERVED, must be zero
```

`witness_id` is a **first-class, always-accepted ABI field**, not a build-flag or a debug bit. A `#ifdef`-gated flag would make `#89`'s advertised surface build-dependent, i.e. would make the mask a lie for a production kernel. Precedent for a shader writing into a ring-3-named slot is op `0x09` (`edge_cov`'s destination mask slot, `GPO_E_DSTSLOT`), resolved with the existing `gpu_shm_mc(id)` (`syscall.cyr:1376`).

Depth is **screen-indexed**: `z_index = y*zw + x`. `dstxy` is folded CPU-side (§4.2), so the shader never sees it.

### 1.3 Per-triangle record in `vtx_id` — `GPU_TRID_VTX_BYTES = 48`

```
+0   vx0 vy0 vx1 vy1 vx2 vy2   i32 16.16 screen, LOW 16 BITS MUST BE ZERO
+24  z0 z1 z2                  u32, 0 <= z_i <= GPU_TRID_Z_MAX (2^24-1)
+36  colour                    u32 premultiplied ARGB — ONE colour, FLAT
+40  reserved x2               MUST be zero
```

Flat, because `depthcore.cyr`'s `dc_get(t,9)` is flat and the accepted surface must equal the proven surface. Gouraud is a rung-18 flag with its own blob and its own stride constant.

### 1.4 `gpo_validate_tridepth(rec, fbw, fbh)`

Dispatch from `gpo_validate` **before** the generic tail, alongside `0x08`/`0x0D` — the tail would bounds-check a depth buffer against the screen. Do **not** add `0x0E` to `gpo_slot_field`/`gpo_slot_bytes` (return 0/absent, same as `0x0A`).

**Header**
1. `flags != 0` → `GPO_E_RESERVED`
2. `zh >= GPU_RT_HANDLES` → `GPO_E_BADSLOT` (verbatim `gpo_validate_depthclear:2860`)
3. `w<1 || h<1 || zw<1 || zh_ext<1` → `GPO_E_DIM`
4. **`(w|h|dx|dy) & 7 != 0` → `GPO_E_ALIGN`** ⭐ this is what keeps `exec == -1`
5. `dx+w > fbw || dy+h > fbh` → `GPO_E_BOUNDS`
6. `dx+w > zw || dy+h > zh_ext` → `GPO_E_BOUNDS`
7. **`zw * 4 * zh_ext > GPU_RT_HANDLE_SIZE` → `GPO_E_SLOTSIZE`** — ⚠ bound against **one 32 MB handle**, never the 256 MB region. `4096*2048*4` is a handle exactly; `4096*2049` overruns into the *next* handle and the corruption surfaces in an unrelated buffer. Same `*4` as `gpu_depth_clear`: two sites, one fact.
8. **`(w>>3) * (h>>3) * nt > GPU_TRID_WORK_MAX` → `GPO_E_WORK`** — the unit is tile·triangle, not pixels. `gpo_validate_trilist`'s `w*h*nt*3` bound is meaningless here.
9. `witness_id != 0` ⇒ `shm_slot_valid` && `shm_mc != 0` (PMM-backed is unreachable by the GPU) && `shm_size >= (w>>3)*(h>>3)*64*8` → else `GPO_E_DSTSLOT`
10. **`zclear` is not in this record** — the shader's far value comes from the header the kernel builds. The *rule* it must satisfy (`>= 2^24`) is a prep assertion, §4.2.

**Triangle list**
11. `nt < 1 || nt > GPU_TRID_LIST_MAX (256)` → `GPO_E_TRILIST`
12. `shm_slot_valid(vid)==0` / `shm_kva==0` / `shm_size < nt*48` → `GPO_E_TRILIST` (`shm_kva`, not `shm_mc` — the *kernel* reads these to build prep; the GPU never touches the slot)

**Per triangle, EVERY one before ANY is drawn** (`gpo_validate_trilist:1398`'s stated rule)

13. `+40` **and `+44`** non-zero → `GPO_E_TRILIST`. ⚠ Probe the **far** dword. Rung 14's `+92` case exists because `+72` was the only one ever tested.
14. `gpo_coord_bad()` on all 6 coords → `GPO_E_COORD`
15. **`(coord & 0xFFFF) != 0` → `GPO_E_SUBPIXEL`** — `depthcore`/`depthmodel` prove the arithmetic in the doubled-**integer** domain only. Accepting arbitrary 16.16 and quantising kernel-side is accept-and-silently-do-something-else. Same doctrine as `WRAP`'s power-of-two reject.
16. `cross`/`a2` bounds → `GPO_E_AREA`, arithmetic identical to `gpo_validate_trilist:1708-1712`. ⚠ `GPU_TRI_AREA_MIN` is what forbids `cross == 0`, and it is therefore the only thing between a ring-3 record and a **kernel `#DE`** on `R = 2^32/area` in prep. Say so in the comment.
17. `z_i > GPU_TRID_Z_MAX` → `GPO_E_ZRANGE` (unsigned field, so `< 0` is unrepresentable)
18. ⭐ **THE CORNER BOUND — `GPO_E_ZRANGE`.** Compute, in i64, `w0 w1 w2 zn` at the **four corners of the draw rect** (all four are affine in (x,y), so extremes are at corners). Require every one to satisfy `|v| < 2^31`.

> **Why corners and not the inside bound.** Attacker measurement: a triangle at (700,500), 8×8 px, z ∈ [0, 8000000] passes `coord < 2^28`, `z <= 2^24-1`, **and** `zmax*4*cross = 2.05e9 <= 2^31-1` — yet peak `|zn|` over its own bounding box is **3.264e9**, 1.52× past a 32-bit lane, wrong at 25 of 81 bbox pixels. The shader is **predicated, not branched**, so it evaluates `zn` on every lane of the tile including far outside the triangle. A bound derived over inside pixels is a bound over a domain the shader does not run on. `depthmodel`'s A4 has the same defect: it reports 2,430,400 (inside only) against a whole-frame peak of 4,836,800.

### 1.5 `GPU_OP_RT_READ = 0x10` — **BLOCKING PREREQUISITE, not a nice-to-have**

`gpo_field_mask(0x10) = 0x009F` → `op · flags · z_handle(2) · dst_id(3) · wh(4) · zwh(7)`. `dstxy` rejected (a handle's origin is `(0,0)`).

~15 lines into a validated `#86` slot.

> ⛔⛔ **"NO DMA AND NO DISPATCH — A KERNEL `memcpy` FROM `gpu_rt_base_phys`" WOULD #PF ON THE FIRST BYTE, AND RUNG 6 HAD ALREADY MEASURED WHY.** The region sits at physical `1020000000..1030000000` — about **64.5 GB** — while `pt_init` identity-maps only **0–4 GB** (`paging.cyr:19`); `mbi.cyr:50` records `fb_fb_phys` #PF'ing once for precisely this reason. `gpu_rt_base_phys` is a real address but not a dereferenceable one: it exists for the audit's arithmetic. ⇒ landed as **CP-DMA, MC-to-MC**, which is what `gpu_readback_shm_sys` (`#90`) already does to capture the back buffer into a client slot — with its iron-proven scoped **`clflush` BEFORE** the DMA (after would write a dirty line back over the GPU's fresh data), and no duplicate GL2 flush since `gpu_batch_tail`'s ACQUIRE_MEM TCWB covers the source side. `0x10..0x17` is the lane `gpu.md` already reserved for fill/blit/readback; `0x0F` stays free for rung 19.

**Why it is blocking**, measured by two independent attackers on the shipped corpus: a divide with the correction **dropped** gives orderdiff **0**, colour-vs-reference **0**, and **19 wrong z**. A uniform bias of any size 1..64 gives 0/0/**507-of-507 wrong z**. Without a z readback the iron burn **cannot fail on a broken divide**, and the divide is this rung's entire novel content. `0x0D` could only ever be validated by timing because the RT arena is opaque; rung 17 must not inherit that blindness.

### 1.6 Constants and lockstep sites

New in `syscall.cyr`:
```
GPU_OP_TRI_DEPTH   = 0x0E
GPU_OP_RT_READ     = 0x10
GPU_TRID_VTX_BYTES = 48
GPU_TRID_LIST_MAX  = 256
GPU_TRID_Z_MAX     = 16777215     # 2^24-1
GPU_TRID_ZCLEAR_MIN= 16777216     # 2^24 — every far value must exceed every legal z
GPU_TRID_WORK_MAX  = 1048576      # 2^20 tile-triangle pairs ~= 67M lane-iterations,
                                  #   the same order as GPU_EDGE_WORK_MAX's 2^26 pixel-edges
GPU_TILE           = 8
GPO_E_SUBPIXEL     = 30
GPO_E_ZRANGE       = 31
GPO_E_ALIGN        = 32
```
`GPO_E_` 9, 10 and 14 are gaps whose history is not visible in the file (they *are* live in the separate `MDO_E_` namespace). Take 30/31/32; do not reuse an absence you cannot explain.

⚠ `GPU_TRID_WORK_MAX = 2^20` **caps 800×600 at 13 triangles**. That is deliberate: v1 is a correctness proof at the 32×32 corpus, not a DOOM-scale renderer. Growing it is its own bite with its own watchdog measurement.

**Move in ONE change, or the mask is a lie:**

| site | change |
|---|---|
| `syscall.cyr:1201` `GPU_OP_SUPPORTED` | `0x3F1F` → **`0x7F1F`** at B5 (bit 14 = `0x0E`); bit 16 = `0x10` follows at B6. ⛔ **AND A SECOND WORD**: this constant is now the *validator's* reachability gate only — `gpu_caps +28` reports `GPU_OP_SUPPORTED & ~GPU_OP_NOTIMPL_MASK`, because B5 as written ("bit 14 … worker returns `GPO_E_NOTIMPL`") advertises an op that does not work, which is the 1.56.24 defect and which `syscall.cyr`'s own comment forbids. Leaving `0x0E` out was equally impossible: `gpo_validate` gates on the word at line 1, so no field rule could be tested at all. |
| `gpo_field_mask` | `+ 0x01FF` for `0x0E`, `+ 0x009F` for `0x10` |
| `gpo_flags_known` | `return 0` for both |
| `gpo_validate` dispatch | two lines, above the generic tail |
| `gpo_execute` | `if (gpu_tri_depth(...) != 1) { return GPO_E_ARM; }` — **`GPO_E_ARM`, not `GPO_E_DISPATCH`**, for `0x0D`'s stated reason: the overwhelmingly likely refusal is rung 6's audit not having passed on this boot, which is an arming fact |
| `gpu_caps_sys +28` | no edit (stores `GPU_OP_SUPPORTED`), but it is gated by `shader_ok` — `0x0E` reads absent when the shader path is down. Comment it. |
| ABI battery `syscall.cyr:2843-2845` | `103 → N` in **both** the `kprint_num` guard and the literal; the `" of 103 cases correct\n"` byte length stays 22; **the `"...0x08/0x09/0x0A/0x0B/0x0C ABIs..."` string grows** — recount with `scripts/check/kprint-len-check.sh`, do not hand-count |
| `scripts/smoke/edge-abi-smoke.sh:85,88` | both `chk` strings move with it |
| `gpu_regs.cyr` | new arena suboffsets + `GPU_COMPUTE_PGM_RSRC1_TDEP` |
| `scripts/check/check-arena.sh` | new slots declared, extents non-overlapping |
| `docs/development/planning/gpu.md` §7 | `0x0E` and `0x10` rows **and** the `0x3F1F → 0x17F1F` line |

⭐ **`#89 +32` is already gone.** `gpu.md` §7 says to mint `+32 opmask_hi / +36 rt_slots / +40 rt_slot_bytes` "now, while nothing can break" — but 1.56.26 allocated `+32..+60` to the phase profile (`gpu_prof_copyin_us` … `gpu_prof_nops`). Same collision class as `0x0C`. Re-home to a **new `len >= 96` tail**: `+64 opmask_hi`, `+68 rt_slots`, `+72 rt_slot_bytes`, `+76 tile_size` — and **widen `is_user_range(buf, 96)` in the same edit** as the write. Writing 96 behind a 64-byte check is the identical defect this cycle just fixed in `#82`/`#83`.

### 1.7 Arena

```
GPU_TRID_SHADER_SUBOFF   0x5E000   4 KB    residency slot 13 (next after TEXBI 0x5D000)
GPU_TRID_PREP_SUBOFF     0x1E4000  32 KB   1 header + 256 x 64 B records (16.4 KB used)
                                            starts exactly where GPU_TRI_COV_SUBOFF ends
```
`GPU_ARENA_SIZE` stays 2 MB, so rung 6's `gpu_rt_overlaps` audit and the arena-unaliased gate are unchanged. Leaves `0x5F000..0x60000` and `0x1EC000..0x1F0000` free. ⛔ Do **not** reuse `GPU_TRI_COV_SUBOFF`'s 1 MB even though `0x0E` builds no coverage mask — sharing a fixed arena slot across ops is rung 12's exact failure (`tex_list.s:32-39`).

---

## 2. THE DIVIDE

### 2.1 Reuse from rung 13: **nothing, as code. Doctrine only.**

Rung 13 divides a 96-bit numerator by a funnel-normalised ~2^30 divisor. Rung 17 divides a 32-bit numerator by a 2^2..2^26 divisor. Three concrete non-transferables:

- **Different number.** `tri_prep` keeps vertices in pixels and lifts to 16.16: `A2 = cross << 16`. `depthcore` *doubles* vertices: `area = 4*cross`. **Ratio 16384.** Corpus triangle 1 (`cross = 672`): rung 13 calls it 44,040,192, rung 17 calls it 2688. Reusing rung 13's record divides by 16384× too much.
- **The funnel never fires.** `t = bitlen64(area) - 30` is **identically 0** for every legal rung-17 area (`area <= 2^26` even at 4096²). What survives is `Dh = area + 1` — a divisor biased *up* with nothing normalising it. The transplant is then exact **iff `z_range < area`**. The corpus is 900/2689 = 0.335: it passes **by luck, by a factor of three**.
- **Measured counterexample, fully ABI-legal.** `area = 40` (a 5-px sliver), z spanning 0..65535, `zn = 2,621,400`: true `Q = 65535`, transplant returns **63937**, error **1598**. At the *minimum* legal area (4) the transplant errs by 1,677,721. `recip32` is also a 32-iteration restoring loop existing to compute a 64-bit quotient; rung 17 needs one CPU divide.

Reused as doctrine: `tri_prep`'s sign normalisation; the one-sided-correction shape; predicates-not-branches; write-the-register-map-first.

### 2.2 The recipe — R2

**CPU prep, per triangle:** `R = 4294967296 / area` (`= floor(2^32/area)`). `area = 4*cross` and `cross >= 1` by `GPU_TRI_AREA_MIN`, so `area >= 4` and `R <= 2^30` fits u32.

**Shader, per pixel per triangle — 5 instructions, all 32-bit:**
```
v_mul_hi_u32   v9,  v8, s42        ; q_est = floor(zn*R / 2^32)      s42 = R
v_mul_lo_u32   v10, v9, s41        ; q*area                          s41 = area
v_sub_u32      v10, v8, v10        ; r = zn - q*area
v_cmp_le_u32   vcc, s41, v10       ; r >= area ?
v_addc_co_u32  v9,  vcc, 0, v9, vcc
```
⚠ Operand order `0, v9` (not `v9, 0`) — that is the iron-proven 4-byte VOP2 encoding; the reverse silently promotes to the 8-byte `_e64` VOP3B form.

**Proof, complete, no magnitude assumption.** With `R = floor(2^32/D)`, so `(2^32-D+1)/D <= R <= 2^32/D`, and `x = zn/D`:
- upper: `zn*R/2^32 <= x` ⇒ `q_est <= Q` — **never overshoots**, so the one-sided correction is correct by construction;
- lower: `zn*R/2^32 >= x - zn/2^32 > x - 1` (because `zn < 2^32`) ⇒ `q_est >= Q-1`.

⇒ `q_est ∈ {Q-1, Q}` for every `zn < 2^32`, every `D >= 2`. One correction is exact. **The sole precondition is `zn < 2^32`** — discharged unconditionally by §1.4 rule 18 (corner bound `|zn| < 2^31`) plus the domain clamp below.

Independently swept twice: 151,935 cases over 49 divisors from 4 to 2^28, all `{kD-1, kD, kD+1}` boundaries plus `zn ∈ {0,1,2^32-1}` — **0 mismatches, max pre-correction shortfall exactly 1, correction fired 35,732 times**.

Three structural wins: 5 instructions vs ~20; 3 scratch VGPRs vs ~12 (and there is **no spill oracle**, so that is a risk decision, not a perf one); **both `v_mul_hi_u32` operands are provably non-negative**, so the rung-11 four-burn signed-high-half fixup is *structurally absent* rather than present-and-correct.

### 2.3 The domain clamp — one instruction that deletes a class

```
v_max_i32 v8, 0, v8        ; immediately before the divide
```
Inside the triangle `zn >= 0` (all `w_i >= 0` after winding normalisation, all `z_i >= 0` by ABI), so the clamp is the **identity on every pixel that can affect output**. Outside, it turns a negative `zn` into `0` instead of a huge unsigned value. This makes the R2 precondition hold *unconditionally* rather than under a predicate, and it removes "the result was garbage but it lost the depth test anyway" from the reasoning — the exact shape of the rung-13 `v19` clobber.

### 2.4 ⛔ THE MIN-BIAS IS **DROPPED**

inv-2 proposed `m = min(z_i)`, `zn' = Σ w_i (z_i - m)`, fold back `z = q + m`. Two attacker findings kill it:

- **Vacuous under the ABI.** §1.4 rule 17 forbids `z_i < 0`. With `z_i >= 0` and `w_i >= 0` inside, `zn >= 0` by construction and `trunc == floor` unconditionally. The bias buys only headroom the corner bound already reserves.
- **Unwitnessable.** Both corpus triangles have `min(z_i) = 100`. Dropping the fold-back entirely gives colour diff **0**, orderdiff **0**, and z wrong at **507/507** covered pixels. It would ship with zero coverage on host *or* iron.

Its *sign* payoff is also the thing the clamp does in one instruction. Dropping it removes a prep mechanism, a shader instruction, and a `v_cmp_lt_i32`-vs-`u32` decision.

### 2.5 Winding normalisation — CPU, in prep

`depthcore`/`depthmodel` currently accept `area < 0` and flip the inside test (`depthmodel.cyr:119-124`). Every reciprocal path requires `area > 0`. **Port `tri_prep`'s `sgn`**: when `cross < 0`, negate the three edge planes **and** `KX/KY/KC` **and** `area`. Exact: `trunc(-zn/-area) == trunc(zn/area)`, and with `zn >= 0, area > 0` trunc ≡ floor. This collapses two inside tests into one uniform `w_i >= 0`, deletes a domain case, and costs zero per pixel.

⛔ It changes the program `depthmodel` is proving. Land it **in the same bite** as the model change, or the byte-identity proof covers a different program than the one that flashes (`depthcore.cyr`'s own header makes exactly this argument).

### 2.6 PROOF OBLIGATION and the gate that discharges it

The obligation is the **defining property of the floor, checked by multiplication only, never by a second divide**:

> **`q*area <= zn < (q+1)*area`** for every `(zn, area)` the ABI permits.

This is an external invariant in the `[[feedback_oracle_must_test_external_invariant]]` sense — byte-diffing the modelled divide against `zn / dm_area` is blind to a shared premise, which is precisely what shipped rung 15's half-texel. Host bit widths: `q <= 2^32`, `area <= 2^26`, product `<= 2^58`, comfortable in i64.

**GATE `tests/gpu/depthdiv.cyr`** — green before a line of `tri_depth.s` is transcribed:

1. **Two counters, never one.** Lower-bound violations (`q*area > zn` ⇒ the estimate overshot ⇒ the no-overshoot proof is wrong) and upper-bound violations (`zn >= (q+1)*area` ⇒ one correction was not enough) are **different defects**. Count separately.
2. **PRINT `max(Q - q_est_before_correction)` AND the correction fire count.** If the max is 0 the correction never fires and the gate is decoration (rung 9b's clamp-hit-counter lesson; `tricore.cyr` already carries `tm_corr_fired`/`tm_corr_count`). If it is >= 2 the recipe is refuted. Expected: max = 1, fires > 0. ⚠ On the corpus the correction fires on only **25 of 689 inside-evaluations (3.6 %)** — without the printed count, "the correction is dead code" and "the correction is right" look identical.
3. **Boundary sweep, not a stride.** ~50 divisors spanning `[4, 2^26]` (powers of two ±4, primes, the corpus values), `zn` at `{k*area - 1, k*area, k*area + 1}` plus random fill. One-ULP errors live at the multiples; a uniform stride walks past them.
4. ⭐ **THE ADVERSARIAL FRAME.** `area = 40`, z spanning 0..65535. Run **both** recipes against **both** frames and print the table: `transplant: green on corpus, RED (1598) on adversarial`. That demonstrates in one printed table that the corpus was blind, at zero burns.
5. **Mutations, each required to go red:** MUT-R1 `R = floor(2^32/(D+1))` (the transplant's bias — must be **green on corpus, red on adversarial**; that asymmetry *is* the point) · MUT-R2 drop the correction · MUT-R3 `>=` → `>` (must fail at exact multiples) · MUT-R4 signed instead of unsigned `mul_hi` · MUT-R5 drop the `v_max_i32` clamp with a negative-`zn` input.
6. **Gate D9 — M2 inverted.** Run `dm_orderdiff()` with the *modelled* divide substituted for the exact one, require **0**, and report `dm_ties` alongside.

---

## 3. THE REGISTER MAP

⛔ **Written down first, transcribed second.** Rung 13 lost a burn to a scratch `v_mul_lo_u32` over a live `v19`: the clobber wrote **zero** and read like a dead shader, invisible to llvm-mc, to `shader-blob.sh` **and** to the host model. Here `v3`/`v4` are live across an **unbounded** loop, so every scratch write is a `v19` candidate on **every** iteration — strictly worse exposure than rung 13's single axis.

### 3.1 VGPRs

```
 LIVE ACROSS THE TRIANGLE LOOP — written in the loop ONLY by the two named v_cndmask
 v0   lane id 0..63          HW-written, NEVER written by us; also the witness input   [whole kernel]
 v1   lxq = 2*lx + 1         draw-local doubled sample x                    [prologue -> L_END]
 v2   lyq = 2*ly + 1                                                        [prologue -> L_END]
 v3   zbest  u32             init = s21 zclear                              [prologue -> L_END]
 v4   cbest  u32 ARGB        init = s22 bg                                  [prologue -> L_END]

 LOOP SCRATCH — all provably dead at the bottom of the loop
 v5   w0                     A0*lxq + B0*lyq + C0                           [L_TRI, one iter]
 v6   w1                                                                     [L_TRI, one iter]
 v7   w2 = area - w0 - w1    derived, exact mod 2^32                        [L_TRI, one iter]
 v8   zn, then clamped zn                                                    [L_TRI, one iter]
 v9   q                                                                      [L_TRI, one iter]
 v10  divide temp: q*area, then the remainder r                              [L_TRI, one iter]
 v11  colour in a VGPR       ⚠ REQUIRED, not cosmetic — see 4.3              [L_TRI, one iter]
 v12  mul temp (B*lyq, KY*lyq)                                               [L_TRI, one iter]
 v13  SPARE, unused in v1
 v14  SPARE, unused in v1
 v15  SPARE, unused in v1

 TAIL — after the loop, deliberately NOT aliased onto v5..v12
 v16  lx (draw-local)                                                        [prologue -> L_END]
 v17  ly (draw-local)                                                        [prologue -> L_END]
 v18:v19  colour store address                                               [L_STORE]
 v20:v21  z store address                                                    [L_STORE]
 v22  witness value                                                          [L_STORE]
 v23:v24  witness store address                                              [L_STORE]

 HIGH WATER = v24.  DECLARE .amdhsa_next_free_vgpr 32.  SEVEN spare.
```

⭐ **Do not hand-squeeze this for occupancy — the trade is illusory.** `GPU_MT_NUM_THREAD_X = 64` (`gpu_regs.cyr:1119`) means one workgroup is exactly one wave, and gfx9 caps workgroups-per-CU at 16, so occupancy is 16 waves/CU for **any** VGPR count up to 64. inv-4's "24 gives 10 waves/SIMD against 32's 8" is unreachable in both directions, and `tri_rgba.s:20-22` carries the same error. Declaring 32 costs nothing. Likewise **do not** alias the tail onto dead loop scratch to save registers — that is exactly the aliasing that produced the `v19` clobber.

⚠ **Do not import tex_bilin's occupancy justification** ("a DOOM frame is 4.71 ms CPU vs 0.09 ms GPU"). That was measured on a per-primitive dispatch shape; rung 17 is one dispatch per frame with per-triangle work moved onto the GPU.

### 3.2 SGPRs

```
 KERNARGS (USER_SGPR = 8 — this is load-bearing, see 4.1)
 s0:s1   prep-record base MC, WALKED per iteration     [whole kernel]
 s2:s3   colour destination base MC, PRE-OFFSET to dstxy
 s4      colour pitch, BYTES
 s5      n_tri
 s6      w (draw width, px)     — reserved for a future partial-tile variant
 s7      h (draw height, px)    — ditto

 SYSTEM
 s8  tgid_x (tile column)     s9  tgid_y (tile row)

 HEADER, loaded once in the prologue by 2 x s_load_dwordx4 from s[0:1] + 0
 s16:s17 z base MC, PRE-OFFSET to dstxy
 s18:s19 witness base MC (0 = witness disabled)
 s20     z pitch, BYTES
 s21     zclear   (>= 2^24, asserted in prep)
 s22     bg
 s23     tiles_x

 DERIVED / SCRATCH
 s10 tile origin x (px)   s11 tile origin y (px)   s12 loop counter t
 s13 s14 s15  SALU scratch (tile index, witness index)
 s24:s25  THE UPDATE PREDICATE                                    [inside L_TRI, one iter]
 s26:s27  predicate scratch pair                                  [inside L_TRI, one iter]
 s28:s31  SPARE

 PER-TRIANGLE RECORD — 4 x s_load_dwordx4, imm offsets 0x0/0x10/0x20/0x30
 s32 A0   s33 B0   s34 C0   s35 A1
 s36 B1   s37 C1   s38 KX   s39 KY
 s40 KC   s41 area s42 R    s43 colour
 s44..s47  RESERVED, must be zero in the record

 HIGH WATER = s47.  DECLARE .amdhsa_next_free_sgpr 48.
```

⭐ **SGPR over-allocation is free on gfx9** (occupancy is VGPR-bound). Push everything wave-uniform into SGPRs; that is the single biggest lever in the whole budget.

⛔ **The predicate must live in a named, even-aligned pair — NOT `vcc`.** The R2 correction writes `vcc` between the edge tests and the update. `s[23:24]` is rejected by the assembler ("invalid register alignment"); use `s[24:25]`. Every straight-line shader in the tree computes its predicate *after* its carry chains and so has never had this hazard. inv-4's "no 64-bit intermediates ⇒ vcc is free" is **false** for this reason.

### 3.3 RSRC — harvested, never hand-counted

`.amdhsa_next_free_vgpr 32` + `.amdhsa_next_free_sgpr 48` + `.amdhsa_ieee_mode 0` (pure-integer kernel, matching `tri_rgba`/`edge_cov`) predicts:

```
RSRC1 = 0x002C0187      RSRC2 = 0x00000190
```

Verified twice by assembling probe descriptors and reading `.rodata` bytes 48/52, reproducing three shipped constants exactly (56/22 → `0x002C00CD` = `RSRC1_EDGE`; 48/64 → TEXBI's fields; 32/48 → `RSRC1_TRI`).

**The granting rule is `granted_sgpr = roundup8(next_free_sgpr + E)`, and for agnos's configuration `E = 6`.** ⛔ This line read "the +6 is VCC(2) + XNACK(4) — gfx90c is an APU and the triple reserves XNACK" until 1.56.44; that cause is **measured wrong**. llvm-mc 22.1.8, solving `E` over `next_free_sgpr = 1..39` on gfx90c: defaults `E=6`; `.amdhsa_reserve_xnack_mask 0` alone `E=6` (**unchanged**); `.amdhsa_reserve_flat_scratch 0` alone `E=4`; both waived `E=2`. XNACK contributes 2, not 4, and is invisible while flat scratch is reserved. The dominating term is FLAT_SCRATCH, which no agnos kernel uses. `edge_cov`'s documented hand-miscount (`0x002C008D`, 24 granted vs the assembler's 32) is exactly `22 + 2`: a count that remembered VCC and had no way to know about XNACK. It is not an arithmetic slip; it is a rule no hand count contains. Under-allocating the SGPR file corrupts the `vcc` carry chain in the address arithmetic and lanes write the **wrong pixels** — "a plausible wrong picture, not a fault".

⛔ **Mint `GPU_COMPUTE_PGM_RSRC1_TDEP` as its own constant** even though `0x002C0187` collides byte-for-byte with `GPU_COMPUTE_PGM_RSRC1_TRI`. Sharing the name couples two kernels' occupancy — the `RSRC1_TEXBI`-vs-`RSRC1_TEX` precedent.

`RSRC2 = 0x190` is byte-identical to `GPU_COMPUTE_RSRC2_COV`, which is what lets `gpu_blend_cov_run` dispatch `tri_depth` **unmodified**. That is why the z and witness bases travel in the record header instead of becoming kernargs 9 and 10.

---

## 4. THE SHADER

### 4.1 Kernarg mapping onto `gpu_blend_cov_run` (unmodified)

`gpu.cyr:3285-3288` emits exactly 8 USER_DATA dwords: `mask_mc lo/hi · dst_mc lo/hi · mask_pitch · dst_pitch · width · color`. Map:

```
mask_mc lo/hi -> prep base       dst_mc lo/hi -> colour base
mask_pitch    -> n_tri           dst_pitch    -> colour pitch bytes
width         -> w               color        -> h
```
Grid: `gx = w>>3`, `gy = h>>3`.

### 4.2 What prep does on the CPU (so the shader does not)

Per record: build the 64-byte header. Per triangle:
1. **double** the integer vertices, compute the three edge planes and `area = Σ C_i`;
2. **normalise winding** — negate all three planes, `KX/KY/KC` and `area` when `cross < 0`;
3. **fold `dstxy` into the constant terms**: substituting `pxq = 2*lx + 1 + 2*dx` gives `C' = C + 2*dx*A + 2*dy*B` (same for `KC'`). **The shader then works entirely in draw-local coordinates and never sees `dstxy`.** Colour and z bases are pre-offset by `dy*pitch + dx*4`.
4. `R = 4294967296 / area`;
5. corner bound (§1.4 rule 18) in i64 — **reject, never wrap**;
6. assert `zclear >= GPU_TRID_ZCLEAR_MIN`;
7. store `A/B/C`, `KX/KY/KC` as **mod-2^32 residues**.

⚠ **The residues are deliberate and must be documented as such.** Storing residues is exact because mod-2^32 is a ring homomorphism *and* the corner bound guarantees the **result** fits a 32-bit lane. Without the comment, a later "fix" that validates `|KC| < 2^31` will refuse legal triangles.

> ⛔ **THE MAGNITUDE ARGUMENT HERE IS WRONG, MEASURED AT B3, AND IT MATTERS BECAUSE IT NAMES THE WRONG TERM.** This paragraph said "`KX = Σ A_i z_i` reaches ~2^39 at legal inputs". That is the bound with *nothing else assumed* — but two things are assumed. **(1) The `dstxy` fold makes the record DRAW-LOCAL, and it cancels position exactly**: measured, the off-origin frame's `KC` is `-3,326,848,000` before the fold and `+1,152,000` after — precisely the origin corpus's `KC` scaled by z, because the fold adds `2·dx·KX` and the vertex translation subtracted it. ⇒ **moving geometry away from the origin cannot enlarge a shipping record's constants.** **(2) The corner bound then pins the rest.** `zn = KX·lxq + KY·lyq + KC` is affine and bounded by 2^31 at all four corners; differencing two corners gives `|KX| < 2^32/(2w-2)` — under 3.1e8 even for the smallest legal `w = 8` — and likewise `KY`. ⇒ **`KX` and `KY` always fit a signed 32-bit field**, and only `KC` can exceed 2^31, by at most the `|KX|+|KY|` margin. The residue is still required, but for one term in a narrow band, not for a 39-bit `KX`.
>
> ⇒ Gate **A8** was rewritten to assert the *fold identity* (`folded KC == origin KC × z-scale`, which is what the off-origin frame actually proves), and a new **A11** exercises residue reconstruction directly at the unfolded `|KC| = 3.33e9` rather than through a frame that can no longer reach one.

### 4.3 Outline

```
                                ; exec == -1 for the entire kernel: the validator forbids
                                ; partial tiles, so there is no bounds guard and no exec write.
  s_load_dwordx4 s[16:19], s[0:1], 0x0
  s_load_dwordx4 s[20:23], s[0:1], 0x10
  s_waitcnt      lgkmcnt(0)
  s_add_u32      s0, s0, 64            ; step past the header
  s_addc_u32     s1, s1, 0             ; ADJACENT — addc consumes SCC as carry-in
  v_and_b32      v16, 7, v0
  v_lshrrev_b32  v17, 3, v0
  s_lshl_b32     s10, s8, 3
  s_lshl_b32     s11, s9, 3
  v_add_u32      v16, s10, v16         ; lx
  v_add_u32      v17, s11, v17         ; ly
  v_lshlrev_b32  v1, 1, v16
  v_or_b32       v1, 1, v1             ; lxq = 2*lx+1
  v_lshlrev_b32  v2, 1, v17
  v_or_b32       v2, 1, v2
  v_mov_b32      v3, s21               ; zbest = zclear
  v_mov_b32      v4, s22               ; cbest = bg
  s_mov_b32      s12, 0
  s_cmp_lt_u32   s12, s5
  s_cbranch_scc0 L_STORE                ; PRE-TEST: an empty list is the common case at 8x8

L_TRI:                                  ; ===== WAVE-UNIFORM LOOP =====
  s_load_dwordx4 s[32:35], s[0:1], 0x0
  s_load_dwordx4 s[36:39], s[0:1], 0x10
  s_load_dwordx4 s[40:43], s[0:1], 0x20
  s_load_dwordx4 s[44:47], s[0:1], 0x30
  s_waitcnt      lgkmcnt(0)             ; ONE full wait, INSIDE the loop, before the first read.
                                        ; NEVER lgkmcnt(1) — SMEM returns OUT OF ORDER on gfx9.
  v_mul_lo_u32   v5,  v1, s32 ; v_mul_lo_u32 v12, v2, s33
  v_add_u32      v5,  v5, v12 ; v_add_u32    v5,  s34, v5      ; w0
  v_mul_lo_u32   v6,  v1, s35 ; v_mul_lo_u32 v12, v2, s36
  v_add_u32      v6,  v6, v12 ; v_add_u32    v6,  s37, v6      ; w1
  v_sub_u32      v7,  s41, v5 ; v_sub_u32    v7,  v7,  v6      ; w2 = area - w0 - w1
  v_mul_lo_u32   v8,  v1, s38 ; v_mul_lo_u32 v12, v2, s39
  v_add_u32      v8,  v8, v12 ; v_add_u32    v8,  s40, v8      ; zn
  v_max_i32      v8,  0,  v8                                    ; domain clamp (2.3)
  ; ---- R2 divide, 5 instructions (2.2) ----
  v_mul_hi_u32   v9,  v8, s42
  v_mul_lo_u32   v10, v9, s41
  v_sub_u32      v10, v8, v10
  v_cmp_le_u32   vcc, s41, v10
  v_addc_co_u32  v9,  vcc, 0, v9, vcc
  ; ---- the predicate: THREE edge tests AND the depth test, all per-lane ----
  v_cmp_le_i32   s[24:25], 0, v5
  v_cmp_le_i32   s[26:27], 0, v6
  s_and_b64      s[24:25], s[24:25], s[26:27]
  v_cmp_le_i32   s[26:27], 0, v7
  s_and_b64      s[24:25], s[24:25], s[26:27]      ; = INSIDE
  v_cmp_lt_u32   s[26:27], v9, v3                   ; STRICT <, UNSIGNED, matching depthcore
  s_and_b64      s[24:25], s[24:25], s[26:27]      ; = WRITE
  ; ---- the update: TWO cndmask, and the ONLY writes to v3/v4 in this loop ----
  v_mov_b32      v11, s43                           ; MANDATORY (see below)
  v_cndmask_b32  v3,  v3, v9,  s[24:25]
  v_cndmask_b32  v4,  v4, v11, s[24:25]
  ; ---- tail: FIXED ORDER ----
  s_add_u32      s0,  s0, 64
  s_addc_u32     s1,  s1, 0                         ; nothing between these two
  s_add_u32      s12, s12, 1
  s_cmp_lt_u32   s12, s5
  s_cbranch_scc1 L_TRI

L_STORE:
  v_mul_lo_u32   v18, v17, s4 ; v_lshlrev_b32 v19, 2, v16 ; v_add_u32 v18, v18, v19
  v_add_co_u32   v18, vcc, s2, v18                  ; writes vcc, does not read it: 1 const-bus
  v_mov_b32      v19, s3
  v_addc_co_u32  v19, vcc, 0, v19, vcc              ; inline 0 + vcc read: 1 const-bus
  global_store_dword v[18:19], v4, off glc
  ; ... identical shape for z with s[16:17]/s20 into v[20:21], storing v3 ...
  ; ... witness (see 5), guarded by a WAVE-UNIFORM s_cmp on s[18:19] != 0 ...
L_END:
  s_waitcnt vmcnt(0)
  s_endpgm
```

### 4.4 Why there is no `s_cbranch` on a per-lane condition

`s_cbranch_vccz` fires only when **no** lane has the condition; `s_cbranch_vccnz` only when **any** does. Either way **one lane decides all 64.** Concretely: `s_cbranch_vccz L_SKIP` around the update executes the update for every lane whenever one lane passes ⇒ the triangle is **dilated to its whole 8×8 tile**, and the far triangle vanishes wherever any lane of that tile saw the near one. The damage is worst exactly at the interpenetration line ⇒ it fails the both-orders oracle ⇒ it reads as *"the serialisation is not serialising"* ⇒ **it buys a TD-5 atomics/binning rewrite for an emission bug.** That is the most expensive misdiagnosis available on this rung.

Prior art, both with signatures: `edge_cov.s:163-183` — the arc's first iron burn, case 14 wrong in 631 of 4096 bytes at worst delta 255, hidden on 19 of 20 corpus cases; `tex_rgba.s:225-230` — "the first version had two". **Corollary:** `edge_cov`'s wave branch was itself *correct* (`s_and_b64 vcc, vcc, exec` first) and still wrong, because the fall-through had no per-lane mask. A wave branch never substitutes for a lane mask.

The **only** `s_cbranch`es are on `s5` (a kernarg) and `s12` (an SALU counter) — wave-uniform by construction, so no lane can need to leave early. Same rule that licenses `tri_rgba.s:181-183` and `edge_cov.s:148-150`.

### 4.5 Named traps, verified this session

- ⛔ **`v_cndmask_b32 v4, v4, s43, s[24:25]` is REJECTED** — "violates constant bus restrictions". The selector spends gfx9's single constant-bus slot, so neither src0 nor src1 may be an SGPR. A 32-bit literal is also rejected ("literal operands are not supported"; VOP3 takes inline constants only, 64 assembles, 65 does not). Hence the mandatory `v_mov_b32 v11, s43`. Same class as `tri_rgba.s:71-74`; `tex_rgba.s:288/412` already does this dance.
- ⛔ **`s_addc_u32` consumes SCC as carry-in.** Nothing may sit between the base-lo add and the base-hi addc. Putting the loop counter's increment in the middle makes the pointer's high dword consume the counter's carry — silently correct on a short list, wrong only on a long one.
- ⭐ **`py` is per-lane for the first time in this tree.** Every shipped pixel shader has `py = tgid_y`, wave-uniform, and computes the row offset in SALU. An 8×8 tile puts **eight distinct rows in one wave**. Copying `s_mul_i32 s11, s9, s6` verbatim gives all 64 lanes the address of row `tgid_y*8`: 8 of 64 lanes correct, the tile writes its top row eight times. Signature: horizontal streaking — which reads as a binning or store bug, not as depth.
- **One 8×8 tile = one 64-lane wave, and that is load-bearing.** No `s_barrier`, no LDS, ever. At 16×16 the single-wave serialisation claim collapses outright.
- **`s_load_dwordx4` only.** `dwordx8`/`dwordx16` assemble but are outside the tree's iron-proven SMEM set, and `s_load_dwordx8 s[26:33]` is rejected for alignment. Walk the base with `s_add_u32`/`s_addc_u32` + immediate offsets, not a runtime SGPR soffset (which `edgeasm` does not emit).
- **Do NOT software-pipeline the record loads.** Double-buffered SGPR banks + partial-wait discipline have never run in this tree, and the measured cost model puts the frame-level lever on `gpu_tex_prep` (CPU), not shader latency.
- ⛔ **No `v_rcp_f32`, no `v_mul_hi_i32`, no `buffer_wbinvl1`.** `edge_setup.s:15-19`: LLVM's f32-reciprocal macro is exact only *empirically* and was demonstrably wrong before 2020. `v_mul_hi_i32` assembles but has never executed on this silicon. GL2 write-back is `gpu_batch_tail`'s `ACQUIRE_MEM` TCWB and the read-side invalidate is the per-dispatch `ACQUIRE_MEM INV` (decision D-6) — duplicating either adds an unproven opcode to solve a problem the ring already solves.
- **Header invariant to write down:** *this shader never reads the render target or the z buffer.* That is what removes the coherence question entirely, and it is exactly what a second-pass variant would break — `0x0D` is CP-DMA (MC-direct) while a shader load goes through GL2, and plan-S3 arm D measured a GL2 read served a stale line over an MC-direct write. It would present as "the depth clear didn't happen".
- **Scalar-cache staleness is already handled**: `GPU_CP_COHER_CNTL_INV = 0x28C40000` sets SH_KCACHE (1<<27), emitted pre-dispatch on every path including `gpu_blend_cov_run`. "Frame 2 shows frame 1's triangles" is not reachable through that door.

---

## 5. THE LANE WITNESS

**Channel:** its own `#86` slot, named by `witness_id`, resolved with `gpu_shm_mc`. Read back by ring 3 with `#73 shm_read` **directly — no `#90` hop**. Prior art is op `0x09`'s destination mask slot (`global_store_byte v[54:55], v53, off glc` into a ring-3-named slot). No new mechanism.

**Layout**
```
slot bytes = tiles_x * tiles_y * 64 * 2 * 4
   32x32 corpus:   4 *  4 * 64 * 2 * 4 =   8192 B
index  = ((tgid_y * tiles_x + tgid_x) * 64 + lane) * 2
word 0 = 0x17000000 | (tile_index << 6) | lane      <- written, always
word 1 = RESERVED, stays poison; the host gate ASSERTS it is still poison in v1
```

**The value is self-describing, and that is the point.** The host does not check "is this poison?" — it checks `witness[2i] == 0x17000000 | i`. The documented consequence of an under-granted SGPR file is a corrupted address carry chain, i.e. lanes writing the *wrong location*. Under a dumb witness that is invisible; under a self-describing one it reads as *"the word at index i says it belongs at index j"*. Four instructions buy that. Word 1 is the Q9-style extension point (a *second blob* could echo each lane's final z there) — it is **not** a z back-door in v1; the plan row's "Z lives in TD-3" holds.

**Placement:** at the **END**, after the colour and z stores — not at the top. A top-of-kernel witness goes green for a wave that hung mid-loop and actively misleads. Unconditional (`exec == -1`, guaranteed by the multiple-of-8 rule), `glc` on the store exactly as `edge_cov`'s mask store carries it.

**Pre-seed:** ring 3 fills every dword with `0xDEADBEEF` (`GPU_MT_NOTYET`) and uses a **FRESH slot per run**. `GPU_SHADER_OUT2_SUBOFF` records the failure this avoids: reusing a slot let a stale L2 line flush back over the pre-seed and mask whether the shader had written at all.

**The five-way discrimination**
1. all poison → **no wave ran** (residency/arm, wrong RSRC1, zero grid, CU mask)
2. whole tiles poisoned → the dispatch grid is short, or a scalar branch skipped those workgroups
3. the same lane index poisoned across many tiles → lane-uniform: exec/predicate defect
4. scattered dropouts → **the S1 symptom** (register aliasing), the only signal available
5. all witnesses correct + colour/z wrong → **the wave ran and computed wrong**; `depthmodel`'s green now convicts the *emission*

⭐ **Pre-register the discriminator for case 4/5 BEFORE the flash.** `gpu_blend_cov_run` programs no scratch descriptor and no `COMPUTE_TMPRING_SIZE`, and hand-written asm never spills — so S1's "VGPR pressure ⇒ spill" names the wrong mechanism. The real mechanism is a wave touching VGPRs outside its allocation, i.e. **another wave's registers on the same SIMD**, whose corruption varies run to run and is byte-for-byte the plan row's *"different output on two consecutive identical frames ⇒ a wave race, and the nondeterminism IS the finding."* **Re-run the identical frame with the grid forced to one workgroup** (`gx = gy = 1`). If determinism returns, it is register aliasing / RSRC1 — **not a race, and no atomics rewrite is warranted.**

⚠ The witness is internal agreement and can never be the only gate.

---

## 6. THE GATES

### 6.1 Host, all green before any burn

| # | file | asserts |
|---|---|---|
| **G1** | `depthmodel.cyr` | **lane fidelity.** Line 126's `zn` accumulate is unmasked i64 while `w0/w1/w2` are masked and sign-restored at 109-117. `dm_kx/ky/kc/area` are unmasked too, and `dm_area` is the sum of three unmasked C-terms — so the claim "w0+w1+w2 == area at 32-bit lanes" that the derived-`w2` optimisation depends on **has never been checked at lane width.** Mask all of them. |
| **G2** | `depthdiv.cyr` (new) | §2.6 in full — two counters, printed shortfall AND fire count, boundary sweep, adversarial frame, 5 mutations |
| **G3** | `depthcore.cyr` | three new corpus frames, §6.3 |
| **G4** | `depthgate.cyr` | D0d, D3, D0e, coverage print, §6.3 |
| **G5** | `depthmodel.cyr` | mirrors the **shipping** program: winding-normalised, `dstxy` folded into C/KC, `w2 = area - w0 - w1`, `v_max_i32` clamp, **unsigned** compare, no min-bias, 32-bit lanes throughout. Byte-identical to `depthcore` in colour **and** z, both orders. |
| **G6** | `depthgate.cyr` | the **corner bound** (§1.4 rule 18) evaluated in i64 on every corpus triangle — the validator's own rule, proven on the corpus |
| **G7** | **EXTERNAL #1** | §6.2 |
| **G8** | **EXTERNAL #2** | §6.2 |
| **G9** | `edgeasm.cyr` | `tri_depth` added to the emit list; `blob_check` vs llvm-mc on the same source; **`ea_vgpr_check(32, "tri_depth")`** |
| **G10** | `scripts/check/tridepth-carry.sh` (new) | no instruction between `L_TRI:` and the loop's `s_cbranch` names **v0 v1 v2 v3 v4** as a destination, except the two named `v_cndmask_b32` |
| **G11** | `shader-blob.sh rsrc` / `check` | RSRC1/RSRC2 harvested from `.rodata` bytes 48/52 and copied **verbatim**; committed store32 table vs assembled source |
| **G12** | `edge_abi_selftest` | ~20 new cases, §6.4 |

Wire G2/G3/G4/G6/G7/G8 into `scripts/check/host-gpu-oracles.sh` **and update its stale scope paragraph in the same edit** — that line has already gone stale twice.

⭐ **G9 and G10 are not optional, because llvm-mc is not an oracle here.** Verified: **llvm-mc assembles a kernel that uses `v24` while declaring `.amdhsa_next_free_vgpr 8`, with NO diagnostic**, emitting a valid RSRC1. The assembler that gates the blob will pass an under-declared shader silently. `ea_vgpr_check` ("the assembler already knows — it encoded every operand") is the tree's only mechanical counter, and it currently covers `edge_setup`/`edge_cov`/`tri_rgba` only. G10 is the gate that would have caught rung 13's `v19` clobber, which was invisible to llvm-mc, to `shader-blob.sh` **and** to the host model.

### 6.2 THE EXTERNAL INVARIANTS

⛔ **The both-orders oracle is NOT external.** It is an internal consistency property that a wrong shader and a wrong reference can satisfy together — the rung-15 shape, where `bicore`, `bimodel`, `texcore` **and** the shader all implemented the same wrong half-texel convention and every agreement gate went green.

⛔ **Translation equivariance is REJECTED as the external gate.** inv-1 proposed drawing the same figure at two `dstxy`. A constant sample-point offset **commutes with integer translation**, so a half-pixel convention error survives it untouched — the identical blindness, one lens over.

**G7 — CONSTANT-Z SILHOUETTE vs the iron-proven 2D path.** A single triangle at constant z, rendered by the depth path, must produce a silhouette byte-identical to what op `0x0A` / `tri_rgba` produces for the same vertices. The conventions are compatible and were checked: `tri_rgba.s:99` samples at `v_add_u32 v5, 0x8000, v5` (+0.5 px in 16.16), which **is** `depthcore`'s doubled `2*px+1`, and the `w == 0` inclusion rule (`>= 0`) matches on both sides. This compares against an **independently burned implementation**, not a co-designed sibling. **No shared premise can satisfy it.**

**G8 — THE INTERPENETRATION LINE, derived without rendering.** For the two corpus triangles, `z_0(x,y) = z_1(x,y)` is a **linear equation in x and y** obtainable on the CPU from the two `(KX, KY, KC, area)` tuples alone. Derive that line analytically, then assert every colour-boundary pixel in the shared region lies on it. Neither the shader nor `depthcore` can fake it, and it is the one gate that tests the *geometry* of the depth decision rather than its bytes.

### 6.3 The corpus — three new frames, because the shipped one is measurably blind

This is the single most important change in the document. **Measured by three independent adversarial passes, on the shipped `dc_corpus`:**

| broken implementation | orderdiff | colour vs ref | **z wrong** |
|---|---|---|---|
| divide one ULP short (4 perturbation models) | **0** | **0 of 1024** | — |
| R2 with the correction **dropped** | **0** | **0** | 19 px |
| rung-13 transplant, correction dropped | **0** | **0** | 92 px |
| uniform bias `z -= k`, any k in 1..64 | **0** | **0** | 507/507 |
| min-bias fold-back dropped | **0** | **0** | 507/507 |
| tile list walked **backwards** | **0** | **0** | 0 |

The corpus's z gradient is **30.95 units per pixel**; the design argues about being exact to 1 unit. Those two numbers cannot both matter. `depthmodel`'s M2 headline is also thinner than it reads: it quantised by 2^4 — **15× the ULP under discussion** — to move 3 pixels of 1024. And **`dc_ties == 0` (depthgate D0a) *is* order-invariance**, so "processes the list in submission order" is currently tested by nothing.

Worse, the two properties are **mutually exclusive on one frame** (measured sweep of z-separation 800 → 1): every separation where a 1-ULP error becomes visible also has `dc_ties > 0`, which fails D0a and makes D1 fire for a *correct* shader.

⇒ **Three frames, ~30 lines in `depthcore.cyr`:**

1. **PRECISION frame** — same geometry, z span compressed from 800 to **2**. It *has* ties, so it is **not** the order oracle: run it in **one fixed submission order** and byte-compare against `depthcore` rendered in that same order. New gate **D0d**.

   > ⭐ **LANDED, AND THE SWEEP CORRECTS THIS ROW.** The row said "span 2–4, ties 40–49, flips 40–49". Measured in-tree across spans 1–800: **span 2 flips 42 (49 ties); span 3 flips 24; span 4 flips 20**, so 3 and 4 are materially worse, not equivalent. ⛔ And the tight end is a **second null set**: **span 1 flips ZERO** — all 182 shared pixels tie, so the strict `<` hands every one to the incumbent in both directions. **Sensitivity is not monotone in the span**, and "tighter is finer" lands exactly on it. D0d therefore re-measures both endpoints every run and asserts the chosen span beats both, rather than leaving the peak as a comment.
2. **QUAD frame** — two triangles sharing a diagonal, `(4,4)-(27,4)-(27,27)-(4,27)`, z 100/300/500. Measured: **23 tie pixels, and the two orders differ in all 23** — reproduced exactly in-tree. `depthcore` has **no top-left fill rule** (`dc_render:114` is a bare `w >= 0`), so both triangles of any quad cover the shared diagonal *and* interpolate to identical z there — every shared edge in every real mesh is an exact tie decided by list order. That is rung 18's checkerboard floor and every DOOM wall. This is the **only** witness that the list is walked in submission order, and the only thing that separates *a reversed list* (a 3-line prep bug) from *a broken serialiser* (TD-5, "a separate larger bite").

   > ⚠ **NUMBERED D5, NOT D3.** `D3` is already the shipped determinism control (`depthgate.cyr:118`). Two gates called D3 is the ATOM_DRY defect one level up. ⭐ The landed gate is also **stronger than this row asked for**: not merely "the two orders differ" but *the **first**-submitted triangle won every one of the 23 ties* — a shader walking the list **backwards** satisfies "they differ" and fails this.
3. **OFF-ORIGIN frame** — exercises the mod-2^32 `KC` residue and the corner bound over the whole-rect `|zn|` domain.

   > ⛔ **THE PARAMETERS IN THIS ROW WERE WRONG AND THE FRAME WOULD HAVE BEEN A THIRD NULL SET.** "Translated to x = 700, `|KC| = 243e9`" is not reproducible: measured, x = 700 at the shipped z range gives **|KC| = 58,124,800 — 26 bits, comfortably inside an i32**, i.e. a frame that names the residue and never exercises it. The identity is exact and settles it: translating by `T` pixels gives **`KC' = KC - 2·T·KX`**, so `KC` grows with position only in proportion to `KX = Σ z_i A_i` — which scales with **z**, not with position. ⇒ landed as **x = 4000 (inside the ABI's 4096-px coord cap) AND z scaled 10×**, giving **|KC| = 3,326,848,000**, past a signed 32-bit field, while `zn` peaks at 48,368,000. New gate **A8** asserts the overflow so the frame cannot silently degrade back.

New gate **D0e** — the sentinel: parameterise `dc_render`'s zclear, render at the value iron actually uses (`0xFFFFFFFF`), and assert `zclear >= 2^24` under the chosen compare. Every existing call site passes `DC_FAR = 1000000`, which is **smaller than the ABI's own legal z ceiling** — the reference's clear plane sits in front of legal geometry and has never once been exercised at the hardware value.

**Coverage print, in the gate rather than discovered post-burn:** of the 16 tiles in the 32×32 corpus, only **7** contain any dual-covered (depth-discriminating) pixel; **9** prove nothing about z (a painter's-order shader is byte-identical there); tiles 13 and 14 are **entirely empty**, so a shader that never ran in them is byte-identical too.

### 6.4 ABI battery additions (~20 cases)

well-formed accept · last handle accepted · `GPU_RT_HANDLES` refused (`BADSLOT`) · `zw*4*zh` one row past a handle (`SLOTSIZE`) · draw rect exceeding `zwh` (`BOUNDS`) · off-screen (`BOUNDS`) · `w=0`/`h=0` (`DIM`) · **`w=12`, `dx=4` (`ALIGN`)** · `nt=0`/`nt=257` (`TRILIST`) · vtx slot one record short (`TRILIST`) · per-triangle reserved **`+44`** non-zero, not `+40` (`TRILIST`) · coord at ±2^28+1 (`COORD`) · coord with low 16 bits set (`SUBPIXEL`) · `z = 2^24` (`ZRANGE`) · a triangle passing the inside bound but failing the **corner** bound (`ZRANGE`) · tile·triangle one past `WORK_MAX` (`WORK`) · witness slot one lane short (`DSTSLOT`) · witness slot PMM-backed (`DSTSLOT`) · unknown flag bit (`RESERVED`) · reserved dword **15** non-zero (`RESERVED`) · plus `0x10`'s own set.

---

## 7. BITE ORDER

Each bite is independently verifiable and lands green. **Bites 1–6 are zero-burn.**

| # | bite | verified by | burn |
|---|---|---|---|
| ✅ **B0** | `depthmodel` lane-fidelity fix (mask `zn`, `KX/KY/KC`, `area` to 32-bit lanes + sign restore) | `host-gpu-oracles.sh` exit 95 | 0 |
| ✅ **B1** | `depthdiv.cyr` — R2 exactness gate + adversarial frame + 5 mutations | exit 95; printed table shows transplant green-on-corpus / RED-on-adversarial | 0 |
| ✅ **B2** | ⭐ corpus: PRECISION + QUAD + OFF-ORIGIN frames; depthgate D0d / D5 / D0e; coverage print | exit 95; **D5 shows the two orders DIFFERING** | 0 |
| ✅ **B3** | reshape `depthcore`+`depthmodel` to the shipping program (winding normalisation, `dstxy` fold, derived `w2`, `v_max` clamp, unsigned compare, no min-bias) + G6 corner bound | byte-identical colour AND z, both orders, all frames | 0 |
| ✅ **B4** | **external gates** G7 (constant-z silhouette vs the `tri_rgba` path) + G8 (analytic interpenetration line) | exit 95 | 0 |
| ✅ **B5** | **ABI only** — `0x0E` constants, `gpo_validate_tridepth`, field mask, flags, `GPU_OP_SUPPORTED` bit 14, battery. Worker returns `GPO_E_NOTIMPL`. ⛔ **Landed with `GPU_OP_NOTIMPL_MASK`, not as written** — see below. | `edge_abi_selftest` **127/127**; `edge-abi-smoke` 16/16; `kprint-len-check.sh` | 0 |
| ✅ **B6** | **`0x10 GPU_OP_RT_READ`** — ⛔ **CP-DMA MC→MC, NOT the kernel memcpy this document specifies** (see §1.5) — validator, battery, `GPU_OP_SUPPORTED` bit 16 | battery **136/136**; `edge-abi-smoke` 16/16 | 0 |
| ✅ **B7** | `gpu_trid_prep_build` — affine hoist, winding, `dstxy` fold, `R = 2^32/area`, residues, arena slots; `check-arena.sh` | ⛔ **NOT a diff against `depthmodel`'s hoist** (host-only, and a second copy of the same derivation) — an EXTERNAL check against the **direct edge functions** by cross product, plus the derived-w2 identity and the floor obligation by multiplication. **256/256**, smoke 18/18 | 0 |
| **B8** | `tri_depth.s` + the §3 register map as its header block + `edgeasm` emit + `ea_vgpr_check` + `tridepth-carry.sh` + RSRC harvest + blob table + `RSRC1_TDEP` | **two independent assemblers agree**; VGPR check green; carry gate green | 0 |
| **B9** | `gpu_tri_depth()` worker — residency at `0x5E000`, witness slot → MC, dispatch through `gpu_blend_cov_run` **unmodified** | build green; `GPU_OP_SUPPORTED` and the worker land together | 0 |
| **B10** | ⭐ **THE BURN.** `gputri` arm: 32×32 corpus, both orders, colour via `#90`→`#73`, **z via `0x10`**, witness via `#73`. Plus the one-workgroup re-run pre-registered as the aliasing-vs-race discriminator. | byte-identical colour **and z** across orders; both match `depthcore`; every witness word self-consistent | **1** |
| **B11** | PRECISION frame (fixed order) + QUAD frame (both orders) on iron | only if B10 is green | 0–1 |

**Pre-registered diagnostic rubric, written down before the flash** (because every failure in T1/T2/T5/T6 presents as order-dependence, which is the TD-5 escalation trigger):

- *a few pixels differ* → precision / tie → the divide or the corner bound
- *whole tiles differ* → wave branch or monotone lane loss → emission
- *the tile's top row replicated 8×* → the row index was computed in SALU (N1)
- *tiles show only background* → a scratch write clobbered `v3`/`v4`, or a signed/unsigned sentinel inversion — **not** "the depth test rejected everything"
- *two consecutive identical frames differ, and one workgroup restores determinism* → **register aliasing / RSRC1, NOT a race.** No atomics rewrite.

---

## 8. WHAT THE ATTACKERS FOUND THAT CHANGES THE DESIGN

Called out separately so it does not dissolve into the plan. Every item below is **measured**, not argued.

1. ⭐⭐ **The shipped corpus is a null-set probe for the property the rung declares load-bearing.** A one-ULP-short divide changes **0 of 1024 pixels** — not "few", zero — across four independent perturbation models. Sensitivity begins at a 1-*bit* quantisation, not at 1 ULP, because the corpus's z gradient is 30.95 units/pixel. Rung 15's leakage was 3151 quotients → 186 texels (5.9 %); here it is 1024 quotients → **0 pixels (0 %)**. ⇒ **PRECISION frame mandatory** (`z` span 2–4, flips 40–49 px).
2. ⭐⭐ **Precision-sensitivity and order-independence are mutually exclusive on one frame.** Sweeping z-separation 800 → 1: every separation where the ULP becomes visible also has `dc_ties > 0`, failing D0a and firing D1 for a *correct* shader. ⇒ **two frames, not one, and `GPU_OP_RT_READ` is BLOCKING, not a risk.** Without a z readback the burn cannot fail on a broken divide.
3. ⭐⭐ **"In submission order" is currently unfalsifiable, and D0a *requires* it to be.** `ties == 0` **is** order-invariance. A shader walking the list backwards passes. A counting-sort binner emitting reversed lists passes. ⇒ **QUAD frame** (23 ties, 23 px differ) is the only serialisation witness — and it is not academic, because `depthcore` has no top-left fill rule, so every shared edge in every real mesh is an exact tie.
4. ⭐ **Signed-vs-unsigned compare was decided oppositely in three investigations, and the likely combination renders a black tile that passes the oracle.** `v_cmp_lt_i32` + the `0xFFFFFFFF` that `gpudepth.cyr:77` already burns = `-1` = nearest ⇒ nothing draws ⇒ both orders identical ⇒ green. ⇒ pinned **unsigned**, plus a validator rule `zclear >= 2^24` and gate D0e that renders the reference at the *hardware* clear value.
5. ⭐ **There was no z store in the design, and no kernarg left to address one.** `dm_vs_ref` compares colour **and** z; the proposed register map ended with a colour pair and a witness pair. `RSRC2` must stay `0x00000190` (USER_SGPR=8) for `gpu_blend_cov_run` to dispatch unmodified, and all 8 dwords were spent. ⇒ **a 64-byte header record in the arena** carrying the z base, witness base, z pitch, zclear, bg and tiles_x.
6. ⭐ **The loop shape was binned in one investigation and unbinned in three — and TD-5 says unbinned.** A kernel binner forces a per-iteration indirection, two dependent SMEM streams, two waits, a different SGPR map and a different tail. ⇒ **no binner, no tile/pair arenas**, with a `GPO_E_WORK` cap in tile·triangle units.
7. ⭐ **The occupancy trade that motivated squeezing the register map is illusory.** One workgroup = one wave, and gfx9 caps 16 workgroups/CU ⇒ occupancy is 4 waves/SIMD for any VGPR count ≤ 64. ⇒ **never hand-squeeze a proven divider for VGPRs**, which was named as the highest-risk manual step in the bite.
8. ⭐ **The min-bias is vacuous under the ABI and unwitnessable on the corpus** (both triangles have `m = 100`; dropping the fold-back gives 0 colour diff and 507/507 wrong z). ⇒ **dropped**, replaced by one `v_max_i32`.
9. ⭐ **The joint bound was derived over inside pixels but the shader is predicated and evaluates every lane.** Measured: a triangle passing *every* proposed validator rule peaks at `|zn| = 3.264e9` over its own bbox — **1.52× past a 32-bit lane**, wrong at 25 of 81 pixels. ⇒ **corner bound**, not inside bound. `depthmodel`'s A4 has the same defect (2.43e6 inside vs 4.84e6 whole-frame).
10. ⭐ **`KX/KY/KC` are unbounded by any validator and the design works only via an undocumented mod-2^32 reduction.** `KC` needs 39 bits off-origin. ⇒ **document the residues as deliberate**, add the OFF-ORIGIN frame, and never "fix" it by validating `|KC| < 2^31` (which would refuse legal triangles).
11. ⭐ **`0x0E` is a REPLACE and the ABI called it a composite.** `dc_render` stores unconditionally, so an empty tile still writes bg + zclear over all 64 pixels. ⇒ **say REPLACE in the ABI**, and drop the claim that N records at different `dstxy` compose over one clear.
12. ⭐ **`llvm-mc` silently accepts an under-declared VGPR count** (uses `v24`, declares 8, no diagnostic). The gating assembler is not an oracle. ⇒ `ea_vgpr_check` for `tri_depth` in `edgeasm.cyr` is **mandatory**, plus the `tridepth-carry.sh` span gate.
13. **Assembler-level corrections, each verified:** `v_cndmask_b32` with an SGPR src violates the constant bus (the `v_mov` is required, not stylistic); `s[23:24]` is rejected for alignment; `v_addc_co_u32 v9, vcc, v9, 0, vcc` silently promotes to the 8-byte VOP3B form — use `0, v9`; and `vcc` is **not** free for the predicate despite there being no 64-bit intermediates, because the R2 correction writes it mid-body.
14. **Translation equivariance is blind to the error it was proposed to catch** (a constant sample offset commutes with integer translation). ⇒ replaced by G7 (constant-z silhouette vs the independently-burned 2D path) and G8 (analytic interpenetration line).

**Confirmed sound, and worth recording as such:** the R2 exactness proof (151,935 cases, 0 mismatches, max shortfall exactly 1); the new-op-not-a-flag argument from `gpo_field_mask(op)`; the per-handle 32 MB depth bound; the far-reserved-dword `+44` check; the harvested RSRC1 with the `roundup8(n+6)` XNACK rule; the mechanical carry-set gate; the self-describing witness value; `GPU_CP_COHER_CNTL_INV` already covering SH_KCACHE; and the watchdog risk being **over-stated** (unbinned at the corpus scale is microseconds; `gpu_recover_dequeue` R-2/R-3/R-4 exist and refuse `GRBM_SOFT_RESET`) — rank it below every item above.