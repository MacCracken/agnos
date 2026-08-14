// blend_alpha.s — gfx90c premultiplied src-over alpha blend with a UNIFORM per-surface alpha, over a
// 2-D GRID, in place on a strided surface.
//
// blend_rect.s plus one scalar: `alpha` in 0..255, applied to the whole rect. It is the shader behind
// `#92` op **0x06** and aethersafha's per-window opacity (M6-C3).
// ⚠ An earlier draft said 0x11. That code is mechanically free but sits inside the reserved
// `0x10-0x17` CP-DMA lane, and gpu.cyr states minting 0x10/0x11 needs a domain state machine nobody
// wrote. This is a SHADER dispatch with no engine-domain transition, so it belongs in the composite
// lane 0x00-0x07 — and 0x06 is the only free code there, since 0x05 and 0x07 have `perm_write` and
// `blend_pk_write` (already-committed, iron-proven blobs) waiting for them.
//
// ⛔ THIS SHADER HAS NOT BEEN BURNED. Every claim below is a HOST claim. blend_rect's bytes are
// iron-proven; these are not, and `shader-blob.sh:11-15` already records that a blob assembled but not
// run "has not met the bar for a hardware run". Treat the numbers here as a prediction to be tested.
//
// DERIVATION FROM blend_rect.s — 9 inserted dwords, 5 CHANGED, 55 unchanged. 60 -> 69 dwords, 276 B.
// ⛔ THE DERIVATION IS NOT MACHINE-CHECKED. This line claimed `scripts/check/shader-derive.sh` gated it;
// THAT SCRIPT DOES NOT EXIST and never did — it was named in five files before anyone wrote it, which is
// the same cited-but-absent-gate defect this tree keeps finding. What DOES gate this shader:
//   · `scripts/check/shader-crossasm.sh` — llvm-mc from this .s vs mabda from the emit list, 69/69 dwords
//   · `tests/gpu/shaderexec.cyr`         — EXECUTES the bytes; the s9 clobber shows as 59,319 mismatches
// Those cover correctness. The 9-inserted/5-changed decomposition below is DOCUMENTATION, verified once
// by machine diff on 2026-08-13 and not re-checked on every build. Do not cite it as a gate.
//
// ⚠⚠ THE FIFTH CHANGE IS THE ONE THAT BITES, AND IT IS NOT A KERNARG RENAME.
// Taking s7 for `alpha` pushes USER_SGPR 7 -> 8, so the TGIDs move s7/s8 -> s8/s9. Four of blend_rect's
// dwords READ a TGID and obviously follow. The fifth does not read one — it WRITES s9 as scratch
// (`s_lshl_b32 s9, s7, 6`, the column base). Under the new layout **s9 IS tgid_y**, so that write
// destroys the row index before the two `s_mul_i32 ..., s9, pitch` reads consume it. Every row address
// would collapse to a function of the column group: column group 0 writes row 0 for every y. It
// assembles clean, it matches its own blob byte for byte, and it faults nothing.
// ⇒ The column scratch moves to **s15**, the ONLY unused SGPR below the saved-EXEC pair in blend_rect
// (it touches s0-s14 and s16-s21, skipping 15 so s[16:17] lands even-aligned).
//
// ⚠ SCC IS LOAD-BEARING BETWEEN THE ADDRESS PAIRS. `s_add_u32` sets SCC and the following
// `s_addc_u32` consumes it; `s_lshl_b32` and `s_add_u32` both WRITE SCC. Nothing may be inserted
// between s12/s13 or between s18/s19, or the 64-bit address carries drop silently. All nine
// insertions are placed outside those pairs.
//
// KERNARGS (USER_SGPR=8):
//   s[0:1] = src base (premultiplied BGRA8888, tightly packed rows of src_pitch bytes)
//   s[2:3] = dst base — READ AND WRITTEN IN PLACE (this is the back buffer)
//   s4     = src pitch in BYTES     s5 = dst pitch in BYTES     s6 = rect width in PIXELS
//   s7     = alpha, INTEGER 0..255
// SYSTEM SGPRs (after the 8 user SGPRs):  s8 = tgid_x (64-px column group)   s9 = tgid_y (row)
//
// ⚠ ALPHA IS AN INTEGER, NOT A PRE-DIVIDED f32 BIT PATTERN. The kernel is FP-free, so it cannot
// compute alpha/255.0f to hand down; and shipping an f32 pattern would put IEEE semantics into the
// `#92` ABI. Four dwords of prologue is the right price.
//
// THE MATH. fa = alpha * (1/255f); every source channel AND the source alpha scale by fa, so
// premultiplication (c <= a) is preserved and `ia = 1 - (sa*fa)/255` falls out of the UNMODIFIED fma.
// ⭐ alpha=255 is the EXACT IDENTITY: 0x3B808081 is the correctly-rounded f32 nearest 1/255 and
// 255 * 0x3B808081 rounds to exactly 1.0f, so every channel falls through unchanged and the output is
// bit-identical to blend_rect's over all 256^3 inputs (measured). alpha=0 leaves dst untouched.
// ⚠ That identity survives by 1/256 of a ULP (255*INV = 1 + 127*2^-31, tie at 128*2^-31). It is a
// coincidence of this constant, not a property to lean on.
//
// ⛔ THE TIE RULE IS NEWLY REACHABLE AND IS AN OPEN QUESTION. blend_rect never had to answer it —
// gpu.cyr states "Exact .5 never occurs here (t = 255k + 127.5 is not an integer), so the tie rule is
// unreachable". blend_alpha REACHES it: 5,905 in-range premultiplied ties, on which round-half-even
// and round-half-away differ for 3,010 outputs (e.g. alpha=4, sa=64, sc=64, dc=128 -> t = 128.5
// exactly; RTNE gives 128, half-away gives 129). This file assumes **RTNE**, matching
// `.amdhsa_float_round_mode_32 0`. ⚠ The tree's only burn evidence does NOT discriminate: burn 1's
// 249 -> 250 is a tie where 250 is even, so both rules agree there. A burn can overturn this.
//
// ROUNDING BIAS: none, matching blend_rect. v_cvt_pk_u8_f32 rounds to nearest (settled on iron,
// 1.56.0 burn 1 — an added +0.5 came out +1 on every channel).
.amdgcn_target "amdgcn-amd-amdhsa--gfx90c"
.text
.p2align 8
.globl blend_alpha
blend_alpha:
    // ---- BOUNDS GUARD: mask off lanes past the right edge BEFORE forming any address ----
    s_lshl_b32      s15, s8, 6             // CHANGED x2: dest s9->s15, src s7->s8 (tgid_x)
    v_add_u32       v12, s15, v0           // CHANGED: reads the relocated scratch
    v_cmp_gt_u32    vcc, s6, v12
    s_and_saveexec_b64 s[16:17], vcc

    // ---- scalar address setup ----
    s_lshl_b32      s10, s8, 8             // CHANGED: tgid_x
    s_mul_i32       s11, s9, s4            // CHANGED: tgid_y
    s_add_u32       s11, s11, s10
    s_add_u32       s12, s0, s11           // sets SCC
    s_addc_u32      s13, s1, 0             // consumes it — do not insert between these two
    s_mul_i32       s14, s9, s5            // CHANGED: tgid_y
    s_add_u32       s14, s14, s10
    s_add_u32       s18, s2, s14           // sets SCC
    s_addc_u32      s19, s3, 0             // consumes it — do not insert between these two

    v_lshlrev_b32   v1, 2, v0

    // src pixel -> v2
    v_mov_b32       v4, s12
    v_mov_b32       v5, s13
    v_add_co_u32    v4, vcc, v4, v1
    v_addc_co_u32   v5, vcc, 0, v5, vcc
    global_load_dword v2, v[4:5], off

    // dst pixel -> v3 ; v[6:7] is ALSO the store address (in place)
    v_mov_b32       v6, s18
    v_mov_b32       v7, s19
    v_add_co_u32    v6, vcc, v6, v1
    v_addc_co_u32   v7, vcc, 0, v7, vcc
    global_load_dword v3, v[6:7], off
    s_waitcnt       vmcnt(0)

    // ---- INSERTED PROLOGUE (4 dwords): fa = alpha / 255 ----
    // Placed after the waitcnt and after the EXEC mask, so surplus lanes do not execute it. It is
    // uniform, so a scalar-only formulation would also work; VOP1 is used because its 9-bit src0
    // reaches SGPRs directly and the value is consumed per-lane four times.
    s_mov_b32       s21, 0x3B808081        // +1/255f  (VOP3 takes no 32-bit literal on gfx9)
    v_cvt_f32_ubyte0 v13, s7               // f32(alpha)
    v_mul_f32       v13, s21, v13          // fa = alpha/255

    // ---- blend body ----
    v_cvt_f32_ubyte3 v8, v2
    v_mul_f32       v8, v13, v8            // INSERTED: sa' = src_a * fa, BEFORE the unmodified fma
    s_mov_b32       s20, 0xBB808081        // -1/255f
    v_fma_f32       v8, v8, s20, 1.0       // ia = 1 - sa'/255  (unchanged)

    v_cvt_f32_ubyte0 v9,  v2
    v_mul_f32       v9, v13, v9            // INSERTED: scale the SOURCE only, never dst
    v_cvt_f32_ubyte0 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 0, v11

    v_cvt_f32_ubyte1 v9,  v2
    v_mul_f32       v9, v13, v9            // INSERTED
    v_cvt_f32_ubyte1 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 1, v11

    v_cvt_f32_ubyte2 v9,  v2
    v_mul_f32       v9, v13, v9            // INSERTED
    v_cvt_f32_ubyte2 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 2, v11

    v_cvt_f32_ubyte3 v9,  v2
    v_mul_f32       v9, v13, v9            // INSERTED
    v_cvt_f32_ubyte3 v10, v3
    v_fma_f32       v9, v10, v8, v9
    v_cvt_pk_u8_f32 v11, v9, 3, v11

    global_store_dword v[6:7], v11, off glc
    s_waitcnt       vmcnt(0)
    s_endpgm

.rodata
.p2align 6
.amdhsa_kernel blend_alpha
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 14
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
    .amdhsa_exception_int_div_zero 0
.end_amdhsa_kernel
