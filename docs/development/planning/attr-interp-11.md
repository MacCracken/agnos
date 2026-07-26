# RUNG 11 — IMPLEMENTATION PLAN

<!-- Rung 11 implementation plan. Produced 2026-07-26 by a 2-ground survey + 3 independent designs
     + 3 adversarial judges (exactness lens, emission lens, cost/consumer lens) + this synthesis.
     Kept because the plan's VALUE is its refutations: three designs were scored, two were killed
     with concrete counterexamples, and ONE UNANIMOUS JUDGE RECOMMENDATION WAS ITSELF REFUTED here
     (§1.3, the E-clamp). gpu.md's rung-11 row points here. -->

## `tri_rgba`: exact integer barycentric attribute interpolation on gfx90c, one new blob

---

## 0. THE VERDICT — RUNG 11 IS ELEVEN BITES. TEN OF THEM COST ZERO BURNS, AND THE BUDGET IS STILL FLASH 1.

**The rung as scoped in `gpu.md:818` cannot be built as written, and the blocker is the ORACLE, not the shader.**

| Missing precondition | Evidence (verified this session) | Consequence if ignored |
|---|---|---|
| **The second oracle clause is unachievable by any integer design.** `gpu.md:818` demands *"bit-identical reproduction of an existing op-`0x04` gradient expressed as two triangles."* | `grad_linear.s:57` derives `t` from **`v_rcp_f32`** — a hardware reciprocal APPROXIMATION. Its own shipped self-test asserts row 0 with **zero** tolerance (`gpu.cyr:3106`) and gates the rest at `maxdev > 2` (`:3111`); `CHANGELOG.md:3210` reports **max dev 1 on iron** against its own integer reference. | The highest-probability outcome is a **CORRECT** shader, deltas of 1 against op `0x04`, and a real flash spent hunting a bug that does not exist — with the actually-wrong thing (the oracle) suspected last. `refagree.cyr:22-25`'s degradation clause requires this be reported to the operator **before** the rung opens. |
| **The third failure mode is mis-attributed.** The row says *"a seam or double-blend on the shared edge of two triangles ⇒ non-watertight fill rule."* | A boundary pixel with α₁ = α₂ = 0.5 composited **sequentially** yields `0.75·col + 0.25·dst` where the union is `1.0·col`. That is **src-over conflation**, present in every 2D rasteriser, and it is not a fill-rule property at all. | A correct shader gets blamed for a mechanism it does not have, and the reference gets indicted alongside it. |
| **A live arena overlap sits under the rung's own working set, and `check.sh` is structurally blind to it.** | `GPU_BATCH_SNAP_SUBOFF = 0xC0000` (`gpu_regs.cyr:1185`) at `GPU_BATCH_SNAP_W(256) × GPU_BATCH_SNAP_H(128) × 4 = 0x20000` spans **[0xC0000, 0xE0000)**. `GPU_EDGE_PREP_SUBOFF = 0xD0000` (`:1164`) is **inside it**. `gpu_regs.cyr:1183` still says S12 is *"well clear of every other slot (highest is BR2_SRC ending 0x79600)"* — written before the rung-9 prep table landed. `scripts/check.sh:56-68` is a **value-only** duplicate test and documents its own blindness: *"it needs no knowledge of each slot's extent, so it cannot rot."* | With `VM_CONTEXT0` disabled there are no page tables — an out-of-bounds store lands somewhere **REAL**. Latent today only because the S12 batch selftest and op `0x08` are never concurrent. **Two of the three candidate designs proposed new slots at `0xD2000`/`0xD3000`/`0xD8000` — all inside the S12 snapshot — and all four would have shipped GREEN.** |
| **There is no host-side barycentric reference.** `grad_ref_px` (`gpu.cyr:3007-3025`) is 2-stop, y-only, and lives in the **kernel**. | Read directly. | If rung 11 hand-transcribes a reference into both the kernel self-test and the host tool, it recreates the ATOM_DRY defect `refraster.cyr:1-18` exists to prevent, and Cyrius shadows duplicate `fn` **silently**. |

**Ordering claim: 10 of the 11 bites are provable at ZERO BURNS. Only Bite 10 needs iron, and it carries three independent oracles on ONE flash. The `gpu.md` budget of Flash 1 holds.** §5 names exactly what would force a second.

---

## 1. THE CHOSEN DESIGN — what I took, and from where

**Spine: EXACT-BARY (design 3).** Unanimous 1st across all three adversarial judges, on three different lenses. It is the only design whose byte-identity oracle is measured against **mathematics** rather than against a specification it shares with its own reference, and the only one that dispatches `edge_setup.s` and `edge_cov.s` as the **shipped, iron-proven binaries, byte-for-byte**.

**Structure:** a CPU-side Cyrius prologue hoists one exact reciprocal per record; `edge_setup` and `edge_cov` run **unmodified** to produce an 8bpp coverage mask into a kernel arena slot; one new blob `tri_rgba.s` reads that byte, evaluates two exact 64-bit edge functions at the pixel centre, derives the third from `E_A + E_B + E_C ≡ 2A`, forms a 96-bit numerator per channel, and takes **one exact round-half-up quotient per channel** by the shared per-record denominator `D255 = 255·2A`.

⭐ **The decisive structural move is that COVERAGE GEOMETRY AND THE ATTRIBUTE FRAME ARE DECOUPLED.** The shape is an edge array (any closed path, exactly like op `0x08`); the attribute basis is 3 vertices + 3 colours, an affine frame that need not coincide with the shape. Barycentric interpolation is an affine function on the whole plane, so this is well-posed. Three consequences carry the rung:

1. **A two-triangle quad is ONE record** — one coverage pass through the unmodified `edge_cov.s`, one blend. **No seam and no double-blend are structurally possible.** Rung 8's shared-edge corpus transfers verbatim.
2. **The op-`0x04` gradient rect is ONE record** (4-edge rect + a 3-vertex frame), which is what makes the replacement oracle a **zero-tolerance** gate instead of a tolerance (§3).
3. Work is `O(covered area)`, not `O(area × ntri)`. Both losing designs loop every triangle over every pixel with no bbox reject; TRIPREP's own self-critique #12 concedes 64 full coverage walks per pixel on a 99%-empty screen.

### 1.1 What I took from the losing designs

| Graft | From | Why |
|---|---|---|
| **The `edgeasm` VGPR high-water gate**, as its own bite | TRIPREP (all three judges named it) | `gpu.md:1017` calls VGPR pressure *"the largest unmeasured assumption and there is no oracle for it"* — `RSRC1` is not GRBM-readable. `edgeasm.cyr` knows every operand it encoded, so it can compute the emit list's maximum VGPR index mechanically and assert it against the committed `.amdhsa_next_free_vgpr`. Converts a silent **under**-declaration (a spill to scratch agnos has never configured — a fault, not a slowdown) into a host-side gate at zero burns. Outlives rung 11. |
| **The wave-uniform 4-channel loop** | judge 2 | Cuts `tri_rgba` from ~600 emit dwords to ~200 — the difference between an emit list a human can review and one they cannot. The trip count is wave-uniform, so `s_cbranch_scc1` here is **not** the burn-1 trap. |
| **The signed-`mul_hi` identity, promoted from fallback to the SHIPPING path** | judge 3's G2, judge 2's verification | `v_mul_hi_i32` (VOP3 `0x287`) has **never executed on agnos silicon** — R10's exact class. `mul_hi_i32(a,b) = mul_hi_u32(a,b) − ((a>>>31)&b) − ((b>>>31)&a)` is exact (re-derived independently: `a_s = a_u − 2³²·s_a`, so `hi(a_s·b_s) = hi(a_u·b_u) − s_a·b_u − s_b·a_u (mod 2³²)`), costs +3 VALU per product, and uses only calibrated opcodes. ⭐ **Result: tri_rgba introduces ZERO new opcodes and ZERO new silicon dependence.** |
| **The banding / fixed-point-width table, as the RECORDED reason the exact path was chosen** | PLANE-11 + EXACT-BARY | *"The denominator has no fixed-point width"* reads as a dodge without the number that says what the shortcut would have cost. §2.5. |
| **The `E_A + E_B + E_C ≡ 2A` identity as the i64-overflow falsification arm** | TRIPREP | Cyrius has no i128, so the algebraic identity is the natural overflow detector. ⚠ Taken with judge 1's correction: `tri_rgba` **derives** `E_A`, which makes the identity structural and therefore vacuous in the shader. The falsification arm computes all three **independently** in the host model and validator. |
| **The 96-bit correction restated as an ADD, not a SUBTRACT** | mine, forced by judge 2's finding that `v_sub_co_u32`/`v_subb_co_u32` are absent from the calibrated set | `if (N' ≥ (qh+1)·D255) qh += 1` is exactly equivalent to `r = N' − qh·D255; if (r ≥ D255) qh += 1`, and needs no multi-precision subtract at all. |
| **The prep record as the kernarg-pressure absorber**, with its own selftest | TRIPREP/judge 2 | A ninth kernarg means a new `RSRC2`, which means `gpu_blend_cov_run` no longer dispatches it — losing the no-dispatcher-change property that made rung 9b cheap. ⚠ Taken with TRIPREP's own warning: it is a new kernel↔shader mini-ABI with **no validator**, a field-order error yields a plausible wrong picture, and its selftest must **not** be a kernel read-back of the record it just wrote — that is echo, not answer ([[feedback_echo_vs_answer_registers]]). |
| **`edge_id = 0 means derive` moved onto an explicit FLAGS BIT** | judge 1's G7 | Zero is the uninitialised value. A caller who forgets to set `edge_id` must get a **reject**, not a triangle. Reject, never guess. |

### 1.2 What I reject, and why

