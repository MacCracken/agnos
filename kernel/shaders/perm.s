// perm.s — gfx90c v_perm_b32 BYTE CROSSBAR: the unpack/repack identity, and the one-instruction channel swap.
//
// TWO PROOFS, ONE KERNEL, ONE DISPATCH. Plan bite S4(i) is the unpack->repack identity with the three fixed
// selectors 0x0c010c00 / 0x0c030c02 / 0x06040200; S4(ii) is the RGBX<->BGRX permutation, selector 0x03000102 —
// the PER-SURFACE channel swap that the DCN HUBP crossbar (bite D1) structurally cannot do, because that
// crossbar is a property of the whole scanout, not of one composited client surface. This arc opened by
// calling that "an unhandled case, not just a slow one", and this file is the first v_perm_b32 in the tree.
//
// The two proofs share a source pixel and NOTHING ELSE. They are written to separate output slots rather than
// composed into one chain, so that a failure in one cannot explain a failure in the other — that separation
// IS the isolation test. Composing them would give exactly one bit of information for two hypotheses.
//
// WHY THIS INSTRUCTION AT ALL. v_perm_b32 is a full byte crossbar: it takes two source dwords, treats them as
// an eight-byte pool, and builds the destination dword by picking ANY pool byte (or a constant 0x00 / 0xFF)
// independently per destination byte — in one VALU op. Nothing else on GFX9 does this. The shift/mask
// equivalent of the R<->B swap is five instructions (two shifts, two ands, one or) plus a staged mask;
// v_perm_b32 is one instruction plus one s_mov_b32 that is hoisted out of any loop.
//
// ⚠ THE POOL IS BACKWARDS FROM THE WRITTEN OPERAND ORDER — the single trap in this instruction. For
//   `v_perm_b32 D, S0, S1, S2`:
//       pool[0..3] = S1 bytes 0..3     <- S1, the SECOND written operand, is the LOW dword of the pool
//       pool[4..7] = S0 bytes 0..3     <- S0, the FIRST written operand, is the HIGH dword
//   So a SINGLE-SOURCE permutation must put the pixel in S1 and an inline 0 in S0. Putting the pixel in S0
//   neither faults nor produces zeros on hardware: it permutes whatever stale value the other VGPR happens to
//   hold, which reads as "the shader is broken" rather than "the operands are swapped" — the most expensive
//   possible misdiagnosis. This ordering was derived from LLVM (its `llvm.amdgcn.perm` folding, cross-checked
//   against the v_perm_b32 that ISel emits for llvm.bswap.i32), not read off a table, because a wrong
//   selector produces a wrong PICTURE and never an exception.
//
//   Selector byte k drives destination byte k, LSB to LSB, so a selector written as hex reads
//   destination-MSB-first: 0x03000102 means D.b3<-pool[3], D.b2<-pool[0], D.b1<-pool[1], D.b0<-pool[2].
//   Values 0..7 index the pool; 8..11 sign-replicate the pool's four u16 lanes to 0x00/0xFF; 12 is a constant
//   0x00; anything >= 13 is a constant 0xFF. Only 12 is used here, as the zero-fill in the unpack.
//
// ⚠ VOP3 TAKES NO 32-BIT LITERAL ON GFX9. v_perm_b32 is VOP3A (opcode 0xD1ED), so
//   `v_perm_b32 v8, 0, v2, 0x03000102` is REJECTED BY THE ASSEMBLER — this class of bug fails at build time,
//   not on iron, which is the one mercy here. Every selector must arrive in an SGPR. The three fixed ones are
//   staged with s_mov_b32 below; the host-driven one needs no staging because it is ALREADY an SGPR — it is a
// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
//   `v_perm_b32 v8, 0, v2, s4` is [0x08,0x00,0xed,0xd1,0x80,0x04,0x12,0x00], src2 field = 4 = s4).
//   The gfx9 constant bus allows ONE distinct SGPR across all three sources and inline constants are free,
//   which is why the single-source form is `v_perm_b32 D, 0, v2, s4` — a second SGPR in any slot would be
//   "violates constant bus restrictions", again at build time.
//
// ⚠ S4(iii) — the VOP3P packed blend — IS NOT IN THIS FILE. It is a different kernel with a different oracle,
//   and since D-2 it must target the PREMULTIPLIED f32 formula that blend_premul.s actually ships, not the
//   straight-alpha integer form the plan row assumed. The unpack/repack proven here is its prerequisite, and
//   that is the only coupling.
//
// KERNARGS (USER_SGPR=6 => RSRC2 0x0C = GPU_COMPUTE_RSRC2_KERNARG3, byte-identical to blend_premul's):
//   s[0:1] = src base — 64 arbitrary pixels, one per lane
//   s[2:3] = out base — FOUR dwords per pixel, 64 * 16 = 1024 bytes. Must be 16-byte aligned; the arena
//            sub-offsets are, and global_store_dwordx4 is the only reason it matters.
//   s[4:5] = the third 64-bit kernarg slot; only s4, its LOW dword, is read. s4 = THE SELECTOR.
//            0x03020100 = identity (D.bk <- pool[k]) — the control run, out must equal in on every slot.
//            0x03000102 = RGBX<->BGRX — swaps bytes 0 and 2, leaves 1 and 3 alone.
// One workitem per pixel; v0 = workitem id; one workgroup of 64, flat 1-D, no grid — exactly blend_premul's
// shape. This rides gpu_matmul_run UNCHANGED and does NOT need gpu_grid7_run: that emitter passes three
// opaque 64-bit values into USER_DATA_0..5 and dispatches (1,1,1), so the call is
// gpu_matmul_run(shader_mc, src_mc, out_mc, selector, done_mc, done_phys, GPU_COMPUTE_PGM_RSRC1_V12) —
// the third "pointer" slot carries the selector, with the host passing a zero high half. RSRC1 is also
// THIS kernel, so it adds no new RSRC constant.
// ⚠ THAT IS TRUE OF perm ONLY. Its sibling blend_pk.s harvests 0x002C0082 (24 SGPRs) and MUST NOT reuse
// V12 — 16 SGPRs under-allocates it, which corrupts the VCC carry chain rather than merely slowing it.
// The two files are meant to be read together and this is the one place where copying between them is
// wrong, so it is flagged in both.
// The plan's 4096 pixels are 64 such dispatches with both base pointers advanced by the host (+256 / +1024).
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl perm
perm:
    // ---- source pixel ----
    v_lshlrev_b32   v1, 2, v0
    v_mov_b32       v3, s0
    v_mov_b32       v4, s1
    v_add_co_u32    v3, vcc, v3, v1
    v_addc_co_u32   v4, vcc, 0, v4, vcc
    global_load_dword v2, v[3:4], off

    // ---- destination: 4 dwords per pixel, so the byte offset is tid * 16, not tid * 4 ----
    v_lshlrev_b32   v7, 4, v0
    v_mov_b32       v5, s2
    v_mov_b32       v6, s3
    v_add_co_u32    v5, vcc, v5, v7
    v_addc_co_u32   v6, vcc, 0, v6, vcc

    // ---- the three FIXED selectors, staged into SGPRs while the load is in flight ----
    // These cannot be immediates (see the VOP3 note above) and they are wave-uniform, so SALU is where they
    // belong; all three s_mov_b32 issue under the vmcnt shadow of the load above and cost nothing.
    s_mov_b32       s6, 0x0c010c00         // unpack bytes {0,1} of S1 into the two u16 lanes, 12 = zero-fill
    s_mov_b32       s7, 0x0c030c02         // unpack bytes {2,3} of S1 into the two u16 lanes
    s_mov_b32       s8, 0x06040200         // repack {S1.b0, S1.b2, S0.b0, S0.b2} -> {c0,c1,c2,c3}
    s_waitcnt       vmcnt(0)

    // ---- SLOT 0 (out+0): S4(ii). The host's selector applied ONCE, straight to the source pixel.
    // Compared against a CPU byte-shuffle. The pixel is S1 and S0 is an inline 0 — see the pool note.
    v_perm_b32      v8, 0, v2, s4

    // ---- SLOT 1 (out+4): the same selector applied a SECOND time to the first result.
    // Both selectors the burn drives are INVOLUTIONS (identity trivially; 0x03000102 swaps b0<->b2, and a
    // transposition is its own inverse), so this slot must equal the source pixel with no CPU model in the
    // loop at all — a self-checking oracle that survives a wrong CPU reference. ⚠ That property belongs to
    // the SELECTOR, not the instruction: a host driving a rotate (e.g. 0x02010003) must compare this slot
    // against a double-shuffle instead, or it will read a correct GPU as broken.
    v_perm_b32      v9, 0, v8, s4

    // ---- SLOT 2 (out+8): S4(i). Unpack to two u16-lane pairs, then repack. Must equal the source pixel.
    // v3/v4 held the source ADDRESS and are recycled as the lane-pair temps; that is only legal after the
    // s_waitcnt vmcnt(0) above, because the load still owns them until it retires.
    v_perm_b32      v3, 0, v2, s6          // v3 = {0, b1, 0, b0} -> u16 lanes (b0, b1)  == channels 0,1
    v_perm_b32      v4, 0, v2, s7          // v4 = {0, b3, 0, b2} -> u16 lanes (b2, b3)  == channels 2,3
    // ⚠ OPERAND ORDER IS LOAD-BEARING HERE and this is the ONE perm in the file with a real ordering
    // constraint. 0x06040200 reads pool[0],pool[2],pool[4],pool[6] = S1.b0, S1.b2, S0.b0, S0.b2 — so the HIGH
    // lane-pair must be S0 (written first) and the LOW pair S1 (written second). Swapping them does not fault:
    // it rotates the channels by two and yields a plausible-looking image with the colours wrong, the worst
    // failure mode available in a burn that is graded partly by photograph.
    v_perm_b32      v10, v4, v3, s8
    // The repack keeps only the LOW byte of each u16 lane — it truncates, there is no clamp. Harmless here
    // because the unpack produced lanes <= 0xFF by construction, but it is the constraint that will order the
    // instructions in S4(iii): the repack must follow the final v_pk_lshrrev_b16, never precede it.

    // ---- SLOT 3 (out+12): the source pixel as this lane actually read it.
    // Not a tautology and not an echo of our own write: it is a second buffer reached through the load path,
    // so it separates "the permutation is wrong" from "the lane addressed the wrong pixel", and it doubles as
    // the lanes-stored witness. A dispatch can retire having written nothing if every lane was EXEC-masked —
    // that is precisely what happened at 1.54.17-19 — so "the dispatch completed" is never evidence.
    v_mov_b32       v11, v2

    global_store_dwordx4 v[5:6], v[8:11], off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
// — gpu_regs.cyr:1033-1035 warns that a miscounted RSRC word is "wrong, not slow". v0..v11 and s0..s8 are
// agnos's values (0/0) against LLVM's defaults of 1/3; no float arithmetic happens in this kernel, but a
// descriptor that disagrees with every other shader in the arena is a difference waiting to be blamed.
.amdhsa_kernel perm
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 12
    .amdhsa_next_free_sgpr 9
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
