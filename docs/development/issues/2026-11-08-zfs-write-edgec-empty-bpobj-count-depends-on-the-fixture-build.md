# 2026-11-08 — the ZFS write smoke's `wr` / `wr@u0` lanes pin edgec's empty_bpobj count, which the fixture build decides

**Status:** 🟡 OPEN — slotted for **1.57.19** (operator, 2026-11-08: "Ship red, fix in 1.57.19").
*(Found by the 1.57.18 full sweep, row 8 — the ZFS write row red on both its parallel run and its serial retry, on these
two lanes alone.)*
**Checked against:** agnos **1.57.18** (merged tree, cyrius 6.7.18) on fixture `r8-83705beec7b1-c579a04a`, and (track T4,
2026-11-08) agnos **8927c965** (1.57.17) on `r8-36904f551255-c579a04a` (red) and `r8-9f0354ae0bb9-c579a04a` (green).
**Severity:** a gate defect, medium. No kernel behaviour is wrong as far as measured: on the red runs every other check of
both lanes passes, including the host's own recount of the written image (`zfs-uacct-check.py` h7: `deadlists: 27
deadlist(s), 51 entries recounted …, empty_bpobj refcount 29 == the entries naming it`). The defect is that one `--want`
pins a number the fixture build does not fix, so the row goes red (or green) at random across fixture rebuilds — the
1.57.16 `full`-lane class ([`archived/2026-11-04-zfs-write-full-lane-rename-depends-on-the-fixture-build.md`](archived/2026-11-04-zfs-write-full-lane-rename-depends-on-the-fixture-build.md)).

## What happens

`scripts/smoke/zfs-write-smoke.sh` (the `WRB` want list shared by `wr` and `wr@u0`) requires

    zfs-wtest: deadlist /agnoswr/edgec object N: 6 entries (3 naming empty_bpobj), dl_used …, prev snapshot unique …, dir SNAP …

and the 1.57.18 kernel prints, on both lanes,

    zfs-wtest: deadlist /agnoswr/edgec object 556: 6 entries (2 naming empty_bpobj), dl_used 188416, prev snapshot unique 94208, dir SNAP 94208

The entry COUNT (6) is fixed by the recipe; how many of the six still name the shared `empty_bpobj` after the op list is
not. The same lane already accepts `--mat '6|7'` for the same reason (the Σ of entries the op list materialises moved
with the build at 1.57.12); edgec's count was left a literal. On this run `mat` was 6 and edgec still read 2, so the two do
not move together — the empty count follows the fixture's PRE-op deadlist, not the op list.

## Why it varies

Fixture RECIPE 8 (`scripts/tool/zfs-fixture-guest.sh` `build_wr_edge`) writes in the clone after `@c1` (t.bin's upper half,
after.txt, a `touch` of e4.bin / c1.bin), which kills metadata born in whichever deadlist interval it happened to be born
in: object numbers come from per-CPU chunks, so which dnode blocks, accounting-ZAP blocks and meta-dnode indirects those
writes rewrite is the build's luck. The recipe's own note (design k.107, the 1.57.12 merge) records the first round of
this — "the op list's exact `mat` and edgec's empty_bpobj count followed the luck" — and the `touch` it added removed one
source of it, not all.

## The fix (1.57.19)

Make the line a function of the kernel and the image, not of the fixture build: hold every `zfs-wtest: deadlist …` line's
`E naming empty_bpobj` (and its entry count) to the host recount of the same written image — `zfs-uacct-check.py`'s
deadlist pass already walks every entry and the empty_bpobj refcount; have it print each head's `entries` / `naming
empty_bpobj` and the smoke compare them with the kernel's lines — and drop the literal (keep `6 entries`). Or remove the
luck in RECIPE 8 (rewrite every metadata path the clone's post-`@c1` writes can reach, as k.107 did for e4.bin / c1.bin),
measured on several builds. The first is the stronger oracle (the writer's self-report against an independent reader)
and survives the next recipe change.

## How to confirm the fix

`ZWS_LANES="wr wr@u0" sh scripts/smoke/zfs-write-smoke.sh` green, OpenZFS verify included, on `r8-83705beec7b1` (2) AND
`r8-9f0354ae0bb9` (3) via `ZFS_FIXTURE_DIR`, then the full ZFS write row once.
