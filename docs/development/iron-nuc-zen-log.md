
---

## <a name="tracker-15630-depth-test"></a>tracker-15630-depth-test — RUNG 17: THE DEPTH TEST'S FIRST CONTACT WITH SILICON (1.56.30)

**Written BEFORE the flash.** Every branch below is pre-registered, because on this rung *every*
failure mode presents as order-dependence — which is also the trigger for a much larger rewrite, and
guessing between them at 2am is how the audio arc spent ~24 un-adjudicable burns.

**Artifact**: AGNOS 1.56.30 bare · `kernel/shaders/tri_depth.s`, 116 dwords, `RSRC1 = 0x002C0187`,
`RSRC2 = 0x00000190` (both harvested from the assembled descriptor, not hand-counted).

**Run order** — `--cov` FIRST. A regression there invalidates everything after it.
```
run /bin/gputri --cov        must STILL be 20 of 20
run /bin/gputri --depth      the rung
run /bin/klug > /depth3.txt
```

### The hypothesis

Two interpenetrating triangles, submitted in BOTH orders, produce byte-identical colour **and depth**,
and both match the CPU reference. One workgroup owns an 8×8 tile and walks the whole triangle list in
submission order in a single 64-lane wave, holding colour and z in registers — deterministic with no
atomics and no binning.

### What makes this burn able to FAIL — read this before trusting a green

⛔ **The order-independence oracle is measurably blind to the one thing this rung adds.** Measured on
the host, on the shipped corpus:

| broken implementation | orders differ | colour vs ref | **z wrong** |
|---|---|---|---|
| divide one ULP short (4 models) | **0** | **0 of 1024** | — |
| the reciprocal's correction dropped | **0** | **0** | 19 px |
| uniform z bias, any k in 1..64 | **0** | **0** | **507 of 507** |
| triangle list walked BACKWARDS | **0** | **0** | 0 |

⇒ the arm reads **z back through op `0x10`** and compares it too. Colour-only, this burn cannot fail
on a broken divide, which is the rung's entire novel content. `burn-prep` refuses to stage a `gputri`
lacking that readback.

### Pre-registered predictions

1. `gputri --cov` is **20 of 20**. (Regression control — if this moves, stop and read nothing else.)
2. `gputri --depth` exits **95**.
3. Colour differs between the two submission orders at **0 px**, and z at **0 px**.
4. Colour vs the CPU reference **0 px**; z vs the CPU reference **0 px**.
5. All 1024 lane-witness words are self-consistent — the word at index *i* says it belongs at *i* —
   and every word 1 is still `0xDEADBEEF`.

### The diagnostic rubric — WHICH failure, not just "it failed"

Every exit code below is distinct precisely because the fixes differ:

| symptom | exit | read it as | do NOT |
|---|---|---|---|
| a few px differ between orders | 94 | precision / a tie → the divide or the corner bound | escalate to atomics |
| **whole tiles** differ | 94 | a wave branch or monotone lane loss → **emission** | blame serialisation |
| the tile's top row replicated 8× | 91/92 | the row index was computed in SALU (`py` is per-lane here for the first time in this tree) | — |
| tiles show only background | 91 | a scratch write clobbered `v3`/`v4`, **or** a signed/unsigned sentinel inversion | read it as "the depth test rejected everything" |
| colour matches, **z** does not | 92 | the divide, the reciprocal, or the corner bound | call it a store bug |
| all witnesses poison | 93 | no wave ran — residency, arm, RSRC1, or a zero grid | — |
| scattered witness dropouts | 93 | register aliasing | call it a race yet — see below |
| two identical frames differ | 94 | **re-run with the grid forced to one workgroup.** If determinism returns it is aliasing / RSRC1, **not** a race, and no atomics rewrite is warranted | rewrite TD-5 |

⛔ **A blank frame passes the both-orders oracle.** Two empty images are byte-identical, so `--depth`
counts touched pixels first and returns **88** if the shader wrote nothing. The specific way to get a
blank frame here is a **signed** depth compare: the hardware far value `0xFFFFFFFF` reads as −1, the
nearest possible depth, so no fragment ever passes. That is pinned unsigned in the shader and
`depthmodel` renders both to prove the difference (unsigned draws 507 px, signed draws 0).

### Coverage, stated before the burn rather than discovered after it

Of the 16 dispatch tiles in the 32×32 corpus, only **7** contain a dual-covered pixel and can
therefore distinguish depth from painter's order. **9** prove nothing about z. **2 are entirely
empty** and are byte-identical for a shader that never ran in them. "Three tiles wrong" is a signal;
"nine tiles identical" is not.

