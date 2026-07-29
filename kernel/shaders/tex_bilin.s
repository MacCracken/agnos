// tex_bilin.s — RUNG 15: BILINEAR (4-tap) texture filtering on gfx90c.
//
// Derived line-for-line from tex_rgba.s (rung 13, iron-proven). Everything up to and including the
// E_A/E_B/E_C setup, and everything from L_HAVE_TEXEL onward, is BYTE-FOR-BYTE the rung 13 code.
// Only three things change, and they are marked ⭐RUNG15 throughout:
//   1. each axis captures the 8-bit FRACTION before it floors, and emits TWO indices, not one;
//   2. the fetch pulls FOUR texels instead of one;
//   3. a 4-tap integer blend collapses them to the single texel v25 that rung 13's tail expects.
//
// ⛔ NO MIMG, NO T#, NO S#, NO SAMPLER DESCRIPTOR — unchanged from rung 13, and bilinear is exactly
// the rung where the temptation to reach for one is strongest. Every instruction below is already
// exercised by an iron-proven blob.
//
// ⛔ E IS SIGNED AND ITS HIGH DWORD MUST BE MULTIPLIED SIGNED. Rung 11 lost FOUR IRON BURNS to
// exactly this: v_mul_hi_u32 on the high half of a signed 64-bit E adds a spurious 2^64*p whenever
// a sample centre falls outside the frame. Texturing extrapolates constantly, so negative E is the
// COMMON case here rather than the corner. Every high-half multiply below carries the fixup
//     mul_hi_i32(a,b) = mul_hi_u32(a,b) - ((a>>31)&b) - ((b>>31)&a)
// with the second term omitted DELIBERATELY because the multiplicands are biased non-negative.
//
// ⭐ THE MIN-BIAS IS WHY THE MULTIPLICANDS ARE NON-NEGATIVE. E_A + E_B + E_C == 2A identically, so
//     N = E_A*u0 + E_B*u1 + E_C*u2 = 2A*m + E_A*(u0-m) + E_B*(u1-m) + E_C*(u2-m)
// and m = min(u0,u1,u2) makes every delta >= 0. The CPU hoists m, the three deltas and both
// comparison limits into the record, so this kernel never computes a minimum and never divides.
//
// ⭐ THE FILTER IS INTEGER, NOT FLOAT, AND IT IS EXACT. gpu.md's rung-15 row specified
// `v_cvt_f32_ubyte0..3` + lerp + `v_cvt_pk_u8_f32`, and named its own risk: matching gfx9's f32
// rounding in a CPU reference. With 8-bit weights,
//     w00 = (256-fx)*(256-fy)   w10 = fx*(256-fy)   w01 = (256-fx)*fy   w11 = fx*fy
//     out = (t00*w00 + t10*w10 + t01*w01 + t11*w11) >> 16
// the weights sum to EXACTLY 65536 for all 65,536 (fx,fy) pairs, so a flat texture reproduces with
// zero DC error, and the accumulator peaks at 255*65536 = 16,711,680 — 8 bits inside a 32-bit lane.
// Proven exhaustively by tests/gpu/bigate.cyr before this file existed. There is no float here, so
// there is no rounding to match: the row's named risk is ELIMINATED, not mitigated. This shader
// contains ZERO v_cvt, exactly like rung 13.
//
// ⭐ THE PREP RECORD IS UNCHANGED. Bilinear needs no new field — the fraction is already present in
// the 16.16 coordinate that rung 13 computes and then throws away. `gpu_tex_prep` is untouched, so
// this rung adds ZERO uncached stores to the per-primitive CPU cost that 1.56.27/28 just cut 4x.
// Q9 +144 stays the reserved extension point.
//
// ============================================================================================
// ⛔⛔ THE HALF-TEXEL BIAS — ADDED AFTER THE FIRST IRON BURN. THE BURN SAID "5 of 5 EXACT" AND THE
//     FILTER WAS STILL WRONG. READ THIS BEFORE TOUCHING THE AXIS BLOCKS.
// ============================================================================================
// The first version of this blob took its taps from floor(u) with weight frac(u). `gputex` came back
// **BILINEAR 5 of 5 EXACT** — shader byte-identical to the bicore reference on every frame — while
// frame 0, the 1:1 identity frame, reported `vs NEAREST: 35 px differ`. A bilinear filter at exact
// 1:1 magnification must reproduce the texture EXACTLY. It did not.
//
// ⭐ THE ARGUMENT IS CONVENTION-FREE, so "our convention differs" was never available as a defence.
// Let texel i's centre sit at i+c for ANY c. Then correct nearest = floor(u - c + 0.5) and correct
// linear taps = floor(u - c) — differing by EXACTLY 0.5 for every c. This blob shipped nearest =
// floor(u) (tex_rgba, iron-proven 17/17) and bilinear = floor(u): a difference of ZERO. floor/floor
// is not a matched pair under ANY convention, and nearest was the one pinned to iron, so linear moved.
//
// ⛔⛔ THE REAL LESSON IS ABOUT THE ORACLE, NOT THE ARITHMETIC. Byte-identity between a shader and its
// reference is STRUCTURALLY BLIND to an error the two SHARE. bicore, bimodel, texcore's
// tex_fetch_bilin and this file all implemented the same wrong convention, so all of them agreed and
// every gate built on their agreement went green. Worse, the two "corner exactness" gates (bigate G2,
// texgate GATE 10) probed EXACT INTEGER coordinates — and `tex_uv_at` always adds 32768 for the pixel
// centre, so **a pixel-centre rasteriser can never emit an integer u at any integer scale**. Those
// gates were collecting evidence at coordinates the raster path cannot produce: precisely the null
// set of the error, and one of them actively ASSERTED the bug.
// ⇒ The only thing that caught it was `gputex`'s DISCRIMINATION GATE — the `vs NEAREST` line — which
// exists because it is the one measurement in the suite that compares against something OTHER than
// the reference. **At least one gate must test an EXTERNAL invariant, not internal agreement.**
//
// ============================================================================================
// ⛔⛔ THE REGISTER MAP. WRITE IT DOWN, THEN TRANSCRIBE — NEVER THE OTHER WAY ROUND.
// ============================================================================================
// Rung 13 lost an iron burn to a scratch write over a live v19: A2_hi is 0 for any frame whose area
// fits 32 bits, so the stray `v_mul_lo_u32 v19, ...` wrote ZERO over the stashed U index and the
// screen came back as texel 0 everywhere — a picture indistinguishable from a dead shader, and
// invisible to llvm-mc, to the blob gate AND to the host model. [[reference_handwritten_shader_regalloc]]
//
// tex_rgba's high-water is v31 against 32 declared VGPRs: ZERO headroom. Bilinear cannot be
// hand-fitted into that, so the declaration is raised to 48 (GPU_COMPUTE_PGM_RSRC1_TEXBI =
// 0x00AC020B) and every new value gets a NAMED register, none of them below v32.
//
// ⚠ 48 VGPRs is an occupancy trade: 8 waves/SIMD -> 5. It is the right trade and the MEASUREMENT
// says so, not intuition — 1.56.26/28 showed a DOOM frame is 4.71 ms of CPU prep against 0.09 ms of
// GPU, so waves-in-flight is the cheap resource here. RSRC1_TEXBI is a SEPARATE constant rather than
// a widened RSRC1_TEX because RSRC1_TEX is shared by gpu_tex_list (op 0x0C) and gpu_tri_tex (op
// 0x0B), both shipped and both iron-proven; widening it in place would cut their occupancy for
// nothing.
//
//   INHERITED FROM RUNG 13 — liveness UNCHANGED, do not write these:
//     v0        lane id (system)                    v1     px            [live to the store]
//     v2:v3     dest address                        v4     coverage      [live to L_MOD]
//     v5,v6     Pcx, Pcy         [dead after E setup]
//     v7        scratch          v8:v9  E_B   v10:v11 E_C   v12:v13 E_A  [all dead after V axis]
//     v14..v18  scratch / address pair              v15    dst pixel (late)
//     v19       tu = x0                             ⭐RUNG15: now the FIRST U tap, not "the" tap
//     v20,v21,v22  N accumulator (96-bit)  [dead after V axis; reused as tap indices]
//     v23       quotient / index                    v25    THE TEXEL (blend output, tail input)
//     v26,v27   src accumulator, qa                 v28..v31  blend scratch
//
//   ⭐RUNG15 — NEW, all >= v32, none aliasing anything above:
//     v32   x1   second U tap index      [set in the U tail, live to the fetch]
//     v33   fx   U fraction, 0..255      [set in the U block, MUST survive the whole V block]
//     v34   y0   first V tap index       [set in the V tail, live to the fetch]
//     v35   y1   second V tap index      [set in the V tail, live to the fetch]
//     v36   fy   V fraction, 0..255      [set in the V block, live to the blend]
//     v37   t00  texel (x0,y0)           v38  t10  texel (x1,y0)
//     v39   t01  texel (x0,y1)           v40  t11  texel (x1,y1)
//     v41   w00  v42 w10  v43 w01  v44 w11      [weights, computed after the fetch]
//     v45   ix, then per-channel scratch   v46  iy, then the channel accumulator
//   HIGH WATER = v46  =>  47 in use, 48 declared. One spare, deliberately: a shader with zero
//   headroom is how the v19 clobber happened, and the next edit to this file should not have to
//   re-open the descriptor to add one temporary.
//
//   ⚠ THE V BLOCK IS A STRAIGHT-LINE COPY OF THE U BLOCK AND TOUCHES v16-v18, v20-v23, v28-v31.
//   It touches NONE of v19, v32, v33. That is the invariant rung 13's burn was about; it now
//   covers three registers instead of one.
//
// ============================================================================================
// ⛔⛔ TWO ORDERING TRAPS FOUND IN THE SPECIFICATION, BEFORE A LINE WAS WRITTEN. BOTH ARE
//     CORRECT UNDER WRAP AND WRONG UNDER CLAMP — I.E. INVISIBLE TO A WRAP-ONLY TEST SUITE.
// ============================================================================================
// TRAP 1 — THE +1 NEIGHBOUR COMES FROM THE PRE-CLAMP FLOOR, NEVER FROM THE CLAMPED INDEX.
//   Rung 13 stashes the POST-wrap/clamp index in v19. Deriving x1 from it computes clamp(clamp(bx)+1),
//   and that is NOT clamp(bx+1): for bx = -1, clamp(clamp(-1)+1) = 1 while clamp(-1+1) = 0. Off by a
//   whole texel, on exactly the extrapolated coordinates a filter exists to smooth. Under mask-WRAP
//   the two orders agree identically, so a wrap-only sweep would never see it.
//   ⇒ every tail below derives BOTH taps from v23 while v23 still holds the raw floor.
//   bicore/bimodel already specify it this way (`x1 = wrap(bx+1)`, not `wrap(x0+1)`) — the model is
//   the oracle precisely because it got this right first.
//
// TRAP 2 — THE OUT-OF-DOMAIN PREDICATES MUST FIRE ON **BOTH** TAPS.
//   Rung 13's CLAMP path ends with two v_cndmask selects: N >= limU forces the last texel, N < 0
//   forces texel 0. Both exist because the u32 reciprocal quotient is GARBAGE outside its domain.
//   If they were applied only to x0, x1 would still be derived from that garbage quotient and the
//   filter would blend a correct edge texel against an arbitrary one. Both selects therefore run
//   twice, on v19 and v32 (and v34/v35 on the V axis). The result is that an out-of-domain sample
//   collapses to a single texel, which is what rung 13 does today.
//   ⚠ THIS IS THE ONE THING bimodel DOES NOT COVER. The model takes a 16.16 UV as GIVEN; the
//   divide-and-predicate stage is upstream of it. So a red burn confined to extrapolated pixels is
//   NOT automatically an emission fault — it is the one place the "green model ⇒ blame the emission"
//   inference does not hold. Named here so nobody has to rediscover it mid-burn.
//   ⭐ fx/fy are deliberately NOT forced when a predicate fires, and that is provable rather than
//   hopeful: with x0 == x1 the U pair collapses to t00*(w00+w10) + t01*(w01+w11) = 256*(A*iy + B*fy),
//   whose >>16 is exactly the V-only lerp. The fraction cannot contribute. Same on the other axis.
//
// Kernargs, as gpu_blend_cov_run stages them — IDENTICAL to rung 13:
//   s[0:1] = the 160-byte TEX-PREP record   s[2:3] = destination rect base
//   s4     = destination pitch in BYTES     s5 = unused
//   s6     = w                              s7 = h
//   s8     = tgid_x (system)                s9 = tgid_y (system)
//
// The TEX-PREP record, 160 B, ten dwordx4 loads. Written by gpu_tex_prep; ring 3 never sees it:
//   Q0 +0    cov_lo cov_hi t 32-t
//   Q1 +16   Dh V L fmt              (fmt: 0 = RGBA8, 1 = IDX8 + LUT)
//   Q2 +32   A2_lo A2_hi tw th
//   Q3 +48   kxB kyB k0B_lo k0B_hi
//   Q4 +64   kxC kyC k0C_lo k0C_hi
//   Q5 +80   tex_lo tex_hi lut_lo lut_hi
//   Q6 +96   du0 du1 du2 mu
//   Q7 +112  dv0 dv1 dv2 mv
//   Q8 +128  limU_lo limU_hi limV_lo limV_hi
//   Q9 +144  reserved, MUST be zero -- the extension point

