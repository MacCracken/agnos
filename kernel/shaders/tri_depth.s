// tri_depth.s — gfx90c DEPTH-TESTED TRIANGLE LIST. 3D arc rung 17.
//
// One workgroup owns an 8x8 tile and walks that tile's whole triangle list IN SUBMISSION ORDER in a
// SINGLE 64-lane wave, holding colour and depth in VGPRs across the loop, with one global_store each
// at the end. That is what makes the result deterministic WITHOUT atomics: 64 lanes, one wave, no
// barrier, no LDS, and every pixel's z lives in a register only its own lane can write.
//
// ⛔⛔ FOUR SEAMS WERE DECIDED TWICE, OPPOSITELY, DURING DESIGN, AND THREE OF THE FOUR WRONG PICKS
// PASS THIS RUNG'S OWN ORACLE. They are pinned here; do not re-open them while reading code.
//
//   1. DEPTH COMPARE IS **UNSIGNED**. z is provably in [0, 2^24-1] and the far value is 0xFFFFFFFF.
//      Under v_cmp_lt_i32 that far value reads as -1 — the NEAREST possible depth — so no fragment
//      ever passes, nothing draws, and a blank frame is byte-identical in both submission orders.
//      The oracle would go GREEN on an empty screen. depthmodel's A9 renders exactly that: unsigned
//      draws 507 px at the hardware clear value, signed draws 0.
//
//   2. THE LIST IS WALKED UNBINNED. Every tile reads the whole contiguous prep array. There is no
//      binning pass and no per-tile list, because a kernel binner plus a contiguous-walking shader
//      puts triangles in tiles they do not touch — which reads as order-dependence and buys a
//      TD-5 atomics rewrite for a three-line prep bug. A GPO_E_WORK cap bounds the cost instead.
//
//   3. THERE IS NO BOUNDS GUARD AND exec IS NEVER WRITTEN. exec == -1 for the entire kernel. The
//      validator refuses any w/h/dx/dy that is not a multiple of 8, so a partial tile cannot exist.
//      ⚠ A prologue guard would make every edge tile show lane dropouts BYTE-IDENTICAL to the
//      register-aliasing signature the lane witness exists to detect, and the burn would be spent
//      telling the two apart.
//
//   4. THIS OP **REPLACES**, IT DOES NOT COMPOSITE. Colour starts at bg and z at zclear in
//      REGISTERS, and both are stored unconditionally, so an empty tile still writes bg over all 64
//      pixels. It never reads the render target and never reads the depth buffer — which is what
//      removes the coherence question entirely, and is exactly what a second pass would break, since
//      the depth clear is CP-DMA (MC-direct) while a shader load goes through GL2.
//
// ⛔ NO s_cbranch ON A PER-LANE CONDITION, ANYWHERE. s_cbranch_vccz fires only when NO lane has the
// condition and s_cbranch_vccnz only when ANY does — either way one lane decides all 64. A wave
// branch around the update would DILATE each triangle to its whole 8x8 tile, worst exactly at the
// interpenetration line, which fails the both-orders oracle and reads as "the serialisation is not
// serialising". The only branches here are on s4 (a kernarg) and s12 (an SALU counter), both
// wave-uniform by construction.
//
// ============================================================================================
// THE REGISTER MAP — WRITTEN DOWN BEFORE THE FIRST INSTRUCTION, DELIBERATELY.
// ============================================================================================
// Rung 13 lost a hardware run to a scratch v_mul_lo_u32 over a live v19: the clobber wrote ZERO and
// read like a dead shader, invisible to the assembler, to the blob gate AND to the host model. Here
// v3/v4 are live across an UNBOUNDED loop, so every scratch write is that same candidate on EVERY
// iteration — strictly worse exposure than rung 13's single axis.
//
//  LIVE ACROSS THE TRIANGLE LOOP — written inside it ONLY by the two named v_cndmask
//   v0   lane id 0..63        HW-written, never written by us; also the witness input   [whole kernel]
//   v1   lxq = 2*lx + 1       draw-local doubled sample x                     [prologue -> L_END]
//   v2   lyq = 2*ly + 1                                                       [prologue -> L_END]
//   v3   zbest  u32           init = s21 zclear                              [prologue -> L_END]
//   v4   cbest  u32 ARGB      init = s22 bg                                  [prologue -> L_END]
//
//  LOOP SCRATCH — all provably dead at the bottom of the loop
//   v5   w0        v6   w1        v7   w2 = area - w0 - w1 (DERIVED, exact mod 2^32)
//   v8   zn, then the clamped zn                 v9   q                v10  q*area, then r
//   v11  colour in a VGPR (REQUIRED, see below)  v12  multiply temp
//   v13 v14 v15  SPARE, unused
//
//  TAIL — after the loop, deliberately NOT aliased onto dead loop scratch
//   v16  lx (draw-local)      v17  ly (draw-local)     [prologue -> L_END]
//   v18:v19  colour store address        v20:v21  z store address
//   v22  witness value                   v23:v24  witness store address
//
//  HIGH WATER = v24. DECLARE 32. SEVEN spare.
//  ⛔ Do NOT hand-squeeze for occupancy — the trade is illusory. One workgroup is exactly one wave
//  (GPU_MT_NUM_THREAD_X = 64) and gfx9 caps workgroups-per-CU at 16, so occupancy is the same for
//  ANY VGPR count up to 64. Declaring 32 costs nothing, and aliasing the tail onto loop scratch is
//  precisely the aliasing that produced rung 13's clobber.
//
//  SGPRs — kernargs (USER_SGPR = 8, load-bearing: it is what lets gpu_blend_cov_run dispatch this
//  kernel UNMODIFIED, which is why the z and witness bases travel in the record header instead of
//  becoming kernargs 9 and 10)
//   s[0:1] prep record base MC, WALKED per iteration    s[2:3] colour base MC, PRE-OFFSET to dstxy
//   s4  n_tri                  s5  colour pitch bytes   s6  w    s7  h   s8 tgid_x  s9 tgid_y
//   ⛔⛔ s4 IS THE COUNT AND s5 IS THE PITCH, IN THAT ORDER, AND THE FIRST BURN GOT IT BACKWARDS.
//   gpu_blend_cov_run emits USER_DATA as mask_mc lo/hi, dst_mc lo/hi, **mask_pitch, dst_pitch**,
//   width, color — so the worker's `n_tri` argument lands in s4 and the framebuffer pitch in s5.
//   Reading them the other way round ran the triangle loop `pitch` times (3328) off the end of the
//   prep array into zeroed arena, where area == 0 makes all three edge tests `0 <= 0` — INSIDE on
//   every lane — and painted colour 0; the colour row stride became 2 bytes.
//   ⚠ THE SIGNATURE WAS DIAGNOSTIC AND IS WORTH KEEPING: every lane witness correct, all 1024 px
//   written, BOTH ORDERS BYTE-IDENTICAL, and all 1024 wrong against the reference. Deterministic and
//   order-independent is exactly what a wave-uniform misread of a kernarg looks like — which is why
//   the reference comparison, not the oracle, is what caught it.
//
//  HEADER, loaded once in the prologue by two s_load_dwordx4 from s[0:1] + 0
//   s16:s17 z base MC, PRE-OFFSET to dstxy   s18:s19 witness base MC (0 = disabled)
//   s20 z pitch bytes   s21 zclear (>= 2^24)   s22 bg   s23 tiles_x
//
//  DERIVED / SCRATCH
//   s10 tile origin x   s11 tile origin y   s12 loop counter   s13 s14 s15 SALU scratch
//   s[24:25] THE UPDATE PREDICATE      s[26:27] predicate scratch      s28..s31 SPARE
//
//  PER-TRIANGLE RECORD — four s_load_dwordx4 at imm 0x0/0x10/0x20/0x30
//   s32 A0  s33 B0  s34 C0  s35 A1 | s36 B1  s37 C1  s38 KX  s39 KY
//   s40 KC  s41 area s42 R  s43 colour | s44..s47 RESERVED, zero in the record
//
//  HIGH WATER = s47. DECLARE 48.
//  ⛔ THE PREDICATE MUST LIVE IN A NAMED, EVEN-ALIGNED PAIR — NOT vcc. The reciprocal's correction
//  writes vcc BETWEEN the edge tests and the update. Every other shader in this tree computes its
//  predicate after its carry chains and so has never had this hazard. s[23:24] is rejected by the
//  assembler for alignment; s[24:25] is correct.
//
// ⛔ RSRC1/RSRC2 ARE HARVESTED FROM THE ASSEMBLED DESCRIPTOR, NEVER HAND-COUNTED. The granting rule
// is roundup8(next_free_sgpr + 6).
// ⛔ THE "+6 = VCC(2) + XNACK(4) — gfx90c is an APU so the triple reserves XNACK" gloss that stood
// here until 1.56.44 IS MEASURED WRONG. llvm-mc 22.1.8, solving E over next_free_sgpr 1..39 on
// gfx90c: defaults E=6; xnack_mask 0 alone E=6 (UNCHANGED); flat_scratch 0 alone E=4; both E=2.
// XNACK contributes 2, not 4, and is invisible while flat scratch is reserved. edge_cov's documented hand-miscount (0x002C008D vs 0x002C00CD) is exactly 22 + 2:
// a count that remembered VCC and had no way to know about XNACK. Under-allocating the SGPR file
// corrupts the vcc carry chain in the address arithmetic and lanes write the WRONG PIXELS — a
// plausible wrong picture, not a fault.

