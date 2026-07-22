// glyph_1bpp.s — gfx90c 1bpp -> 32bpp expansion with a TRANSPARENT background: the bitmap-text primitive.
//
// The highest call-count drawing operation in the whole desktop tree. Every character cell in every
// terminal, menu, label and list row is this: take a 1-bit-per-pixel glyph bitmap, write a solid colour
// where the bit is set, and LEAVE THE DESTINATION ALONE where it is clear.
//
// That last part is what makes it its own kernel rather than a special case of anything else. It is not a
// fill (the background must survive), not a copy (the source has no colour), and not a blend (there is no
// partial coverage — a bit is on or off). It is a CONDITIONAL STORE, which on a SIMD machine means an EXEC
// mask derived from the source data itself.
//
// It also consumes the font's NATIVE format. kashi ships CP437 as 1bpp row bytes; expanding those to 8bpp
// coverage in userland just to call #93 would reintroduce the per-pixel CPU loop this whole arc exists to
// delete. And 1bpp is 8x smaller than a coverage mask and 32x smaller than an RGBA source.
//
// ⚠ THIS KERNEL IS EXACTLY VERIFIABLE, unlike blend_cov. There is no arithmetic on colour at all — a pixel
// either becomes `colour` or is untouched — so the self-test asserts bit-exactness with no tolerance and
// no rounding discussion. Any deviation is a real bug.
//
// BIT ORDER: MSB-first within each byte (bit 7 is the leftmost pixel), matching kashi/VGA/PSF convention
// and fb_console.cyr's own `load8(glyph + row)` walk. Getting this backwards mirrors every glyph, which is
// obvious on screen but silent in a numeric test — so the test renders readable words, not a pattern.
//
// KERNARGS (USER_SGPR=8):
//   s[0:1] = bitmap base (1bpp, rows of s4 BYTES)      s[2:3] = dst base
//   s4     = bitmap row stride in BYTES   s5 = dst pitch in BYTES   s6 = width in PIXELS
//   s7     = colour, stored verbatim where a bit is set
// SYSTEM SGPRs (after the 8 user SGPRs):  s8 = tgid_x   s9 = tgid_y
//
// Width is arbitrary; surplus lanes mask off before any address is formed, as in blend_rect.s.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl glyph_1bpp
glyph_1bpp:
    // ---- BOUNDS GUARD ----
    s_lshl_b32      s10, s8, 6
    v_add_u32       v2, s10, v0            // this lane's x
    v_cmp_gt_u32    vcc, s6, v2
    s_and_saveexec_b64 s[20:21], vcc

    // ---- source byte: one byte covers 8 pixels, so the byte index is x >> 3 ----
    v_lshrrev_b32   v3, 3, v2
    s_mul_i32       s11, s9, s4
    s_add_u32       s12, s0, s11
    s_addc_u32      s13, s1, 0
    v_mov_b32       v4, s12
    v_mov_b32       v5, s13
    v_add_co_u32    v4, vcc, v4, v3
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_load_ubyte v6, v[4:5], off

    // ---- destination pixel ----
    s_lshl_b32      s14, s8, 8
    s_mul_i32       s15, s9, s5
    s_add_u32       s15, s15, s14
    s_add_u32       s16, s2, s15
    s_addc_u32      s17, s3, 0
    v_lshlrev_b32   v1, 2, v0
    v_mov_b32       v7, s16
    v_mov_b32       v8, s17
    v_add_co_u32    v7, vcc, v7, v1
    v_addc_co_u32   v8, vcc, 0, v8, vcc
    s_waitcnt       vmcnt(0)

    // ---- test this lane's bit: MSB-first, so shift = 7 - (x & 7) ----
    v_and_b32       v9, 7, v2
    v_sub_u32       v9, 7, v9
    v_lshrrev_b32   v10, v9, v6
    v_and_b32       v10, 1, v10
    v_cmp_ne_u32    vcc, 0, v10
    s_and_b64       exec, exec, vcc        // CONDITIONAL STORE: clear bits leave dst untouched

    v_mov_b32       v11, s7
    global_store_dword v[7:8], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel glyph_1bpp
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 12
    .amdhsa_next_free_sgpr 22
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