.text
.globl tex_bilin
.p2align 8
.type tex_bilin,@function

tex_bilin:
    s_mov_b64       exec, -1

    s_load_dwordx4  s[24:27], s[0:1], 0x0
    s_load_dwordx4  s[28:31], s[0:1], 0x10
    s_load_dwordx4  s[32:35], s[0:1], 0x20
    s_load_dwordx4  s[36:39], s[0:1], 0x30
    s_load_dwordx4  s[40:43], s[0:1], 0x40
    s_load_dwordx4  s[44:47], s[0:1], 0x50
    s_load_dwordx4  s[48:51], s[0:1], 0x60
    s_load_dwordx4  s[52:55], s[0:1], 0x70
    s_load_dwordx4  s[56:59], s[0:1], 0x80
    s_waitcnt       lgkmcnt(0)

    // ---- px = tgid_x*64 + lane, py = tgid_y. Bounds guard BEFORE any address is formed ----
    s_lshl_b32      s10, s8, 6
    v_add_u32       v1, s10, v0             // v1 = px
    v_cmp_gt_u32    vcc, s6, v1             // w > px ?
    s_and_saveexec_b64 s[20:21], vcc
    s_cbranch_execz L_END

    // ⭐ WAVE-UNIFORM BRANCH ON THE FORMAT WORD. `flags` lives in an SGPR, so every lane takes the
    // same side — the one place a scalar branch is legitimate. Bit 1 is FULLCOV.
    s_and_b32       s13, s31, 2
    s_cmp_eq_u32    s13, 2
    s_cbranch_scc1  L_FULLCOV

    // ---- coverage byte at (px, py). The mask is w bytes per row, tightly packed. ----
    s_mul_i32       s11, s9, s6             // py * w
    v_add_u32       v7, s11, v1
    v_mov_b32       v14, s24
    v_mov_b32       v15, s25
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_ubyte v4, v[14:15], off
    s_waitcnt       vmcnt(0)

    // ⛔ ZERO COVERAGE STORES NOTHING. A lane outside the shape must leave the destination alone;
    // writing "the blend of a transparent source" would still clobber whatever a previous triangle
    // put there, which is precisely the class of bug rung 12's batch path was wrecked by.
    v_cmp_ne_u32    vcc, 0, v4
    s_and_saveexec_b64 s[22:23], vcc
    s_cbranch_execz L_END
    s_branch        L_HAVE_COV

