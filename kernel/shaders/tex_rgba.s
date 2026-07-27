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
    // ⛔ v[20:21], NOT v[21:22]. The 96-bit numerator is (v20 lo, v21 mid, v22 hi); its 64-bit
    // VALUE is v[20:21]. Comparing v[21:22] compares the numerator SHIFTED RIGHT BY 32 against an
    // unshifted limit — off by 2^32. The limit check already fired when v22 != 0, so v[20:21] is
    // the whole value here.
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_lt_u64    vcc, v[20:21], v[16:17]
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
    // ⛔ (q+1)*A2 AS A PROPER 64x32 PRODUCT. A2 is 64-bit (s32 lo, s33 hi), so
    //     lo = lo(q1*A2lo)   hi = hi(q1*A2lo) + lo(q1*A2hi)
    // The first version folded this through v_mad_u64_u32 with v16 as both an operand and part of
    // the destination, and compared against v[21:22] — the numerator shifted right by 32. The
    // result was a correction that could never fire, so a quotient landing one ULP short of an
    // exact integer stayed short. Iron found it at u = 6.5*8/13 = 4.0 exactly: texel 3 for texel 4.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v19, v18, s33
    v_add_u32       v17, v17, v19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    v_add_u32       v23, s17, v23           // fold the bias back in
    // ⚠ ARITHMETIC shift and SIGNED clamps. q+m can be negative when the UV frame extrapolates
    // below zero; a logical shift would turn that into a huge positive index and v_min_u32 would
    // then select dim-1 — the OPPOSITE edge. texcore clamps such samples to texel 0.
    v_ashrrev_i32   v23, 16, v23
    s_sub_i32       s61, s60, 1
    v_max_i32       v23, 0, v23
    v_min_i32       v23, s61, v23

L_U_DONE:
    v_mov_b32       v19, v23                // stash tu; v23 is reused by the V axis

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

    v_mov_b32       v23, 0
    v_cmp_lt_i32    vcc, v22, 0
    s_cbranch_vccnz L_V_DONE

    // ⛔ v[20:21], NOT v[21:22]. The 96-bit numerator is (v20 lo, v21 mid, v22 hi); its 64-bit
    // VALUE is v[20:21]. Comparing v[21:22] compares the numerator SHIFTED RIGHT BY 32 against an
    // unshifted limit — off by 2^32. The limit check already fired when v22 != 0, so v[20:21] is
    // the whole value here.
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_lt_u64    vcc, v[20:21], v[16:17]
    s_cbranch_vccnz L_V_DIV
    s_sub_i32       s61, s60, 1
    v_mov_b32       v23, s61
    s_branch        L_V_DONE

L_V_DIV:
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

    // ⛔ (q+1)*A2 AS A PROPER 64x32 PRODUCT. A2 is 64-bit (s32 lo, s33 hi), so
    //     lo = lo(q1*A2lo)   hi = hi(q1*A2lo) + lo(q1*A2hi)
    // The first version folded this through v_mad_u64_u32 with v16 as both an operand and part of
    // the destination, and compared against v[21:22] — the numerator shifted right by 32. The
    // result was a correction that could never fire, so a quotient landing one ULP short of an
    // exact integer stayed short. Iron found it at u = 6.5*8/13 = 4.0 exactly: texel 3 for texel 4.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v19, v18, s33
    v_add_u32       v17, v17, v19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    v_add_u32       v23, s17, v23
    // ⚠ ARITHMETIC shift and SIGNED clamps. q+m can be negative when the UV frame extrapolates
    // below zero; a logical shift would turn that into a huge positive index and v_min_u32 would
    // then select dim-1 — the OPPOSITE edge. texcore clamps such samples to texel 0.
    v_ashrrev_i32   v23, 16, v23
    s_sub_i32       s61, s60, 1
    v_max_i32       v23, 0, v23
    v_min_i32       v23, s61, v23

L_V_DONE:
    // v19 = tu, v23 = tv, both already clamped into range.

    // ======================================================================================
    // THE TEXEL FETCH
    // ======================================================================================
    // ⭐ s_cbranch ON THE FORMAT IS SAFE, AND THAT IS NOT AN ACCIDENT. `fmt` lives in an SGPR, so
    // the branch is WAVE-UNIFORM — every lane takes the same side. This is the one place a scalar
    // branch is legitimate; a per-lane condition here would need an exec mask, which is the trap
    // [[reference_gfx9_per_lane_control_flow]] records.
    v_mul_lo_u32    v7, v23, s34            // tv * tw
    v_add_u32       v7, v7, v19             // + tu   => linear texel index
    s_cmp_eq_u32    s31, 0
    s_cbranch_scc0  L_FETCH_IDX8

    v_lshlrev_b32   v7, 2, v7               // RGBA8: 4 bytes per texel
    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_dword v25, v[14:15], off
    s_waitcnt       vmcnt(0)
    s_branch        L_HAVE_TEXEL

L_FETCH_IDX8:
    // ⚠ TWO DEPENDENT FETCHES. The index load must complete before the LUT address exists, so the
    // s_waitcnt between them is load-bearing, not defensive.
    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_ubyte v25, v[14:15], off
    s_waitcnt       vmcnt(0)
    v_lshlrev_b32   v7, 2, v25              // index * 4 into the 256-entry LUT
    v_mov_b32       v14, s46
    v_mov_b32       v15, s47
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_dword v25, v[14:15], off
    s_waitcnt       vmcnt(0)

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
