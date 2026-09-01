---
name: "#92 ABI table is nine ops and nine reason codes behind the kernel"
description: "agnos-userland-abi.md documents gpu_shader_op#92 ops 0x00-0x08 and reasons 1-20; the kernel ships 0x00-0x10 and 1-29, and GPU_OP_SUPPORTED advertises all of them to ring 3"
type: issue
---

# `#92` — the normative ABI table stops at op `0x08`; the kernel ships through `0x10`

**Status:** 🟡 **OPEN — a documentation gap on a SHIPPED and partly BURNED surface.**
**Filed:** 2026-08-31 (1.56.55), out of the open-issue re-audit.
**Repo owning it:** agnos. No cyrius peer — `#92` has no cyrius wrapper at all; callers use a raw
`syscall(92, …)` (aethersafha `src/gpu.cyr` records this: *"THERE IS NO CYRIUS WRAPPER FOR #92. The
band's wrappers stop at `sys_gpu_caps` (#89)"*).
**Severity:** **Medium.** Nothing is broken and nothing regresses. But a ring-3 author reading the
normative contract concludes `0x08` is the last op and that a `23` return is undefined — and one of
the undocumented ops is **shipped and burned on iron**.

## The gap, exactly

`docs/development/agnos-userland-abi.md`'s `#92` op table ends at `| 0x08 | EDGE_COV |`, and its
reason-code table ends at `20`. `kernel/core/syscall.cyr` declares:

| op | name | declared at |
|---|---|---|
| `0x09` | `TRI_RGBA` — barycentric per-vertex RGBA + src-over (3D rung 11) | `syscall.cyr:1645` |
| `0x0A` | `TRI_LIST` — N triangles from a vertex slot (rung 12) | `syscall.cyr:1655` |
| `0x0B` | `TRI_TEX` — affine nearest-neighbour texturing (rung 13) | `syscall.cyr:1688` |
| `0x0C` | `TEX_LIST` — N textured primitives, ONE dispatch (rung 14) | `syscall.cyr:1789` |
| `0x0D` | `DEPTH_CLEAR` — clear a TD-3 depth handle (rung 17) | `syscall.cyr:1845` |
| `0x0E` | `TRI_DEPTH` — depth-tested triangle list (rung 17) | `syscall.cyr:1846` |
| `0x0F` | `TRI_PERSP` — perspective-correct textured triangles (rung 18) | `syscall.cyr:1852` |
| `0x10` | `RT_READ` — copy a render-target handle out to a `#86` slot (rung 17) | `syscall.cyr:1854` |

and reason codes `21 GPO_E_WORK`, `22 GPO_E_AREA`, **`23 GPO_E_FRAME`**, `24 GPO_E_TRILIST`,
`25 GPO_E_TEXSLOT`, `26 GPO_E_TEXDIM`, `27 GPO_E_LUTSLOT`, `28 GPO_E_MIXMODE`, `29 GPO_E_NOTIMPL`.

⛔ **These are not experimental.** `GPU_OP_SUPPORTED = 0x1FF5F` (`syscall.cyr:1859`) advertises every
one of them to ring 3, and its own comment says it **MUST equal what `gpo_validate` REACHES**. Op
`0x06 BLEND_ALPHA` and op `0x09` are iron-burned (2026-08-16 and the `blend_alpha`/tri arc).

## Why it is being filed rather than fixed

Writing nine normative op contracts — record layout, per-op flag vocabulary, work bound, and the
reason codes each can return — is a piece of work in its own right, derived from `gpo_validate*` and
cross-checked against the `#92` ABI battery. It is not a release-eve edit, and a half-derived table
would be worse than an absent one because it would read as authoritative.

⚠ **The absence is now stated in the doc itself** (a banner above the op table lists every missing op
and reason code and names `syscall.cyr`'s `gpo_validate*` plus the battery as the interim source of
truth), so the failure mode this issue guards against — a reader silently concluding `0x08` is the
end — is closed even while the rows are not written.

## Precedent, and why this matters more than it looks

This is the same shape as the `#96 fork` row that was missing until 1.56.55: a shipped, gated syscall
surface with no normative row, unnoticed because nothing compared the kernel against the doc. There,
the tooling gap was `syscall-abi-check.sh` scanning only `kernel/core/syscall.cyr` for the number set.
Here there is **no gate at all** — `syscall-abi-check.sh` compares syscall NUMBERS, not the op
vocabulary inside an op-dispatched syscall, so `#92`'s table can drift arbitrarily far with nothing
saying so. It has drifted nine ops.

⇒ **The durable fix is a gate, not a doc edit.** A check that parses `GPU_OP_* = 0x..` out of
`syscall.cyr` and the `| 0x.. |` rows out of the ABI doc, and fails on a mismatch, would have caught
this at the first op and would keep catching it. The same check should compare `GPO_E_* = N` against
the reason table. That is the ask; the nine rows fall out of satisfying it.

## Related

- [`2026-08-30-tri-corner-bound-coordinate-frame.md`](2026-08-30-tri-corner-bound-coordinate-frame.md)
  — the `0x09`/`0x0A` corner-bound fix, whose own `GPO_E_FRAME` (`23`) return is one of the
  undocumented reason codes.
- [`2026-08-05-syscall-96-fork.md`](2026-08-05-syscall-96-fork.md) — the missing-row precedent, and
  the gate blind spot that allowed it.