L_FULLCOV:
    // ⭐ FULLCOV: every pixel is covered, so there is no mask to read and no lane to mask off.
    // The kernel skipped both coverage dispatches, so the mask slot holds STALE bytes from a
    // previous op — loading it would be reading another primitive's shape. 255 is not an
    // optimisation here, it is the only correct value.
    v_mov_b32       v4, 0xFF

L_HAVE_COV:

    // ---- sample point at the pixel CENTRE, 16.16 ----
    v_lshlrev_b32   v5, 16, v1
    v_add_u32       v5, 0x8000, v5          // Pcx
    s_lshl_b32      s12, s9, 16
    s_add_i32       s12, s12, 0x8000
    v_mov_b32       v6, s12                 // Pcy

    // ---- E_B = kxB*Pcx + kyB*Pcy + k0B, signed, 64-bit ----
    v_mul_lo_u32    v8,  s36, v5
    v_mul_hi_u32    v9,  s36, v5
    s_ashr_i32      s13, s36, 31
    v_and_b32       v14, s13, v5
    v_sub_u32       v9,  v9, v14
    v_ashrrev_i32   v14, 31, v5
    v_and_b32       v14, s36, v14
    v_sub_u32       v9,  v9, v14

    v_mul_lo_u32    v10, s37, v6
    v_mul_hi_u32    v11, s37, v6
    s_ashr_i32      s13, s37, 31
    v_and_b32       v14, s13, v6
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s37, v14
    v_sub_u32       v11, v11, v14

    v_add_co_u32    v8,  vcc, v8, v10
    v_addc_co_u32   v9,  vcc, v9, v11, vcc
    v_mov_b32       v14, s38
    v_mov_b32       v15, s39
    v_add_co_u32    v8,  vcc, v8, v14
    v_addc_co_u32   v9,  vcc, v9, v15, vcc  // v[8:9] = E_B

    // ---- E_C = kxC*Pcx + kyC*Pcy + k0C ----
    v_mul_lo_u32    v10, s40, v5
    v_mul_hi_u32    v11, s40, v5
    s_ashr_i32      s13, s40, 31
    v_and_b32       v14, s13, v5
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v5
    v_and_b32       v14, s40, v14
    v_sub_u32       v11, v11, v14

    v_mul_lo_u32    v12, s41, v6
    v_mul_hi_u32    v13, s41, v6
    s_ashr_i32      s13, s41, 31
    v_and_b32       v14, s13, v6
    v_sub_u32       v13, v13, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s41, v14
    v_sub_u32       v13, v13, v14

    v_add_co_u32    v10, vcc, v10, v12
    v_addc_co_u32   v11, vcc, v11, v13, vcc
    v_mov_b32       v14, s42
    v_mov_b32       v15, s43
    v_add_co_u32    v10, vcc, v10, v14
    v_addc_co_u32   v11, vcc, v11, v15, vcc // v[10:11] = E_C

    // ---- E_A = 2A - E_B - E_C. Derived, not a third cross product. ----
    v_mov_b32       v12, s32
    v_mov_b32       v13, s33
    v_sub_co_u32    v12, vcc, v12, v8
    v_subb_co_u32   v13, vcc, v13, v9, vcc
    v_sub_co_u32    v12, vcc, v12, v10
    v_subb_co_u32   v13, vcc, v13, v11, vcc // v[12:13] = E_A

    // ======================================================================================
    // U AXIS
    // ======================================================================================
    s_mov_b32       s14, s48                // du0
    s_mov_b32       s15, s49                // du1
    s_mov_b32       s16, s50                // du2
    s_mov_b32       s17, s51                // mu
    s_mov_b32       s18, s56                // limU_lo
    s_mov_b32       s19, s57                // limU_hi
    s_mov_b32       s60, s34                // tw
    v_mov_b32       v20, 0
    v_mov_b32       v21, 0
    v_mov_b32       v22, 0
    // -- N = E_A*du0 + E_B*du1 + E_C*du2, 96 bits, every high half SIGNED --
    v_mul_lo_u32    v16, v12, s14
    v_mul_hi_u32    v17, v12, s14
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v13, s14
    v_mul_hi_u32    v17, v13, s14
    v_ashrrev_i32   v18, 31, v13
    v_and_b32       v18, s14, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v8, s15
    v_mul_hi_u32    v17, v8, s15
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v9, s15
    v_mul_hi_u32    v17, v9, s15
    v_ashrrev_i32   v18, 31, v9
    v_and_b32       v18, s15, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v10, s16
    v_mul_hi_u32    v17, v10, s16
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v11, s16
    v_mul_hi_u32    v17, v11, s16
    v_ashrrev_i32   v18, 31, v11
    v_and_b32       v18, s16, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    // ⛔ NO SCALAR BRANCH ON A PER-LANE CONDITION. s_cbranch_vccz tests whether ALL lanes matched,
    // so one lane with a negative numerator would drag EVERY lane down the same path.
    // [[reference_gfx9_per_lane_control_flow]] The quotient is computed for every lane and the two
    // short-circuits are applied as v_cndmask selects afterwards.
    v_lshrrev_b32   v16, s26, v20
    v_lshlrev_b32   v17, s27, v21
    v_or_b32        v16, v16, v17
    v_lshrrev_b32   v17, s26, v21
    v_lshlrev_b32   v18, s27, v22
    v_or_b32        v17, v17, v18

    v_lshlrev_b32   v28, s30, v16
    s_sub_i32       s61, 32, s30
    v_lshrrev_b32   v29, s61, v16
    v_lshlrev_b32   v30, s30, v17
    v_or_b32        v29, v30, v29
    v_mul_hi_u32    v30, v28, s29
    v_mul_lo_u32    v31, v29, s29
    v_mul_hi_u32    v28, v29, s29
    v_add_co_u32    v30, vcc, v30, v31
    v_addc_co_u32   v28, vcc, 0, v28, vcc
    v_lshlrev_b32   v29, 1, v28
    v_lshrrev_b32   v30, 31, v30
    v_or_b32        v23, v29, v30

    // ⛔ v18 IS REUSED HERE, NOT v19. The first rung-13 version used v19 as scratch for lo(q1*A2hi)
    // — and v19 HOLDS THE STASHED U INDEX. Because A2_hi is 0 for any frame whose area fits 32 bits,
    // that multiply wrote ZERO over tu and iron came back with texel 0 everywhere. q+1 is dead after
    // this product, so v18 is free to take it.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v18, v18, s33
    v_add_u32       v17, v17, v18
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    // ⭐RUNG15 — CAPTURE THE FRACTION BEFORE THE FLOOR DESTROYS IT.
    // v23 now holds the U coordinate in 16.16. Rung 13 floors it and throws the low half away; that
    // low half IS the filter weight. `v_lshrrev_b32` + `v_and_b32` rather than one `v_bfe_u32`:
    // identical result, and this pair is the exact idiom L_MOD already runs on iron.
    // ⚠ TRUNCATING, matching bi_frac/bm_frac32. A rounded fraction here against a truncated one in
    // the reference is precisely the mismatch class this rung's host gates exist to catch (bimodel
    // M5), and it would show as a uniform half-texel drift, not as an obvious break.
    v_add_u32       v23, s17, v23           // q + mu, 16.16
    // ⛔⛔ THE HALF-TEXEL BIAS. ITS ABSENCE WAS THE 1.56.29 BURN'S FINDING — see the header.
    // 0xFFFF8000 is -32768 in two's complement: one VOP2-with-literal, no VCC, no new VGPR.
    // ⚠ MUST PRECEDE THE FRACTION CAPTURE. Both the taps and the weight derive from the shifted
    // coordinate; biasing after the capture would fix the taps and leave the weight half a texel out,
    // which is a subtler wrong than the bug it replaces.
    // ⚠ v_add_u32-with-literal, NOT v_subrev_u32: `edgeasm.cyr` already emits this encoding class
    // (e_vop2_lit), so the sovereign second assembler covers it for free. v_subrev would have been
    // one dword cheaper and a NEW encoding class — the two-assembler discipline costs more than a dword.
    v_add_u32       v23, 0xFFFF8000, v23    // ⭐ -0.5 texel: taps from floor(u-0.5), weight frac(u-0.5)
    v_lshrrev_b32   v33, 8, v23
    v_and_b32       v33, 0xFF, v33          // ⭐ v33 = fx, 0..255 — MUST SURVIVE THE WHOLE V BLOCK

    // ⚠ ARITHMETIC shift: q+m goes negative where the UV frame extrapolates below zero, and a
    // logical shift would make that a huge positive index selecting the OPPOSITE edge.
    // ⚠⚠ v23 IS NOW bx, THE PRE-CLAMP FLOOR, AND BOTH TAPS COME FROM IT (trap 1 in the header).
    // Note bx is a 32-bit value shifted right by 16, so |bx| < 2^16 and bx+1 CANNOT overflow —
    // that is why the +1 below needs no guard.
    v_ashrrev_i32   v23, 16, v23
    s_sub_i32       s61, s60, 1

    // ⛔ THE WRAP BRANCH MUST PRECEDE THE SATURATION. In rung 13's first version it sat AFTER
    // v_max_i32/v_min_i32, so wrap AND-ed an index already clamped into [0, dim-1] — a no-op, and
    // iron reported a constant texel across a tile that should have tiled 0,1,2,3.
    s_and_b32       s62, s31, 4
    s_cmp_eq_u32    s62, 4
    s_cbranch_scc1  L_U_WRAP

    // -- CLAMP: x0 = clamp(bx), x1 = clamp(bx+1). BOTH derived from v23 while it is still bx. --
    v_add_u32       v32, 1, v23
    v_max_i32       v32, 0, v32
    v_min_i32       v32, s61, v32           // ⭐ v32 = x1
    v_max_i32       v19, 0, v23
    v_min_i32       v19, s61, v19           // ⭐ v19 = x0

    // -- predicate: N >= limit => the last texel (guards the u32 quotient against wrapping).
    //    ⭐RUNG15: fires on BOTH taps (trap 2). Applied to x1 as well, or the filter blends a
    //    correct edge texel against one derived from a garbage quotient. --
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_mov_b32       v18, s61
    v_cndmask_b32   v19, v19, v18, vcc
    v_cndmask_b32   v32, v32, v18, vcc

    // -- predicate: N < 0 => texel 0. Applied LAST so it wins over the limit select. BOTH taps. --
    v_mov_b32       v18, 0
    v_cmp_lt_i32    vcc, v22, 0
    v_cndmask_b32   v19, v19, v18, vcc
    v_cndmask_b32   v32, v32, v18, vcc
    s_branch        L_U_TAIL

