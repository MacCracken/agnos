<!-- Rung 9b implementation plan. Produced 2026-07-25 by a 12-agent survey + adversarial
     design panel (5 surveyors, 3 independent designs, 3 adversarial judges by distinct lens,
     1 synthesis). Kept because the plan's VALUE is its refutations: three designs were scored
     and two were killed with concrete counterexamples, and those counterexamples are the
     reason the shipped design looks the way it does. gpu.md's rung-9 row points here. -->

# RUNG 9b — IMPLEMENTATION PLAN

## `edge_cov`: a two-dispatch, LDS-free, sort-free gfx90c edge rasteriser

---

## 0. THE VERDICT — 9b IS ELEVEN BITES, NOT ONE. EIGHT OF THEM COST ZERO BURNS.

**9b as scoped in `gpu.md:816` cannot be one bite, and the reason is not the shader.** Three of its stated preconditions do not exist in the tree:

| Missing precondition | Evidence | Consequence if ignored |
|---|---|---|
| **The 20-case corpus does not exist.** | `"20 cases"` / `"20-case"` appears exactly twice in `gpu.md`, both as *specification* (`:808`, `:816`). The tree has 8 `corpus_case` + 3 `shared_edge_pair` calls (`cpuref.cyr:309-322`). Rung 8's own closure text honestly says **"✅ Corpus: 8 cases"**. | 9b reports a pass against a corpus nobody wrote, or silently redefines its own oracle to 11. |
| **The reference is hand-transcribed three times** (`cpuref.cyr:64-209`, `refagree.cyr:51-172`, `tileown.cyr:56-…`) with different array bounds and width constants. Cyrius shadows duplicate `fn`s silently. | Read directly. | *"Byte-identical to the CPU reference"* has no single referent. |
| **`accrow[64]` overflows the ORACLE at any W > 64.** Module-scope `var accrow[64]` = 64 i64 slots; `span_add` indexes it by pixel x up to W (`cpuref.cyr:76-79, 107, 122`). `crx`/`crd` are declared on the next line. | Read directly. | The corpus's own 128-wide cases corrupt the *reference*, and it presents as a plausible wrong triangle. **Fatal, and it is in the oracle, not the shader.** |

Plus one the survey did not classify as a prerequisite but is: **`gpo_validate_edge` bounds `w`, `h`, `ne`, `rule` and the slots but never the coordinates** (`syscall.cyr:1083-1126`), and surveyor 2 reproduced *by execution* that ABI-legal i32 coordinates overflow the reference's own i64 product. **Above roughly `M·d ≈ 2^63` the oracle has no defined value**, so "byte-identical" is meaningless there regardless of which divider is chosen. That is a separate, kernel-side, QEMU-verifiable bite.

And one authoring prerequisite: **mabda's `gfx9_encode.cyr` has no label/patch pass and no assertion of any kind** (verified: 19 pure field-packing fns; `vsrc1=300` silently encodes as `v44`). Rung 7's row exists verbatim to catch this *"before anyone hand-writes a 200-instruction kernel."* The authoring tool is its own bite, with its own calibration gate.

**Ordering claim: 8 of the 11 bites are provable at ZERO BURNS. Only bites B9 and B10 need iron, and B9 carries three independent oracles on one flash.**

---

## 1. THE CHOSEN DESIGN — what I took, and from where

