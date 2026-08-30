---
name: tri corner bound coordinate frame
description: "#92 ops 0x09/0x0A validate the frame-skew corner bound in SCREEN coordinates while the shader samples RECT-LOCAL ones"
type: issue
---

# `#92` ops 0x09 / 0x0A — the frame-skew corner bound is evaluated in the wrong coordinate frame

**Found** 2026-08-30, by an adversarial review of the 1.56.52 P2 batch — not by the 1.56.51 audit
sweep, which did not look at either bound.

**Status**: OPEN, and deliberately not fixed in 1.56.52. Op 0x09 is **shipped and burned**
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
