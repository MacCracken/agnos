// tex_list.s — RUNG 14: N textured primitives in ONE dispatch, op 0x0C GPU_OP_TEX_LIST.
//
// ⭐ WHY A FUSED DISPATCH AT ALL, measured not assumed. Rung 13 measured the dispatch chain at a
// FIXED 52.7 us regardless of rect size; FULLCOV cut it to ~27.9 us by removing two of the three
// dispatches. A DOOM frame is ~640 wall columns, and at one dispatch each that is 17.9 ms of pure
// OVERHEAD inside a 28.6 ms frame before a single pixel is shaded. Fusing pays the fixed cost once.
//
// ⛔ AND IT MUST FUSE BY DISPATCH, NOT BY GEOMETRY. tests/gpu/doomwall.cyr measured the tempting
// alternative — merging a run of columns into one affine quad — and refuted it: at a 1.5x depth
// ratio across the seg, 4096 of 4096 pixels differ, because ty_step = 1/depth is a hyperbola in
// screen x while an affine quad interpolates it linearly. That is exactly `rw_scale += rw_scalestep`,
// the swim cyrius-doom removed at render.cyr:1275. One quad per column stays bit-exact
// (tests/gpu/doomcol.cyr: 7/7 EXACT); only the DISPATCH count may be collapsed.
//
// ⭐⭐ THE BODY BELOW IS RUNG 13's, CHARACTER-FOR-CHARACTER. Everything from the format branch to
// s_endpgm is copied verbatim from tex_rgba.s, and scripts/check/texl-body-identity.sh FAILS THE
// BUILD if the two ever diverge. That is the whole safety argument for this file: rung 13's
// texturing arithmetic is iron-proven at 17/17, and the only new code here is the ~15-instruction
// prologue that picks WHICH primitive this workgroup is shading. A hand-edited copy that could
// drift would have thrown that proof away; a gated copy keeps it.
//
// THE GRID MAPPING. gx = n_prims << tile_shift, gy = max(ph) over the list.
//     prim = tgid_x >> tile_shift          which primitive this workgroup shades
//     tile = tgid_x - (prim << tile_shift) which 64-px slice of that primitive's width
//     px   = tile*64 + lane                rect-local column
//     py   = tgid_y                        rect-local row
// tile_shift is ceil(log2(ceil(max_pw/64))), computed CPU-side, so the split is a shift and never a
// divide. For DOOM columns (pw = 1) tile_shift is 0, gx is exactly n_prims, and px is just the lane.
// Indexing the record array by tgid_x makes the per-pixel cost O(1): no search, and no requirement
// that the primitives be adjacent, uniform, or sorted.
//
// ⛔ FULLCOV IS MANDATORY FOR THIS OP (gpo_validate_texlist enforces it per primitive), which is
// what makes the fusion safe. Rung 12's tri-list corrupted every triangle but the last because N
// primitives SHARED three fixed arena slots inside an open batch. Here each primitive owns its own
// 160-byte record in an array and there is NO coverage stage to share — that failure mode is not
// guarded against, it is unrepresentable. The mask-loading path in the body below is therefore
// DEAD CODE here; it is retained only so the body stays character-identical to rung 13's. Should it
// ever be reached, cov_lo/cov_hi are 0 (gpu_texl_build passes 0 deliberately) and it faults on a
// null load rather than silently texturing through another primitive's stale mask.
//
// Kernargs, as gpu_tex_list stages them through gpu_blend_cov_run:
//   s[0:1] = the record ARRAY base          s[2:3] = back-buffer base (NOT a rect base)
//   s4     = destination pitch in BYTES     s5 = n_prims
//   s6     = tile_shift                     s7 = unused
//   s8     = tgid_x (system)                s9 = tgid_y (system)
//
// The per-primitive record is rung 13's 160-byte TEX-PREP record with its reserved Q9 filled in:
//   Q0 +0    cov_lo cov_hi t 32-t     (cov is 0: FULLCOV is mandatory)
//   Q1 +16   Dh V L fmt
//   Q2 +32   A2_lo A2_hi tw th
//   Q3 +48   kxB kyB k0B_lo k0B_hi
//   Q4 +64   kxC kyC k0C_lo k0C_hi
//   Q5 +80   tex_lo tex_hi lut_lo lut_hi
//   Q6 +96   du0 du1 du2 mu
//   Q7 +112  dv0 dv1 dv2 mv
//   Q8 +128  limU_lo limU_hi limV_lo limV_hi
//   Q9 +144  dst_off  pwh(ph<<16|pw)  0 0     ← list-only, zero in an op 0x0B record

