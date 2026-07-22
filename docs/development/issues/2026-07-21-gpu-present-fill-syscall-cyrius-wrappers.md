# 2026-07-21 — Display/2D syscalls `present` (#84) / `gpu_fill` (#85) + their cyrius wrappers

**Status:** 🟡 **OPEN** (cyrius leg). **Kernel:** done + **iron-proven** on archaemenid — `#84` cut with the
P7 blit/present split (**1.55.x**), `#85` cut **1.55.30** (CP-DMA fill). **cyrius:** `SYS_GPU_PRESENT = 84` /
`SYS_GPU_FILL = 85` + agnos-gated wrappers — **this ask**. **Consumer:** `/bin/gpufill` (agnos `gpu-test/`)
currently calls the raw `syscall(84)` / `syscall(85, color)` and would migrate to the named wrappers.

Mirror: `cyrius/docs/development/issues/2026-07-21-agnos-sys-gpu-present-fill-wrappers.md`.

Continues the band established by `2026-07-10-readdir-syscall-cyrius-wrapper.md` (#81) and
`2026-07-14-gpu-dispatch-syscall-cyrius-wrappers.md` (#82/#83). The cyrius agnos enum currently **stops at
83** — #84/#85 are the gap.

## ⚠⚠ Why the agnos gate is a SAFETY requirement — the sharpest case in this band so far

On **Linux x86_64**: syscall **84 = `rmdir(pathname)`** and **85 = `creat(pathname, mode)`**.

- **`sys_gpu_present()` is NULLARY.** Ungated on Linux it emits **`rmdir()` with whatever stale value happens
  to be in `rdi`** — interpreted as a path pointer. That is a **destructive** call: it can *delete a
  directory*. Every prior collision in this band was non-destructive by comparison (`fchdir`#81 harmless;
  `rename`#82 / `mkdir`#83 damaging but not deleting). **This one removes data.**
- **`sys_gpu_fill(color)`** ungated becomes **`creat(color, mode)`** — a 32-bit pixel colour reinterpreted as
  a path pointer, creating/truncating a file at whatever that address decodes to.

The nullary hazard compounds a known issue: see `2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md`. A
nullary wrapper must not leak a caller-visible register into `a1`.

**Both wrappers MUST be `#ifdef CYRIUS_TARGET_AGNOS`-gated, and on non-agnos targets must return an error
WITHOUT emitting the syscall instruction.**

## Problem

The 1.55.x DISPLAY arc (Thrust P) gave agnos a sovereign 2D path on the AMD Cezanne iGPU (DCN 2.1 + the
gfx90c compute ring) with **no amdgpu**: scanout flip → vblank pacing → double-buffered blit → and, at
1.55.30, **hardware 2D acceleration via CP-DMA** (a PM4 `DMA_DATA` copy/fill executed on the MEC compute
ring). `#84`/`#85` are the ring-3 seam that exposes the present + clear half of that to userspace.

This is the path a sovereign compositor (**aethersafha**) consumes to clear and present frames without the
CPU touching every pixel. Programs currently reach it via raw `syscall(84)` / `syscall(85, …)`, which is
unergonomic and — per the warning above — genuinely dangerous to write portably.

## Kernel side (done — iron-proven)

Handlers in `kernel/core/gpu.cyr` (`gpu_blit_present`, `gpu_fill_sys`); dispatch in `kernel/core/syscall.cyr`.

### `#84 present() -> 1 / 0`
- **No arguments.** Flips the accumulated blit back buffer to the scanout, **tear-free and vsync-paced**.
- The explicit half of the blit/present split: a compositor blits its windows with `blit`#39's `DEFER_PRESENT`
  bit set (no flip), then calls this **once** to show the finished frame.
- `1` = presented; `0` = nothing to present (double-buffer not armed / direct-FB path — the deferred blits
  already hit the live FB).

### `#85 gpu_fill(color) -> 0 / -1`
- `color`: a 32-bit **xRGB8888** value.
- GPU-clears the **current blit back buffer** to `color` via a **CP-DMA** fill — a PM4 `DMA_DATA` constant-fill
  (`SRC_SEL=2 DATA`, the value in dw2) submitted on the proven MEC compute ring. Replaces a full-screen CPU
  store-loop. Arms the double-buffer lazily; pairs with `present`#84 to show the result.
- **Ring-3 names only the colour.** The kernel targets the back buffer internally, so **no GPU MC address
  crosses the syscall boundary** and `fb_phys` stays unexposed — the same discipline as `blit`#39.
- `0` = filled; `-1` = no usable display (no GPU/pipe — e.g. **QEMU**) or the fill failed.

### Behaviour notes for the wrapper docs
- **Iron-only.** Under QEMU (which emulates no AMD GFX) `#85` returns `-1` and `#84` returns `0` **cleanly** —
  no fault. Consumers should treat these as "no GPU here", not as an error, exactly like the `#82`/`#83`
  precedent.
- **Both block.** `#84` blocks until the pipe takes the surface at the next vblank (≤ one frame) — that is the
  point, it *is* the vsync pacer. `#85` busy-waits on a bounded CP-DMA completion fence (~100 ms cap).
- `#85`'s fill is **scanout-visible with no cache flush**: the CP-DMA writes MC-direct (`DST_SEL=0`), bypassing
  GL2, so no `ACQUIRE_MEM` is required.
- **Iron proof of the primitive:** `gpu: CP-DMA hardware fill verified (4KB, all=pattern)` (1.55.30), alongside
  `gpu: CP-DMA hardware copy verified (4KB, dst==src)`. End-to-end ring-3 exercise: `/bin/gpufill`.

## cyrius-side ask

Mirror the existing agnos band (`lib/syscalls_x86_64_agnos.cyr`), same shape as the `SYS_GPU_DISPATCH*` rows
that already carry their Linux-collision note:

```cyrius
SYS_GPU_PRESENT = 84;    # present() → 1/0; flip the blit back buffer to the scanout (RMDIR on Linux — DESTRUCTIVE)
SYS_GPU_FILL    = 85;    # gpu_fill(color) → 0/-1; GPU-clear the back buffer via CP-DMA (CREAT on Linux)
```

```cyrius
fn sys_gpu_present(): i64   { return syscall(SYS_GPU_PRESENT); }
fn sys_gpu_fill(color): i64 { return syscall(SYS_GPU_FILL, color); }
```

**Requirements**
1. **`#ifdef CYRIUS_TARGET_AGNOS`-gated** — see the safety warning above. `84 = rmdir` on Linux **deletes**;
   this is not a portability nicety. On non-agnos targets: return an error, do **not** emit the syscall.
2. **`sys_gpu_present()` is nullary** — ensure no stale/caller register leaks into `a1` (cf.
   `2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md`).
3. Document the iron-only returns in the wrapper comments so `-1` / `0` read as "no GPU here" rather than a
   failure.
4. Land for the next cyrius release; `gpufill` then migrates off the raw numbers and re-pins.

## Consumers

- **`/bin/gpufill`** (agnos `gpu-test/`, 0.1.0) — the reference ring-3 consumer: fills red/green/blue via
  `#85` and flips each in via `#84`; exits `95` iff every fill+present succeeded.
- **aethersafha** — the real target: compositor back-buffer clears (`#85`) + frame present (`#84`).