| Rejected | From | Reason |
|---|---|---|
| **Transcribing `edge_cov`'s inner walk into a new blob** | TRIPREP, PLANE-11 (both say "VERBATIM") | There is no call instruction in play. A hand-copy of 135 dwords into a new kernel with a new register allocation and a new loop bound is **a new blob that has never run**; rung 9's iron-validated 20/20 corpus, `edgemodel.cyr`'s five gates, and the shared-edge watertightness oracle do **not** transfer to it. It is ATOM_DRY at machine-code level, where Cyrius's silent duplicate-`fn` shadowing has no analogue and nothing warns. **This makes TRIPREP internally inconsistent**: its central watertightness claim — *"the fill rule is not 'the same rule', it is THE SAME MACHINE CODE"* — is true only of its D1. |
| **PLANE-11's `±2^44` gradient clamp** | PLANE-11 | Its own self-critique 3 is correct and damning: the clamp is output-**bounded**, not output-**neutral**, and cannot be proven otherwise. No natural corpus case exercises it; reference and shader clamp identically so nothing in the byte-diff can say it fired. |
| **PLANE-11's 12 × 87-iteration bit-serial 96/64 divisions in a GPU dispatch** | PLANE-11 | ~17,000 VALU in a **single lane** per triangle. It claims ~7 µs; at 4 cycles per wave-instruction on a SIMD16 the honest number is ~40 µs — **larger than a whole dispatch**, paid even at `ntri = 1`, the common case. The hoisting argument is sound; the placement is not. |
| **PLANE-11's `#86`-slot destination + a second `BLEND_RECT` to place it** | PLANE-11 | A 4th dispatch plus a full read+write of the surface. Judge 3 measures the crossover at ~1747 covered px against rung 10's **measured** 1751 — rung 11 would consume the entire margin the kill gate bought, on its first day, for a destination `SHM_MAX_SIZE = 2 MB` caps at ~700×700 anyway. |
| **TRIPREP's `L2 = min(L2, 2^23 − L1)` renormalisation** | TRIPREP | Asymmetric in the vertices: two callers submitting the same triangle with rotated vertex order get bit-different boundary pixels. Its own self-critique 11 concedes a rotation-invariance test **will** go red. |
| **Any Q-bit fixed-point barycentric** (TRIPREP's Q=23, PLANE-11's F=32) | both | Both ship a reference that implements the **same approximation** as the shader. If the spec is wrong, both agree and both are wrong, and a green byte-diff says nothing. That is "a gate that cannot fail" in the precise sense this arc bans. |
| **`v_rcp_f32` in the barycentric path — and specifically the power-of-two escape hatch** | all three found it independently | Replicating `grad_linear`'s float sequence **and** making the calibration rect's width a power of two **would** give bit-identity (`v_rcp_f32` is mantissa-driven with the exponent handled separately, so `fl(W·H)` shares `fl(H)`'s mantissa and `rcp` scales by an exact power of two). ⛔ It is banned twice in the strongest language in the tree (`edge_setup.s:15-18`, `edgemodel.cyr:87-92`) and it would trade an exact-by-construction divider for an ISA-permitted ±1-ULP approximation **in order to agree with a LESS accurate reference**. [[feedback_sovereignty_over_slip_at_base]]. **Recorded here as REJECTED so it is not rediscovered mid-bite as a "fix".** |
| **VOP3P / DS / SDWA / DPP / cross-lane of any kind** | — | Verified: `mabda/src/gfx9_encode.cyr:270-383` implements exactly VOP1, VOP2, VOPC, VOP3a, VOP3b, SOP1, SOP2, SOPP, SOPC, SMEM, FLAT. `v_pk_mad_u16`, `ds_*`, `v_readlane`, `v_permlane` would each need a new **format function in mabda** — a cross-repo edit inside a shader rung. This is a written design rule for the whole rung, not a coincidence. |

### 1.3 ⛔ THE UNANIMOUS GRAFT I REFUTE — DO NOT CLAMP `E_i` TO `[0, 2A]`

**All three judges independently named TRIPREP's pre-divider clamp as "the highest-value graft" / "the best single idea in either losing design". It is wrong for this design, and the counterexample is stark.**

The clamp's appeal is real: it *manufactures* the `u ≤ d` gift the half-open rule handed rung 9 for free (`edgemodel.cyr:161-165`), bounds `q` at 765 instead of 783,360, and deletes an invented validator constant. **But it breaks the gradient-equivalence oracle at the far corner of every gradient rect.**

The gradient frame is `A = (0, 32768) C0`, `B = (Wfx, 32768) C0`, `C = (0, 32768 + den·65536) C1`. At the rect's last pixel `(w−1, h−1)`:

```
E_C = 2A exactly          E_B = den·65536·Px > 0          E_A = 2A − E_B − E_C = −E_B  < 0
unclamped:  N = (E_A + E_B)·c0' + E_C·c1' = 0·c0' + 2A·c1'  =>  q = c1     ✅
clamped:    Ê_A = 0  =>  N = E_B·c0' + 2A·c1'               =>  q ≈ c1 + c0·(1 − 1/2w)
```

At the **shipped** self-test constants (`GPU_GRD_C0 = 0xFFC000C0`, so `c0_R = 192`; `GPU_GRD_C1 = 0x00000000`, so `c1_R = 0`) the last row's last pixel comes out **≈192 instead of 0**. A massive, visible error — and one the byte-diff would attribute to the interpolator.

**Root cause:** the clamp is only inert where all `E_i ≥ 0`, i.e. **inside the frame**. A triangle does not contain its own bounding box, so no frame that reproduces a full-width gradient can contain the rect it interpolates over. The individual `E_A` goes negative while the **sum** stays correct — and that cancellation is precisely what the clamp destroys.

⇒ **`GPU_TRI_E_RATIO` survives — but derived, not invented.** EXACT-BARY's own W4 concedes 1024 *"has no geometric meaning"*. §2.4 derives its **hard ceiling of 701,000** from the one-step correction bound and states 1024 as a chosen operating point with a **685× margin** and a real geometric meaning: *the maximum frame skew relative to the evaluation rect*. The numerator's non-negativity is restored by `N' = max(N, 0) + bias` — one 96-bit sign-select per channel — and the byte range and premultiplication by `min(q, 255)` then `min(q_ch, q_a)`, two VALU per channel, present identically in the reference.

### 1.4 Dispatch shape — three dispatches, ONE new blob, ZERO dispatcher change

```
CPU prologue   (gpu_tri_rgba, Cyrius, no dispatch, ~200 ns)
   - if FLAG_DERIVE: synthesise the frame's 3 edges into GPU_TRI_EDGE_SUBOFF (48 B)
   - 2A, D255, t, Dh, L, V = recip32(Dh<<L), the 6 affine coefficients, 3 packed colours
   - write the 128-byte TRI-PREP record; gpu_mfence()
D1  edge_setup   THE SHIPPED BINARY, BYTE-UNCHANGED.  grid ((ne+63)/64, 1)
D2  edge_cov     THE SHIPPED BINARY, BYTE-UNCHANGED.  grid ((w+63)/64, h) -> 8bpp cov in the arena
D3  tri_rgba     NEW BLOB.                            grid ((w+63)/64, h), 64x1, gy = py
```

All three ride the **unmodified** `gpu_blend_cov_run` (`gpu.cyr:2665`). `tri_rgba` is authored at `RSRC2 = 0x190 = GPU_COMPUTE_RSRC2_COV` — no dispatcher change, no new PM4, no `RSRC2` edit. **That is a design RULE (Decision 6), not a coincidence, and it is what made rung 9b cheap.**

Three sequential calls, not one chained submission: each already emits `ACQUIRE_MEM` invalidate → `DISPATCH_DIRECT` → `CS_PARTIAL_FLUSH` → `TCWB` → fence, the S3-proven producer→consumer pattern (`gpu.cyr:3834-3837`).

⛔ **Fusing D2 into D3 would save 28.8 µs and one arena slot. Rejected with a number:** at `w·h = 2^20` the raster work is ~3.8 ms, so 28.8 µs is **0.75%** — and fusion would edit `edge_cov.s` (losing the oracle, Decision 1) and push VGPRs past 64. Named as a rung-12 option with its measured upside, not taken.

**Kernargs** — `gpu_blend_cov_run`'s existing 8-slot signature, unchanged:

```
s[0:1] = TRI-PREP base (kernel arena)   s[2:3] = dst base (back buffer + dy*pitch + dx*4)
s4     = dst pitch (bytes)              s5     = 0
s6     = w (pixels)   <- edge_cov's EXACT position, so the bounds guard transplants verbatim
s7     = 0            <- TWO SPARE, same as edge_cov
s8 = tgid_x    s9 = tgid_y (= py)    v0 = lane 0..63
```

⭐ The **coverage-mask base rides inside the prep record**, not a kernarg. That is R7's *"design the setup record to absorb the extra state"*, and it is what leaves two kernargs spare for rung 12.

### 1.5 Arena — ⛔ NOTHING BELOW `0xE0000`

Verified free windows: `[0xA8000, 0xC0000)` (96 KB, above the S3 tiles which end `0xA7FFF`) and **`[0xE0000, 0x1F0000)` (1.06 MB, above the S12 snapshot, below the sacrificial slot)**.

| Constant | Value | Extent | Note |
|---|---|---|---|
| `GPU_TRI_SHADER_SUBOFF` | `0x59000` | 4 KB | residency slot **9**. ⚠ Slot 8 (`0x58000`) is `GPU_BLEND_DONE_SUBOFF`, so the table is no longer contiguous — `GPU_SHADER_SLOT_BASE`'s *"8 slots × 4 KB = 0x50000..0x57FFF"* comment (`gpu_regs.cyr:1226`) **must be updated in the same bite** or the rung-6 arena audit reads a stale map. |
| `GPU_TRI_PREP_SUBOFF` | `0xE0000` | 8 KB → `0xE2000` | 64 records × 128 B |
| `GPU_TRI_EDGE_SUBOFF` | `0xE2000` | 4 KB → `0xE3000` | synthesised frame edges when `FLAG_DERIVE` is set |
| `GPU_TRI_COV_SUBOFF` | `0xE4000` | 1 MB → `0x1E4000` | 8bpp coverage scratch; **48 KB clear** of `GPU_SACRIFICIAL_SUBOFF` at `0x1F0000` |
| `GPU_HIGHEST_PUBLISHED_SLOT` | `0xD0000` → `0xE4000` | | |

**And the pre-existing overlap is fixed in the same bite: `GPU_EDGE_PREP_SUBOFF` moves `0xD0000` → `0xA8000`** (8 KB, in the free window below the S12 snapshot), and `gpu_regs.cyr:1183`'s stale *"well clear of every other slot"* comment is corrected. B0.

### 1.6 The TRI-PREP record — 128 B, kernel-owned, ring 3 never sees it

```
Q0 +0    cov_mc_lo   cov_mc_hi   t           t32 = 32 - t
Q1 +16   Dh          V           L           reserved (0)
Q2 +32   A2_lo       A2_hi       D255_lo     D255_hi
Q3 +48   kxB         kyB         k0B_lo      k0B_hi
Q4 +64   kxC         kyC         k0C_lo      k0C_hi
Q5 +80   cA          cB          cC          reserved (0)     <- packed premultiplied ARGB
Q6 +96   reserved (0) x4       Q7 +112  reserved (0) x4        <- THE EXTENSION POINT
```

Six `global_load_dwordx4`. `E = kx·Px + ky·Py + k0` is precomputed CPU-side, so the shader does **no per-pixel vertex subtraction**. ⭐ Q6/Q7 carry the record-level *"every undefined dword MUST be zero"* rule into the kernel↔shader seam, mirroring the `#92` record — which is what makes `rt_handle` (Trap 3) a non-breaking future extension **by construction**.

### 1.7 `tri_rgba` — the per-pixel kernel

```
s_mov_b64 exec, -1
px = tgid_x*64 + lane ; v_cmp_gt_u32(w, px) ; s_and_saveexec_b64 ; s_cbranch_execz L_END   [edge_cov.s:35-39 shape]
load TRI-PREP Q0..Q4                                                              5x dwordx4
cov = load_ubyte(cov_mc + py*w + px)
⭐ v_cmp_ne_u32(cov,0) ; s_and_saveexec_b64 ; s_cbranch_execz L_END
   ⛔ THIS IS AN EXEC MASK, NOT A BRANCH ON VCC. Masking EXEC is per-lane and correct;
      s_cbranch_vccz is wave-level and IS the rung-9b burn-1 fault (edge_cov.s:163-182,
      hidden on 19 of 20 corpus cases). Every early-out in this kernel is an exec mask. (Decision 7)
Pcx = (px<<16) + 32768 ; Pcy = (py<<16) + 32768                    [Pcy wave-uniform -> SALU]
E_B = smul64(kxB,Pcx) + smul64(kyB,Pcy) + k0B                                    ~20 VALU
E_C = smul64(kxC,Pcx) + smul64(kyC,Pcy) + k0C                                    ~20 VALU
E_A = A2 - E_B - E_C                                                              ~8 VALU
load TRI-PREP Q5 ; qa = 255
s_mov_b32 s_ch, 0
L_CH:                            ⭐ WAVE-UNIFORM loop, 4 iterations, s_cbranch_scc1.
                                    The trip count is uniform, so this is NOT the burn-1 trap. (Decision 7)
    sh = 24 - s_ch*8                                     [alpha FIRST, so qa is live for r/g/b]
    p_i = ((c_i >> sh) & 0xFF) * cov                     [<= 65025]                6+3 VALU
    N   = E_A*p_A + E_B*p_B + E_C*p_C                    [96-bit signed]            ~39 VALU
    N'  = max(N, 0) + (D255 >> 1)                        [96-bit, round-half-up]     ~8 VALU
    Nh  = N' >> t                                        [96->64 funnel, t in [10,31]] ~8 VALU
    qh  = <edge_cov.s:105-121 VERBATIM>(P=Nh, d=Dh, V, L)                            25 VALU
    ⭐ if (N' >= (qh+1)*D255) qh += 1     THE single exact correction, branch-free    ~20 VALU
       (an ADD and a 96-bit unsigned compare -- no multi-precision SUBTRACT, so
        v_sub_co_u32 / v_subb_co_u32 are not needed and nothing new is calibrated)
    q = min(qh, 255) ; if (s_ch == 0) qa = q ; q = min(q, qa)                         ~3 VALU
    out = out | (q << sh)                                                             ~2 VALU
    s_ch++ ; s_cmp_lt_u32 s_ch, 4 ; s_cbranch_scc1 L_CH
⭐ src-over tail: blend_premul.s's f32 core VERBATIM, src = `out`                    ~22 VALU
   2 (ia = fma(sa, fl(-1/255), 1.0)) + 4 channels x (v_cvt_f32_ubyteN, v_fma_f32, v_cvt_pk_u8_f32)
global_store_dword at dst + py*pitch + px*4
L_END: s_endpgm

TOTAL ~ 540 VALU/px.  The four exact quotients + their accumulate = ~408 of that = 76%.
```

**⭐ NEW OPCODE NEEDS: NONE.** Every instruction has executed on agnos silicon. `v_mul_lo_u32`/`v_mul_hi_u32` (VOP3 `0x285`/`0x286`), `v_ashrrev_i32`, `v_and_b32`, `v_xor_b32`, `v_add_co_u32`/`v_addc_co_u32`, `v_cndmask_b32`, `v_cmp_*`, `v_lshlrev_b32`/`v_lshrrev_b32`, `v_min_u32`/`v_max_i32`, `global_load_dword/dwordx4/ubyte`, `global_store_dword`, `s_and_saveexec_b64` — all shipped. The f32 tail's `v_cvt_f32_ubyte0..3` (VOP1 `0x11`-`0x14`), `v_fma_f32` (VOP3 `0x1CB`) and `v_cvt_pk_u8_f32` (VOP3 `0x1DD`) are shipped in `blend_premul`/`grad_linear` **and** already inside `edgeasm`'s calibration gate.

**On "no float", scoped honestly:** the barycentric divide is integer and exact. The composite tail is f32 — and `blend_pk.s:55-56` proves it **bit-identical** to the integer `sc + round(dst·ia/255)` over **all 8,421,376 premultiplied triples**. That is a *proven re-expression*, not an approximation. It is also **cheaper** (`blend_premul.s:6-9`: f32 = 20-22 VALU/px vs packed-int16 with div-255 = 31-33, because gfx9 has hardware unpack only to f32 and hardware pack only from f32). ⚠ Its one corner — a small **negative** `ia` at `src_a = 255` (`blend_pk.s:76-81`) — is **already settled on iron**: `grad_linear`'s row 0 is exactly that input (`C0 = 0xFFC000C0` has G = 0x00 with a0 = 255 over underlay G = 0x20 / 0xE0) and it is asserted **bit-exact with zero tolerance** and passes (`gpu.cyr:3106`). ⇒ `v_cvt_pk_u8_f32` round-and-clamps small negatives to 0, settled by a shipped passing gate. The integer swap (`blend_pk.s:9-23`'s exact `+128` / `(m+(m>>8))>>8` pairing — ⛔ **copy the pairing verbatim; two of the four bias/shift combinations fail, 45 and 47 cases**) is a named, costed fallback: 4 calibrated VOP2 per channel + unpack/pack.

