---
name: tri corner bound coordinate frame
description: "#92 ops 0x09/0x0A validate the frame-skew corner bound in SCREEN coordinates while the shader samples RECT-LOCAL ones"
type: issue
---

# `#92` ops 0x09 / 0x0A — the frame-skew corner bound is evaluated in the wrong coordinate frame

**Found** 2026-08-30, by an adversarial review of the 1.56.52 P2 batch — not by the 1.56.51 audit
sweep, which did not look at either bound.

**Status:** ✅ **FIXED AND NOW ACTUALLY GATED — 1.56.55.** ⛔⛔ **The fix landed without any mutation coverage on op 0x09 — THE BURNED OP THE RULING WAS ABOUT — and that was found by re-auditing this record, not by the battery.** Measured 2026-08-31: every op-0x09 record in the battery sat at `dstxy 0`, including the frame-skew case *this same cut moved to the origin*, except `tri: dst runs off the framebuffer`, which returns `GPO_E_DIM` ~90 lines before the corner loop and cannot reach it. At `dx=dy=0` the screen and rect-local corner sets are **identical by construction**, so reverting `gpo_validate_tri` to `dx`/`dy` left the battery **GREEN**. The only discriminating case in the file was op **0x0A**`s, which routes to `gpo_validate_trilist` and never to `gpo_validate_tri` — the unburned sibling had the test, the burned primary did not.
⭐ **Closed with two new cases (battery 175 → 177) and the mutation now fails by name on op 0x09**: reverting the corner loop to screen coordinates reports `edge-abi: FAIL tri: a tiny triangle FAR from the origin clears the bound (rect-local) want 29 got 23` — `GPO_E_NOTIMPL` (bound accepted) against `GPO_E_FRAME` (old bound rejected). Arithmetic, not tuning: a 1 px triangle gives `a2 = 65536` (clears `GPU_TRI_AREA_MIN` at equality) and `lim = 67,108,864`; a 64x64 rect at (1024, 900) puts `|E|` at 4.16M rect-local and 71.27M in screen coordinates. It needs **both** a tiny triangle and a far rect — a 64 px triangle makes `lim` ~1000x either corner value and proves nothing, and a rect at the origin makes the frames coincide.
⚠ **Three load-bearing false comments swept in the same pass**, all calling the vertex frame screen-space when the shader never sees an origin: `syscall.cyr:2725` (inside `gpo_validate_tri` itself), and the op `0x0A`/`0x0B` per-triangle record layouts at `:1650` and `:1684` — the normative text a ring-3 caller reads. Verified against the source: `gpu_tri_prep(rec_phys, cov_mc, vx0..vy2, ca, cb, cc)` takes **no** `dx`/`dy`, `gpu_tri_dispatch` folds the origin into the destination address only, and `tri_rgba.s` bounds `px = tgid_x*64 + lane` by `s6 = w` and `py = tgid_y` by `s7 = h`.
⛔ **Still open, and filed separately:** the `#92` ABI table documents ops `0x00`-`0x08` and reasons `1`-`20`, while the kernel ships `0x00`-`0x10` and `1`-`29` — so `0x09`, `0x0A` and this issue`s own `GPO_E_FRAME` (`23`) have **no normative row at all**. See [`2026-08-31-gpu-op-92-abi-table-nine-ops-behind.md`](2026-08-31-gpu-op-92-abi-table-nine-ops-behind.md).

**Earlier status:** ✅ **FIXED 1.56.55**, on an operator ruling — **including op 0x09, which is shipped and burned.** Both `gpo_validate_tri` (0x09) and `gpo_validate_trilist` (0x0A) now evaluate the corner bound at RECT-LOCAL corners `(0,0)…(w-1,h-1)`, matching what the shader, the coverage pass and the byte-exact oracle all sample. Confirmed from `tri_rgba.s` directly: `px = tgid_x*64 + lane` bounded by `s6 = w`, `Pcx = (px << 16) + 0x8000`, and `gpu_tri_prep` takes no `dx`/`dy` — `gpu_tri_dispatch` folds the origin into the DESTINATION ADDRESS only.

