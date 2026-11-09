# 2026-11-08 — readdir#81 and readdir_at#101 cut a name at 62 bytes and say nothing, so a row can name another file

**Status:** ✅ **RESOLVED in agnos 1.57.18** (2026-11-08, all three asks). **(1)** byte 63 of a `readdir`#81 / `readdir_at`#101
record is flags — bit 0 `RD_DIR`, **bit 1 `RD_CUT`**, set exactly when the name was longer than 62 bytes (clear on an exact-62
name), at all three writers through one `rd_rec_put`; the cut ends on a UTF-8 character boundary. **(2)** ABI § 4.2.1 writes
the record, the limit and "use `getdents`#29 for whole names" into the contract. **(3)** `lseek`#58 repositions an ext2 or ZFS
`AO_DIRECTORY` fd (SEEK_SET / SEEK_CUR, an opaque cookie that survives close and reopen), with a forged ext2 offset snapped to
the next record boundary, so a tree walk can resume `#29` with no fd held. Found and fixed with it: an aligned mid-record
#101 cursor lost 294 of 300 entries; ext2 #29 / #81 / #101 ran without `fs_lock`; a too-small getdents buffer answered 0
(end) instead of -1. Gate `scripts/smoke/fs-listing-smoke.sh`. crab's `== 1` readers and its tree walk are filed
(`crab/docs/development/issues/2026-11-08-agnos-readdir-cut-bit-and-directory-lseek.md`).
*(Filed from crab **0.11.3**. crab's 0.11.2 audit found it: `crab/docs/audit/2026-11-08-0.11.2-p-1.md`, H10.)*
**Checked against:** agnos **8927c965** (1.57.17), `kernel/core/ext2.cyr:2378` and `:2475`, `kernel/core/zfs.cyr:2001`.
**Severity:** high for a file manager. A file whose name is over 62 bytes cannot be reached through these calls, and when a sibling is named exactly its first 62 bytes, a delete aimed at the long name removes the sibling. It takes a rare pair of names, and what it costs is a file.

## What happens

`#81` and `#101` write fixed 64-byte records: the name, a NUL, and a type byte at 63. All three writers cap the name with `if (n > 62) { n = 62; }`: `ext2_readdir_sys`, `ext2_readdir_at_sys` and `zfs_readdir_at`. Nothing in the record or the return value says it happened, and ext2 allows 255 bytes (`ext2.cyr:3701`). The cut is by bytes, so it can also end inside a UTF-8 sequence.

Measured on 1.57.17 under QEMU, on ext2, with a ring-3 probe listing one directory:

| On disk | Contents | `#81` and `#101` list | Opening the name as listed |
|---|---|---|---|
| `a` x 70 | `LONG-70` | `a` x 62 | reads `SIBLING-62`, the wrong file |
| `a` x 62 | `SIBLING-62` | `a` x 62 | reads `SIBLING-62` |
| `b` x 62 + `-one` | `B-ONE` | `b` x 62 | -1 |
| `b` x 62 + `-two` | `B-TWO` | `b` x 62 | -1 |
| `short.txt` | `SHORT` | `short.txt` | reads `SHORT` |

`unlink#30` on the listed `a` x 62 returned 0 and removed `SIBLING-62`. The 70-byte file stayed, and its row now opens nothing.

In the same run `getdents#29` listed every name whole, at 70, 66 and 66 bytes, and each file opened with the right contents. The ZFS cap is read from the source, not run.

## Why it lands here

The kernel holds the whole name and writes a shorter one, so no caller can tell a cut name from a real one. Length is no clue, because a name of exactly 62 bytes is legal and lists the same way. Only the kernel can say which it was.

## The ask

1. **Mark a cut name in the record.** Set bit 1 of byte 63 when the name was longer than 62 bytes, at the three sites. The record stays 64 bytes, so no caller's buffer moves. ⚠ A caller testing byte 63 with `== 1` would read a cut directory as a file until it masks the bit. crab is the only caller of `#81` or `#101` found across the sibling repos (darshini and agnsh's `ls` use `#29`), and it would change with this.
2. **Write the limit into the ABI.** `agnos-userland-abi.md:497` says "64-byte records" and nothing about the cut. It is written down only in the comment above `zfs_readdir_at` and in an archived issue.

3. **Let `lseek#58` reposition a directory fd.** A caller that walks a tree in steps holds no fd between them, so it cannot resume `#29`: `lseek` refuses everything but `VFS_EXT2_FILE` and `VFS_ZFS_FILE` (`syscall.cyr:12680`), and one fd per level needs up to 127 of the 32. Both directory fds already keep their position in payload[0], `VFS_EXT2_DIR` a byte offset and `VFS_ZFS_DIR` a cursor, so accepting those two tags with `SEEK_SET` and `SEEK_CUR` is the whole change.

A caller that lists one directory can already use `#29`. If the better answer is to retire `#81` and `#101` in its favour, the third ask is what makes that possible for a tree walk.

## What crab does meanwhile

crab **0.11.4** lists its panes through `#29`, so a row holds its whole name and Delete removes the right file. Its tree walk still reads `#101`, because of the third ask, so a folder copy or delete stops at a name over 62 bytes.