.text
.globl tex_list
.p2align 8
.type tex_list,@function

// ⛔ REGISTER SAFETY, DERIVED NOT ASSUMED. This prologue writes s0, s1, s2, s3, s6, s7, s10, s14,
// s15 and s[16:19], all of which the shared body ALSO touches. It is safe for one checked reason:
//   s14..s19 — the body's FIRST touch is a WRITE (`s_mov_b32 s14, s48` … `s19, s57`, the U-axis
//              constants), and this prologue needs none of them after it finishes. Verified by
//              extracting the body and reading every occurrence, not by assuming.
//   s6       — becomes pw, which is exactly what the body means by s6. Its only body read is on the
//              coverage path, which FULLCOV makes unreachable here.
//   s7, s10  — the body never reads either.
//   s0..s3   — s[0:1] is consumed by the record loads above; s[2:3] is read once, at the store.
// ⚠ Rung 13 lost a burn to precisely this class: a "fix" wrote a scratch value over a still-live
// v19, and the clobber wrote ZERO, so the shader read like a dead one. Hand-written asm has no
// register allocator. Re-derive this list after ANY edit to either file.

tex_list:
    s_mov_b64       exec, -1

    // ---- which primitive, and which 64-px slice of it ----
    s_lshr_b32      s14, s8, s6             // prim = tgid_x >> tile_shift
    s_lshl_b32      s15, s14, s6
    s_sub_u32       s15, s8, s15            // tile = tgid_x - (prim << tile_shift)

    // ⚠ CLOBBERS s[0:1] ON PURPOSE. Once the record address is formed nothing downstream wants the
    // array base, and keeping a second copy would cost an SGPR pair for no reader.
    s_mul_i32       s10, s14, 160
    s_add_u32       s0, s0, s10
    s_addc_u32      s1, s1, 0

    s_load_dwordx4  s[24:27], s[0:1], 0x0
    s_load_dwordx4  s[28:31], s[0:1], 0x10
    s_load_dwordx4  s[32:35], s[0:1], 0x20
    s_load_dwordx4  s[36:39], s[0:1], 0x30
    s_load_dwordx4  s[40:43], s[0:1], 0x40
    s_load_dwordx4  s[44:47], s[0:1], 0x50
    s_load_dwordx4  s[48:51], s[0:1], 0x60
    s_load_dwordx4  s[52:55], s[0:1], 0x70
    s_load_dwordx4  s[56:59], s[0:1], 0x80
    s_load_dwordx4  s[16:19], s[0:1], 0x90  // Q9: dst_off, pwh — the list-only fields
    s_waitcnt       lgkmcnt(0)

    // ---- this primitive's own size, from its own record ----
    s_and_b32       s6, s17, 0xFFFF         // pw   ⚠ s6 stops being tile_shift HERE; the body
    s_lshr_b32      s7, s17, 16             // ph      reads s6 as the width, exactly as rung 13 does

    // ⛔ ROWS PAST THIS PRIMITIVE'S HEIGHT DO NOTHING. The grid is sized by the TALLEST primitive in
    // the list, so a short primitive's workgroups WILL be launched for rows it does not own. Exiting
    // is the whole reason a list may hold primitives of differing heights; without this guard a
    // 16-row primitive in a list whose tallest is 200 would scribble 184 rows past its rect.
    s_cmp_ge_u32    s9, s7
    s_cbranch_scc1  L_END

    // ---- px = tile*64 + lane, bounds-guarded BEFORE any address is formed ----
    s_lshl_b32      s10, s15, 6
    v_add_u32       v1, s10, v0             // v1 = px
    v_cmp_gt_u32    vcc, s6, v1             // pw > px ?
    s_and_saveexec_b64 s[20:21], vcc
    s_cbranch_execz L_END

    // ---- this primitive's destination origin ----
    // ⚠ A BYTE OFFSET FROM THE BACK BUFFER, added here rather than baked into the record on the CPU:
    // the record then does not encode WHICH buffer it was built for, so a front/back flip between
    // build and dispatch cannot aim it at the visible frame.
    s_add_u32       s2, s2, s16
    s_addc_u32      s3, s3, 0

    // ⭐ WAVE-UNIFORM BRANCH ON THE FORMAT WORD. `flags` lives in an SGPR, so every lane takes the
    // same side — the one place a scalar branch is legitimate. Bit 1 is FULLCOV.
    s_and_b32       s13, s31, 2
    s_cmp_eq_u32    s13, 2
    s_cbranch_scc1  L_FULLCOV

    // ---- coverage byte at (px, py). The mask is w bytes per row, tightly packed. ----
    s_mul_i32       s11, s9, s6             // py * w
    v_add_u32       v7, s11, v1
    v_mov_b32       v14, s24
    v_mov_b32       v15, s25
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_ubyte v4, v[14:15], off
    s_waitcnt       vmcnt(0)

    // ⛔ ZERO COVERAGE STORES NOTHING. A lane outside the shape must leave the destination alone;
    // writing "the blend of a transparent source" would still clobber whatever a previous triangle
    // put there, which is precisely the class of bug rung 12's batch path was wrecked by.
    v_cmp_ne_u32    vcc, 0, v4
    s_and_saveexec_b64 s[22:23], vcc
    s_cbranch_execz L_END
    s_branch        L_HAVE_COV

