// tri_persp.s — gfx90c PERSPECTIVE-CORRECT TEXTURED TRIANGLES. 3D arc rung 18.
//
// One workgroup owns an 8x8 tile and walks that tile's triangle list in submission order in a SINGLE
// 64-lane wave, exactly rung 17's shape. What is new is the arithmetic: a 64-bit numerator held in a
// register PAIR, and an EXACT per-pixel divide by a denominator that varies per pixel.
//
// ============================================================================================
// WHAT IS PERSPECTIVE-CORRECT INTERPOLATION, AND WHY IT IS TWO OF RUNG 17'S PLANES
// ============================================================================================
//     a_persp(x,y) = [ SUM e_i * (W_i * a_i) ] / [ SUM e_i * W_i ]      with W_i = 2^16 / w_i
// Both numerator and denominator are AFFINE in (x,y), so prep hoists each to A*x + B*y + C and this
// kernel evaluates two planes and divides. ⭐ Affine texturing — what a shader that skipped the divide
// produces — is measurably wrong on the corpus figure: 1540 of 1541 covered pixels differ, worst by
// 9,902,774 in 16.16 (~151 texels). That number is what makes a green burn mean the divide HAPPENED.
//
// ⛔⛔ FIVE THINGS HERE ARE PINNED BY HOST MEASUREMENT, NOT BY PREFERENCE. Every one was established
// before a line of this file existed (tests/gpu/perspbits, perspdiv, perspgate, perspmodel — all exit
// 95, all in scripts/check/host-gpu-oracles.sh). Do not re-open them while reading code.
//
//   1. NO v_rcp_f32, ANYWHERE. The release row prescribes it and its own risk column admits the cost:
//      "the CPU reference must use the same approximation or the diff is unfair" — which would make the
//      reference a MODEL OF THE HARDWARE instead of a statement of truth. That is exactly the
//      shared-premise structure that cost a burn in each of the last two rungs. edge_setup.s bans it
//      independently: "exact only EMPIRICALLY ... a +1-ULP perturbation the ISA permits breaks it".
//      ⇒ the divide is an EXACT restoring loop. Measured alternative: a seeded divide works but needs a
//      correction loop sized from a DERIVED bound of 32, not the 9 a 730-case sweep observed.
//
//   2. THE NUMERATOR IS A REGISTER PAIR. Measured 46-57 bits. This is the first kernel in the tree whose
//      per-pixel value does not fit one lane, so the 64x32 multiply and the carry chain below are new
//      machinery, not boilerplate.
//
//   3. THE DENOMINATOR FITS ONE LANE ONLY BECAUSE THE VALIDATOR SAYS SO. "D fits a 32-bit lane" is FALSE
//      at the ABI's extremes — measured at 8,583,644,160 = 2^33 with w at its floor and the coordinate
//      ceiling. gpo_validate_triperspec bounds D at the draw rect's four corners (D is affine; rung 17's
//      corner bound is the precedent and depthgate's D8 proved the shortcut sound against brute force).
//
//   4. THE REMAINDER FITS ONE LANE, and that is what makes the divide affordable. `rem < D` after every
//      subtraction and D <= 2^31-1, so `(rem << 1) | bit` stays under 2^32. ⚠ THE ABI BOUND AND THIS
//      CLAIM ARE THE SAME FACT: an earlier D_MAX of 2^32-1 would have needed 33 bits here.
//
//   5. w IS FLOORED AND CEILINGED. `W = 2^16/w` is an INTEGER divide, so w >= 65537 gives W = 0 and a
//      divide by zero; w = 65536 gives W = 1, i.e. zero bits of reciprocal precision. The validator
//      admits [256, 4096] — the band the host probes actually swept.
//
// ⛔ NO s_cbranch ON A PER-LANE CONDITION. s_cbranch_vccz fires only when NO lane has the condition and
// _vccnz only when ANY does — either way one lane decides all 64, which DILATES a triangle to its whole
// tile. The only branches here are on s4 (a kernarg), s12 (an SALU counter) and s13 (the divide's
// iteration counter), all wave-uniform by construction. ⚠ The divide loop's trip count is a CONSTANT,
// which is precisely what makes it legal to drive with s_cbranch_scc1.
//
// ============================================================================================
// THE REGISTER MAP — WRITTEN DOWN BEFORE THE FIRST INSTRUCTION.
// ============================================================================================
// Rung 13 lost a hardware run to a scratch v_mul_lo_u32 over a live v19: the clobber wrote ZERO, read
// like a dead shader, and was invisible to the assembler, to the blob gate AND to the host model. Rung
// 17 then lost one to a kernarg read backwards. Both were mechanical, both are now gated, and this map
// is the input to those gates.
//
//  LIVE ACROSS THE TRIANGLE LOOP — written inside it ONLY by the two named v_cndmask
//   v0   lane id 0..63       HW-written, never written by us                    [whole kernel]
//   v1   lxq = 2*lx + 1      draw-local doubled sample x                        [prologue -> L_END]
//   v2   lyq = 2*ly + 1                                                         [prologue -> L_END]
//   v3   ubest u32 16.16     the winning u                                      [prologue -> L_END]
//   v4   vbest u32 16.16     the winning v                                      [prologue -> L_END]
//
//  LOOP SCRATCH — all provably dead at the bottom of the triangle loop
//   v5   e0        v6   e1        v7   e2 = area - e0 - e1 (DERIVED; only its SIGN is read)
//   v8   D  (one lane, bounded by the validator)
//   v9:v10   N as a PAIR (lo, hi) -- the numerator under division
//   v11  q          the quotient being built
//   v12  rem        the running remainder, ONE lane (see pin 4)
//   v13  multiply / bit-extract temp
//   v14  second multiply temp -- the 64x32 product's high half
//   v15  SPARE
//
//  TAIL — deliberately NOT aliased onto dead loop scratch
//   v16  lx (draw-local)     v17  ly (draw-local)     [prologue -> L_END]
//   v18:v19  destination address
//   v20  texel address scratch    v21  fetched texel
//   v22:v23  texture address pair
//
//  HIGH WATER = v23. DECLARE 32. EIGHT spare.
//  ⛔ Do NOT hand-squeeze for occupancy — one workgroup is exactly one wave and gfx9 caps
//  workgroups-per-CU at 16, so occupancy is identical for any VGPR count up to 64. Aliasing the tail
//  onto loop scratch is precisely what produced rung 13's clobber.
//
//  SGPRs — kernargs (USER_SGPR = 8, which is what lets gpu_blend_cov_run dispatch this UNMODIFIED)
//   s[0:1] prep record base MC, WALKED per iteration    s[2:3] colour base MC, PRE-OFFSET to dstxy
//   s4  n_tri      s5  colour pitch bytes      s6  w      s7  h      s8 tgid_x    s9 tgid_y
//  ⛔⛔ s4 IS THE COUNT AND s5 IS THE PITCH, IN THAT ORDER. gpu_blend_cov_run emits USER_DATA as
//  mask_mc lo/hi, dst_mc lo/hi, **mask_pitch, dst_pitch**, width, color, and the worker passes n_tri as
//  mask_pitch. Rung 17's FIRST BURN read these backwards: the loop ran `pitch` = 3328 times off the end
//  of the prep array into zeroed arena where area == 0 makes every edge test `0 <= 0` — inside on every
//  lane — and painted a uniform frame. ⚠ All 1024 lane witnesses were correct, all pixels written, and
//  BOTH SUBMISSION ORDERS BYTE-IDENTICAL, because a wave-uniform kernarg misread is deterministic by
//  construction. Only the reference comparison caught it. scripts/check/tridepth-contract.sh gates the
//  equivalent for rung 17; the same check must exist for this file before it flashes.
//
//  HEADER, loaded once in the prologue by two s_load_dwordx4 from s[0:1] + 0
//   s16:s17 texture base MC   s18 texture pitch bytes   s19 tex w-1 mask   s20 tex h-1 mask
//   s21 bg   s22 tiles_x   s23 (reserved)
//
//  DERIVED / SCRATCH
//   s10 tile origin x   s11 tile origin y   s12 triangle counter   s13 divide bit counter
//   s14 s15 SALU scratch      s[24:25] THE UPDATE PREDICATE      s[26:27] predicate scratch
//   s28:s31 SPARE
//
//  PER-TRIANGLE RECORD — 96 bytes, SIX s_load_dwordx4 at imm 0x0/0x10/0x20/0x30/0x40/0x50
//   s32 A0   s33 B0   s34 C0   s35 A1
//   s36 B1   s37 C1   s38 area s39 A_D
//   s40 B_D  s41 C_D  s42 A_Nu_lo s43 A_Nu_hi
//   s44 B_Nu_lo s45 B_Nu_hi s46 C_Nu_lo s47 C_Nu_hi
//   s48 A_Nv_lo s49 A_Nv_hi s50 B_Nv_lo s51 B_Nv_hi
//   s52 C_Nv_lo s53 C_Nv_hi s54 RESERVED s55 RESERVED
//
//  HIGH WATER = s55.  DECLARE 56.
//  ⛔ THE PREDICATE MUST LIVE IN A NAMED, EVEN-ALIGNED PAIR, NOT vcc: the divide's carry chain writes
//  vcc on every one of its iterations, between the edge tests and the update. s[23:24] is rejected for
//  alignment; s[24:25] is correct.
//
// ⛔ RSRC1/RSRC2 ARE HARVESTED FROM THE ASSEMBLED DESCRIPTOR, NEVER HAND-COUNTED. The granting rule is
// roundup8(next_free_sgpr + 6) and the +6 is VCC(2) + XNACK(4) — gfx90c is an APU and the triple
// reserves XNACK. edge_cov's documented hand-miscount was exactly 22 + 2: a count that remembered VCC
// and had no way to know about XNACK. Under-allocating the SGPR file corrupts the vcc carry chain in the
// address arithmetic and lanes write the WRONG PIXELS — a plausible wrong picture, not a fault.

