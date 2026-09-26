# 2026-09-25 — AHCI: a command that times out is abandoned while the device may still DMA into the caller's buffer

**Status:** 🟡 **OPEN**, unslotted. This is the late-completion class that 1.57.8 fixed for NVMe
(`nvme_io_poll_n`/`nvme_io_settle`) and virtio-blk (`vblk_wait`/`vblk_settle`), in the two places it was not
applied: AHCI, and NVMe's admin poll.
**Filed by:** agnos, from the 1.57.8 DMA1 end review and the NVME step report (`open_problems[1]`).
**Checked against:** agnos **1.57.8**, `kernel/core/ahci.cyr` `ahci_issue_rw_inner` (~:1024, the
`AHCI_TIMEOUT_SPINS` loop and the "stuck" return ~:1084-1097), and `kernel/core/nvme.cyr` `nvme_admin_poll`
(~:511).
**Severity:** possible memory corruption after one slow command. No AHCI timeout has been observed. The NVMe admin
path runs at init only.

## What happens

1. **AHCI.** `ahci_issue_rw_inner` spins up to `AHCI_TIMEOUT_SPINS` (an iteration count, not wall time). On a stuck
   PxCI it returns 0 with the command still issued. The PRDT points at the CALLER's buffer (or the bounce page), and
   the next command reuses slot 0's header and CT. A late completion can then DMA into memory the caller has already
   reused, and the next command's completion is read against a slot the device has not finished with.
2. **NVMe admin.** `nvme_admin_poll` keeps the old iteration budget, and on a CID mismatch it still returns the
   stale entry's status. It runs only during init (IDENTIFY, create queues), where a failure leaves NVMe not ready.

## The fix

Use the NVMe/virtio-blk shape:
- a wall-time budget (`klog_uptime_us`; a spin backstop when the TSC reads 0);
- a timed-out slot recorded as late, and a settle before the slot, CT or bounce page is reused;
- if the command never completes, a port reset (PxCMD.ST = 0, wait for PxCMD.CR = 0), or the port taken offline;
- for `nvme_admin_poll`, the same CID consumption as `nvme_io_poll_n`.

## Gate

An `AHCI_SELFTEST`-style arm that forces a late completion (a zero budget on one command against a throttled QEMU
disk, as `nvme-late-smoke` does), then issues N reads of known LBAs and checks every byte. It must be RED on today's
code.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/DMA1-endreview.json` (verdict text), `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/NVME-report.json` (`open_problems`).