L_FULLCOV:
    // ⭐ FULLCOV: every pixel is covered, so there is no mask to read and no lane to mask off.
    // The kernel skipped both coverage dispatches, so the mask slot holds STALE bytes from a
    // previous op — loading it would be reading another primitive's shape. 255 is not an
    // optimisation here, it is the only correct value.
    v_mov_b32       v4, 0xFF

L_HAVE_COV:

    // ---- sample point at the pixel CENTRE, 16.16 ----
    v_lshlrev_b32   v5, 16, v1
    v_add_u32       v5, 0x8000, v5          // Pcx
    s_lshl_b32      s12, s9, 16
    s_add_i32       s12, s12, 0x8000
    v_mov_b32       v6, s12                 // Pcy

    // ---- E_B = kxB*Pcx + kyB*Pcy + k0B, signed, 64-bit ----
    v_mul_lo_u32    v8,  s36, v5
    v_mul_hi_u32    v9,  s36, v5
    s_ashr_i32      s13, s36, 31
    v_and_b32       v14, s13, v5
    v_sub_u32       v9,  v9, v14
    v_ashrrev_i32   v14, 31, v5
    v_and_b32       v14, s36, v14
    v_sub_u32       v9,  v9, v14

    v_mul_lo_u32    v10, s37, v6
    v_mul_hi_u32    v11, s37, v6
    s_ashr_i32      s13, s37, 31
    v_and_b32       v14, s13, v6
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s37, v14
    v_sub_u32       v11, v11, v14

    v_add_co_u32    v8,  vcc, v8, v10
    v_addc_co_u32   v9,  vcc, v9, v11, vcc
    v_mov_b32       v14, s38
    v_mov_b32       v15, s39
    v_add_co_u32    v8,  vcc, v8, v14
    v_addc_co_u32   v9,  vcc, v9, v15, vcc  // v[8:9] = E_B

    // ---- E_C = kxC*Pcx + kyC*Pcy + k0C ----
    v_mul_lo_u32    v10, s40, v5
    v_mul_hi_u32    v11, s40, v5
    s_ashr_i32      s13, s40, 31
    v_and_b32       v14, s13, v5
    v_sub_u32       v11, v11, v14
    v_ashrrev_i32   v14, 31, v5
    v_and_b32       v14, s40, v14
    v_sub_u32       v11, v11, v14

    v_mul_lo_u32    v12, s41, v6
    v_mul_hi_u32    v13, s41, v6
    s_ashr_i32      s13, s41, 31
    v_and_b32       v14, s13, v6
    v_sub_u32       v13, v13, v14
    v_ashrrev_i32   v14, 31, v6
    v_and_b32       v14, s41, v14
    v_sub_u32       v13, v13, v14

    v_add_co_u32    v10, vcc, v10, v12
    v_addc_co_u32   v11, vcc, v11, v13, vcc
    v_mov_b32       v14, s42
    v_mov_b32       v15, s43
    v_add_co_u32    v10, vcc, v10, v14
    v_addc_co_u32   v11, vcc, v11, v15, vcc // v[10:11] = E_C

    // ---- E_A = 2A - E_B - E_C. Derived, not a third cross product. ----
    v_mov_b32       v12, s32
    v_mov_b32       v13, s33
    v_sub_co_u32    v12, vcc, v12, v8
    v_subb_co_u32   v13, vcc, v13, v9, vcc
    v_sub_co_u32    v12, vcc, v12, v10
    v_subb_co_u32   v13, vcc, v13, v11, vcc // v[12:13] = E_A

    // ======================================================================================
    // U AXIS
    // ======================================================================================
    s_mov_b32       s14, s48                // du0
    s_mov_b32       s15, s49                // du1
    s_mov_b32       s16, s50                // du2
    s_mov_b32       s17, s51                // mu
    s_mov_b32       s18, s56                // limU_lo
    s_mov_b32       s19, s57                // limU_hi
    s_mov_b32       s60, s34                // tw
    v_mov_b32       v20, 0
    v_mov_b32       v21, 0
    v_mov_b32       v22, 0
    // -- N = E_A*du0 + E_B*du1 + E_C*du2, 96 bits, every high half SIGNED --
    v_mul_lo_u32    v16, v12, s14
    v_mul_hi_u32    v17, v12, s14
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v13, s14
    v_mul_hi_u32    v17, v13, s14
    v_ashrrev_i32   v18, 31, v13
    v_and_b32       v18, s14, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v8, s15
    v_mul_hi_u32    v17, v8, s15
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v9, s15
    v_mul_hi_u32    v17, v9, s15
    v_ashrrev_i32   v18, 31, v9
    v_and_b32       v18, s15, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v10, s16
    v_mul_hi_u32    v17, v10, s16
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v11, s16
    v_mul_hi_u32    v17, v11, s16
    v_ashrrev_i32   v18, 31, v11
    v_and_b32       v18, s16, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    // ⛔ NO SCALAR BRANCH ON A PER-LANE CONDITION, AND THE FIRST VERSION HAD TWO.
    // s_cbranch_vccz tests whether ALL lanes matched and s_cbranch_vccnz whether ANY did, so a
    // single lane with a negative numerator dragged EVERY lane down the same path. That is the
    // gfx9 trap this tree already records: a per-lane condition is a PREDICATE, never a branch.
    // [[reference_gfx9_per_lane_control_flow]] The quotient is now computed for every lane and
    // the two short-circuits are applied as v_cndmask selects afterwards.
    v_lshrrev_b32   v16, s26, v20
    v_lshlrev_b32   v17, s27, v21
    v_or_b32        v16, v16, v17
    v_lshrrev_b32   v17, s26, v21
    v_lshlrev_b32   v18, s27, v22
    v_or_b32        v17, v17, v18

    v_lshlrev_b32   v28, s30, v16
    s_sub_i32       s61, 32, s30
    v_lshrrev_b32   v29, s61, v16
    v_lshlrev_b32   v30, s30, v17
    v_or_b32        v29, v30, v29
    v_mul_hi_u32    v30, v28, s29
    v_mul_lo_u32    v31, v29, s29
    v_mul_hi_u32    v28, v29, s29
    v_add_co_u32    v30, vcc, v30, v31
    v_addc_co_u32   v28, vcc, 0, v28, vcc
    v_lshlrev_b32   v29, 1, v28
    v_lshrrev_b32   v30, 31, v30
    v_or_b32        v23, v29, v30

    // ⛔ v18 IS REUSED HERE, NOT v19. The first version used v19 as scratch for lo(q1*A2hi) — and
    // v19 HOLDS THE STASHED U INDEX across the V axis. Because A2_hi is 0 for any frame whose area
    // fits 32 bits, that multiply wrote ZERO over tu, and iron came back with texel 0 on every
    // pixel of the 1:1 case. q+1 is dead after this product, so v18 is free to take it.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v18, v18, s33
    v_add_u32       v17, v17, v18
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    // ⚠ ARITHMETIC shift and SIGNED clamps: q+m goes negative where the UV frame extrapolates
    // below zero, and a logical shift would make that a huge positive index selecting the OPPOSITE
    // edge. texcore clamps such samples to texel 0.
    v_add_u32       v23, s17, v23
    v_ashrrev_i32   v23, 16, v23
    s_sub_i32       s61, s60, 1

    // ⛔ THE WRAP BRANCH MUST PRECEDE THE SATURATION, AND THE FIRST VERSION DID NOT.
    // It sat AFTER v_max_i32/v_min_i32, so wrap AND-ed an index already clamped into [0, dim-1] —
    // a no-op. Iron reported a constant 0xff073815 (texel 7) across a tile where the reference
    // tiled 0,1,2,3: saturation wearing wrap's flag. The located diffs named it in one read.
    // ⚠ The AND handles a NEGATIVE index correctly on two's complement (-1 & 7 = 7, the far edge)
    // — exactly what the reference's restored floor-divide produces.
    s_and_b32       s62, s31, 4
    s_cmp_eq_u32    s62, 4
    s_cbranch_scc1  L_U_WRAP

    v_max_i32       v23, 0, v23
    v_min_i32       v23, s61, v23

    // -- predicate: N >= limit => the last texel (guards the u32 quotient against wrapping) --
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_mov_b32       v18, s61
    v_cndmask_b32   v23, v23, v18, vcc

    // -- predicate: N < 0 => texel 0. Applied LAST so it wins over the limit select. --
    v_mov_b32       v18, 0
    v_cmp_lt_i32    vcc, v22, 0
    v_cndmask_b32   v23, v23, v18, vcc
    s_branch        L_U_TAIL

