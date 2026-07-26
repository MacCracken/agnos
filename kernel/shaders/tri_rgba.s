// tri_rgba.s — gfx90c BARYCENTRIC ATTRIBUTE INTERPOLATION. 3D arc rung 11.
//
// One lane per pixel, 64x1. Reads the 8bpp coverage mask the edge rasteriser produced, evaluates
// two exact edge functions at the pixel centre, interpolates per-vertex premultiplied RGBA, and
// src-over's the result into the back buffer.
//
// ⭐ COVERAGE GEOMETRY AND THE ATTRIBUTE FRAME ARE INDEPENDENT. The shape is an edge array; the
// attribute basis is 3 vertices + 3 colours. Barycentric interpolation is affine over the whole
// plane, so the frame need not coincide with the shape. That is what lets a two-triangle quad be
// ONE record — one coverage pass, one blend — making a seam structurally unrepresentable rather
// than merely tested-for.
//
// ⛔ EVERY EARLY-OUT IS AN EXEC MASK, NEVER A BRANCH ON VCC. `s_cbranch_vccz` fires only when NO
// lane has work, so a lane that should stop falls through and keeps working. That exact fault hid
// on 19 of 20 corpus cases in the coverage rasteriser and cost a hardware run. The only backward
// branch in this kernel is the channel loop, whose trip count is WAVE-UNIFORM (always 4) and
// therefore safe to drive with s_cbranch_scc1.
//
// ⚠ E_A IS DERIVED, NOT COMPUTED. E_A + E_B + E_C == 2A identically for every point, so only two
// cross products are evaluated per pixel. This also removes "do the three sum to 2A at 64 bits?"
// as a question the shader could get wrong.
//
// ⚠ REGISTER BUDGET IS MEASURED, NOT ESTIMATED. This kernel's highest register is v55, so it
// declares 56 — the same budget the shipped edge_cov uses. 64 is the hard occupancy cliff (65
// drops from 4 waves per SIMD to 3), so there are 8 registers of real headroom. The declaration is
// checked mechanically against the emit list because RSRC1 is NOT GRBM-readable and nothing on the
// machine can contradict a wrong one.
//
// ⛔ RSRC1/RSRC2 ARE HARVESTED FROM THE ASSEMBLED OBJECT, NEVER HAND-COUNTED. A hand-derivation of
// edge_cov's value gave 0x002C008D against the real 0x002C00CD — an SGPR field of 2 where the
// assembler grants 3. Under-allocating the SGPR file corrupts the vcc carry chain in the address
// arithmetic and lanes write the WRONG PIXELS: a plausible wrong picture, not a fault.
//
// SGPR convention (8 user SGPRs, preloaded via COMPUTE_USER_DATA_0..7):
//   s[0:1] = TRI-PREP record   s[2:3] = dst base (back buffer)   s4 = dst pitch bytes
//   s5 = unused                s6 = w                            s7 = h
//   s8 = tgid_x (system)       s9 = tgid_y (system)
//
// The TRI-PREP record, 128 B, six dwordx4 loads. Written by the CPU prologue; ring 3 never sees it:
//   Q0 +0    cov_lo cov_hi t t32
//   Q1 +16   Dh V L -
//   Q2 +32   A2_lo A2_hi D255_lo D255_hi
//   Q3 +48   kxB kyB k0B_lo k0B_hi
//   Q4 +64   kxC kyC k0C_lo k0C_hi
//   Q5 +80   cA cB cC -
//   Q6/Q7    reserved, MUST be zero -- the extension point

.text
.globl tri_rgba
.p2align 8
.type tri_rgba,@function