.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.globl tri_persp
.p2align 8
.type tri_persp,@function

tri_persp:
    s_load_dwordx4 s[16:19], s[0:1], 0x0
    s_load_dwordx4 s[20:23], s[0:1], 0x10
    s_waitcnt      lgkmcnt(0)
    // ⛔⛔ STEP ONE FULL STRIDE (96), NOT 64. THIS COST A BURN. The header occupies one record slot, so
    // this step and GPU_TPER_PREP_STRIDE are THE SAME NUMBER — and rung 17's stride is 64, so copying
    // its `s_add_u32 s0, s0, 64` left the shader reading the header's last 32 bytes plus record 0's
    // first 64 as if they were record 0. ⚠ THE SIGNATURE: garbage coefficients give coordinates
    // uncorrelated with anything, and on a two-colour checkerboard that reads as ~50% wrong against
    // BOTH references at once (measured 748 and 769 of 1541) -- equidistant from perspective and
    // affine, which is what says "neither" rather than "the divide is off".
    // ⇒ scripts/check/triper-contract.sh now asserts this against the constant.
    s_add_u32      s0, s0, 96
    s_addc_u32     s1, s1, 0

    // ---- lane -> tile-local, then draw-local ------------------------------------------------
    // ⭐ py IS PER-LANE. An 8x8 tile puts eight distinct rows in one wave; computing the row offset in
    // SALU from tgid_y would give all 64 lanes the address of row tgid_y*8 — 8 of 64 correct, the tile
    // writing its top row eight times. Signature: horizontal streaking, which reads as a store bug.
    v_and_b32      v16, 7, v0
    v_lshrrev_b32  v17, 3, v0
    s_lshl_b32     s10, s8, 3
    s_lshl_b32     s11, s9, 3
    v_add_u32      v16, s10, v16
    v_add_u32      v17, s11, v17
    // the pixel CENTRE (px + 0.5) is the exact integer 2*px + 1, the domain the reference proves.
    // Draw-local: dstxy is folded into every constant term by prep, so this kernel never sees it.
    v_lshlrev_b32  v1, 1, v16
    v_or_b32       v1, 1, v1
    v_lshlrev_b32  v2, 1, v17
    v_or_b32       v2, 1, v2

    v_mov_b32      v3, s21                  // ubest = bg (this op REPLACES its rect)
    v_mov_b32      v4, s21

    // ⛔ COVERAGE MUST BE ACCUMULATED, because L_STORE fetches unconditionally. Without this the
    // kernel paints a texel fetched at a bg-DERIVED coordinate wherever nothing is covered -- garbage
    // outside the geometry rather than the background. Found while writing the test arm: the reference
    // would have had to model the garbage, which is the wrong way round.
    s_mov_b64      s[28:29], 0
    s_mov_b32      s12, 0
    s_cmp_lt_u32   s12, s4
    s_cbranch_scc0 L_STORE                  // an empty list is the common case at 8x8

