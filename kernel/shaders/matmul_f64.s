// matmul_f64.s — gfx90c FULL-PRECISION 8x8 matmul on the shader cores. C[8x8] = A[8x8] * B[8x8], f64.
//
//   C[i][j] = sum_{k=0..7} A[i][k] * B[k][j]
//
// This is the integer crown (gpu_matmul_write_shader, 41 dwords) re-typed to f64: identical tiled shape,
// identical loop, identical carry-chain addressing — only the element width changes from 4 bytes to 8.
// One lane per output element, 64 outputs, 64 lanes, ONE workgroup, exactly one wave64. Three callers in
// gpu.cyr write THIS one 43-dword blob: gpu_shader_dispatch_f64 (the exact-integer boot proof),
// gpu_shader_dispatch_f64_fidelity (the rounding-data proof), and gpu_dispatch_f64_sys (the ring-3 seam).
//
// ⚠ THE MAC IS SEPARATE v_mul_f64 THEN v_add_f64 — DELIBERATELY NOT A FUSED v_fma_f64. This is the whole
//   point of the kernel and the one edit that would silently destroy it. rosnet accumulates as mul-then-add
//   (its f64v_fmadd lowers to mulpd+addpd; the scalar path is f64_add(y, f64_mul(x, W))), so it takes TWO
//   roundings per k step. A fused FMA takes ONE — it keeps the full product and rounds only at the add. On
//   exact-integer test data the two agree, which is exactly why the boot proof CANNOT tell them apart; the
//   fidelity dispatch feeds data whose products exceed 2^53 so the multiply must round, and there a
//   v_fma_f64 DIVERGES from the CPU reference in the low bits. Same k-ascending order + two roundings per
//   step is what makes this shader bit-identical to rosnet, and bit-identity is the deliverable.
//   ⚠ gpu_regs.cyr's comment above GPU_COMPUTE_PGM_RSRC1_F64 still says "v_fma_f64 MAC". That comment is
//   STALE — the shipped kernel below contains no FMA of any kind. Trust these bytes, not that line.
//
// ⚠ s_mov_b64 exec, -1 IS THE FIRST INSTRUCTION AND IT IS LOAD-BEARING. On this raw non-HWS HQD path the
//   full 64-lane wave arrives with EXEC = 0: burns 1.54.17-19 saw the wave RETIRE (done fired, ACTIVE=1)
//   having stored NOTHING, because every lane was masked off. C2f's single-lane wave got a SPI-auto
//   EXEC = 0x1 and stored, which is what made the full-wave case look like a store bug rather than a mask
//   bug. The explicit set is what lights all 64. It is correct ONLY because 64 is an EXACT wave64 for this
//   fixed 8x8 problem — a grid with a partial last wave must use a real lane mask (s_bfm /
//   s_and_saveexec_b64, as blend_rect.s and its siblings do) or the surplus lanes issue OOB stores.
//
// ADDRESSING. tid = v0 (workitem id X, 0..63) -> i = tid>>3, j = tid&7. Every stride is the integer
// kernel's doubled, because an element is 8 bytes now:
//   A row base  = i * 64   (8 doubles per row)      A step per k = +8    (walk the row)
//   B col base  = j * 8                              B step per k = +64   (walk DOWN the column)
//   C element   = tid * 8
// The kernarg bases are SCALAR (s[0:1], s[2:3], s[4:5]) but each lane needs its own address, so the base is
// splatted into a VGPR pair with v_mov_b32 and the per-lane offset folded in with the
// v_add_co_u32 / v_addc_co_u32 carry chain. That pair, not the SGPR pair, is what global_* addresses
// through — the carry-in half (v_addc_co_u32 ..., 0, hi, vcc) is not decoration, it is what makes a
// carry out of the low dword reach the high half of a 64-bit MC address.
//
// REGISTER ALLOCATION — where the 16-VGPR count actually comes from:
//   v0        workitem id                  v1:v2   A pointer, then reused as the C pointer after the loop
//   v3:v4     B pointer                    v5,v6   i*64, j*8 (dead after the bases are formed)
//   v7        tid*8, the C offset — computed BEFORE the loop and held across it, which is why it survives
//             in its own register instead of being recomputed
//   v8:v9     A[i][k]                      v10:v11 B[k][j]
//   v12:v13   the f64 accumulator, zeroed as two v_mov_b32 (0.0 is all-zero bits, so no f64 constant
//             is needed and no literal dword is spent)
//   v14:v15   THE PRODUCT TEMP — the separate mul needs somewhere to land, and that pair is the entire
//             reason this kernel declares 16 VGPRs where the integer crown declares 12. A fused FMA would
//             not need it; the fidelity requirement buys the register.
// s0..s5 are the three 64-bit kernargs, s6 is the loop counter, vcc carries the address chain.
// ⚠ RSRC1's VGPR field MUST be 3 (16 VGPRs). Field 2 (12 VGPRs) does not fault — it under-allocates and
//   corrupts the v[12:13] accumulator, i.e. wrong numbers out of a dispatch that reports success.
//
// LOOP. s6 = K = 8, counted down; s_sub_i32 / s_cmp_lg_i32 / s_cbranch_scc1 back to `loop`. Both loads are
// issued back to back and ONE s_waitcnt vmcnt(0) covers both — they are independent, so serialising them
// with two waits would only cost latency. The branch is written as a LABEL here; it assembles to the raw
// -18-dword displacement (0xBF85FFEE) that the shipped table carries, and that equality is checked by
// the shipped table (that displacement is part of the committed hex, which is the source of truth).
//
// KERNARGS (COMPUTE_USER_DATA_0..5, USER_SGPR=6 => RSRC2 0x0C = GPU_COMPUTE_RSRC2_KERNARG3):
//   s[0:1] = A base   s[2:3] = B base   s[4:5] = C base — each 64 doubles / 512 bytes, row-major.
// The final store is `glc`, matching the integer crown: the CPU polls C out of the carveout immediately
// after the dispatch retires, so the write must not sit in a non-coherent cache.
//
// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
// hand-counted — gpu_regs.cyr:1033-1035 warns a miscounted RSRC word is "wrong, not slow". Harvested here:
// RSRC1 = 0x002C0043 (== GPU_COMPUTE_PGM_RSRC1_F64) and RSRC2 = 0x0000000C (== GPU_COMPUTE_RSRC2_KERNARG3),
// both matching the constants gpu.cyr already dispatches with. ieee_mode/denorm_32 are pinned to agnos's
// values (0/0) against LLVM's defaults of 1/3; denorm_16_64 stays 3, which is the mode this kernel's f64
// arithmetic actually runs under, and FLOAT_MODE 0xC0 is that pairing.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl matmul_f64
matmul_f64:
    // Every lane live. See the EXEC note above — exact-wave64 only.
    s_mov_b64       exec, -1

    // tid -> (i, j) and the three byte offsets. All three are f64-scaled: i*64, j*8, tid*8.
    v_lshrrev_b32   v5, 3, v0              // i   = tid >> 3
    v_and_b32       v6, 7, v0              // j   = tid & 7
    v_lshlrev_b32   v5, 6, v5              // v5  = i * 64   (A row offset, 8 doubles per row)
    v_lshlrev_b32   v6, 3, v6              // v6  = j * 8    (B column offset)
    v_lshlrev_b32   v7, 3, v0              // v7  = tid * 8  (C offset — held live across the whole loop)

    // A pointer: v[1:2] = s[0:1] + i*64
    v_mov_b32       v1, s0
    v_mov_b32       v2, s1
    v_add_co_u32    v1, vcc, v1, v5
    v_addc_co_u32   v2, vcc, 0, v2, vcc

    // B pointer: v[3:4] = s[2:3] + j*8
    v_mov_b32       v3, s2
    v_mov_b32       v4, s3
    v_add_co_u32    v3, vcc, v3, v6
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    // acc = 0.0 — the f64 zero is all-zero bits, so two plain v_mov_b32 do it with no literal dword.
    v_mov_b32       v12, 0
    v_mov_b32       v13, 0

    s_movk_i32      s6, 8                  // K = 8, counted down
