// edge_setup.s — gfx90c EDGE PROLOGUE. 3D arc rung 9b, dispatch 1 of 2.
//
// One lane per edge. Reads the caller's 16-byte edge record (ax, ay, bx, by as i32 in 16.16)
// and writes a 32-byte PREP record the rasteriser consumes:
//
//     [ ax, ay, ylo, yhi ] [ N, d, V, L ]
//
// ⭐ WHY THIS DISPATCH EXISTS AT ALL. The reference crossing is
//     xx = ax + ((bx-ax)*(sy-ay)) / (by-ay)
// and gfx9 has NO integer divide. But the divisor `by-ay` is CONSTANT PER EDGE, while `sy`
// varies per sub-scanline and the crossing is evaluated by every lane of every workgroup. So
// the reciprocal belongs here — computed once per edge — and the rasteriser then gets its
// quotient from 25 branch-free multiply/shift ops with no division anywhere.
//
// ⛔ NO v_rcp_f32. LLVM's f32-reciprocal division macro is exact only EMPIRICALLY (its own
// source comment says so), was demonstrably wrong before 2020, and a +1-ULP perturbation the
// ISA permits breaks it inside our operand range. The 32-iteration restoring loop below is
// exact BY CONSTRUCTION, and hoisted per edge it costs nothing amortised.
//
// ⚠ ay/by stored here are the RAW endpoints, NOT the swapped ylo/yhi. The reference swaps only
// ylo/yhi/dir; the crossing formula uses raw `ay`. Getting this backwards silently changes the
// answer on exactly half the edges (every downward-wound one).
//
// KERNARGS (USER_SGPR=8, matching GPU_COMPUTE_RSRC2_COV = 0x190):
//   s[0:1] = edge array base (16 B/edge)      s[2:3] = prep table base (32 B/edge)
//   s4     = n_edges                          s5, s6, s7 = unused
// SYSTEM SGPRs: s8 = tgid_x, s9 = tgid_y (unused here)
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl edge_setup
edge_setup:
    s_mov_b64       exec, -1

    // ---- ei = tgid_x*64 + lane, and the bounds guard BEFORE any address is formed ----
    s_lshl_b32      s10, s8, 6
    v_add_u32       v1, s10, v0
    v_cmp_gt_u32    vcc, s4, v1
    s_and_saveexec_b64 s[20:21], vcc
    s_cbranch_execz L_DONE

    // ---- load the edge: v4=ax v5=ay v6=bx v7=by ----
    v_lshlrev_b32   v20, 4, v1              // ei * 16
    v_mov_b32       v2, s0
    v_mov_b32       v3, s1
    v_add_co_u32    v2, vcc, v2, v20
    v_addc_co_u32   v3, vcc, 0, v3, vcc
    global_load_dwordx4 v[4:7], v[2:3], off
    s_waitcnt       vmcnt(0)

    // ---- ylo / yhi / d / N ----
    v_min_i32       v8,  v5, v7             // ylo = min(ay, by)
    v_max_i32       v9,  v5, v7             // yhi = max(ay, by)
    v_sub_u32       v10, v9, v8             // d = yhi - ylo
    v_max_u32       v10, 1, v10             // d >= 1: a horizontal edge would divide by zero.
                                            // It contributes no crossing (the half-open test
                                            // rejects it), so the value is never used -- but an
                                            // unclamped 0 would make dp = 0 and hang the loop.
    v_sub_u32       v11, v6, v4             // N = bx - ax

    // ---- normalise: dp = d << clz32(d), so dp is in [2^31, 2^32) ----
    v_ffbh_u32      v12, v10                // L = clz32(d)
    v_lshlrev_b32   v13, v12, v10           // ⚠ REV: amount in src0, VALUE in vsrc1 -> d << L

    // ---- V = floor((2^63 - 1) / dp), 32-iteration integer RESTORING division ----
    // The numerator's high dword is 0x7FFFFFFF and its low dword is ALL ONES. Since dp >= 2^31
    // the high dword is always < dp, and the bit shifted in is ALWAYS 1 -- so the numerator
    // needs no register at all and the loop carries only the remainder.
    // `top` MUST be captured before the shift: v_lshlrev_b32 is 32-bit and drops the carry.
    v_mov_b32       v14, 0x7FFFFFFF         // r
    v_mov_b32       v15, 0                  // V
    s_mov_b32       s22, 32
L_RECIP:
    v_lshrrev_b32   v16, 31, v14            // top = r >> 31
    v_lshlrev_b32   v14, 1, v14
    v_or_b32        v14, 1, v14             // r = (r << 1) | 1
    v_cmp_ge_u32    vcc, v14, v13
    v_cmp_ne_u32_e64 s[24:25], 0, v16
    s_or_b64        vcc, vcc, s[24:25]      // ge = top | (r >= dp)
    v_sub_u32       v17, v14, v13
    v_cndmask_b32   v14, v14, v17, vcc      // r -= dp when ge
    v_lshlrev_b32   v15, 1, v15
    v_addc_co_u32   v15, vcc, 0, v15, vcc   // V = (V << 1) | ge
    s_sub_i32       s22, s22, 1
    s_cmp_lg_i32    s22, 0
    s_cbranch_scc1  L_RECIP

    // ---- store the 32-byte prep record ----
    v_lshlrev_b32   v21, 5, v1              // ei * 32
    v_mov_b32       v18, s2
    v_mov_b32       v19, s3
    v_add_co_u32    v18, vcc, v18, v21
    v_addc_co_u32   v19, vcc, 0, v19, vcc
    v_mov_b32       v24, v4                 // ax
    v_mov_b32       v25, v5                 // ay  (RAW, not ylo)
    v_mov_b32       v26, v8                 // ylo
    v_mov_b32       v27, v9                 // yhi
    v_mov_b32       v28, v11                // N
    v_mov_b32       v29, v10                // d
    v_mov_b32       v30, v15                // V
    v_mov_b32       v31, v12                // L
    global_store_dwordx4 v[18:19], v[24:27], off glc
    global_store_dwordx4 v[18:19], v[28:31], off offset:16 glc
    s_waitcnt       vmcnt(0)

L_DONE:
    s_endpgm

// ============================================================================================
// DERIVED RSRC VALUES — extracted MECHANICALLY from the kernel descriptor below, never counted
// ============================================================================================
//   COMPUTE_PGM_RSRC1 = 0x002C00C7   (32 VGPRs, 32 SGPRs granted)
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
.amdhsa_kernel edge_setup
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 32
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