### 1.8 Registers and RSRC

> ⭐ **MEASURED 2026-07-26 from the assembled object, not estimated.** The prologue assembles and
> its descriptor harvests to **`RSRC1 = 0x002C018F`** (64 VGPRs, 56 SGPRs) and
> **`RSRC2 = 0x00000190`** — which is **byte-identical to the shipped `GPU_COMPUTE_RSRC2_COV`**.
> That is the property the dispatch claim rests on: the existing `gpu_blend_cov_run` can issue this
> blob with no PM4 change, no RSRC2 edit and no dispatcher change. It is now harvested rather than
> assumed.
> ⚠ The `next_free_vgpr 64` in the source is a CEILING, not a measurement — the prologue alone uses
> only up to v6. It must be re-derived from the finished emit list via the high-water gate before
> the blob ships, or it over-declares and silently costs occupancy (the one direction that gate
> cannot see).


Estimated **~56 VGPRs** with the channel loop rolled and colour bytes re-extracted per iteration rather than held live. gfx9 grants in blocks of 4; 56 and 64 both give `floor(256/n) = 4` waves/SIMD, so there is real slack, but **64 is the hard ceiling** — 65 drops occupancy to 3.

⛔ **`RSRC1` IS HARVESTED MECHANICALLY** — `llvm-objcopy -O binary --only-section=.rodata`, byte 48 — **never counted**. A hand-derivation of `edge_cov`'s value gave `0x002C008D` against the real `0x002C00CD`: an SGPR field of 2 (24 granted) where the assembler grants 3 (32). Under-allocating the SGPR file corrupts the vcc carry chain in the address arithmetic and lanes write the **WRONG PIXELS** — a plausible wrong picture, not a fault. Warned in three places in the tree, one from a demonstrated defect. ⚠ Per `gpu.md:1017` there is no oracle for **over**-declaration either. Bite 6 lands the high-water gate, which catches under-declaration only.

---

## 2. THE DIVISION ANSWER — SETTLED, AND EXACT

> ⛔ **CORRECTION, 2026-07-26, from building the reference and the corpus.** This section claims
> `t = bitlen64(D255) - 30` lands in **[10, 31]**. It does not, at either end, and the corpus
> measures **[2, 18]**:
> * **The upper end is unconstructible.** Edge coordinates are bounded at ±2^28 in 16.16
>   (`GPU_EDGE_COORD_MAX`, i.e. ±4096 px), so the largest legal cross product is ~2^24 and
>   `2A ~ 2^40`, giving `t ~ 18`. The "2A just below AREA_MAX ⇒ t = 31" case **cannot be written**
>   and no corpus entry claims it.
> * **The lower end excludes ordinary geometry.** `t ≥ 10` needs an area above ~16500 px², so
>   every triangle smaller than roughly 128×128 falls below it. The reference originally *refused*
>   those as degenerate. A 16×16 frame measures `t = 2`.
> * **`L ∈ {1, 2}` is wrong for the same reason** — smaller frames need a longer normalising
>   shift. The invariant that actually matters is the one `recip32` depends on:
>   `Dh << L ∈ [2^31, 2^32)`. That is what is asserted now; `L` itself is unconstrained.
>
> `t` is clamped at 0 (`t = max(0, bitlen64(D255) - 30)`): when `D255` already fits in 30 bits
> there is nothing to normalise, and a negative shift is meaningless. **Nothing else in the design
> moves** — the shift exists only to put `Dh` in `recip32`'s domain, and it still does.


**`src'_ch = floor((N_ch + D255/2) / D255)` is the EXACT round-half-up of the EXACT rational, computed with one hoisted 32-bit reciprocal per record and 25 branch-free VALU plus one exact 96-bit correction per channel. There is no runtime division, no float, and no fixed-point barycentric anywhere in the interpolation path.**

### 2.1 What is divided, and why it hoists

The barycentric numerators are the three edge functions at the sample point, and `E_A + E_B + E_C ≡ 2A` **identically, for every P** — an algebraic identity, not an approximation. Two consequences cut work before any arithmetic:

* only **two** cross products per pixel; `E_A = 2A − E_B − E_C`. Saves 8 VALU/px and removes *"do the three cross products sum to 2A at 64 bits?"* as a question in the shader.
* **all four channels share ONE denominator** ⇒ one hoisted reciprocal serves all four quotients. The naive *"3 barycentrics × 4 channels = 12 quotients"* is never built.

`2A` is **constant per record in exactly the sense `by−ay` is constant per edge** — which is the whole argument `edge_setup.s:10-13` gives for why rung 9 has no per-pixel divide. Rung 11 inherits it unchanged and needs **no new division primitive**.

⭐ **Hoisting to a CPU-side Cyrius prologue rather than to a third GPU dispatch** costs ~200 ns instead of 28.8 µs, and — more importantly — gives `recip32` **ONE implementation**, shared by the kernel and the host model, instead of a GPU transcription that has to be proven equal to it. Rung 9b bite Bite 0 exists because *"the reference"* had three referents.

### 2.2 The CPU prologue

```
2A     = cross(B-A, C-A)                    exact i64; if 2A < 0, negate the coefficient triple
D255   = 255 * 2A                           <= 255*2^53 = 2.297e18 < 2^61          fits i64
t      = bitlen64(D255) - 30                t in [10, 31]                          <- PROVEN, §2.3
Dh     = (D255 >> t) + 1                    in [2^29+1, 2^30]    (+1 => ONE-SIDED correction)
L      = clz32(Dh)                          in {1, 2}
V      = recip32(Dh << L)                   edgemodel.cyr:97-112 VERBATIM -- the 32-iteration
                                            integer RESTORING loop, exact BY CONSTRUCTION
```

`Dh << L ∈ [2^31, 2^32)` is *exactly* `recip32`'s domain. Direct reuse, no re-derivation.

### 2.3 ⭐ THE TWO SHIFT-MASK HAZARDS ARE STRUCTURALLY UNREACHABLE — DERIVED, WITH A FALSIFICATION ARM

gfx9 masks shift counts to 5 bits. Rung 9 dodged this class entirely because the ±2^28 coordinate guard made `L == 0` unreachable, and `edge_cov.s:102-104` instructs that *"if `GPU_EDGE_COORD_MAX` is ever widened past 2^30, add the explicit `L == 0 → tw = 0` cndmask **IN THE SAME BITE**"*. Rung 11 faces two of them and closes both by construction:

```
GPU_TRI_AREA_MIN = 2^32   =>  D255 >= 255*2^32,  bitlen >= 40  =>  t >= 10   ⇒ t == 0  UNREACHABLE
GPU_TRI_AREA_MAX = 2^53   =>  D255 <= 255*2^53,  bitlen <= 61  =>  t <= 31   ⇒ t == 32 UNREACHABLE
Dh in [2^29+1, 2^30]      =>  L = clz32(Dh) in {1,2}           ⇒ L == 0  UNREACHABLE
                                                                 and 32-L <= 31, never masking to 0
```

⭐ **`L == 0` is unreachable here by the DIVIDER's own construction, not by a coordinate guard** — a strictly stronger guarantee than rung 9's.

⚠ **The `t ≤ 31` bound has exactly ONE step of margin**, and it is enforced by a hard reject. **Widening `GPU_TRI_AREA_MAX` by even one bit REQUIRES the `t == 32` cndmask in the same bite.** Cross-referenced from `syscall.cyr`, `gpu_regs.cyr` and `tri_rgba.s`, exactly the way `edge_cov.s:102-104` documents its own dependency. ⛔ **And unlike rung 9, it gets a falsification arm** (gate 4 of Bite 4): sweep `2A` outside `[2^32, 2^53]` and require the divider to break. *Rung 9's L==0 dependency has no such arm; three adversarial reviewers raised it and each refuted it only by argument.*

Named alternative if the area bound must widen: precompute two mask words on the CPU (`sm = (t==32 ? 0 : ~0)`, `tm = (t==0 ? 0 : ~0)`) and AND them into the funnel — 4 VALU/px, both endpoints resolved where they are trivially testable. Recorded in §9 so widening has a costed path.

### 2.4 The estimate-and-correct proof, and where `GPU_TRI_E_RATIO` actually comes from

```
Nh = floor(N'/2^t)          Dh = floor(D255/2^t) + 1 >= D255/2^t
qh = floor(Nh/Dh)           Q  = floor(N'/D255)
```

* **`qh ≤ Q`**: `Nh/Dh ≤ (N'/2^t)/(D255/2^t) = N'/D255`, and floor is monotone. The `+1` on `Dh` is what makes this **one-sided**, mirroring rung 9's *"THE single correction"*.
* **`Q − qh ≤ 1`**: writing `N' = Nh·2^t + a` and `D255 = (Dh−1)·2^t + c`,
  `N'/D255 − Nh/Dh = (a·Dh + Nh·(2^t − c)) / (D255·Dh) ≤ 2^t(Dh + Nh)/(D255·Dh) ≤ (Q+1)/(Dh−1) ≤ 783361/2^29 = 1.459e-3`.
  A gap below 1 forces the floors to differ by at most 1. **Margin 685×.**
* **The correction test is evaluated at FULL 96-bit width against the untruncated numerator**, so the answer is the exact floor regardless of how the estimate was formed.

⭐ **`GPU_TRI_E_RATIO` is exactly the constant that bounds `Q`, and its HARD CEILING is derived from that inequality:**

```
Q     <= 3 * R * 65025 / 255 = 765 * R
gap   <= (Q+1)/2^29 < 1   =>   Q < 2^29   =>   R < 2^29/765 = 701,000      <- THE HARD CEILING
SHIPPED VALUE: R = 1024, i.e. a 685x MARGIN to the ceiling.
GEOMETRIC MEANING: the maximum SKEW of the attribute frame relative to the evaluation rect.
   For frame == shape and rect == the shape's bbox, the ratio is O(1); it grows with skew
   (A=(0,0), B=(1,0), C=(k,1) evaluated at the bbox corner (k,0) gives lambda_B = k).
```

That is what W4's *"a constant I invented... it has no geometric meaning"* was missing. It is a **reject** with its own reason code so a caller who trips it gets a fix (*shrink the mask or grow the frame*), never a wrong picture — the discipline `GPO_E_WORK` was minted under.

### 2.5 Bit widths, every stage

| quantity | width | worst case | headroom |
|---|---|---|---|
| frame vertex coord (16.16) | i32 | ±2^28 (`GPU_EDGE_COORD_MAX`, reused) | 8× |
| edge-fn coefficients `kx`, `ky` | i32 | ±2^29 | 4× |
| edge-fn constant `k0` | i64 | ±2^58 | 32× |
| `E_i(Pc)` | **i64** | ±2^59 | 16× |
| `2A` | i64 | `[2^32, 2^53]` **enforced** | — |
| `D255 = 255·2A` | i64 | 2.297e18 < 2^61 | 4× |
| `p_i = c_i·cov` | u32 | 65025 | — |
| **`N_ch = Σ E_i·p_i`** | **96-bit (3 dwords)** | `3·min(2^59, R·2A)·65025 < 2^77` | **2^19 = 524,000×** |
| bias `D255>>1` | i64 | 2^60 | — |
| `Nh = N'>>t` | u64 | `(Q+1)·Dh ≤ 783361·2^30 = 2^49.6` | 2^14 |
| `Nh<<L` (divider normalise) | u64 | 2^51.6 | 2^12 |
| `(qh+1)·D255` (correction) | 96-bit | `783361·2^61 = 2^80.6` | 2^15 |
| `q` before clamp | u32 | 783,360 | — |
| `q` after clamp | u8 | 255 | — |

### 2.6 WORST-CASE ERROR VS THE EXACT RESULT: **ZERO**