L_TRI:
    // ===== WAVE-UNIFORM TRIANGLE LOOP ========================================================
    s_load_dwordx4 s[32:35], s[0:1], 0x0
    s_load_dwordx4 s[36:39], s[0:1], 0x10
    s_load_dwordx4 s[40:43], s[0:1], 0x20
    s_load_dwordx4 s[44:47], s[0:1], 0x30
    s_load_dwordx4 s[48:51], s[0:1], 0x40
    s_load_dwordx4 s[52:55], s[0:1], 0x50
    // ⛔ ONE FULL WAIT before the first read. NEVER lgkmcnt(n>0): SMEM returns OUT OF ORDER on gfx9.
    s_waitcnt      lgkmcnt(0)

    // ---- two edge planes; the third is DERIVED ----------------------------------------------
    v_mul_lo_u32   v5,  v1, s32
    v_mul_lo_u32   v13, v2, s33
    v_add_u32      v5,  v5, v13
    v_add_u32      v5,  s34, v5
    v_mul_lo_u32   v6,  v1, s35
    v_mul_lo_u32   v13, v2, s36
    v_add_u32      v6,  v6, v13
    v_add_u32      v6,  s37, v6
    // ⭐ e2 = area - e0 - e1. Exact mod 2^32 because the three planes sum to the area identically, and
    // SAFE here for a specific reason: e0/e1/e2 feed ONLY the inside test, so just their signs are read.
    // D and N come from their own planes, so a derived e2 never enters arithmetic whose value is used.
    v_sub_u32      v7,  s38, v5
    v_sub_u32      v7,  v7,  v6

    // ---- the denominator, ONE lane (validator-bounded, pin 3) -------------------------------
    v_mul_lo_u32   v8,  v1, s39
    v_mul_lo_u32   v13, v2, s40
    v_add_u32      v8,  v8, v13
    v_add_u32      v8,  s41, v8

    // ---- the predicate: three edge tests, all PER-LANE, computed BEFORE the divide ----------
    // ⚠ Computed here and not after, because the divide's carry chain writes vcc on every iteration.
    // Inside is a single uniform e_i >= 0 because prep normalises winding once per triangle.
    v_cmp_le_i32   s[24:25], 0, v5
    v_cmp_le_i32   s[26:27], 0, v6
    s_and_b64      s[24:25], s[24:25], s[26:27]
    v_cmp_le_i32   s[26:27], 0, v7
    s_and_b64      s[24:25], s[24:25], s[26:27]      // = INSIDE
    s_or_b64       s[28:29], s[28:29], s[24:25]      // any lane covered by ANY triangle, ever

    // ---- the U numerator as a 64-BIT PAIR ---------------------------------------------------
    // A_Nu * lxq, a 64x32 product in four instructions: lo, hi, the high operand's contribution, add.
    v_mul_lo_u32   v9,  v1, s42
    v_mul_hi_u32   v10, v1, s42
    v_mul_lo_u32   v13, v1, s43
    v_add_u32      v10, v10, v13
    // + B_Nu * lyq
    v_mul_lo_u32   v13, v2, s44
    v_mul_hi_u32   v14, v2, s44
    v_add_co_u32   v9,  vcc, v9,  v13
    v_addc_co_u32  v10, vcc, v10, v14, vcc
    v_mul_lo_u32   v13, v2, s45
    v_add_u32      v10, v10, v13
    // + C_Nu, a 64-bit constant. ⛔ THE TWO HALVES STAY ADJACENT: v_addc_co_u32 consumes vcc as
    // carry-IN, so anything between them corrupts the high word by exactly one — which on a texture
    // coordinate is a one-texel seam, not a crash. perspmodel's M1 measures it at 312 pixels.
    // ⛔ THE HIGH HALF MUST COME FROM A VGPR. `v_addc_co_u32 v10, vcc, v10, s47, vcc` is REJECTED —
    // "violates constant bus restrictions": the vcc carry-IN already spends gfx9's single constant-bus
    // slot, so src1 may not also be an SGPR. Same class as the v_mov rung 17's v_cndmask needs.
    // ⚠ The mov sits BEFORE the pair, never between it: v_addc_co_u32 consumes vcc as carry-in.
    v_mov_b32      v14, s47
    v_add_co_u32   v9,  vcc, v9,  s46
    v_addc_co_u32  v10, vcc, v10, v14, vcc

    // ---- THE EXACT DIVIDE: q = floor(N / D), restoring, 56 iterations ------------------------
    // ⭐ Exact BY CONSTRUCTION — no error bound to prove, no ISA guarantee to trust, and no reference
    // that has to model an approximation. The remainder is ONE lane (pin 4).
    // ⚠ The trip count is a CONSTANT, so s_cbranch_scc1 on it is wave-uniform and legal.
    v_mov_b32      v11, 0
    v_mov_b32      v12, 0
    s_mov_b32      s13, 56
