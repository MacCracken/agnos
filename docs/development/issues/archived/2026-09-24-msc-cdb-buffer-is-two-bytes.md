# 2026-09-24 — USB mass storage: every SCSI command builds its 16-byte CDB in a 2-byte stack buffer

**Status:** ✅ **RESOLVED 1.57.7 (2026-09-25)** — step MSC: all seven SCSI builders in `usb/msc.cyr` use `var cdb_buf[16]`; `check-array-sizing.sh` rewritten so it sees loop, alias and callee writes into a function-local array. Gates: `scripts/smoke/msc-cdb-smoke.sh` (sweep row; RED `msc-cdb: FAIL sites=7 clobbered=7` on the `[2]` code, GREEN 26/0 on `[16]`, `-smp 1` and `-smp 4`) and `check.sh`'s array-sizing gate (RED on the unfixed tree with exactly the 7 sites, GREEN after). Built, gated, NOT burned. See § Resolution.
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

## Resolution (1.57.7, 2026-09-25)

**What shipped:** `var cdb_buf[16]` at TUR, INQUIRY, READ CAPACITY, REQUEST SENSE, READ(10), WRITE(10) and
SYNCHRONIZE CACHE, with the banner and comment corrections. The production image kept its size (2,431,480 B at the
time; 13 bytes differ, all inside the seven functions). An `MSC_CDB_CANARY` build plants a canary above each
buffer; the smoke reads it back after every command and checks its placement (gap 8..24 at run time, plus a static
source check). `check-array-sizing.sh` strips comments and strings, walks braces, applies rules 1/1′/2/2′/3/4/4b
and carries a 23-case control corpus with exact extents; `check.sh` prints its log on failure. `msc-short-smoke`
runs through `qemu-dwell` and asserts positively; both smokes seed a pattern at LBA 0 (a zero stick made the old
assertion vacuous).

**What the change broke — checked before archiving:** nothing observed (check 35/35, test 4/4, ktest 107/3, agnsh
`-smp 1`/`-smp 4`, aarch64 lists identical). Residuals, documented in the gate and the instrument banner, not
defects: rule 4 is silent on 20 callee extents whose writes follow a parameter-steered guard; one local inserted
above a `[16]` buffer at a site whose canary sits 8 mod 16 is byte-identical to alignment filler at run time (only
the static check sees it). Noted, not filed: `msc_read_lba` trusts the xHCI-reported count, not
`dCSWDataResidue` (a deliberate 1.56.52 choice), reachable only with a malformed CDB.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/MSC-report.json`, `MSC-fix-report.json`.