L_U_WRAP:
    v_and_b32       v23, s61, v23           // dim-1; tiles instead of saturating
L_U_TAIL:
    v_mov_b32       v19, v23                // stash tu; the V axis must not touch v19


    // ======================================================================================
    // V AXIS — the same block against Q7/Q8's second half. Straight-line duplicate, on purpose:
    // sharing one routine would need a real call/return, and two copies of proven arithmetic beat
    // a trampoline in a per-pixel path.
    // ======================================================================================
    s_mov_b32       s14, s52                // dv0
    s_mov_b32       s15, s53                // dv1
    s_mov_b32       s16, s54                // dv2
    s_mov_b32       s17, s55                // mv
    s_mov_b32       s18, s58                // limV_lo
    s_mov_b32       s19, s59                // limV_hi
    s_mov_b32       s60, s35                // th
    v_mov_b32       v20, 0
    v_mov_b32       v21, 0
    v_mov_b32       v22, 0

    v_mul_lo_u32    v16, v12, s14
    v_mul_hi_u32    v17, v12, s14
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v13, s14
    v_mul_hi_u32    v17, v13, s14
    v_ashrrev_i32   v18, 31, v13
    v_and_b32       v18, s14, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v8, s15
    v_mul_hi_u32    v17, v8, s15
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v9, s15
    v_mul_hi_u32    v17, v9, s15
    v_ashrrev_i32   v18, 31, v9
    v_and_b32       v18, s15, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_mul_lo_u32    v16, v10, s16
    v_mul_hi_u32    v17, v10, s16
    v_add_co_u32    v20, vcc, v20, v16
    v_addc_co_u32   v21, vcc, v21, v17, vcc
    v_mov_b32       v18, 0
    v_addc_co_u32   v22, vcc, v22, v18, vcc
    v_mul_lo_u32    v16, v11, s16
    v_mul_hi_u32    v17, v11, s16
    v_ashrrev_i32   v18, 31, v11
    v_and_b32       v18, s16, v18
    v_sub_u32       v17, v17, v18
    v_add_co_u32    v21, vcc, v21, v16
    v_addc_co_u32   v22, vcc, v22, v17, vcc

    v_lshrrev_b32   v16, s26, v20
    v_lshlrev_b32   v17, s27, v21
    v_or_b32        v16, v16, v17
    v_lshrrev_b32   v17, s26, v21
    v_lshlrev_b32   v18, s27, v22
    v_or_b32        v17, v17, v18

    v_lshlrev_b32   v28, s30, v16
    s_sub_i32       s61, 32, s30
    v_lshrrev_b32   v29, s61, v16
    v_lshlrev_b32   v30, s30, v17
    v_or_b32        v29, v30, v29
    v_mul_hi_u32    v30, v28, s29
    v_mul_lo_u32    v31, v29, s29
    v_mul_hi_u32    v28, v29, s29
    v_add_co_u32    v30, vcc, v30, v31
    v_addc_co_u32   v28, vcc, 0, v28, vcc
    v_lshlrev_b32   v29, 1, v28
    v_lshrrev_b32   v30, 31, v30
    v_or_b32        v23, v29, v30

    // ⛔ v18 IS REUSED HERE, NOT v19. The first version used v19 as scratch for lo(q1*A2hi) — and
    // v19 HOLDS THE STASHED U INDEX across the V axis. Because A2_hi is 0 for any frame whose area
    // fits 32 bits, that multiply wrote ZERO over tu, and iron came back with texel 0 on every
    // pixel of the 1:1 case. q+1 is dead after this product, so v18 is free to take it.
    v_add_u32       v18, 1, v23
    v_mul_lo_u32    v16, v18, s32
    v_mul_hi_u32    v17, v18, s32
    v_mul_lo_u32    v18, v18, s33
    v_add_u32       v17, v17, v18
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_addc_co_u32   v23, vcc, v23, 0, vcc

    // ⚠ ARITHMETIC shift and SIGNED clamps: q+m goes negative where the UV frame extrapolates
    // below zero, and a logical shift would make that a huge positive index selecting the OPPOSITE
    // edge. texcore clamps such samples to texel 0.
    v_add_u32       v23, s17, v23
    v_ashrrev_i32   v23, 16, v23
    s_sub_i32       s61, s60, 1

    s_and_b32       s62, s31, 4
    s_cmp_eq_u32    s62, 4
    s_cbranch_scc1  L_V_WRAP

    v_max_i32       v23, 0, v23
    v_min_i32       v23, s61, v23

    // -- predicate: N >= limit => the last texel (guards the u32 quotient against wrapping) --
    v_mov_b32       v16, s18
    v_mov_b32       v17, s19
    v_cmp_le_u64    vcc, v[16:17], v[20:21]
    v_mov_b32       v18, s61
    v_cndmask_b32   v23, v23, v18, vcc

    // -- predicate: N < 0 => texel 0. Applied LAST so it wins over the limit select. --
    v_mov_b32       v18, 0
    v_cmp_lt_i32    vcc, v22, 0
    v_cndmask_b32   v23, v23, v18, vcc
    s_branch        L_V_TAIL