Not "≤ 1". Zero. `src'_ch` is the exact round-half-up of the exact rational `(Σ E_i·c_i·cov) / (255·2A)` at the exact pixel centre, because `E_i` is exact (64-bit cross product, 16× headroom), `N` is exact (96-bit accumulate, 524,000× headroom), and the quotient is exact by estimate-and-correct verified at full width.

`floor((N + D/2)/D)` is exactly round-half-up **for both parities of `D`**: for even `D` the bias is exact; for odd `D` ties are unreachable (`N/D = k+1/2` needs `2N = (2k+1)D`, odd RHS against even LHS), so it degenerates to round-to-nearest.

⭐ Folding `cov` into the colour (`p_i = c_i·cov ≤ 65025`, 12 VALU once per pixel) makes coverage modulation and the barycentric divide **ONE rounding instead of two** — strictly *more* exact than the shipped `blend_cov` path, at 12 VALU where a separate div-255 costs 14.

**Premultiplication:** inside the frame all `E_i ≥ 0` and `Σ E_i = 2A`, so `N_ch ≤ N_a` for `c_i ≤ a_i`, floor is monotone, `q_ch ≤ q_a` — this generalises `grad_linear.s:9-12`'s two-stop argument to three vertices. Outside, `min(q_ch, q_a)` restores it in 1 VALU. **The host model asserts the `min` never fires on the frame interior; its mutation is to break the frame.**

### 2.7 ⭐ AT WHAT WIDTH WOULD IT BAND — THE NUMBER, AND THE SHORTCUT IT PRE-ANSWERS

The row names *"banding ⇒ fixed-point width of the denominator"*. **That failure mode does not apply to this design — the denominator has no fixed-point width.** That reframing changes what a red burn indicts, which is the whole point of stating it before the flash. But it reads as a dodge without the number, so here is what the cheap shortcut would have cost.

Suppose someone "simplifies" to a `k`-bit fixed-point barycentric, `λ̂_i = floor(E_i·2^k / 2A)`, then `colour = (Σ λ̂_i c_i) >> k`. Max colour error = `3·255·2^-k` byte units:

| k | max error (LSB) | pixels potentially ±1 |
|---|---|---|
| 8 | 2.99 | systematic, visibly banded |
| **11** | **0.373** | **the threshold: systematic ±1 begins here** |
| 16 | 0.0117 | ~2.3% — **1 pixel in 43** |
| 24 | 4.6e-5 | ~0.009% |
| 32 | 1.8e-7 | ~3.6e-5 % |
| **exact (this design)** | **0** | **0%** |

