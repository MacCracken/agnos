# 2026-11-04 — the ZFS write smoke's `full` / `full@pre` lanes pass or fail with the fixture build, not with the kernel

**Status:** ✅ RESOLVED in **1.57.17** (track T5, merged at 1.57.17) — design
`docs/development/proposals/2026-10-09-zfs-write.md` **k.137**. The issue's direction (a), built with (b)'s wait: after
B5's fill and its refused 128 KiB write the op list GIVES BACK two records (`fill-5.bin` truncated by 262,144 B — a
free, netfree, so it commits at the slop), then the unlink and the rmdir, whose publish releases the give-back's frees
(k.125), then the rename. The rename's room is the fill's leftover + two records ± three txgs' metadata deltas, against
its 4,096 B charge, on any build; without the release it would not fit on any build, so the lane still proves the
release. The writer prints its own room before the give-back and before the rename (`core/zfs_write.cyr`
`zfs_wt_room`: `zfs-wtest: room after txg T: R B (room X - allocated Y, deferred Z)`), and the smoke's new `--fit`
(`scripts/smoke/lib/zfs-room-check.py --fit`) holds FIT / RELEASE / WRITER to the space record replayed from the
image. `full@pre` re-derived the same way (it gained the namespace `--want`s it never had). Proven
(`ZWS_LANES="full full@pre"`, both lanes green with OpenZFS verify 37/37 each, on THREE builds): the cached
`r8-3daae94469aa` (fill leftover −24,576 B → the rename admitted with 253,952 B; without the release −294,912), a rebuild
with another payload hash into a scratch `ZFS_FIXTURE_DIR` (`r8-ba5c6ddb797f`, cyrius 6.7.9's payload, `alloc zdb`
56,672,256 B: +69,632 → 335,872 B) and a second build of the current key there (56,647,680 B: +118,784 → 360,448 B).
The unchanged 1.57.16 list is RED on the first (`rename … FAIL no space: the pool is at its slop`) and GREEN on the
second — one kernel, two verdicts, which the new lane does not have. ⚠ "The CONTENT is the same in every build" below
holds for the fill's total only: the fill files' sizes move with `available` (three `full.manifest` variants over nine
builds). `logs` and the other lanes checked: no fixture-margin dependence (k.137 (e)).
*(Found by the 1.57.16 full sweep, row 8; the cause measured the same day; fixed 2026-11-04.)*
**Was:** 🟡 OPEN — slotted for **1.57.17** (operator, 2026-11-04: "record, fix next cut").
**Checked against:** agnos **e3cf52d2** (1.57.16, cyrius 6.7.18) and the 1.57.14 tree (cyrius 6.6.20) — the same red on
both, on the same fixture.
**Severity:** a gate defect, medium. No kernel behaviour is wrong as far as measured: the writer refuses a rename at
the slop, which is OpenZFS's rule for a non-netfree op. The defect is that the lane's expectation depends on a margin
that the fixture build does not fix, so the sweep's ZFS write row goes red (or green) at random across fixture
rebuilds.

## What happens

The `full` lane (pool `agnosfull`, fixture recipe 8) fills the pool to its slop (B5's fill: write blocks until one is
refused), then runs the op list `zfs_write.cyr` gives that pool (`zfs_wt_u`, ~`:11480`): `unlink /agnosfull/b6/a.txt`
and `rmdir /agnosfull/b6e` (netfree: they commit at the slop), then `rename /agnosfull/dir/s1.txt
/agnosfull/b6/s1.txt`, which the lane expects to SUCCEED — the code's own note: "(B11, k.64 / k.125) at the slop after
the fill: the frees of two txgs back are released at every commit, so the rename's one microzap growth fits".

On the fixture the 1.57.16 sweep built (`~/.cache/agnos/zfs-fixtures/r8-3daae94469aa-c579a04a`), the fill ends
**−24,576 B** past the margin (the lane's `room:` line: "then -24576 B left (< the refused block's 131072 B)"), the
unlink's and rmdir's frees (txgs 253 / 254) are not yet released when the rename (txg 255) asks for room, and the
rename is refused: `zfs-wtest: rename FAIL no space: the pool is at its slop`. `full@pre` fails the same way. The other
19 of 21 lanes pass.

## Why it varies

- The fixture is rebuilt whenever its cache key changes. The key hashes the payload — `tests/zfs`'s `zfsx`, rebuilt
  by cyrius on every run — so any compiler change that moves a byte of `zfsx` rebuilds every pool: 173,112 B at cyrius
  6.6.20, 173,128 B at 6.7.9, 173,272 B at 6.7.18.
- `agnosfull`'s CONTENT is the same in every build (`full.manifest` sha `9e2d98115bda…` in r7 and r8), but OpenZFS's
  metadata allocation is not: `full.acct`'s `alloc zdb` reads 56,647,680 / 56,659,968 / 56,635,392 / 56,635,392 B
  across the four cached builds (a 24 KB spread), and the room left after the fill moves with it.
- **Measured:** the 1.57.14 kernel (cyrius 6.6.20, the build whose sweep passed this row 21/21) fails the `full` lane
  identically on the r8-3daae fixture (`ZWS_LANES=full`, its banner `AGNOS kernel v1.57.14`). The toolchain is not the
  cause.

## The fix (1.57.17)

Make the lane's outcome a function of the kernel, not of the fixture build. Either:

- **the fill leaves a FIXED margin** — fill to "one block refused", then free or write back to a margin the rename's
  growth provably needs (computed from the plan, not assumed); or
- **the rename runs after the deferred frees are released** (two more commits after the unlink / rmdir), which is
  what the k.64 / k.125 note relies on — and keep a refused-at-the-slop rename as its own named case.

Then re-derive `full@pre` the same way, and prove both against at least two fixture builds whose `alloc zdb` differ
(the cached r7 sets have three).

## How to confirm the fix

`ZWS_LANES="full full@pre" sh scripts/smoke/zfs-write-smoke.sh` green on the current fixture AND on one rebuilt with a
different payload hash (`ZFS_FIXTURE_DIR=<scratch>`), then the full ZFS write row once.
