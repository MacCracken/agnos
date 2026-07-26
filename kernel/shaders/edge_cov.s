// edge_cov.s — gfx90c EDGE RASTERISER. 3D arc rung 9b, dispatch 2 of 2. THE triangle kernel.
//
// One lane per pixel, 64x1. Walks the prep table `edge_setup.s` produced and writes one 8bpp
// coverage byte. A triangle is a 3-edge closed path, so nothing here is triangle-specific.
//
// ⭐ NO SORT, NO LDS, NO CROSS-LANE OPERATION. The CPU reference sorts each sub-scanline's
// crossings and walks spans. A lane cannot afford a 256-entry insertion sort and cannot share
// one: gfx9 has no per-lane runtime-indexed VGPR access (v_movrels goes through M0 and is
// wave-uniform), so a resident per-lane crossing list REQUIRES LDS -- which drags in the DS
// format, a never-set RSRC2 field, and an allocation with NO readable oracle (the SH registers
// are not readable; a wrong LDS size would be undetectable). Instead each lane advances a
// cursor across ITS OWN pixel and re-scans the edge table per step. The re-scan is the chosen
// cost, and its trip count was MEASURED at 5 (edgemodel.cyr gate 4), not assumed.
//
// ⚠ HORIZONTAL EDGES REACH THIS SHADER. The #92 ABI's `ne >= 3` counts SUBMITTED edges and the
// reference filters `y0 == y1` internally, so the guard below must reject them here too --
// five of the twenty corpus cases contain one.
//
// ⛔ EVERY fragment is truncated SEPARATELY (`>> 2`). Merging them and truncating once is
// byte-invisible at EDGE_CAP=64 (one output step costs 257 accumulator units, a fragment loses
// at most 0.75), so no output test catches it -- edgemodel.cyr gate 5 checks it at the
// accumulator instead. Do not "simplify" this on the grounds that nothing goes red.
//
// KERNARGS (USER_SGPR=8, RSRC2 = GPU_COMPUTE_RSRC2_COV = 0x190):
//   s[0:1] = prep table   s[2:3] = dst mask   s4 = n_edges   s5 = unused   s6 = w   s7 = unused
// SYSTEM SGPRs: s8 = tgid_x (64-px column block), s9 = tgid_y (= py). v0 = lane 0..63.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl edge_cov
edge_cov:
    s_mov_b64       exec, -1

    // ---- px = tgid_x*64 + lane, bounds guard BEFORE any address is formed ----
    s_lshl_b32      s10, s8, 6
    v_add_u32       v1, s10, v0             // px
    v_cmp_gt_u32    vcc, s6, v1             // w > px ?
    s_and_saveexec_b64 s[20:21], vcc
    s_cbranch_execz L_END

    v_lshlrev_b32   v2, 16, v1              // pl = px << 16
    v_mov_b32       v3, 0x10000
    v_add_u32       v3, v2, v3              // pr = pl + 65536
    v_mov_b32       v4, 0                   // acc
    s_lshl_b32      s11, s9, 16             // py << 16
    s_mov_b32       s12, 0                  // s = sub-scanline index 0..3

    // ================= SUB-SCANLINE LOOP (4 iterations) =================
L_SUB:
    // sy = (py << 16) + (s*65536 + 32768)/4  ->  {8192, 24576, 40960, 57344}
    s_lshl_b32      s13, s12, 14            // s * 16384
    s_add_u32       s13, s13, 8192
    s_add_u32       s13, s13, s11           // sy
    v_mov_b32       v5, v2                  // u = pl

    // ================= BREAKPOINT WALK =================
L_STEP:
    v_mov_b32       v6, 0                   // w_acc
    v_mov_b32       v7, 0x7FFFFFFF          // vmin = INF
    v_mov_b32       v8, 0                   // any
    s_mov_b32       s14, 0                  // ei

    // ================= EDGE SCAN =================