L_V_WRAP:
    v_and_b32       v23, s61, v23           // dim-1; tiles instead of saturating
L_V_TAIL:
    // v19 = tu, v23 = tv, both in range: clamped or tiled per the WRAP flag.

    // ======================================================================================
    // THE TEXEL FETCH
    // ======================================================================================
    // ⭐ s_cbranch ON THE FORMAT IS SAFE, AND THAT IS NOT AN ACCIDENT. `fmt` lives in an SGPR, so
    // the branch is WAVE-UNIFORM — every lane takes the same side. This is the one place a scalar
    // branch is legitimate; a per-lane condition here would need an exec mask, which is the trap
    // [[reference_gfx9_per_lane_control_flow]] records.
    v_mul_lo_u32    v7, v23, s34            // tv * tw
    v_add_u32       v7, v7, v19             // + tu   => linear texel index
    // ⛔ TEST BIT 0, NOT THE WHOLE WORD. s31 became a FLAGS word when FULLCOV was added, so the
    // old `s31 == 0` meant "RGBA8 and not fullcov" — an RGBA8 primitive with FULLCOV set (s31 = 2)
    // would have fallen through to the IDX8 fetch and read one byte per texel through a palette
    // that was never supplied. Caught by reading the change, not by a burn.
    s_and_b32       s13, s31, 1
    s_cmp_eq_u32    s13, 0
    s_cbranch_scc0  L_FETCH_IDX8

    v_lshlrev_b32   v7, 2, v7               // RGBA8: 4 bytes per texel
    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_dword v25, v[14:15], off
    s_waitcnt       vmcnt(0)
    s_branch        L_HAVE_TEXEL

