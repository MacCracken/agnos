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
// ⚠ REGISTER BUDGET IS TIGHT AND MEASURED, NOT ESTIMATED. The shipped edge_cov uses up to v55
// against a declared 56 — zero headroom — so this kernel declares its own budget rather than
// inheriting that descriptor. 64 is the hard occupancy cliff: 65 registers drops from 4 waves per
// SIMD to 3. edgeasm's high-water gate checks the emit list against the declaration mechanically,
// because RSRC1 is NOT GRBM-readable and nothing on the machine can contradict a wrong one.
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
    .amdhsa_next_free_vgpr 64
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
