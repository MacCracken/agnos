// blend_pk.s — gfx90c src-over alpha blend, PREMULTIPLIED, INTEGER VOP3P packed-u16.
//
// S4(iii): the packed re-expression of the shipped f32 kernel (blend_premul.s). Same kernargs, same
// dispatch shape, same input pixels — so the two can be run back-to-back on the SAME buffers and
// diffed. The claim under test is BIT-IDENTITY, not "close enough": out == blend_premul's out on
// every pixel. That is provable, not hopeful — see EXACTNESS below.
//
//   f32 kernel (shipped):  out_c = src_c + dst_c * (1 - src_a/255)      rounded by v_cvt_pk_u8_f32
//   this kernel:           ia = 255 - src_a                             exact integer, no 1/255
//                          n  = dst_c * ia                              <= 65025
//                          m  = n + 128                                 <= 65153  (folded into the mad)
//                          q  = (m + (m >> 8)) >> 8    == round(n/255)  max intermediate 65407
//                          out_c = src_c + q                            <= 255
//
// WHY +128 AND NOT +127. Five div-255 candidates were checked exhaustively over every n in [0,65025]:
//     m=n+127; q=(m+1+(m>>8))>>8    0 fail   max 65407   (correct, but costs one extra add)
//     m=n+128; q=(m  +(m>>8))>>8    0 fail   max 65407   <-- USED: the +128 folds into v_pk_mad_u16
//     m=n+127; q=(m  +(m>>8))>>8   45 fail               (breaks at n == 128 mod 255)
//     m=n+128; q=(m+1+(m>>8))>>8   47 fail               (breaks at n == 127 mod 255)
//     ((n+127)*257)>>16            45 fail   max 16744064 — ALSO blows the u16 lane
// The two bias values are NOT interchangeable with the two shift forms: TWO of the four pairings (C and
// D) are wrong. A is also correct, but costs one extra add, which is the only reason B is used. This is
// the single most swappable-looking line in the kernel.
//
// EXACTNESS / why bit-identity holds (all verified exhaustively, not sampled):
//   * NOTHING OVERFLOWS. n <= 65025 (510 spare), m <= 65153, m+(m>>8) <= 65407 — 128 to spare at the
//     tightest point. No clamp instruction anywhere, no widening to u32 in the core. ⚠ AND THAT IS THE
//     ONLY ARGUMENT FOR +128 THAT IS NOT ABOUT ROUNDING — an earlier draft of this header claimed the
//     truncating variant m=n+1 "peaks at 65792 and DOES wrap". IT DOES NOT: 65792 needs n=65535, and n
//     = dst_c*(255-src_a) <= 65025, so m=n+1 peaks at 65280, comfortably inside u16. The +128 form is
//     forced by ROUNDING alone. A false second justification is worse than none — it invites someone
//     who disproves it to "fix" the real one too.
//   * ROUNDING TIES ARE UNREACHABLE, so round-to-nearest is unambiguous and the f32 kernel's
//     v_cvt_pk_u8_f32 (which ROUNDS, settled on iron at 1.56.0/1.56.1) agrees with integer
//     round-half-up on every reachable value. ⚠ The parity sketch that blend_premul.s's header gives —
//     n/255 = k + 1/2 needs 2n = 510k + 255, even = odd, no solution — is about the EXACT RATIONAL
//     n/255, and the hardware never computes that. It computes fl(dst_c * fl(1 - a/255) + src_c), and
//     fl(-1/255) is not -1/255, so the rounding could in principle be pushed ONTO an exact k+0.5 (all
//     half-integers up to 255.5 are representable in f32). Measured instead of argued, over the full
//     256^3 cube: exact-.5 convert inputs = 0; min distance from the actual f32 convert input to any
//     k+0.5 = 1.9455e-03 vs max |f32 - exact| = 3.0039e-05, a 64.8x margin; and RNE vs
//     round-half-away-from-zero disagree on ZERO triples. The tie rule never comes into play, and the
//     result does not depend on which tie rule the hardware uses.
//   * THE f32 PATH IS ITSELF EXACT. fl(-1/255) * a + 1.0 lands on a multiple of 2^-31 in [-1,1]
//     (<= 32 significant bits) and dst*ia + src needs at most 40 significand bits, so each f32 step
//     is a single correctly-rounded operation with no accumulated error; the smallest distance from
//     an f32 intermediate to a rounding boundary is 1.95e-3, ~65x the largest f32 deviation (3.0e-5).
//     No f32 error can flip the convert. Also checked: no ia value is denormal, so pinning
//     .amdhsa_float_denorm_mode_32 0 (FTZ) never fires on the f32 side either.
//   * RESULT, from an instruction-level simulation of exactly the sequence below (u16 lanes wrapping
//     mod 2^16 at every op, v_perm_b32's low-byte-only repack, the 32-bit final add):
//         vs the EXACT rational reference : 0 mismatches over the whole 256^3 cube — the integer
//                                           formula is exact everywhere, including where it overflows
//                                           a byte, so the only failure mode is the lane carry below.
//         vs blend_premul.s (f32)         : 0 mismatches over all 8,421,376 premultiplied triples,
//                                           max out exactly 255, clamp not needed.
//         vs blend_premul.s, FULL cube    : 4,177,920 divergences — NOT a defect, this is the
//                                           precondition firing: f32 clamps where packed wraps.
//     Measured intermediate maxima over the premultiplied domain match the analysis exactly:
//         n <= 65025    m <= 65153    m+(m>>8) <= 65407    (u16 limit 65535)
//
// >>> PRECONDITION — THE TEST MUST FEED PREMULTIPLIED PIXELS (src_c <= src_a). <<<
// Two instructions depend on it and NEITHER faults if it is violated:
//   1. the final v_add_u32 is a plain 32-bit add on packed bytes; it is only lane-safe because
//      src_c + q <= 255, so no carry crosses a byte boundary. Straight-alpha input reaches a measured
//      max of 510 and SILENTLY CORRUPTS THE NEIGHBOURING CHANNEL.
//   2. the repack v_perm_b32 takes only the LOW byte of each u16 lane — there is no clamp, a lane of
//      0x0134 repacks as 0x34.
// Under the same violation the f32 kernel saturates instead (v_cvt_pk_u8_f32 clamps), so the two
// kernels DIVERGE on non-premultiplied data and the S4 diff would fail for a reason that has nothing
// to do with VOP3P. If straight-alpha ever needs supporting, the tail becomes 2 v_perm_b32 (src must
// then be UNPACKED, which the premultiplied path skips entirely — that asymmetry is what makes the core
// 14) + 2 v_pk_add_u16 + 2 v_pk_min_u16 + 1 v_perm_b32 repack, replacing the current 2: 19 core VALU,
// still under the f32 path's 18-core/31-total once addressing is counted.
//
// ONE CORNER THAT CANNOT BE SETTLED OFF IRON. At src_a = 255 the f32 path's ia is -127*2^-31, NOT zero
// (it is normal, not denormal, so FTZ never fires). For src_c = 0 and dst_c >= 1 the value handed to
// v_cvt_pk_u8_f32 is therefore strictly NEGATIVE — 255 such triples, min -1.508e-05. The integer path
// gives exactly src_c there. They agree only if v_cvt_pk_u8_f32 rounds-and-clamps a small negative to 0
// rather than converting modularly. That input is not exotic: it is OPAQUE BLACK SOURCE over any
// non-black destination. The burn's pixel list must contain it.
//
// ------------------------------------------------------------------------------------------------
// VALU COUNT — THE DELIVERABLE. Counted by hand below and confirmed against the disassembly.
//
//                                       blend_premul.s (f32)      blend_pk.s (VOP3P)
//     blend core                              18                        14
//     address arithmetic (identical)          13                        13
//     TOTAL VALU / pixel                      31                        27
//     SALU (s_mov constants)                   1                         6
//
// The f32 core is 2 (ia) + 4 channels x 4 (2x v_cvt_f32_ubyte, v_fma_f32, v_cvt_pk_u8_f32) = 18.
// The packed core is 14, itemised inline as "core N/14" on every VALU line below.
//
// blend_premul.s's header estimates "packed-int16 with div255 = 31-33" VALU. THAT NUMBER IS STALE.
// It was measured for a shift/mask, one-channel-at-a-time integer formulation. With v_perm_b32 doing
// unpack/repack four channels at a time and v_pk_mad_u16 folding the rounding bias into the multiply,
// the integer core is 14, not 31-33 — i.e. ~22% FEWER VALU than the float path, not ~70% more. The
// f32 kernel's other claims all survive re-testing (v_dot4_i32_i8 genuinely absent on gfx90c;
// v_cvt_pk_u8_f32 rounds; premultiplied output provably <= 255). Only the integer estimate was wrong.
// HAVE THE BURN PRINT THE REAL COUNT rather than trusting either comment.
//
// Honest caveat on what this buys: the f32 path pays ZERO unpack/repack cost because
// v_cvt_f32_ubyteN and v_cvt_pk_u8_f32 fuse byte extract/insert INTO the arithmetic op. The packed
// path must pay 3 v_perm_b32 to unpack and 1 to repack. So the 4-instruction win is real but thin at
// one pixel per lane, and S4(iii) should be sold as a PROOF OF EQUIVALENCE (and as the enabling proof
// for VOP3P at all), not as a perf bite. The packed form only pulls away when a workitem handles two
// pixels and pairs channel c of pixel A with channel c of pixel B — that variant is unbuilt and
// unmeasured, and the f32 path amortises addressing equally well, so decide it before a burn.
// ------------------------------------------------------------------------------------------------
//
// STANDING RULE, CONFIRMED AT ASSEMBLE TIME: ANYTHING ENCODED VOP3A/VOP3B/VOP3P TAKES NO 32-BIT
// LITERAL ON GFX9. It is not a VOP3P-only rule — v_perm_b32 is VOP3A and is rejected identically:
//     v_pk_add_u16 v1, v2, 0x007f007f     -> error: literal operands are not supported
//     v_perm_b32   v4, v1, v2, 0x03000102 -> error: literal operands are not supported
//     v_and_b32    v5, 0x00ff00ff, v2     -> OK   (VOP2/_e32 DOES take one; VOP3 _e64 does not)
// So every selector and mask below is staged through an SGPR with s_mov_b32 first. This one fails
// loudly at assemble time rather than silently on iron. The other half of the rule is the gfx9
// constant-bus limit of ONE distinct SGPR per VALU instruction; inline constants (-16..64, and the
// float inlines) are free and do not count, which is why "v_perm_b32 v9, 0, v3, s6" is legal.
//
// v_perm_b32 POOL ORDER — THE TRAP. The 64-bit byte pool is {S0, S1} with S1 as the LOW dword:
//     pool[0..3] = S1 bytes 0..3      pool[4..7] = S0 bytes 0..3
// i.e. THE DATA MUST BE IN S1, the SECOND written source. Selector index 12 = constant 0x00,
// 13..15 = 0xFF, and selector byte k selects destination byte k (LSB to LSB), so a selector hex
// literal reads destination-MSB-first left to right. Getting this backwards does not fault:
// putting the pixel in S0 yields whatever garbage is in the S1 VGPR, and swapping the two operands
// of the REPACK yields a clean two-channel colour rotation that still looks like a plausible image.
//
// KERNARGS — identical to blend_premul.s so the same host path drives both
// (COMPUTE_USER_DATA_0..5, USER_SGPR=6 => RSRC2 0x0C, matching the existing 3-kernarg dispatches):
//   s[0:1] = src base (premultiplied BGRA/RGBA8888)   s[2:3] = dst base   s[4:5] = out base
// One workitem per pixel; v0 = workitem id. Flat 1-D over the rect — no grid yet, that is a later bite.
// It rides gpu_matmul_run unchanged; RSRC2 harvests to 0x0C == GPU_COMPUTE_RSRC2_KERNARG3, which that
// emitter already hardcodes.
//
// ⚠⚠ RSRC1 IS **NOT** GPU_COMPUTE_PGM_RSRC1_V12. THIS IS THE ONE WAY TO LOSE THE BURN. ⚠⚠
// ⚠ THIS FILE IS HUMAN-READABLE REFERENCE ONLY. The authoritative artifact is the hex table committed
//   in kernel/core/gpu.cyr, which is iron-proven on archaemenid. There is NO build-time assembler
//   dependency: agnos does not ship, invoke, or require llvm — the shaders were authored once and
//   their bytes are the source of truth. If these ever need regenerating, do it through mabda's
//   sovereign Cyrius gfx9 encoder (mabda/src/gfx9_encode.cyr), NEVER a C/C++ toolchain.
// gpu_regs.cyr today — it has MIN 0x002C0040, V12 0x002C0042, F64 0x002C0043, GLYPH 0x002C00C2,
// GRID/COV/GRAD 0x002C00C3. blend_premul is dispatched at gpu.cyr:1595 with V12, and the sibling
// perm.s deliverable legitimately reuses V12, so copying either call site is the obvious integrator
// move and it is WRONG: V12's SGPRS field grants 16, this kernel needs 18 (12 architectural s0..s11
// plus 6 special: VCC pair, FLAT_SCRATCH pair, XNACK pair). Under-allocating SGPRs is the "wrong, not
// slow" class gpu_regs.cyr:1033-1035 warns about, and the first thing it corrupts here is the VCC
// carry chain in the address arithmetic — i.e. lanes reading and writing the wrong pixels, or off the
// end of the arena into the VM fault sink. ADD:
// and pass it for blend_pk ONLY. (GLYPH's 0x002C00C2 would also be *safe* — same 12 VGPRs, 32 SGPRs,
// over-allocation only costs occupancy — but reusing a constant named for another kernel is how the
// next recount goes wrong. Over-allocating is survivable; under-allocating is not.)

