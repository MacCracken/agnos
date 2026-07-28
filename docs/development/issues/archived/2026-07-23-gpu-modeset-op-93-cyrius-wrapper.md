# 2026-07-23 — #92 `gpu_shader_op` + #93 `gpu_modeset_op` — wrappers wanted (target cyrius 6.4.73)

**Target: cyrius 6.4.73.** Two wrappers, same shape, and they are the **only** ones left outstanding in the
`82…93` GPU band (verified against `lib/syscalls_x86_64_agnos.cyr` and `issues/archived/` — see the band
table below; two of agnos's own issue docs were stale on this and were corrected while filing).

| # | Status | Urgency |
|---|---|---|
| **`#92 gpu_shader_op`** | 🔴 **agnos SHIPPED it and a consumer is working around the missing wrapper right now** with a raw `syscall(92, …)` — `aethersafha/src/gpu.cyr:97-102`. Lands on Linux `chown(path,…)`, the band's **most dangerous** collision. | **Higher.** Real code, today. |
| **`#93 gpu_modeset_op`** | 🟡 **Shape frozen + operator-ratified (MD-4); kernel half not yet implemented** (agnos bite H3). | Safe to wrap ahead of the kernel — reason is structural, see *"Why early is safe here"*. |

They take the **identical `(desc_uva, len)` signature** — descriptor array, op code inside the record. One
pattern, twice.

Unlike the Tier-2 rows of
[`archived/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md`](archived/2026-07-22-gpu-display-syscall-band-cyrius-wrappers.md)
— which said *"do not wrap these until agnos ships each"* — **`#93` is safe to wrap early**, and the
reason is structural rather than a judgement call.

Mirror (language-agent territory — agnos does not edit it):
`cyrius/docs/development/issues/2026-07-23-agnos-gpu-modeset-op-93.md`.

---

## What it is

The single ring-3 entry point for the **MODESET** work — item 7 of the one open GPU release
(agnos `docs/development/planning/gpu.md`). Every modeset write bite (`M4`–`M9`) drives from a userland
tool `/bin/modeset` through this one syscall, behind an on-disk arm-once latch.

```
#93  gpu_modeset_op(desc_uva, len) -> 0 / negative
```

Two arguments. `desc_uva` is a **userland VA** pointing at an **array of fixed-size descriptor records**;
`len` is the byte length of that array. The **op code lives inside each record**, not in the syscall number.

## Why it is ONE syscall with a descriptor array

Operator decision **MD-4**, ratified 2026-07-23, and shader-arc decision **D-3** before it. The shader arc
violated D-3 once and it cost an ABI break at S12: per-operation syscalls and inline scalar arguments run out
of argument slots (a gradient needing two stops plus geometry had **no room left at all** and never got a
ring-3 path). A record has no such ceiling. So the modeset band is **one number, extensible by record**, from
day one.

The kernel half follows `gpu_shader_op_sys` and `gpu_blit_shm_sys`: it **validates in-kernel**, **derives MC
addresses in-kernel** — *no MC address ever crosses the ring-3 boundary* — and **rejects rather than clips**.

## Why early is safe here (and why the "don't wrap until shipped" rule doesn't bite)

**The wrapper is layout-agnostic.** It passes a pointer and a length; it does not encode a single field of
the descriptor record. The record layout is still being finalised by bite H3 on the kernel side, and it can
keep evolving — adding ops, adding fields, growing the record — **without ever changing the wrapper's
signature**. That is the whole point of the descriptor-array design.

What is already frozen and will not move:

- the **number 93** (operator-ratified, MD-4),
- the **arity and meaning**: `(desc_uva, len)`,
- the **return convention**: `0` on success, negative on rejection,
- the **name** `gpu_modeset_op`.

The earlier "don't wrap until agnos ships" rule existed because those syscalls encoded *packed geometry* in
their arguments, so a kernel-side change to the packing would silently invalidate a shipped wrapper. That
failure mode does not exist for a `(ptr, len)` pair.

## ⚠ SAFETY — #93 collides with a Linux syscall, but it is the mildest of this band

| # | agnos | Linux x86_64 | Destructive? | Notes |
|---|---|---|---|---|
| 93 | `gpu_modeset_op(desc_uva, len)` | **`fchown(fd, uid, gid)`** | **Yes, but unlikely to land** | arg1 is a **userland VA** — a large value that is essentially never a valid fd — so a stray off-agnos call is overwhelmingly `EBADF`. Contrast **#92** (`chown`), whose arg1 is a *path* pointer and which therefore performs a real path-resolving metadata write. |

**This is a reason for calm, not for dropping the gate.** The **file-level `#ifdef CYRIUS_TARGET_AGNOS`
gate** is still required, exactly as for `#84`–`#92`: off-agnos these functions must **not exist**, so a
referencing build fails at *compile* time rather than issuing `fchown` at runtime. `EBADF-most-of-the-time`
is not a safety property.

agnos's side extends `scripts/agnos-crossbuild-gate.sh` with the new row when H3 lands.

## Wrapper shape (for the language agent — agnos does not add these)

```cyrius
SYS_GPU_MODESET_OP = 93;   # gpu_modeset_op(desc_uva, len) → 0/negative; ARRAY of descriptor records,
                           # op code INSIDE each record (D-3 / MD-4). Kernel validates + derives MCs;
                           # no MC address crosses the ring-3 boundary; rejects rather than clips.
                           # FCHOWN on Linux — arg1 is a userland VA so a stray call is ~always EBADF,
                           # but the gate is still load-bearing. Off-agnos this must not exist.
```
```cyrius
fn sys_gpu_modeset_op(desc_uva, len): i64 { return syscall(SYS_GPU_MODESET_OP, desc_uva, len); }
```

Docstring should carry: the descriptor-array contract (op code inside the record), the reject-don't-clip
rule, the Linux collision + why it is milder than #92's, and the **iron-only** caveat — QEMU emulates no AMD
GPU, so a return under QEMU means "no GPU here", not "the modeset worked".

## Status of the rest of the band — VERIFIED against cyrius 6.4.72 source, not against our own issue text

⚠ **Two of agnos's own issue documents were stale about this and were corrected while filing.** The band
state below was read from `cyrius/lib/syscalls_x86_64_agnos.cyr` and `issues/archived/`.

| # | agnos kernel | cyrius wrapper | Notes |
|---|---|---|---|
| `#82` `#83` | shipped | ✅ `sys_gpu_dispatch`, `sys_gpu_dispatch_f64` | compute band |
| `#84`–`#89` | shipped | ✅ through `sys_gpu_caps` (:674) | issue **closed + archived** |
| `#90` `#91` | shipped, iron-proven | ✅ `sys_gpu_readback_shm` (:687), `sys_gpu_blit_bb` (:699) | issue **closed + archived** — the "cyrius leg still OPEN" line in [`archived/2026-07-23-gpu-readback-blit-bb-wrappers.md`](archived/2026-07-23-gpu-readback-blit-bb-wrappers.md) is **STALE**; the wrappers landed |
| **`#92`** | shipped, consumed | ❌ **NONE — and there is a live in-house workaround** | see below |
| **`#93`** | **not yet** (bite H3) | ❌ **none** | this issue |

### ⚠ `#92 gpu_shader_op` has no wrapper, and a consumer is working around it right now

`aethersafha/src/gpu.cyr:97-102` says so explicitly and does a **raw `syscall(92, ...)`** behind its own
`#ifdef CYRIUS_TARGET_AGNOS`, calling that "the sanctioned in-house idiom" because the band's wrappers stop
at `#89`. agnos's own `/bin/gpublend` does the same. That is a real gap worth closing in the same 6.4.73
pass as `#93` — it is the **more urgent** of the two, because `#92` is already shipped, already consumed
end-to-end by the compositor, and lands on Linux `chown(path, uid, gid)` where **arg1 is a genuine user VA
the kernel would read as a path** — the most dangerous collision in the whole band.

```cyrius
SYS_GPU_SHADER_OP = 92;   # gpu_shader_op(desc_uva, len) → 0/negative; ARRAY of 64-byte op records.
                          # Every dword an op does not define MUST be zero — the kernel REJECTS a non-zero
                          # reserved field rather than ignoring it, which is what keeps unused dwords safe
                          # to define later without an ABI break.
                          # CHOWN on Linux — arg1 is a real user VA read as a PATH. Gate is load-bearing.
```
```cyrius
fn sys_gpu_shader_op(desc_uva, len): i64 { return syscall(SYS_GPU_SHADER_OP, desc_uva, len); }
```

**Note `#92` and `#93` share the exact same `(desc_uva, len)` shape** — descriptor array, op code inside the
record, kernel validates and derives MCs. Wrapping them together is one pattern, twice.

So the genuinely outstanding cyrius work is **`#92` and `#93`**, not three wrappers.

## Still open after the wrapper lands

- **The kernel half (agnos bite H3).** `/bin/modeset` + the handler + the record layout. Not blocked on
  cyrius; the two proceed in parallel.
- **Iron proof.** Every modeset arm is iron-only and several are console-risky; the wrapper being present
  changes nothing about that. The first consumer is `run /bin/modeset --caps`, which returns an op-support
  mask and a distinct exit code per failure mode.