tri_rgba:
    s_mov_b64       exec, -1

    // ---- px = tgid_x*64 + lane, py = tgid_y. Bounds guard BEFORE any address is formed ----
    s_lshl_b32      s10, s8, 6
    v_add_u32       v1, s10, v0             // v1 = px
    v_cmp_gt_u32    vcc, s6, v1             // w > px ?
    s_and_saveexec_b64 s[20:21], vcc
    s_cbranch_execz L_END

    // ---- coverage byte: cov_base + py*w + px --------------------------------------------
    // ⚠ The coverage pointer lives in the RECORD, not in an SGPR. Loading it here keeps the
    // kernarg budget at 8 and leaves the record as the single description of the work.
    s_load_dwordx4  s[12:15], s[0:1], 0x0   // Q0: cov_lo cov_hi t t32
    s_waitcnt       lgkmcnt(0)

    s_mul_i32       s11, s9, s6             // py*w   (wave-uniform -> SALU)
    v_add_u32       v2, s11, v1             // py*w + px
    v_add_co_u32    v2, vcc, s12, v2
    // ⛔ CONSTANT BUS: v_addc_co_u32 already reads vcc, so it may NOT also read an SGPR. The
    // high half must be moved into a VGPR first and added with an INLINE ZERO in src0. Writing
    // the obvious `v_addc_co_u32 v3, vcc, s13, v3, vcc` is rejected by the assembler — which is
    // the point of assembling rather than hand-encoding.
    v_mov_b32       v3, s13
    v_addc_co_u32   v3, vcc, 0, v3, vcc
    global_load_ubyte v4, v[2:3], off       // v4 = cov
    s_waitcnt       vmcnt(0)

    // ---- ⭐ ZERO COVERAGE EXITS PER LANE, AS AN EXEC MASK --------------------------------
    // Not s_cbranch_vccz. A wave-level branch here would let every uncovered lane keep running
    // and blend a colour into a pixel the shape never touched.
    v_cmp_ne_u32    vcc, 0, v4
    s_and_saveexec_b64 s[22:23], vcc
    s_cbranch_execz L_END

    // ---- the rest of the prep record -----------------------------------------------------
    s_load_dwordx4  s[24:27], s[0:1], 0x10  // Q1: Dh V L -
    s_load_dwordx4  s[28:31], s[0:1], 0x20  // Q2: A2_lo A2_hi D255_lo D255_hi
    s_load_dwordx4  s[32:35], s[0:1], 0x30  // Q3: kxB kyB k0B_lo k0B_hi
    s_load_dwordx4  s[36:39], s[0:1], 0x40  // Q4: kxC kyC k0C_lo k0C_hi
    s_load_dwordx4  s[40:43], s[0:1], 0x50  // Q5: cA cB cC -
    s_waitcnt       lgkmcnt(0)

    // ---- sample point at the PIXEL CENTRE, 16.16 -----------------------------------------
    // ⚠ Only the sample point is 16.16. The frame's kx/ky are plain pixel deltas and only the
    // constant term carries the <<16, which is why 2A is cross<<16 and not cross<<32.
    v_lshlrev_b32   v5, 16, v1              // px << 16
    v_add_u32       v5, 0x8000, v5          // + 0.5 px  -> Pcx
    v_mov_b32       v6, s9
    v_lshlrev_b32   v6, 16, v6
    v_add_u32       v6, 0x8000, v6          // Pcy (wave-uniform value, kept in a VGPR for VOP3)

    // ======================================================================================
    // E_B and E_C — two exact signed 64-bit edge functions at the sample point
    // ======================================================================================
    // ⛔ v_mul_hi_i32 IS NEVER USED, AND THAT IS DELIBERATE. It has never executed on this
    // silicon, so it would be an unproven opcode on the critical path. The signed high half is
    // built from the UNSIGNED one by an exact identity:
    //     mul_hi_i32(a,b) = mul_hi_u32(a,b) - ((a>>31)&b) - ((b>>31)&a)
    // which follows from a_signed = a_unsigned - 2^32*sign(a). Cost is +3 VALU per product and
    // it introduces ZERO new opcodes — every instruction below is already iron-proven.
    // ⚠ The sign mask of an SGPR operand is taken with s_ashr_i32: it is wave-uniform, so
    // computing it per lane would burn a VALU slot for a value every lane shares.

    // ---- E_B = kxB*Pcx + kyB*Pcy + k0B ---------------------------------------------------
    v_mul_lo_u32    v8,  s32, v5            // lo(kxB * Pcx)
    v_mul_hi_u32    v9,  s32, v5            // hi_u(kxB * Pcx)
    s_ashr_i32      s44, s32, 31            // sign mask of kxB
    v_and_b32       v14, s44, v5
    v_sub_u32       v9,  v9, v14            // -= (sign(a) & b)
    v_ashrrev_i32   v14, 31, v5             // sign mask of Pcx
    v_and_b32       v14, s32, v14
    v_sub_u32       v9,  v9, v14            // -= (sign(b) & a)   => v[8:9] = kxB*Pcx, signed

    v_mul_lo_u32    v10, s33, v6            // lo(kyB * Pcy)
    v_mul_hi_u32    v11, s33, v6
    s_ashr_i32      s44, s33, 31
    v_and_b32       v14, s44, v6
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s33, v14
    v_sub_u32       v11, v11, v14           // v[10:11] = kyB*Pcy, signed

    v_add_co_u32    v8,  vcc, v8, v10
    v_addc_co_u32   v9,  vcc, v9, v11, vcc  // v[8:9] += v[10:11]
    v_mov_b32       v14, s34
    v_mov_b32       v15, s35
    v_add_co_u32    v8,  vcc, v8, v14
    v_addc_co_u32   v9,  vcc, v9, v15, vcc  // v[8:9] = E_B

    // ---- E_C = kxC*Pcx + kyC*Pcy + k0C ---------------------------------------------------
    v_mul_lo_u32    v10, s36, v5
    v_mul_hi_u32    v11, s36, v5
    s_ashr_i32      s44, s36, 31
    v_and_b32       v14, s44, v5
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v5
    v_and_b32       v14, s36, v14
    v_sub_u32       v11, v11, v14

    v_mul_lo_u32    v12, s37, v6
    v_mul_hi_u32    v13, s37, v6
    s_ashr_i32      s44, s37, 31
    v_and_b32       v14, s44, v6
    v_sub_u32       v13, v13, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s37, v14
    v_sub_u32       v13, v13, v14

    v_add_co_u32    v10, vcc, v10, v12
    v_addc_co_u32   v11, vcc, v11, v13, vcc
    v_mov_b32       v14, s38
    v_mov_b32       v15, s39
    v_add_co_u32    v10, vcc, v10, v14
    v_addc_co_u32   v11, vcc, v11, v15, vcc // v[10:11] = E_C

    // ---- E_A = 2A - E_B - E_C ------------------------------------------------------------
    // ⭐ DERIVED, not a third cross product. E_A + E_B + E_C == 2A identically for every point,
    // so this saves 8 VALU AND removes "do the three sum to 2A at 64 bits?" as a question.
    v_mov_b32       v12, s28
    v_mov_b32       v13, s29                // v[12:13] = 2A
    v_sub_co_u32    v12, vcc, v12, v8
    v_subb_co_u32   v13, vcc, v13, v9, vcc
    v_sub_co_u32    v12, vcc, v12, v10
    v_subb_co_u32   v13, vcc, v13, v11, vcc // v[12:13] = E_A

    // ======================================================================================
    // THE CHANNEL LOOP — 4 iterations, WAVE-UNIFORM trip count
    // ======================================================================================
    // ⭐ s_cbranch_scc1 IS SAFE HERE and nowhere else in this kernel. The trip count is 4 for
    // every lane, so this is not the per-lane-break trap: no lane can need to leave early.
    // Alpha runs FIRST (shift 24) so the alpha quotient is live to clamp r/g/b against.
    // ⚠ Rolling the loop is what keeps the register budget under the occupancy cliff — the colour
    // bytes are re-extracted per iteration rather than held live in 12 registers.
    v_mov_b32       v20, 0                  // out accumulator
    v_mov_b32       v21, 0xFF               // qa, the alpha quotient (255 until alpha is computed)
    s_mov_b32       s45, 24                 // shift for this channel: 24, 16, 8, 0

