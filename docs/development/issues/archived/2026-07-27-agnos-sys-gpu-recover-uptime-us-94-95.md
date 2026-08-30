# agnos syscalls #94 `gpu_recover_op` and #95 `uptime_us` have no stdlib wrapper

**Status:** ✅ **RESOLVED — both cyrius wrappers exist and the class is now GATED.** Swept 2026-08-30. `SYS_GPU_RECOVER_OP = 94` and `SYS_UPTIME_US = 95` are in `lib/syscalls_x86_64_agnos.cyr`, and the three-way `syscall-abi-check.sh` gate now makes a missing peer a build failure rather than something a consumer discovers by calling `syscall(94, …)` raw.

**Original status:** ✅ **FIXED — verified 2026-08-07 against cyrius 6.5.9.** Filed 2026-07-27 against cyrius
**6.4.80** / agnos kernel **1.56.23**; sat labelled OPEN for eleven days after it shipped.
`lib/syscalls_x86_64_agnos.cyr` now carries `SYS_GPU_RECOVER_OP = 94` (line 140) and
`SYS_UPTIME_US = 95` (line 142) with `sys_gpu_recover_op(arm)` / `sys_uptime_us()` wrappers.

⭐ **This class of drift is now caught mechanically, not by memory.** `scripts/check/syscall-abi-check.sh`
(added 1.56.39, in `sweep.sh`) cross-checks the kernel's number set against the ABI doc and against
cyrius's wrapper band, with four negative controls. A missing wrapper fails the gate. That gate — not
this file — is what keeps the next one from rotting.
**Affects:** `cyrius/lib/syscalls_x86_64_agnos.cyr` (the agnos syscall band).
**Cross-filed** at `cyrius/docs/development/issues/` per the agnos↔cyrius convention
([[feedback_cross_repo_issues_both_repos]]).

**⚠ NOT A CYRIUS BUG.** Both syscalls landed in agnos after the band was last extended; the wrapper
file is simply behind. Filed now because **v6.4.x closeout / v6.5.0 open** is the natural point to
take them, and because the band is otherwise contiguous.

## Summary

The agnos syscall band in `lib/syscalls_x86_64_agnos.cyr` is contiguous and complete **through #93**:

```
SYS_GPU_READBACK_SHM = 90    SYS_GPU_BLIT_BB = 91
SYS_GPU_SHADER_OP    = 92    SYS_GPU_MODESET_OP = 93
```

agnos `kernel/core/syscall.cyr` implements **two more**, neither of which has an enum entry or a
wrapper:

| # | agnos | shape | shipped in |
|---|---|---|---|
| **94** | `gpu_recover_op(arm)` | one i64 arm selector → 0 / `<0` | 3D arc rung 5 (hang/recovery battery) |
| **95** | `uptime_us()` | nullary → microseconds, or **−1** if the TSC was never calibrated | rung-10 era |

## Why it matters — the barrier is the wrapper, and there isn't one

Every comment in the #82–#93 band names the same safety argument: the file-level
`#ifdef CYRIUS_TARGET_AGNOS` gate is what stops an agnos-band number being issued on Linux, where
these are entirely different calls. Without a wrapper, consumers call `syscall(94)` / `syscall(95)`
**raw**, which compiles and runs off-agnos with no gate at all:

- **#95 on Linux is `umask(mask)`.** Non-destructive in the sense that it only changes the caller's
  own file-creation mask — but it *succeeds*, returns a plausible small integer, and a tool timing
  itself would silently read that as a timestamp. This is the failure shape the band's own comments
  call out: the dangerous collisions are the ones that **succeed**.
- **#94 on Linux is `fchmodat`.** arg1 is read as a directory fd.

⚠ **This is not hypothetical — the in-tree burn instrument already does it.**
`agnos/tests/gpu/gputex.cyr` calls `syscall(95)` directly for its timing windows (it is the only
correct clock on the `run` path, since a foreground program executes with IF cleared and `uptime_ms`
#40 is frozen for its whole run). It is correct on agnos and unguarded everywhere else.

## Ask

Add to `lib/syscalls_x86_64_agnos.cyr`, inside the existing `CYRIUS_TARGET_AGNOS` gate:

```cyrius
SYS_GPU_RECOVER_OP = 94;   # gpu_recover_op(arm) -> 0/<0   (FCHMODAT on Linux)
SYS_UPTIME_US      = 95;   # uptime_us() -> us, or -1 if uncalibrated (UMASK on Linux — SUCCEEDS)

fn sys_gpu_recover_op(arm): i64 { ... }
fn sys_uptime_us(): i64 { ... }
```

⛔ **`sys_uptime_us` must propagate −1 unchanged.** agnos returns −1 specifically to distinguish "no
clock" from "0 µs elapsed"; the kernel comment records that conflating them **burned two flashes on
the rung-10 gate**. A wrapper that clamps, or that maps −1 to 0, re-creates exactly that defect one
layer up.

⚠ **`sys_gpu_recover_op`'s arms are compiled out of a production kernel** (they wedge the GPU on
purpose and are gated behind `GPU_RECOVER`). The wrapper should therefore be treated like the rest of
the GPU band — present unconditionally, returning whatever the kernel returns, with no assumption
that the arm exists in the running kernel.

## Precedent

Same shape as the already-archived `2026-07-08-agnos-sys-readlink-peer`,
`2026-07-09-agnos-sys-blk-peers`, `2026-07-09-agnos-sys-shm-peers`,
`2026-07-14-agnos-sys-gpu-dispatch-wrappers`, `2026-07-21-agnos-sys-gpu-present-fill-wrappers`,
`2026-07-22-agnos-gpu-display-syscall-band` and `2026-07-23-agnos-gpu-modeset-op-93` — the last of
which was wrapped **before** its kernel half landed, so wrapping a shipped-and-iron-proven pair is
strictly the easier case.

## Not in scope

There is no #96+. The band is complete at 95 as of agnos 1.56.23; this issue closes the gap rather
than opening a new one.