L_DIVU:
    s_sub_u32      s13, s13, 1
    // rem = (rem << 1) | bit(N, s13); q <<= 1
    v_lshlrev_b32  v12, 1, v12
    s_sub_u32      s14, s13, 32
    s_cmp_ge_i32   s13, 32
    s_cselect_b32  s15, s14, s13
    v_mov_b32      v13, v9
    s_cmp_ge_i32   s13, 32
    s_cbranch_scc0 L_DIVU_LO
    v_mov_b32      v13, v10
L_DIVU_LO:
    v_lshrrev_b32  v13, s15, v13
    v_and_b32      v13, 1, v13
    v_or_b32       v12, v13, v12
    v_lshlrev_b32  v11, 1, v11
    // if (rem >= D) { rem -= D; q |= 1 }  -- PREDICATED, never branched
    v_cmp_le_u32   s[26:27], v8, v12
    v_sub_u32      v13, v12, v8
    v_cndmask_b32  v12, v12, v13, s[26:27]
    v_or_b32       v13, 1, v11
    v_cndmask_b32  v11, v11, v13, s[26:27]
    s_cmp_lg_u32   s13, 0
    s_cbranch_scc1 L_DIVU

    // ---- the update: the ONLY write to v3 in this loop --------------------------------------
    v_cndmask_b32  v3, v3, v11, s[24:25]

    // ---- the V numerator, same shape, same divide -------------------------------------------
    v_mul_lo_u32   v9,  v1, s48
    v_mul_hi_u32   v10, v1, s48
    v_mul_lo_u32   v13, v1, s49
    v_add_u32      v10, v10, v13
    v_mul_lo_u32   v13, v2, s50
    v_mul_hi_u32   v14, v2, s50
    v_add_co_u32   v9,  vcc, v9,  v13
    v_addc_co_u32  v10, vcc, v10, v14, vcc
    v_mul_lo_u32   v13, v2, s51
    v_add_u32      v10, v10, v13
    // ⛔ THE HIGH HALF MUST COME FROM A VGPR. `v_addc_co_u32 v10, vcc, v10, s53, vcc` is REJECTED —
    // "violates constant bus restrictions": the vcc carry-IN already spends gfx9's single constant-bus
    // slot, so src1 may not also be an SGPR. Same class as the v_mov rung 17's v_cndmask needs.
    // ⚠ The mov sits BEFORE the pair, never between it: v_addc_co_u32 consumes vcc as carry-in.
    v_mov_b32      v14, s53
    v_add_co_u32   v9,  vcc, v9,  s52
    v_addc_co_u32  v10, vcc, v10, v14, vcc

    v_mov_b32      v11, 0
    v_mov_b32      v12, 0
    s_mov_b32      s13, 56
