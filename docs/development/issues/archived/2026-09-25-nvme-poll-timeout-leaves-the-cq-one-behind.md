# 2026-09-25 — NVMe: an I/O poll timeout leaves the completion queue one entry behind for the rest of the boot

**Status:** ✅ **RESOLVED 1.57.8 (2026-09-25)**. Step NVME changed three things. `nvme_io_poll_n` runs on a wall-time budget: 5 s per transfer and 30 s per FLUSH (`klog_uptime_us`). It consumes every CQE by CID and discards strays, and it records a timed-out CID as late. `nvme_io_settle()` reaps that CID before any DMA buffer is reused, and disables the controller if the CID never arrives. Gate: `scripts/smoke/nvme-late-smoke.sh` (`NVME_SELFTEST` arms stamp, shift, reuse and lost; the disk is throttled to 100 IOPS; sweep row at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
**Filed by:** agnos, from the 1.57.7 S8 step report and `steps/HARNESS-BACKLOG.md` (S8 row).
**Checked against:** agnos **1.57.7**, `kernel/core/nvme.cyr` `nvme_io_poll_n` (~:785-814).
**Severity:** a permanent I/O desync after one slow completion: every later command may complete with the
PREVIOUS command's status, and a read may return the previous command's data.

## What happens

`nvme_io_poll_n(expected_cid, max_iters)` gives up after a fixed ITERATION count (10M) and returns −1 without
consuming the late completion. The next command's poll then consumes the previous command's CQE, logs
`nvme: I/O CID mismatch expected=N got=N-1`, and returns that entry's status as its own. From then on every poll
is one behind. Observed in `wait-ring3-smoke` `-smp 4` under KVM with the host loaded by parallel QEMU runs:
`nvme: I/O poll timeout` at 33.5 s, then 1,704 mismatch lines; the waitx driver never finished (10 FAIL). The
re-run passed (60/0).

## The fix (1.57.8)

- a time-based poll budget (TSC via `sched_clock_us`, or the PM timer before calibration), not an iteration count;
- on a CID mismatch, do not return the stale entry's status: consume by CID (drain entries until the expected CID,
  or record the late CID and discard it when it arrives), so a timeout cannot shift every later command;
- a timed-out command's buffer must not be reused until its completion is consumed (the device may still DMA into it).

## Gate

An `NVME_SELFTEST` arm that forces one timeout (a tiny budget on one command), then issues N reads of known LBAs
and checks every CID and every byte (RED on today's code: mismatch lines and wrong data); `wait-ring3-smoke` and
the ext2 smokes stay green.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/logs/S8/final/reg/wait-run1/waitx-smp4.log`, `wait-ring3-smoke.log` (FAIL) vs `wait-ring3-smoke.run2.log` (PASS).

## Resolution (1.57.8, 2026-09-25)

**What shipped:**
- **The budget.** It is checked before the CQ, so a zero budget gives up without looking. A spin backstop of
  budget × 64 applies when the TSC reads 0.
- **CID matching.** The expected CID returns its status. Any other CID is logged as a stray and discarded.
- **Settle points.** `nvme_io_settle()` runs at the top of `nvme_rw_internal`, in flush, before both bounce copies
  (`nvme_blk_write`, `nvme_blk_write_sectors`), and on the failure path of both caller-buffer paths
  (`nvme_read_sectors`, `nvme_write_sectors`).
- **A lost completion.** If the CID never arrives, the controller is disabled (`CC.EN = 0`, `nvme_io_ready = 0`), so no
  buffer goes back to a live device.
- **Mutations.** The old poll gives a shift FAIL (960 bad words; the CQ left one behind), and reuse and lost FAIL too.
  Dropping the bounce settle makes reuse FAIL only on the throttled disk, which is why the smoke throttles.
- **Docs.** New `docs/architecture/nvme-io-completion.md`.

**What the change broke — checked before archiving:** nothing found. `wait-ring3-smoke` 60/0, `ext2-write-smoke` and
`blk-write-smoke` stay green, and the end review found no blocker. Residuals, documented and not defects of this
change:
- `nvme_lock` is held with preemption off for up to 5 s (30 s for FLUSH), plus up to 5 s in settle, while a device is
  dead. This is by design.
- If `nvme_disable` itself times out, the device may stay live.
- The caller-buffer settle-on-failure is not exercised by the selftest. It is the same call the reuse arm proves.
- `nvme_admin_poll` (init only) keeps the iteration budget and the stale-status-on-mismatch behaviour. Filed with the
  AHCI twin as `2026-09-25-ahci-timeout-abandons-an-in-flight-command.md`.

Found on the way, the same class, and fixed in 1.57.8 by DMA1: virtio-blk's abandoned FLUSH (`vblk_wait` /
`vblk_settle`).

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/NVME-report.json`, `NVME-endreview.json`; logs under `logs/NVME/`.
