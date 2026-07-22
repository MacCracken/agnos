// blend_rect.s — gfx90c premultiplied src-over alpha blend over a 2-D GRID, in place on a strided surface.
//
// The grid peer of blend_premul.s. That kernel proved the BLEND MATH on iron (1.56.0 burn 2: 64 px,
// bit-exact vs the CPU reference). This one keeps that arithmetic byte-for-byte identical and changes only
// the ADDRESSING, so a failure here cannot be a blend bug — it is an address bug or a coherence bug.
//
// WHY A 2-D GRID AND NOT A FLAT INDEX: a flat pixel id would need `y = gid / width`, and integer division
// by a runtime width costs a v_rcp_f32 + Newton correction + fixup on GFX9 (no integer divide exists).
// Dispatching DIM = (width/64, height, 1) makes the same decomposition FREE: x comes from tgid_x, y from
// tgid_y, both delivered in SGPRs by the SPI. This is also how real compositors dispatch.
//
// ⚠ SGPR COLLISION — the reason this is not a copy-paste of blend_premul.s: that kernel stages the
// -1/255f constant in **s6**. With TGID_X_EN set, **s6 IS tgid_x**. Reusing it here would overwrite the
// column index with a float constant and every address would be wrong. The constant lives in s15 below.
//
// KERNARGS (USER_SGPR=6):
//   s[0:1] = src base (premultiplied BGRA8888, tightly packed rows of src_pitch bytes)
//   s[2:3] = dst base — READ AND WRITTEN IN PLACE (this is the back buffer)
//   s4     = src pitch in BYTES     s5 = dst pitch in BYTES
// SYSTEM SGPRs (after the 6 user SGPRs):  s6 = tgid_x (64-px column group)   s7 = tgid_y (row)
//
// In-place is safe: exactly one lane owns each pixel, and each lane reads only the pixel it writes.
// There is no cross-lane dependency, so no barrier and no ordering hazard.
//
// ⚠ WIDTH MUST BE A MULTIPLE OF 64. There is no bounds guard — a partial trailing group would blend
// pixels past the rect's right edge. The caller enforces this; gpu.cyr rejects a non-multiple width
// rather than silently corrupting the row to its right.
//
// ROUNDING: v_cvt_pk_u8_f32 ROUNDS TO NEAREST (settled on iron, 1.56.0 burn 1 — an added +0.5 came out
// +1 on every channel). No rounding bias is applied here, matching the corrected blend_premul.s.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl blend_rect
blend_rect:
    // ---- scalar address setup: the whole 64-lane group shares one row and one column base ----
    s_lshl_b32      s8, s6, 8              // column byte base = tgid_x * 64 px * 4 B
    s_mul_i32       s9, s7, s4             // src row byte base = tgid_y * src_pitch
    s_add_u32       s9, s9, s8
    s_add_u32       s10, s0, s9            // sets SCC = carry
    s_addc_u32      s11, s1, 0             // consumes that carry — 64-bit src address
    s_mul_i32       s12, s7, s5            // dst row byte base = tgid_y * dst_pitch
    s_add_u32       s12, s12, s8
    s_add_u32       s13, s2, s12
    s_addc_u32      s14, s3, 0             // 64-bit dst address

    v_lshlrev_b32   v1, 2, v0              // per-lane byte offset within the 64-px group

    // src pixel -> v2
    v_mov_b32       v4, s10
    v_mov_b32       v5, s11
    v_add_co_u32    v4, vcc, v4, v1
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_load_dword v2, v[4:5], off

    // dst pixel -> v3 ; v[6:7] is ALSO the store address (in place)
    v_mov_b32       v6, s13
    v_mov_b32       v7, s14
    v_add_co_u32    v6, vcc, v6, v1
    v_addc_co_u32   v7, vcc, 0, v7, vcc
    global_load_dword v3, v[6:7], off
    s_waitcnt       vmcnt(0)

    // ---- blend body: IDENTICAL to blend_premul.s except the constant lives in s15, not s6 ----
    // ia = 1 - src_a/255, as one FMA: v8 = src_a * (-1/255) + 1.0
    v_cvt_f32_ubyte3 v8, v2
    s_mov_b32       s15, 0xBB808081        // -1/255f (VOP3 takes no 32-bit literal on gfx9)
    v_fma_f32       v8, v8, s15, 1.0

    v_cvt_f32_ubyte0 v9,  v2
    v_cvt_f32_ubyte0 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 0, v11

    v_cvt_f32_ubyte1 v9,  v2
    v_cvt_f32_ubyte1 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 1, v11

    v_cvt_f32_ubyte2 v9,  v2
    v_cvt_f32_ubyte2 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 2, v11

    v_cvt_f32_ubyte3 v9,  v2
    v_cvt_f32_ubyte3 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 3, v11

    // store in place over the dst pixel
    global_store_dword v[6:7], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel blend_rect
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 12
    .amdhsa_next_free_sgpr 16
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