L_EDGE:
    s_lshl_b32      s15, s14, 5             // ei * 32
    v_mov_b32       v9,  s0
    v_mov_b32       v10, s1
    v_add_co_u32    v9,  vcc, v9, s15
    v_addc_co_u32   v10, vcc, 0, v10, vcc
    global_load_dwordx4 v[12:15], v[9:10], off          // ax ay ylo yhi
    global_load_dwordx4 v[16:19], v[9:10], off offset:16 // N  d  V  L
    s_waitcnt       vmcnt(0)

    // ---- act = (ylo <= sy) && (sy < yhi). THE HALF-OPEN RULE, before the divide. ----
    // A horizontal edge has ylo == yhi and can satisfy neither, so it is rejected here.
    v_mov_b32       v20, s13                // sy
    v_cmp_le_i32    vcc, v14, v20           // ylo <= sy
    v_cndmask_b32   v21, 0, 1, vcc
    v_cmp_gt_i32    vcc, v15, v20           // yhi > sy
    v_cndmask_b32   v22, 0, 1, vcc
    v_and_b32       v21, v21, v22           // act (0 or 1)

    // ================= THE 25-OP BRANCH-FREE DIVIDER =================
    // trunc(N*t/D) = sign(N) * floor(M*u/d), with u <= d guaranteed by the half-open rule.
    v_sub_u32       v23, v20, v13           // t = sy - ay   (RAW ay)
    v_ashrrev_i32   v24, 31, v23
    v_add_u32       v25, v23, v24
    v_xor_b32       v25, v25, v24           // u = |t|
    v_cmp_ne_u32    vcc, 0, v21
    v_cndmask_b32   v25, 0, v25, vcc        // off-guard -> u = 0 -> P = 0, never wraps
    v_ashrrev_i32   v26, 31, v16
    v_add_u32       v27, v16, v26
    v_xor_b32       v27, v27, v26           // M = |N|
    v_mul_lo_u32    v28, v27, v25           // P.lo
    v_mul_hi_u32    v29, v27, v25           // P.hi  ⭐ NEVER RUN ON AGNOS SILICON -- burn 1's
                                            // first oracle exists for exactly this instruction
    v_sub_u32       v30, 32, v19            // L32 = 32 - L
    v_lshlrev_b32   v31, v19, v28           // P' = P << L, built from four 32-bit ops
    v_lshlrev_b32   v32, v19, v29
    v_lshrrev_b32   v33, v30, v28
    v_or_b32        v32, v32, v33
    v_mul_hi_u32    v34, v31, v18           // h0   (a0*V's LOW dword is never needed)
    v_mul_lo_u32    v35, v32, v18           // l1
    v_mul_hi_u32    v36, v32, v18           // h1
    v_add_co_u32    v37, vcc, v34, v35      // m
    v_addc_co_u32   v38, vcc, 0, v36, vcc   // hh
    v_lshlrev_b32   v39, 1, v38             // q_hat = (hh:m) >> 31
    v_lshrrev_b32   v40, 31, v37
    v_or_b32        v39, v39, v40
    v_mul_lo_u32    v41, v39, v17
    v_sub_u32       v42, v28, v41           // r = P.lo - q*d   (low dword only)
    v_cmp_ge_u32    vcc, v42, v17
    v_addc_co_u32   v39, vcc, 0, v39, vcc   // THE single correction; q is now exactly Q
    v_sub_u32       v43, v12, v39           // ax - q
    v_add_u32       v44, v12, v39           // ax + q
    v_cmp_gt_i32    vcc, 0, v16             // N < 0 ?
    v_cndmask_b32   v45, v44, v43, vcc      // xx

    // ---- dir = (ay == yhi) ? -1 : +1 ----
    v_cmp_eq_i32    vcc, v13, v15
    v_cndmask_b32   v46, 1, -1, vcc

    // ---- accumulate winding to the left of u; track the nearest crossing to the right ----
    // `<=` not `<`: ties at the left edge must count, exactly as the reference's sorted walk
    // counts them before emitting the following span.
    v_cmp_le_i32    vcc, v45, v5            // xx <= u
    v_cndmask_b32   v47, 0, v46, vcc
    v_cmp_ne_u32    vcc, 0, v21
    v_cndmask_b32   v47, 0, v47, vcc        // gated by act
    v_add_u32       v6, v6, v47             // w_acc += dir

    v_cmp_gt_i32    vcc, v45, v5            // xx > u
    v_cndmask_b32   v48, 0, 1, vcc
    v_and_b32       v48, v48, v21           // and act
    v_min_i32       v49, v7, v45
    v_cmp_ne_u32    vcc, 0, v48
    v_cndmask_b32   v7, v7, v49, vcc        // vmin = min(vmin, xx)
    v_or_b32        v8, v8, v48             // any

    s_add_u32       s14, s14, 1
    s_cmp_lt_u32    s14, s4
    s_cbranch_scc1  L_EDGE
    // ================= end EDGE SCAN =================

    // ---- no crossing to the right: NEVER fill past the last crossing ----
    v_cmp_ne_u32    vcc, 0, v8
    s_and_b64       vcc, vcc, exec
    s_cbranch_vccz  L_SUBNEXT

    v_min_i32       v50, v7, v3             // v = min(vmin, pr)
    v_sub_u32       v51, v50, v5            // v - u
    v_lshrrev_b32   v51, 2, v51             // ONE fragment, truncated ONCE
    v_cmp_ne_u32    vcc, 0, v6              // w_acc != 0 ?
    v_cndmask_b32   v51, 0, v51, vcc
    v_add_u32       v4, v4, v51             // acc += fragment
    v_mov_b32       v5, v50                 // u = v

    v_cmp_lt_i32    vcc, v5, v3             // u < pr ?
    s_and_b64       vcc, vcc, exec
    s_cbranch_vccnz L_STEP
    // ================= end BREAKPOINT WALK =================

