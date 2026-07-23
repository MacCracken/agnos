// matmul_dot.s — gfx90c ALU + REDUCTION LOOP: the per-lane integer dot product, on a REAL branch loop.
//
//   out[tid] = sum_{k=0..K-1} a[tid*K + k] * b[tid*K + k]      K = 4
//
// This is agnos GPU arc bite C2g-3, the last primitive before the matmul crown (C2g-4). Every dispatch
// before it was straight-line: C2g-1 stored a constant, C2g-2 read one operand per lane through a kernarg
// pointer and wrote it back. This one is the first shader in the tree that BRANCHES — s_cmp_lg_i32 +
// s_cbranch_scc1 around a body that loads, multiplies, accumulates, and advances two pointers. Once a
// backward branch and a multiply-accumulate are both proven on iron, C2g-4's 8x8 matmul is the same loop
// with a different address walk, and the ML layers (attn11/tentib) have a GPU to ride onto.
//
// WHY THIS SHAPE AND NOT A CROSS-LANE REDUCTION. "Reduction" here is serial and PRIVATE to each lane: lane
// tid owns the whole K-element dot product and accumulates it in one VGPR (v8). No DPP, no permlane, no LDS,
// no cross-lane traffic of any kind. That is deliberate — the bite is proving the LOOP and the MAC, and a
// cross-lane reduction would fold a second unproven mechanism into the same oracle. Each of the 64 lanes is
// an independent, separately-checkable dot product, so a partial failure names the lanes that failed instead
// of collapsing to one "the reduction is wrong" bit. The host verifies all 64 against a CPU model.
//
// THE LOOP IS SCALAR-UNIFORM, WHICH IS THE ONLY REASON s_cbranch IS LEGAL HERE. The trip count lives in an
// SGPR (s6) and is the same for every lane, so the compare is SALU, the branch is scalar, and all 64 lanes
// take it together. There is no divergence and therefore no exec-mask manipulation inside the loop. A
// data-dependent trip count would need exec save/restore and would NOT be this kernel.
//
// ⚠ s_mov_b64 exec, -1 MUST BE THE FIRST INSTRUCTION. On this raw non-HWS HQD path the SPI hands the wave
//   exec = 0; without this the shader retires having stored nothing and the dispatch still "completes",
//   which reads as a memory or addressing bug rather than a masking one. (This is why the host oracle checks
//   64 dot-product VALUES and never "the dispatch finished".) exec = -1 is correct ONLY for an exact 64-lane
//   wave, which is what this dispatch is: one workgroup, NUM_THREAD_X = 64, DIM 1x1x1, no grid. A surplus
//   lane under a partial wave would store somewhere real in the carveout, since paging is off.
//
// ⚠ K IS ENCODED TWICE and the two encodings are not adjacent. Once as the trip count (s_movk_i32 s6, 4) and
//   once inside the slice stride (v_lshlrev_b32 v9, 4, v0 — tid * K * 4 bytes = tid << 4 only because K = 4).
//   Changing K means changing BOTH; changing only the trip count silently reads the wrong lane's operands
//   instead of faulting, because every address stays inside the same seeded buffer.
//
// ⚠ v1:v2 AND v3:v4 ARE DESTROYED BY THE LOOP. They are the a/b cursors and the body advances each by 4
//   bytes per iteration, so after K iterations neither holds anything the epilogue can use. The output
//   address is therefore rebuilt from scratch after the loop out of s[4:5], and the byte offset it needs
//   (tid * 4) is computed in the PROLOGUE into v10 and held live across the whole loop — v10 is the one
//   VGPR the body must not touch. Recomputing it after the loop would work too; keeping it in a register the
//   loop does not name makes the constraint visible at the point where it could be broken.
//
// ADDRESSING. Two separate strides, and they differ: the a/b slices are K dwords per lane (tid * 16, v9),
// the output is one dword per lane (tid * 4, v10). 64-bit pointer arithmetic is the usual
// v_add_co_u32 / v_addc_co_u32 carry pair against vcc; the in-loop +4 bumps use the same pair.
//
// ⚠ BYTE-IDENTITY TRAP IN THE IN-LOOP BUMP. `v_add_co_u32_e64 v1, vcc, v1, 4` is TWO dwords (VOP3): VOP2
// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
//   automatically, the _e64 suffix here is documentation, not coercion. Writing the commuted, mathematically
//   identical `v_add_co_u32 v1, vcc, 4, v1` collapses to ONE dword of VOP2 and changes both the instruction
//   bytes and the branch displacement. The shipped table is 38 dwords with a -17 dword branch; the commuted
//   form would be 36 with -15. Same arithmetic, different ISA — and this file's only job is the ISA.
//   For the same reason the trip count is s_movk_i32 (0xB0060004) and not s_mov_b32 (0xBE860084): both are
//   one dword and both put 4 in s6, but they are different encodings and only one is what iron ran.
//
// ⚠ THE BRANCH DISPLACEMENT IS WRITTEN AS A LABEL. The shipped dword is 0xBF85FFEF and disassembles as
//   `s_cbranch_scc1 65519` — 65519 is the raw u16 field, i.e. -17 as a signed dword displacement from the
//   instruction AFTER the branch. `dot_loop` is placed on the first global_load so the reassembled field
//   comes out 0xFFEF exactly; a label one instruction off would still assemble and still run, just wrong.
//
// v_mul_lo_u32 is the full 32-bit low product (VOP3, two dwords) followed by a separate v_add_u32.
// v_mad_u32_u24 would fuse the two, but its operands are 24-bit and the seeded values are not bounded to
// 24 bits by anything in the host, so the fused form is not a drop-in here.
//
// KERNARGS (COMPUTE_USER_DATA_0..5, USER_SGPR = 6 => RSRC2 0x0C = GPU_COMPUTE_RSRC2_KERNARG3):
//   s[0:1] = a base — 256 dwords, host-seeded a[i] = i + 1
//   s[2:3] = b base — 256 dwords, host-seeded b[i] = i + 2
//   s[4:5] = out base — 64 dwords, one dot product per lane
//   s6     = NOT a kernarg. The loop counter, clobbered. USER_SGPR = 6 preloads s0..s5 only, so s6 is the
//            first SGPR this shader is free to use, and next_free_sgpr is 7 for that reason.
//
// REGISTERS: v0 = workitem id (SPI-supplied) · v9 = tid*16 (a/b slice byte offset) · v10 = tid*4 (out byte
// offset, LIVE ACROSS THE LOOP) · v1:v2 = a cursor · v3:v4 = b cursor · v5 = a[k] · v6 = b[k] · v7 = product
// which is exactly GPU_COMPUTE_PGM_RSRC1_V12 — the VGPR granule is 4 on gfx9, so 11 and 12 encode the same
// RSRC1 and 12 is written to match the constant's name.
//
// — gpu_regs.cyr:1033-1035 warns that a miscounted RSRC word is "wrong, not slow", and there is no QEMU path
// for any of kernel/core/gpu.cyr, so a bad word fails as a burn on the operator's only dev machine.
// ieee_mode/denorm_32 are pinned to agnos's values (0/0) against LLVM's defaults of 1/3. This kernel does no
// float arithmetic, but a descriptor that disagrees with every other shader in the arena is a difference
// waiting to be blamed for something else.
//
// PROVENANCE: this file is a RECONSTRUCTION. The 38 dwords were hand-typed into gpu_shader_dispatch4 in
// reassemble byte-identically to that shipped table; the committed hex remains the iron-proven authority.
// Byte-identity is the whole deliverable — nothing here may be "improved".
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl matmul_dot
matmul_dot:
    // ---- exec first, before anything can be masked away. See the note above. ----
    s_mov_b64       exec, -1

    // ---- byte offsets. Two strides: K dwords per lane in / one dword per lane out. ----
    v_lshlrev_b32   v9, 4, v0              // v9  = tid * 16 = tid * K * 4  (a/b slice)
    v_lshlrev_b32   v10, 2, v0             // v10 = tid * 4                 (out slot; LIVE ACROSS THE LOOP)

    // ---- a cursor = a + slice ----
    v_mov_b32       v1, s0
    v_mov_b32       v2, s1
    v_add_co_u32    v1, vcc, v1, v9
    v_addc_co_u32   v2, vcc, 0, v2, vcc

    // ---- b cursor = b + slice ----
    v_mov_b32       v3, s2
    v_mov_b32       v4, s3
    v_add_co_u32    v3, vcc, v3, v9
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    // ---- accumulator and trip count. s6 is uniform, so the whole loop is scalar-controlled. ----
    v_mov_b32       v8, 0                  // acc = 0
    s_movk_i32      s6, 0x4                // K   = 4   (see the "K is encoded twice" note)