L_U_WRAP:
    // ⚠ The AND handles a NEGATIVE index correctly on two's complement (-1 & 7 = 7, the far edge) —
    // exactly what the reference's restored floor-divide produces. Both taps mask INDEPENDENTLY:
    // masking x0+1 instead of bx+1 would agree here, but the header's trap 1 makes bx the rule on
    // both paths so the two tails cannot drift apart.
    v_add_u32       v32, 1, v23
    v_and_b32       v32, s61, v32           // ⭐ v32 = x1 = (bx+1) & (tw-1)
    v_and_b32       v19, s61, v23           // ⭐ v19 = x0 = bx & (tw-1)
L_U_TAIL:
    // ⭐ LIVE FROM HERE THROUGH THE FETCH: v19 (x0), v32 (x1), v33 (fx).
    // The V block below must not touch any of the three.


    // ======================================================================================
    // V AXIS — the same block against Q7/Q8's second half. Straight-line duplicate, on purpose:
    // sharing one routine would need a real call/return, and two copies of proven arithmetic beat
    // a trampoline in a per-pixel path.
    // ======================================================================================
    s_mov_b32       s14, s52                // dv0
    s_mov_b32       s15, s53                // dv1
    s_mov_b32       s16, s54                // dv2
    s_mov_b32       s17, s55                // mv
    s_mov_b32       s18, s58                // limV_lo
    s_mov_b32       s19, s59                // limV_hi
    s_mov_b32       s60, s35                // th
    v_mov_b32       v20, 0
    v_mov_b32       v21, 0
    v_mov_b32       v22, 0

    v_mul_lo_u32    v16, v12, s14
    v_mul_hi_u32    v17, v12, s14
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v13, s14
    v_mul_hi_u32    v17, v13, s14
    v_ashrrev_i32   v18, 31, v13
    v_and_b32       v18, s14, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v8, s15
    v_mul_hi_u32    v17, v8, s15
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v9, s15
    v_mul_hi_u32    v17, v9, s15
    v_ashrrev_i32   v18, 31, v9
    v_and_b32       v18, s15, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v10, s16
    v_mul_hi_u32    v17, v10, s16
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v11, s16
    v_mul_hi_u32    v17, v11, s16
    v_ashrrev_i32   v18, 31, v11
    v_and_b32       v18, s16, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_lshrrev_b32   v16, s26, v20
    v_lshlrev_b32   v17, s27, v21
    v_or_b32        v16, v16, v17
    v_lshrrev_b32   v17, s26, v21
    v_lshlrev_b32   v18, s27, v22
    v_or_b32        v17, v17, v18

    v_lshlrev_b32   v28, s30, v16
    s_sub_i32       s61, 32, s30
    v_lshrrev_b32   v29, s61, v16
    v_lshlrev_b32   v30, s30, v17
    v_or_b32        v29, v30, v29
    v_mul_hi_u32    v30, v28, s29
    v_mul_lo_u32    v31, v29, s29
    v_mul_hi_u32    v28, v29, s29
    v_add_co_u32    v30, vcc, v30, v31
    v_addc_co_u32   v28, vcc, 0, v28, vcc
    v_lshlrev_b32   v29, 1, v28
    v_lshrrev_b32   v30, 31, v30
    v_or_b32        v23, v29, v30

    // ⛔ v18 IS REUSED HERE, NOT v19 — see the U axis. ⭐RUNG15: v32 and v33 are ALSO live across
    // this block now, so the same rule covers three registers, not one.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v18, v18, s33
    v_add_u32       v17, v17, v18
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    // ⭐RUNG15 — capture fy before the floor, exactly as the U axis captured fx.
    v_add_u32       v23, s17, v23           // q + mv, 16.16
    v_add_u32       v23, 0xFFFF8000, v23    // ⭐ -0.5 texel — see the U axis for the full reasoning
    v_lshrrev_b32   v36, 8, v23
    v_and_b32       v36, 0xFF, v36          // ⭐ v36 = fy, 0..255

    v_ashrrev_i32   v23, 16, v23            // v23 = by, the PRE-clamp floor
    s_sub_i32       s61, s60, 1

    s_and_b32       s62, s31, 4
    s_cmp_eq_u32    s62, 4
    s_cbranch_scc1  L_V_WRAP

    // -- CLAMP: y0 = clamp(by), y1 = clamp(by+1). BOTH from v23 while it is still by. --
    v_add_u32       v35, 1, v23
    v_max_i32       v35, 0, v35
    v_min_i32       v35, s61, v35           // ⭐ v35 = y1
    v_max_i32       v34, 0, v23
    v_min_i32       v34, s61, v34           // ⭐ v34 = y0

    // -- predicate: N >= limit => the last texel. ⭐RUNG15: BOTH taps. --
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_mov_b32       v18, s61
    v_cndmask_b32   v34, v34, v18, vcc
    v_cndmask_b32   v35, v35, v18, vcc

    // -- predicate: N < 0 => texel 0. Applied LAST. ⭐RUNG15: BOTH taps. --
    v_mov_b32       v18, 0
    v_cmp_lt_i32    vcc, v22, 0
    v_cndmask_b32   v34, v34, v18, vcc
    v_cndmask_b32   v35, v35, v18, vcc
    s_branch        L_V_TAIL