L_FETCH_IDX8:
    // ⚠ TWO DEPENDENT FETCHES. The index load must complete before the LUT address exists, so the
    // s_waitcnt between them is load-bearing, not defensive.
    v_mov_b32       v14, s44
    v_mov_b32       v15, s45
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_ubyte v25, v[14:15], off
    s_waitcnt       vmcnt(0)
    v_lshlrev_b32   v7, 2, v25              // index * 4 into the 256-entry LUT
    v_mov_b32       v14, s46
    v_mov_b32       v15, s47
    v_add_co_u32    v14, vcc, v14, v7
    v_addc_co_u32   v15, vcc, v15, 0, vcc
    global_load_dword v25, v[14:15], off
    s_waitcnt       vmcnt(0)

L_HAVE_TEXEL:
    // ======================================================================================
    // COVERAGE MODULATION, then SRC-OVER — the destination address is formed only now
    // ======================================================================================
    v_mov_b32       v7, s9                  // py
    v_mul_lo_u32    v7, v7, s4              // py * pitch (BYTES)
    v_lshlrev_b32   v14, 2, v1
    v_add_u32       v7, v7, v14
    v_mov_b32       v2, s2
    v_mov_b32       v3, s3
    v_add_co_u32    v2, vcc, v2, v7
    v_addc_co_u32   v3, vcc, v3, 0, vcc
    global_load_dword v15, v[2:3], off
    s_waitcnt       vmcnt(0)

    // ⛔ THE /255 IS THE BIT-IDENTITY HINGE. `(x*a + 127) >> 8` is NOT the same function as
    // `(x*a + 127) / 255`; rung 11 established that the exact divide decides whether byte-identity
    // is achievable at all. Both loops below use the reciprocal identity
    //     floor(x/255) = (x + (x>>8) + 1) >> 8   for x < 2^24
    // and the inputs here peak at 255*255 + 127 = 65152, four orders inside that bound.
    v_mov_b32       v26, 0                  // src accumulator
    v_mov_b32       v27, 0xFF               // qa, alpha's quotient (255 until alpha is computed)
    s_mov_b32       s45, 24                 // ALPHA FIRST, so qa is live to clamp r/g/b against