dot_loop:
    // Both operand loads issue back to back so the second is in flight under the first's latency; one
    // s_waitcnt covers both. The loop is not software-pipelined — the wait is inside the body, and every
    // iteration pays a full round trip. That is correct-and-simple on purpose: this bite proves the loop
    // exists, not that it is fast.
    global_load_dword v5, v[1:2], off      // a[k]
    global_load_dword v6, v[3:4], off      // b[k]
    s_waitcnt       vmcnt(0)

    v_mul_lo_u32    v7, v5, v6             // full 32-bit low product
    v_add_u32       v8, v8, v7             // acc += a[k]*b[k]   (no carry-out wanted, so plain v_add_u32)

    // advance both cursors by one dword. VOP3 by necessity — do not commute these operands.
    v_add_co_u32_e64 v1, vcc, v1, 4
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    v_add_co_u32_e64 v3, vcc, v3, 4
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    s_sub_i32       s6, s6, 1
    s_cmp_lg_i32    s6, 0
    s_cbranch_scc1  dot_loop               // shipped as 0xBF85FFEF = -17 dwords; the label must land here

    // ---- epilogue: rebuild the output address. v1:v2 was walked forward by the loop and is dead. ----
    v_mov_b32       v1, s4
    v_mov_b32       v2, s5
    v_add_co_u32    v1, vcc, v1, v10
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    global_store_dword v[1:2], v8, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel matmul_dot
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 12
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
