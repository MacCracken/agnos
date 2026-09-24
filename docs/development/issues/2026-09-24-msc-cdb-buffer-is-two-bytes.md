# 2026-09-24 — USB mass storage: every SCSI command builds its 16-byte CDB in a 2-byte stack buffer

**Status:** 🟡 **OPEN** — an arising repair for 1.57.x (roadmap § 1.57.x, last row). Filed rather than
fixed in 1.57.6 because it was found during that release's review of an unrelated subsystem (spawn), after
the release's USB surface was already gated, and the fix wants its own step with the MSC smoke; 1.57.6 does
not touch `usb/msc.cyr`.
**Filed by:** agnos, from the 1.57.6 spawn fix pass (the same trap it fixed in `pfds[2]`).
**Checked against:** agnos **1.57.6**, `kernel/arch/x86_64/usb/msc.cyr`, read in the working tree. **By
inspection only**: no run has shown a failure, and `msc-short-smoke` (sweep row) passes.
**Severity:** a ring-0 stack-frame overrun on every USB-storage SCSI command. Its observable effect depends
on what the compiler places above the buffer in each frame, which has not been measured.

## What the code does

A function-local `var x[N]` in cyrius is **N bytes** (module scope is N u64 — the trap this tree records in
`state.md` as its highest-yield one, and which the 1.57.6 spawn fix pass re-verified when it resized three
`pfds[2]` pipe buffers to `[16]`). Seven functions in `usb/msc.cyr` declare `var cdb_buf[2];` and then
write 16 bytes into it:

| line (1.57.6) | function | write |
|---|---|---|
| 1117 | `msc_test_unit_ready` | zero loop `while (k < 16) store8(cdb_p + k, 0)` (the declaration's comment says "16 bytes") |
| 1196 | `msc_inquiry` | the same zero loop, then bytes 0, 3, 4 |
| 1261 | `msc_read_capacity` | the same zero loop, then byte 0 |
| 1328 | `msc_request_sense` | the same zero loop (comment "16 bytes"), then bytes 0, 4 |
| 1468 | `msc_read_lba` | `msc_build_rw10_cdb` — zeroes 16, writes bytes 0, 2–5, 7, 8 |
| 1509 | `msc_write_lba` | `msc_build_rw10_cdb` |
| 1567 | `msc_blk_flush` | the zero loop, then byte 0 (its comment: "cdb_buf[2] matches msc_read_lba's proven 10-byte-CDB allocation") |

So each call writes 14 bytes past the 2-byte slot. `scripts/check/check-array-sizing.sh` does not see it:
the offsets are loop variables or a callee's.

## The fix

`var cdb_buf[16];` at all seven sites (a CBW's CDB field is 16 bytes, and `msc_scsi_exec` copies from
`cdb_p`), and correct the two "16 bytes" comments and the `msc_blk_flush` comment that call the 2-byte
allocation proven. Worth deciding in the same step whether `check-array-sizing.sh` can learn the
`while (k < N) store8(p + k, …)` shape.

## Gate

`msc-short-smoke.sh` (the tree's only usb-storage coverage: enumeration on QEMU's xHCI, then a READ(10)
A/B) reaches the enumeration commands and READ(10); WRITE(10) and SYNCHRONIZE CACHE ride the
`MSC_RW_DEMO` / flush paths. Its passing today says the overrun lands somewhere harmless in those frames
under this compiler, not that it is absent. A discriminating test would read the frame layout from the
disassembly (or place a canary local beside the buffer) and show it clobbered before the fix and intact
after.
