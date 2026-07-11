# ext2 reader: 64-bit i_size (large_file) for files > 2 GiB

**Filed:** 2026-07-10
**Component:** `kernel/core/ext2.cyr` (read path)
**Raised by:** the agnova sovereign ext2 *writer* (diskfmt `df_format_ext2` / `df_ext2_add_file`)

> **RESOLVED — already implemented (2026-07-10). Filed on a stale comment, not the code.**
> On re-derivation from the source, the kernel *already* does everything this issue asked for:
> `ext2_inode_filesize` returns `lo | (hi << 32)` (64-bit); the read path (`ext2_read_file`), stat,
> and symlink resolution all consume that; the block map already walks the triple-indirect tree;
> and LARGE_FILE (ro_compat `0x2`) is **not** in `ro_danger`, so a large_file fs mounts read+write.
> The "2 GiB cap" I quoted was a stale *comment* at `ext2.cyr:220` (since corrected) — the code never
> capped. No kernel change is needed. The only residual is agnova-side and theoretical: its writer
> stores 32-bit `i_size_lo` only, so a file in (4 GiB, 4.29 GiB] (its double-indirect ceiling) would
> truncate its size and it doesn't set LARGE_FILE. No base-system file approaches that, so it is not
> worth a change now; if ever needed, it is an agnova writer completeness item, not a kernel fix.

## Summary

The kernel's ext2 reader caps a file's `i_size` at 2 GiB — `ext2_inode_size_lo` reads only
`i_size_lo` (@ inode offset 4) and the code comments the cap explicitly:

```
kernel/core/ext2.cyr:220:  # For Phase 1 we cap at 2 GB regardless (i_size_hi == 0 always on small test images).
```

The block-mapping path already reaches ~4 TB (triple-indirect), so the limit is the **size
field**, not the block map. To read a file larger than 2 GiB the reader must:

1. Combine `i_size_lo` (@4) with `i_size_high` (@ 0x6C, aka `i_dir_acl` for regular files) into a
   64-bit size.
2. Accept the `large_file` RO_COMPAT feature (0x2) in the superblock feature check (safe — it is a
   read-only-compatible feature; unknown RO_COMPAT features are safe to mount read-only anyway).

## Why it matters (agnova side)

agnova's ext2 writer supports **double-indirect** files up to ~4.29 GiB and is otherwise ready to
write **triple-indirect** files of any size. It deliberately does **not** enable `large_file` or
emit 64-bit sizes today, because the kernel would misread them. Double-indirect (≤ 2 GiB in
practice) covers every base-system file — no rootfs file approaches 2 GiB — so this is not
blocking any current workload. It becomes relevant only when a single installed file exceeds
2 GiB (e.g. a large model weight or container image staged into the root).

## Fix sketch

- Read path: `ext2_inode_size(inode) = i_size_lo | (i_size_high << 32)` when `large_file` is set.
- Superblock: tolerate `RO_COMPAT & large_file`.
- Then agnova can enable `large_file` + write `i_size_high` + the triple-indirect tree (the
  writer's streaming builder already generalizes to a third level).

Until then: agnova caps files at the double-indirect maximum and refuses larger ones cleanly.