**Spine: MULINV-EDGE's divider (A2).** It is the only divider in the three proposals whose exactness is an *integer theorem* rather than a hardware measurement, its falsification arm fires exactly where the proof says it should, and I re-derived and re-ran it independently this session (below). A1's 30-iteration restoring divider is **refuted** (judge 1's counterexample is real and I reproduce the class); A3's answer is to not do the division on the GPU at all, which forfeits the arc.

**Structure: A1's verified whole-shader semantics (bit-identity claims 1–7), re-hosted onto the sort-free per-lane breakpoint walk (surveyor 2, verified 221/221) — with NO LDS, NO sort, NO cross-lane operation, NO DS instruction, NO `RSRC2` change and NO dispatcher change.**

**Two additions taken from A3:** (a) `min(acc, 65536)` before the ×255, which is output-equivalent to the reference's `c > 255` clamp and removes the accumulator-width question entirely; (b) its insistence that the *fragment multiset*, not the covered length, is the spec.

**What I reject and why:**

| Rejected | From | Reason |
|---|---|---|
| LDS + `ds_read/write_b64` + bitonic sort | A1 | The DS **format** has zero functions in mabda's encoder; no agnos shader has ever issued a DS instruction; no shipped `RSRC2` has ever set `GRANULATED_LDS_SIZE` (`gpu_regs.cyr:1088,1097,1108,1113` all zero); the SH registers are **not readable** (S1 settled negative, `gpu.cyr:1818-1827`) so a wrong LDS allocation has **no oracle** — and A1's proposed self-witness (write slot 0, read it back) tests round-trip, not allocation size, which is the only thing that can be wrong. That is [[feedback_echo_vs_answer_registers]] exactly. **A1's central "LDS is forced, not chosen" claim is false**: surveyor 2 verified an LDS-free per-lane form. |
| A1's 30-iteration restoring divider | A1 | Its seed invariant `R = P>>30 < d` fails once `\\|bx-ax\\| ≥ 2^30`, *inside* the region where cpuref is still well-defined, and raising the trip count does not fix it. Its iteration count is derived from a validator guard that does not exist yet — so relaxing the guard later silently corrupts output with no fault. |
| A2's `8×8` tile mapping (SB-8) | A2 | Contradicts A2's own body text and every shipped 2-D consumer (`gpu_cov_surface:2954`, `:2813`, `:3545`, `:3509` all use `gx=(w+63)/64, gy=h`), and throws away an 8× factor on the crossing solve. |
| A2's "two `DISPATCH_DIRECT`s chained in one submission" | A2 | Never done by agnos. **Replaced by two sequential `gpu_blend_cov_run` calls** — each already emits its own `ACQUIRE_MEM` invalidate → `DISPATCH_DIRECT` → `CS_PARTIAL_FLUSH` → `TCWB` → `WRITE_DATA` fence, which is precisely the S3-proven producer→consumer pattern. **Zero new PM4.** |
| A3 as the shipped rung | A3 | Its own summary: *"staged-and-stopped is a dead end for all of Phase II."* It also puts i64 raster math + a 256-entry insertion sort into `gpu.cyr` (8196 lines), which `gpu.md:808` forbids verbatim, and it biases rung 10's kill gate toward a **false kill**. |

**A3's staging discipline is kept — but as a HOST bite (B2), where it costs nothing, not as four iron burns.**

---

### 1.1 Dispatch shape

Two dispatches, both through the **unmodified** `gpu_blend_cov_run` (`gpu.cyr:2324`), which already takes `rsrc1` as a parameter and hardcodes `RSRC2 = GPU_COMPUTE_RSRC2_COV = 0x190` (USER_SGPR=8, TGID_X+TGID_Y, `tgid_x = s8`, `tgid_y = s9`, `TIDIG_COMP_CNT=0` so only `v0` is live).

```
gpu_edge_cov(edge_mc, dst_mc, w, h, n_edges, rule):
    if (rule != 0)              return GPO_E_RULE;      # NONZERO only — see §6
    if (n_edges > EDGE_CAP)     return GPO_E_EDGEBUF;   # shipped envelope == proven envelope
    if (gpu_edge_arm() != 1)    return 0;

    # --- dispatch 1: per-edge prologue table -------------------------------
    gpu_blend_cov_run(arena_mc + GPU_EDGE_SETUP_SUBOFF,   # shader
                      edge_mc,                            # s[0:1] edge array (16 B/edge)
                      arena_mc + GPU_EDGE_PREP_SUBOFF,    # s[2:3] prep table (32 B/edge)
                      n_edges, 0, 0, 0,                   # s4..s7
                      GPU_COMPUTE_PGM_RSRC1_ESET,
                      (n_edges + 63) / 64, 1,             # gx, gy
                      done_mc, done_phys);

    # --- dispatch 2: the rasteriser ---------------------------------------
    gpu_blend_cov_run(arena_mc + GPU_EDGE_SHADER_SUBOFF,  # slot 6, 0x56000 (reserved at 9a)
                      arena_mc + GPU_EDGE_PREP_SUBOFF,    # s[0:1] prep table
                      dst_mc,                             # s[2:3] 8bpp mask, pitch == w
                      n_edges, 0, w, 0,                   # s4..s7
                      GPU_COMPUTE_PGM_RSRC1_EDGE,
                      (w + 63) / 64, h,                   # gx, gy  <-- 64x1, NOT 8x8
                      done_mc, done_phys);
```

⚠ **`gx = (w+63)/64, gy = h` is a deliberate deviation from `gpu.md:816`'s "one lane per pixel of an 8×8 tile"**, recorded the way 9a recorded its `dstxy` deviation. Reasons: (a) `GPU_MT_NUM_THREAD_X = 64` is a module constant in the ring program (`gpu.cyr:2344`, `gpu_regs.cyr:1080`), not a parameter — an 8×8 tile still dispatches one wave64; (b) at 64×1 `py` and therefore `sy` are **wave-uniform**, so the crossing solve is one set per wave instead of eight; (c) it is byte-for-byte the convention every shipped 2-D consumer uses, which removes "tgid mapping" from burn 1's failure space entirely.

### 1.2 Arena

| Constant | Value | Note |
|---|---|---|
| `GPU_EDGE_SHADER_SUBOFF` | `0x56000` | **already reserved at 9a** (`gpu_regs.cyr:1150`); 8 KB clear before the done marker at `0x58000` |
| `GPU_EDGE_SETUP_SUBOFF` | `0x57000` | slot 7 of the same 0x1000-strided residency table; currently unoccupied |
| `GPU_EDGE_PREP_SUBOFF` | `0xD0000` | 256 edges × 32 B = **8 KB**. Arena is `0x200000`; highest live `_SUBOFF` below the sacrificial page is `GPU_BATCH_SNAP_SNAP` at `0xC0000`. |

`scripts/check.sh:40-53` gates `_SUBOFF` uniqueness automatically. The rung-6 arena audit must be told about `0xD0000`.

### 1.3 The per-edge prologue record (32 B, two `global_load_dwordx4`)

Written by dispatch 1, read by dispatch 2. All fields i32/u32.

```
+0   ax        (16.16, raw endpoint — NOT the swapped ylo)
+4   ay        (16.16, raw endpoint)
+8   ylo       = min(ay, by)
+12  yhi       = max(ay, by)
+16  N         = bx - ax        SIGNED (sign and magnitude both derived in the raster kernel)
+20  d         = max(yhi - ylo, 1)     <-- the horizontal-edge clamp, MANDATORY
+24  V         = floor((2^63 - 1) / (d << clz32(d)))
+28  L         = clz32(d)
```

`dir` is **not stored** — it is `(ay == yhi) ? -1 : +1`, two instructions, and `ay`/`yhi` are both in the record.
`active` is **not stored** — a horizontal edge has `ylo == yhi`, which makes the half-open test `ylo ≤ sy < yhi` unsatisfiable, so it is masked out by the guard that has to run anyway.

⛔ **`d = max(…, 1)` is not optional.** `cpuref.cyr:87` DROPS `y0 == y1` edges; `gpo_validate_edge` rejects `ne < 3` (`syscall.cyr:1099`) and filters nothing, so the shader **is** handed horizontals — and three of the eight existing corpus cases contain one. Without the clamp, `clz32(0)` in the setup kernel is undefined.

### 1.4 Dispatch 1 — `edge_setup.s`, one lane per edge

```
  s_mov_b64 exec, -1                       # 0xbefe01c1 (verified against shipped bytes)
  s_lshl_b32 s10, s8, 6 ; v_add_u32 v1, s10, v0        # ei = tgid_x*64 + lane
  v_cmp_gt_u32 vcc, s4, v1 ; s_and_saveexec_b64 ...    # ei < n_edges
  s_cbranch_execz DONE
  addr = s[0:1] + ei*16 ; global_load_dwordx4 v[4:7]   # ax ay bx by
  s_waitcnt vmcnt(0)
  v_min_i32  v8,  v5, v7                   # ylo        (VOP2 0x0C — VERIFIED)
  v_max_i32  v9,  v5, v7                   # yhi        (VOP2 0x0D — VERIFIED)
  v_sub_u32  v10, v9, v8                   # d
  v_max_u32  v10, 1, v10                   # d >= 1     (VOP2 0x0F)
  v_sub_u32  v11, v6, v4                   # N = bx - ax
  v_ffbh_u32 v12, v10                      # L = clz32(d)   (VOP1 0x2D — VERIFIED)
  v_lshlrev_b32 v13, v12, v10              # dp = d << L, top bit set
  # ---- V = floor((2^63 - 1) / dp), 32-iteration integer restoring loop ----
  # numerator 0x7FFF_FFFF_FFFF_FFFF: hi dword = 0x7FFFFFFF < dp always (dp >= 2^31),
  # lo dword is all-ones, so the bit shifted in is ALWAYS 1 -- no numerator register.
  v_mov_b32 v14, 0x7FFFFFFF                # r
  v_mov_b32 v15, 0                         # V
  s_mov_b32 s20, 32
LOOP:
  v_lshrrev_b32 v16, 31, v14               # top = r >> 31   (carry out of the shift)
  v_lshlrev_b32 v14, 1, v14
  v_or_b32      v14, 1, v14                # r = (r<<1) | 1
  v_cmp_ge_u32  vcc, v14, v13
  v_cmp_ne_u32_e64 s[22:23], 0, v16
  s_or_b64      vcc, vcc, s[22:23]         # ge = top | (r >= dp)
  v_sub_u32     v17, v14, v13
  v_cndmask_b32 v14, v14, v17, vcc
  v_lshlrev_b32 v15, 1, v15
  v_addc_co_u32 v15, vcc, 0, v15, vcc      # V = (V<<1) | ge
  s_sub_i32 s20, s20, 1 ; s_cmp_lg_i32 s20, 0 ; s_cbranch_scc1 LOOP
  # ---- store ----
  store [ax, ay, ylo, yhi] then [N, d, V, L] at s[2:3] + ei*32, glc
DONE: s_endpgm
```

~55 instructions, ~70 dwords, **one** backward branch. Runtime ≈ 32 × 9 ≈ **290 VALU per edge**; the entire 256-edge worst case is one workgroup × 4 rounds ≈ 1160 wave-instructions **for the whole dispatch**. Against a 64×64 raster that is under 0.1%.

⭐ **No `v_rcp_f32` anywhere.** Three surveys independently established the f32-reciprocal macro's exactness is *empirically* guaranteed by LLVM's own comment, was demonstrably wrong before 2020 (issue #45557), and fails 7/200,000 in our operand range under a +1-ULP perturbation the ISA permits. The 32-iteration integer loop is exact by construction and costs nothing amortised. [[feedback_sovereignty_over_slip_at_base]].

### 1.5 Dispatch 2 — `edge_cov.s`, one lane per pixel, 64×1

```
KERNARGS: s[0:1] prep table  s[2:3] dst mask  s4 n_edges  s5 —  s6 w  s7 —
          s8 tgid_x (64-px column block)   s9 tgid_y (= py)   v0 lane 0..63
```

Per-lane pseudocode (this is what B2 implements in Cyrius and diffs against `refraster.cyr` at **zero burns** before one instruction is assembled):

```
px = tgid_x*64 + lane
if (px >= w) exit                                  # EXEC guard, blend_cov.s:43-47 pattern
pl = px << 16 ;  pr = pl + 65536 ;  acc = 0
INF = 0x7FFFFFFF ;  vneg1 = -1

for s in 0..3:                                     # scalar loop, 4 iterations
    sy = (py << 16) + SUBY[s]                      # SUBY = {8192,24576,40960,57344} — EXACT
    u = pl
    loop:                                          # BREAKPOINT WALK, per-lane divergent
        w_acc = 0 ; vmin = INF ; any = 0
        for ei in 0 .. n_edges-1:                  # scalar loop over the prep table
            load rec[ei]                           # ax ay ylo yhi | N d V L
            act = (ylo <= sy) && (sy < yhi)        # HALF-OPEN, evaluated BEFORE the divide
            xx  = crossing(rec, sy)                # §2 — 25 branch-free VALU
            dir = (ay == yhi) ? -1 : +1
            if act && xx <= u  : w_acc += dir       # <= not <, so ties at the left edge count
            if act && xx >  u  : vmin = min(vmin, xx) ; any = 1
        if !any: break                             # NEVER fill past the last crossing
        v = min(vmin, pr)
        if w_acc != 0: acc += (v - u) >> 2         # ONE fragment, truncated ONCE
        u = v
        if u >= pr: break
acc = min(acc, 65536)
c   = ((acc << 8) - acc) >> 16                     # acc*255 without a literal
store8(dst + py*w + px, c)                         # global_store_byte ... glc
```

**Instruction budget:** prologue ≈ 20 dwords · sub-scanline head ≈ 8 · breakpoint head ≈ 8 · edge-loop body ≈ 55 (incl. the 25-op divider and 2 loads) · breakpoint tail ≈ 20 · epilogue ≈ 25 → **≈ 140 dwords, ≈ 100 instructions**, plus `edge_setup` at ≈ 70 dwords. Slot 6 has 8 KB before the done marker; slot 7 has 4 KB. Comfortable.

For scale: the largest blob agnos has ever shipped is `grad_linear` at **70 dwords**; `blend_cov` is 67. This is 2× the ceiling, not 3× (A1 was 213). **Three backward branches** (sub-scanline, breakpoint, edge) against a shipped ceiling of one — which is why the label/patch pass (B4) is a hard prerequisite, not a convenience.

**Registers:** ~32 VGPRs / ~32 SGPRs. `RSRC1 ≈ 0x002C00C7`. ⚠ **DERIVE the committed value from the final `.s`'s `.amdhsa_next_free_vgpr`/`_sgpr`, never hand-count** — `gpu_regs.cyr:1151-1157` spells out that under-allocating the SGPR file corrupts the vcc carry chain in address arithmetic and lanes write the wrong pixels. No scratch: agnos never writes `COMPUTE_TMPRING_SIZE`, so no-spill is a build-time guarantee (`gpu.cyr:1818-1827`).

### 1.6 Why the breakpoint walk re-scans the edge array, stated plainly

Judge 2 correctly caught that A2 never picked between two incompatible horns. **I pick the re-scan horn explicitly and count it.**

The crossing `xx` depends on `(edge, sy)` only, never on `px` — so a *resident* crossing list would be cheaper. But gfx9 has **no per-lane runtime-indexed VGPR access** (`v_movrels` indexes through M0, which is wave-uniform), so a resident per-lane list needs LDS, which drags in the DS format, the never-set `RSRC2` LDS field and the unobservable allocation. The re-scan avoids all of it.

**The multiplier is ~1.5, not large.** The breakpoint loop's trip count is `1 + (crossings strictly inside this pixel)`. For a pixel with no interior crossing the loop runs **exactly once** (scan → `vmin > pr` → clamp → add → `u = pr` → break). Surveyor 2 measured max 3 fragments per pixel per sub-scanline over the whole corpus, and the wave pays the max over its 64 lanes, so ≈ 2 in practice.

**Cost, per workgroup (64 pixels of one row):** ≈ `4 × 1.5 × E × 60` wave-instructions ≈ **360·E**.

| | this design | A1 (LDS+bitonic) |
|---|---|---|
| E = 3 (triangle — the actual consumer, and rung 12) | ~1,100 | ~1,790 |
| E = 64 | ~23,000 | ~7,760 |
| E = 256 | ~92,000 | ~36,600 |

It is **cheaper where the consumers are** (triangles, `tri-list`, DOOM quads) and loses at high edge counts. Edge-parallel Phase A is a named deferred optimisation (§6), not a 9b requirement.

**Watchdog arithmetic** (Cezanne, 8 CU × 4 SIMD16, ~1.8 GHz, ≈1.4e10 wave-instr/s, SALU free — *my model, not a measurement*):

| workload | wave-instr | est. | vs the hardcoded 100 ms (`gpu.cyr:2357`) |
|---|---|---|---|
| corpus, 64×64, E=3 | 64 wg × 1,100 | ~5 µs | fine |
| 4096², E=3 | 262,144 × 1,100 | ~20 ms | fine |
| 4096², E=64 | 262,144 × 23,000 | ~430 ms | **over by 4.3×** |

⇒ **Ship `EDGE_CAP = 64` as a named reject, pass the timeout through from `gpu_edge_cov` instead of inheriting the literal, and print `gpu_last_wait_us` (already recorded by `gpu_wait_done`) from `/bin/gputri`.** Raise the cap at B10 from the measured curve, never from this model.

---

## 2. THE DIVISION ANSWER — SETTLED

**`trunc(N·t/D)` is computed as `sign(N) · floor(M·u/d)` via one per-edge 32-bit reciprocal and 25 branch-free VALU per crossing. There is no runtime division in the raster kernel at all.**

### 2.1 Sign collapse (exact, no fixup)

`cpuref.cyr:157` is `xx = ax + ((bx-ax)*(sy-ay))/(by-ay)`, i64, truncating toward zero (Cyrius `/` → `cqo; idiv`, `cyrius/src/common/ir.cyr:402`, `backend/x86/emit.cyr:282-284`).

The half-open test at `cpuref.cyr:153-154` forces `sign(sy-ay) = sign(by-ay)`:
- `D > 0` ⇒ `ylo = ay` ⇒ `t = sy-ay ∈ [0, D)`;
- `D < 0` ⇒ `yhi = ay` ⇒ `t ∈ [D, 0)`.

Hence with `M = |bx-ax|`, `d = |by-ay|`, `u = |sy-ay| ∈ [0, d]`:

```
trunc(N·t/D) = (N < 0 ? -1 : +1) · floor(M·u/d)
```

because `trunc(x) = sign(x)·floor(|x|)`. **All four sign quadrants collapse to one unsigned floor-division, and trunc-toward-zero is obtained by construction rather than by fixup.** This matters: surveyor 2 measured that substituting floor for trunc changes output bytes in **51 of 420 cases**, and the quotient is negative on *every left-leaning edge* — the common case.

⚠ `ay` and `by` in that expression are the **RAW endpoints**, not the swapped `ylo`/`yhi` (`cpuref.cyr:149-150` swaps only `ylo`/`yhi`/`dir`). Getting this backwards silently changes the answer.

### 2.2 Normalisation — `u ≤ d` is what makes a 64/32 problem into a 32-bit one

`P := M·u ≤ M·d < 2^32·d`. With `L = clz32(d)`, `dp = d<<L ∈ [2^31, 2^32)`:

```
P' := P << L  <  2^32·d·2^L = dp·2^32 ≤ 2^64        -- ALWAYS fits 64 bits
floor(P/d) = floor(P'/dp)                            -- scaling preserves the rational exactly
```

`u ≤ d` is a **gift from the half-open rule**, not an assumption.

### 2.3 The reciprocal is exactly 32 bits, and the correction is exactly one

`V := floor((2^63-1)/dp)`. Since `2^31 ≤ dp < 2^32`, `V ∈ [2^31, 2^32)` — one VGPR.

Write `2^63-1 = V·dp + e`, `0 ≤ e < dp`. Then `P'·V/2^63 = P'/dp − δ` with

```
δ = P'(1+e)/(dp·2^63) ≤ M·dp·dp/(dp·2^63) = M·dp/2^63 < M/2^31
```

so **`M < 2^31` ⇒ `δ < 1` ⇒ `q̂ = floor(P'·V / 2^63) ∈ {Q-1, Q}`**, `Q = floor(P/d)`.

The remainder `r = P − q̂·d` satisfies `P mod d ≤ r < (P mod d) + d < 2d`, so **if `2d < 2^32` the correction test is a genuine low-dword-only 32-bit compare** — the high dword of `P` is never needed.

And the low dword of the 96-bit product `P'·V` is discardable: with `(hh:m)` the top 64 bits and `l0` the bottom 32, `frac((hh:m)/2^31) + l0/2^63 ≤ (2^31-1)/2^31 + (2^32-1)/2^63 < 1`, so `floor(product/2^63) = (hh:m) >> 31`. **One of the four multiplies is never issued.**

### 2.4 The 25-instruction sequence

```
 1  v_sub_u32      t,  sy, ay              # RAW ay
 2  v_ashrrev_i32  ts, 31, t
 3  v_add_u32      u,  t, ts
 4  v_xor_b32      u,  u, ts               # u = |t|
 5  v_cndmask_b32  u,  0, u, s[act]        # off-guard -> u = 0, P = 0, no wrap ever
 6  v_ashrrev_i32  ns, 31, N
 7  v_add_u32      M,  N, ns
 8  v_xor_b32      M,  M, ns               # M = |N|
 9  v_mul_lo_u32   plo, M, u               # VOP3 0x285  (SHIPPED in matmul_i32)
10  v_mul_hi_u32   phi, M, u               # VOP3 0x286  (NEVER RUN ON AGNOS — see §5)
11  v_sub_u32      L32, 32, L
12  v_lshlrev_b32  a0,  L, plo             # ---- P' = P << L, 4 VOP2 ops,
13  v_lshlrev_b32  a1,  L, phi             #      no v_lshlrev_b64 needed
14  v_lshrrev_b32  tw,  L32, plo           #
15  v_or_b32       a1,  a1, tw             #
16  v_mul_hi_u32   h0,  a0, V
17  v_mul_lo_u32   l1,  a1, V
18  v_mul_hi_u32   h1,  a1, V              # (a0*V's LOW dword never computed — §2.3)
19  v_add_co_u32   m,   vcc, h0, l1
20  v_addc_co_u32  hh,  vcc, 0, h1, vcc
21  v_lshlrev_b32  q,   1, hh              # ---- q_hat = (hh:m) >> 31
22  v_lshrrev_b32  tw,  31, m
23  v_or_b32       q,   q, tw
24  v_mul_lo_u32   qd,  q, d
25  v_sub_u32      r,   plo, qd            # low dword only
26  v_cmp_ge_u32   vcc, r, d
27  v_addc_co_u32  q,   vcc, 0, q, vcc     # THE single correction. q is now EXACTLY Q.
28  v_sub_u32      xn,  ax, q
29  v_add_u32      xp,  ax, q
30  v_cmp_gt_i32   vcc, 0, N
31  v_cndmask_b32  xx,  xp, xn, vcc        # xx = ax +/- Q
```

No branch, no loop, no float, no divergence, no 64-bit divide, no LDS.

### 2.5 Domain, guard, and the shift-by-32 edge case

**Exact ⟺ `|bx-ax| < 2^31` AND `2·|by-ay| < 2^32`.**

Note that `2d < 2^32` ⇒ `d ≤ 2^31-1` ⇒ `L ≥ 1` ⇒ `L32 ≤ 31`, so **A2's own Risk-3 shift-by-32 hazard is unreachable on the proved domain** — the domain condition already forbids it. (I checked this specifically; A2 flagged it as "the single most likely silent-corruption path" and it is a non-issue given the guard.)

**REQUIRED GUARD (its own bite, B3): each of `x0,y0,x1,y1 ∈ [−2^28, +2^28]`** (±4096 px in 16.16, matching `GPU_COV_MAX_DIM = 4096`). Then `M, d ≤ 2^29` ⇒ `δ < 1/4`, `r < 2^30`, `L ≥ 3`. Two bits of margin on both.

⭐ **The guard is chosen from the REFERENCE's needs, not the divider's.** `gpo_validate_edge` bounds `w`, `h`, `ne`, `rule` and the slots but never the coordinates, and surveyor 2 reproduced *by execution* that ABI-legal i32 coordinates wrap the reference's own i64 product (true `N = 1.037e19`, machine result negative, `xx` outside `[min(ax,bx), max(ax,bx)]`). **Above that point the oracle does not exist.** The guard would be required no matter which divider we chose. It is a real ABI change and must land before any 9b green is cited.

⚠ **Do NOT let a divider's parameter be derived from the guard.** That is exactly the trap A1 set — its literal `30` came from `±2^28`, so someone relaxing the guard later silently corrupts output with no fault. This divider survives to `±2^30`, verified, so the guard has margin over the divider rather than defining it.

### 2.6 What I verified this session, independently

`/tmp/claude-1000/…/scratchpad/plan/div.py` — models the shader as 32-bit lane ops (every intermediate masked to 32 bits, the 64-bit shift done as two dwords via the shift-shift-or funnel, `mul_hi` explicit) and compares against a literal transcription of `cpuref.cyr:157` in exact Python integers with trunc-toward-zero, including the `ylo/yhi/dir` swap and the half-open guard:

```
|coord| <= 2^28   tested 200000  bad 0  max corrections 1
|coord| <= 2^29   tested 200000  bad 0  max corrections 1
|coord| <= 2^30   tested 200000  bad 0  max corrections 1     <-- 2 bits past the guard
adversarial       tested  14598  bad 0  max corrections 1
   (d in [1,400] + {65535,65536,65537,2^20,2^28,2^29,2^30,2^31-1}
    x u in {0, 1, d-1, d, d/2}  x  M in {0,1,2,3,2^29-1,2^29,2^30,2^31-2,2^31-1})
```

The assertion `P<<L < 2^64` never fired. **600,000 whole-expression cases + 14,598 adversarial, zero mismatches, correction count never exceeded 1 — exactly as Claim 4 predicts.** This corroborates A2's own 3.7M-case run and judge 1's independent 500K-case run.

For contrast, judge 1 measured A1's 30-iteration divider at **6,859 wrong per 120,000** at `|coord| ≤ 2^30`, inside cpuref's own domain of definition.

---

## 3. ORDERED SUB-BITES

**Legend:** 🆓 = zero burns (host or QEMU) · 🔥 = needs iron.

---

### B0 🆓 HOST — `refraster.cyr` extraction + the `accrow` fatal
**Lands:** `tests/gpu/refraster.cyr`, include-only (no `main`, no `_entry` — `cpuref.cyr:301,342-343` make it a *program*, so including it today gives duplicate `main`/`_entry` and Cyrius shadows duplicates silently). Contains `R_*`, `edges_reset`, `edge_add`, `span_add`, `raster`, with `W`/`H`/`MAXE` as module vars and **`accrow` sized by a declared `MAXW` plus a RUN-TIME `if (W > MAXW) fail loudly`** — a check, not a comment. Re-point `cpuref.cyr`, `refagree.cyr`, `tileown.cyr` at it.
**Verified by:** all three still exit **95/95/95, unchanged**.
**Why first:** `var accrow[64]` is exactly 64 i64 slots and `span_add` indexes it to `W`; at any `W > 64` it writes into `crx`/`crd` — corrupting the **ORACLE**, presenting as a plausible wrong triangle. Every later bite cites this file.

---

### B1 🆓 HOST — itemise and author the 20-case corpus
**Lands:** one table in `refraster.cyr` driving **both** the reference and the `#92` edge array from a single source of truth. The plan never enumerated 20; I enumerate it here so the number is never inherited un-itemised again:

| # | case | why it is in |
|---|---|---|
| 1 | plain triangle | baseline |
| 2 | zero-area / collinear | all-zero answer |
| 3 | backfacing CW | `wind != 0` fills both windings; a naive `wind > 0` fails only here |
| 4 | 1-px sliver | contains a horizontal edge |
| 5 | clipped off-screen (negative coords) | **sign-extension trap** |
| 6 | fully outside | all-zero answer |
| 7 | pixel-centre straddling | contains a horizontal edge |
| 8 | full-canvas | horizontal edge + coords beyond the mask |
| 9 | **bowtie** (self-intersecting) | fragment-partition discriminator |
| 10 | **two overlapping triangles in one edge array** (6 edges) | ⛔ **mandatory** — merging a pixel's fragments changes output in 2/221 cases and *first differs here*; a single triangle can never expose it |
| 11–13 | three shared-edge pairs (axis-aligned / skewed / near-full) | watertightness |
| 14 | **open (non-closed) 3-edge path** | `gpo_validate_edge` requires `ne ≥ 3`, never closure; the walk's break-on-no-crossing-to-the-right is load-bearing here |
| 15 | x-asymmetric triangle | gputri's current triangle is symmetric about x=64 in a 128-wide mask, so an x-mirrored tgid map shifts by 1 px instead of looking wrong |
| 16 | mask width **not** a multiple of 64 (e.g. 37×29) | EXEC guard |
| 17–18 | tile-boundary shapes lifted from `tileown.cyr` | block-boundary ownership |
| 19 | wide mask (e.g. 200×64) | `tgid_x` wraps ≥3× |
| 20 | 64-gon (`n_edges = 64`) | the edge loop at the shipped cap |

Record "20 cases, itemised" in the `gpu.md` row.
**Verified by:** `cpuref` still 95 with the extended corpus; each case's reference mask non-degenerate where intended.

---

### B2 🆓 HOST — **THE CORRECTNESS GATE.** `tests/gpu/edgemodel.cyr`
**Lands:** the *entire* shader algorithm, in Cyrius, at shader register widths: the §1.4 setup (`clz`, restoring-loop `V`), the §2.4 25-op divider with **every intermediate explicitly masked to 32 bits**, and the §1.5 sort-free breakpoint walk. Diffed byte-for-byte against `refraster.cyr`'s `raster()`.

**Gates (all four required):**
1. All 20 corpus cases + 200 random triangles + 60 random 3-triangle meshes: **0 differing bytes**.
2. The exhaustive divider sweep (`d ∈ [1,400] × u ∈ {0,1,d-1,d,d/2} × M ∈ {extremes}`): 0 wrong, corrections ≤ 1.
3. The **falsification arm**: `M ≥ 2^31` MUST produce mismatches. A domain claim with no failing arm is not a claim.
4. An assertion that the breakpoint loop's max trip count over the corpus is recorded and printed.

⚠ Cyrius traps this bite must respect: `>>` is **LOGICAL**, `>>>` is arithmetic (inverted from C/Java) — the abs idiom needs `>>>`, everything in the divider needs `>>`; `load32` **zero-extends**, so edge coordinates must be sign-extended before any arithmetic (this alone silently destroys corpus case 5); module-scope `var X[N]` = N×u64; **no chained `else if`**.

**Why this bite is the whole plan's keystone:** it converts "the algorithm is exact" from three surveyors' Python into a Cyrius artifact diffed against the artifact that *is* the oracle, **at zero burns**, before one instruction is assembled. It is also A3's staging discipline bought for free: if B2 is green and iron is red, the fault is in the *emission*, not the *algorithm*.

---

### B3 🆓 QEMU — the coordinate guard
**Lands:** `|x0|,|y0|,|x1|,|y1| ≤ 268435456` in `gpo_validate_edge`, with a **NEW reason code** (`GPO_E_COORD`, not a reused `GPO_E_DIM` — the failure table must distinguish it). Documented in `docs/development/agnos-userland-abi.md` §3.4 as *the domain on which byte-identity to the reference is DEFINED*, citing surveyor 2's executed i64-overflow counterexample. `edge_abi_selftest` gains in-range and out-of-range cases; count extends from 16.
**Verified by:** `scripts/smoke/edge-abi-smoke.sh` green at the new count, **plus a mutation check** that deleting the bound fails the new case (the 9a discipline: calibrate the null).
**No shader involved. Independently landable.**

---

### B4 🆓 HOST — the authoring tool `tests/gpu/edgeasm.cyr`
**Lands:** includes mabda's **LIVE** `gfx9_encode.cyr` by relative path (`asmagree.cyr:44`'s shape; needs `CYRIUS_ALLOW_PARENT_INCLUDES=1` — a vendored copy would drift and defeat the comparison). Adds, **locally, never in mabda** ([[feedback_cyrius_hands_off]] applies to mabda by the same logic — it is a sibling repo):
- the **label/fixup pass** lifted from `mabda/src/gfx9_compile.cyr:827-884` (`laboff[]`, `patch_off[]`/`patch_tgt[]`, resolve as `simm = (tgt - (br+4))/4`, rewrite the low 16 bits in place). `gfx9_enc_sopp`'s negative-offset handling is already verified (`0xbf85ffef` reproduced), so only the bookkeeping is new. ⚠ **Re-derive the array sizing** — `gfx9_compile` declares `var patch_off[2048]` FUNCTION-LOCAL (2048 *bytes*); at module scope in a top-level program the same declaration means 8× that.
- **asserting wrappers**: a `vop3()` that emits **both** dwords in one call and **refuses `src == 255`** (VOP3 has no literal form; mabda's own compiler treats this as `CMP_ERR_VOP3_LITERAL`); range-checked `v()`/`s()`; a `k()` that **fails loud** instead of silently returning 255.

⛔ **CALIBRATION GATE, non-negotiable: the tool must re-emit `blend_cov`'s 67 shipped, iron-proven dwords (`gpu.cyr:2247-2316`) byte-identically from a hand-written instruction list.** A tool that cannot re-emit a known-good shader has no business emitting a new one.

**Why it is a separate bite:** three backward branches with hand-counted offsets in a 140-dword blob is the silent-corruption failure mode this rung cannot afford — a dropped VOP3/FLAT hi dword shifts everything after it and produces a wrong *picture*, never a fault.

---

### B5 🆓 HOST — extend `asmagree.cyr` to the classes 9b introduces
Rung 7 proved VOP1 ×2, VOP2 ×3, SOP1+literal, SOPP, and one VOP3a *lo* dword — and its row states the honest limit itself. 9b adds: `v_mul_hi_u32`, `v_ffbh_u32`, `v_min_i32`/`v_max_i32`/`v_min_u32`/`v_max_u32`, `v_cndmask_b32` (VOP2 and the VOP3 SGPR-pair form), `v_cmp_*_e64` (VOPC-as-VOP3 with an SGPR-pair destination), `v_add_co_u32`/`v_addc_co_u32`, `global_load_dwordx4`, `global_store_byte`, `s_andn2_b64`, `s_cbranch_execnz`, `s_or_b64`.

**Reference table captured this session with `llvm-mc -arch=amdgcn -mcpu=gfx90c -show-encoding`** (a one-off investigation tool, per D-1, never a build gate):

| instruction | encoding | note |
|---|---|---|
| `v_ffbh_u32 v1, v2` | `[02 5b 02 7e]` | VOP1 **0x2D** — closes surveyor 1's UNKNOWN |
| `v_mul_hi_u32 v1,v2,v3` | `[01 00 86 d2][02 07 02 00]` | VOP3 **0x286** |
| `v_min_i32 / v_max_i32` | `…0x18 / …0x1a` | VOP2 **0x0C / 0x0D** — closes surveyor 1's UNKNOWN |
| `v_min_u32 / v_max_u32` | `…0x1c / …0x1e` | VOP2 **0x0E / 0x0F** |
| `global_load_dwordx4` | `[00 80 5c dc][02 00 7f 04]` | dword0 `0xdc5c8000` |
| `global_store_byte … glc` | `[00 80 61 dc][02 04 7f 00]` | dword0 **`0xdc618000`** — confirms surveyor 1's DERIVED `0x18` |
| `v_readfirstlane_b32 s1,v2` | `[02 05 02 7e]` | VOP1 **0x02** |
| `s_andn2_b64` | `[04 06 82 89]` | SOP2 **0x13** — ⚠ **CORRECTED at B5.** This row read `[04 06 84 89]` / op 0x09; that dword's `sdst` field is 4, not 2, and the opcode is 0x13. Re-derived by running `llvm-mc` in-session and settled by byte-diff — a first hand-decode of the corrected dword said 0x12 and was also wrong. |
| `s_cbranch_execnz 0` | `[00 00 89 bf]` | SOPP 0x09 |
| `s_ff1_i32_b32 / s_flbit_i32_b32` | `[02 10 81 be] / [02 12 81 be]` | SOP1 0x10 / 0x12 |

**Zero new encoding FORMATS.** Every class above is VOP1/VOP2/VOPC/VOP3a/VOP3b/SOP1/SOP2/SOPC/SOPP/FLAT, and surveyor 1 verified by execution that each reproduces a shipped agnos dword through the unmodified encoder. Only the opcode *numbers* are new, and the encoder takes raw numbers. **No mabda edit is required.**
**Verified by:** `asmagree` exit 95 with the extended table.

---

### B6 🆓 HOST — author and byte-verify both blobs
**Lands:** `kernel/shaders/edge_setup.s` and `kernel/shaders/edge_cov.s` (documentation of record, per `gpu.cyr:2243-2246`), emitted through `edgeasm.cyr` into `store32` tables.
**Verified by:** every dword byte-diffed against `llvm-mc -mcpu=gfx90c` on the same source, **and** the per-instruction table printed so a human can check operand order — especially the **REV shift semantics** (amount in `src0`, value in `vsrc1`) and `v_addc_co_u32`'s inline-0-in-src0 / VGPR-in-vsrc1 constraint. Derive `GPU_COMPUTE_PGM_RSRC1_EDGE` and `_ESET` from the `.amdhsa_kernel` descriptors mechanically.

---

### B7 🆓 QEMU — the kernel seam
**Lands:** `GPU_EDGE_SETUP_SUBOFF = 0x57000`, `GPU_EDGE_PREP_SUBOFF = 0xD0000`, both RSRC1 constants; `edge_setup_write()` and `edge_cov_write()` next to `blend_cov_write`; `gpu_edge_arm()` replaced with the 5-gate peer body (`gpu_cov_arm`, `gpu.cyr:2935-2945`) writing **both** blobs then `gpu_mfence()`; `gpu_edge_cov()` per §1.1 with `gx = (w+63)/64, gy = h`, a **comment naming the lane shape**, the `rule != 0` and `n_edges > 64` rejects, and a **passed-through timeout**.

⛔ **In the SAME bite:** flip `edge_abi_selftest`'s hardcoded `GPO_E_ARM` expectation (`syscall.cyr:1185`) to `0`. Arming the shader turns `scripts/smoke/edge-abi-smoke.sh` red *for a correct reason*, and a known-red gate carried into a burn is how a real regression gets waved through.

⛔ **Do NOT touch** `gpu_blend_cov_run`'s duplicated `TCWB` packets (`gpu.cyr:2334, 2351` vs `gpu_batch_tail:2209`) and **do not touch** the mis-attributed comment at `gpu.cyr:2192-2193` inside this bite. Removing a coherence packet is the class that cost eight burns at C2g-1. See §6.

**Verified by:** `check.sh` unaliased-slot gate; `scripts/smoke/edge-abi-smoke.sh` **16/16 + 8/8 green** in QEMU.

---

### B8 🆓 QEMU — rebuild `/bin/gputri` and wire it into the burn
**Lands:**
- `tri_edges` grown to ≥ 8 edges (`var tri_edges[8]` = 64 B = **exactly 4 edges** today; the bowtie and the overlapping pair overrun into `tri_mask`).
- A **separate, non-aliasing** reference-mask buffer (`tri_mask[2048]` = 16384 B = exactly 128×128 with zero slack, used today for *both* prefill and readback).
- Per-case alloc / `0xA5` prefill / dispatch / readback / compare loop with per-case free+realloc. Slot *i* is a **FIXED 2 MB window** (`syscall.cyr:736-737`), so the prefill is mandatory, not optional.
- A per-case **FNV-64 digest of the reference mask, printed by BOTH `cpuref` and `gputri`, gated on equality** — the only check that catches a `--agnos` codegen divergence making both sides wrong together, which `gpu.md:1019` names by name.
- **Negative controls N1–N8, each a gate that must FIRE or the tool exits 86 and never 95:** N1 poisoned-copy comparator calibration · N2 no-dispatch arm reports UNTOUCHED · N3 coverage floor (≥3 cases with ≥1000 nonzero reference bytes — *"fully outside"* and *"zero-area"* both have all-zero correct answers, so a dead shader that writes zeroes passes them byte-exactly) · N4 ≥1 reference byte strictly between 0 and 255 (else a binary non-antialiased rasteriser passes the whole axis-aligned subset) · N5 backfacing · N6 non-multiple-of-64 width · N7 same case twice in one boot, byte-identical · N8 slot free-then-realloc (the C2g-1 stale-ghost path `gpucopy` already hit on iron).
- **Exit-code contract**, splitting today's overloaded 96: **95** all cases exact AND all controls fired · **100** no GPU / no carveout (QEMU) — split out of 96 per `gpucopy`'s precedent · **96** seam live, shader not resident · **92/91/89** mismatch classified fill-rule / shape / tgid-mapping · **88** UNTOUCHED · **87** wrote, covered nothing · **86** a negative control failed · **85** in-tool reference digest ≠ host `cpuref` digest · **90** named `#92` fault · **84** unknown arg.
- **Wiring:** `stage_one agnos/gpu-test gputri.cyr gputri` in `scripts/burn/stage-tools.sh` and a `gputri) _src="tests/gpu/build/gputri_agnos"` arm in `burn-prep.sh`'s tool map. **`gputri` appears in NEITHER today** (`grep -rn gputri scripts/` → no matches), so a burn would run an absent or hand-staged binary against a fresh kernel.

---

### B9 🔥 IRON — **BURN 1. THREE ORACLES, ONE FLASH, DELIBERATELY NARROW.**
Run in this order so a red localises to one of three things instead of to "the shader":

1. **`gputri --valu`** — a ~15-instruction smoke kernel writing known results for `v_mul_hi_u32` (`0xFFFFFFFF×0xFFFFFFFF→0xFFFFFFFE`, `0x80000000×2→1`, `0x80000000×0x80000000→0x40000000`, `3×5→0`), `v_ffbh_u32`, `v_min_i32`/`v_max_i32`/`v_min_u32`/`v_max_u32`, `v_cndmask_b32`, `v_cmp_ge_u32`, `v_addc_co_u32` into a readback slot. ⚠ **`v_mul_hi_u32` appears in NO shipped agnos shader** (`v_mul_lo_u32` is in `matmul_i32.s` and `matmul_dot.s`; `mul_hi` in neither) and the entire divider rests on it. **Gate: all values exact.** If red, the divider is 25 instructions wide, not 250, and the fallback is surveyor 4's double-and-add (verified 0/24,316, no `mul_hi`, ~6.7× slower per crossing, same prologue).
2. **`gputri --prep`** — dispatch 1 only, on a 3-edge triangle; the kernel prints the first three 32-byte prep records via `klug`, `gputri` prints its own host-computed table in the same boot, operator captures one text file ([[reference_klug_text_burn_capture]]). **Gate: identical.** This gives the setup kernel — including the 32-iteration reciprocal loop and the horizontal-edge clamp — **its own oracle**, so "prologue wrong" and "divider wrong" never both present as "wrong edge pixels".
3. **`gputri --cov`** — the itemised corpus at **64×64 with `n_edges ≤ 8` only**, plus N1–N8. **Gate: 95.**

**Additions specific to this burn:** a `gpu_ring_breadcrumb()` immediately before `DISPATCH_DIRECT` — it exists (`gpu.cyr:209-217`) but its only callers are the fault-net test, so a hang today gives `rptr`/`wptr` and names no packet; and `gpu_last_wait_us` printed per case.

**Pre-registered failure table (`gpu.md`'s four, plus two this design adds):**

| observation | indictment |
|---|---|
| all-sentinel | the **post-dispatch TC write-back** is missing — the iron capture (`shader_cohere.txt:133-141`) shows 0-of-4096 with WB=off and 4096-of-4096 COHERENT with INV=off, so `gpu.cyr:2192-2193`'s attribution of that number to the *invalidate* is **backwards** and must be corrected before anyone cites this row |
| wrong shape | edge setup / the prep table (already separated by oracle 2) |
| right shape, wrong edge px | fill rule / the span walk |
| some blocks right | tgid mapping (largely removed by 64×1) |
| **every 4th byte right, others stale** | ⭐ **`global_store_byte` lane clobber.** No agnos shader has ever issued a sub-dword store (the only byte op anywhere is a `global_load_ubyte` in `blend_cov`). This is A3's finding and it is **not avoided by any design** — it hits any 8bpp mask writer. Fallback: 4 px/lane packed with `v_perm_b32` (whose encoding `perm.s` already proves) into one `global_store_dword`, at the cost of `gx = ceil(w/256)`. |
| **mask right except the last fragment of some pixels** | the breakpoint walk's terminator or the `v > pr` clamp |

---

### B10 🔥 IRON — **BURN 2. Raise the envelope on evidence, and fire rung 10's kill gate.**
Full 20-case corpus including the 64-gon; `n_edges` at 8/32/64/128/256 and mask sizes 64²/128²/512², recording `gpu_last_wait_us` at each point. **Set the shipped `EDGE_CAP` from the measured curve, not from §1.6's model.** Then rung 10's crossover measurement in the same tool run at zero extra flash — which this design can do honestly *because scan conversion is on the GPU* (see §5).

---

## 4. HOW THE PLAN ANSWERS EVERY SURVIVING REFUTATION

| # | Refutation | Answer |
|---|---|---|
| **J1-A** | A1's 30-iteration divider is **wrong** on legal input: `ax=962495017, ay=-813168629, bx=-794569038, by=256011723, sy=-118319317` → cpuref `-179402837`, A1 `-44612492` (off by 2057 px). 6,859/120,000 wrong at `\\|coord\\| ≤ 2^30`, inside cpuref's domain. | **Accepted and avoided.** A1's divider is not used. MULINV verified 0/600,000 at `2^28/2^29/2^30` this session. And §2.5 forbids deriving any divider parameter from the guard. |
| **J1-B** | A2's Part C ends at `xx = ax ± Q` **unconditionally** — no validity flag, no INF pad — so off-guard edges still inject a crossing at `x = ax`. Breaks cpuref's *first* corpus case: 1280/4096 bytes wrong. | **Fixed structurally.** The guard mask `s[act]` is applied at **three** points, not one: (i) `u := 0` when off-guard (line 5), (ii) `v_cndmask` to **0** before the winding accumulate, (iii) `v_cndmask` to **INF** before the min-reduction. A2 had only (i). Because no crossing list is materialised, there is no pad array to get wrong. B2 tests this at zero burns. |
| **J1-C** | span_cov could not be refuted on bit-exactness, **but** it does not perform the computation the oracle exists to test. | **Accepted — which is why A3 is not the shipped rung.** Its staging value is taken as B2 (host, free), and its two genuinely portable findings — `min(acc,65536)` and the sub-dword-store risk — are taken. |
| **J2-A** | A1's *"LDS is forced, not chosen"* is **false** — surveyor 2 verified an LDS-free per-lane form. Having chosen LDS, A1 imports the one format the encoder cannot emit, a never-set `RSRC2` field on a granule the author admits they did not read, a dispatcher change, a nested bitonic loop, and six hand-patched offsets. | **Accepted in full. No LDS, no DS, no `RSRC2` change, no dispatcher change.** |
| **J2-B** | A2 never picks between its two horns: the cheap "PASS A keep (xx,dir)" variant **needs LDS**; the LDS-free variant re-scans per breakpoint, which A2's 200–240-instruction figure never counts. | **Accepted; the re-scan horn is picked explicitly and counted (§1.6).** Typical breakpoint trip count is **1**, wave-max ≈ 2, so the multiplier is ~1.5. That is what the cheap per-edge prologue buys. |
| **J2-C** | span_cov moves i64 raster math + a 256-entry insertion sort into `gpu.cyr` (8196 lines) — which `gpu.md:808` forbids verbatim — and defers rather than retires the toolchain bar. | **Avoided.** All raster math is on the GPU. The kernel gains only `gx`/`gy` arithmetic, two `store32` blob tables, and the envelope rejects. And **B4 lands the toolchain bar first, with a calibration gate.** |
| **J3-A** | A1's LDS allocation **has no oracle** — the SH regs are unreadable (S1 settled negative), and the proposed self-witness tests round-trip at offset 0, not allocation size. An echo, not an answer. | **Accepted; no LDS.** The same standard is applied to what *is* new: `v_mul_hi_u32` gets an **answer register** (oracle 1 of B9), and the prep table gets an independent readback diff (oracle 2). |
| **J3-B** | A2's SB-8 is a monolith that reconstitutes exactly the undifferentiated-blob failure it was built to avoid, and its `8×8` mapping contradicts A2's own body text and every shipped consumer. | **Fixed.** Mapping is **64×1**. The final bite is split three ways *within one burn* (B9's three oracles), and B2 already proves the raster half at zero burns. |
| **J3-C** | span_cov **corrupts rung 10's kill gate in the direction that falsely kills the arc** — its 95.7–99.6% GPU-share headline is measured at 64²+ and does not survive extrapolation to the ~625-px-per-glyph workload rung 10 is pre-registered against. | **Avoided.** This is the pure GPU rasteriser; rung 10 measures the op the arc actually wants, and B10 fires it in the same tool run at zero extra flash. |

---

## 5. THINGS I AM NOT SURE OF — flagged, not smoothed

1. **`v_mul_hi_u32` has never executed on agnos silicon.** Verified by grep of `kernel/shaders/*.s`. The whole divider rests on it being an exact 32×32→high-32 unsigned multiply. This is B9's oracle 1 and it must run before anything else on that flash. Fallback named.
2. **My instruction counts and all wall-clock figures are arithmetic, not measurement.** I did not assemble either shader and did not measure Cezanne. The divider's *correctness* I verified by execution; its *cost* I did not. The 100 ms watchdog conclusion (`4096² × E=64` over by ~4.3×) is an order-of-magnitude gate that says "measure before accepting the full ABI envelope", not a prediction.
3. **The breakpoint walk is surveyor 2's formulation, verified by them at 221/221, and re-derived by me — but I did not re-run it.** B2 exists to close that at zero burns, against the extended corpus, before any emission.
4. **`gpu.cyr:2192-2193` misattributes the coherence evidence** (credits 4096-of-4096 stale to the *pre-dispatch invalidate*; the iron capture shows it belongs to the *write-back*). Surveyor 3 caught this; I did not independently re-read `shader_cohere.txt`. Correct the **comment** before B9 cites the failure table; do **not** touch the packets.
5. **The i32→i64 sign-extension of edge coordinates** is a live one-line trap in B2 (`load32` zero-extends in Cyrius) that silently destroys corpus case 5. Flagged because it is the kind of thing that reads as a shader bug.
6. **Whether `gpo_validate_edge`'s new coordinate guard should be `±2^28` or wider** is a judgement, not a derivation. `±2^28` matches `GPU_COV_MAX_DIM = 4096`, gives the divider 2 bits of margin and the reference 5, and costs 8 compares. A wider guard is defensible and the divider survives to `±2^30` — but the *reference* is the binding constraint, not the divider.
7. **Whether the 3 shared-edge pairs were intended to count toward "20"** is genuinely ambiguous (`gpu.md:808` lists 8 *categories*, one plural). B1 itemises and says so rather than picking silently.

---

## 6. DEFERRED, AND WHY

| Deferred | Why | Trigger to revisit |
|---|---|---|
| **`rule = 1` (EVENODD)** — `gpu_edge_cov` returns `GPO_E_RULE` | `cpuref.cyr:192` implements only `wind != 0`; `syscall.cyr:1095` accepts rule 1. A rule-1 path would ship with **no oracle at all**. Rejecting keeps the accepted surface equal to the proven surface — consistent with the arc's own "a flag that is accepted and ignored" rule. | Port sadish's `(wind & 1)` branch into `refraster.cyr` (two lines) + a bowtie under both rules. Its own bite. |
| **`n_edges > 64`** — rejected with a named code, never clamped | §1.6's watchdog arithmetic; unmeasured. | B10's measured curve. |
| **Edge-parallel Phase A / a crossing cache** | Would win ~2–4× at `E ≥ 64` but needs LDS or per-workgroup scratch. The consumers are triangles. | Only if B10 shows high-`E` masks matter to a real consumer. |
| **f64 divider (`v_rcp_f64` + Newton + `DIV_FIXUP`)** | ~6× fewer ops at small `E`, but every op is rate-1/16 on a Cezanne APU, and judge 1 measured **bare f64 wrong in 158,445/600,000 adversarial cases at the `±4096 px` envelope** (surveyor 4's "0 fixup / 300,000" holds only in *their* narrower range — surveyor 2 predicted the failure from theory and was right). It needs an integer remainder fixup to ship. | Never precede a divider proven on iron. Post-B10 optimisation at most. |
| **Chaining both dispatches into one submission** | Two sequential `gpu_blend_cov_run` calls already work with zero new PM4 and reuse the S3-proven producer→consumer coherence. Chaining saves ~60 µs. | Rung 10, if the fixed cost dominates. |
| **`gpu_blend_cov_run`'s duplicated unconditional `TCWB`** (7 dwords/dispatch) and its **ungated `ACQUIRE_MEM`s** | Removing a coherence packet is the class that cost eight burns at C2g-1. | Its own bite, with the S3 arms re-run. **Never folded into 9b.** |
| **`8×8` tile mapping from `gpu.md:816`** | Deviated to 64×1 for the three reasons in §1.1. | Record the deviation in the rung row the way 9a recorded `dstxy`. |
| **Full `4096² × 256`-edge envelope** | Unmeasured against any watchdog. | B10. |
| **Active-edge bucketing / bbox culling** | Turns the `O(E)` per-pixel scan into `O(active)`. Real, and the correct scale-up. | After 9b is green; own bite. |

---

## 7. ONE-PARAGRAPH SUMMARY FOR THE ROW

> **9b = 11 bites, 8 at zero burns.** `edge_cov` is a **two-dispatch** gfx90c rasteriser: a per-edge prologue kernel computes `(ylo, yhi, M, d, V, L)` into an 8 KB arena table using a 32-iteration exact integer reciprocal, then a **64×1, one-lane-per-pixel** raster kernel walks the edge table per sub-scanline with a **sort-free breakpoint walk**, computing each crossing with **25 branch-free 32-bit VALU** via `q̂ = (P·V)>>63` plus **one** correction — exact, trunc-toward-zero, proved algebraically and verified over 600,000 whole-expression cases at `±2^30` with **zero mismatches and corrections never above 1**. **No LDS, no DS instruction, no sort, no cross-lane operation, no `RSRC2` change, no dispatcher change, no `v_rcp` of any width, no new encoding format.** ~100 + ~55 instructions across two blobs in arena slots 6 and 7. Preconditions landed as their own bites: the `refraster.cyr` extraction with the `accrow` fatal fixed, the itemised 20-case corpus, the `±2^28` coordinate guard (required for the *reference* to be well-defined at all), and an authoring tool calibrated by re-emitting `blend_cov`'s 67 shipped dwords. **Deviations recorded: 64×1 not 8×8; NONZERO only; `n_edges ≤ 64` for the first landing.**"

---

## ⛔ STATUS — SHIPPED. THIS IS HISTORY, NOT A PLAN. (banner added 2026-07-28)

**Rung 9b shipped and is iron-closed** — `edge_cov` is op `0x08 GPU_OP_EDGE_COV`, `GPU_OP_SUPPORTED` bit 8, iron-validated at **1.56.17** (`gputri --cov` exit 95, 20 of 20 byte-identical to `refraster.cyr`). Everything below is the plan that produced it. **Read it for the refutations, not for the numbers.**

⛔ **Numbers in this file that the shipped kernel contradicts — verified against source 2026-07-28:**

| This file says | Shipped | Where |
|---|---|---|
| `edge_cov` blob is **133** dwords | **135** — the delta is exactly the case-14 fix (two instructions) | `edge_cov_write` in `gpu.cyr`; `shader-blob.sh check kernel/shaders/edge_cov.s edge_cov` prints `135 dwords match` |
| arena table at **`0xD0000`** | **`0xA8000`** | `gpu_regs.cyr` — moved at 1.56.19 because `0xD0000` sat *inside* the batched-op region |
| B10 raises `GPU_EDGE_CAP` | B10 ran and the gate was **REPLACED, not raised** — `GPU_EDGE_CAP` stays 256 (the ABI maximum) and the real bound is the `GPU_EDGE_WORK_MAX` **work product** `w*h*n_edges`, measured at `28.8 µs + 0.0005953*(w*h)*ne` | `gpu.cyr`, `gpo_validate_edge` |

⚠ **A companion file `edge-cov-9b-blobs.cyr.txt` was DELETED 2026-07-28.** It held the pre-burn-1 `edge_cov` blob (133 dwords) — assembler output that was already wrong when it was committed, referenced by nothing, and indistinguishable at a glance from the shipped table. A stale blob sitting next to a plan is a trap, not a record; the authority is the committed `*_write()` table in `gpu.cyr`, gated by `shader-blob.sh`.

⚠ **351 lines of agent-orchestration JSON were removed from the end of this file 2026-07-28.** They were captured by accident when the synthesis agent's output was pasted in, contained no claim about the kernel, and left the file ending mid-JSON with a duplicate copy of its own prose escaped inside a string. Nothing about the plan was lost.
