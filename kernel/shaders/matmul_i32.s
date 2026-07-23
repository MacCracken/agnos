// matmul_i32.s — gfx90c C2g-4, THE CROWN: a real integer matmul C[8x8] = A[8x8] * B[8x8] on the shader cores.
//
//   C[i][j] = sum_{k=0..7} A[i*8+k] * B[k*8+j]        A, B, C row-major i32, 64 elements each
//
// ONE LANE PER OUTPUT ELEMENT. 64 outputs, 64 lanes, one exact wave64 in one workgroup — the decomposition
// that makes this kernel loop-free in the i/j dimensions and leaves only the K reduction as a real branch
// loop. tid decodes to i = tid>>3 and j = tid&7; the lane then walks row i of A and column j of B, so every
// lane reads a different pair of streams and no lane needs to see another lane's registers. There is no LDS
// (.amdhsa_group_segment_fixed_size 0), no cross-lane op, and no barrier: the "tile" here is the whole 8x8
// and it lives in global memory plus twelve VGPRs. That is what makes this the smallest honest matmul —
// everything above it (blocking, LDS staging, wider K) is an optimization of a kernel that already computes
// the right numbers, and the right numbers are what C2g-4 was for. It is bit-correct against the CPU
// reference in gpu_shader_dispatch5, and it is the matmul the attn11/tentib ML layers ride onto the GPU;
// gpu_dispatch_sys (ring-3 syscall #82) runs THIS SAME shader over caller-supplied A/B.
//
// ADDRESSING — the one asymmetry, and the whole point of the kernel. A is walked along a ROW and B along a
// COLUMN, but both are row-major, so their strides differ:
//     A: base offset i*32  (= i*8 elements * 4 bytes),  step +4   per k   — adjacent, one row
//     B: base offset j*4   (= j elements * 4 bytes),    step +32  per k   — a full row per k, one column
//     C: offset tid*4, written once after the loop
// This is the ONLY structural delta from its predecessor C2g-3 (the reduction-loop kernel, 38 dwords), where
// both pointers stepped +4 because each lane owned a private contiguous slice of two vectors. Change B's step
// from 4 to 32 and add the i/j decode and a dot-product kernel becomes a matmul. If B's stride is ever wrong
// the dispatch still completes and still stores 64 values — it computes a different, plausible-looking matrix.
// There is no fault to catch it, which is why the oracle is an exact CPU re-derivation of all 64 elements and
// not a spot check.
//
// REGISTER ALLOCATION (12 VGPRs, v0..v11 — the budget RSRC1 declares, with nothing to spare):
//     v0        workitem-id-X, SPI-preloaded. NEVER CLOBBERED. C2g-2's kernarg shader overwrote v0 in place
//               (`v_lshlrev_b32 v0, 2, v0`); this kernel cannot, because it needs tid THREE ways (i, j, and
//               the C offset) and the C offset is not consumed until after the loop has recycled v1/v2.
//     v9, v10   the two decoded byte offsets, i*32 and j*4. Dead after the base folds.
//     v11       tid*4, the C offset. LIVE ACROSS THE WHOLE LOOP — computed up front and touched by nothing
//               in the body. It is the reason the kernel needs 12 VGPRs rather than 11.
//     v1:v2     64-bit walking pointer into A;  v3:v4  64-bit walking pointer into B.
//     v5, v6    the two loaded operands;  v7  their product;  v8  the accumulator.
//     v1:v2 are REUSED after the loop as the C pointer. Legal only because the loop's final iteration has
//     already retired its loads under s_waitcnt vmcnt(0); the loop increments them one last time on the exit
//     iteration and that value is simply overwritten.
//
// ⚠ EXEC. The kernel's first instruction is `s_mov_b64 exec, -1`, and it is not decoration. Burns 1.54.17-19
//   showed a 64-lane wave RETIRE — fence fired, ACTIVE=1 — having stored NOTHING, because every lane was
//   EXEC-masked: C2f's 1-lane wave got a helpful SPI-auto EXEC=0x1, but the full wave came up with EXEC=0 on
//   this raw non-HWS HQD path. "The dispatch completed" is therefore never evidence that lanes ran.
//   ⚠ FORWARD-CARRY: `exec, -1` is correct ONLY for an EXACT full wave (64 threads = exactly wave64, which
//   is what GPU_MT_NUM_THREAD_X dispatches). Any future grid with a PARTIAL last wave must replace this with
//   a real lane mask (s_bfm / whole-wave-mode) or the surplus lanes perform out-of-bounds stores.
//
// THE LOOP is bottom-tested: s_sub_i32 / s_cmp_lg_i32 / s_cbranch_scc1 with the trip count in the WAVE-UNIFORM
// SGPR s6, so the branch is scalar and the whole wave takes it together — no divergence, no exec manipulation
// inside the body. Being bottom-tested it has no zero-trip guard and executes the body at least once; K is a
// compile-time 8 here (s_movk_i32 s6, 0x8), so that is safe by construction, but a K driven from a kernarg
// would need a guard ahead of the label. The backward branch is written as a LABEL; it assembles to
// s_cbranch_scc1 -17 dwords, which is the shipped 0xBF85FFEF.
//
// ⚠ `v_add_co_u32_e64` IS SPELLED EXPLICITLY on the two pointer bumps and must stay that way. The VOP2 form
//   requires its second source to be a VGPR, and `v1, vcc, v1, 4` has the CONSTANT second — so the assembler
//   is forced to the VOP3 (e64) encoding, two dwords instead of one. Writing the plain mnemonic happens to
//   select the same thing today; writing _e64 makes the two-dword footprint explicit rather than incidental,
//   and this file's contract is byte-identity with an iron-proven table.
//
// The MAC is v_mul_lo_u32 (VOP3, two dwords — there is no VOP2 form) then v_add_u32 with NO carry: the
// accumulator wraps mod 2^32, exactly as the CPU reference does when it masks & 0xFFFFFFFF. The single
// s_waitcnt vmcnt(0) covers BOTH loads jointly, which is why they are issued back to back before it. Both
// loads are re-issued every iteration and nothing is prefetched or unrolled; that is a deliberate floor, not
// an oversight — this kernel's job was correctness on iron.
//
// KERNARGS (COMPUTE_USER_DATA_0..5, USER_SGPR=6 => RSRC2 0x0C = GPU_COMPUTE_RSRC2_KERNARG3):
//     s[0:1] = A base    s[2:3] = B base    s[4:5] = C base      (s6 is the loop counter, not a kernarg)
// Dispatched by gpu_matmul_run: DISPATCH_DIRECT dim 1x1x1 with NUM_THREAD_X = 64. RSRC1 harvests to
// 0x002C0042 = GPU_COMPUTE_PGM_RSRC1_V12 (12 VGPRs / 16 SGPRs), the constant gpu.cyr already passes in —
// so this kernel adds no new RSRC constant, exactly as perm.s does not.
//
// Its f64 sibling gpu_matmul_write_shader_f64 (43 dwords) is this same structure over 8-byte elements:
// global_load/store_dwordx2 into register pairs, every stride doubled, and a separate v_mul_f64 + v_add_f64
// in place of the integer MAC.
//
// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
// — gpu_regs.cyr:1033-1035 warns that a miscounted RSRC word is "wrong, not slow". ieee_mode/denorm_32 are
// pinned to agnos's values (0/0) against LLVM's defaults of 1/3; this kernel does no float arithmetic, but a
// descriptor that disagrees with every other shader in the arena is a difference waiting to be blamed.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl matmul_i32
matmul_i32:
    // ---- unmask the wave. See the EXEC note above; this is load-bearing, not boilerplate. ----
    s_mov_b64       exec, -1

    // ---- decode tid -> (i, j) and stage the three byte offsets. v0 survives all of this. ----
    v_lshrrev_b32   v9, 3, v0              // i   = tid >> 3
    v_and_b32       v10, 7, v0             // j   = tid & 7
    v_lshlrev_b32   v9, 5, v9              // v9  = i*32  = A row base   (i*8 elements * 4 bytes)
    v_lshlrev_b32   v10, 2, v10            // v10 = j*4   = B column base
    v_lshlrev_b32   v11, 2, v0             // v11 = tid*4 = C offset, live until after the loop

    // ---- fold the offsets into the 64-bit kernarg bases. v_add_co/v_addc_co carry through vcc; the high
    // half takes an inline 0 as its addend and picks up only the carry. ----
    v_mov_b32       v1, s0
    v_mov_b32       v2, s1
    v_add_co_u32    v1, vcc, v1, v9        // A + i*32  -> &A[i][0]
    v_addc_co_u32   v2, vcc, 0, v2, vcc

    v_mov_b32       v3, s2
    v_mov_b32       v4, s3
    v_add_co_u32    v3, vcc, v3, v10       // B + j*4   -> &B[0][j]
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    v_mov_b32       v8, 0                  // acc = 0
    s_movk_i32      s6, 0x8                // K = 8, wave-uniform in an SGPR so the branch stays scalar

