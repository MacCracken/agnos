# 2026-07-22 — The GPU/display syscall BAND (#86-#91) + their cyrius wrappers (consolidated ask)

**Status:** 🟡 **OPEN** (cyrius leg). Supersedes the one-at-a-time pattern of
`2026-07-14-gpu-dispatch-syscall-cyrius-wrappers.md` (#82/#83, resolved) and
`2026-07-21-gpu-present-fill-syscall-cyrius-wrappers.md` (#84/#85, resolved in cyrius **[6.4.70]**).
**This is one ticket for the whole remaining band** so the cyrius side can land it in a single pass with
consistent gating and docstrings, rather than a new ask every time agnos ships a syscall.

Mirror: `cyrius/docs/development/issues/2026-07-22-agnos-gpu-display-syscall-band.md`.

**Two tiers — please treat differently:**
- **Tier 1 — EXISTS + IRON-PROVEN, needs wrappers now:** `#86 shm_create_gpu`, `#87 gpu_blit_shm` (agnos 1.55.31). **Validated on archaemenid 2026-07-22:** `/bin/gpublit` composited three GPU-blitted squares onto a GPU-filled background and presented them — the full compositor frame shape (clear → composite → flip) with zero per-pixel CPU work. Back-buffer stride and scanout confirmed in agreement (squares landed at the exact coded coordinates).
- **Tier 2 — SHAPE DECLARED, agnos implements first:** `#88 gpu_fill_rect`, `#89 gpu_caps`,
  `#90 gpu_readback_shm`, `#91 gpu_blit_bb`. Listed so the numbers stay contiguous and reserved, and so the
  wrapper work can be planned once. **Do not wrap these until agnos ships each** — they are documented here
  to prevent number drift, not to be implemented ahead of the kernel.

---

## ⚠⚠ SAFETY — this band collides with destructive Linux syscalls

agnos renumbers syscalls; the whole band lands on occupied Linux x86_64 numbers. An ungated wrapper does not
merely "not work" — it performs a **different, sometimes destructive, filesystem operation** on whatever
garbage the arguments decode to.

| # | agnos | Linux x86_64 | Destructive? | Notes |
|---|---|---|---|---|
| 86 | `shm_create_gpu` | `link(old,new)` | no | Two garbage pointers → FS litter |
| 87 | `gpu_blit_shm` | **`unlink(path)`** | **YES — DELETES A FILE** | arg1 is a 1..16 id ⇒ near-null ⇒ EFAULT likely, but it is state-influenced |
| 88 | `gpu_fill_rect` | `symlink(target,link)` | no | ⚠ arg1 is a 32-bit **colour** (e.g. `0x00FF0000` = 16 MB) which **can decode to a mapped address** — the string read is not guaranteed to fault |
| 89 | `gpu_caps` | `readlink(path,buf,sz)` | no (to FS) | ⚠ the kernel **WRITES** into arg2 for arg3 bytes — a wild process-memory write if rsi ever holds a mapped address |
| 90 | `gpu_readback_shm` | **`chmod(path,mode)`** | **YES** | **Materially the worst number in the band**: a packed geometry word reinterpreted as a mode can set **setuid**. Mitigating: arg1 is a 1..16 id ⇒ near-null path ⇒ EFAULT overwhelmingly likely |
| 91 | `gpu_blit_bb` | **`fchmod(fd,mode)`** | **YES** | **The one row where the Linux call would plausibly SUCCEED**: arg1 is a packed `srcxy`, and `(0,0)` packs to `0` = **stdin** — small coordinates are all valid fd numbers |

### This hazard is not hypothetical — it is live in the tree

`/home/macro/Repos/setu/src/buf.cyr:99-107`:

```cyrius
fn setu_buf_close(buf_id): i64 {
    #ifdef CYRIUS_TARGET_AGNOS
    return sys_shm_free(buf_id);           # shm_free#74
    #endif
    #ifndef CYRIUS_TARGET_AGNOS
    var path[48];
    setu_buf_path(buf_id, &path);
    return syscall(87, &path);             # unlink
    #endif
}
```

**Syscall 87 means `unlink` and `gpu_blit_shm` in the SAME FILE, ten lines apart, separated only by an
`#ifdef`.** This code is correct — but it is the clearest possible demonstration that the gate is
load-bearing, not stylistic.

**Requirement:** keep the existing **file-level** `#ifdef CYRIUS_TARGET_AGNOS` gate in `lib/syscalls.cyr`
(introduced for #84/#85 in 6.4.70). Off-agnos the functions must **not exist**, so a referencing build fails
at **compile** time with no binary emitted. cyrius's own stated reasoning — guarding N of ~80 rows is false
comfort when `SYS_OPEN=7` is Linux `lseek` — applies with more force here, given three destructive rows.

---

## Tier 1 — exists in agnos 1.55.31, wrappers wanted now

### `#86 shm_create_gpu(size) -> id (>=1) / -1`
The **GPU-visible** peer of `shm_create`#71. Same table and same `shm_write`#72 / `shm_read`#73 /
`shm_free`#74 afterwards — only the backing differs: the page is carved from the **GPU carveout** (2.5 GB in,
clear of console FB / back buffers / PSP TMR / compute arena) so it has an **MC address the CP-DMA engine can
read**.

This is not an optimisation. `shm_create`#71 uses `pmm_alloc_2mb()` → **system RAM**, which the GPU **cannot
reach at all** (bus-master is off by design; the engines see only the FB aperture). A GPU composite from a #71
buffer is impossible. Returns `-1` when there is no carveout (**QEMU**) — the caller falls back to #71 and the
CPU path, unchanged.

### `#87 gpu_blit_shm(id, wh, dstxy) -> 0 / -1`
GPU-composite a client surface from its carveout slot straight into the blit back buffer at `(dx,dy)`, via
the iron-proven `gpu_cp_dma_blit` (one CP-DMA per row; src stride `w*4`, dst stride = framebuffer pitch).
Replaces **both** the shm→userland read **and** the per-pixel composite loop — pixels never leave kernel
GPU-visible memory. Packing matches `blit`#39: `wh = (h<<16)|w`, `dstxy = (dy<<16)|dx`.

⚠ **Rejects rather than clips** anything off-screen — the compositor owns clipping, which is precisely why
`#89 gpu_caps` is a prerequisite for using this correctly.

```cyrius
SYS_SHM_CREATE_GPU = 86;   # shm_create_gpu(size) → id/-1; GPU-visible shm page (LINK on Linux)
SYS_GPU_BLIT_SHM   = 87;   # gpu_blit_shm(id,wh,dstxy) → 0/-1; GPU composite (UNLINK on Linux — DELETES)
```
```cyrius
fn sys_shm_create_gpu(size): i64          { return syscall(SYS_SHM_CREATE_GPU, size); }
fn sys_gpu_blit_shm(id, wh, dstxy): i64   { return syscall(SYS_GPU_BLIT_SHM, id, wh, dstxy); }
```

---

## Tier 2 — declared shape; agnos implements, then cyrius wraps

| # | Signature | Priority | Why |
|---|---|---|---|
| 88 | `gpu_fill_rect(color, wh, dstxy) -> 0/-1` | **P0** | The highest-value missing primitive. #85 fills the **whole** buffer; there is no rect form. `aethersafha/src/render.cyr:31-50` `fill_rect` runs ~10×/window/frame (body, titlebar, focus accent, 3 buttons) plus ~9×/frame for the shell panel — the Files window alone is ~189k `bhumi_fb_set` calls/frame, each 4 compares + 2 `load64` + 2 multiplies before one `store32`. CP-DMA-shaped: `h` × `gpu_cp_dma_fill(dst_mc + row*pitch, color, w*4)` |
| 89 | `gpu_caps(buf, len) -> 0/-1` | **P0** | Ring 3 currently cannot learn the **back-buffer** geometry, and #87 rejects off-screen rects, so a compositor *must* know true width/height to clip. Today the only capability probe is "call #86 and look for −1". `aethersafha/src/main.cyr:34-35` **hardcodes `AE_W=1280`/`AE_H=720`** and never calls `bhumi_output_query`. Info query, not a pixel op — the CP-DMA constraint doesn't apply |
| 90 | `gpu_readback_shm(id, wh, srcxy) -> 0/-1` | **P1** | **Prevents a silent regression.** `aethersafha/src/screen_capture.cyr:483-527` reads the *userland* fb; the moment the frame lives in the kernel back buffer, capture keeps returning plausible-but-stale pixels — failing quietly. CP-DMA is direction-agnostic (both operands are MC), so this is #87 with the operands swapped |
| 91 | `gpu_blit_bb(srcxy, wh, dstxy) -> 0/-1` | **P2** | Damage-driven redraw + scrolling. No fb→fb copy exists anywhere today; `win_move` mutates x/y and repaints from scratch, and `rend_dmg_*` tracks a dirty rect **nothing reads**. ⚠ **Specify at cut time:** per-row copy has no reverse-order path, so overlapping rects moving **down/right will smear** — either reject overlap or add a reverse-row mode |

---

## NOT CP-DMA — these need the compute-shader path (the alpha/translucency arc)

CP-DMA is a **byte mover with no ALU**: no blending, no ROP, no format conversion, no intra-row pixel
replication. The following must **not** be proposed as CP-DMA syscalls. They are *not* blocked — agnos has
**iron-proven programmable shader execution** on the gfx90c cores (`compute shader executed`, `integer matmul
online (bit-correct vs CPU)`, `f64 matmul rosnet-bit-correct`) with a ring-3 dispatch seam at **#82/#83**. These
belong to the **alpha/translucency arc** and will ride a compositing shader, not the DMA engine.

- **Alpha blend** — `aethersafha/src/render.cyr:54-66` (`rend_blend`), per-pixel `(sr*a + dr*ia)/255`.
- **Anti-aliased coverage blit** — `sadish/src/raster.cyr:432-480`; src-over modulated by an 8-bit coverage
  mask. This is *the* vector-text/shape path (rekha glyph → sadish path → coverage → blit).
- **Gradient blit** — `sadish/src/raster.cyr:491+`, per-pixel lerp + src-over.
- **Bitmap glyph draw** — `aethersafha/src/render.cyr:231-281`, `dhancha/src/surface.cyr:94-113`. 1bpp → 32bpp
  with a **transparent** background: a *conditional* per-pixel store, so neither a fill (would clobber the
  background) nor a copy (source is 1bpp). **Highest call-count site in the tree** (~128 bit-tests + ~40 writes
  per glyph per frame) and the one that most wants a shader. Until then, chrome text renders CPU-side into its
  own #86 slot and composites with #87.
- **Bresenham diagonals** — `sadish/src/draw.cyr:23-97`; non-rectangular, inexpressible in CP-DMA.
- **RGBX ↔ BGRX channel swap** — `bhumi/src/scanout.cyr:105-108` (currently only *warns*). A byte permutation
  *within* each pixel. Note there is no CPU path for this either — it is an unhandled case today.
- **X-axis integer scale** — `blit`#39's a4 bits [39:32] uses a CPU row-expand buffer. CP-DMA can repeat
  **rows** (Y scale = re-issue a row copy) but cannot replicate **pixels within** a row. **Explicit
  non-ask: do NOT add a scale field to #87/#88/#91.**
- **Shaped/alpha cursor** — doesn't exist yet. An *opaque square* cursor is just #88; a shaped one is shader
  work (or a DCN hardware cursor plane, which is display-pipe territory).

---

## Requirements

1. **File-level `#ifdef CYRIUS_TARGET_AGNOS` gate** for every row — three of them (#87, #90, #91) are
   destructive on Linux, and #91 would plausibly **succeed**.
2. Each wrapper's docstring carries its **Linux collision** and the destructive flag, as 6.4.70 did for
   #84/#85.
3. Document the **iron-only** returns (`-1` / `0` under QEMU = "no GPU here", not a failure).
4. Tier 2 rows are **reserved, not requested** — wrap each as agnos ships it.
5. Keep `scripts/agnos-crossbuild-gate.sh` coverage extended to the new rows.

## Consumers

- **aethersafha** — the compositor: #85 clear, #88 chrome rects, #87 window composite, #84 present, #89 to
  clip correctly, #90 for screen capture, #91 for damage/scroll.
- **bhumi** — `src/scanout.cyr` is the only target-specific file; the present path lands here.
- **setu** — client surfaces migrate from #71 to #86 so they are GPU-blittable.
- **`/bin/gpufill`, `/bin/gpublit`** (agnos `gpu-test/`) — the ring-3 proof programs.