.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.globl tri_depth
.p2align 8
.type tri_depth,@function

tri_depth:
    // ---- header: z base, witness base, z pitch, zclear, bg, tiles_x -------------------------
    s_load_dwordx4 s[16:19], s[0:1], 0x0
    s_load_dwordx4 s[20:23], s[0:1], 0x10
    s_waitcnt      lgkmcnt(0)
    // step the record pointer past the 64-byte header.
    // ⛔ NOTHING MAY SIT BETWEEN THESE TWO. s_addc_u32 consumes SCC as carry-in; putting the loop
    // counter's increment in the middle makes the pointer's high dword consume the counter's carry
    // — silently correct on a short list, wrong only on a long one.
    s_add_u32      s0, s0, 64
    s_addc_u32     s1, s1, 0

    // ---- lane -> tile-local (x,y), then draw-local ------------------------------------------
    // ⭐ py IS PER-LANE FOR THE FIRST TIME IN THIS TREE. Every shipped pixel shader has py = tgid_y,
    // wave-uniform, and computes the row offset in SALU. An 8x8 tile puts EIGHT DISTINCT ROWS in one
    // wave; copying that idiom would give all 64 lanes the address of row tgid_y*8 — 8 of 64 lanes
    // correct, the tile writing its top row eight times. Signature: horizontal streaking, which
    // reads as a binning or store bug rather than as depth.
    v_and_b32      v16, 7, v0
    v_lshrrev_b32  v17, 3, v0
    s_lshl_b32     s10, s8, 3
    s_lshl_b32     s11, s9, 3
    v_add_u32      v16, s10, v16
    v_add_u32      v17, s11, v17

    // doubled sample point: the pixel CENTRE (px + 0.5) is the exact integer 2*px + 1, which is the
    // domain depthcore and depthmodel prove. Draw-local: dstxy is folded into the record's constant
    // terms by prep, so this kernel never sees it.
    v_lshlrev_b32  v1, 1, v16
    v_or_b32       v1, 1, v1
    v_lshlrev_b32  v2, 1, v17
    v_or_b32       v2, 1, v2

    v_mov_b32      v3, s21                  // zbest = zclear
    v_mov_b32      v4, s22                  // cbest = bg

    s_mov_b32      s12, 0
    s_cmp_lt_u32   s12, s4
    s_cbranch_scc0 L_STORE                  // PRE-TEST: an empty list is the common case at 8x8