loop:
    // Both operands issue before the wait so one vmcnt(0) retires the pair.
    global_load_dword v5, v[1:2], off      // A[i][k]
    global_load_dword v6, v[3:4], off      // B[k][j]
    s_waitcnt       vmcnt(0)
    v_mul_lo_u32    v7, v5, v6             // VOP3 — no VOP2 form of the 32-bit low multiply exists
    v_add_u32_e32   v8, v8, v7             // acc += A*B, no carry out: wraps mod 2^32 like the CPU reference

    // Advance both pointers. The asymmetric strides ARE the matmul — see the ADDRESSING note.
    v_add_co_u32_e64 v1, vcc, v1, 4        // A: next column of the row
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    v_add_co_u32_e64 v3, vcc, v3, 32       // B: next row of the column (N*4 = a whole row)
    v_addc_co_u32   v4, vcc, 0, v4, vcc

    s_sub_i32       s6, s6, 1              // K--
    s_cmp_lg_i32    s6, 0
    s_cbranch_scc1  loop                   // assembles to -17 dwords; bottom-tested, so K >= 1 is required

    // ---- store C[i][j]. v1:v2 are recycled here — safe, the loads that owned them have retired. ----
    v_mov_b32       v1, s4
    v_mov_b32       v2, s5
    v_add_co_u32    v1, vcc, v1, v11       // C + tid*4
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    global_store_dword v[1:2], v8, off glc  // glc: push past L1 so the CPU's post-fence read sees it
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel matmul_i32
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