L_V_WRAP:
    v_add_u32       v35, 1, v23
    v_and_b32       v35, s61, v35           // ⭐ v35 = y1 = (by+1) & (th-1)
    v_and_b32       v34, s61, v23           // ⭐ v34 = y0 = by & (th-1)
L_V_TAIL:
    // v19 = x0, v32 = x1, v34 = y0, v35 = y1 — all in range, clamped or tiled per the WRAP flag.
    // v33 = fx, v36 = fy.

    // ======================================================================================
    // ⭐RUNG15 — THE FOUR-TAP FETCH
    // ======================================================================================
    // ⭐ FOUR LOADS IN FLIGHT, ONE s_waitcnt. The four texel addresses are independent, so they are
    // all formed first and all issued before the single wait. Four serialised round trips with a
    // wait between each would be the obvious transcription and would cost four full memory latencies
    // per pixel instead of one. This needs four ADDRESS PAIRS live at once — v[14:15], v[16:17],
    // v[28:29], v[30:31] — every one of them provably dead here: v14-v18 are the axis blocks'
    // scratch, v28-v31 are the divide's scratch and are not re-initialised until L_OVER.
    //
    // E_A/E_B/E_C (v8..v13) and the N accumulator (v20..v22) are ALSO dead from this point — both
    // axes are finished with them. v20..v23 are reused below as the four tap indices, which is safe
    // for exactly that reason and is stated here rather than left to be re-derived.
    v_mul_lo_u32    v20, v34, s34           // r0 = y0 * tw
    v_mul_lo_u32    v21, v35, s34           // r1 = y1 * tw
    v_add_u32       v22, v20, v19           // i00 = r0 + x0
    v_add_u32       v23, v20, v32           // i10 = r0 + x1   (r0 dead after this line)
    v_add_u32       v20, v21, v19           // i01 = r1 + x0
    v_add_u32       v21, v21, v32           // i11 = r1 + x1   (r1 dead after this line)

    // ⛔ TEST BIT 0, NOT THE WHOLE WORD. s31 became a FLAGS word when FULLCOV was added, so an
    // `s31 == 0` test would mean "RGBA8 and not fullcov" and an RGBA8 primitive with FULLCOV set
    // would fall through to the IDX8 fetch and read one byte per texel through an absent palette.
    s_and_b32       s13, s31, 1
    s_cmp_eq_u32    s13, 0
    s_cbranch_scc0  L_FETCH_IDX8

    // ---- RGBA8: four dwords, 4 bytes per texel ----
    v_lshlrev_b32   v22, 2, v22
    v_lshlrev_b32   v23, 2, v23
    v_lshlrev_b32   v20, 2, v20
    v_lshlrev_b32   v21, 2, v21

    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v22
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    v_mov_b32       v16, s44
    v_mov_b32       v17, s45
    v_add_co_u32    v16, vcc, v16, v23
    v_addc_co_u32   v17, vcc, v17, 0, vcc
    v_mov_b32       v28, s44
    v_mov_b32       v29, s45
    v_add_co_u32    v28, vcc, v28, v20
    v_addc_co_u32   v29, vcc, v29, 0, vcc
    v_mov_b32       v30, s44
    v_mov_b32       v31, s45
    v_add_co_u32    v30, vcc, v30, v21
    v_addc_co_u32   v31, vcc, v31, 0, vcc

    global_load_dword v37, v[14:15], off    // t00
    global_load_dword v38, v[16:17], off    // t10
    global_load_dword v39, v[28:29], off    // t01
    global_load_dword v40, v[30:31], off    // t11
    s_waitcnt       vmcnt(0)
    s_branch        L_HAVE_TAPS