// warns a hand-counted RSRC word is "wrong, not slow"; deriving it from the same source that assembled
// the code removes that class of bug entirely — and this kernel adds 5 SGPRs over blend_premul, which
// is exactly the kind of recount a human forgets. ieee_mode/denorm are pinned to agnos's values (0/0);
// LLVM defaults to 1/3. They do not affect this integer kernel's arithmetic, but they must match
// blend_premul.s or the two kernels are not running under the same machine state and the S4 diff
// stops being a controlled comparison.
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl blend_pk
blend_pk:
    // byte offset = tid * 4
    v_lshlrev_b32   v1, 2, v0                                   // addr  1/13

    // src pixel -> v2 ; dst pixel -> v3
    v_mov_b32       v4, s0                                      // addr  2/13
    v_mov_b32       v5, s1                                      // addr  3/13
    v_add_co_u32    v4, vcc, v4, v1                             // addr  4/13
    v_addc_co_u32   v5, vcc, 0, v5, vcc                         // addr  5/13
    global_load_dword v2, v[4:5], off

    v_mov_b32       v6, s2                                      // addr  6/13
    v_mov_b32       v7, s3                                      // addr  7/13
    v_add_co_u32    v6, vcc, v6, v1                             // addr  8/13
    v_addc_co_u32   v7, vcc, 0, v7, vcc                         // addr  9/13
    global_load_dword v3, v[6:7], off

    // Constants. SALU, and dispatch-invariant — these hoist out of any future per-pixel loop, which
    // is why the 6-vs-1 s_mov delta does not belong in the per-pixel VALU comparison. Issued here so
    // they overlap the two loads' latency instead of stalling behind the s_waitcnt.
    s_mov_b32       s6,  0x0c010c00     // perm sel: S1 bytes {0,1} -> u16 lanes (c0 lo, c1 hi)
    s_mov_b32       s7,  0x0c030c02     // perm sel: S1 bytes {2,3} -> u16 lanes (c2 lo, c3 hi)
    s_mov_b32       s8,  0x0c030c03     // perm sel: broadcast S1 byte 3 (alpha) into BOTH u16 lanes
    s_mov_b32       s9,  0x06040200     // perm sel: repack {S1.b0,S1.b2,S0.b0,S0.b2} -> c3 c2 c1 c0
    s_mov_b32       s10, 0x00ff00ff     // 255 in BOTH halves — see op_sel_hi note below
    s_mov_b32       s11, 0x00800080     // +128 rounding bias in BOTH halves

    s_waitcnt       vmcnt(0)            // v2/v3 live from here; v6/v7 (dst address) now reusable

    // ---- op_sel / op_sel_hi are written out EXPLICITLY on every VOP3P below. ------------------
    // The mnemonic default IS op_sel:[0,0(,0)] op_sel_hi:[1,1(,1)] (verified by disassembling what
    // out anyway because the ONE line that must differ is invisible otherwise, and getting it wrong
    // ASSEMBLES CLEAN AND COMPUTES THE WRONG ANSWER IN THE HIGH LANE ONLY. op_sel_hi[i]=1 means
    // "source i's lane-1 input is bits[31:16]"; =0 means "take bits[15:0] for both lanes".
    // Therefore a scalar that is only in the low half needs op_sel_hi=0 on that operand:
    //   - the shift counts below are the INLINE CONSTANT 8 = 0x00000008, high half ZERO, so they
    //     REQUIRE op_sel_hi:[0,1] — with the default, lane 1 would shift by 0.
    //   - s10/s11 are pre-replicated into both halves by the s_mov above, so they keep the default.
    // Measured cost of getting the shift modifier wrong, simulated on THIS kernel: 8,266,513 of the
    // 8,421,376 premultiplied channel-triples (98.2%) come out wrong, and the damage is confined to
    // the HIGH lanes — channels 1 and 3 (G and A) — while channels 0 and 2 (B and R) stay perfect.
    // It renders as a plausible image with a green/alpha cast, NOT as garbage.
    // THE BURN'S PASS CRITERION MUST CHECK G AND A EXPLICITLY, not "the image looks right".
    // (v_perm_b32 is VOP3A, not VOP3P; "op_sel:" on it is a syntax error, hence no modifier there.)
    // ------------------------------------------------------------------------------------------

    // ia = 255 - src_a, splatted to both u16 lanes.
    v_perm_b32       v8,  0, v2, s8                              // core  1/14  v8 = {sa, sa}
    v_pk_sub_u16     v8,  s10, v8 op_sel:[0,0] op_sel_hi:[1,1]   // core  2/14  ia = 255 - sa
                                                                 //   v_pk_sub_u16 D,S0,S1 = S0 - S1.
                                                                 //   No clamp: sa <= 255 so ia >= 0.

    // Unpack dst into two channel pairs. src stays PACKED — it is only needed for the final 32-bit
    // add, so it never gets unpacked at all. That asymmetry is worth 2 VALU.
    v_perm_b32       v9,  0, v3, s6                              // core  3/14  dst {c0, c1}
    v_perm_b32       v10, 0, v3, s7                              // core  4/14  dst {c2, c3}

    // m = dst_c * ia + 128, two channels at a time. v_pk_mad_u16 D,S0,S1,S2 = S0*S1 + S2 (addend is
    // src2, the last operand — confirmed by compiling known mul-then-add semantics, not from syntax).
    // Fusing the bias here is what makes this 14 and not 16. Un-fused equivalent, if the burn wants
    // opcode coverage of v_pk_mul_lo_u16 (verified to give identical results, costs +1 VALU each):
    //     v_pk_mul_lo_u16 v9, v9, v8   op_sel:[0,0] op_sel_hi:[1,1]
    //     v_pk_add_u16    v9, v9, s11  op_sel:[0,0] op_sel_hi:[1,1]
    // Do NOT put `clamp` on v_pk_mul_lo_u16 — it assembles, but its meaning on a low-half multiply is
    // not established by anything verifiable here, and nothing in this kernel needs saturation.
    v_pk_mad_u16     v9,  v9,  v8, s11 op_sel:[0,0,0] op_sel_hi:[1,1,1]  // core  5/14  m = dc*ia+128
    v_pk_mad_u16     v10, v10, v8, s11 op_sel:[0,0,0] op_sel_hi:[1,1,1]  // core  6/14

    // q = (m + (m>>8)) >> 8  ==  round(m_without_bias / 255).
    // v_pk_lshrrev_b16 D,S0,S1 = S1 >> S0 — the shift amount is src0 ("rev" order), the DATA is src1.
    // Written the other way round this assembles fine and computes v9 >> 8 ... of the wrong operand.
    v_pk_lshrrev_b16 v6,  8, v9  op_sel:[0,0] op_sel_hi:[0,1]    // core  7/14  m>>8   (<= 254)
    v_pk_lshrrev_b16 v7,  8, v10 op_sel:[0,0] op_sel_hi:[0,1]    // core  8/14
    v_pk_add_u16     v9,  v9,  v6 op_sel:[0,0] op_sel_hi:[1,1]   // core  9/14  m+(m>>8) (<= 65407)
    v_pk_add_u16     v10, v10, v7 op_sel:[0,0] op_sel_hi:[1,1]   // core 10/14
    v_pk_lshrrev_b16 v9,  8, v9  op_sel:[0,0] op_sel_hi:[0,1]    // core 11/14  q = round(n/255)
    v_pk_lshrrev_b16 v10, 8, v10 op_sel:[0,0] op_sel_hi:[0,1]    // core 12/14

    // Repack the four q values back into byte lanes. OPERAND ORDER IS LOAD-BEARING: selector
    // 0x06040200 reads pool[0],pool[2],pool[4],pool[6] = S1.b0, S1.b2, S0.b0, S0.b2, and S1 is the
    // LOW dword of the pool — so S0 must be the HIGH channel pair (c2,c3) and S1 the LOW pair (c0,c1).
    // Swapped, this yields c1 c0 c3 c2: a two-channel rotation that does not fault and looks like an
    // image. Safe against the repack's implicit low-byte truncation only because q <= 255 by now,
    // which is exactly what the >>8 above guarantees — this instruction MUST follow it.
    v_perm_b32       v11, v10, v9, s9                            // core 13/14  q3 q2 q1 q0

    // out = src + q. Plain 32-bit add on packed bytes: legal ONLY under the premultiplied invariant
    // (src_c + q <= 255 per channel, so no carry crosses a byte lane). See PRECONDITION above.
    v_add_u32        v11, v2, v11                                // core 14/14

    // store to out
    v_mov_b32       v4, s4                                       // addr 10/13
    v_mov_b32       v5, s5                                       // addr 11/13
    v_add_co_u32    v4, vcc, v4, v1                              // addr 12/13
    v_addc_co_u32   v5, vcc, 0, v5, vcc                          // addr 13/13
    global_store_dword v[4:5], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel blend_pk
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 6
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 0
    .amdhsa_system_vgpr_workitem_id 0
    // VGPRs: highest used is v11 -> 12, the SAME granule as blend_premul.s. Achieved by reusing the
    // dst-address pair v6/v7 as the shift temporaries after s_waitcnt; a naive allocation reaches v13
    // and rounds up to 16, i.e. a 4th VGPR granule for nothing. SGPRs: s0..s5 kernargs + s6..s11
    // constants -> 12 architectural (blend_premul needs 7), + 6 special (VCC/FLAT_SCRATCH/XNACK) = 18,
    // which rounds to the 24 granule. RSRC1 therefore harvests as 0x002C0082, NOT V12's 0x002C0042 —
    // see the RSRC1 warning in the header. Both are far under the gfx9 per-wave limit and neither
    // crosses an occupancy threshold, so blend_pk and blend_premul run at the same occupancy and the
    // VALU comparison is not confounded by it.
    .amdhsa_next_free_vgpr 12
    .amdhsa_next_free_sgpr 12
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
