# 2026-09-25 — harness: blk-write and ext2 (arm 1) score a firmware VOID as a FAIL; msc-short has no `-smp 4` variant

**Status:** ✅ **RESOLVED 1.57.9 (2026-09-26)** — `blk-write-smoke` and `ext2-smoke` boot through `qemu_dwell_kernel` + `qemu_assert_booted` (a firmware VOID exits 2 with its reason; per-run log paths); ext2's arm 1 uses the NVMe ESP recipe; `msc-short-smoke` loops `${MSC_SHORT_SMP:-1 4}` with the `-smp 4` half gated; the 8 stale issue-path comments are fixed. Gate: blk-write PASS at `-smp 1` and `-smp 4`, ext2 7/0/0, msc-short PASS at both. See § Resolution.
**Filed by:** agnos, from the 1.57.8 `steps/HARNESS-BACKLOG.md` (NVME, XHCI and DMA1 rows).
**Checked against:** agnos **1.57.8**, `scripts/smoke/blk-write-smoke.sh` (~:56-75),
`scripts/smoke/ext2-smoke.sh` (arm `1-baseline`) and `scripts/smoke/msc-short-smoke.sh`.
**Severity:** a false red, which causes wasted bisects, plus a missing SMP variant. There is no kernel defect.

## What happens

1. **`blk-write-smoke.sh`** runs its own `qemu-system-x86_64 &` plus a `sleep 1` poll loop, with no banner gate
   (neither `qemu_dwell_kernel` nor `qemu_assert_booted`). A firmware VOID (`gnoboot: fail @ EBS`) is therefore
   scored as a "blkwr never dispatched" FAIL. It also writes fixed `/tmp/blkwr-*.log` paths, which collide across
   parallel trees.
2. **`ext2-smoke.sh` arm `1-baseline`** puts the ESP on virtio-blk, which does not boot on this box. The resulting
   OVMF boot menu is scored as "FAIL: 1-baseline did NOT reach shell (regression!)". Arms 2–5 pass.
3. **`msc-short-smoke.sh`** boots `-cpu max` with no `-smp` and no `smoke_accel`, although MSC is reached from
   ISR and syscall paths on SMP boxes. The XHCI step ran a scratch copy at `-smp 4` under KVM, and it passed.

## The fix

- Move `blk-write` and `ext2` onto `qemu_dwell_kernel` (exit 2 on VOID) and use per-run log paths.
- Move ext2's arm 1 to the NVMe ESP recipe, or classify it VOID.
- Loop `msc-short` over `${MSC_SHORT_SMP:-1 4}`, as `msc-cdb-smoke` does, and gate the `-smp 4` half.

## Gate

For each smoke: a forced VOID (an ESP that does not boot) reports VOID and exits 2, not FAIL. `msc-short` prints
both SMP verdicts.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/HARNESS-BACKLOG.md`; `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/logs/DMA1/reg-ext2.log`; `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/logs/XHCI/msc-short-smp4.log`.

## Resolution (1.57.9, 2026-09-26)

Prior art followed: Linux kselftest (distinct PASS / FAIL / SKIP / timeout results), LAVA / KernelCI (infrastructure failure is not
a test failure), xfstests' `notrun`.

What it broke: nothing. Left for the harness issue `2026-09-26-harness-backlog-after-1-57-9.md`: blk-write and ext2 are still not
sweep rows, 53 older dangling issue-path comments, `ktest.sh` leaves a TEST kernel in `build/agnos`, the fixed `/tmp/sweep-gate.log`.