L_FETCH_IDX8:
    // ⚠ TWO DEPENDENT ROUNDS. All four indices must land before any LUT address exists, so the
    // s_waitcnt between the rounds is load-bearing, not defensive. Within each round the four loads
    // are independent and issue together.
    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v22
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    v_mov_b32       v16, s44
    v_mov_b32       v17, s45
    v_add_co_u32    v16, vcc, v16, v23
    v_addc_co_u32   v17, vcc, v17, 0, vcc
    v_mov_b32       v28, s44
    v_mov_b32       v29, s45
    v_add_co_u32    v28, vcc, v28, v20
    v_addc_co_u32   v29, vcc, v29, 0, vcc
    v_mov_b32       v30, s44
    v_mov_b32       v31, s45
    v_add_co_u32    v30, vcc, v30, v21
    v_addc_co_u32   v31, vcc, v31, 0, vcc

    global_load_ubyte v37, v[14:15], off
    global_load_ubyte v38, v[16:17], off
    global_load_ubyte v39, v[28:29], off
    global_load_ubyte v40, v[30:31], off
    s_waitcnt       vmcnt(0)

    // ⚠ ALL FOUR LUT ADDRESSES ARE FORMED BEFORE ANY LUT LOAD IS ISSUED. The loads write v37..v40,
    // which are the very registers the addresses are read from; forming and issuing one at a time
    // would still be correct, but this ordering makes the read-before-write obvious instead of
    // relying on the reader to check load latency.
    v_lshlrev_b32   v22, 2, v37             // index * 4 into the 256-entry LUT
    v_mov_b32       v14, s46
    v_mov_b32       v15, s47
    v_add_co_u32    v14, vcc, v14, v22
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    v_lshlrev_b32   v22, 2, v38
    v_mov_b32       v16, s46
    v_mov_b32       v17, s47
    v_add_co_u32    v16, vcc, v16, v22
    v_addc_co_u32   v17, vcc, v17, 0, vcc
    v_lshlrev_b32   v22, 2, v39
    v_mov_b32       v28, s46
    v_mov_b32       v29, s47
    v_add_co_u32    v28, vcc, v28, v22
    v_addc_co_u32   v29, vcc, v29, 0, vcc
    v_lshlrev_b32   v22, 2, v40
    v_mov_b32       v30, s46
    v_mov_b32       v31, s47
    v_add_co_u32    v30, vcc, v30, v22
    v_addc_co_u32   v31, vcc, v31, 0, vcc

    global_load_dword v37, v[14:15], off
    global_load_dword v38, v[16:17], off
    global_load_dword v39, v[28:29], off
    global_load_dword v40, v[30:31], off
    s_waitcnt       vmcnt(0)