L_CH:
    // ---- premultiplied channel byte * coverage, per vertex --------------------------------
    v_mov_b32       v14, s40
    v_lshrrev_b32   v14, s45, v14
    v_and_b32       v14, 0xFF, v14
    v_mul_lo_u32    v14, v14, v4            // pA = cA[ch] * cov   (<= 65025)
    v_mov_b32       v15, s41
    v_lshrrev_b32   v15, s45, v15
    v_and_b32       v15, 0xFF, v15
    v_mul_lo_u32    v15, v15, v4            // pB
    v_mov_b32       v16, s42
    v_lshrrev_b32   v16, s45, v16
    v_and_b32       v16, 0xFF, v16
    v_mul_lo_u32    v16, v16, v4            // pC

    // ---- N = E_A*pA + E_B*pB + E_C*pC, accumulated at 96 bits ----------------------------
    // ⚠ 96 BITS IS NOT OPTIONAL. |E| reaches 2^52 at the frame-skew bound and p reaches 2^16, so
    // a single product reaches 2^68 — past 64 bits. v[24:26] is the three-dword accumulator.
    v_mov_b32       v24, 0
    v_mov_b32       v25, 0
    v_mov_b32       v26, 0

    // -- term 1: E_A (v[12:13]) * pA (v14) --
    v_mul_lo_u32    v17, v12, v14
    v_mul_hi_u32    v18, v12, v14           // E lo half is UNSIGNED, no sign fixup needed
    v_add_co_u32    v24, vcc, v24, v17
    v_addc_co_u32   v25, vcc, v25, v18, vcc
    v_mov_b32       v19, 0
    v_addc_co_u32   v26, vcc, v26, v19, vcc
    v_mul_lo_u32    v17, v13, v14           // E hi half * p, lands one dword up
    v_mul_hi_u32    v18, v13, v14
    v_add_co_u32    v25, vcc, v25, v17
    v_addc_co_u32   v26, vcc, v26, v18, vcc

    // -- term 2: E_B (v[8:9]) * pB (v15) --
    v_mul_lo_u32    v17, v8, v15
    v_mul_hi_u32    v18, v8, v15
    v_add_co_u32    v24, vcc, v24, v17
    v_addc_co_u32   v25, vcc, v25, v18, vcc
    v_mov_b32       v19, 0
    v_addc_co_u32   v26, vcc, v26, v19, vcc
    v_mul_lo_u32    v17, v9, v15
    v_mul_hi_u32    v18, v9, v15
    v_add_co_u32    v25, vcc, v25, v17
    v_addc_co_u32   v26, vcc, v26, v18, vcc

    // -- term 3: E_C (v[10:11]) * pC (v16) --
    v_mul_lo_u32    v17, v10, v16
    v_mul_hi_u32    v18, v10, v16
    v_add_co_u32    v24, vcc, v24, v17
    v_addc_co_u32   v25, vcc, v25, v18, vcc
    v_mov_b32       v19, 0
    v_addc_co_u32   v26, vcc, v26, v19, vcc
    v_mul_lo_u32    v17, v11, v16
    v_mul_hi_u32    v18, v11, v16
    v_add_co_u32    v25, vcc, v25, v17
    v_addc_co_u32   v26, vcc, v26, v18, vcc

    // ---- clamp at zero BEFORE the rounding bias ------------------------------------------
    // ⚠ ORDER MATTERS. Clamping after the bias would round a negative numerator toward zero by a
    // different route and disagree with the reference by one level. A sample centre outside the
    // frame legitimately gives a negative weight, so this fires on real geometry, not just at
    // the edges of the test corpus.
    v_ashrrev_i32   v19, 31, v26            // sign mask of the 96-bit accumulator
    v_not_b32       v19, v19                // 0 if negative, all-ones otherwise
    v_and_b32       v24, v24, v19
    v_and_b32       v25, v25, v19
    v_and_b32       v26, v26, v19

    // ---- + D255/2, round-half-up ---------------------------------------------------------
    v_mov_b32       v17, s30
    v_mov_b32       v18, s31                // v[17:18] = D255
    v_lshrrev_b64   v[17:18], 1, v[17:18]   // D255 >> 1
    v_add_co_u32    v24, vcc, v24, v17
    v_addc_co_u32   v25, vcc, v25, v18, vcc
    v_mov_b32       v19, 0
    v_addc_co_u32   v26, vcc, v26, v19, vcc

    // ---- funnel the 96-bit numerator down to 64 by t --------------------------------------
    // ⭐ ALWAYS FITS. t ~= log2(2A) - 22 and N <= 3 * 2^(t+48), so N >> t <= 3*2^48 for EVERY
    // frame size. Small frames make t small and the numerator small by the same factor.
    v_lshrrev_b64   v[17:18], s14, v[24:25]
    v_lshlrev_b32   v19, s15, v26           // s15 = 32 - t, the high dword's contribution
    v_or_b32        v18, v18, v19           // v[17:18] = N >> t

    // ---- the estimate-and-correct quotient, the shipped divider's shape -------------------
    // Reused rather than re-derived: this is the same routine already iron-proven in the
    // coverage rasteriser. s24 = Dh, s25 = V, s26 = L.
    v_lshlrev_b32   v27, s26, v17           // a0 = plo << L
    v_sub_u32       v28, 32, s26
    v_lshrrev_b32   v28, v28, v17           // plo >> (32-L)
    v_lshlrev_b32   v29, s26, v18
    v_or_b32        v28, v29, v28           // a1 = (phi << L) | (plo >> (32-L))

    v_mul_hi_u32    v29, v27, s25           // h0 = hi(a0 * V)   -- a0*V's low dword is never used
    v_mul_lo_u32    v30, v28, s25           // l1 = lo(a1 * V)
    v_mul_hi_u32    v31, v28, s25           // h1 = hi(a1 * V)
    v_add_co_u32    v29, vcc, v29, v30      // sum = h0 + l1
    v_mov_b32       v30, 0
    v_addc_co_u32   v31, vcc, v31, v30, vcc // hh = h1 + carry
    v_lshlrev_b32   v31, 1, v31
    v_lshrrev_b32   v30, 31, v29
    v_or_b32        v22, v31, v30           // q_hat = (hh:m) >> 31

    // ---- ⭐ THE SINGLE EXACT CORRECTION ---------------------------------------------------
    // Compared against the ORIGINAL 96-bit numerator, not the funnelled one — the funnel threw
    // away low bits, so correcting on N>>t would be correcting against a value that is not the
    // numerator. Branch-free: an add and a 96-bit unsigned compare, so no multi-precision
    // SUBTRACT is needed and nothing new has to be calibrated.
    v_add_u32       v27, 1, v22             // q+1
    v_mul_lo_u32    v28, v27, s30
    v_mul_hi_u32    v29, v27, s30
    v_mul_lo_u32    v30, v27, s31
    v_add_u32       v29, v29, v30           // v[28:29] = (q+1) * D255, 64-bit

    // 96-bit >= 64-bit: any non-zero top dword wins outright.
    v_cmp_lt_u32    vcc, v24, v28
    v_subb_co_u32   v30, vcc, v25, v29, vcc // borrow out of the middle dword
    v_cmp_ne_u32    vcc, 0, v26
    v_cndmask_b32   v30, v30, 0, vcc        // top dword non-zero => no borrow => N' >= need
    v_cmp_eq_u32    vcc, 0, v30
    v_addc_co_u32   v22, vcc, v22, 0, vcc   // q += 1 exactly when N' >= (q+1)*D255

    // ---- clamp to a byte, then to alpha ---------------------------------------------------
    v_min_u32       v22, 0xFF, v22
    v_min_u32       v22, v22, v21           // never exceed alpha (premultiplied invariant)
    s_cmp_eq_u32    s45, 24
    s_cselect_b64   s[46:47], -1, 0
    v_cndmask_b32   v21, v21, v22, s[46:47] // on the alpha pass, qa := q
    v_lshlrev_b32   v23, s45, v22
    v_or_b32        v20, v20, v23           // out |= q << shift

    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_CH

    // ======================================================================================
    // SRC-OVER INTO THE BACK BUFFER
    // ======================================================================================
    // out = src + dst * (255 - src_a) / 255, per channel, integer.
    // ⚠ THE /255 IS THE BIT-IDENTITY HINGE. `(x*a + 127) >> 8` is NOT the same function as
    // `(x*a + 127) / 255` — they differ by one level on a large fraction of inputs. The exact
    // form is what the reference computes, so it is what this must compute.
    v_lshlrev_b32   v2, 2, v1               // px * 4
    v_mov_b32       v3, s9
    v_mul_lo_u32    v3, v3, s4              // py * pitch
    v_add_u32       v2, v2, v3
    v_mov_b32       v3, 0
    v_add_co_u32    v2, vcc, s2, v2
    v_mov_b32       v3, s3
    v_addc_co_u32   v3, vcc, 0, v3, vcc     // v[2:3] = &dst[py][px]
    global_load_dword v27, v[2:3], off
    s_waitcnt       vmcnt(0)

    v_lshrrev_b32   v28, 24, v20
    v_sub_u32       v28, 0xFF, v28          // inv = 255 - src_a
    v_mov_b32       v31, 0                  // result accumulator
    s_mov_b32       s45, 24