L_SUBNEXT:
    s_add_u32       s12, s12, 1
    s_cmp_lt_u32    s12, 4
    s_cbranch_scc1  L_SUB
    // ================= end SUB-SCANLINE LOOP =================

    // ---- c = min(acc, 65536) * 255 >> 16, written as (acc<<8 - acc) >> 16 ----
    // min(acc, 65536) is output-equivalent to the reference's `c > 255` clamp and removes the
    // accumulator-width question entirely.
    v_mov_b32       v52, 0x10000
    v_min_u32       v4, v4, v52
    v_lshlrev_b32   v53, 8, v4
    v_sub_u32       v53, v53, v4
    v_lshrrev_b32   v53, 16, v53

    // ---- dst + py*w + px ----
    s_mul_i32       s16, s9, s6
    v_mov_b32       v54, s2
    v_mov_b32       v55, s3
    v_add_co_u32    v54, vcc, v54, s16
    v_addc_co_u32   v55, vcc, 0, v55, vcc
    v_add_co_u32    v54, vcc, v54, v1
    v_addc_co_u32   v55, vcc, 0, v55, vcc
    global_store_byte v[54:55], v53, off glc
    s_waitcnt       vmcnt(0)

L_END:
    s_endpgm

// ============================================================================================
// DERIVED RSRC VALUES — extracted MECHANICALLY from the kernel descriptor below, never counted
// ============================================================================================
//   COMPUTE_PGM_RSRC1 = 0x002C00CD   (56 VGPRs, 32 SGPRs granted)
//   COMPUTE_PGM_RSRC2 = 0x00000190  == the SHIPPED GPU_COMPUTE_RSRC2_COV
//
// ⭐ RSRC2 matching the shipped constant is what lets `gpu_blend_cov_run` dispatch BOTH of
// these kernels UNMODIFIED: USER_SGPR=8, TGID_X_EN, TGID_Y_EN. No dispatcher change, no new
// PM4, no RSRC2 edit.
//
// ⛔ HAND-COUNTING THIS IS A REAL HAZARD, demonstrated. A hand-derivation of edge_cov's value
// gave 0x002C008D — an SGPR field of 2 (24 granted) where llvm-mc grants 3 (32). Under-
// allocating the SGPR file corrupts the vcc carry chain in the address arithmetic, and the
// first casualty is lanes writing the WRONG PIXELS. The committed value comes from
// `llvm-objcopy -O binary --only-section=.rodata` byte 48, not from arithmetic.
.rodata
.p2align 6
.amdhsa_kernel edge_cov
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 56
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
