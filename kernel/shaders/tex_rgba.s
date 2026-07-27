// tex_rgba.s — RUNG 13: nearest-neighbour, affine-UV texture mapping on gfx90c.
//
// ⛔ NO MIMG, NO T#, NO S#, NO SAMPLER DESCRIPTOR. The texel address is computed here and fetched
// with a plain global_load. Every instruction in this kernel is one already exercised by the
// rungs 9-12 blobs that are iron-proven on this silicon; introducing an image-op path would add a
// descriptor format, a sampler state and a fetch class at once, none covered by an existing oracle.
//
// ⭐ THE ALGORITHM IS ALREADY PROVEN. texmodel.cyr byte-diffs this exact arithmetic against
// texcore.cyr at 32-bit register widths — 0 differing bytes over 7 frames x 32x32 px x 3 coverages,
// both formats, with four live falsification gates. If a burn of this blob is red, the fault is the
// EMISSION. That split is what produced rung 11's 10-of-11 zero-flash record.
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
// Kernargs, as gpu_blend_cov_run stages them:
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
.globl tex_rgba
.p2align 8
.type tex_rgba,@function

tex_rgba:
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

    // -- clamp: N < 0 => texel 0. The divider below is UNSIGNED. --
    v_mov_b32       v23, 0
    v_cmp_lt_i32    vcc, v22, 0
    s_cbranch_vccz  L_U_HI
    s_branch        L_U_DONE

L_U_HI:
    // -- N >= limU => the last texel. Guards the u32 quotient against wrapping. --
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_lt_u64    vcc, v[21:22], v[16:17]
    s_cbranch_vccnz L_U_DIV
    s_sub_i32       s61, s60, 1
    v_mov_b32       v23, s61
    s_branch        L_U_DONE

L_U_DIV:
    // -- funnel right by t, then the shipped estimate-and-correct quotient --
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
    v_or_b32        v23, v29, v30           // q

    // -- the single exact correction, against the ORIGINAL 96-bit numerator --
    v_add_u32       v16, 1, v23
    v_mul_lo_u32    v17, v16, s32
    v_mul_hi_u32    v18, v16, s32
    v_mad_u64_u32   v[16:17], vcc, v16, s33, v[17:18]
    v_cmp_le_u64    vcc, v[16:17], v[21:22]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    v_add_u32       v23, s17, v23           // fold the bias back in
    v_lshrrev_b32   v23, 16, v23
    s_sub_i32       s61, s60, 1
    v_min_u32       v23, s61, v23

L_U_DONE:
    s_nop           0

L_END:
    s_endpgm

.section .rodata,"a"
.p2align 6
.amdhsa_kernel tex_rgba
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 32
    .amdhsa_next_free_sgpr 64
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    .amdhsa_ieee_mode 1
.end_amdhsa_kernel