L_DIVV:
    s_sub_u32      s13, s13, 1
    v_lshlrev_b32  v12, 1, v12
    s_sub_u32      s14, s13, 32
    s_cmp_ge_i32   s13, 32
    s_cselect_b32  s15, s14, s13
    v_mov_b32      v13, v9
    s_cmp_ge_i32   s13, 32
    s_cbranch_scc0 L_DIVV_LO
    v_mov_b32      v13, v10
L_DIVV_LO:
    v_lshrrev_b32  v13, s15, v13
    v_and_b32      v13, 1, v13
    v_or_b32       v12, v13, v12
    v_lshlrev_b32  v11, 1, v11
    v_cmp_le_u32   s[26:27], v8, v12
    v_sub_u32      v13, v12, v8
    v_cndmask_b32  v12, v12, v13, s[26:27]
    v_or_b32       v13, 1, v11
    v_cndmask_b32  v11, v11, v13, s[26:27]
    s_cmp_lg_u32   s13, 0
    s_cbranch_scc1 L_DIVV

    v_cndmask_b32  v4, v4, v11, s[24:25]

    // ---- tail: FIXED ORDER, the two pointer adds adjacent -----------------------------------
    s_add_u32      s0,  s0, 96
    s_addc_u32     s1,  s1, 0
    s_add_u32      s12, s12, 1
    s_cmp_lt_u32   s12, s4
    s_cbranch_scc1 L_TRI

