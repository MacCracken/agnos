// matmul_copy.s — gfx90c COMPUTE KERNARGS: read a per-lane operand through a pointer the host handed us.
//
//   out[tid] = in[tid]
//
// This is agnos GPU-arc bite C2g-2, and it is the last primitive before a real matmul. It is a copy loop
// only in the sense that a wire is a circuit: the DATA movement is trivial on purpose, so that the one
// thing under test is unambiguous — that a shader can take a BASE POINTER it never saw at assembly time,
// add its own lane offset to it, and both READ and WRITE through it. Every dispatch before this one either
// wrote a constant or baked its output address into the instruction stream as a literal (C2g-1). A matmul
// cannot do that: its operands live wherever the host allocated them. So this kernel proves the addressing
// mechanism in isolation, with the arithmetic removed, because a failure here and a failure in a matmul's
// inner product look identical in memory and only one of them is cheap to debug.
//
// KERNARGS — VIA USER_DATA, NOT VIA THE KERNARG SEGMENT. gpu_shader_dispatch3 sets
// RSRC2 = GPU_COMPUTE_RSRC2_KERNARG = 0x08 (USER_SGPR = 4), which makes the SPI preload
// COMPUTE_USER_DATA_0..3 straight into s0..s3 before the first instruction issues:
//   s[0:1] = input base   (arena + GPU_KERNARG_IN_SUBOFF  = +0x18000, 64 dwords, seeded in[i] = i*7+1)
//   s[2:3] = output base  (arena + GPU_KERNARG_OUT_SUBOFF = +0x18400, 64 dwords, pre-set to GPU_MT_NOTYET)
// There is no kernarg-segment pointer and no s_load_dwordx2 — the pointers ARE the user SGPRs. That is why
// .amdhsa_user_sgpr_kernarg_segment_ptr is 0 below; turning it on would shift s0..s3 and silently make
// every lane address garbage. The host is the only party that knows these addresses, and it passes them
// as two opaque 64-bit values, which is exactly the shape the matmul emitter later reuses for A/B/C.
//
// ⚠ THE SEED PATTERN IS NOT DECORATION. in[i] = i*7+1 is distinct from GPU_MT_NOTYET and distinct per lane,
//   so the readback separates three outcomes that a zero-fill would collapse into one: the lane wrote the
//   right value; the lane wrote SOMETHING but read the wrong address (wrong i, plausible-looking); the lane
//   never ran at all (still NOTYET). "The dispatch completed" is never evidence — see the EXEC note.
//
// ⚠ EXEC IS NOT ASSUMED. `s_mov_b64 exec, -1` is the first instruction and it is load-bearing, not
//   boilerplate. A dispatch whose lanes are all EXEC-masked retires cleanly, sets its completion fence, and
//   writes NOTHING — the 1.54.17-19 failure — so an un-forced EXEC turns "the shader is wrong" into "the
//   shader never executed" with no way to tell them apart from the memory image. The workgroup is exactly
//   64 threads (GPU_MT_NUM_THREAD_X = 64, DIM 1x1x1), i.e. exactly one full wave, so unmasking all 64 lanes
//   is correct here and ONLY here: a partial final wave under a -1 EXEC would run lanes past the end of the
//   buffer. Any grid that is not a multiple of 64 must bound the tail, not copy this line.
//
// ⚠ v0 IS DESTROYED IN PLACE. `v_lshlrev_b32 v0, 2, v0` overwrites the workitem id with the BYTE offset
//   (tid * 4, dwords). Nothing downstream can recover the raw tid — which is fine because nothing needs it,
//   and it is what keeps this kernel inside 4 VGPRs. blend_premul.s and perm.s deliberately do the opposite
//   (v1 <- v0 << 2, tid preserved) because they index two differently-strided buffers; do not copy the
//   in-place form into a kernel that still needs the id.
//
// ⚠ v1/v2 CARRY TWO DIFFERENT ADDRESSES. They hold the 64-bit INPUT address for the load, and are then
//   rebuilt from s[2:3] as the OUTPUT address for the store. That reuse is legal only because the
//   `s_waitcnt vmcnt(0)` sits between them: until the load retires it still owns its address registers, and
//   clobbering them early does not fault — it issues the load against a half-written address, which reads
//   as data corruption rather than as an ordering bug.
//
// ADDRESSING. Each address is a full 64-bit add: `v_add_co_u32` produces the low half plus a carry in VCC,
// and `v_addc_co_u32 vhi, vcc, 0, vhi, vcc` folds that carry into the high half. The offset is unsigned and
// small, but the base is a real 48-bit MC address, so the carry path is not optional — dropping it works
// for every buffer that happens not to straddle a 4 GiB boundary and then does not.
//
// The store carries `glc`. The host reads the result through the same coherent path the ring's
// post-dispatch TC-writeback ACQUIRE_MEM establishes; a non-coherent store would leave the result sitting
// in L1 where the CPU cannot see it, presenting as "the shader never wrote".
//
// WEDGE ENVELOPE: bounded. A bad per-lane address faults into the 0x1FFC dummy net, which the caller reads
// back as VM_L2_PROT_FAULT_STATUS != 0 — a reported failure, not a hang. This bite is gated on C2g-1
// (gpu_mt_ok == 1), so parallel execution is already proven before pointer indirection is introduced; that
// ordering is what makes a failure here attributable to the pointers.
//
// Straight-line, 17 dwords, no branches and no loop — one lane, one element, one round trip.
//
// DESCRIPTOR / RSRC HARVEST (llvm-mc -mcpu=gfx90c, scripts/gfx9-asm.sh):
//   RSRC1 = 0x002C0040   == GPU_COMPUTE_PGM_RSRC1_MIN (gpu_regs.cyr:994), which is what
//                           gpu_shader_dispatch3 actually programs (gpu.cyr:4021). VGPRS field 0 = 4 VGPRs,
//                           and v0..v3 is exactly what this kernel allocates.
//   RSRC2 = 0x00000008   == GPU_COMPUTE_RSRC2_KERNARG (gpu_regs.cyr:1043), USER_SGPR = 4.
// ⚠ NOT V12. GPU_COMPUTE_PGM_RSRC1_V12 = 0x002C0042 is a DIFFERENT constant, belonging to the later
//   12-VGPR kernels that ride gpu_matmul_run (blend_premul, perm, the f64 matmuls). Setting
//   .amdhsa_next_free_vgpr 12 here does harvest 0x002C0042 — the .text is byte-identical either way, since
//   the descriptor is not embedded — but it would then disagree with the RSRC1 word this shader is
//   dispatched with on iron, which is the one number the descriptor exists to keep honest. The count is 4.
//   (The SGPR field is pinned at 1 = 16 SGPRs for any .amdhsa_next_free_sgpr from 4 to 9 on this target, so
//   only the VGPR count is a live choice.)
//
// The .amdhsa_kernel block exists so llvm-mc COMPUTES RSRC1/RSRC2 instead of anyone hand-counting them;
// gpu_regs.cyr:1033-1035 warns that a miscounted RSRC word is "wrong, not slow". ieee_mode and
// float_denorm_mode_32 are pinned to agnos's values (0/0) against LLVM's defaults of 1/3 — this kernel does
// no float arithmetic at all, but a descriptor that disagrees with every other shader in the arena is a
// difference waiting to be blamed for something else.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl matmul_copy
matmul_copy:
    // Force the full wave live. Exactly 64 threads dispatched; see the EXEC note above.
    s_mov_b64       exec, -1

    // v0 = tid * 4 — the byte offset, shared by both buffers (both are dword arrays, same stride).
    v_lshlrev_b32   v0, 2, v0

    // ---- read in[tid] through the host-supplied input pointer s[0:1] ----
    v_mov_b32       v1, s0
    v_mov_b32       v2, s1
    v_add_co_u32    v1, vcc, v1, v0
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    global_load_dword v3, v[1:2], off
    s_waitcnt       vmcnt(0)                // v3 is the operand AND v1/v2 are free to rebuild — both.

    // ---- write it back through the host-supplied output pointer s[2:3] ----
    v_mov_b32       v1, s2
    v_mov_b32       v2, s3
    v_add_co_u32    v1, vcc, v1, v0
    v_addc_co_u32   v2, vcc, 0, v2, vcc
    global_store_dword v[1:2], v3, off glc
    s_waitcnt       vmcnt(0)                // retire the store before s_endpgm; the fence is the oracle.
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel matmul_copy
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 16
    .amdhsa_user_sgpr_count 4
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 4
    .amdhsa_next_free_sgpr 4
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
