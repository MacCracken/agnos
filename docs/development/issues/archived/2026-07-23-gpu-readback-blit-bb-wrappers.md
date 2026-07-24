> ## ✅ CLOSED + ARCHIVED 2026-07-23
>
> **The cyrius wrappers this issue asked for HAVE LANDED** — verified against
> `cyrius/lib/syscalls_x86_64_agnos.cyr` at 6.4.72, not against this document:
> `sys_shm_create_gpu` (:640) · `sys_gpu_blit_shm` (:651) · `sys_gpu_fill_rect` (:662) ·
> `sys_gpu_caps` (:674) · `sys_gpu_readback_shm` (:687) · `sys_gpu_blit_bb` (:699), plus
> `sys_gpu_present` / `sys_gpu_fill` / `sys_gpu_dispatch{,_f64}`. The cyrius-side mirrors are in
> `cyrius/docs/development/issues/archived/`.
>
> ⚠ **Any "cyrius leg still OPEN" wording below is STALE** — it was true when written and is not now.
> Still-outstanding wrappers are tracked in
> [`2026-07-23-gpu-modeset-op-93-cyrius-wrapper.md`](../2026-07-23-gpu-modeset-op-93-cyrius-wrapper.md):
> **`#92 gpu_shader_op` and `#93 gpu_modeset_op` only.**

# 2026-07-23 — #90 `gpu_readback_shm` + #91 `gpu_blit_bb` now IMPLEMENTED in agnos — promote to wrappers-wanted

**Status:** 🟢 **IRON-PROVEN, wrappers wanted** (cyrius leg still OPEN). Promotes the two **Tier 2** rows of
[`2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md`](2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md)
— which said *"declared shape; agnos implements, then cyrius wraps … do not wrap these until agnos ships
each."* **agnos has now shipped AND iron-proven both** on archaemenid (`/bin/gpucopy` → `run: exit 95`,
2026-07-23) — including a fix for a readback-coherence bug (a reused `#90` slot returned a stale cache-line
ghost; `gpu_readback_shm_sys` now `clflush`es the destination window before the CP-DMA). Both are safe to wrap.

This closes the **numbering hole** in the GPU band. The kernel dispatch was contiguous through #89 and then
jumped to #92; #90/#91 were live-but-unimplemented. They are now implemented, so ring-3 wrappers can land the
whole `84…92` band with no gap.

Mirror (language-agent territory — agnos does not edit it):
`cyrius/docs/development/issues/2026-07-23-agnos-gpu-readback-blit-bb.md`.

---

## What agnos shipped (kernel half — build + check green)

Both handlers are implemented in `kernel/core/syscall.cyr`, dispatched at `num == 90` / `num == 91`, and
build clean: `scripts/build.sh` **OK**, `scripts/check.sh` **14 passed, 0 failed** (including the *call
arity* gate that catches argument-count drift). They are CP-DMA jobs on the same iron-proven `gpu_cp_dma_blit`
primitive that #87 already uses — no new engine work.

### `#90 gpu_readback_shm(id, wh, srcxy) -> 0 / -1`
The **inverse of #87 `gpu_blit_shm`**: GPU-copy a `w×h` rect **out of** the blit back buffer at `(sx,sy)`
**into** the client's carveout shm slot `id`. Screen-capture / read-pixels primitive. Without it a compositor
reading its own shm sees **stale** content — the composited frame lives in the kernel's GPU back buffer, never
in the client page (this is the silent regression the prior issue's Tier-2 note called out for
`aethersafha/src/screen_capture.cyr`). Captures the render target #87/#88/#92 write, before #84 flips.

