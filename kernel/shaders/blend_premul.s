// blend_premul.s — gfx90c src-over alpha blend, PREMULTIPLIED, f32.
//
//   out = src + dst * (1 - src_a)
//
// WHY FLOAT, NOT INTEGER: GFX9 has hardware unpack ONLY to f32 (v_cvt_f32_ubyte0..3, one VOP1 per byte
// lane, no shift/mask) and hardware pack ONLY from f32 (v_cvt_pk_u8_f32, one VOP3A, converts AND inserts
// into a chosen byte lane). Neither the integer nor the f16 path has any equivalent. Measured on this ISA:
// premultiplied f32 = 20-22 VALU/pixel; packed-int16 with div255 = 31-33; packed f16 = 43-45. Float is not
// a compromise here, it is the native format for byte-packed pixels. (v_dot4_i32_i8, which would rescue an
// integer path, does not exist on gfx90c — it assembles for gfx906 and is rejected for gfx90c.)
//
// WHY PREMULTIPLIED: drops the src*a term entirely (5 fewer VALU) AND makes the result provably <= 255, so
// no clamp instruction is needed. Verified exhaustively over all valid (sa, s<=sa, d): 0 mismatches vs the
// exact rational reference, max result exactly 255.
//
// ROUNDING — SETTLED ON IRON (1.56.0 burn 1): v_cvt_pk_u8_f32 ROUNDS TO NEAREST; it does NOT truncate.
// The first version added +0.5 before the convert on the assumption it truncated, which double-rounded and
// came out +1 on every channel (lane 1 gave 0xFFFAFAFA for an expected 0xFFF9F9F9). No +0.5 is needed, and
// dropping it saves 4 VALU/pixel. Exact .5 inputs provably cannot occur here: t/255 = k+0.5 requires
// t = 255k + 127.5, never an integer for integer t = dst_c*ia — so round-to-nearest and the CPU reference's
// round-half-up agree on every reachable value, and the tie rule never comes into play.
//
// KERNARGS (COMPUTE_USER_DATA_0..5, USER_SGPR=6 => RSRC2 0x0C, matching the existing 3-kernarg dispatches):
//   s[0:1] = src base (premultiplied BGRA/RGBA8888)   s[2:3] = dst base   s[4:5] = out base
// One workitem per pixel; v0 = workitem id. Flat 1-D over the rect — no grid yet, that is a later bite.

// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
// warns a hand-counted RSRC word is "wrong, not slow"; deriving it from the same source that assembled the
// code removes that class of bug entirely. ieee_mode/denorm are pinned to agnos's values (0/0) — LLVM
// defaults to 1/3, and a silent float-semantics mismatch is the worst possible failure mode here.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl blend_premul
blend_premul:
    // byte offset = tid * 4
    v_lshlrev_b32   v1, 2, v0

    // src pixel -> v2 ; dst pixel -> v3
    v_mov_b32       v4, s0
    v_mov_b32       v5, s1
    v_add_co_u32    v4, vcc, v4, v1
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_load_dword v2, v[4:5], off

    v_mov_b32       v6, s2
    v_mov_b32       v7, s3
    v_add_co_u32    v6, vcc, v6, v1
    v_addc_co_u32   v7, vcc, 0, v7, vcc
    global_load_dword v3, v[6:7], off
    s_waitcnt       vmcnt(0)

    // ia = 1 - src_a/255, computed as a single FMA: v8 = src_a * (-1/255) + 1.0
    // 0xBB808081 is -1/255f. VOP3 takes no 32-bit literal on gfx9, so it is staged through an SGPR.
    v_cvt_f32_ubyte3 v8, v2
    s_mov_b32       s6, 0xBB808081
    v_fma_f32       v8, v8, s6, 1.0

    // per channel: out = src_c + dst_c * ia + 0.5, then convert+insert into its byte lane.
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

    // store to out
    v_mov_b32       v4, s4
    v_mov_b32       v5, s5
    v_add_co_u32    v4, vcc, v4, v1
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_store_dword v[4:5], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel blend_premul
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 12
    .amdhsa_next_free_sgpr 8
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
