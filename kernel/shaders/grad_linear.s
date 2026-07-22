// grad_linear.s — gfx90c VERTICAL LINEAR GRADIENT: interpolate between two premultiplied colours down the
// rect and composite the result src-over, in place. The last drawing primitive on the 1.56.x scope list.
//
// This one has NO SOURCE BUFFER AT ALL. Both endpoints are SGPRs and the varying quantity is the row index,
// which the SPI already hands us in tgid_y. So a full-screen gradient reads zero source bytes — where
// blend_rect would need 4 bytes per pixel and blend_cov 1, this needs none. On the CPU a gradient is the
// worst case of all: per-pixel interpolate AND per-pixel blend, with no memcpy-shaped inner loop to lean on.
//
// PREMULTIPLIED IS WHAT MAKES THE LERP LEGAL. Linear interpolation between two premultiplied colours is
// still premultiplied — if c0 <= a0 and c1 <= a1 then c0+(c1-c0)t <= a0+(a1-a0)t for t in [0,1]. Lerping
// STRAIGHT-alpha colours is the classic gradient bug: it darkens through the middle, because the colour
// crosses the alpha ramp instead of riding it.
//
// ⚠ PRECISION: t comes from v_rcp_f32, a hardware RECIPROCAL APPROXIMATION (~1 ULP), not an exact divide —
// GFX9 has no integer divide and no exact f32 divide instruction. Consequences the self-test encodes
// rather than glosses:
//   - row 0 IS exact (t is exactly 0.0, so the result is exactly colour0) and is asserted with no tolerance
//   - the LAST row is NOT guaranteed exact: t = (H-1) * rcp(H-1) may land a hair under 1.0
//   - everywhere else the deviation is bounded at <= 2 and the observed maximum is REPORTED
// The bound is 2 rather than blend_cov's 1 precisely because of the reciprocal — stated up front so the
// looser gate reads as a derived consequence rather than a gate quietly widened to make a test pass.
//
// KERNARGS (USER_SGPR=7):
//   s[0:1] = dst base — read and written IN PLACE     s2 = dst pitch in BYTES
//   s3     = width in PIXELS   s4 = height in ROWS (the interpolation denominator is height-1)
//   s5     = colour at row 0, premultiplied ARGB      s6 = colour at row height-1
// SYSTEM SGPRs (after the 7 user SGPRs):  s7 = tgid_x   s8 = tgid_y
//
// Bounds guard and in-place safety are as in blend_rect.s.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl grad_linear
grad_linear:
    // ---- BOUNDS GUARD (width is s3 here, not s6 — the kernarg layout differs from blend_rect) ----
    s_lshl_b32      s9, s7, 6
    v_add_u32       v12, s9, v0
    v_cmp_gt_u32    vcc, s3, v12
    s_and_saveexec_b64 s[16:17], vcc

    // ---- destination ----
    s_lshl_b32      s10, s7, 8
    s_mul_i32       s11, s8, s2
    s_add_u32       s11, s11, s10
    s_add_u32       s12, s0, s11
    s_addc_u32      s13, s1, 0
    v_lshlrev_b32   v1, 2, v0
    v_mov_b32       v6, s12
    v_mov_b32       v7, s13
    v_add_co_u32    v6, vcc, v6, v1
    v_addc_co_u32   v7, vcc, 0, v7, vcc
    global_load_dword v3, v[6:7], off

    // ---- t = tgid_y / (height - 1), uniform across the whole workgroup ----
    s_add_i32       s14, s4, -1
    v_cvt_f32_u32   v9, s14
    v_rcp_f32       v9, v9
    v_cvt_f32_u32   v2, s8
    v_mul_f32       v2, v2, v9
    s_waitcnt       vmcnt(0)

    // ---- sa = a0 + (a1-a0)*t ; ia = 1 - sa/255 ----
    s_mov_b32       s20, 0xBB808081        // -1/255f
    v_cvt_f32_ubyte3 v9, s5
    v_cvt_f32_ubyte3 v10, s6
    v_sub_f32       v10, v10, v9
    v_fma_f32       v11, v10, v2, v9       // sa (kept — the alpha channel reuses it below)
    v_fma_f32       v8, v11, s20, 1.0      // ia

    v_cvt_f32_ubyte0 v9, s5
    v_cvt_f32_ubyte0 v10, s6
    v_sub_f32       v10, v10, v9
    v_fma_f32       v9, v10, v2, v9        // sc = c0 + (c1-c0)*t
    v_cvt_f32_ubyte0 v10, v3
    v_fma_f32       v9, v10, v8, v9        // + dst*ia
    v_cvt_pk_u8_f32 v13, v9, 0, v13

    v_cvt_f32_ubyte1 v9, s5
    v_cvt_f32_ubyte1 v10, s6
    v_sub_f32       v10, v10, v9
    v_fma_f32       v9, v10, v2, v9
    v_cvt_f32_ubyte1 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v13, v9, 1, v13

    v_cvt_f32_ubyte2 v9, s5
    v_cvt_f32_ubyte2 v10, s6
    v_sub_f32       v10, v10, v9
    v_fma_f32       v9, v10, v2, v9
    v_cvt_f32_ubyte2 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v13, v9, 2, v13

    // alpha: sa already interpolated in v11, no second lerp
    v_cvt_f32_ubyte3 v10, v3
    v_fma_f32       v9, v10, v8, v11
    v_cvt_pk_u8_f32 v13, v9, 3, v13

    global_store_dword v[6:7], v13, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel grad_linear
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 7
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 14
    .amdhsa_next_free_sgpr 21
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