### ✅✅ RESULT — CLOSED ON IRON 2026-07-29, exit 95, in TWO burns

`gputri --cov` **20 of 20** (regression control held). `gputri --depth` **exit 95**:

```
witness -- 0 poison, 0 mislabelled, 0 stray word-1 writes
colour buffer touched at 1024 of 1024 px
both submission orders -- colour differs at 0 px, z differs at 0 px
vs the CPU reference -- colour 0 px differ, z 0 px differ
```

**All five pre-registered predictions confirmed.** Depth-tested triangle rasterisation runs on gfx90c:
one workgroup per 8×8 tile, one 64-lane wave, colour and z held in registers across the triangle
loop, one store each at the end. Deterministic **without atomics and without a binning pass** — TD-5's
escalation was never needed.

### ⛔⛔ BURN 1 WAS RED, AND THE WAY IT WAS RED IS THE FINDING

Burn 1 returned **exit 91** with a signature that passed every axis the rung was designed around:

```
witness -- 0 poison, 0 mislabelled, 0 stray word-1 writes     <- the wave ran, addressing correct
colour buffer touched at 1024 of 1024 px                      <- it wrote everywhere
both submission orders -- colour differs at 0 px, z differs at 0 px   <- THE ORACLE PASSED
vs the CPU reference -- colour 1024 px differ, z 1024 px differ       <- and every pixel was wrong
```

**Cause**: `gpu_blend_cov_run` emits USER_DATA as `mask_mc lo/hi, dst_mc lo/hi, mask_pitch, dst_pitch,
width, color`, so the worker's `n_tri` lands in **s4** and the framebuffer pitch in **s5**. The shader
read them swapped. The triangle loop therefore ran `pitch` = **3328** times, walking off the end of
the prep array into zeroed arena — where `area == 0` makes all three edge tests `0 <= 0`, i.e. inside
on every lane — and painted a uniform frame, while the colour row stride became **2 bytes**.

⇒ **A wave-uniform misread of a kernarg is deterministic by construction, so NO order-independence or
determinism test can ever see one.** The rung's own oracle was green on a completely wrong frame. What
caught it was the comparison against the CPU reference — which is only possible because the arm reads
the render target back through op `0x10`.