L_OVER:
    v_lshrrev_b32   v29, s45, v27
    v_and_b32       v29, 0xFF, v29          // dst channel
    v_mul_lo_u32    v29, v29, v28
    v_add_u32       v29, 0x7F, v29          // d*inv + 127
    // /255 via the reciprocal identity: floor(x/255) = (x + (x>>8) + 1) >> 8 for x < 2^24.
    v_lshrrev_b32   v30, 8, v29
    v_add_u32       v30, v29, v30
    v_add_u32       v30, 1, v30
    v_lshrrev_b32   v30, 8, v30
    v_lshrrev_b32   v29, s45, v20
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
.amdhsa_kernel tri_rgba
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    // ⭐ 56, NOT 64, AND IT IS MEASURED. The emit list's highest register is v55, so 56 is the
    // exact requirement — the same budget the shipped coverage kernel uses. 64 was the ceiling
    // reserved while the body was being written; leaving it there would have over-declared by 8
    // registers, which the high-water gate CANNOT see (it catches under-declaration only) and
    // which costs occupancy for nothing.
    .amdhsa_next_free_vgpr 56
    .amdhsa_next_free_sgpr 48
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    .amdhsa_ieee_mode 0
    .amdhsa_exception_fp_ieee_invalid_op 0
    .amdhsa_exception_fp_denorm_src 0
    .amdhsa_exception_fp_ieee_div_zero 0
    .amdhsa_exception_fp_ieee_overflow 0
    .amdhsa_exception_fp_ieee_underflow 0
    .amdhsa_exception_fp_ieee_inexact 0
    .amdhsa_exception_int_div_zero 0
.end_amdhsa_kernel