L_TRI:
    // ===== WAVE-UNIFORM LOOP =================================================================
    s_load_dwordx4 s[32:35], s[0:1], 0x0
    s_load_dwordx4 s[36:39], s[0:1], 0x10
    s_load_dwordx4 s[40:43], s[0:1], 0x20
    s_load_dwordx4 s[44:47], s[0:1], 0x30
    // ⛔ ONE FULL WAIT, INSIDE THE LOOP, BEFORE THE FIRST READ. NEVER lgkmcnt(1): SMEM returns OUT
    // OF ORDER on gfx9, so a partial wait can let a later load's data be read as an earlier one's.
    s_waitcnt      lgkmcnt(0)

    // ---- two edge functions, affine: w = A*lxq + B*lyq + C ---------------------------------
    v_mul_lo_u32   v5,  v1, s32
    v_mul_lo_u32   v12, v2, s33
    v_add_u32      v5,  v5, v12
    v_add_u32      v5,  s34, v5
    v_mul_lo_u32   v6,  v1, s35
    v_mul_lo_u32   v12, v2, s36
    v_add_u32      v6,  v6, v12
    v_add_u32      v6,  s37, v6
    // ⭐ w2 IS DERIVED, NOT EVALUATED. The three edge planes sum to the area identically, so this is
    // exact mod 2^32 and saves a multiply-add per pixel per triangle. depthmodel's A6 checks that
    // identity at 32-bit lane width on every lane of every frame — it had never been checked before.
    v_sub_u32      v7,  s41, v5
    v_sub_u32      v7,  v7,  v6

    // ---- the depth numerator, the same affine shape --------------------------------------
    v_mul_lo_u32   v8,  v1, s38
    v_mul_lo_u32   v12, v2, s39
    v_add_u32      v8,  v8, v12
    v_add_u32      v8,  s40, v8

    // ---- the domain clamp: ONE instruction that deletes a class ---------------------------
    // Inside the triangle every w_i >= 0 and every z_i >= 0, so zn >= 0 already and this is the
    // IDENTITY on every lane that can affect output. Outside, it turns a negative zn into 0 rather
    // than a huge unsigned value — which is what makes the reciprocal's precondition (zn < 2^32)
    // hold UNCONDITIONALLY instead of under a predicate, and removes "the result was garbage but it
    // lost the depth test anyway" from the reasoning. That shape is exactly rung 13's v19 clobber.
    v_max_i32      v8,  0,  v8

    // ---- the divide: q = floor(zn / area), five 32-bit instructions -----------------------
    // R = floor(2^32/area), computed once per triangle on the CPU. With that R and any zn < 2^32:
    //   upper: zn*R/2^32 <= zn/area  =>  q_est <= Q, so it NEVER overshoots and a ONE-SIDED
    //          correction is correct by construction;
    //   lower: zn*R/2^32 >= zn/area - zn/2^32 > zn/area - 1  =>  q_est >= Q-1.
    // So q_est is in {Q-1, Q} and one correction is exact. depthdiv proves it over 23,950 boundary
    // cases x 24 divisors, prints the max pre-correction shortfall (exactly 1) AND the fire count
    // (5,432) — because without both, "the correction is dead code" and "the correction is right"
    // are the same green.
    // ⛔ NOT rung 13's reciprocal. That one divides a 96-bit numerator by a funnel-normalised ~2^30
    // divisor; its funnel is identically inert here (area <= 2^26 even at 4096^2) and what survives
    // is a divisor biased UP with nothing normalising it. Measured: exact on this corpus, and wrong
    // by 1598 on an ABI-legal 5-pixel sliver.
    // ⭐ Both v_mul_hi_u32 operands are provably non-negative, so rung 11's four-burn signed-high-half
    // fixup is STRUCTURALLY ABSENT rather than present-and-correct.
    v_mul_hi_u32   v9,  v8, s42
    v_mul_lo_u32   v10, v9, s41
    v_sub_u32      v10, v8, v10
    v_cmp_le_u32   vcc, s41, v10
    // ⚠ Operand order `0, v9` and NOT `v9, 0` — that is the iron-proven 4-byte VOP2 encoding; the
    // reverse silently promotes to the 8-byte VOP3B form.
    v_addc_co_u32  v9,  vcc, 0, v9, vcc

    // ---- the predicate: THREE edge tests AND the depth test, all PER-LANE -------------------
    // Inside is a single uniform w_i >= 0 because prep normalises winding (a clockwise triangle has
    // its three planes AND KX/KY/KC AND area negated together, once, on the CPU). Negating area
    // alone would leave the numerator signed wrong, the clamp above would turn it into 0 — the
    // NEAREST value — and a clockwise triangle would silently draw in front of everything.
    v_cmp_le_i32   s[24:25], 0, v5
    v_cmp_le_i32   s[26:27], 0, v6
    s_and_b64      s[24:25], s[24:25], s[26:27]
    v_cmp_le_i32   s[26:27], 0, v7
    s_and_b64      s[24:25], s[24:25], s[26:27]      // = INSIDE
    // STRICT <, UNSIGNED. Strict is what makes a TIE keep the incumbent, i.e. the EARLIER-submitted
    // triangle — which is how submission order becomes observable at all, and is what the quad frame
    // (23 exact ties, both orders differing in all 23) exists to witness.
    v_cmp_lt_u32   s[26:27], v9, v3
    s_and_b64      s[24:25], s[24:25], s[26:27]      // = WRITE

    // ---- the update: TWO cndmask, and the ONLY writes to v3/v4 in this loop ----------------
    // ⛔ THE v_mov IS MANDATORY, NOT COSMETIC. `v_cndmask_b32 v4, v4, s43, s[24:25]` is REJECTED —
    // the selector spends gfx9's single constant-bus slot, so neither src0 nor src1 may be an SGPR.
    // A 32-bit literal is rejected too (VOP3 takes inline constants only: 64 assembles, 65 does not).
    v_mov_b32      v11, s43
    v_cndmask_b32  v3,  v3, v9,  s[24:25]
    v_cndmask_b32  v4,  v4, v11, s[24:25]

    // ---- tail: FIXED ORDER, and the two pointer adds stay adjacent -------------------------
    s_add_u32      s0,  s0, 64
    s_addc_u32     s1,  s1, 0
    s_add_u32      s12, s12, 1
    s_cmp_lt_u32   s12, s4
    s_cbranch_scc1 L_TRI

