# 2026-07-14 — GPU-compute dispatch syscalls `gpu_dispatch` (#82) / `gpu_dispatch_f64` (#83) + their cyrius wrappers

**Status:** 🟡 **OPEN** (cyrius leg). **Kernel:** done + **iron-proven** on archaemenid — `#82` cut
**1.54.30** (pointer-hardened at **1.54.33**), `#83` cut **1.54.33**. **cyrius:** `SYS_GPU_DISPATCH = 82` /
`SYS_GPU_DISPATCH_F64 = 83` + agnos-gated wrappers — **this ask**. **Consumer:** `gpumm` 0.2.0 currently
calls the raw `syscall(82, …)` / `syscall(83, …)` and would migrate to the named wrappers.

Mirror: `cyrius/docs/development/issues/2026-07-14-agnos-sys-gpu-dispatch-wrappers.md`.

## ⚠ Why the agnos gate is a SAFETY requirement, not a nicety

On **Linux x86_64**, syscall **82 = `rename(oldpath, newpath)`** and **83 = `mkdir(path, mode)`**.

An ungated wrapper would not merely "not work" on Linux — it would pass the caller's **matmul buffer
pointers as filesystem paths** and attempt to **rename a file** or **create a directory**. This is sharper
than the `readdir`#81 precedent (81 = `fchdir` on Linux, harmless by comparison). Both wrappers **must** be
`#ifdef CYRIUS_TARGET_AGNOS`-gated, and on non-agnos targets must return an error **without emitting the
syscall instruction**.

## Problem

The 1.54.x GPU arc gave agnos sovereign GPU compute — the AMD Cezanne iGPU (gfx90c) driven directly by the
kernel with **no amdgpu and no ROCm**: PSP firmware load → CP/MEC engines → GPUVM → PM4 → hand-assembled
gfx90c shaders → an 8×8 matmul running on the shader cores, verified bit-for-bit against a CPU reference on
real hardware. The **ring-3 seam** that exposes this to userspace is `#82`/`#83`.

This is the path the sovereign GPU-compute/ML libraries (**mabda / tentib / attn11**) consume to run
inference on the GPU *on agnos* — mabda's GPU surface is Linux-only today, and this is its agnos backend.
Programs currently reach it via a raw `syscall(82, …)`, which is both unergonomic and (per the warning
above) dangerous to write portably.

## Kernel side (done — iron-proven)

Both handlers live in `kernel/core/gpu.cyr`; dispatch in `kernel/core/syscall.cyr`.

### `#82 gpu_dispatch(a, b, c) -> 0 / <0`
- `a`, `b`: ring-3 pointers to **64 × i32**, row-major 8×8 (256 bytes each).
- `c`: ring-3 pointer to **64 × i32** — receives `C = A · B`.
- The kernel copies A/B into the GPU carveout, runs the proven `gfx90c` integer matmul on the shader cores,
  and copies C back.
- **Iron:** `gpu: userspace matmul OK (64/64 bit-correct vs CPU)` on archaemenid (1.54.30).

### `#83 gpu_dispatch_f64(a, b, c) -> 0 / <0`
- Same shape, **f64**: `a`, `b`, `c` are ring-3 pointers to **64 × f64**, row-major 8×8 (512 bytes each).
- **rosnet-bit-correct**: the shader accumulates with separate `v_mul_f64` + `v_add_f64` (two roundings,
  k-ascending) — deliberately **not** a fused `v_fma_f64` — because rosnet accumulates as mul-then-add
  (`f64v_fmadd` lowers to `mulpd+addpd`; the scalar path is `f64_add(y, f64_mul(x, W))`). Proven on iron
  against rounding data where fused-vs-unfused diverge on 29/64 outputs.
- **Iron:** `gpu: f64 matmul rosnet-bit-correct (8x8, rounding)` (1.54.32) and, from ring 3,
  `gpu: userspace f64 matmul OK (64/64 rosnet-bit-correct)` (1.54.33).

### Return codes (both)
| Code | Meaning |
|---|---|
| `0` | OK — `C` written |
| `-1` | GPU not ready (no AMD GPU / engines or shader unproven — e.g. **QEMU**, which emulates no AMD GFX) |
| `-2` | Dispatch did not complete (watchdog) |
| `-3` | VM fault |
| `-4` | A pointer is outside the caller's user range |
| `-5` | A user page is not mapped |

### Behaviour notes for the wrapper docs
- **Iron-only.** Under QEMU these return `-1` cleanly (verified via `basestack-run-smoke.sh`: the ELF loads,
  runs in ring 3, calls the syscall, takes the `-1` path, exits — no fault).
- **Blocking.** The handler busy-waits on a bounded watchdog (~100 ms cap) for the dispatch fence.
- **Hardened** (1.54.33): `is_user_range` on all three pointers; A/B reads go through `proc_copy_from_user`
  (page-walks the caller's CR3, refuses not-present/non-user pages); the C write-back is preceded by a
  present+user page-walk verify.
- Fixed 8×8 today. A future generalized (M,N,K) form would take new numbers, not new semantics here.

## cyrius-side ask

Mirror the existing agnos band (`lib/syscalls_x86_64_agnos.cyr`), same shape as the `SYS_SND_*` / `SYS_BLK_*`
rows:

```cyrius
SYS_GPU_DISPATCH     = 82;   # gpu_dispatch(a,b,c) -> 0/-1..-5; 64xi32 A,B -> C=A*B on the GPU shader cores
SYS_GPU_DISPATCH_F64 = 83;   # gpu_dispatch_f64(a,b,c) -> 0/-1..-5; 64xf64, rosnet-bit-correct
```

```cyrius
fn sys_gpu_dispatch(a, b, c): i64     { return syscall(SYS_GPU_DISPATCH, a, b, c); }
fn sys_gpu_dispatch_f64(a, b, c): i64 { return syscall(SYS_GPU_DISPATCH_F64, a, b, c); }
```

**Requirements**
1. **`#ifdef CYRIUS_TARGET_AGNOS`-gated** — see the safety warning above (82 = `rename`, 83 = `mkdir` on
   Linux). On non-agnos targets: return an error, do **not** emit the syscall.
2. Document the return codes + the iron-only `-1` in the wrapper comments, so a consumer treats `-1` as
   "no GPU here" rather than a failure.
3. Land for the next cyrius release; `gpumm` then migrates off the raw numbers and re-pins.

## Consumers

- **`gpumm`** (0.2.0) — the reference ring-3 consumer; runs both matmuls and verifies each against a CPU
  reference. Migrates to the named wrappers once they land.
- **mabda / tentib / attn11** — the real target: this is mabda's *agnos* GPU backend seam.