L_MOD:
    v_lshrrev_b32   v14, s45, v25
    v_and_b32       v14, 0xFF, v14
    v_mul_lo_u32    v14, v14, v4            // * coverage
    v_add_u32       v14, 0x7F, v14
    v_lshrrev_b32   v16, 8, v14
    v_add_u32       v14, v14, v16
    v_add_u32       v14, 1, v14
    v_lshrrev_b32   v14, 8, v14
    v_min_u32       v14, 0xFF, v14
    s_cmp_eq_u32    s45, 24
    s_cselect_b64   s[62:63], -1, 0
    v_cndmask_b32   v27, v27, v14, s[62:63] // on the alpha pass, qa := q
    v_min_u32       v14, v14, v27           // premultiplied invariant: no channel exceeds alpha
    v_lshlrev_b32   v14, s45, v14
    v_or_b32        v26, v26, v14
    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_MOD

    // ---- out = src + dst * (255 - src_a) / 255, per channel ----
    v_lshrrev_b32   v28, 24, v26
    v_and_b32       v28, 0xFF, v28
    v_sub_u32       v28, 0xFF, v28          // inv = 255 - src_a
    v_mov_b32       v31, 0
    s_mov_b32       s45, 24

L_OVER:
    v_lshrrev_b32   v29, s45, v15
    v_and_b32       v29, 0xFF, v29          // dst channel
    v_mul_lo_u32    v29, v29, v28
    v_add_u32       v29, 0x7F, v29
    v_lshrrev_b32   v30, 8, v29
    v_add_u32       v30, v29, v30
    v_add_u32       v30, 1, v30
    v_lshrrev_b32   v30, 8, v30
    v_lshrrev_b32   v29, s45, v26
    v_and_b32       v29, 0xFF, v29          // src channel
    v_add_u32       v30, v29, v30
    v_min_u32       v30, 0xFF, v30
    v_lshlrev_b32   v30, s45, v30
    v_or_b32        v31, v31, v30
    s_sub_i32       s45, s45, 8
    s_cmp_ge_i32    s45, 0
    s_cbranch_scc1  L_OVER

    global_store_dword v[2:3], v31, off
    s_waitcnt       vmcnt(0)

L_END:
    s_endpgm

.section .rodata,"a"
.p2align 6
.amdhsa_kernel tex_list
    .amdhsa_group_segment_fixed_size 0
    .amdhsa_private_segment_fixed_size 0
    .amdhsa_kernarg_size 48
    .amdhsa_user_sgpr_count 8
    .amdhsa_user_sgpr_kernarg_segment_ptr 0
    .amdhsa_system_sgpr_workgroup_id_x 1
    .amdhsa_system_sgpr_workgroup_id_y 1
    .amdhsa_system_vgpr_workitem_id 0
    .amdhsa_next_free_vgpr 32
    .amdhsa_next_free_sgpr 64
    .amdhsa_reserve_vcc 1
    .amdhsa_float_round_mode_32 0
    .amdhsa_float_round_mode_16_64 0
    .amdhsa_float_denorm_mode_32 0
    .amdhsa_float_denorm_mode_16_64 3
    .amdhsa_dx10_clamp 1
    .amdhsa_ieee_mode 1
.end_amdhsa_kernel