L_STORE:
    // ---- colour: addr = base + ly*pitch + lx*4 --------------------------------------------
    v_mul_lo_u32   v18, v17, s5
    v_lshlrev_b32  v19, 2, v16
    v_add_u32      v18, v18, v19
    v_add_co_u32   v18, vcc, s2, v18         // writes vcc, does not read it: one const-bus operand
    v_mov_b32      v19, s3
    v_addc_co_u32  v19, vcc, 0, v19, vcc     // inline 0 + vcc read: one const-bus operand
    global_store_dword v[18:19], v4, off glc

    // ---- depth: same shape, its own pitch and base ----------------------------------------
    v_mul_lo_u32   v20, v17, s20
    v_lshlrev_b32  v21, 2, v16
    v_add_u32      v20, v20, v21
    v_add_co_u32   v20, vcc, s16, v20
    v_mov_b32      v21, s17
    v_addc_co_u32  v21, vcc, 0, v21, vcc
    global_store_dword v[20:21], v3, off glc

    // ---- the lane witness, LAST ------------------------------------------------------------
    // ⭐ AT THE END, NOT THE TOP, AND THE VALUE IS SELF-DESCRIBING. A top-of-kernel witness goes
    // green for a wave that hung mid-loop and actively misleads. And the host does not check "is
    // this poison?" — it checks witness[2i] == 0x17000000 | i, because the documented consequence of
    // an under-granted SGPR file is a corrupted address carry chain, i.e. lanes writing the WRONG
    // LOCATION. Under a dumb witness that is invisible; under this one it reads as "the word at
    // index i says it belongs at index j". Four instructions buy that.
    //   index  = ((tgid_y * tiles_x + tgid_x) * 64 + lane) * 2
    //   word 0 = 0x17000000 | (tile_index << 6) | lane
    //   word 1 = RESERVED, stays poison; the host asserts it is still poison.
    s_cmp_lg_u64   s[18:19], 0               // WAVE-UNIFORM: a kernarg, not a lane condition
    s_cbranch_scc0 L_END
    s_mul_i32      s13, s9, s23              // tgid_y * tiles_x
    s_add_u32      s13, s13, s8              // + tgid_x = tile index
    s_lshl_b32     s14, s13, 6               // tile_index << 6
    s_or_b32       s14, s14, 0x17000000      // the self-describing tag
    v_or_b32       v22, s14, v0              // | lane
    s_lshl_b32     s15, s13, 9               // tile_index * 64 lanes * 2 words * 4 B = << 9
    v_lshlrev_b32  v23, 3, v0                // lane * 2 words * 4 B
    v_add_u32      v23, s15, v23
    v_add_co_u32   v23, vcc, s18, v23
    v_mov_b32      v24, s19
    v_addc_co_u32  v24, vcc, 0, v24, vcc
    global_store_dword v[23:24], v22, off glc

L_END:
    s_waitcnt vmcnt(0)
    s_endpgm

.section .rodata,"a"
.p2align 6
.amdhsa_kernel tri_depth
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 0
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    // 32 VGPRs: the emit list's highest register is v24. Declared 32 rather than 25 because the
    // granting granularity makes anything below 32 no cheaper here, and because occupancy is
    // workgroup-capped either way — see the register-map block above.
    .amdhsa_next_free_vgpr 32
    .amdhsa_next_free_sgpr 48
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    // pure-integer kernel, matching tri_rgba and edge_cov
    .amdhsa_ieee_mode 0
    .amdhsa_exception_fp_ieee_invalid_op 0
    .amdhsa_exception_fp_denorm_src 0
    .amdhsa_exception_fp_ieee_div_zero 0
    .amdhsa_exception_fp_ieee_overflow 0
    .amdhsa_exception_fp_ieee_underflow 0
    .amdhsa_exception_fp_ieee_inexact 0
    .amdhsa_exception_int_div_zero 0
.end_amdhsa_kernel