⛔ **THE BATTERY COULD NOT SEE THE FIX AT FIRST, AND THAT IS THE PART WORTH REMEMBERING.** Both existing frame-skew cases produced their skew from DISTANCE (a small rect placed far away), which is exactly the quantity the corrected bound ignores — so they stopped tripping and had to be re-derived from the arithmetic: a 1 px triangle gives `lim = 65536 * 1024 = 67,108,864`, and `|E|` at the far corner is about `(w-1)<<16`, so the bound trips for `w >= 1026`. Both now use a 1088x512 rect at the origin.
⛔ Then every case sat AT the origin, where screen and rect-local coordinates COINCIDE — and reverting the bound to `dx`/`dy` left the battery **green**. Measured. A new case carries the discrimination: a tiny triangle under a 64x64 rect at `(1024, 900)`, which is accepted rect-locally (`|E|` ~4.1M) and rejected in screen coordinates (~71.2M). It needs BOTH a small triangle and a far rect; the 64 px fixture triangle makes `lim` ~1000x larger than either corner value and proves nothing. Battery **174 → 175**, and the mutation now fails by name.

**Original status:** OPEN, and deliberately not fixed in 1.56.52. Op 0x09 is **shipped and burned**
(`blend_alpha`/tri arc, iron 2026-08-16), so changing what its validator accepts is an ABI-semantics
change to a burned op. That wants an operator ruling, not a patch-release edit.

## Mechanism

`gpo_validate_tri` (op 0x09) and, since 1.56.52, `gpo_validate_trilist` (op 0x0A) bound the frame skew
by evaluating the two edge functions at the four corners of the destination rect:

```
var qx = dx;  var qy = dy;
if (ci == 1) { qx = dx + w - 1; }
...
var pcx = (qx << 16) + 32768;
```

Those are **screen** coordinates — the rect's position in the framebuffer.

The shader samples **rect-local** ones. `gpu_tri_list` → `gpu_tri_rgba(edge_mc, w, h, dx, dy, …)` →
`gpu_tri_prep(rec_phys, cov_mc, vx0..vy2, ca, cb, cc)` — no `dx`/`dy` parameter and no origin fold;
`k0b`/`k0c` are stored as `(ay*cx - ax*cy) << 16` verbatim. `gpu_tri_dispatch` folds the origin into
the **destination address** only (`dst_mc = bb_mc + dy * pitch + dx * 4`) and the eight USER_DATA
dwords it hands the shader do not contain `dx`/`dy` at all (s6 = w, s7 = h). `kernel/shaders/tri_rgba.s`
computes `px = tgid_x*64 + lane` bounded by s6, `py = tgid_y` bounded by s7, then
`Pcx = (px << 16) + 0x8000`. The coverage pass agrees — `edge_cov.s` uses the same rect-local `px`, and
`gpu_edge_cov` receives no `dx`/`dy`. So does the byte-exact oracle: `tests/gpu/gputri.cyr`'s
`tl_render_one` calls `tri_ref_px(xx, yy, …)` with `xx, yy` in `[0,w) x [0,h)`.

⇒ The validator bounds `|E|` over a set of points the hardware never evaluates, and does not bound it
over the set it does.

## Why it has not bitten

The vertices in a well-formed record are themselves rect-local (the battery's fixture triangles span
`(0,0)`–`(64,64)` with the rect at the origin), so for a rect at or near the origin the two frames
coincide and the bound is accidentally right. Measured 2026-08-30: a well-formed 64 px triangle with
the rect at `(1024, 900)` is still **accepted**, so the mismatch does not reject realistic batches.
That measurement is now a permanent battery case — `list: a well-formed batch at a NON-origin rect` —
so if anyone changes either bound and a non-origin batch starts being refused, it fails there by name.

## Why it still matters

The bound exists to stop the 96-bit numerator overflowing when a frame is small relative to the rect.
Evaluated in the wrong frame it is not measuring that quantity, so:

- it can **reject** a record the hardware would render (a far-from-origin rect with a legitimate
  triangle whose screen-coordinate `E` is large), and
- it can **admit** one that overflows (a large rect at the origin whose rect-local `E` runs away while
  the screen-coordinate corners happen to sit close to the triangle).

Neither has been demonstrated with a concrete record. Both follow from the frame mismatch.

## What a fix would have to settle

1. **Which frame is authoritative** — almost certainly rect-local, since that is what the shader, the
   coverage pass and the byte-exact oracle all use.
2. **Op 0x09's shipped behaviour.** Its battery case `tri: frame skew beyond the ratio` places a 1 px
   triangle under a 512x512 rect at `(1024, 900)` and expects `GPO_E_FRAME`. Under rect-local
   evaluation that record may no longer be refused, so the case has to be re-derived rather than
   re-run — and op 0x09 is burned, so a caller could be relying on the current refusal.
3. **Whether op 0x0A should be changed alone.** It is not burned and has no consumers yet, so it could
   move first — at the cost of two sibling validators disagreeing about the same shader, which is the
   condition that produced this defect in the first place.

⚠ Do **not** "fix" this by deleting either bound. The overflow it guards is real; only the frame it
measures in is wrong.
