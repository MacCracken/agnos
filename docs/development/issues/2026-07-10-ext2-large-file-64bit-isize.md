# ext2 reader: 64-bit i_size (large_file) for files > 2 GiB

**Filed:** 2026-07-10
**Component:** `kernel/core/ext2.cyr` (read path)
**Raised by:** the agnova sovereign ext2 *writer* (diskfmt `df_format_ext2` / `df_ext2_add_file`)

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
