# 2026-09-25 — harness: blk-write and ext2 (arm 1) score a firmware VOID as a FAIL; msc-short has no `-smp 4` variant

**Status:** 🟡 **OPEN**, unslotted. These are pre-existing harness defects that the 1.57.8 steps found. Under the
gate-budget rule they were not fixed inside those steps.
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