- Pack: `wh = (h<<16)|w`, `srcxy = (sy<<16)|sx` (blit#39 convention).
- Rejects (does not clip): off-screen rect, a slot too small for `w*h*4`, a **PMM-backed** slot (`shm_mc == 0`
  ⇒ the GPU cannot *write* it — allocate with #86), or no usable display.

### `#91 gpu_blit_bb(srcxy, wh, dstxy) -> 0 / -1`
GPU rect **copy within** the blit back buffer — move a window / scroll a region entirely on the GPU, no
fb→fb copy existed anywhere before this.

- Pack: `srcxy = (sy<<16)|sx`, `wh = (h<<16)|w`, `dstxy = (dy<<16)|dx`.
- Rejects (does not clip) either rect off-screen.
- ⚠ **OVERLAP handled kernel-side — the wrapper does NOT need to.** The prior issue flagged *"per-row copy
  has no reverse-order path, so overlapping rects moving down/right will smear — either reject overlap or add
  a reverse-row mode."* **agnos took the reverse-row mode:** a downward move (`dy > sy`) copies rows
  **bottom-up**, so each source row is read before the overlapping destination row above it is overwritten
  (memmove semantics). Upward / non-overlapping moves stay top-down. The one residual, documented in the
  handler: **intra-row horizontal overlap on the SAME source row** is undefined (one CP-DMA reads-then-writes
  the whole row) — a caller must not self-overlap a single row. Vertical scrolling, the primary use, is safe
  both directions.

---

## SAFETY — unchanged from the prior issue's table; re-stated because both are destructive on Linux

Both land on **destructive** Linux x86_64 numbers. Full table + the live setu `#ifdef` demonstration are in
[`2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md`](2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md#-safety--this-band-collides-with-destructive-linux-syscalls);
the two rows that now need wrappers:

| # | agnos | Linux x86_64 | Destructive? | Notes |
|---|---|---|---|---|
| 90 | `gpu_readback_shm` | **`chmod(path,mode)`** | **YES** | A packed geometry word reinterpreted as a mode can set **setuid**. Mitigating: arg1 is a 1..N id ⇒ near-null path ⇒ EFAULT overwhelmingly likely. |
| 91 | `gpu_blit_bb` | **`fchmod(fd,mode)`** | **YES** | arg1 is a packed `srcxy`; **`(0,0)` packs to fd 0 = stdin**, so small coordinates are all valid fd numbers and the Linux call would **plausibly SUCCEED**. |

**Requirement:** the **file-level `#ifdef CYRIUS_TARGET_AGNOS` gate** (as for #84–#89) is the only barrier —
off-agnos these functions must **not exist** so a referencing build fails at compile time.

## Wrapper shape (for the language agent — agnos does not add these)

```cyrius
SYS_GPU_READBACK_SHM = 90;   # gpu_readback_shm(id,wh,srcxy) → 0/-1; capture bb→shm.
                             # CHMOD on Linux — a metadata WRITE that can set setuid. Gate is load-bearing.
SYS_GPU_BLIT_BB      = 91;   # gpu_blit_bb(srcxy,wh,dstxy) → 0/-1; bb→bb move/scroll (overlap-safe kernel-side).
                             # FCHMOD on Linux — (0,0) packs to fd 0 = stdin, would PLAUSIBLY SUCCEED. Gate load-bearing.
```
```cyrius
fn sys_gpu_readback_shm(id, wh, srcxy): i64 { return syscall(SYS_GPU_READBACK_SHM, id, wh, srcxy); }
fn sys_gpu_blit_bb(srcxy, wh, dstxy): i64   { return syscall(SYS_GPU_BLIT_BB, srcxy, wh, dstxy); }
```

Docstrings should carry: the packing, the reject-don't-clip contract, the Linux collision + destructive flag,
and the **iron-only** returns (`0`/`-1` under QEMU means "no GPU here", not a failure).

## Still open after the wrappers land

- **Iron proof.** Both are pixel-path primitives; QEMU emulates no AMD GPU, so neither is *proven* until a
  burn. #90 in particular fails **silently** if wrong (stale-but-plausible pixels), so its oracle must compare
  a readback against known composited content, not merely check the return code.
- **Consumers** (from the prior issue): #90 → `aethersafha/src/screen_capture.cyr`; #91 → `win_move` /
  `rend_dmg_*` damage-driven redraw + scrolling.