⭐ **This is the second time in two rungs that the oracle passed and an external comparison caught the
defect** (rung 15's half-texel was the first). The pattern is now explicit: **agreement between the
shader and anything co-designed with it is not evidence.** At least one gate must compare against
something that shares no premise — an independently burned path, an analytic invariant, or a readback.

⚠ **And it was invisible to everything cheaper than a burn**: it assembled cleanly under llvm-mc,
matched its committed blob byte-for-byte, and left all 22 host gates green — because none of them can
see across the kernarg boundary. The host model has no kernargs; the assembler does not know what the
caller passes. ⇒ `scripts/check/tridepth-contract.sh` now asserts the contract as the two instructions
that consume it (`s_cmp_lt_u32 s12, s4` at both loop sites, `v_mul_lo_u32 v18, v17, s5` for the row
stride), plus the loop-carried-register span check. Mutation-tested by reverting the exact defect.

⇒ **Carry-forward for rung 18 and every future kernel dispatched through a shared primitive**: the
kernarg mapping is a CONTRACT between two files that no compiler checks. Assert it mechanically, or
pay a burn to learn it.

---

## <a name="tracker-15631-persp"></a>tracker-15631-persp — RUNG 18: PERSPECTIVE-CORRECT TEXTURING'S FIRST CONTACT WITH SILICON (1.56.31)

**Written BEFORE the flash.** Rung 17 needed two burns because its first failure looked like a pass on
every axis the rung was designed around. Every branch below is pre-registered.

**Artifact**: AGNOS 1.56.31 · `kernel/shaders/tri_persp.s`, 195 dwords, `RSRC1 = 0x002C01C7` /
`RSRC2 = 0x00000190`, both **harvested** from the assembled descriptor. ⚠ The predicted RSRC1 was
`0x002C0187` and was **wrong** — 56 SGPRs against rung 17's 48.

**Run order** — `--cov` FIRST; a regression there invalidates everything after it.
```
run /bin/gputri --cov        must STILL be 20 of 20
run /bin/gputri --depth      rung 17 regression: must STILL be exit 95
run /bin/gputri --persp      the rung
run /bin/klug > /persp1.txt
```

### The hypothesis

A checkerboarded floor quad in 16:1 perspective, textured with per-pixel perspective-correct
coordinates: numerator and denominator each hoisted to an affine plane, an exact 56-iteration restoring
divide per attribute, no `v_rcp_f32` anywhere.

### ⭐⭐ What makes this burn able to FAIL — the oracle is a DISCRIMINATION

Matching the perspective reference is **necessary and not sufficient.** A shader that skipped the divide
produces the *affine* answer, so `--persp` compares against **both** references and requires:

| | required |
|---|---|
| vs the PERSPECTIVE reference | **0** of ~1541 covered px differ |
| vs the AFFINE reference | **more than half** must differ |

Measured on the host before the shader existed: affine differs at **1540 of 1541** px, worst by
9,902,774 in 16.16 (~151 texels). ⛔ Without the second row a green result is consistent with the divide
never happening — the null-set trap rung 17's corpus fell into, where a one-ULP divide error moved
**0 of 1024** pixels. `burn-prep` refuses to stage a `gputri` lacking either comparison.

### Pre-registered predictions

1. `gputri --cov` is **20 of 20**, and `--depth` is still **exit 95**. (Regression controls — if either
   moves, stop.)
2. `--persp` exits **95**.
3. vs perspective: **0** differing covered px.
4. vs affine: **> 770** differing covered px (half of ~1541).
5. The buffer is touched at all 4096 px — this op REPLACES its rect, and bg is stored where nothing is
   covered via the accumulated-coverage predicate.

### The diagnostic rubric — WHICH failure, not just "it failed"

| symptom | exit | read it as | do NOT |
|---|---|---|---|
| matches affine closely | **87** | the divide did not run — check the record's D plane and the restoring loop, not the geometry | conclude the hoist is wrong |
| differs from perspective by a few px | 86 | precision — the divide or the 64-bit carry chain | rewrite the interpolation |
| differs from perspective by ~all px | 86 | a kernarg misread or a plane swapped — `triper-contract.sh` gates the first, so suspect the record layout | assume the shader is wrong before checking prep |
| a one-texel SEAM along triangle edges | 86 | the 64-bit accumulate lost its carry — `perspmodel`'s M1 measures this at 312 px | call it a fill-rule problem |
| horizontal streaking | 86 | the row index was computed wave-uniformly; `py` is per-lane here | blame the store address |
| garbage outside the geometry | 86 | the accumulated-coverage predicate — bg is not reaching uncovered lanes | blame the texture fetch |
| nothing written | 88 | residency, arm, RSRC1, or a zero grid | — |

⛔ **A wave-uniform kernarg misread is deterministic**, so no determinism or repeatability test can see
one. That is why the reference comparison — not repeatability — is the oracle here, and why the affine
row exists beside it.

### ⛔ Burn 1 — exit 100, and the defect was in the INSTRUMENT, not the kernel

```
gputri --cov     20 of 20                    <- regression control held
gputri --depth   exit 95                     <- rung 17 still correct
gputri --persp   exit 100, nothing after the banner
```

Exit 100 means "no GPU" — and there plainly was one, since `--depth` had just passed on the same boot.

**Cause: two undersized buffers in `gputri.cyr`.** Module-scope `var X[N]` is **N × u64 = 8N bytes**.
`pp_tex` was declared `[16384]` = 131,072 B for a 256×256×4 = **262,144 B** texture — half — and
`pp_got` was `[512]` = 4,096 B for a 64×64×4 = **16,384 B** readback — a quarter. `pp_checker()` runs
*before* the allocations and overflowed `pp_tex` by 128 KB into whatever follows in BSS, so the
triangle count came back corrupted and `shm_create_gpu(n*64)` was called with a bad size.

⚠ **`check-array-sizing.sh` could not catch it, and that is not a gap in the gate.** It covers
FUNCTION-LOCAL arrays at LITERAL offsets; these are module-scope with computed offsets, and the gate's
own header already says a clean run is not proof of absence. ⇒ the cover is a **runtime** guard
(`pp_size_ok`) that ties each declared size to the bytes the arm will actually write — the two are
literals and computations respectively, and nothing in the language relates them.

⚠ And a second, smaller lesson: a bare shared exit code cannot distinguish three different allocation
failures. Each `shm_create_gpu` call now names itself and its size before returning.

⭐ **This burn was still worth its cost as a regression control**: `--cov` 20/20 and `--depth` exit 95
on the 1.56.31 kernel prove rungs 9b and 17 survive everything rung 18 added — the ABI growth, the new
op, the sixth resident blob and the arena slots.

**Re-flash**: tool-only change, but the oracle is `run /bin/<tool>`, so `--update-all`.

### ⛔⛔ Burn 2 — exit 86, and the READING of the numbers is the finding

```
gputri --cov     20 of 20            <- control held
gputri --depth   exit 95             <- control held
gputri --persp   buffer touched at 4096 of 4096 px
                 vs PERSPECTIVE reference 748 of 1541 covered px differ
                 vs AFFINE      reference 769 of 1541 covered px differ
                 exit 86
```

⭐ **748 and 769 out of 1541, with half being 770.** The output is essentially EQUIDISTANT from both
references — which on a two-colour checkerboard is what "uncorrelated with either" looks like, since a
coordinate landing anywhere at random matches ~50% of the time. ⇒ this is **not** a precision defect and
**not** a missing divide; the texture coordinates are garbage. The affine row is what establishes that:
had the divide simply not run, `vs AFFINE` would have been ~0 and `vs PERSPECTIVE` ~1540.

**Cause: a 32-byte skew between prep and the shader.**

| | stride | shader steps past the header | prep writes record 0 at |
|---|---|---|---|
| rung 17 | 64 | 64 | +64 ✓ |
| rung 18 | **96** | **64** | **+96** ✗ |

The header occupies one record slot, so the shader's `s_add_u32 s0, s0, N` and `GPU_TPER_PREP_STRIDE`
are the same number. Rung 17's stride is 64; its `s_add_u32 s0, s0, 64` was copied into a kernel whose
stride is 96, so every record read began 32 bytes early — the header's tail followed by record 0's head,
interpreted as `A0 B0 C0 A1 ...`.

⚠ **Nothing on the host could see it.** The assembler does not know the stride; prep does not know what
the shader steps; the blob gate compares the shader to itself; and both `perspcore` and `perspmodel`
compute from coefficients rather than from a record at an offset. It is a contract between two files,
like the kernarg order that cost rung 17 a burn — the same shape, one bite later.

⇒ `scripts/check/triper-contract.sh` **CHECK 3** now reads `GPU_TPER_PREP_STRIDE` out of `gpu_regs.cyr`
and requires exactly two `s_add_u32 s0, s0, <stride>` in the shader (header step + loop tail).
Mutation-tested by restoring the 64 and watching it go red.

⭐ **The rubric worked.** "differs from perspective by ~all px → suspect the record layout, not the
shader" was written before the flash and pointed straight at it.

### ✅ Burn 3 — THE SHADER IS CORRECT. `vs PERSPECTIVE 0 of 1541`. The arm misread it.

```
gputri --cov     20 of 20                                      <- control held
gputri --depth   exit 95                                       <- control held
gputri --persp   buffer touched at 4096 of 4096 px
                 vs PERSPECTIVE reference   0 of 1541 covered px differ
                 vs AFFINE      reference 731 of 1541 covered px differ
                 exit 87  "MATCHES THE AFFINE REFERENCE too closely"
```

⭐⭐ **`vs PERSPECTIVE = 0` is the result.** Perspective-correct textured rasterisation is byte-identical
to the CPU reference at every covered pixel on gfx90c: a 64-bit numerator in a register pair, an exact
56-iteration restoring divide per attribute, no `v_rcp_f32` anywhere. The verdict line is wrong; the
render is not.

### ⛔ The defect is an ANALYSIS error in the arm — two different quantities, one threshold

The arm required `da > checked/2` and got 731 against a half of 770. That threshold came from
`perspgate`'s P2: *"affine differs at 1540 of 1541"*. **But P2 measures COORDINATE divergence and the arm
compares TEXELS.** After sampling a 16×16-cell checkerboard, most differing coordinates land in the same
cell and return the same colour. The textured figure is smaller by exactly the cell size.

⭐ **Confirmed by measurement, not by argument**: `perspgate`'s new **P7** applies the identical
checkerboard fetch to both references on the host and measures **731 of 1541** — the number the GPU
produced, to the pixel. The GPU matched the perspective reference exactly AND diverged from affine
exactly as much as the reference itself does.

### ⇒ The discrimination belongs on the CORPUS, not on the GPU comparison

Once `dp == 0`, the divide provably ran: the GPU matched, at every covered pixel, a reference that
samples different texels from the affine answer at 731 of them. A shader that skipped the divide cannot
do that. So the arm now:

1. computes `expect_da` — how far the two REFERENCES are from each other after texturing — and **refuses
   to judge the GPU at all** if that is small, because then a match would prove nothing;
2. requires `dp == 0`;
3. requires `da == expect_da` exactly, as a consistency check that the arm's references agree with its
   own comparison.

⚠ The old form could call a correct shader broken. The new one cannot: every threshold is a measured
quantity of the corpus rather than a fraction chosen by hand.