L_HAVE_TAPS:
    // ======================================================================================
    // ⭐RUNG15 — THE 4-TAP INTEGER BLEND. Collapses v37..v40 into v25, the single texel that
    // rung 13's unmodified tail consumes.
    // ======================================================================================
    // ⛔ EVERY PRODUCT AND PARTIAL SUM IS 32-BIT (v_mul_lo_u32 / v_add_u32), AND THAT IS PROVED,
    // NOT ASSUMED: bigate G4 shows the accumulator peaks at 255 * 65536 = 16,711,680 ~ 2^24, which
    // is 8 bits inside a 32-bit lane. No v_mul_hi, no 64-bit carry chain, no float.
    // The weight sum is exactly 65536 for all 65,536 (fx,fy) pairs (bigate G1), so >>16 is an exact
    // divide by the weight total and a flat texture reproduces with ZERO DC error.
    v_sub_u32       v45, 0x100, v33         // ix = 256 - fx
    v_sub_u32       v46, 0x100, v36         // iy = 256 - fy
    v_mul_lo_u32    v41, v45, v46           // w00 = ix * iy
    v_mul_lo_u32    v42, v33, v46           // w10 = fx * iy
    v_mul_lo_u32    v43, v45, v36           // w01 = ix * fy
    v_mul_lo_u32    v44, v33, v36           // w11 = fx * fy
    // ⚠ THE WEIGHT-TO-TAP ASSIGNMENT IS THE ONE THING A SUM CHECK CANNOT CATCH. Swapping w10 and
    // w01 keeps the sum at 65536 and passes bigate G1; it fails G6 (separability) and bimodel M1.
    // w10 pairs with the x1/y0 tap, w01 with the x0/y1 tap. Read that twice before editing.

    // ix/iy are dead from here; v45/v46 become the per-channel scratch and accumulator.
    v_mov_b32       v25, 0                  // the blended texel
    s_mov_b32       s45, 24                 // channel shift: A, B, G, R — descending, like L_MOD.
                                            // ⚠ s45 is tex_hi, dead now that every fetch has landed;
                                            // rung 13's tail re-initialises it for L_MOD anyway.