L_STORE:
    // ---- fetch the texel at (u >> 16, v >> 16), masked into the texture ---------------------
    // ⚠ The masks in s19/s20 are w-1 and h-1, so the texture dimensions must be powers of two on this
    // path — the same WRAP restriction op 0x0C already enforces, and a REJECT rather than a clamp.
    v_lshrrev_b32  v20, 16, v3
    v_and_b32      v20, s19, v20
    v_lshrrev_b32  v21, 16, v4
    v_and_b32      v21, s20, v21
    v_mul_lo_u32   v21, v21, s18
    v_lshlrev_b32  v20, 2, v20
    v_add_u32      v20, v20, v21
    v_add_co_u32   v22, vcc, s16, v20
    v_mov_b32      v23, s17
    v_addc_co_u32  v23, vcc, 0, v23, vcc
    global_load_dword v21, v[22:23], off glc
    s_waitcnt      vmcnt(0)
    // ⭐ bg where NOTHING covered this lane. Predicated, never branched -- a wave branch here would
    // give the whole tile one answer.
    v_mov_b32      v20, s21
    v_cndmask_b32  v21, v20, v21, s[28:29]

    // ---- store: addr = base + ly*pitch + lx*4 -----------------------------------------------
    v_mul_lo_u32   v18, v17, s5
    v_lshlrev_b32  v19, 2, v16
    v_add_u32      v18, v18, v19
    v_add_co_u32   v18, vcc, s2, v18
    v_mov_b32      v19, s3
    v_addc_co_u32  v19, vcc, 0, v19, vcc
    global_store_dword v[18:19], v21, off glc

L_END:
    s_waitcnt vmcnt(0)
    s_endpgm

.section .rodata,"a"
.p2align 6
.amdhsa_kernel tri_persp
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 0
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    // 32 VGPRs: the emit list's highest is v23. Occupancy is workgroup-capped either way, so 32 costs
    // nothing and leaves eight spare rather than inviting the aliasing that cost rung 13 a run.
    .amdhsa_next_free_vgpr 32
    .amdhsa_next_free_sgpr 56
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    // pure-integer kernel: no v_cvt, no v_rcp_f32, matching tri_depth / tri_rgba / edge_cov
    .amdhsa_ieee_mode 0
    .amdhsa_exception_fp_ieee_invalid_op 0
    .amdhsa_exception_fp_denorm_src 0
    .amdhsa_exception_fp_ieee_div_zero 0
    .amdhsa_exception_fp_ieee_overflow 0
    .amdhsa_exception_fp_ieee_underflow 0
    .amdhsa_exception_fp_ieee_inexact 0
    .amdhsa_exception_int_div_zero 0
.end_amdhsa_kernel
