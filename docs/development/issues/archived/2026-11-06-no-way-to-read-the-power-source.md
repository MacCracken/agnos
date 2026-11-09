# 2026-11-06 — ring 3 cannot tell mains from battery, so background work cannot pause on battery

**Status:** ✅ **RESOLVED in agnos 1.57.18** (operator ruling 2026-11-08: an ACPI namespace scan, no AML interpreter and no EC
driver this cut). **`power_source`#114** returns one word: `w & 0xFF` = 0 cannot say · 1 mains · 2 battery (reserved), reason
bits above it (ABI row 114, § 4.10). The boot-time scan of the DSDT and every SSDT answers **mains** when no battery
(`PNP0C0A` / `ACPI0002`) is declared or every declared battery's `_STA` is a constant absent, and **cannot say** for any
present battery — so QEMU and archaemenid answer mains, and a laptop answers cannot say until the AML `_PSR` / `_BST`
evaluator on the roadmap exists. No blocking, no lock, cheap for daimon's 10 s poll. Gate
`scripts/smoke/power-source-smoke.sh` (15 boots, 11 crafted SSDTs). daimon's agnos arm is filed
(`daimon/docs/development/issues/2026-11-08-agnos-power-source-arm-for-fx-power-find.md`).
*(Filed from daimon **2.5.4**, whose file index runs on the agnos target.)*
**Checked against:** agnos **107ad763** (1.57.17). `kernel/core/power.cyr` is shutdown and reset: the ACPI FADT and
`\_S5` decode, `power_reset`, `power_flush`, the quiesce paths. A search of `kernel/` for `_PSR`, `_BST`, `power_supply`
and `AC_ADAPTER` finds nothing, and the syscall list in `kernel/core/syscall.cyr:29` names no power query.
**Severity:** low for daimon, which runs regardless. It holds one line of crab's stated behaviour, on the primary target.

## What daimon needs

crab (the AGNOS file manager) asks that the disk index is built in the background and **pauses on battery**
(its canvas: *"Index · embedding new files 31% · local · pauses on battery"*). daimon 2.5.4 builds that index in
slices on its event loop, and pausing is not stepping. On Linux it reads `/sys/class/power_supply/*/status` every
10 s while a walk is running.

There is no peer on agnos, so `GET /v1/files/index` answers `"power":"unknown"` there, and a walk runs on battery.

## The ask

One read-only answer, in whatever shape suits the kernel: is this machine on mains, on battery, or can it not say?
A call that a poll can make every 10 s, that does not block, and that answers "cannot say" on hardware with no
battery or under QEMU, is all daimon would use. Charge level is not needed.

## What daimon does meanwhile

`"power":"unknown"`, stated in the answer, with the walk running: its `_fx_power_find` has no agnos arm. A walk is
bounded (3 ms a slice, then everything else runs), so the cost on battery is power, not responsiveness. daimon will add
the arm when a source exists; nothing else about the index changes.

## Related

- daimon `src/files.cyr` (`_fx_power_find`, `_fx_power_poll`), `docs/adr/010-file-index.md`.
- `daimon/docs/development/issues/archive/2026-09-23-crab-needs-a-file-index-tags-and-ranked-search.md`, item 1.
