# exFAT write smoke fails on host exfatprogs 1.3.2 (mkfs.exfat format drift)

**Status:** OPEN — filed 2026-05-31 during the agnos 1.40.9 exec-iron triage.
**Sequencing (user, 2026-05-31):** repair AFTER the 1.40.9 exec re-burn confirms
the current ring-3 fix. The planned FAT/exFAT Track-B iron burn follows the exec
burn; fold this mkfs-1.3.2 repair into that Track-B work, not before it. Do NOT
gate the exec re-burn on this.
**Severity:** medium (blocks `exfat-write-smoke.sh` + the `sweep.sh` exFAT row; does
NOT affect exec / ext2 / FAT32 / the iron exec re-burn).
**Not a regression of any kernel change** — reproduces on a clean baseline build
(verified by `git stash` + rebuild during the 1.40.9 work).

## Symptom

`scripts/exfat-write-smoke.sh` → **FAIL**, every row red, including tests that
predate any recent kernel work (1.34.4 rootext readback, 1.34.5 non-ASCII
create/find) through the 1.39.x shell verbs and 1.40.1 vfs_read_file. Final line:
`FAIL: fsck clean but no file counted (set not recognized)`.

The "every row including months-old ones" pattern + "fsck clean but set not
recognized" points at the **image the smoke creates**, not the AGNOS exFAT
backend logic: the volume mkfs builds is no longer recognized/mounted by AGNOS,
so no write test can run.

## Host environment

- `mkfs.exfat` = **exfatprogs 1.3.2** (`/usr/bin/mkfs.exfat`).
- Same class of host-default drift as the jbd2 CSUM_V3 surprise (host e2fsprogs
  1.47.4 enabling `metadata_csum` by default broke the 1.38.x write-side smoke
  premise). A newer `mkfs.exfat` likely changed a default — candidate suspects:
  boot-region / VBR checksum layout, default cluster (allocation-unit) size,
  upcase-table or allocation-bitmap placement, or a FAT/bitmap offset the AGNOS
  exfat mount/probe path hard-assumes.

## Repro

```sh
cd ~/Repos/agnos && sh scripts/exfat-write-smoke.sh   # FAIL on any current build
```

## Next steps (when picked up)

1. Capture the smoke's `mkfs.exfat` invocation + dump the produced volume
   (`hexdump` the VBR + the boot-checksum sector + the first FAT/bitmap) and
   diff against a known-good pre-1.3.2 image if one survives in git/CI history.
2. Re-derive the exFAT VBR / boot-checksum / cluster-heap-offset fields from the
   Microsoft exFAT spec (per `feedback_redesign_dont_reinvent` — triangulate,
   don't single-source) and find where the AGNOS `exfat` mount/probe diverges
   from what 1.3.2 now emits.
3. Decide: teach the backend the new default, OR pin the smoke's `mkfs.exfat`
   flags to the format AGNOS expects (mirrors the jbd2 `--csum-v3` smoke-image
   fix that stopped the gap hiding in QEMU).

## Cross-refs

- agnos CHANGELOG `[1.40.9]` (filed alongside the exec-iron triage).
- Parallel precedent: the jbd2 CSUM_V3 host-default drift (CHANGELOG `[1.38.10]`,
  `ext4-jbd2-prior-art.md` §8).