L_BILERP:
    v_lshrrev_b32   v45, s45, v37
    v_and_b32       v45, 0xFF, v45
    v_mul_lo_u32    v46, v45, v41           // c00 * w00
    v_lshrrev_b32   v45, s45, v38
    v_and_b32       v45, 0xFF, v45
    v_mul_lo_u32    v45, v45, v42           // c10 * w10
    v_add_u32       v46, v46, v45
    v_lshrrev_b32   v45, s45, v39
    v_and_b32       v45, 0xFF, v45
    v_mul_lo_u32    v45, v45, v43           // c01 * w01
    v_add_u32       v46, v46, v45
    v_lshrrev_b32   v45, s45, v40
    v_and_b32       v45, 0xFF, v45
    v_mul_lo_u32    v45, v45, v44           // c11 * w11
    v_add_u32       v46, v46, v45
    // ⚠ LOGICAL shift. The accumulator is a sum of products of non-negatives and cannot be negative;
    // stating the reason is what stops a future edit from reaching for v_ashrrev_i32 by symmetry
    // with the coordinate floors above, where the arithmetic shift IS required.
    v_lshrrev_b32   v46, 16, v46
    v_and_b32       v46, 0xFF, v46
    v_lshlrev_b32   v46, s45, v46
    v_or_b32        v25, v25, v46
    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_BILERP

    // ⭐RUNG15: everything from L_HAVE_TEXEL to s_endpgm is rung 13's tail VERBATIM — comments
    // included — and scripts/check/texbi-body-identity.sh proves it character for character. The
    // claim lives in the GATE, not in a comment inside the body: a copy that merely asserts it is a
    // copy is the ATOM_DRY defect class, two artifacts differing in name but not in intent. This
    // note sits OUTSIDE the compared span on purpose; putting it inside would break the identity it
    // describes, which is how the first version of this file failed its own gate.
L_HAVE_TEXEL:
    // ======================================================================================
    // COVERAGE MODULATION, then SRC-OVER — the destination address is formed only now
    // ======================================================================================
    v_mov_b32       v7, s9                  // py
    v_mul_lo_u32    v7, v7, s4              // py * pitch (BYTES)
    v_lshlrev_b32   v14, 2, v1
    v_add_u32       v7, v7, v14
    v_mov_b32       v2, s2
    v_mov_b32       v3, s3
    v_add_co_u32    v2, vcc, v2, v7
    v_addc_co_u32   v3, vcc, v3, 0, vcc
    global_load_dword v15, v[2:3], off
    s_waitcnt       vmcnt(0)

    // ⛔ THE /255 IS THE BIT-IDENTITY HINGE. `(x*a + 127) >> 8` is NOT the same function as
    // `(x*a + 127) / 255`; rung 11 established that the exact divide decides whether byte-identity
    // is achievable at all. Both loops below use the reciprocal identity
    //     floor(x/255) = (x + (x>>8) + 1) >> 8   for x < 2^24
    // and the inputs here peak at 255*255 + 127 = 65152, four orders inside that bound.
    v_mov_b32       v26, 0                  // src accumulator
    v_mov_b32       v27, 0xFF               // qa, alpha's quotient (255 until alpha is computed)
    s_mov_b32       s45, 24                 // ALPHA FIRST, so qa is live to clamp r/g/b against

L_MOD:
    v_lshrrev_b32   v14, s45, v25
    v_and_b32       v14, 0xFF, v14
    v_mul_lo_u32    v14, v14, v4            // * coverage
    v_add_u32       v14, 0x7F, v14
    v_lshrrev_b32   v16, 8, v14
    v_add_u32       v14, v14, v16
    v_add_u32       v14, 1, v14
    v_lshrrev_b32   v14, 8, v14
    v_min_u32       v14, 0xFF, v14
    s_cmp_eq_u32    s45, 24
    s_cselect_b64   s[62:63], -1, 0
    v_cndmask_b32   v27, v27, v14, s[62:63] // on the alpha pass, qa := q
    v_min_u32       v14, v14, v27           // premultiplied invariant: no channel exceeds alpha
    v_lshlrev_b32   v14, s45, v14
    v_or_b32        v26, v26, v14
    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_MOD

    // ---- out = src + dst * (255 - src_a) / 255, per channel ----
    v_lshrrev_b32   v28, 24, v26
    v_and_b32       v28, 0xFF, v28
    v_sub_u32       v28, 0xFF, v28          // inv = 255 - src_a
    v_mov_b32       v31, 0
    s_mov_b32       s45, 24

L_OVER:
    v_lshrrev_b32   v29, s45, v15
    v_and_b32       v29, 0xFF, v29          // dst channel
    v_mul_lo_u32    v29, v29, v28
    v_add_u32       v29, 0x7F, v29
    v_lshrrev_b32   v30, 8, v29
    v_add_u32       v30, v29, v30
    v_add_u32       v30, 1, v30
    v_lshrrev_b32   v30, 8, v30
    v_lshrrev_b32   v29, s45, v26
    v_and_b32       v29, 0xFF, v29          // src channel
    v_add_u32       v30, v29, v30
    v_min_u32       v30, 0xFF, v30
    v_lshlrev_b32   v30, s45, v30
    v_or_b32        v31, v31, v30
    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_OVER

    global_store_dword v[2:3], v31, off
    s_waitcnt       vmcnt(0)

L_END:
    s_endpgm

.section .rodata,"a"
.p2align 6
.amdhsa_kernel tex_bilin
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    // ⭐RUNG15: 48, not rung 13's 32. High water is v46; the spare is deliberate (see the map).
    // ⚠ THIS MUST AGREE WITH GPU_COMPUTE_PGM_RSRC1_TEXBI (0x00AC020B) in kernel/core/gpu_regs.cyr —
    // the kernel writes RSRC1 from that constant, NOT from this directive. `shader-blob.sh rsrc`
    // prints what the assembler derived here; the two are diffed by scripts/check.sh.
    .amdhsa_next_free_vgpr 48
    .amdhsa_next_free_sgpr 64
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    .amdhsa_ieee_mode 1
.end_amdhsa_kernel
