# NVMe I/O completion — one outstanding command, consumed by its own CID (1.57.8)

`kernel/core/nvme.cyr` drives one polled I/O queue pair (qid 1, 64 entries, IEN=0) under the whole-controller
`nvme_lock`. Three invariants keep a slow device from corrupting I/O; the reason for each is a measured failure.

## 1. A timed-out command is LATE, not gone

`nvme_io_poll_n(cid, budget_us)` gives up after a wall-time budget (5 s per transfer, 30 s per FLUSH, on
`klog_uptime_us()` — see `kernel-clocks.md`) and records the CID in `nvme_io_late` / `nvme_io_late_cid`. The device
still owns that command: it may write its CQE and DMA into its buffer at any later time. Until 1.57.8 the poll gave
up after 10M iterations (tens of ms under KVM) and forgot the command; the next poll consumed its CQE, printed
`CID mismatch` and returned the stale status as its own, and the CQ stayed one entry behind for the rest of the
boot (1.57.7 S8: 1,704 mismatch lines, waitx 10 FAIL on a loaded host).

## 2. Every submit path settles first — so at most one command is ever outstanding

`nvme_io_settle()` polls FOR the late CID before anything else touches a DMA buffer: at the top of
`nvme_rw_internal` (before the PRP list is written), in `nvme_blk_flush`, and in the two write-bounce paths
(`nvme_blk_write`, `nvme_blk_write_sectors`) **before the copy into the scratch**, not merely before the submit —
a late READ into the scratch would otherwise land on top of the data being written (the NVME_SELFTEST `reuse`
arm is RED without it). The two caller-buffer paths (`nvme_read_sectors` / `nvme_write_sectors`, used by
`blk_*_sectors_direct` with ext2's own pages) settle before they return a failure, because returning hands the
caller's buffer back. With settle in front of every submit, a CQE is only ever the expected CID or a stray; a
stray is logged (`nvme: I/O stray CID N discarded`) and its status is never anyone's answer.

## 3. A completion that never comes turns the controller off

If settle's own budget expires, the only way to guarantee no further DMA into a buffer the kernel has handed back
is a controller reset: `nvme_disable()` (CC.EN=0, wait CSTS.RDY=0), `nvme_io_ready = 0`, and every later NVMe
I/O fails fast with -1. ⚠ Residual: if `nvme_disable` itself times out (RDY never clears) the device may still be
live; that prints `nvme: disable timeout` and is not otherwise contained.

Gate: `NVME_SELFTEST` → `scripts/smoke/nvme-late-smoke.sh` (build.md row).

## The admin queue has the same shape (1.57.9)

`nvme_admin_poll(cid)` (init only: IDENTIFY, CREATE IO CQ/SQ) now works like the I/O poll: a 5 s wall-time budget
checked before the CQ, every CQE consumed and matched by CID, and strays logged and discarded
(`nvme: admin stray CID N discarded`). Before 1.57.9 it returned the first CQE's status whatever its CID. A timeout
disables the controller, as Linux does for any admin timeout. Gate: `nvmest: admin`. The AHCI counterpart of this
document is `ahci-command-recovery.md`.

## virtio-blk has the same shape (1.57.8 DMA1)

`kernel/core/virtio_blk.cyr` keeps one request in flight on its single virtqueue, and until 1.57.8 both of its polls
(`vblk_do_request`, `vblk_do_flush`) gave up after 2,000,000 iterations (~20 ms under TCG) and forgot the request —
a FLUSH is a host fsync and outlived that on a loaded host (`dmash: virtio FAIL bad=16000`, 3 runs of 4 at -smp 1).
The late completion was then consumed by the next request's poll, which read the shared status byte before its
own transfer ran. Now `vblk_wait(budget_us)` polls on the same wall-time clock (5 s per transfer, 30 s per FLUSH),
marks a timeout `vblk_late`, and `vblk_settle()` reaps it at the top of both request paths and in `vblk_blk_write`
**before the copy into `vblk_dma_buf`**; a request that never completes resets the device (status 0) and takes
virtio-blk offline (`vblk: late request lost - device reset`). Gate: the `virtio` arm of `DMA_SHADOW_SELFTEST`
(docs/architecture/dma-cpu-pointers.md), whose FLUSH now passes at -smp 1 TCG.