⇒ **`0.16` fixed point — the obvious *"surely 16 bits is plenty"* shortcut, and the one that saves ~40% of the kernel — puts roughly 1 pixel in 43 off by one.** Invisible on a photo; lethal to a byte-identical oracle. Recorded here so it is a re-openable explicit decision, not a mid-bite "fix". (PLANE-11's equivalent statement from the other end: a stepped formulation needs `F ≥ 25` before a band boundary moves less than half a pixel.)

Separately, the **8-bit destination** bands on its own: a gradient of Δ byte-steps across L covered pixels has bands `L/Δ` px wide. Inherent to the format, identical for op `0x04`, and its fix is dithering — a later rung, not more denominator bits.

⛔ **The honest cost, stated plainly rather than buried:** refusing float and refusing fixed-point costs ~408 VALU/px, **~76% of `tri_rgba` and ~37% of the whole per-pixel cost**. A `v_rcp_f32` + 4 `v_fma_f32` interpolator is ~10 VALU. The design is defensible on exactness and on sovereignty; the operator should see that number rather than a slogan.

---

## 3. THE ORACLE — RESTATED, AND STRONGER THAN THE ROW ASKED FOR

⛔ **`gpu.md:818`'s second clause must be rewritten and RATIFIED BEFORE THE BITE PLAN IS EXECUTED, not after the first amber result.** The precedent for restating rather than forcing a false equivalence is already in the tree: `refagree.cyr:22-25` requires that a change to the arc's premier oracle be *"reported to the operator BEFORE rung 9 opens, not discovered at the close."*

⭐ **With this design the change is an UPGRADE, not a degradation.** Op `0x04`'s *shader* cannot be matched — but the **integer reference it is itself measured against** can be, exactly, and that is the stronger claim.

### 3.1 Gate (b) — bit-identity vs `grad_ref_px`, re-derived independently this session

Place the gradient as **ONE record**: coverage = the 4-edge rectangle `[0,w]×[0,h]`; frame `A = (0, 32768) C0`, `B = (w<<16, 32768) C0`, `C = (0, 32768 + den·65536) C1`, with `den = h−1`. ⚠ The `32768` is load-bearing — it puts the frame vertices on pixel-row **centres** so that row `r` samples exactly `λ = r/den`.

```
2A   = Wfx*den*65536            E_C(Pc) = Wfx*(Pc.y - 32768) = Wfx*r*65536       => lambda_C = r/den, x-FREE
E_B  = den*65536*Px   (x-dependent, but A and B carry the SAME colour, so it cancels identically)
N    = (2A - E_C)*c0' + E_C*c1'   with c' = 255*c in the fully-covered interior
q    = floor((N + D255/2)/D255)
     = floor(( c0*(den-r) + c1*r + den/2 ) / den)          after cancelling Wfx*65536*255
```

That is `grad_ref_px` (`gpu.cyr:3007-3025`) character-for-character. **Checked for BOTH parities:**

* **`den` even** — the bias `den/2` is exact in both. Identical.
* **`den` odd** — `grad_ref_px` truncates `den/2` to `(den−1)/2`; mine keeps `den/2` exactly (the surviving factor `65536` makes it representable). Write `S = c0(den−r) + c1·r`. The two differ iff the interval `(S + (den−1)/2, S + den/2]` contains an integer. For odd `den` that interval is `(k, k+0.5]` with `k` integer — **it contains none. Identical.** ⭐ This was the one place the formulas could have diverged by 1 LSB, and it does not.

⭐ **`GPU_GRD_H = 200` ⇒ `den = 199`, ODD — the SHIPPED self-test constants exercise precisely the branch that could have diverged.**

The src-over tail closes the chain: `grad_ref`'s `(sc·255 + dc·ia + 127)/255 = sc + floor((dc·ia+127)/255) = sc + round-half-up(dc·ia/255)`, which `blend_pk.s:55-56` proves equals the f32 `sc + dc·fma(sa, −1/255, 1)` over all 8,421,376 premultiplied triples. And the interior coverage is exactly 255 (a fully-covered pixel accumulates `R_ONE = 65536`, and `(65536·255)>>16 = 255` exactly).

> ⛔ **CORRECTION, 2026-07-26, from building the model.** The specified parity falsification —
> *"`den` odd must still be bit-exact"* — is **unconstructible**. `D255 = 255 · 2A` and `2A` carries
> a `<< 16`, so `D255` always has at least 16 trailing zeros and **can never be odd**. The mutation
> it proposed (bias → `(D255−1)/2`) broke exactly the same 33 pixels as the skip-the-correction
> gate, because both perturb the same rounding boundary — two gates reporting identical failures
> are one gate. Replaced by the **E-clamp refutation** (Decision 4 / §1.3), which the plan wanted
> recorded as a test rather than as prose: clamping each weight into `[0, 2A]` breaks **3246**
> pixels, so the rejection of that design is now measured, not asserted.

### 3.2 The four gates as they will be written into the row

* **(a) PRIMARY, ZERO TOLERANCE** — byte-identical vs a new host-side `tri_ref_px` on a 3-colour corpus. ⚠ **It MUST carry x-varying weight.** On the two-triangle rect `λ` reduces to `y/H` independent of `x`, so **gate (b) provably CANNOT detect an x-direction barycentric error at all** — a shader with `kx` wired to zero passes the gradient reproduction perfectly. **The 3-colour triangle is the SOLE gate on the x term.** (Decision 13)
* **(b) NEW, ZERO TOLERANCE** — byte-identical vs `grad_ref_px`'s formula on the one-record gradient rect, **both parities of `den`, rows 0 and `den` included**.
* **(c) op `0x04`'s SHIPPED SHADER — reported, not gated at 0** — max deviation ≤ 1 per channel with the observed maximum **PRINTED**; row 0 asserted bit-exact (`t = 0.0` and `λ = 0` are both exactly zero). ⭐ **State the direction: where they differ, rung 11 is the MORE ACCURATE of the two.** Op `0x04`'s own header (`grad_linear.s:18`) concedes its last row *"is NOT guaranteed exact"*; the integer path gives exactly 1.
* **(d) WATERTIGHTNESS, ZERO TOLERANCE** — the two-triangle quad is **one record**: one coverage pass, one blend, so a seam is not structurally representable. Gated **at the accumulator** (`edgemodel.cyr` gate-5's pattern), with the per-primitive-composite **mutation** required to go red.

### 3.3 ⛔ AND THE ROW'S THIRD FAILURE MODE MUST BE CORRECTED

*"a seam or double-blend on the shared edge of two triangles ⇒ non-watertight fill rule"* is **mis-attributed**. Two triangles with **different frames** are two records, and that seam is real **src-over conflation**: a boundary pixel with α₁ = α₂ = 0.5 composited sequentially yields `0.75·col + 0.25·dst` where the union is `1.0·col` — **25% destination show-through**. Every 2D rasteriser has it. The corpus gates the one-record case at zero and **MEASURES-AND-REPORTS** the two-record case, with a named future rung (joint coverage resolve), rather than a silent pass. (Decision 14)

---

## 4. D-ROWS — THE DECISIONS THE LADDER MUST NOT SILENTLY DEVIATE FROM

*[[feedback_execute_the_plan_you_wrote]] — name the bite ID and the governing Decisions before coding. Deviating silently is the recurrence that costs the most.*

| # | Decision |
|---|---|
| **Decision 1** | `edge_setup.s` and `edge_cov.s` are dispatched as the **SHIPPED BINARIES, byte-for-byte**. The coverage walk is never transcribed into any new blob. If the fill rule's certification is wanted, the shipped bytes must run. |
| **Decision 2** | **No `v_rcp_f32`, no float, in the barycentric divide.** The power-of-two escape hatch to op-`0x04` bit-identity is **REJECTED** and named as rejected (§1.2). |
| **Decision 3** | The composite tail **is** `blend_premul`'s f32 core — a PROVEN re-expression (8,421,376 triples), not an approximation. The integer `blend_pk` swap is a named, costed fallback; if taken, the `+128` / `(m+(m>>8))>>8` pairing is copied **verbatim**. |
| **Decision 4** | ⛔ **NO E-CLAMP to `[0, 2A]`.** Counterexample in §1.3: it breaks gate (b) at the far corner by ~192 levels on the shipped self-test colours. The numerator's bound comes from `GPU_TRI_E_RATIO`, whose hard ceiling is **derived** (701,000) and whose shipped value is 1024. |
| **Decision 5** | The reciprocal is hoisted to a **CPU-side Cyrius prologue**, not a third dispatch. `recip32` has ONE implementation, shared by kernel and host model. |
| **Decision 6** | `RSRC1` harvested mechanically (`llvm-objcopy` byte 48), never counted. `tri_rgba` is authored at `RSRC2 = 0x190` so `gpu_blend_cov_run` dispatches it **unmodified** — no dispatcher change, no new PM4. |
| **Decision 7** | Every **per-lane** early-out is an EXEC mask or a `v_cndmask`, **never `s_cbranch_vccz`**. The 4-channel loop is **wave-uniform** (`s_cbranch_scc1`) and that is explicitly NOT the burn-1 trap. Keep this distinction in the wording; it is lost in summaries. |
| **Decision 8** | `t ∈ [10, 31]` and `L ∈ {1, 2}` by `AREA_MIN = 2^32` / `AREA_MAX = 2^53`, so **both** shift-mask endpoints and `L == 0` are structurally unreachable — **documented as a DEPENDENCY at all three sites, WITH a falsification arm**. Widening `AREA_MAX` by one bit requires the `t == 32` cndmask **in the same bite**. |
| **Decision 9** | **No rung-11 arena slot below `0xE0000`.** And `GPU_EDGE_PREP_SUBOFF` moves out of the S12 snapshot in Bite 0 regardless. |
| **Decision 10** | **No new work constant is minted.** `GPU_EDGE_WORK_MAX = 2^26` (measured) governs D1/D2 unchanged because they are literally the same code. `GPU_TRI_MAX_PIXELS = 2^20` is an **ARENA SIZE** and is labelled as such, not dressed as a design bound. |
| **Decision 11** | `edge_id = 0` does **not** silently mean "derive". An explicit flags bit does. Reject, never guess. |
| **Decision 12** | **ONE reference**, host-side, shared: `gpu-test/triref.cyr`, which **INCLUDES** `refraster.cyr` and does not re-transcribe it. |
| **Decision 13** | The 3-colour triangle is the **SOLE** gate on the x term. The gradient rect provably cannot detect an x error. The corpus says which is which, and the mutation proves it. |
| **Decision 14** | The two-record seam is **REPORTED, not gated at zero**, and `gpu.md:818`'s third failure mode is corrected before the flash. |
| **Decision 15** | Every gate names its mutation, and **the mutation is run**. A gate that cannot fail is not a gate. |
| **Decision 16** | **The burn PRINTS the real cost.** No VALU count in this plan is a measurement. `blend_pk.s:95-101` records a hand-counted estimate that was wrong by more than 2×, and its own conclusion applies verbatim. |

---

## 5. ORDERED SUB-BITES

**Legend:** 🆓 = zero burns (host or QEMU) · 🔥 = needs iron.

---

### Bite 0 🆓 QEMU — the arena overlap, filed and fixed *(governs: Decision 9)*
**Lands:** `GPU_EDGE_PREP_SUBOFF` moves `0xD0000` → `0xA8000` (8 KB, in the 96 KB window above the S3 tiles). `gpu_regs.cyr:1183`'s stale *"well clear of every other slot (highest is BR2_SRC ending 0x79600)"* corrected to name the S12 extent explicitly. `gpu_regs.cyr:949-950`'s *"[0xC0000, 0x200000) is 1.25 MB with nothing mapped into it"* corrected.
**Plus `scripts/check-arena-extents.sh`:** a new gate driven by an explicit `# EXTENT: <bytes>` annotation beside each `_SUBOFF`. Slots with a declared extent are pairwise **range**-checked; undeclared slots are skipped and **counted, with the count printed**. Annotate the slots whose extents are known today (S12 `0x20000`, S3 `0x28000`, EDGE_PREP `0x2000`, COV_MASK, BR_SRC, BR2_SRC, the shader slots, and rung 11's three).
**Verified by:** the new gate goes **RED on the pre-fix tree** (mutation: revert the move) and green after. `check.sh`'s existing value-only gate stays — it is orthogonal and it cannot rot.
**Why first:** `check.sh:56-68` is structurally blind to extent overlap by design, and with `VM_CONTEXT0` disabled an out-of-bounds store lands somewhere **real**. **Two of the three candidate designs proposed slots inside the live S12 buffer and all would have shipped green.** File this regardless of rung 11.

---

### Bite 1 🆓 DOC — restate the rung-11 oracle, and RATIFY IT *(governs: Decision 2, Decision 13, Decision 14)*
**Lands:** `gpu.md:818`'s oracle column replaced with §3.2's four gates; the third failure mode corrected per §3.3; the `v_rcp_f32` escape hatch recorded as **REJECTED**; `gpu.md:907`'s `GPU_OP_SUPPORTED` claim reconciled (**`0x11F` → `0x31F` at rung 11**; `0x1F1F` is the projected end state including `0x05`-`0x07` and `0x0A`-`0x0C`); `gpu.md:907`'s sketched record shape (`vtx_slot · vcount · rt_handle · dstxy · wh · flags`) replaced by the inline-frame record of Bite 5, with the deviation recorded the way 9a recorded its `dstxy` deviation.
⛔ **This bite must be RATIFIED BY THE OPERATOR before Bite 7 emits one instruction.** `refagree.cyr:22-25` requires an oracle change be reported before the rung opens. Building first and explaining after would be quietly redefining the rung's own success criterion — the same class as the five `GPO_E_EDGEBUF` rejects that *"were MINE"*.
**Also flag, do not work around:** ⚠ **`h = 1` is a LIVE latent bug in op `0x04`.** `syscall.cyr:1571` accepts `h ≥ 1`, but `den = h−1 = 0` gives `v_rcp_f32(0.0) = +Inf` and `t = 0.0·Inf = NaN`; `grad_ref_px` divides by zero on the same input. Neither is guarded. Any calibration sweep over `h` hits it. Its own bite, in op `0x04`'s file.
⚠ **And the doc drift, confirmed:** `gpu_regs.cyr:1151` says the `edge_cov` blob is *"133 dwords / 532 B"* and `gpu.cyr:2453` says *"58/58 and 133/133"*, but `edge_cov_write` contains exactly **135** `store32` calls with the last at `+536` and `return 135`, and `edgeasm.cyr:917` compares 135. Harmless at 4 KB slot spacing; fix it now, because rung 11 will copy the comment style.

---

### Bite 2 🆓 HOST — `gpu-test/triref.cyr`, THE reference *(governs: Decision 12)*
**Lands:** `tri_ref_px(prep, px, py, cov, dst)` implementing §2 exactly — `E = kx·Px + ky·Py + k0` in i64, `N = Σ E_i·c_i·cov` in exact Cyrius i64 (the reference may use i64 freely; only the *model* is register-width-constrained), `floor((N + D255/2)/D255)`, `min(q,255)`, `min(q_ch,q_a)`, then the integer src-over. **INCLUDES `refraster.cyr`** and reuses its edge machinery for coverage — it does not re-transcribe it.
**Verified by:** `cpuref`/`refagree`/`tileown` all still exit 95, unchanged; plus a direct check that `tri_ref_px` on the gradient frame reproduces `grad_ref_px`'s formula for `den ∈ {2..256}` **and both parities**, exhaustively over `y` and over 64 random `(c0,c1,dst)` triples.
⚠ Cyrius traps this bite must respect, every one of which has cost this arc real time: `>>` is **LOGICAL** and `>>>` is arithmetic (inverted from C) — `sar32` exists at `edgemodel.cyr:66` for exactly this; module-scope `var X[N]` is `N×u64` in an INCLUDED module but **N BYTES** in a top-level program (the `accrow[64]` latent fatal was this, **IN THE ORACLE**); `load32` **zero-extends**, so every coordinate read back needs an explicit sign-extend; no chained `else if`.

---

### Bite 3 🆓 HOST — itemise and author the 16-case TRI corpus *(governs: Decision 13, Decision 15)*
**Lands:** one table in `triref.cyr` driving **both** the reference and the `#92` records from a single source of truth. Enumerated here so the number is never inherited un-itemised:

| # | case | why it is in |
|---|---|---|
| T1 | 3-colour triangle, frame == shape, **x-VARYING weight** | ⭐ the primary gate, and the **only** x-term gate |
| T2 | T1 with vertex order **ROTATED** | rotation invariance — bit-identical is required, and this is the test that kills TRIPREP's renormalisation |
| T3 | T1 **mirrored in x** | x-term sign |
| T4 | flat colour (`c0 == c1 == c2`) | the row's own first failure mode; a **CONTROL** for T1, never a pass-gate on its own |
| T5 | op-`0x04` gradient rect, `den` **EVEN** (`h = 64`) | gate (b), even parity |
| T6 | op-`0x04` gradient rect, `den` **ODD** (`h = 200`, the shipped `GPU_GRD_H`) | gate (b), the parity branch that could have diverged |
| T7 | two-triangle quad, **ONE record** (rect shape + one frame) | gate (d) — structurally seamless |
| T8 | two triangles, **TWO records**, different frames | the honest seam **MEASUREMENT** (reported, not gated at 0) |
| T9 | decoupled frame: 5-edge star shape, large containing frame | the decoupling itself |
| T10 | skew frame at ratio ≈ 512 | inside `E_RATIO` |
| T11 | skew frame at ratio ≈ 2048 | must **REJECT** with `GPO_E_FRAME` — falsification |
| T12 | `2A` just above `AREA_MIN` ⇒ **`t = 10`** | the `t` lower endpoint |
| T13 | `2A` just below `AREA_MAX` ⇒ **`t = 31`** | ⭐ the `t` upper endpoint — both shift-mask arms exercised |
| T14 | alpha-varying triangle (`a0 ≠ a1 ≠ a2`) over a non-black dst | the src-over tail with varying alpha |
| T15 | premultiplication boundary: `c == a` exactly at each vertex | the `min(q_ch, q_a)` path |
| T16 | **engineered numerator**: `N'` just below a multiple of `D255` | forces the `+1` correction to **FIRE** |

⚠ **T16 is not optional.** The correction margin is 1.459e-3, i.e. roughly 1 quotient in 685 — over a small corpus you can easily see **zero** firings, and a gate that cannot fail is not a gate. The firing **RATE** is printed, the way `edgemodel` prints the walk's trip count.
⚠ **Every seeded vertex must satisfy `c ≤ a` per channel.** `CHECK_PREMUL` is reserved and rejected (`syscall.cyr:996-999`), and `syscall.cyr:955-957` already warns straight alpha washes out **SILENTLY, never an error**. With three independent vertex colours the odds of a test author getting this wrong are materially higher than with two stops. The corpus asserts it.

---

### Bite 4 🆓 HOST — **THE CORRECTNESS GATE.** `gpu-test/trimodel.cyr` *(governs: Decision 4, Decision 8, Decision 15)*
**Lands:** the *entire* `tri_rgba` algorithm, in Cyrius, **at shader register widths** — every intermediate explicitly masked through `u32()`/`sar32()`/`clz32()`, the 96-bit accumulate as three explicit dwords, the funnel as explicit shift/or, the `edge_cov.s:105-121` divider verbatim, the correction as the 96-bit add-and-compare. Byte-diffed against `triref.cyr`.

**Gates (all seven required):**

| gate | claim | ⭐ the MUTATION that must turn it RED |
|---|---|---|
| 1 | all 16 corpus cases + 200 random 3-colour triangles: **0 differing bytes** | wire `kx` to zero → **T1/T3 red, T5/T6 STAY GREEN** (this simultaneously proves gate (b) cannot police the x term, Decision 13) |
| 2 | the quotient vs the exact rational, swept over `2A ∈ [2^32, 2^53] × E ∈ [−R·2A, R·2A] × p ∈ {extremes}` | skip the `+1` correction → T16 red |
| 3 | **FALSIFICATION — the parity bias.** `den` odd must still be bit-exact | truncate the bias to `(D255−1)/2` → **T6 red, T5 green** |
| 4 | **FALSIFICATION — the shift-mask dependency.** `2A` outside `[2^32, 2^53]` **MUST** break the divider | force `t = 32` → T13 red; force `t = 0` → T12 red; force `Dh = 2^31` (⇒ `L = 0`) → the divider breaks. **If nothing breaks, `AREA_MIN`/`AREA_MAX` are decoration.** |
| 5 | **FALSIFICATION — i64 overflow.** `E_A + E_B + E_C == 2A` computed with **three INDEPENDENT cross products** must hold below ±2^28 and **FAIL** above ±2^30 | ⚠ the shader *derives* `E_A`, which makes the identity structural and vacuous — the arm computes all three independently or it proves nothing |
| 6 | **the E-CLAMP refutation, recorded as a test.** Adding TRIPREP's `Ê = clamp(E, 0, 2A)` **MUST** turn T5/T6 red | this is a mutation that *documents a rejected design*; without it §1.3's counterexample is prose, and all three judges recommended the clamp |
| 7 | the **`min(q_ch, q_a)` premultiplication restore NEVER fires on the frame interior**, and the seam measured **at the accumulator** over T7 | break the frame (move a vertex inside the mask) → the `min` must start firing |

⚠ ⭐ **`trimodel.cyr` is a TOP-LEVEL PROGRAM and `refraster.cyr`/`triref.cyr` are INCLUDED modules — `var X[N]` means N BYTES in one and `N×u64` in the other.** Rung 9b shipped a real instance of this (`var accrow[64]`, correct at W=64, corrupting `crx`/`crd` at any W>64, **fatal in the ORACLE**). `scripts/check-array-sizing.sh` covers function-local overruns only; this one is on the author.

**Why this bite is the keystone:** it converts *"the algorithm is exact"* from three designs' prose into a Cyrius artifact diffed against the artifact that **is** the oracle, **at zero burns, before one instruction is assembled**. If Bite 4 is green and iron is red, the fault is in the **emission**, not the **algorithm**. That split is why 8 of 11 rung-9b bites cost zero burns.

---

### Bite 5 🆓 QEMU — the `#92` ABI *(governs: Decision 10, Decision 11)*

**The record — field mask `0xFFFB`, 15 of 16 dwords:**

```
dword  byte  field
  0      0   op = 0x09  GPU_OP_TRI_RGBA
  1      4   flags   bit0 = GPU_TRI_FLAG_DERIVE (synthesise the frame's 3 edges); else MUST be 0
  2      8   RESERVED, MUST be 0        <- the surviving forward-compat dword (rt_handle / Trap 3)
  3     12   edge_id  #86 slot of 16-byte edges; MUST be 0 iff FLAG_DERIVE
  4     16   wh    = (h<<16) | w
  5     20   dstxy = (dy<<16) | dx      ⭐ DEFINED for this op, unlike 0x08
  6-11  24   vx0 vy0 vx1 vy1 vx2 vy2    i32, 16.16 screen space
 12-14  48   c0 c1 c2                   premultiplied ARGB, A in bits 24-31
   15   60   n_edges | (rule << 16)     MUST be 0 iff FLAG_DERIVE
```

**Why no vertex slot** — three reasons in order of weight: **(1) it fits**, with a reserved dword to spare; **(2)** a slot costs three new failure modes for zero function (a third slot-validity check, a third pairwise alias check, a third `gpo_slot_bytes` rule) and rung 9a's first battery run caught four real defects, one of them an alias check in the wrong ORDER relative to a size check; **(3) precedent** — op `0x04` carries its colour stops **inline** for exactly this reason (*"NO SOURCE BUFFER AT ALL"*, `grad_linear.s:4-7`) and `gpo_slot_field` returns 0 for it. Op `0x09` generalises op `0x04`; it generalises its ABI shape too. ⭐ And a 64-triangle mesh with `FLAG_DERIVE` is **one `#92` call, 64 self-contained records, ZERO shm slots**.

**Destination: the BACK BUFFER at `dstxy`** — the architectural fork, **named and resolved rather than discovered mid-bite**. ⛔ `GPU_RT_REGION_OFF` / `rt_handle` (Trap 3) **do not exist anywhere in `kernel/core/*.cyr`** — grep returns nothing. Trap 3 is gated on rung 6's arena audit, which has not burned; landing a 256 MB region and a new handle namespace inside a Flash-1 bite is the big-bang this plan forbids; and gate (c) needs the back buffer anyway, because that is where op `0x04` writes. ⇒ `gpo_validate`'s generic geometry block (`dx+w ≤ fbw`, `dy+h ≤ fbh`, **REJECT never clip**) applies verbatim. ⚠ Note the deviation from op `0x08`, which explicitly *refuses* `dstxy` because it never touches the framebuffer. The two are consistent, not contradictory.

**Per-op flags:** introduce `gpo_flags_known(op)` returning `0x00` for every existing op and `0x01` for `0x09`, so *"a flag that is accepted and ignored"* stays impossible per-op. `GPU_OP_FLAGS_KNOWN` becomes its default.

> ⛔ **CORRECTION, 2026-07-26, from implementing the validator.** `GPU_TRI_AREA_MIN` and
> `GPU_TRI_AREA_MAX` below are wrong by exactly 2^16, from the same lifted-vertex assumption
> corrected in §2. Only the constant term and `2A` carry the `<< 16`; `kx`/`ky` already multiply a
> 16.16 sample point. So `2A = cross << 16`, and:
> * **`AREA_MIN` is 2^16, not 2^32.** A 0.5 px² frame is `cross = 1`, i.e. `2A = 2^16`. The stated
>   2^32 demands `cross ≥ 2^16`, an area of 32768 px² — it would have **rejected every triangle
>   smaller than about 256×256**, which is most of them. The battery carries a 16×16 frame as an
>   ACCEPT case specifically to pin this.
> * **`AREA_MAX` is 2^42, not 2^53.** Coordinates cap at ±2^28 in 16.16 (±4096 px), so `cross ≤ 2^26`
>   and `2A ≤ 2^42`. The stated 2^53 sits above anything constructible and could never have fired.

**New constants and codes:**
```
GPU_TRI_AREA_MIN   = 2^32     frame area >= 0.5 px^2       -> GPO_E_AREA  (22)
GPU_TRI_AREA_MAX   = 2^53     frame area <= 2^20 px^2      -> GPO_E_AREA
GPU_TRI_E_RATIO    = 1024     max |E_i| / |2A| over the 4 mask-rect corners
                                                            -> GPO_E_FRAME (23)
GPU_TRI_MAX_PIXELS = 2^20     w*h; ⚠ AN ARENA SIZE, NOT A DESIGN BOUND
                                                            -> GPO_E_TRIDIM (24)
GPU_OP_SUPPORTED   0x11F -> 0x31F   (bit 9 = code 0x09)
reused verbatim: GPO_E_DIM 6, GPO_E_ARM 7, GPO_E_RESERVED 12, GPO_E_EDGEBUF 16, GPO_E_BOUNDS 5,
                 GPO_E_RULE 18, GPO_E_COORD 20, GPO_E_WORK 21
```
⭐ **No new work constant is minted (Decision 10).** D1/D2 are literally the shipped blobs, so `GPU_EDGE_WORK_MAX = 2^26` (measured on iron, `gpu.cyr:84-104`) governs them unchanged; `GPU_TRI_MAX_PIXELS = 2^20` bounds D3 and **is** the coverage scratch size. Worst-case total (`w·h = 2^20`, `ne = 4`) ≈ 5 ms against the 100 ms watchdog — **20× margin**, and the burn prints the real number.
⚠ `GPU_TRI_MAX_PIXELS` is labelled in the source as what it is: *"this is the free window above the S12 snapshot, not a design decision. Callers tile. The fix is a larger arena or Trap 3."*
⭐ **`GPU_TRI_AREA_MAX` is not the binding constraint on any legal draw**: the largest legal mask is 2^20 px, and a frame that covers it has area ≤ 2^20 px² = `AREA_MAX`. It binds only *decoupled* frames far larger than their mask, which is extrapolation, which `E_RATIO` already governs. The two caps agreeing is a checkable invariant, not a coincidence.

**`gpo_validate_tri(rec, fbw, fbh)` — ORDER MATTERS, and the order is `gpo_validate_edge`'s:**
```
1.  shared reserved-dword + flags sweep (ENTER AT gpo_validate, never the sub-validator --
    9a's battery caught three defects from skipping exactly this)
2.  w,h >= 1 ; <= GPU_COV_MAX_DIM ; w*h <= GPU_TRI_MAX_PIXELS          GPO_E_DIM / GPO_E_TRIDIM
3.  dx+w <= fbw ; dy+h <= fbh          REJECT, never clip              GPO_E_BOUNDS
4.  all six frame coords within +-GPU_EDGE_COORD_MAX                   GPO_E_COORD
    ⚠ load32 ZERO-EXTENDS -- sign-extend BEFORE comparing, or every legal negative coordinate
      is rejected. At Bite 3 this mutation was caught ONLY by a NEGATIVE BOUNDARY case; a battery
      of rejects alone passed for the wrong reason.
5.  2A = cross(B-A, C-A) ; AREA_MIN <= |2A| <= AREA_MAX                 GPO_E_AREA
6.  E_i at the FOUR CORNERS of the mask rect, 12 exact i64 evaluations;
    max |E_i| <= GPU_TRI_E_RATIO * |2A|                                GPO_E_FRAME
    (E is affine, so its extremes over a rectangle are AT the corners -- exact, not sampled)
7.  if !FLAG_DERIVE: rule == NONZERO (GPO_E_RULE) ; 3 <= ne <= GPU_EDGE_CAP ; slot valid /
    non-PMM / large enough (GPO_E_EDGEBUF) ; w*h*ne <= GPU_EDGE_WORK_MAX (GPO_E_WORK) ;
    per-edge coordinate walk (GPO_E_COORD)
    if  FLAG_DERIVE: edge_id, n_edges and rule MUST all be 0           GPO_E_RESERVED
8.  gpu_tri_arm() != 1                       residency LAST            GPO_E_ARM
```
**Verified by:** ~16 new records through the **SHIPPED** `gpo_validate` under `#ifdef TRI_ABI_SELFTEST` (never a host copy — that is the ATOM_DRY defect and one implementation is the only real defence): one well-formed, one per reject above, the `FLAG_DERIVE with n_edges != 0` case, and a **negative-coordinate BOUNDARY** case. `scripts/tri-abi-smoke.sh` green in QEMU, **plus a mutation check per reject** that deleting the bound fails the new case.
⛔ **In the SAME bite:** `gpu_tri_arm()` returns 0 until Bite 8, so the well-formed record's expectation is `GPO_E_ARM`, flipped to `0` in Bite 8. A known-red gate carried into a burn is how a real regression gets waved through.

---

### Bite 6 🆓 HOST — `edgeasm.cyr`: the VGPR high-water gate *(governs: Decision 6)*
**Lands:** ⭐ **`edgeasm` computes the emit list's maximum VGPR index mechanically** — it already knows every operand it encoded — and asserts it against the value the committed `.amdhsa_next_free_vgpr` implies. Runs over `blend_cov`, `edge_setup` and `edge_cov` first, where the answers are known (12 / 32 / 56), then over `tri_rgba` in B7.
**Verified by:** the three shipped blobs report exactly their committed values, **plus a mutation** — bump one operand to `v56` in the `edge_cov` list and the gate must fire.
⭐ `gpu.md:1017` calls VGPR pressure *"the largest unmeasured assumption and there is no oracle for it"* because `RSRC1` is not GRBM-readable. This converts silent **UNDER**-declaration — a spill to scratch agnos has never configured, i.e. a **fault**, not a slowdown — into a host-side gate at zero burns. ⚠ It catches under-declaration **only**; over-declaration stays silent and costs occupancy. Say so in the gate's own output.
**Also lands:** whatever `asmagree` classes `tri_rgba` needs that are not yet byte-diffed against `llvm-mc`. ⚠ Per Bite 5's own provenance note, that obligation is **weaker than it looks**: for an instruction appearing in no shipped shader, `llvm-mc` agreement proves *"the encoder agrees with LLVM"*, **not** *"these bytes work on gfx90c"*. ⭐ This design needs **no such instruction** (§1.7), which is a deliberate property and not luck.

---

### Bite 7 🆓 HOST — author and byte-verify `kernel/shaders/tri_rgba.s` *(governs: Decision 1, Decision 6, Decision 7)*
**Lands:** the blob (documentation of record, per `gpu.cyr:2243-2246`), emitted through `edgeasm.cyr` into a `store32` table.
**Verified by:** every dword byte-diffed against `llvm-mc -mcpu=gfx90c` on the same source; the per-instruction table printed so a human can check operand order — especially the **REV shift semantics** (amount in `src0`, value in `vsrc1`) and `v_addc_co_u32`'s inline-0-in-`src0` / VGPR-in-`vsrc1` constraint; **the Bite 6 VGPR high-water gate green**; `RSRC1`/`RSRC2` derived mechanically from the `.amdhsa_kernel` descriptor.
⛔ **`edge_setup.s` and `edge_cov.s` ARE NOT OPENED IN THIS BITE.** Decision 1.
**Emit-list discipline:** ~200 dwords with the wave-uniform channel loop, **two** backward branches (channel loop, and none other) plus the two exec-mask forward exits. Long straight-line code is mechanically safe under a byte-diff; more resolved branches is exactly the silent-corruption surface Bite 4-of-9b was written against.

---

> ⚠ **BITE 7 WAS SPLIT, DELIBERATELY AND ON THE RECORD.** It specified the blob authored through
> `edgeasm` AND byte-diffed against `llvm-mc` in one step. The shader came in at **269 dwords**, and
> re-emitting 269 instructions by hand through `edgeasm` is a bite-sized task in its own right —
> folding it in here is exactly the big-bang this plan forbids elsewhere.
> * **Landed now:** the `.s` source, the assembled blob, `RSRC1`/`RSRC2` harvested from the
>   descriptor, the generated `tri_rgba_write` table, and `scripts/shader-blob.sh` — which closes
>   the *"kernel table ≠ assembled source"* gap mechanically. Calibrated on the shipped, iron-proven
>   `edge_cov` blob (135 dwords match) and mutation-tested both ways (a corrupted dword and a
>   deleted one both go red). Wired into `check.sh` for all three blobs.
> * **Deferred to its own bite:** the sovereign `edgeasm` re-emit. ⛔ The tree's standing bar
>   (`gpu.cyr:2468`) is **two independent assemblers**, and only one has run. **This blob must not
>   reach a hardware run until that lands**, and the note above `tri_rgba_write` says so at the site.

### Bite 8 🆓 QEMU — the kernel seam *(governs: Decision 5, Decision 9, Decision 10)*
**Lands:** the three arena constants of §1.5 with `# EXTENT:` annotations; `GPU_COMPUTE_PGM_RSRC1_TRI` harvested; `tri_rgba_write()` beside `edge_cov_write`; `gpu_tri_arm()` as the 5-gate peer body (`gpu_cov_arm`, `gpu.cyr:2935-2945`) writing the blob then `gpu_mfence()`; the **CPU prologue** of §2.2 inside `gpu_tri_rgba(rec…)`, sharing `recip32` with the host model; `gpu_tri_rgba()` issuing the three dispatches of §1.4; `GPU_SHADER_SLOT_BASE`'s stale *"8 slots"* comment updated.
⭐ **The prep-record oracle lands HERE, at zero burns, not on the flash.** The kernel prints its 128-byte record; `/bin/gputri` prints its own host-computed record from the same inputs in the same boot; they are diffed field by field. ⚠ **NOT a kernel read-back of what it just wrote — that is echo, not answer.** Rung 9b spent a whole iron oracle on the equivalent; this design gets it free because the prologue is CPU-side Cyrius.
⛔ **In the SAME bite:** flip `tri_abi_selftest`'s `GPO_E_ARM` expectation to `0`.
⛔ **Do NOT touch** `gpu_blend_cov_run`'s duplicated `TCWB` packets or its ungated `ACQUIRE_MEM`s. Removing a coherence packet is the class that cost eight burns at C2g-1.
**Verified by:** `check.sh` (both arena gates), `scripts/tri-abi-smoke.sh` green, the prep-record diff green in QEMU.

---

### Bite 9 🆓 QEMU — `/bin/gputri --tri`, and wire it into the burn *(governs: Decision 15)*
**Lands:** the corpus loop with per-case alloc / `0xA5` prefill / dispatch / readback / compare (slot *i* is a **fixed 2 MB window**, so the prefill is mandatory); a per-case **FNV-64 digest of the reference output printed by BOTH `triref` and `gputri` and gated on equality** — the only check that catches a `--agnos` codegen divergence making both sides wrong together, which `gpu.md:1019` names by name; and **negative controls N9-N16, each a gate that must FIRE or the tool exits 86 and can never reach 95:**

| control | what it refuses to let pass |
|---|---|
| **N9** | comparator calibration — a deliberately poisoned copy must compare unequal |
| **N10** | the sentinel is observable: prefill, read back **without** dispatching |
| **N11** | **colour-variation floor** — ≥3 cases where the reference carries ≥64 distinct values. ⭐ Without this, a **flat-colour** shader (the row's own first named failure mode) passes any single-colour case byte-exactly |
| **N12** | ⭐⭐ **x-variation floor** — ≥1 case whose reference varies **along a row** by ≥32 levels. **This is the only thing standing between an x-term-wired-to-zero shader and a green run** |
| **N13** | the `+1` correction **fired at least once** across the corpus; the count is printed |
| **N14** | the `min(q_ch, q_a)` premultiplication restore fired at least once (outside the frame only) |
| **N15** | the same case twice in one boot, byte-identical |
| **N16** | the in-tool reference digest equals the host `triref` digest |

**Exit-code contract**, mirroring `gputri --cov`'s: **95** all exact and all controls fired · **100** no GPU / no carveout (QEMU) · **96** seam live, shader not resident · **93/92/91** mismatch classified colour / coverage / tgid-mapping · **88** UNTOUCHED · **86** a control failed · **85** digest mismatch · **90** named `#92` fault · **84** unknown arg.
⚠ **Wiring is part of the bite**: `stage_one agnos/gpu-test gputri.cyr gputri` in `scripts/stage-tools.sh` and the `gputri)` arm in `burn-prep.sh`'s tool map must already cover the rebuilt binary, or the burn runs a stale one against a fresh kernel. [[feedback_ifdef_bites_name_their_build_flags]] — this bite names `TRI_ABI_SELFTEST` and any `BURN_*` flag it needs, and builds through `burn-prep.sh`, never a hand-rolled script.

---

### Bite 10 🔥 IRON — **BURN 1. THREE ORACLES, ONE FLASH, DELIBERATELY NARROW.**
Run in this order so a red localises to one of three things instead of to *"the shader"*:

1. **`gputri --tri96`** — a ~40-instruction smoke kernel exercising **the composite arithmetic the whole design rests on**, against host-computed known answers written into a readback slot: the signed-`mul_hi` identity at all four sign quadrants; one full 96-bit `Σ E_i·p_i` accumulate; the `96→64` funnel at **both** `t = 10` and `t = 31`; one complete quotient with the correction forced to fire and forced not to fire. **Gate: every value exact.** If red, the arithmetic is 40 instructions wide, not 200.
   ⭐ **No new opcode is under test here, deliberately** — every instruction has run on agnos. What is under test is the *composition*, which is where a red would otherwise present as "wrong colours".
2. **`gputri --tri`** — the 16-case corpus at ≤ 256×256 with `ne ≤ 8`, plus N9-N16. **Gate: 95.**
3. **`gputri --gradcmp --bench`** — gate (c) against the live op-`0x04` output (max dev PRINTED, row 0 asserted bit-exact), plus the cost sweep: `gpu_last_wait_us` per dispatch at 3-4 mask sizes, **the real per-pixel cost**, and rung 10's crossover **re-measured for op `0x09`**.

**Additions specific to this burn:** `gpu_ring_breadcrumb()` immediately before each `DISPATCH_DIRECT` (it exists at `gpu.cyr:209-217` but its only callers are the fault-net test, so a hang today gives `rptr`/`wptr` and names no packet); and `gpu_last_wait_us` printed per dispatch, so the coverage-mask memory round-trip (§8.4) is separated from the colour work.
**Capture:** `run /bin/gputri --tri > f.txt` on agnos-fs; the operator mounts `/dev/nvme0n1p2` ro to copy out. [[reference_klug_text_burn_capture]] — text, not photos.

**Pre-registered failure table** (rung 10's lesson: pre-register the number, then be wrong in public):

| observation | indictment |
|---|---|
| all-sentinel | the post-dispatch TC write-back, or `gpu_tri_arm` |
| right shape, **flat** colour | `kx`/`ky` reached the shader as zero — the prep record's field ORDER (§8.3), not the interpolator |
| right shape, colour wrong **only near one vertex** | the `E_A = 2A − E_B − E_C` derivation, or a sign fixup in the `mul_hi` identity |
| **wrong on a SIZE BAND, plausible elsewhere** | ⭐ the `t` funnel. T12/T13 bracket it; this is the case-14 shape and the highest-probability silent defect in the blob |
| colours off by exactly 1, everywhere | the bias, or the correction never firing (check N13's printed count first) |
| ±1 vs op `0x04` only | ⭐ **NOT A DEFECT.** That is gate (c)'s stated tolerance and rung 11 is the more accurate side |
| alpha right, RGB wrong | the wave-uniform channel loop's shift, or `qa` liveness |
| a sheared image | the prep record's `dst_pitch`/`w` field order |

**Pre-registered cost model, so it can be falsified:** `tri_rgba` ≈ 540 VALU/px; total ≈ 1000-1140 VALU/px ≈ 4.0-4.5 ns/px at judge 3's calibration (1 VALU ≈ 4.0 ps, back-solved from the measured `0.0005953 µs/(px·edge)`); three dispatches ≈ 86.4 µs fixed; CPU barycentric + blend ≈ 70 ns/px. ⇒ **crossover ≈ 1300 covered px (a 36×36 region), against rung 10's measured 1751 for coverage alone.** ⚠ **Rung 10's own pre-registration was wrong by 7× in the GPU's favour. This one can be wrong the other way.** Decision 16.

---

### Bite 11 🔥 IRON — **CONTINGENCY ONLY.** *Not in the Flash-1 budget.*
Fires **only** if Bite 10 is red in a way `--tri96` did not localise, or if the measured cost demands the uniform-alpha fast path (§9). Envelope-raising rides Bite 10's `--bench` data and needs no separate flash.

---

## 6. HOW THE PLAN ANSWERS EVERY SURVIVING REFUTATION

| # | Refutation | Answer |
|---|---|---|
| **J1/J2/J3-A** | The rung's second oracle is unachievable; a correct shader will show deltas of 1 and a flash will be spent hunting a bug that does not exist. | **Accepted, and UPGRADED rather than degraded.** Bite 1 replaces it with §3.2's four gates, of which (b) is bit-identity vs `grad_ref_px` — re-derived here for both parities, with the shipped `den = 199` exercising the branch that could have diverged. Ratified before B7. |
| **J1/J2/J3-B** | TRIPREP/PLANE-11 transcribe `edge_cov`'s walk into a new blob; the 20/20 iron certification does not transfer. | **Avoided structurally.** Decision 1: both blobs are dispatched as the shipped binaries. The fill rule is not *"the same rule"*, it is **the same machine code**. |
| **J1/J2/J3-C** | Both losing designs place arena slots inside the live S12 snapshot, and `check.sh` cannot see it. | **Verified independently and fixed in Bite 0**, including the *pre-existing* `GPU_EDGE_PREP` overlap, plus a new extent-aware gate. Rung 11's slots are all above `0xE0000`. |
| **J1-G1 / J2-1 / J3-G1** | *"Clamp `E_i` to `[0, 2A]` — the highest-value graft in either losing design."* All three judges. | ⛔ **REFUTED, §1.3.** It breaks gate (b) at the far corner by ~192 levels on the shipped self-test colours, because the gradient frame's `E_A` is legitimately negative there while the **sum** is correct. `E_RATIO` survives, but with its ceiling **derived** (701,000) and a geometric meaning, which is what W4 was actually missing. Bite 4 gate 6 keeps the refutation as a running test. |
| **J3-F5 / J2-5** | `v_mul_hi_i32` (VOP3 `0x287`) has never executed on agnos; its failure mode is wrong colours on half the triangles — a plausible picture, not a fault. | **Accepted, and inverted.** The identity `mul_hi_i32(a,b) = mul_hi_u32(a,b) − ((a>>>31)&b) − ((b>>>31)&a)` is the **shipping** path (+3 VALU/product), re-derived here. `0x287` is a later measured optimisation behind its own first-burn oracle. ⭐ **`tri_rgba` introduces zero new silicon dependence.** |
| **J2** | *"Not in edgeasm's calibrated set"* is not an expressibility blocker — `e_vop3` takes a raw opcode; only a new FORMAT is blocked. | **Accepted and used.** Verified: mabda implements exactly VOP1/VOP2/VOPC/VOP3a/VOP3b/SOP1/SOP2/SOPP/SOPC/SMEM/FLAT. The design needs no format mabda lacks, and no new opcode either. |
| **J2** | `v_sub_co_u32`/`v_subb_co_u32` are absent; every design needs a 64-bit subtract. | **Designed out.** The correction is `if (N' ≥ (qh+1)·D255) qh += 1` — an add and an unsigned compare, exactly equivalent, no multi-precision subtract anywhere. |
| **J1/J2/J3-W4** | `GPU_TRI_E_RATIO = 1024` is *"a constant I invented... no geometric meaning... will probably move"*. | **Fixed by derivation, §2.4.** Hard ceiling 701,000 from the one-step correction bound; 1024 is an operating point with a 685× margin; the meaning is *maximum frame skew relative to the evaluation rect*; T10/T11 bracket it and T11 must reject. |
| **J1-W10 / J2 / J3-G6** | `t == 0` and `t == 32` are reachable and are *"the highest-probability silent defect in the blob"*; rung 9 dodged this class only via a coordinate guard. | **Closed by construction AND falsified.** §2.3 derives `t ∈ [10,31]` and `L ∈ {1,2}` from `AREA_MIN`/`AREA_MAX`/`Dh`'s range. Bite 4 gate 4 **requires** the mutation to go red, which is exactly what rung 9's `L==0` dependency never had. The dependency is cross-referenced at three sites, and the mask-word alternative is costed in §9. |
| **J1's numeric corrections** (`L ∈ {2,3}`, `t ∈ [10,32]`, `N ≤ 2^89.6`) | Judge 1 corrected EXACT-BARY and was itself slightly off. | Re-derived from scratch: **`L ∈ {1,2}`**, **`t ∈ [10,31]`** (judge 1 said `[11,32]`; `AREA_MIN = 2^32` gives `bitlen(D255) = 40`, so `t = 10`, and `AREA_MAX = 2^53` closes the top at 31), **`N < 2^77`**. Every width in §2.5 is derived here, not inherited. |
| **J1-G2 / J3-G5** | Accumulate-then-composite-once across primitives is *"not an optimisation, it is the correctness requirement"*. | **Deliberately NOT grafted, and named as rung 12.** Reasons: it pushes `blend_pk`'s div-255 outside its exhaustively-calibrated `n ∈ [0, 65025]` range (judge 2's own warning); it needs a vertex slot and blows the 15-of-16-dword record; and it is the big-bang this plan forbids. ⭐ **The decoupled frame already delivers what the row's oracle asks for** — a two-triangle quad reproducing a gradient is ONE record, structurally seamless. The two-record seam is §3.3's honest report, with its mutation pre-written. |
| **J3-W2** | The crossover claim is arithmetic, and rung 10's arithmetic was off by 7×. | **Accepted.** §5-Bite 10 pre-registers ~1300 px *as a model* and measures it in the same tool run at zero extra flash, the way rung 10's was. Decision 16. |
| **J3-F9** | The coverage mask round-trips through memory — 1 MB write + 1 MB read at the cap, absent from every VALU-only cost model. | **Accepted and instrumented.** Bite 10 oracle 3 prints `gpu_last_wait_us` **per dispatch**, which separates D2's write from D3's read. It moves the crossover by ~5 px; it does not change the ranking; it must not be modelled away. |
| **J2-G7** | Roll the 4-channel unroll into a wave-uniform loop — ~200 dwords instead of ~600. | **Taken (§1.7),** with Decision 7's wording preserved verbatim so the *wave-uniform loop vs per-lane break* distinction is not lost in a later summary. |
| **J2-G8** | SMEM for the wave-uniform prep record would cut real VGPR pressure. | **Deferred, §9.** `mabda` has `gfx9_enc_smem_lo` (an existing format) but `edgeasm` has no wrapper. ⚠ gfx9's constant-bus limit allows one SGPR source per VALU instruction, so it helps values used once, not the divider's hot operands. Worth measuring, not assuming. |

---

## 7. THE CORPUS'S OWN HONESTY PROBLEM, STATED ONCE

Three of the row's stated failure modes are satisfiable by a shader that does almost nothing, and the corpus alone does not catch any of them:

* a **flat-colour** shader passes any single-colour case byte-exactly (T4 is a *control*, not a gate) → **N11**;
* a shader with the **x term wired to zero** passes T5 and T6 *perfectly*, because `λ` reduces to `y/H` independent of `x` → **N12, and T1/T3 are the only gates**;
* a **dead** shader that writes zeroes passes any all-zero-answer case → **N10 + the coverage floor inherited from `--cov`'s N3**.

⭐ **A control-less run still prints "16 of 16".** `gputri.cyr:6-12` already states this for rung 9 and the tool already exits 86 rather than 95 when a control fails to fire. Rung 11 keeps that contract byte-for-byte.

---

## 8. THINGS I AM NOT SURE OF — flagged, not smoothed

1. ⛔ **Every VALU count in this plan is hand-counted, and this tree has been burned by exactly that.** `blend_pk.s:95-101` records a hand-counted estimate wrong by more than 2×, and its own conclusion is *"HAVE THE BURN PRINT THE REAL COUNT rather than trusting either comment."* My 540 VALU/px, the 408-VALU exactness cost, the ~76% share, and the ~1300-px crossover are all in that category. The host model can count *instructions*; it cannot measure *issue rate*.
2. ⭐ **PARTLY MEASURED NOW (2026-07-26).** The assembler computes the emit list's high-water VGPR
   mechanically, and the shipped blobs measure: **`edge_setup` up to v31, `edge_cov` up to v55**,
   both declaring **56**. So `edge_cov` sits at its declared limit with **zero headroom** — this
   plan's ~56-VGPR estimate for `tri_rgba` therefore lands exactly at that ceiling and against the
   64-register occupancy cliff. `tri_rgba` needs either its own RSRC1 or a register budget proven
   to fit in 56; it cannot simply inherit the shared descriptor and hope. The gate is
   mutation-tested (a deliberate 1-VGPR declaration is refused).
2b. ⛔ **The VGPR estimate still has no oracle for over-declaration.** ~56 is arithmetic on a register map nobody has written; 64 is the occupancy cliff and 65 spills to scratch agnos has never configured — a fault, not a slowdown. Bite 6's high-water gate catches **under**-declaration only, and `gpu.md:1017` is explicit that `RSRC1` is not GRBM-readable. This is the largest unmeasured assumption in the design.
3. ⚠ **The TRI-PREP record is new unvalidated kernel↔shader surface.** Written by CPU stores, read by six `global_load_dwordx4`, with no reject path. A field-order error yields a *plausible wrong picture* (wrong pitch = a sheared image), which is why Bite 8 gives it a host-vs-kernel diff rather than a read-back, and why Bite 10's failure table names it twice.
4. ⚠ **The coverage round-trip is unmodelled in the VALU arithmetic.** 2 MB of traffic at the cap, ~20-40 µs at Cezanne bandwidth — the same order as the third dispatch. Bite 10 prints it.
5. ⚠ **Colour is POINT-sampled while coverage is AREA-integrated.** Rung 9 integrates over four sub-scanlines and analytically in x; rung 11 evaluates colour at one pixel centre. For a 1-px sliver the centre can lie outside the shape, and `E_RATIO` + the output clamps supply the answer. This is standard practice and visually correct, but the output is **not** "the average colour over the covered area" and nobody should later cite it as such or build an oracle assuming it. The exact alternative (evaluate at each fragment's midpoint, which is always inside, and is exact because affine interpolation's integral over an interval equals midpoint × length) costs ~4× the colour work; named in §9.
6. ⚠ **Non-overlap and premultiplication are both unchecked at the shape level and both fail silently.** `CHECK_PREMUL` is reserved and rejected. Op `0x09` does check `c ≤ a` per *vertex* — 9 byte-compares per record, affordable precisely because the frame is three colours and not a 2 MB surface — which makes it **stricter than ops `0x01`/`0x02`/`0x04`**, and that inconsistency is a real wart. It gets one line of justification in the ABI doc, or it reads as an oversight in the other direction.
7. ⚠ **`GPU_TRI_MAX_PIXELS = 2^20` is an arena size wearing a constant's clothes.** It is labelled as such (Decision 10), but a 1024×1024 mask cap will be quoted as a design limit by someone reading only the constant. The real fix is a larger arena or Trap 3.
8. ⚠ **The `E_RATIO` operating point of 1024 has no consumer to derive it from**, because rung 11 has no shipped consumer yet. It will probably move the first time a real caller exists. That is fine — it is a reject with a specific fix — but it is a judgement, not a derivation, and only its *ceiling* is derived.
9. ⚠ **`recip32` is transplanted from `edgemodel.cyr` to the kernel prologue.** They are meant to be the same function; Decision 5 says one implementation. If the kernel's copy is edited and the model's is not, the byte-diff still passes because both sides of the diff use the model's. **The seam is the CPU prologue, and Bite 8's host-vs-kernel record diff is the only thing watching it.**

---

## 9. DEFERRED, AND WHY

| Deferred | Why | Trigger to revisit |
|---|---|---|
| **Trap 3 / `rt_handle` / offscreen render targets** | Does not exist anywhere in `kernel/core/*.cyr`; gated on rung 6's arena audit, which has not burned. Two large unproven things on one flash. | ⭐ Non-breaking **by construction**: `rt_handle` takes dword 2 with *"0 = the back buffer"*, which is exactly what the "every undefined dword must be zero" rule buys. |
| **Multi-primitive accumulate-then-composite-once** (the joint coverage resolve) | Pushes div-255 outside its calibrated range and needs a vertex slot. §6. | **Rung 12.** Its mutation gate is pre-written: composite per-primitive and a 50/50 seam pixel over an opaque source must show 25% destination show-through as a **large measured delta**. If that mutation does not go red, the seam gate is not wired up. |
| **The affine-plane closed form** (PLANE-11's core insight) | `λ0+λ1+λ2 ≡ 1` makes the interpolant an affine function, so four per-pixel quotients could become a hoisted plane at ~52 VALU instead of ~408. **Mathematically sound and a ~37% kernel-wide saving.** ⛔ Not at rung 11: it is exactly the spec-vs-spec downgrade that cost PLANE-11 the ranking. | **Rung 12+, gated by byte-diff against the now-shipped exact path** — which is the ideal referent PLANE-11 never had. ⭐ Take PLANE-11's insistence on the CLOSED form over an incremental one with it: no accumulation means no path dependence, so two lanes reaching the same pixel by different routes cannot disagree and a wave boundary cannot become an error boundary. |
| **The exact-remainder incremental walk** (`q += qx; r += rx; if (r ≥ D) { r −= D; q++ }`) | **Also exact and also drift-free.** Rejected on **dispatch shape alone** — a lane jumps to its own `(px,py)`, it does not step along a scan — **not on exactness.** | Recorded so nobody re-derives it as an improvement. Only relevant if the dispatch shape ever changes. |
| **Fragment-midpoint colour sampling** (the exact area integral) | ~4× the colour work; §8.5. | A measured complaint about boundary colour on thin primitives. |
| **The uniform-alpha fast path** (`a0 == a1 == a2` ⇒ skip one quotient) | Detect in the validator, flag in the prep record, **wave-uniform** branch. −25% on the colour stage, exactness preserved. The common case for gradients and solid-alpha fills. | If Bite 10's measured cost bites. It is the **only** exactness-preserving reduction on the table. |
| **`v_mul_hi_i32` (VOP3 `0x287`)** | Would collapse each signed product by 3 VALU. Has never executed on agnos — R10's class. | Its own first-thing-on-burn-N oracle, the way `v_mul_hi_u32` got one at rung 9b burn 1. |
| **SMEM for the wave-uniform prep record** | Would cut real VGPR pressure. Needs an `edgeasm` wrapper (the mabda format exists). ⚠ gfx9's constant-bus limit means it helps values used once. | If Bite 6's high-water gate reports > 60 VGPRs. |
| **The two shift-mask cndmasks / CPU-precomputed mask words** | 4 VALU/px, resolves both endpoints where they are trivially testable, and would let `AREA_MAX` widen past 2^53. | ⛔ **MANDATORY, IN THE SAME BITE, if `GPU_TRI_AREA_MAX` is ever raised by even one bit.** Decision 8. |
| **`rule = 1` (EVENODD)** | `refraster` implements `wind != 0` and nothing else; a rule-1 path would ship with **no oracle**. Same call rung 9 made, same reason. | Port sadish's `(wind & 1)` branch into `refraster.cyr` + a bowtie under both rules. Its own bite. |
| **Per-record bbox culling / batching an N-triangle mesh into fewer dispatches** | Each record is 3 dispatches; a 64-triangle mesh is ~5.5 ms of pure fixed cost. Real, and the correct scale-up. | Rung 12 (`tri-list`), where the vertex slot and the tiling both belong. |
| **Fusing D2 and D3** | Saves 28.8 µs = **0.75%** at the cap, and would edit a shipped iron-proven blob (violating Decision 1) and push VGPRs past 64. | Named as a rung-12 option with its measured upside. Never folded into rung 11. |
| **`gpu_blend_cov_run`'s duplicated `TCWB` and ungated `ACQUIRE_MEM`s** | Removing a coherence packet is the class that cost eight burns at C2g-1. | Its own bite, with the S3 arms re-run. **Never folded into rung 11.** |

---

## 10. ONE-PARAGRAPH SUMMARY FOR THE ROW

> **Rung 11 = 11 bites, 10 at zero burns, Flash 1.** Op `0x09 GPU_OP_TRI_RGBA` is a **three-dispatch, one-new-blob** design in which **`edge_setup.s` and `edge_cov.s` are dispatched as the SHIPPED BINARIES, byte-for-byte** — so the fill rule is not *"the same rule"*, it is the same machine code, and rung 9's 20/20 iron certification still certifies the coverage path rung 11 actually ships. **Coverage geometry and the attribute frame are DECOUPLED**: the shape is any edge array, the attribute basis is 3 vertices + 3 colours, so a two-triangle quad is **ONE record, one coverage pass, one blend, and no seam or double-blend is structurally representable**. A **CPU-side Cyrius prologue** hoists one exact 32-bit reciprocal per record (`recip32`, `edgemodel.cyr:97-112`, one shared implementation), and the new `tri_rgba` kernel evaluates two exact 64-bit edge functions at the pixel centre, derives the third from `E_A+E_B+E_C ≡ 2A`, and takes **one EXACT round-half-up quotient per channel** — a 96-bit numerator over `D255 = 255·2A`, via rung 9's 25-op branch-free multiply-shift plus **one** correction verified at full 96-bit width, with a **685× margin**. **Worst-case error vs the exact rational: ZERO, not ≤1.** No `v_rcp_f32`, no float in the divide, no fixed-point barycentric, no LDS, no cross-lane op, **no new opcode, no new encoding format, no new silicon dependence, no `RSRC2` change and no dispatcher change**. `t ∈ [10,31]` and `L ∈ {1,2}` are derived from `AREA_MIN`/`AREA_MAX` so **both gfx9 shift-mask hazards and `L==0` are structurally unreachable — with a falsification arm, which rung 9's equivalent dependency never had.** ⛔ **Two plan changes were forced and must be ratified before the flash:** `gpu.md:818`'s second oracle clause is unachievable for any integer design (op `0x04`'s `t` is `v_rcp_f32`; its own shipped self-test reports max dev 1 on iron) and is **UPGRADED**, not degraded, to bit-identity vs `grad_ref_px` proven for **both parities of `den`**; and the row's third failure mode is **mis-attributed** — a seam between separately-composited primitives is src-over conflation, not a fill-rule bug. ⛔ **One live latent defect was found and is fixed regardless of rung 11:** `GPU_EDGE_PREP_SUBOFF = 0xD0000` sits **inside** the 128 KB `GPU_BATCH_SNAP_SNAP` buffer at `[0xC0000, 0xE0000)`, and `check.sh`'s value-only gate is structurally blind to extent overlap. ⭐ **And one unanimous judge recommendation was refuted**: clamping `E_i` to `[0, 2A]` — named "the highest-value graft" by all three judges — breaks the gradient oracle by ~192 levels at the far corner, because the frame's `E_A` is legitimately negative there while the sum is correct. **Deviations recorded: back buffer at `dstxy`, not Trap 3; no vertex slot (15 of 16 dwords inline, op `0x04`'s precedent); `FLAG_DERIVE` rather than `edge_id == 0`; `GPU_OP_SUPPORTED` `0x11F → 0x31F`, not `0x1F1F`.**