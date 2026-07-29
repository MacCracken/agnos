---
name: AGNOS Kernel State
description: Live state of the AGNOS kernel — version, sizes, sibling pins, subsystem rollup, in-flight slots. Refreshed every release.
type: state
---

# AGNOS — Live State

> **Last refresh**: 2026-07-28 · kernel head **1.56.30** (open; 1.56.29 closed — rung 15 iron-validated) · **▶ ACTIVE — 1.56.x GPU (the one open GPU release; there is no 1.57/1.58/1.59).** Full plan + reference:
[`docs/development/planning/gpu.md`](planning/gpu.md) — the single GPU document. **DONE and shipped:**
(1) **the ring-3 GPU band has consumers** — aethersafha composites on the GPU (opaque via `#87`, translucent
via `#92` op 0x01 premultiplied src-over), unblocked by setu 0.6.0/0.7.0 asking `shm_create_gpu` #86 (the
root blocker was memory: #71 = system RAM the GPU can't reach, NOT the alpha convention). Full premultiplied
chain shipped across 10 repos on cyrius 6.4.71 (setu 0.7.0 · aethersafha 0.9.7 · sadish 0.5.0 · dhancha 0.9.2
· rekha 0.3.3 · rupa 0.1.1 · bhumi 1.1.1 · crab 0.4.2 · jalwa 1.4.2 · puka 0.6.6). (2) **Shader ISA is
sovereign** — all **17** `.s`-backed kernels reference-verified byte-identical to their committed hex (the
count was 11 at 1.56.7; six landed since — edge_setup, edge_cov, tri_rgba, tex_rgba, tex_list, tex_list_cm);
the **llvm-mc BUILD gate was REMOVED (1.56.8)** because llvm-mc is C++ and a sovereign build depends on no
C/C++ toolchain (sovereign assembler = mabda's Cyrius `gfx9_encode.cyr`). ⚠ **But llvm-mc came back as a
CHECK tool and nobody noticed:** `scripts/check/shader-blob.sh:31-34` hard-requires `llvm-mc` + `llvm-objcopy`
and `exit 2`s without them, and `scripts/check.sh:86-90` treats exit 2 as drift — so **`check.sh` goes RED on
a box with no LLVM**, quietly reversing ratified decision D-1. Also only **6 of the 17** blobs are gated at
all (all 17 currently match; it is a coverage gap, not a break). Both are cut 1.56.24. (3) **D-1/D-2/D-4 ratified (1.56.8):**
llvm-mc rejected; `#92` blend = premultiplied f32, frozen; whole-surface translucency IS a real MUDRA/SHANTA
requirement → DCN second plane stays a live deferred item. **REMAINING — rebuilt 2026-07-28 as numbered cuts; see [`planning/gpu.md`](planning/gpu.md) § release plan. ⛔ The previous text here was materially false and three agents planned against it:** it called MODESET "recommended next, own the pipe from cold" when **the live-pipe modeset is DONE** (M1-M6 iron-closed 1.56.11/1.56.12; item 7's own criterion `OTG_MASTER_EN` 0→1 met at 1.56.12 — frame counter 2615→0→115, panel blanked and relit), and it twice promised an "L1 discriminator runs first, free" that **had already run and returned VOID** (2026-07-24/25; the positive control did not sound, so it carries zero information — never write it up as "sequencing exonerated"). **✅ 1.56.24 DONE** (zero burns: four real correctness defects + this ledger). **✅ 1.56.25 DONE** (zero burns: dead-code removal + the `EDGE_CAP_PROBE` burn-trap — a profile that built a kernel byte-identical to the default while telling the operator otherwise). **✅✅ 1.56.26 CLOSED ON IRON 2026-07-28** — `F` is **PER-PRIMITIVE, 7.35 µs each**, all of it in `gpu_texl_build`/`gpu_tex_prep` (build is 117× the validate slope). A 640-column DOOM frame carries **4.71 ms of CPU** that no transpose removes; **the GPU is no longer the bottleneck, the CPU prep is, by 52×**. **✅ 1.56.27 + ✅✅ 1.56.28 BOTH CLOSED ON IRON 2026-07-28 — `gpu_tex_prep` IS DONE.** The arena is
**UC-mapped**, and the prep record was costing **76 uncached stores/prim**. Two cuts: narrow the
zero-fill (76→40, predicted 3.84 / **measured 4.21**) then pair into `store64` (40→20, predicted 2.50 /
**measured 2.487**). **DOOM CPU 4.71 → 1.61 ms; total `#92` at n=256 3248 → 1421 µs, 2.29×.**
Corroborated independently by `gputex`'s op 0x0C window (216 → 160 µs = 1.75 µs/prim vs a build-slope
delta of 1.72). Model, fitted across three store counts: **~86 ns per UC store + 0.79 µs of real
arithmetic** ⇒ 2.487 is within ~3× of the floor, the last 20 stores need 128-bit stores the FP-free
kernel posture bars, so **further work here is low-yield — STOP.**
⛔ The scoped *"cached scratch + bulk copy"* follow-on is **STRUCK, not deferred**: `memcpy` copies its
aligned bulk with `store64`, so it produces the identical 20 UC transactions plus an extra pass.
⛔⛔ **AND THE PRE-REGISTERED CONTROL FAILED ON 1.56.28** — `wait` was written down as must-not-move and
fell 51%. A global GPU speed-up is ruled out (`gputex`'s pure-GPU bench unchanged: 52.0→50.0 µs) and the
drop is concentrated at high n (`wait @ n=32` +6%, `@ n=256` −43%), so `wait` most likely carries
**CPU memory-controller backlog from the record writes themselves** — i.e. it was a **badly designed
control, not a bonus**. ⚠ `build` and `wait` deltas came out *exactly* equal (557 µs); unexplained,
needs a third primitive count, do not build on it. **⇒ `wait` is not a clean GPU-time measurement at
high primitive counts and must not be cited as one until it has an independent control.**
**▶ 1.56.29 OPEN — RUNG 15 `bilinear`. THE BLOB IS LANDED; ONE ITEM LEFT (the iron oracle).**
✅ `kernel/shaders/tex_bilin.s`, **580 dwords**, resident at `GPU_TEXBI_SHADER_SUBOFF = 0x5D000`,
dispatched under a **separate** `GPU_COMPUTE_PGM_RSRC1_TEXBI = 0x00AC020B` (48 VGPRs) — *not* a widened
`RSRC1_TEX`, which is shared by two iron-proven paths. **INTEGER 4-tap, zero `v_cvt`**: the float plan
was dropped because with 8-bit weights the filter is *exact* (weight sum exactly 65536 for all 65,536
`(fx,fy)`; accumulator peaks at 16,711,680, inside a 32-bit lane), so the row's named rounding risk is
**eliminated, not mitigated**. ⭐ The prep record is **unchanged** — the fraction was already in the
16.16 coordinate rung 13 discarded — so this rung adds **zero** UC stores to the CPU cost 1.56.27/28
just cut 4×. ✅ ABI flag flipped reserved→accepted **in the same change as the blob** (battery
**94/94**); `check.sh` **20/20**; `bigate`/`bimodel` now actually RUN (they were cited but executed by
nothing); `texbi-body-identity.sh` proves rung 13's head AND tail survive verbatim, mutation-tested
four ways. ⚠ **NOT YET IRON-VALIDATED.**
✅ **THE `gputex` BILINEAR ARM IS LANDED TOO** — CLAMP path (where both ordering traps are
observable, unlike WRAP), byte-identity vs `bicore`, plus a **discrimination gate**: the run FAILS if
the GPU's output is identical to the *nearest* reference on every frame, because a kernel that
silently dispatched the rung-13 blob would otherwise score a perfect green. Gated on the TOTAL, not
per-frame — frame 0 is the 1:1 case where bilinear MUST equal nearest (bigate G2 on iron).
⭐ **PRE-BURN FINDING THAT MAKES THE BURN INTERPRETABLE: bilinear reads 8 quotient bits nothing had
ever compared.** Nearest consumes only `uv >>> 16`, so rungs 13/14's 17/17 record proves the shader's
reciprocal agrees with an exact divide **in the high half only**. `texgate` **gate 7** compares the
whole 16.16 word — **5140 quotients, ZERO differ** — and **gate 8** proves it connected: the exact
correction moves **3151 quotients** where gate 6 measured only **186 texels**, i.e. **17× more error
hidden by nearest than exposed by it**. ⇒ **A RED BILINEAR BURN IS THE BLEND, NOT THE DIVIDER.**
Gates 9/10 give the new four-tap addressing its first oracle (2178 samples, WRAP+CLAMP, negative and
multi-tile UV; corner-exact at all 64 texel centres). `burn-prep.sh` refuses to flash a `gputex`
lacking the bilinear arm **or** its discrimination check — a pre-1.56.29 binary passes every
col-major string and exits 95 with zero bilinear data.
⛔⛔ **THE BURN RAN 2026-07-28 AND FOUND A REAL DEFECT *THROUGH A GREEN RESULT*.** `gputex` reported
**BILINEAR 5 of 5 EXACT** — and the filter was still wrong. Frame 0 (the 1:1 identity frame) reported
`vs NEAREST: 35 px differ`, **falsifying pre-registered prediction 3**. A bilinear filter at exact
1:1 magnification must reproduce the texture EXACTLY. The taps were coming from `floor(u)`/`frac(u)`;
they must come from **`floor(u - 0.5)`/`frac(u - 0.5)`**.
⭐ **CONVENTION-FREE ARGUMENT** (so "our convention differs" was never a defence): for texel *i*'s
centre at *i+c*, correct nearest = `floor(u-c+0.5)` and correct linear taps = `floor(u-c)` — differing
by **exactly 0.5 for every c**. AGNOS shipped both as `floor(u)`, a difference of ZERO. Not a matched
pair under ANY convention; nearest is pinned to iron 17/17, so linear moved. Adjudicated by four
independent analyses + three adversarial refuters — **0 of 3 could refute it**.
✅ **FIXED** (1.56.29, same open cycle): `v_add_u32 v23, 0xFFFF8000, v23` per axis in `tex_bilin.s`
(580 → **584 dwords**, no new VGPR, RSRC1 unchanged), `BI_HALF` in `bicore`, matching bias in
`texcore`'s `tex_fetch_bilin` and `bimodel`'s `bm_sample`. ⛔ **NOT** folded into `gpu_tex_prep`'s
`mu`/`mv` — looks free, is not: `limu` is *derived* from `mu`, so it would shift the out-of-domain
predicate half a texel. Nearest untouched.
⛔⛔ **THE LESSON, which outlives the bug: byte-identity between a shader and its reference is
STRUCTURALLY BLIND to an error the two SHARE.** All four implementations carried the same wrong
convention, so all agreed and every gate built on their agreement went green. Worse — `bigate` G2 and
`texgate` GATE 10a probed **exact integer coordinates**, but `tex_uv_at` always adds 32768 for the
pixel centre, so **a pixel-centre rasteriser can never emit an integer u at any integer scale**: they
were collecting evidence on the null set of the error, and 10a actively *asserted* the bug. The only
thing that caught it was the **discrimination gate** (`vs NEAREST`), the one measurement comparing
against something other than the reference. ⇒ **At least one gate must test an EXTERNAL invariant.**
New: `texgate` **GATE 11** (absolute — bilinear at 1:1 == the source texture, via `tex_uv_at`) and
**GATE 12** (falsifies it, breaks 63/64); GATE 10 inverted; `bigate` G2 re-anchored + G2b;
`bimodel` **M6**; `gputex` now asserts frame 0 == 0 and `burn-prep` enforces its presence.
✅✅ **RE-BURN 2026-07-28 (`tex2.txt`): RUNG 15 IS CLOSED AND IRON-VALIDATED — all four predictions
hold.** `gputri --cov` 20/20; `gputex` **exit 95**, BILINEAR **5 of 5 EXACT**, and **frame 0 reports
`vs NEAREST: 0`** (was 35) — the falsified prediction now CONFIRMED. ⭐ `exit 95` is itself the
assertion passing: the new 1:1-identity gate returns 86 on a single differing pixel, so a green exit
is positive evidence rather than the absence of evidence it was on burn 1. The golden data moved on
all five frames as predicted (89→86, 300→278, 208→202, 119→114; total 751→**680**) because the
reference moved with the shader — frame 0 is the only number that could adjudicate anything, because
it is pinned by an EXTERNAL invariant rather than by agreement with a reference.
⚠ **Carry-forward**: the rung-closure debt is now **seven** rungs ahead of a shipped consumer (rule 2
says one). 1.56.32's item, and this close made it one worse.
⛔ **THE TRAP CLASS THIS RUNG KEEPS PRODUCING: correct under WRAP, wrong under CLAMP.** Three instances
now — the M2 shift kind, the `+1` neighbour needing the **pre-clamp floor**, and the out-of-domain
predicates needing to fire on **both** taps. A wrap-only suite sees none of them. Anyone adding a
coordinate transform here must sweep CLAMP too.
**▶ 1.56.30 OPEN — RUNG 17 `depth` IS GATED ON RUNG 6, WHICH WAS NEVER RUN.**
Verified from source: `GPU_OP_SUPPORTED = 0x1F1F`, `0x0D` free, mask grows to `0x3F1F`. ⚠ That mask is
BOTH the validator gate and what `gpu_caps` #89 advertises, so growing it ADVERTISES the op —
accepted-must-equal-proven means the worker lands in the same change.
⛔ **CORRECTION, recorded because the mistake is instructive:** a first pass measured `GPU_ARENA_SIZE`
(2 MB, 48 KB + 60 KB free) and reported "nowhere to put Z" as an open decision. **Wrong arena.**
`GPU_ARENA` is the command/shader/scratch carveout; **TD-3 already ratified** that render targets live
in a SEPARATE **256 MB region at `GPU_RT_REGION_OFF = 0xB0000000`** (8 handles x 32 MB, fits
2560x1440x4 colour + depth, ending at the 3 GB carveout top so an overrun hits the fault net). The
answer was in the decision table; the arithmetic was measuring the wrong region.
⛔ **THE REAL BLOCKER: TD-3 WAS NEVER BUILT.** `GPU_RT_REGION_OFF` appears **nowhere in
`kernel/core/*.cyr`**, and **rung 6 `arena-audit` has never run** — the read-only iron check that
`[GPU_RT_REGION_OFF, carveout_top)` is genuinely unclaimed. Its own note gates this exactly: *"Region
not free ⇒ TD-3 has nowhere to live."* ⚠ With `VM_CONTEXT0` disabled there are **no page tables**, so
an OOB store lands somewhere real — "free" must be MEASURED.
⭐ **Why it hid for six rungs:** rung 6's note says a failure stalls Phase II "at rung 11", yet
rungs 11-16 all shipped — they fit the 2 MB arena. **Rung 17 is the first rung whose buffer does not.**
✅✅ **RUNG 6 CLOSED AND IRON-VALIDATED (`tex3.txt`, 2026-07-28) — all four predictions confirmed.**
`gpuwedge --rt-audit` exit 95, `RT AUDIT PASS`. Region `[0xB0000000, 0xC0000000)` -> phys
`1020000000..1030000000`, and **`1030000000` is exactly the `top=1030000000` the boot path reports
from an INDEPENDENT source** (E820/PMM, nothing to do with `MC_VM_FB_OFFSET`) — two unrelated
witnesses agreeing. ⭐ **Check 7 fired and was informative**: `live scanout mc f400000000` = the
carveout base, i.e. the console FB at offset 0, exactly where the map says. Not zero (which would
have been VOID), not inside the region. TD-3's placement is confirmed against HARDWARE.
✅ **Op `0x0D` DEPTH_CLEAR is live on iron** — minted with its worker, mask `0x1F1F -> 0x3F1F`, ABI
battery **103/103**, gated so nothing can store until the audit passes on that boot.
✅✅ **OP `0x0D` DEPTH_CLEAR IS COMPLETE AND IRON-VALIDATED (`depth2.txt`), after TWO defects the
timing oracle caught on a target that cannot be read back at all.**
**(1) A 262x WORKER BUG.** `gpu_cp_dma_fill_rect` issued **one CP-DMA packet per row with its own
fence wait** (600 packets for 800x600) on a **contiguous** buffer. One `gpu_cp_dma_fill` instead:
32 MB clear **221,875 -> 848 us**. ⭐ The per-row model was confirmed to **0.1%** (108.2 vs 108.3
us/row across two independent rects).
**(2) THE INSTRUMENT TIMING ITSELF.** `gpu_depth_clear` -> `gpu_rt_arm()` runs the whole rung-6 audit
on the FIRST call of a boot, and that audit ends in **`klug_spill()` — a 64 KB ext2 write to NVMe**,
landing INSIDE the first timed loop. ~490 ms of I/O over 20 iterations of ~50 us of real work: the
setup outweighed the measurement **~500x** and INVERTED the ratio. Fixed with a warm-up outside the
timer (worth **189x** of the total improvement by itself); `burn-prep` now refuses to stage a
`gpudepth` lacking it.
⚠ **CORRECTION**: the "89 ms per 800x600 clear / 21 MB/s" figure published mid-arc was contaminated
by that one-time cost. True per-clear was **64.9 ms**. The conclusion was right; the number was not.
⭐ **COST MODEL, now clean**: **86.5 us fixed per dispatch + 22.7 ps/byte = 44.1 GB/s marginal.** A
full 800x600 depth clear is **130 us**, ~0.5% of a 35 Hz frame — not a design constraint on rung 17.
Total arc: 800x600 x20 went **1,788,344 -> 2,602 us = 687x**.
⛔⛔ **THE DISCRIMINATOR WORTH KEEPING — a falsified prediction is a DEFECT or a MODEL ERROR, and the
residual tells you which.** The same prediction (ratio -> 17x) failed on two burns: once with a
**490,462 us residual nothing explained** (a defect — the instrument), once with **zero unexplained
residual**, both points fitting `F + b*bytes` and `F` corroborating two prior independent
measurements (a model error — I assumed fixed cost would vanish; it became SINGULAR, not zero, and is
still 67% of the small clear). **Do not accept "the prediction was optimistic" until the residual is
accounted for.** The two look identical on a scorecard and are not the same event.
⚠ **Carry-forward**: ~86.5 us is now the floor for ANY single fenced CP-DMA op. Rung 17's tile pass
will issue many; a burst of small fills needs batching without a per-op fence — rung 14's fusion
shape. Named so it is not rediscovered.
✅ **RUNG 17's DEPTH REFERENCE + ORDER-INDEPENDENCE GATE LANDED** (`depthcore.cyr` / `depthgate.cyr`,
host, **exit 95, 7 gates**) — the rung's OWN iron oracle is proven sound before a shader exists.
⭐ The reference uses the **SHADER's loop structure** (pixels outer, triangles inner, colour+z per
pixel across the inner loop, stored once), not a convenient equivalent: the other nesting is easier,
gives the same answer here, and would agree for reasons the shader does not share — so it could not
witness the serialisation claim.
⛔⛔ **FOUND WHILE WRITING IT: Z-TIES ARE ORDER-DEPENDENT on ANY correct implementation, hardware
included.** The test is a strict `<`, so at exactly-equal z the FIRST submitted wins (`<=` would give
the LAST). ⇒ **"both orders byte-identical" is NOT universal** — it holds only where every covered
pixel has a strictly unique nearest z. A corpus with one tie would FAIL A CORRECT SHADER on iron and
the burn would chase a defect that is not there. `dc_render` counts ties; **D0a asserts zero**.
Gates: **D0a** no ties · **D0b** 507 px covered (two EMPTY images are byte-identical) · **D0c** red
290 / blue 217 both win (a pair where one occludes the other makes depth indistinguishable from
painter's) · **D1** the oracle · **D2** co-planar MUST go order-dependent, 182 px — D1 is connected ·
**D3** deterministic · **D4** on all 182 shared pixels the nearer won, checked against z **recomputed
from the vertices**, not read from the renderer's own z-buffer.
✅ **THE MODEL LANDED TOO** (`depthmodel.cyr`, **exit 95**) — the **affine hoist** (`A·x+B·y+C` per
edge, `KX·x+KY·y+KC` for the depth numerator, all per-triangle CPU work like rung 13's record) proven
byte-identical to the reference in **colour AND z**, both orders, at 32-bit lane widths (numerator
peaks 2,430,400). Six mutations, all connected.
⭐⭐ **THE RUNG-17 FINDING — z PRECISION IS LOAD-BEARING FOR ORDER-INDEPENDENCE.** Quantising z to 16
levels creates **3 tie px**, and those 3 ties **break order-independence (3 px differ between
orders)**. A tie is decided by SUBMISSION ORDER, so a divide one ULP short does not perturb a pixel —
**it destroys the byte-identity that IS the iron oracle**. ⚠ Three pixels is exactly the size that
reads as noise on iron; the oracle demands byte-identity so that three is a FAILURE, not a shrug.
⚠ **Why rung 13 got away with what rung 17 cannot**: there a one-ULP quotient error was INVISIBLE
(nearest truncated it away — texgate gate 6 measured 186 texels moved against 3,151 quotients that
changed). **Depth compares the WHOLE quotient.** ⇒ The shader's reciprocal needs texgate GATE 7's
treatment: compare the full quotient word against an exact divide, not just the decision it feeds.
⛔ The model uses an EXACT divide; gfx9 has none. The shader will use the hoisted-reciprocal path
(`recip32` + `tm_quot` + one exact correction, iron-proven at rungs 9/13) and that normalisation is
NOT yet modelled.
⛔⛔ **THE SHADER IS DESIGNED BUT NOT WRITTEN, AND THE REASON IS A FINDING.**
[`planning/rung17-tri-depth.md`](planning/rung17-tri-depth.md) — a 4-lens + 3-attacker derivation over
the shipped tree. **FOUR SEAMS WERE DECIDED TWICE, OPPOSITELY, AND THREE OF THE FOUR WRONG PICKS PASS
THE RUNG'S OWN ORACLE.** Worst: a **signed** depth compare with the `0xFFFFFFFF` far value op 0x0D
already burns makes `-1` the NEAREST value ⇒ nothing ever draws ⇒ both orders byte-identical ⇒
**oracle GREEN on a blank frame.** Pinned: unsigned `v_cmp_lt_u32`, unbinned loop (TD-5 says no
binning), NO exec guard (8-alignment validator rule instead — a prologue guard forges the S1
per-lane-dropout signature the witness exists to detect), and REPLACE-not-composite.
⛔ **MEASURED BY ME (`depthmodel` M2c, in-tree): the order-independence oracle is a NEARLY-BLIND
detector of divide error.** A one-ULP z error on one triangle moves order-independence by **1 px out
of 507** while moving the direct reference diff by **217** — ~200x less sensitive, and 1 px is
exactly the size that reads as noise. ⚠ **This BOUNDS the M2a/M2b claim I recorded earlier**: z
precision IS load-bearing, and the oracle built on it is NOT sensitive enough to police it.
⇒ **The divide needs its own gate** — texgate GATE 7's treatment, the whole quotient word against an
exact divide over the ABI's admissible range. It cannot be deferred to the burn, because **on iron z
is not readable at all** (kernel-owned TD-3 handle; #90 reads the framebuffer).
⚠ An agent claimed the stronger result (orderdiff exactly 0 for a dropped correction); that number
was NOT reproduced here and must be re-measured before being relied on.
✅ **(1) THE DIVIDE GATE IS LANDED** — `depthdiv.cyr`, **exit 95**, 23,950 boundary cases x 24
divisors, 3 mutations red. Obligation `q*area <= zn < (q+1)*area` checked **by multiplication, never
a second divide** (a second divide is the first one agreeing with itself). Two counters — overshoot
refutes the no-overshoot proof that licenses a ONE-SIDED correction; undershoot means one was not
enough. G2 prints max pre-correction shortfall (**exactly 1**) and fire count (**5,432**): without
both, "correction is dead code" and "correction is right" are the same green.
⭐⭐ **G3 MEASURED IN-TREE: the corpus would have certified a divide wrong by 1598.** Rung 13's
transplant gives exact=900/transplant=900 on depthcore's corpus and **63937 vs 65535 (error 1598)**
on an ABI-legal 5-px sliver (area=40). ⇒ recipe changed to **R2** (`R = floor(2^32/area)`, mul_hi +
one correction, 5 instructions); both mul_hi operands provably non-negative so rung 11's
signed-high-half fixup is STRUCTURALLY ABSENT. ⇒ **Boundary sweep, not a stride** — one-ULP errors
live AT the multiples.
✅ **(2) LANE FIDELITY (B0)** — `depthmodel` claimed "32-bit lanes" while accumulating `zn`,
`KX/KY/KC` and `area` in **unmasked i64**, and evaluated `zn` **only inside the triangle** though the
shader is predicated and runs every lane. Fixed: the model now computes from the **mod-2^32 residues
the record actually carries**, and A4's whole-frame peak is **4,836,800** against the old inside-only
2,430,400 — exactly the 2x the plan predicted. New **A5** (residue path == truth, per lane), **A6**
(`w0+w1+w2 == area` at lane width — the identity the shader's derived `w2` rests on, never checked
before). ⚠ A4 also bounded against 2^32-1 rather than **2^31-1**: a value that sign-restores negative
would have passed A4 while failing the compare it feeds. **M5 is the instructive mutation** — adding
`3*2^32` to KC leaves the residue bit-identical, so the reference diff is **0** and only A5 moves.
✅ **(3) THREE NEW FRAMES (B2), AND THE SHIPPED CORPUS'S BLINDNESS REPRODUCED IN-TREE** — on it a
one-ULP z error flips **0 of 1024 px**, and since `dc_ties == 0` **is** order-invariance, *"walks the
list in submission order"* — the entire claim of tile serialisation — **was tested by nothing**.
**PRECISION** (D0d, span 2, 42 px flip) · **QUAD** (D5, 23 ties, both orders differ in all 23, **and
the first-submitted won every one** — a backwards walk passes "they differ" and fails this) ·
**OFF-ORIGIN** (D6/A7c/A8) · **D0e** the sentinel (render at the hardware `0xFFFFFFFF`; ⚠ `DC_FAR` =
1,000,000 sits **in front of** the ABI's own legal z ceiling) · **D7** coverage: of 16 dispatch tiles
only **7 discriminate depth**, 9 are byte-identical for a painter's-order shader, **2 are entirely
empty**.
⛔⛔ **TWO PLAN NUMBERS DIED ON MEASUREMENT, BOTH THE SAME SHAPE — a frame that names a property and
cannot witness it.** (a) **ULP sensitivity is NOT monotone in the z span**: at span **1** every shared
pixel ties, the strict `<` hands them all to the incumbent either way, and the frame flips **zero** —
a *second* null set that "tighter is finer" lands on exactly. D0d now re-measures both endpoints every
run. (b) The plan's OFF-ORIGIN **x = 700 gives |KC| = 58,124,800 — 26 bits, inside an i32**, so it
would never have exercised the residue it exists for. `KC' = KC - 2*T*KX` and `KX` scales with **z**,
not position ⇒ landed at **x = 4000 AND z x10**, `|KC| = 3,326,848,000`, with **A8 asserting the
overflow**.
✅ **(4) THE SHIPPING PROGRAM (B3), ALL FIVE CHANGES IN ONE BITE** — winding normalisation · `dstxy`
folded into the constant terms · `w2` **derived** (`area - w0 - w1`) · the `v_max_i32` domain clamp ·
**unsigned** depth compare. ⛔ *One bite by necessity*: each changes the program the byte-identity
proof covers, so a split would prove a different program than the one that flashes. **Three of the
five are invisible to a plain reference diff**, so each got the gate that can actually see it:
**A12/D9** winding is a *labelling convention* — reversing it must change nothing, and `wind_flips`
(**2048 vs 0**) separates "fired and was right" from "never fired" · **M7** normalise but forget to
flip `KX/KY/KC` → RED (diff 567) · **A10** the clamp fires on **10 lanes, 0 of them inside** (it is
the identity where it matters *by construction*, so output diffing can never witness it — a counter
is the only honest gate) · **A9** at the hardware far value the unsigned compare draws **507 px and
the signed one draws 0**, demonstrating the rung's worst wrong pick rather than asserting it ·
**D8** the validator's four-corner shortcut proven against brute force (**4,836,800 == 4,836,800**,
independently equal to `depthmodel`'s A4 peak).
⛔⛔ **AND B3 FALSIFIED THE PLAN'S RESIDUE ARGUMENT — it named the wrong term.** §4.2 said
`KX = Σ A_i z_i` "reaches ~2^39 and does not fit an i32". Two things it did not account for: **the
`dstxy` fold makes the record draw-local and cancels position EXACTLY** (measured: off-origin `KC` is
−3,326,848,000 before the fold, **+1,152,000** after — the origin corpus's KC × the z-scale, to the
digit), so distance from the origin cannot enlarge a shipping record; and **the corner bound then
pins the rest** — differencing two corners of the affine `zn` gives `|KX| < 2^32/(2w−2)` < 3.1e8 even
at the smallest legal `w`, so **`KX` and `KY` ALWAYS fit** and only `KC` can exceed 2^31, by at most
the `|KX|+|KY|` margin. ⇒ A8 re-aimed at the **fold identity** (which is what the frame really
proves) and a new **A11** exercises residue reconstruction directly at the unfolded |KC| = 3.33e9.
▶ **REMAINING for rung 17 — SIX bites, not "the shader"** (⚠ this line previously said *"REMAINING:
(2) the shader"*, which collapsed B3–B9 into one and would have put a 584-dword blob ahead of the
program it is supposed to reproduce). Per [`planning/rung17-tri-depth.md`](planning/rung17-tri-depth.md)
§7: **B4** external gates G7/G8 · **B5** ABI `0x0E` · **B6** `0x10 GPU_OP_RT_READ` (**blocking**:
without a z readback the burn cannot fail on a broken divide) · **B7** prep · **B8** `tri_depth.s` ·
**B9** worker · **B10** the burn. The four pins must not be re-opened at transcription time.

Remaining after rung 15 — ⚠ **this list was STALE by +2 until 2026-07-28** (it still carried the
pre-renumbering mapping and collapsed rungs 17/18/19 into one cut); [`planning/gpu.md`](planning/gpu.md)
§ release plan is authoritative and this now matches it: **1.56.30** rung 17 `depth` (⚠ op `0x0D` does
not exist yet — `GPU_OP_SUPPORTED` is `0x1F1F`, so minting it means growing `gpu_caps` #89's support
word first), **1.56.31** rung 18 `persp-correct`, **1.56.32** rung 19 `pilot` **+ the rung-closure
debt** (the kernel is six rungs ahead of a shipped consumer; rule 2 says one — either the consumer
ships there or the rule gets struck), **1.56.33** MODESET's true residual — the COLD case only,
**1.56.34** HDMI audio (carries the imitation-edge removal), **1.56.35** the measured invalidate hoist. · **HDMI audio: (a) sequencing is ELIMINATED** by M9 (1.56.15 — both arms exit 95 in one boot, DIG_MODE 2→3 readback-verified, ATOM #4 rc 0, #76 DISABLE+ENABLE rc 0); ⛔ the DCCG symbol-clock lead is FALSIFIED (in-boot A/B, burn 11). Surviving candidates: **(b) a write that does not latch · (c) the bare-metal environment.** · **3D — the rung ladder is at 14b, and rung 16 `tile-own` is ALSO done (1.56.17, host, 0 burns).** Rungs 9–13 are IRON-CLOSED
(edge coverage · attribute interpolation · tri-list · **texturing 17/17 byte-identical, both formats, WRAP,
FULLCOV**). **⭐⭐⭐ RUNG 14 *AND* 14b ARE BOTH IRON-CLOSED 2026-07-27 (burn 2, exit 95, zero red
lines).** op 0x0C `TEX_LIST` is byte-identical to 32 individual op 0x0B dispatches; the col-major
flag `GPU_TEX_FLAG_COLMAJOR` renders **byte-identical to row-major** on all three arms across two
independent boots; and the **op-to-op seam** closed with them (`IDENTICAL batched and alone` —
two op 0x0C records in one #92 array, iron-proving the `gpu_batch_active` suspend in `gpu_tex_list`,
which is the shape a DOOM frame actually has since 640 columns exceeds the 512 cap).
⛔⛔⛔ **AND THE COST MODEL IS INVERTED — do NOT carry rung 14's 177 ns figure forward, it is
RETRACTED.** Six RM/CM pairs across two burns fit **a = −5 ns per LAUNCHED wave (statistically
zero) · b = 36 ns per WORKING wave · F = 264 µs fixed**. ⇒ *A launched-but-exiting wave is FREE*,
the exact opposite of what rung 14 recorded. Its 177/22 came from an `a·launched + b·working` fit
with **no constant term** on two points (zero degrees of freedom): re-running that regression
reproduces 177/22 exactly, so the arithmetic was right and the MODEL was wrong — 264 µs of fixed
cost had nowhere to go but the launched coefficient. A third point at 24× fewer waves is what
exposed it. ⇒ **"row-major cannot draw a DOOM frame — 24.5 ms" is RETRACTED**; measured, that frame
is **4.6 ms** and fits the budget. Col-major remains a **50× GPU reduction** (0.09 ms) and is worth
keeping — because it is 50× cheaper, not because the alternative is impossible.
✅✅ **`F` IS ANSWERED — MEASURED ON IRON 2026-07-28 (1.56.26, exit 95). IT IS PER-PRIMITIVE: 7.35 µs
EACH, AND IT IS ALL IN `gpu_texl_build` / `gpu_tex_prep`.** Two points, n=32 and n=256: CPU grew
**7.59×** for 8× the primitives. Slopes — `validate` 0.0625 µs/prim · **`build` 7.29 µs/prim** ·
`wait` 5.14 µs/prim. gpu.md's "~7.4 µs" guess was right to two figures, but its composition was wrong
in the way that matters: **build is 117× the validate slope**, so optimising the validator buys 0.9%.
⇒ **a 640-column DOOM frame carries 4.71 ms of CPU — 16.5% of a 28.6 ms budget — and NO TRANSPOSE
REMOVES ANY OF IT.** ⛔⛔ **This re-ranks the 3D lane: the GPU is no longer the bottleneck, the CPU prep
is, by 52×.** Frame totals: row-major 4.71 CPU + 4.60 GPU = **9.31 ms**; col-major 4.71 + 0.09 =
**4.80 ms**, so rung 14b's 50× is real but GPU-only and reads **~1.9× at the frame level**. Col-major
stays — it is simply no longer where the time is. **NEXT: `gpu_tex_prep`** (7.35 µs ≈ 22,000 cycles at
3 GHz for one affine frame — defect-shaped, not irreducible). ✅ Both sanity gates passed: WAIT was
substantial and scaled (drain-netting held), and the OBSERVED grid matched prediction exactly at both
points (1024/8192) — the first actual check of a wave count in this arc rather than an assumption.
⚠ WAIT fits `36 µs + 161 ns/wave`, 4.5× the 36 ns/working model — **deliberately NOT promoted**: a
two-point fit is what produced the retracted 177 ns figure, and 1-px primitives run 1/64 occupancy, so
occupancy is the likely missing variable. Needs a third point.
As built at 1.56.23: op `0x0C GPU_OP_TEX_LIST` fuses N
textured primitives into ONE dispatch — ABI 83/83, validator, record array, dispatch, shader (458 dwords =
a **41**-dword prologue + the **417**-dword character-identical body, gated by `texl-body-identity.sh`;
⚠ corrected 1.56.24 — "a 16-instruction prologue on rung 13's 442" conflated tex_rgba's 442-dword TOTAL
with the 417 the gate actually asserts: tex_rgba = 25 + 417, tex_list = 41 + 417, so the 16-dword delta is
prologue-vs-prologue), host
grid-mapping oracle 6/6 + 3/3 mutations, and a `gputex` case demanding byte-identity against 32 individual
op 0x0B dispatches. ⛔ **Two plan premises were overturned by measurement this cycle** — rung 14 is
DISPATCH-bound not bandwidth-bound (52.7 µs fixed vs ≥3680 MB/s), and "walls batch as textured quads" is
REFUTED (`doomwall`: a 1.5× depth ratio makes 4096/4096 px wrong, because `ty_step = 1/depth` is a hyperbola
in screen x). Batch by DISPATCH, never by geometry. ⭐ The lane-efficiency question is ANSWERED, not open: 3.1% occupancy at 2 px wide, 99.6 ns per
USEFUL pixel against rung 13's 1.6 ns/px slope. The deferral worked as designed — the flag was
named, left unbuilt pending a measurement, and the measurement says build it. (the
consumer stack — soorat/kiran/joshua + cyrius-mine-cart/cyrius-block-game — is cataloged and waits on the
kernel; kernel → engine, so port soorat/kiran to learn the seam) · a minor invalidate-hoist perf item · the ML full-forward wiring follow-on (per-repo consumer task). ⚠ **Every GPU-pixel arm is IRON-ONLY** — QEMU has no AMD GPU, and `#92`'s failure mode is SILENT
(straight-alpha renders washed out, never an error), so nothing GPU-composited is proven without a burn.
**Closed within 1.56.x:** the **ML crown (1.54.x C6)** — real ML-layer matmuls on the gfx90c shader cores, **bit-identical** vs CPU, THREE proven consumers ("three jewels", all iron exit 95 2026-07-23): **rupantara 0.4.1** (`/bin/gpulayer` — f64 MLP up-projection `linear_fwd_gpu` tiled onto `#83`, bit-exact K≤8) + **tentib 1.0.1** (`/bin/gpumm` — ternary integer `ternary_matmul_free_gpu` tiled onto `#82`, bit-exact at ANY K via associative i64 accumulate, K=16 cross-tile; first negative-integer proof of `#82`) + **attn11 1.14.1** (`/bin/gpuattn` — the parent transformer's own `qlinear_fwd` hook routed to `#83`); retires the "GPU capability with no caller" anti-pattern; `#90 gpu_readback_shm` + `#91 gpu_blit_bb` (CP-DMA screen-capture readback + bb→bb blit/scroll, iron-proven `/bin/gpucopy` exit 95, 2026-07-23; found+fixed a reused-slot readback-coherence bug → scoped `clflush` in `gpu_readback_shm_sys`, new disassembly-verified `clflush` primitive); the S lane S0-S12 (all iron-proven) and the D lane D1/D2 (closed on iron across
five burns 2026-07-22, then code+flag DELETED — see [[feedback_dlane_five_burns_what_went_wrong]]). · Recent CLOSED arcs (decaying history → [`CHANGELOG.md`](../../CHANGELOG.md)): **1.53.x** kernel FP/SIMD — ring-3 f64 + naad sine-oscillator DSP (iron-validated 2026-07-06) · **1.52.x** audio-output HDA/Azalia — DOOM *with sound* out the ALC897 analog jack, ★ FIRST SOUND FROM SOVEREIGN AGNOS (iron-validated 2026-07-05) · **1.51.x** pkg-manager kernel surface + NIC RX-IRQ latency · **1.50.x** full-RAM usage + high-VA mmap arena · **1.47.x / 1.46.x** proc-teardown-on-fault + SMP STEP-2 (iron-validated 2026-06-26) · **1.45.x** TLS/net + userland net-tools.
>
> **Closed arc — 1.44.x multi-threading / preemptive scheduling (CLOSED at 1.44.26; iron burn pending — superseded by the now-closed 1.45.x net/TLS arc above; its deferred namesake — per-process kernel stacks / IF=1 preemptive `agnsh` / SMP-AP wake — is the active 1.46.x arc).** The deep transition from the cooperative single-core model to preemptive multi-threading ([[project_multithreading_future_arc]]). **Opening (1.44.0):** `kthread_create` — a kernel-thread primitive on the shared AS (CR3 0x1000, IF=1) from a static stack pool, generalizing the hand-rolled 1.40.10 idle proc — plus the **preempt gate** (`preempt_count` + `preempt_disable`/`preempt_enable`, wired into `do_context_switch`): a timer tick inside a `preempt_disable()` section is a no-op switch, so the shared scratch buffers / non-reentrant FS code can stay atomic under preemption (the "reentrant-or-gated" foundation that unwinds the no-lock invariant). `THREAD_SELFTEST` / `scripts/smoke/thread-smoke.sh` QEMU-green: two kthreads tight-loop to tens-of-millions while the timer round-robins them; both freeze under `preempt_disable()`. **Production unchanged** (`preempt_count`=0 → `do_context_switch` byte-identical; the kthread pool is inert until a thread spawns). **1.44.1 (reentrant-or-gated syscalls + kthread dogfood):** the three `sti`-window syscalls — `kbd_read_blocking` (read#5), `sleep_ms`#41, `kbscan`#42 — now suspend preemption through the nestable `preempt_disable`/`preempt_enable` gate instead of the ad-hoc `sched_active=0` save/restore toggle (`sched_active` is now boot-only); and the production **idle thread is spawned via `kthread_create`** (pool stack, slot 0) instead of a hand-rolled stack — dogfooding the 1.44.0 primitive in the real boot path. Behavior-preserving (delegation smoke + doom-smoke + thread-smoke + sweep 7/7; −4 KB). **1.44.2 (reentrancy gate applied):** `vfs_sec_wfile_alloc_slot` — the FAT/exFAT write-fd pool's slot allocator — now claims under `preempt_disable()`. It found+claimed a free `sec_wfile_inuse[]` flag via a **non-atomic test-and-set** (`if(flag==0){flag=1}`) that relied on no-preemption; the gate makes it atomic so two threads can't grab the same write block. First real adopter of the gate pattern; `sweep` 7/7 (FAT/exFAT writes drive it). Follow-on allocators (`vfs_alloc` fd table, proc/kthread slot claims) stay IF=0-safe today. **1.44.3 (per-process CS/SS — first step to ring-3 preemption):** `proc_restore_context` reads CS/SS from new pid-indexed `proc_cs[]`/`proc_ss[]` arrays instead of hardcoding `CS=0x08`/`SS=0x10`; `proc_save_context` persists them. Defaults ring-0 so every current proc round-trips byte-identically (behavior-preserving) — it removes the hardcode wall that forced any switched-to proc into ring 0. A multi-agent design pass corrected the plan: the feared KPTI hazard is a non-issue (collapsed KPTI — per-proc CR3 is a full kernel superset, no ISR CR3 switch needed); the real remaining wall is the shared TSS RSP0 (0x200000) + syscall kstack (needs per-proc kernel stacks, a later bite). Validated: thread-smoke + agnsh-smoke (clean boot) + doom-smoke + sweep 7/7. **1.44.4 (preemptive ring-3 — the central milestone):** `proc_set_ring3(pid)` flips a proc's saved selectors to ring-3 (CS=0x23/SS=0x1B); a `RING3_SELFTEST` spawns ONE ring-3 proc (own CR3, IF=1) running a syscall-free raw-machine-code loop incrementing a user-VA counter — `ring3-smoke` proves the timer preempts it under its own CR3 and the scheduler iretq's back into ring 3 (`ring3: preempt OK`, counter ~127 M), and the preempt gate freezes it (`ring3: gate held`). En route it found + fixed a **latent `spawn_user_proc` huge-page aliasing bug** (`pmm_alloc` 4 KB → `pmm_alloc_2mb`; `proc_map_page` maps 2 MB pages, so a 4 KB-backed code page aliased to the 2 MB base = zeros → `#PF CR2=0` at entry; latent because the only prior caller is the skipped KTEST path) — cracked with `qemu -d int`. Payload is raw bytes not a fn (a Cyrius prologue does a relocate-sensitive access that #PFs after `memcpy`). Production unaffected (`RING3_SELFTEST` off; `spawn_user_proc` is KTEST-only). **1.44.5 (two ring-3 procs):** the `RING3_SELFTEST` now spawns TWO ring-3 procs (own CR3 each, IF=1) running the SAME syscall-free payload incrementing user VA 0x2000000 — distinct CR3s map that one VA to distinct counters, so both advancing (`ring3-smoke`: A≈183 M / B≈224 M) proves the scheduler cr3_loads A→B→A every slice (ring-3↔ring-3, not just ring-3↔idle) AND per-proc address-space isolation; both freeze under the gate. Production byte-identical to 1.44.4 (all changes gated). Two syscall-free procs share the single TSS RSP0 safely (single-core serial ISR completion). **1.44.6 (syscalls from preemptible ring-3 — wall dissolved):** the `RING3_SELFTEST` payload now makes a `getpid` syscall (#2) each iteration before incrementing — both procs reach ~86–90 K loops (vs 1.44.5's ~127 M pure-increment, confirming real ring-0 round-trips), both freeze under the gate, no crash. So a preemptible ring-3 proc can SYSCALL safely + two can concurrently. The "per-proc-kstack wall" from the 1.44.3 note is **superseded**: `SFMASK` (0x40700) clears IF on every SYSCALL entry so handlers run uninterruptible, and the only IF-window syscalls (`kbd_read_blocking`/`sleep_ms`/`kbscan`) are preempt-gated (1.44.1) — so no syscall is ever preempted mid-handler and the shared syscall kstack (0x3F0000) + RSP0 (0x200000) stay serial; **no per-proc kernel stack is needed**. Residual (checklist, not a wall): any new IF-window syscall must adopt the 1.44.1 gate. Production byte-identical (gated). **1.44.7 (concurrent ring-3 execution + clean exit — the headline payoff):** a scheduled ring-3 proc B runs a FINITE program (count to N then `exit` #0) to completion and is cleanly retired (state 0) WHILE proc A stays live (`ring3-smoke`: `child exited` + `preempt OK` + `gate held`; B hits exactly N=0x1000000). Fixed a real scheduler bug — `do_context_switch` unconditionally set the switched-away proc to ready, RESURRECTING any proc that called `exit()`; now guarded on `!= 0` (raw `load64`, the cc5-regalloc-safe form) so a dead proc stays dead and `sched_next()` retires it. Production change, behavior-identical there (`exec_and_wait` children longjmp out, never hitting this path); validated thread-smoke + agnsh + doom + sweep 7/7 (+64 B). A first selftest refactor triple-faulted; **ruled out a cycc 6.1.23 regression** (exact-1.44.6 rebuilds green under it) and used a 1-array-refill design. **1.44.8 (real ELF spawn):** `elf_load` (the in-memory ELF loader behind `spawn`#3) now sets ring-3 selectors (`proc_set_ring3`) so a spawned ELF runs scheduled, and its segment loader was rewritten to the SMAP-safe / 2 MB-aligned / no-CR3-switch form `elf_load_from_file` uses (it was doubly broken — kernel-writes-user-page SMAP #PF + `pmm_alloc` 4 KB alias — both latent because `spawn`#3 was never exercised). `RING3_SELFTEST` proc B is now a real in-memory ELF64 (`elf_load`) that counts to N then `exit`s; `ring3-smoke` `child exited` green while A stays live. Production unaffected (`elf_load` is spawn-only; exec/DOOM/agnsh use the separate `elf_load_from_file`); +160 B; sweep 7/7. **1.44.9 (non-blocking waitpid + blocker scoped):** `waitpid`(#4) is now a non-blocking poll (child exit code, or -2/WOULD_BLOCK); the ring-3 PARENT `spawn`(#3)+`waitpid`(#4) selftest triple-faulted (#UD child) and is **deferred on a precisely-located blocker** — `elf_load` from `spawn`(#3) under the parent's CR3 loads the segment right (instrumented `phys[entry]=0xB8`) but mis-wires the child's page tables (per-proc CR3 256 MB–1 GB mirror gap). Selftest reverted to the green 1.44.8 form. **Next bites:** **`spawn`(#3) copies the user ELF to a kernel buffer + runs `elf_load` under the kernel CR3** (unblocks the ring-3 parent spawn+waitpid); then make agnsh itself schedulable so it backgrounds a program (real "shell stays live"); `kthread_yield`; SMP-AP wakeup. **Absorbs 1.43.x carry-forward:** per-process env, FB scaling, zero-copy FB-mmap. **Userland testing surface (done):** the kriya/owl coreutils delegation — agnoshi **1.5.0** dropped its in-process verbs → kriya `/bin` dispatcher (11 `/bin/<verb>` symlinks) + owl `cat`; END-TO-END QEMU-green (`scripts/harness/agnsh-delegation-test.py`); fixed kriya 1.1.2 + owl 1.3.8 (stale-`fnptr` allocator gap). **Recently closed (detail in CHANGELOG):** **1.43.x graphics/DOOM** — iron-complete, burn `1439` plays DOOM in-game on real Zen; **1.42.x perf + hardening ∥ sysinfo/klug** — Track-A perf bites (1.42.5/7/8/9) + carry-forward hardening (1.42.2/3/4) + `uname`#34/`sysinfo`#35/`klug`#36 + the klug log ring (Track-A perf iron-pending). **Backlog:** backspace-on-iron (1.41.x); `symlink`#43 → `lstat`#44/`readlink`#45 (kriya `ln -s`); execwait 8-arg cap; `klug`/`dmesg` reader + wiring `cmdrs`/`bnrmr`/`mihi`/`iam` to `uname`#34/`sysinfo`#35.
>
> **History lives elsewhere — this file is current-truth + pointers, NOT a log.** Per-release detail → [`CHANGELOG.md`](../../CHANGELOG.md). Forward plan → [`roadmap.md`](roadmap.md). Iron-burn attempts → agnosticos [`iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md). ABI contract → [`agnos-userland-abi.md`](agnos-userland-abi.md).
>
> **Scope**: live snapshot of this repo (`agnos`). Volatile state lives here so [`CLAUDE.md`](../../CLAUDE.md) can stay durable. Historical narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md); the design ledger lives in [`roadmap.md`](roadmap.md). Iron-bring-up per-attempt detail lives in [agnosticos `iron-nuc-zen-log.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).

---

## Version

| Field | Value | Source |
|---|---|---|
| **Kernel** | **1.56.30** | [`VERSION`](../../VERSION) |
| **Cyrius toolchain pin** | **6.2.36** | `cyrius.cyml [package].cyrius` |
| **Released** | 2026-07-28 | [`CHANGELOG.md`](../../CHANGELOG.md) |
| **Iron-validated** | 2026-05-25 (archaemenid NUC AMD — **MVP gate green since Attempt 68 / 1.30.9**; **1.32.x networking arc iron-COMPLETE**: r8169 unicast-RX solved at 1.32.7 + DHCP real lease `.142` iron-verified at 1.32.9; storage trio + GPT + ext4 + shell byte-clean). The 1.33.x ext2/4-WRITE + 1.34.x FAT-family arcs are QEMU/`fsck`-validated; their final-bite iron burns stay user-driven (pending). | NUC AMD Attempts 68 (MVP gate) + 71-77 (FB) + 80-91 (storage arc) + 92+ (networking arc — DHCP iron-verified 1.32.9) |

## Open investigations

The kernel cleared boot-to-shell-on-iron at Attempt 68 (agnos 1.30.9) and stays green; the 1.31.x storage + 1.32.x networking arcs are iron-COMPLETE (DHCP real lease iron-verified at 1.32.9, agnosticos [`#tracker-1329-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log-mvp2.md#tracker-1329-cycle)). **No MVP blockers.** One live item:

- **AMD Zen scanout residue (Quiet Boot legibility)** — parked at gnoboot 0.4.2 / agnos 1.30.12 with the bug surviving. Two GOP-side SetMode lever variants falsified (Attempt 78 closed the bounce form). Next-cycle resumption options: HUBP `clear_tiling` port (Linux `drivers/gpu/drm/amd/display/` analog) OR architectural eval of a shadow-buffer FB-console model (simpledrm-style). Pin: [`project_amd_zen_scanout_residue`](../../../../.claude/projects/-home-macro-Repos-agnosticos/memory/project_amd_zen_scanout_residue.md). VGA-spec path stays MVP-legible.

### Resolved (historical, kept as audit trail)

- **2026-06-08 first-`mmap`-return RIP=0 (repaired at 1.43.8)**: was NOT a SYSRET
  return-state bug — it was user-stack **aliasing**. User stacks sat at
  `0x800000 + pid*0x400000`, so for pid ≥ 2 the stack VA landed inside the
  `PD[8..63]` identity-supervisor pmm pool; a later `sys_mmap` `memset(phys,0,2 MB)`
  whose identity VA aliased the stack zeroed the live ring-3 stack → next `ret`
  jumped to RIP=0. Recovery-shell `run` (low pid) never aliased — which is why
  `doom-smoke` passed while agnsh-launched doom (higher pid) locked up. Fixed by
  relocating user stacks to `0x3FC00000` (top of the non-identity arena) + mmap
  ceiling `0x3FA00000` + `invlpg` after the PDE store; the cyrius-doom warm-up-`mmap`
  workaround was removed. Validated: doom renders via both `execwait` and recovery
  `run` with 0 RIP=0 faults (1.44.x carry-forward, closed). See CHANGELOG [1.43.8].
- **2026-05-13 RDRAND under default qemu64 CPU**: kernel stalled at `Page tables: 1024MB mapped` because the smoke test missed `-cpu max` (default `qemu64` lacks RDRAND, `pmm_init` → `kaslr_seed` → `rdrand_u64` faulted silently). Real iron supports RDRAND. Fixed in `gnoboot/tests/ovmf_smoke.sh` with `-cpu max`.
- **2026-05-13/14 Timer-driven context switch under UEFI+gnoboot**: traced to `test_proc_a/b` returning into uninitialized stack memory exposed by gnoboot's pre-handoff state. Closed by Phase 4/5 progression (real user procs replaced test stubs in the boot path) and the iron-validation milestone 2026-05-15 which cleared all 17 init checkpoints + `sched_active=1` + first hlt + context-switch loop on real Zen silicon.
- **2026-05-17 Phase 3 USB silent-absorb (Repair EE)**: 13-hypothesis arc through Attempts 32-54 chasing a "controller absorbs PORTSC.PR writes" hypothesis. Root cause: `xhci_portsc_write` inner re-mask `& XHCI_PORTSC_NEUTRAL` stripping the RW1S PR bit. One-line fix in `agnos@41ee6dc`. See CHANGELOG [1.30.5] for the narrative.
- **2026-05-18 xHCI Enable Slot CCE silent-absorb (Repair QQ + cyrius gvar-init-order fix)**: 9-letter spec-path repair ladder (FF→OO) falsified Attempts 57-62 on AMD FCH 1022:1639. Resolution came from the cyrius side: v5.11.64 fixed a kmode init-order bug where `var X = INT_LITERAL` at module scope read as 0 before the init block ran, causing silent-absorb on the cmd-path. Iron-validated at Attempt 68 (1.30.9) — typeable shell on archaemenid → MVP gate hit. See agnosticos `iron-nuc-zen-log` § Attempt 68 + cyrius `issues/2026-05-18-gvar-init-order-zero-reads.md`.
- **2026-05-20 NVMe arc + iron debut**: Phase 1-5 driver shipped under [1.31.0]; iron debut on Crucial P3 2 TB at Attempt 80 was first-try clean. The contrast with xHCI's 5-week / 19-attempt / 9-letter-code path is the structural reading on `feedback_redesign_dont_reinvent`: port from Linux's `drivers/nvme/host/pci.c`, redesign to Cyrius conventions, get a clean iron debut.
- **2026-05-25 networking arc close (r8169 unicast-RX → DHCP)**: the 1.32.3 `dhcp: OFFER timeout` was NOT a DHCP-layer bug — it was the r8169 RX ring dropping clean unicast frames for want of a free descriptor (16-deep ring). Fixed at **1.32.7** (RX ring 16→64; `missed` 176→0; on-LAN + off-LAN TCP handshakes complete on iron), DHCP re-enabled at **1.32.9** with a real lease `.142` iron-verified. The whole 1.32.x networking arc is COMPLETE. agnosticos [`#tracker-1329-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log-mvp2.md#tracker-1329-cycle) + CHANGELOG [1.32.x].

The full history of these investigations lives in [`CHANGELOG.md`](../../CHANGELOG.md) and the agnosticos iron-nuc-zen-log. This `state.md` section tracks **live** investigation only — historical investigations should resolve here and migrate to CHANGELOG.

---

## Build artifacts

Sizes from `wc -c` on `build/agnos*` after `scripts/build.sh`, cyrius 6.2.36, default DCE.

| Arch | Binary | Size | Notes |
|---|---|---|---|
| x86_64 | `build/agnos` | **1,209,880 B** (at 1.45.17) | ELF64 multiboot2 (Path C — sovereign UEFI boot-info ABI via gnoboot v0.4.2+; RDI = `&boot_info`, magic `0x41474E4F`), entry `0x1000a8`. Boots under `qemu-system-x86_64 -cpu max` + OVMF + gnoboot. Iron-validated on archaemenid: MVP gate Attempt 68 (1.30.9), storage trio Attempts 80/81/87, ext4 victory lap 90/91, networking arc through Attempt ~100 (DHCP iron-verified 1.32.9), shell-separation burn `14115`, DOOM in-game burn `1439`, `net_config`#61 on-subnet-DNS burn `14516` (the 1.45.17 RX-drain fix is pending burn). |
| aarch64 | `build/agnos-aarch64` | deferred — separate work area | Compile-only, no boot harness; **not gated** (test.sh/check.sh/CI are x86-only). During first-primary-kernel buildup the **AMD x86 line (archaemenid) is the one and only kernel** — aarch64 bring-up (incl. stub parity) is its own future arc (decade 1.6x), not maintained in lockstep here. x86 is the only build the target line depends on. |

Per-cut size trajectory + deltas live in [`CHANGELOG.md`](../../CHANGELOG.md) (the at-a-glance ledger — this is current truth, not a log). Bookmarks: ~249 KB (1.28.x) → **~395 KB v1.30.9 MVP gate** → 1.31.x storage → 1.32.x networking → 1.33.x ext2/4 write → 1.34.x FAT-family → 798,936 B (1.34.6) → 1.35.x comms + mmap/munmap + RTC → 828,464 B (1.35.7) → 1.36.x refactor (byte-identical) → 1.37–1.39 big-write arcs (ext4 extent / jbd2 / VFS-write) → 1.40.x exec-from-disk → 1.41.x shell-separation → 1.42.x perf + sysinfo/klug → 1.43.x graphics/DOOM → 1.44.x preemptive-scheduling: 1,193,424 B (1.44.22) → **1.45.x net/TLS + net-tools: 1,209,880 B (1.45.17)**.

---

## Source rollup

| Tree | Files | Notes |
|---|---|---|
| `kernel/` (total) | **80** `.cyr` | ~27,000 lines across all kernel sources. The 1.36.x refactor split `net.cyr` (2019 → 272 LOC) into 8 focused files (`net.cyr` core + `net_dhcp`/`net_icmp`/`net_dns`/`net_ntp`/`net_rtc`/`net_ingress`/`net_tcp`) and `main.cyr` (1661 → 1244 LOC) into `main.cyr` (boot init) + `selftests.cyr` + `boot_finish.cyr`. Pure reorg, byte-identical builds. |
| `kernel/agnos.cyr` | 1 | Main orchestrator — only `#ifdef` + `include` |
| `kernel/kernel_hello.cyr` | 1 | Minimal smoke test |
| `kernel/klib/` | 3 | `kstring.cyr`, `kfmt.cyr`, `ktagged.cyr` — vendored kernel-safe stdlib |
| `kernel/arch/x86_64/` | 17 | boot_shim, boot_data, fb, fb_console, mbi, serial, gdt, idt, pic, apic, smp, keyboard, paging, io, syscall_hw, ring3, iommu |
| `kernel/arch/x86_64/usb/` | 9 | xhci, xhci_regs, xhci_ring, xhci_cmd, xhci_ctx, xhci_port, hid, hid_translate, msc (USB Mass Storage) |
| `kernel/arch/aarch64/` | 9 | boot_data, serial, gic, timer, exceptions, keyboard, paging, stubs, main |
| `kernel/core/` | **26** | pmm, vmm, heap, proc, sched, syscall, vfs, devs, initrd, kprint, main, pci, acpi, elf; **net, virtio_net, r8169** (networking); **block, nvme, ahci, virtio_blk, ramdisk, gpt** (storage); **ext2, fatfs, exfat** (filesystems) |
| `kernel/user/` | 4 | shell, init, test, test_procs |
| `kernel/version.cyr` | 1 | Auto-generated banner strings — `scripts/version-bump.sh` regenerates |

---

## Subsystem status (40+)

All subsystems are **code-complete** through the active 1.45.x cycle (net/TLS hooks #45–#61 + the net-tools family). **MVP gate cleared on iron** — typeable shell at Attempt 68 (1.30.9). Iron-validated since: the **1.31.x storage arc** (NVMe / AHCI / USB-MS / RAM-disk / VirtIO-blk + 5-backend block layer + GPT, Attempts 80/81/87/90/91); the **1.32.x networking arc** (TCP/UDP + DHCP + r8169 NIC, iron-COMPLETE 1.32.9); the **1.33.x ext2/4 WRITE arc** (persist-across-reboot); the **1.41.x shell-separation arc** (agnsh types/dispatches on archaemenid, burn `14115`); and the **1.43.x graphics arc** (DOOM in-game on real Zen, burn `1439`). QEMU/`fsck`-validated, iron-pending: the **1.34.x FAT-family arc**, the **1.37–1.39 big-write arcs** (ext4 extent / jbd2 / VFS-write), **1.40.x exec-from-disk**, **1.42.x perf/sysinfo/klug**, and the **1.44.x preemptive-scheduling arc** (multi-proc ring-3, schedulable agnsh `&`, SMP-AP wake+park — the next burn). The README § Subsystems is the full enumeration; the roadmap's arc ledger is the at-a-glance index; this table is the shipped-surface detail.

| Subsystem | Notes |
|---|---|
| Boot (multiboot2, 32→64 shim) | 32-bit ELF entry, long mode transition (x86_64) |
| Boot (aarch64) | DTB, EL2→EL1, PL011 UART, GIC, ARM timer |
| Boot (Path-C sovereign UEFI) | gnoboot v0.4.2 hands off via `RDI = &boot_info` (magic `0x41474E4F`); replaces multiboot2-via-GRUB |
| Framebuffer console | GOP handoff capture, WC remap, pitch-aware u64 block-copy paint, 8x16 VGA BIOS-ROM glyph set (true-font swap at 1.30.12) |
| Serial I/O | COM1 `0x3F8` (x86_64), PL011 UART (aarch64) |
| GDT | 5 segments + TSS descriptor |
| TSS | Ring 3 transitions, RSP0 |
| IDT | 256 vectors, default `iretq` handler |
| PIC | 8259A, ICW1–4, remap to INT 32+ |
| Local APIC | MMIO at `0xFEE00000`, timer, IPI |
| GIC | ARM GICv2 interrupt controller (aarch64) |
| Timer | APIC periodic ~100 Hz (x86_64), ARM generic timer (aarch64) |
| Keyboard (PS/2) | Full US QWERTY (x86_64), UART RX (aarch64) |
| Keyboard (USB-HID via xHCI) | Full Phase 1-5 boot kbd driver — `hid_kbd_configure`, `hid_poll`, HID→PS/2 mapping, kb_buf writer; iron-typeable at Attempt 68 |
| Page Tables | 2 MB huge pages, 4 GB identity map, per-process |
| PMM | Bitmap, 4,096 pages, next-free hint |
| VMM | map/unmap/alloc, user-accessible pages, UC + WC remap helpers |
| Kernel Heap | Slab allocator, 8 size classes (32–4,096 B) |
| Process Table | 16 slots, 176 B context, CR3 per-process; `kthread_create` spawns shared-AS kernel threads from a static stack pool (1.44.0) |
| Context Switch | Full register save/restore, CR3 switch (timer-ISR-driven) |
| Scheduler | Preemptive round-robin; `preempt_count` gate (`preempt_disable`/`preempt_enable`) makes reentrancy-critical sections atomic vs. preemption (1.44.0 multi-threading opening) |
| SYSCALL/SYSRET | MSR setup, ring 3 transition |
| ELF Loader | Static ELF64, per-process address space |
| VFS | File table, device/memfile/signalfd/epoll/timerfd/pipe types |
| Device Drivers | Serial char device |
| Initrd | Flat format, name lookup |
| PCI Bus | Config space scan, device discovery, 64-bit BAR support |
| ACPI | RSDP scan, DMAR parsing (VT-d), basic table layout |
| IOMMU (VT-d) | Root/context/IO page tables, DTE registration for device DMA |
| VirtIO-Net | Legacy PCI, virtqueues, Ethernet frames (QEMU NIC) |
| **r8169 NIC** | Realtek RTL8111/8168/8169 GbE driver — RX/TX descriptor rings (64/RX, TX-split mask), unicast filter, iron-validated on archaemenid (RX isolated-construction fix 1.32.7) |
| IP/UDP Stack | ARP, IPv4, UDP send/recv |
| TCP Stack | Connect, send, recv, close, SYN/ACK/FIN state machine + **server primitives** (listen/accept) |
| **DHCP client** | DISCOVER → OFFER → REQUEST → ACK lease acquisition; iron-verified lease on archaemenid (1.32.9) |
| VirtIO-Blk | Legacy PCI, sector read/write, DMA buffers |
| **NVMe** | Full Phase 1-5 driver — probe + admin queue + I/O queue + R/W DMA + PRP1/PRP2/PRP-list dispatch. Iron-debut clean on Crucial P3 2 TB at Attempt 80 (1.31.0) |
| **AHCI/SATA** | Full Phase 1-4 driver — HBA probe + per-port CL+FIS bring-up + IDENTIFY DEVICE + READ/WRITE DMA EXT. QEMU-validated on q35 ich9-ahci; iron-validated on archaemenid (Attempt 87) |
| **Block-layer dispatch** | `kernel/core/block.cyr` — tag-based 5-backend dispatch (`BLK_VIRTIO` / `BLK_NVME` / `BLK_AHCI` / `BLK_USB` / `BLK_RAM`); NVMe overrides virtio; AHCI/USB register as secondary when NVMe present (1.31.x) |
| **GPT partition parser** | Full Phase 1-3 — header probe + signature decode + full 16 KB array walk + UTF-16LE name extraction + `parts` shell command + `gpt_partition_info(idx)` helper + table-less CRC32 (0xEDB88320) validation + backup-header recovery + 7-GUID type classifier (ESP / MSFT Basic / Linux FS / Linux Swap / Linux LVM / Linux RAID / BIOS Boot) (1.31.1) |
| **USB Mass Storage** | `usb/msc.cyr` — Bulk-Only Transport, SCSI READ/WRITE(10), block-layer backend (`BLK_USB`) |
| **RAM-disk** | `core/ramdisk.cyr` — in-memory block backend (`BLK_RAM`) for test/seed images |
| **ext2 / ext4** | Read **and write** — inode/block-group walk, directory ops, file create/write/truncate; persist-across-reboot iron-validated (1.33.x WRITE arc, Attempts 90/91) |
| **FAT12 / FAT16 / FAT32** | Read **and write** — cluster-chain walk, LFN (read + spanning-append write), file create/overwrite/truncate/delete, cluster allocator; `fsck.fat` + `mtools` validated (1.34.x) |
| **exFAT** | Read **and write** — 32-bit FAT, allocation bitmap, up-case table (RLE), typed dir-sets (File / Stream-Ext / File-Name), SetChecksum/NameHash; root extension + spanning-append; `fsck.exfat` validated (1.34.x) |
| **FS-write safety guard** | Refuses FAT/exFAT writes on ESP-type GPT partitions (boot ESP protection); `FAT_ALLOW_ESP_WRITE` compile-override for QEMU test images (1.34.6) |
| Pipes | Circular buffer IPC, read/write ends, VFS type 6 |
| SMP Infrastructure | APIC, IPI, trampoline, per-CPU stacks |
| Shell | 28 commands (storage/FS/net arcs added `parts`, mount/ls/cat/write/rm/mkdir over the FS backends, net diagnostics) |
| kybernet Init | PID 1 |
| Signals | per-process `proc_signals` / `proc_sigmask`, `kill`, `sigprocmask`, `signalfd` |
| Epoll + Timerfd | `epoll_{create,ctl,wait}`, `timerfd_{create,settime}` |

### Syscall surface (44 functional + 1 diagnostic = 45 dispatch entries, 0–44)

`exit`(0), `write`(1), `getpid`(2), `spawn`(3), `waitpid`(4), `read`(5),
`close`(6), `open`(7), `dup`(8), `mkdir`(9), `rmdir`(10), `mount`(11),
`sync`(12), `reboot`(13), `pause`(14), `getuid`(15), `kill`(16),
`sigprocmask`(17), `signalfd`(18), `epoll_create`(19), `epoll_ctl`(20),
`epoll_wait`(21), `timerfd_create`(22), `timerfd_settime`(23),
`umount`(24), `pipe`(25), `mmap`(27), `munmap`(28), `getdents`(29),
`unlink`(30), `rename`(31), `link`(32), `stat`(33), `uname`(34),
`sysinfo`(35), `klug`(36), `execwait`(37), `fbinfo`(38), `blit`(39),
`uptime_ms`(40), `sleep_ms`(41), `kbscan`(42), `spawn_path`(43),
`sched_yield`(44).

Slot **26** is `write_boot_checkpoint(byte)` — a CMOS-write diagnostic from
iron-boot bring-up, not part of the functional set. Growth since the v1.21.0
26-call kybernet base is **per native workload, never to chase a Linux ABI**:
`mmap`/`munmap` (27/28, 1.35.x — anonymous 2 MB-granular memory); the
**mount-routed FS surface** (29–33 `getdents`/`unlink`/`rename`/`link`/`stat`,
1.41.3 — what agnsh + kriya drive); the **sovereign sysinfo/log surface** (34–36
`uname`/`sysinfo`/`klug`, 1.42.x — mihi/iam/chakshu/klug); the **exec + graphics
+ timing surface** (37–42 `execwait`/`fbinfo`/`blit`/`uptime_ms`/`sleep_ms`/
`kbscan`, 1.43.x — `run`, DOOM); and the **preemptive-scheduling surface** (43
`spawn_path` = non-blocking from-disk spawn for agnsh `&`, 44 `sched_yield`,
1.44.x). Still **no socket / AF_ALG / `splice`** — the attack-surface story
stays anchored on that structural absence, not a fixed table size. Per-call ABI
contract: [`agnos-userland-abi.md`](agnos-userland-abi.md).

---

## Ecosystem (userland boot stack)

The kernel itself has zero deps (`[deps] stdlib = []` in `cyrius.cyml`).
What boots on top of it (live versions in [agnosticos `state.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md)):

```
kybernet (PID 1)
├── agnosys      — syscall bindings (Linux x86_64 + aarch64 wrappers)
├── agnostik     — shared types/primitives (error/security/agent/telemetry)
├── argonaut     — service lifecycle, health, seccomp/Landlock, PID-1 harness
│                  (BOOT_MINIMAL mode adds agnoshi as no-deps console service — 1.30.x MVP path)
│   └── libro    — cryptographic audit chain
└── daimon       — agent orchestrator
```

**Single-pin convention retired**: the old "all on one cyrius pin" stack convention dissolved during the v5.11.x burst (2026-05-11/12/13); each repo now pins independently. **agnos is on cyrius 6.0.56** (6.0.1 → 6.0.3 at 1.35.5, 2026-05-27; held on 6.0.3 through the 1.37/1.38 big-write arcs; → 6.0.14 at the **1.39.0 cycle-open**, 2026-05-28, after a byte-identical kernel A/B; → **6.0.56 at the 1.41.4 shell-separation bite** for `CYRIUS_TARGET_AGNOS` — held-known-working since; 6.0.1 had graduated from 5.11.64 mid-1.31.x). Build agnos-target binaries with the pinned 6.0.56, not the default `cyrius` wrapper (which uses latest and only warns about drift). The per-repo pin-lag spectrum is tracked in [agnosticos `state.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/state.md) — the genesis repo is authoritative for cross-repo state. **Sibling versions intentionally elided here** to avoid double-bookkeeping.

---

## Test surface

| Gate | Count | Source |
|---|---|---|
| `scripts/check.sh` | **11/11** PASS | build, test, doc-exists ×6, version-in-kernel, version-in-changelog, binary-size |
| `scripts/test.sh --all` | **7/7** PASS | x86 builds, multiboot ELF, size, kernel_hello builds; aarch64 compiles, size, valid ELF |
| CI `boot-test` (QEMU) | banner + `KASLR: pmm_next_free=N` varies across 2 boots + `Memory isolation: PASS` + `Userland exec complete` | `.github/workflows/ci.yml` `boot-test` job |
| CI `Format check` | all kernel sources fmt-clean (1 skip: `kernel/user/shell.cyr` per `#ifdef`-in-fn-body carve-out) | `ci.yml` `check` job |

CI runs on a self-hosted runner labeled `[self-hosted, linux, x64]` for
`boot-test` and `benchmarks` (need QEMU + KVM-class CPU); `build`, `check`,
`test`, `security`, `docs` run on `ubuntu-latest`.

---

## In-flight (roadmap snapshot)

Source: [`docs/development/roadmap.md`](roadmap.md) `## Active` section.

| # | Item | Status |
|---|---|---|
| 1 | **1.44.x preemptive-scheduling arc — CLOSING** | Multi-threading/preemptive-sched complete: `kthread_create` + `preempt_count` gate, preemptive ring-3 (multi-proc, per-CR3, while syscalling), schedulable agnsh `&` (`spawn_path`#43 / `sched_yield`#44), SMP-AP wake+park (#1.44.18). **1.44.21-22 arc-closing security/hardening + clarity sweep** cut (the `kbd_read_nonblock` OOB clamp + the APIC delivery-status timeout + comment-correctness fixes). All QEMU-green; **iron-burn pending on archaemenid** → [`#tracker-144x-cycle`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md#tracker-144x-cycle). |
| 2 | **SMP-AP wake on real hardware — the next burn's riskiest item** | QEMU-validated only (1.44.18, `smp-smoke` 3/3); real-Zen INIT-SIPI timing is unproven. 1.44.21 made the wake **fail-safe** (bounded APIC delivery-status poll → a stuck IPI bounds-out instead of hanging the boot). One-line re-gate of `smp_start_aps` is the fallback. |
| 3 | AMD Zen Quiet-Boot scanout residue | Parked next-cycle pin (`project_amd_zen_scanout_residue`). MVP unblocked via VGA-spec path; resumption options are HUBP `clear_tiling` port or shadow-buffer FB-console architectural eval. |
| 4 | **Next arc — 1.45.x cyrius-audit crossover** | TLS→HTTP→`ark`-fetch + PIE→full-binary KASLR — the primitives are built upstream (cyrius/`sigil`-side); 1.45.x is their agnos-side consumption. Forward plan in [`roadmap.md`](roadmap.md). |

Recently closed — arc bookmarks only; per-cut detail in [`CHANGELOG.md`](../../CHANGELOG.md):
- **1.44.x — multi-threading / preemptive scheduling** (latest, CLOSING): `kthread_create` + `preempt_count` gate; preemptive ring-3 (multi-proc, per-CR3, syscalling); concurrent exec + clean exit; real ELF spawn; non-blocking `waitpid`; **schedulable agnsh `&`** (`spawn_path`#43, non-blocking cooked-line read, `sched_yield`#44, idle-deprioritization — bg jobs ×2.3); **SMP-AP wake+park** (#1.44.18, single-core invariant intact); per-process env (#1.44.19); kernel-scaled blit (#1.44.20); **arc-closing security/hardening sweep (1.44.21)** = the `kbd_read_nonblock` cross-call OOB-flush clamp + the APIC delivery-status timeout; **clarity sweep (1.44.22)** = comment-correctness (byte-identical). All QEMU-green; iron-burn pending.
- **1.43.x — graphics / DOOM**: `execwait`#37 (`run`) + FB-console ANSI/SGR + `fbinfo`#38/`blit`#39 + `uptime_ms`#40/`sleep_ms`#41/`kbscan`#42 → **DOOM plays in-game on real Zen** (burn `1439`).
- **1.42.x — perf + hardening ∥ sysinfo/klug**: heap/memory/fs-read/fb-blit perf + carry-forward hardening + `uname`#34/`sysinfo`#35/`klug`#36 + the klug kernel-log ring + a 6-dim hardening/audit sweep (1.42.14).
- **1.41.x — shell-separation**: agnsh is the interactive shell exec'd from disk in ring 3 (the in-kernel shell shrank to a recovery REPL); real FS syscalls (29–33); **iron-complete (burn `14115`)**.
- **1.40.x — exec-from-disk + VFS mount routing**: a program loaded from the filesystem runs in ring 3 (iron-validated, `14013_final`).
- **1.37–1.39 big-write own-cycles**: ext4 extent-allocation (1.37) · jbd2 journaling (1.38, iron-complete) · VFS generic-write lift (1.39) — all crash-safe.
- **1.36.x — refactor cycle**: `net.cyr` 8-split + `main.cyr` split into boot/selftests/boot_finish; byte-identical builds.
- **1.35.7 — arc-close hardening (pass 1)**: `ip_safe_payload_len` clamps the IPv4 total-length at `net_poll` to the received frame — kills a forged-length over-read across ICMP/UDP/TCP. `hardening-smoke.sh` green.
- **1.35.6 — DNS cache**: 8-entry TTL-respecting positive cache (`dns_cache_find`/`_put`, lwIP-style evict-soonest) + TTL extraction; repeated lookups stop re-querying. `dns-smoke.sh` 3/3. (multi-A/CNAME + retransmit were already in the 1.35.0 stub.)
- **1.35.5 — RTC boot clock**: CMOS RTC read (`rtc_read_unix`) + `civil_to_unix` seed a local wall clock at boot (`date` `[RTC]`/`[NTP]`); NTP refines. Also moved the kernel cyrius pin 6.0.1 → 6.0.3 (byte-identical A/B). `rtc-smoke.sh` green.
- **1.35.4 — `munmap`**: syscall 28 + the inverse of mmap (PD-walk → `proc_unmap_page` + `invlpg` → `pmm_free_2mb`) + LIFO arena reclaim. Closes the mmap/munmap pair. `mmap-smoke.sh` 2/2.
- **1.35.3 — anonymous `mmap`**: syscall 27 + `pmm_alloc_2mb` 2 MB-contiguous allocator; 2 MB-granular zero-filled memory into the caller's address space. First new functional syscall since v1.21.0. (Was the roadmap `mmap (anonymous-only)` open item.)
- **1.35.0–1.35.2 — networking-comms arc**: DNS stub resolver + ICMP/ping + TCP hardening (B0–B4) + NTP/SNTP. The reliable-stream + name-resolution + wall-clock substrate for TLS. All RELEASED + smokes green.
- **1.34.x — FAT-family arc**: FAT12/16/32 + exFAT read **and write** (LFN, cluster allocator, root extension, spanning-append, overwrite/truncate/delete) + ESP-write safety guard (1.34.6). `fsck.fat` / `fsck.exfat` / `mtools` validated.
- **1.33.x — ext2/4 WRITE arc**: file create/write/truncate on ext2/ext4; persist-across-reboot iron-validated (Attempts 90/91).
- **1.32.x — networking arc**: TCP/UDP server primitives + DHCP client + r8169 NIC; iron-COMPLETE (DHCP lease verified 1.32.9; r8169 RX fix 1.32.7).
- **1.31.x — storage arc**: NVMe (iron Attempt 80) + GPT + AHCI/SATA (iron Attempt 87) + USB-MS + RAM-disk + 5-backend block layer + ext2/ext4 read.
- **1.30.x — MVP gate**: typeable shell on archaemenid at Attempt 68 (1.30.9) + FB-hardening sweep (true-font swap 1.30.12).
- **1.27.x – 1.29.x and earlier**: Path-C sovereign UEFI ABI (1.30.0), KASLR / Security Hardening 13/13 (1.28.x), VFS tagged-unions (1.29.x) — see archived `CHANGELOG.md` entries.

---

## Verification hosts

| Host | Purpose | Status |
|---|---|---|
| Self-hosted GH runner (`agnos-runner`) | CI boot-test + benchmarks on real KVM | Active |
| Dev box (Arch, Linux 7.0.3, QEMU 11.0) | Local builds, boot, bench | Active |
| QEMU `-cpu max` x86_64 | Required for boot (boot shim sets SMEP+SMAP in CR4 — `qemu64` default lacks both, triple-faults) | — |
| QEMU `-M virt -cpu cortex-a57` aarch64 | Build target; live boot not yet wired | Compile only |

---

## Refresh discipline

[`CHANGELOG.md`](../../CHANGELOG.md) carries the full per-cut narrative; this file is current-truth + pointers, **not a log**. Arc-level summary lives in the "Recently closed" block above.

`scripts/version-bump.sh` keeps the header date + Version-table row + `roadmap.md "Current"` line fresh atomically with the bump. Body prose (Build artifacts sizes, Source rollup counts, Subsystem status table, In-flight table, Recently-closed bookmarks) needs a **manual sweep at each minor closeout** — the script touches the header, not the body. This pattern was established during the 2026-05-18 doc-staleness audit (script-fresh header found next to v1.29.0-era body prose); the 1.35.0 cycle-open sweep (2026-05-26) brought the body forward from its frozen 1.31.1 shape through the 1.32.x networking / 1.33.x ext2-4-write / 1.34.x FAT-family arcs.