loop:
    global_load_dwordx2 v[8:9],   v[1:2], off   // A[i][k]
    global_load_dwordx2 v[10:11], v[3:4], off   // B[k][j]
    s_waitcnt       vmcnt(0)                    // one wait covers both — the loads are independent

    // THE MAC. Two instructions, two roundings, matching rosnet's f64_mul then f64_add. Not an FMA.
    v_mul_f64       v[14:15], v[8:9],   v[10:11]    // prod = A[i][k] * B[k][j]   (rounding 1)
    v_add_f64       v[12:13], v[12:13], v[14:15]    // acc += prod                (rounding 2)

    // Advance both pointers. The +8 / +64 land in src1, which VOP2 reserves for a VGPR, so the assembler
    // takes the VOP3 (e64) encoding here while the v5/v6 folds above stayed VOP2 — that asymmetry is in
    // the shipped bytes and is not a transcription slip.
    v_add_co_u32    v1, vcc, v1, 8         // A += 8   — next column of the row
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    v_add_co_u32    v3, vcc, v3, 64        // B += 64  — next ROW, i.e. down the column (N * 8)
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    s_sub_i32       s6, s6, 1
    s_cmp_lg_i32    s6, 0
    s_cbranch_scc1  loop                   // assembles to -18 dwords (0xBF85FFEE)

    // C pointer: v[1:2] = s[4:5] + tid*8. v1/v2 are recycled from the A pointer, which is dead now.
    v_mov_b32       v1, s4
    v_mov_b32       v2, s5
    v_add_co_u32    v1, vcc, v1, v7
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    global_store_dwordx2 v[1:2], v[12:13], off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel matmul_f64
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 16
    .amdhsa_next_free_sgpr 7
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
