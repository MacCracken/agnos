# AHCI command recovery: a timed-out command ends only when the engine is proven stopped (1.57.9)

`kernel/core/ahci.cyr` issues every command through slot 0 of the port's command list. The three issue paths
(`ahci_issue_rw_inner`, `ahci_issue_nodata_inner`, `ahci_identify_device_inner`) share slot 0's header, the per-port
command table (CT) and its PRDT. The PRDT's DBA is the **caller's** buffer: ext2 pages, the `blk_*` scratch, the
IDENTIFY page. There is no bounce page. All of this runs under the whole-HBA `ahci_lock`, a preempt-disabled spinlock.
The HBA is polled and PxIE is never written. Three invariants keep a slow or failing SATA device from corrupting
memory. Each one comes from a measured failure (issue `2026-09-25-ahci-timeout-abandons-an-in-flight-command`).

## 1. An issue path never returns while the HBA still owns its command

Until 1.57.9 the poll was an iteration count (1M MMIO spins, 30M for FLUSH). When the count ran out, or when
`PxTFD.ERR` was set, the path returned 0 with `PxCMD.ST=1` and `PxCI` bit 0 still set. The device could then DMA into a
buffer the caller had already reused, and the next command rewrote slot 0 and the CT under a command still in flight.
`AHCI_SELFTEST` `reuse` measured this under QEMU: `bad=512`, meaning every word of the caller's stamp was overwritten
by the late read.

Now the budget is wall time on `klog_uptime_us()`: 5 s per R/W and IDENTIFY, 30 s per FLUSH. While the TSC is not yet
calibrated, the backstop is `budget*64` spins, the same as `nvme_io_poll_n`. On a timeout or an error,
`ahci_run_slot0` calls `ahci_port_recover` **before it returns**. That function implements AHCI 1.3.1 §6.2.2.1:

1. `ST=0` and wait for `CR=0`, within 500 ms (§10.1.2). Per §3.3.14 the HBA clears `PxCI`, and once `CR=0` its
   command-list DMA engine is idle.
2. Clear `PxSERR` and `PxIS`. This happens after the stop because a late D2H FIS may still arrive (§10.4.1).
3. If `BSY` or `DRQ` is still set, send a COMRESET (§10.4.2).
4. Restart: FRE, then `ST=1`, then wait for `CR=1`.

The order follows Linux's EH: freeze, reset, then finish the command. FreeBSD finishes the command and then resets,
which is safe there only because the CCB goes back later. In agnos the return value itself hands the buffer back, so
the reset has to come first.

The ST=0 is what carries the fix. Mutation M2 kept the budget and the recovery call but skipped the stop, and `reuse`
went RED again with `bad=512`. QEMU 11.1.1 honours the spec here: an ST 1→0 write settles the in-flight DMA before
`CR` reads 0.

## 2. PxIS, not PxTFD.ERR, is the error signal

`PxTFD` is a copy of the **last** D2H FIS. After a failed command its `ERR` bit stays set until the device sends
another FIS. The old poll checked `PxTFD.ERR` while `PxCI` was still set, so it failed the *next* command
immediately, while that command was still running, and then abandoned it. `ahci_poll_slot0` reads `PxCI` and then
tests `PxIS` for `TFES|HBFS|HBDS|IFS`. `PxIS` is cleared before every issue, so it only ever describes the current
command. `AHCI_SELFTEST` `tfes` goes RED with the old `PxTFD.ERR` check (M3). It also goes RED without the recovery
(M1), because a halted engine leaves the port not idle.

## 3. An engine that will not stop takes the ports offline

If `CR` does not clear, recovery escalates in steps, least intrusive first (§10.4). It sends a COMRESET and stops the
engine again. If `CR` still does not clear, it sets `GHC.HR` (`ahci_hba_reset_quiet`), which resets every port, so
every port is marked `ahci_port_dead`. A port is also marked dead if the link does not return after a COMRESET or the
engine will not restart. `ahci_port_ready` runs at the top of all three issue paths and checks the flag first, so a
dead port never touches slot 0, the CT or a buffer again. Later AHCI I/O fails fast with -1.

This flag is the only "late" record. NVMe cannot cancel one command from the host, so 1.57.8 records a timed-out
command as late and reaps it later (`nvme-io-completion.md`). AHCI can cancel one, and it does so synchronously.

⚠ Residual: if `GHC.HR` itself never clears, the HBA's DMA is not proven stopped. The event is printed as
`hba-reset-stuck (DMA not proven stopped)` and the ports stay offline. Nothing further contains it. NVMe carries the
same residual when `nvme_disable` times out.

## Printing

Recovery runs under `ahci_lock`, so it never calls kprint. Events are collected in `ahci_note`. The lock wrappers
(`ahci_issue_rw_n`, `ahci_issue_nodata`, `ahci_identify_device`) copy the notes into `ahci_last_note` and print them
after unlock, for example `ahci: port 0 timeout - recovered` or
`ahci: port 0 timeout comreset hba-reset - port offline`. The word `recovered` is printed only when
`ahci_port_recover` actually brought the port back.

## Gate

`AHCI_SELFTEST` → `scripts/smoke/ahci-late-smoke.sh` (see the build.md row). The SATA disk is throttled to 100 IOPS,
and the selftest fills QEMU's throttle bucket before each injection. That keeps the timed-out read running roughly
10 ms past the return. Without the throttle, QEMU can finish the read before the caller stamps the buffer, and the
test could not tell the fix from the abandon (the lesson from 1.57.8's nvme-late smoke).

## NVMe admin (same cut)

`nvme_admin_poll` now uses `nvme_io_poll_n`'s approach: a wall-time budget of 5 s checked before the CQ, consume by
CID, and discard strays. A timeout disables the controller (`nvme_disable`, `nvme_admin_ready=0`, `nvme_io_ready=0`),
which matches Linux's rule that any admin timeout resets the controller. Gate: the `nvmest: admin` arm of
`NVME_SELFTEST`.
