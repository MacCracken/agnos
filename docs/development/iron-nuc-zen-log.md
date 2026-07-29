
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
