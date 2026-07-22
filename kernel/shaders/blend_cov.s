// blend_cov.s — gfx90c COVERAGE blend: a uniform premultiplied colour modulated by an 8-bit per-pixel
// coverage mask, composited src-over onto a strided surface. The anti-aliased text and shape primitive.
//
// This is the shape a 2D renderer actually needs. A rasteriser (rekha glyph → sadish path) emits COVERAGE,
// not colour: one byte per pixel saying how much of that pixel the shape covers. The colour is uniform for
// the whole run. So the source is an SGPR, not a buffer, and the varying input is 8bpp rather than 32bpp —
// a quarter of the source bandwidth of blend_rect for the same output.
//
// It is also the only way to get a smooth edge at all. CP-DMA can fill rectangles; blend_rect can composite
// a rectangular image. Neither can produce a non-rectangular shape with a soft boundary, because both are
// blind to partial pixel coverage. That is the whole reason this kernel exists.
//
// MATH (all premultiplied, so scaling by coverage keeps the invariant c <= a):
//   f    = cov / 255                    coverage as a fraction
//   sa'  = colour_a * f                 the effective source alpha for this pixel
//   sc'  = colour_c * f                 likewise per channel — premultiplied stays premultiplied
//   out  = sc' + dst_c * (1 - sa'/255)
// The four colour->float converts and their multiplies are hoisted out of the per-channel work, so the
// inner cost is one convert + one fma + one pack per channel.
//
// ⚠ PRECISION — this kernel is NOT claimed bit-exact against exact rational arithmetic, and the self-test
// says so rather than pretending otherwise. blend_rect had ONE rounding site (the final pack). Here the
// coverage multiply inserts a second, and 1/255 is not representable in binary floating point, so an
// intermediate can land a half-ulp either side. Two cases ARE exact and are asserted as such: cov = 0 must
// return dst untouched, and cov = 255 must equal the blend_rect result already proven bit-correct. Between
// them the test bounds the deviation at <= 1 and REPORTS the observed maximum, so drift shows up as a
// number rather than as a silently loosened gate.
//
// KERNARGS (USER_SGPR=8):
//   s[0:1] = coverage mask base (8bpp, rows of mask_pitch BYTES)
//   s[2:3] = dst base — read and written IN PLACE
//   s4     = mask pitch in BYTES    s5 = dst pitch in BYTES    s6 = width in PIXELS
//   s7     = premultiplied colour, ARGB8888 (uniform across the whole dispatch)
// SYSTEM SGPRs (after the 8 user SGPRs):  s8 = tgid_x   s9 = tgid_y
//
// Bounds guard, in-place safety, and rounding behaviour are all as in blend_rect.s — see that file. Width
// is arbitrary; surplus lanes mask off before any address is formed.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl blend_cov
blend_cov:
    // ---- BOUNDS GUARD: mask off lanes past the right edge BEFORE forming any address ----
    s_lshl_b32      s10, s8, 6             // first pixel x of this workgroup
    v_add_u32       v12, s10, v0           // this lane's x
    v_cmp_gt_u32    vcc, s6, v12           // width > x ?
    s_and_saveexec_b64 s[20:21], vcc

    // ---- mask address: 8bpp, so the column offset in BYTES equals the pixel index ----
    s_mul_i32       s11, s9, s4
    s_add_u32       s11, s11, s10
    s_add_u32       s12, s0, s11
    s_addc_u32      s13, s1, 0

    // ---- dst address: 32bpp, column offset = tgid_x * 64 px * 4 B ----
    s_lshl_b32      s14, s8, 8
    s_mul_i32       s15, s9, s5
    s_add_u32       s15, s15, s14
    s_add_u32       s16, s2, s15
    s_addc_u32      s17, s3, 0

    // coverage byte -> v2 (lane offset is the raw index, one byte per pixel)
    v_mov_b32       v4, s12
    v_mov_b32       v5, s13
    v_add_co_u32    v4, vcc, v4, v0
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_load_ubyte v2, v[4:5], off

    // dst pixel -> v3 ; v[6:7] is ALSO the store address (in place)
    v_lshlrev_b32   v1, 2, v0
    v_mov_b32       v6, s16
    v_mov_b32       v7, s17
    v_add_co_u32    v6, vcc, v6, v1
    v_addc_co_u32   v7, vcc, 0, v7, vcc
    global_load_dword v3, v[6:7], off
    s_waitcnt       vmcnt(0)

    // f = cov / 255
    s_mov_b32       s24, 0x3B808081        // +1/255f
    v_cvt_f32_ubyte0 v8, v2
    v_mul_f32       v8, s24, v8

    // sa' = colour_a * f ; ia = 1 - sa'/255   (colour is a SCALAR — VOP1 accepts an SGPR source)
    s_mov_b32       s25, 0xBB808081        // -1/255f
    v_cvt_f32_ubyte3 v9, s7
    v_mul_f32       v9, v9, v8
    v_fma_f32       v10, v9, s25, 1.0

    v_cvt_f32_ubyte0 v13, s7
    v_mul_f32       v13, v13, v8
    v_cvt_f32_ubyte0 v14, v3
    v_fma_f32       v13, v14, v10, v13
    v_cvt_pk_u8_f32 v11, v13, 0, v11

    v_cvt_f32_ubyte1 v13, s7
    v_mul_f32       v13, v13, v8
    v_cvt_f32_ubyte1 v14, v3
    v_fma_f32       v13, v14, v10, v13
    v_cvt_pk_u8_f32 v11, v13, 1, v11

    v_cvt_f32_ubyte2 v13, s7
    v_mul_f32       v13, v13, v8
    v_cvt_f32_ubyte2 v14, v3
    v_fma_f32       v13, v14, v10, v13
    v_cvt_pk_u8_f32 v11, v13, 2, v11

    // alpha channel reuses sa' already computed in v9 — no second multiply
    v_cvt_f32_ubyte3 v14, v3
    v_fma_f32       v13, v14, v10, v9
    v_cvt_pk_u8_f32 v11, v13, 3, v11

    global_store_dword v[6:7], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel blend_cov
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 15
    .amdhsa_next_free_sgpr 26
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
