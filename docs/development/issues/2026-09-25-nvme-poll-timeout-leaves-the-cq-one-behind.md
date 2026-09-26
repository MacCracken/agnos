# 2026-09-25 — NVMe: an I/O poll timeout leaves the completion queue one entry behind for the rest of the boot

**Status:** 🟡 **OPEN** — planned for **1.57.8**. Seen once during 1.57.7's S8 regression run; not caused by any
1.57.7 step (`nvme.cyr` is untouched by them).
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
