# ext2 rename-replace and in-core orphans (1.57.17)

Two invariants the ext2 driver keeps since 1.57.17, and what a change near them must not break. The code is
`kernel/core/ext2.cyr` (`ext2_rename_replace`, `ext2_dir_set_entry`, the in-core orphan block above `ext2_unlink`);
the proof is `scripts/smoke/ext2-rename-replace-smoke.sh` (crash cuts + ring 3) and `tests/rnrep/rnrep.cyr`.

## 1. `rename#31` over an existing name: one commit write, and an order around it

agnos ext2 has no journal on its write path (jbd2 is inert, `power.cyr`), and every metadata write completes before the
next step starts (prior-art `ext2-ext4-write-prior-art.md` § 3), so **the write order is the crash story**.

- **The commit is ONE block write**: the destination dirent rewritten in place to the new inode number and file type
  (`ext2_dir_set_entry`, Linux `ext2_set_link`). The inode field is 4 aligned bytes — no sector splits it.
- **A file** (`src` not a directory): src links +1 → ★ commit → src's old dirent removed → src links −1 → the victim
  loses a link. A file's count is never too LOW for the names that reference it (a later `unlink` of the stale name would
  free it under the live one), only one too high.
- **A directory** (over an empty directory only): src's old dirent removed **first** → ★ commit → its `..` → src_parent
  links −1 → the victim to 0 links. With two parent entries on disk, e2fsck pass 2 keeps the first it meets (block order)
  and CLEARS the other — so the dst-first order lets a repair delete the destination. Old-name-first leaves, at worst,
  the moved directory in `/lost+found` with its subtree, while the destination still names the old empty directory.
- **Every cut** leaves the destination naming the old inode or the new one, before and after `e2fsck -fy`.
  The smoke's 21 cut boots (`EXT2_RNCUT_SELFTEST=1`, `ext2_rncut` halts the box after cut K) measure exactly that.

⚠ Changing the order means re-running the cut part (`RNREP_PARTS=cuts`). Mutation M2 (directory commit first) is the
measured counter-example: `Entry 'v' in /cut/b is a link to directory /cut/a/s. Clear` — the destination missing.

## 2. A last link removed while an fd holds the inode: freed at the last close

POSIX keeps an open file's contents until its last close. `ext2_inode_last_link` writes such an inode with links 0 and
i_dtime 0 (Linux ext2's unlinked-but-open inode) and registers it in a 32-slot in-core table; `ext2_orphan_reap` frees
every registered inode that **no fd slot anywhere names** (`ext2_ino_held` scans the global table and every per-process
table for `VFS_EXT2_FILE` / `VFS_EXT2_DIR` payload[2] — vfs.cyr's `pipe_buf_referenced` rule, because agnos has no
open-file description and fd entries are COPIED by inherit / fork).

- **The reap runs** after `vfs_close_inner` clears an ext2 slot and after `proc_destroy_fd_table_held` frees a table. A
  path that clears an ext2 slot any other way (a #43 CLEANFD scrub, a redirect overwrite) does not leak: the orphan is
  freed at the next close or teardown anywhere. ⚠ A new holder of an inode number OUTSIDE fd slots (an in-kernel
  handle kept across syscalls) must be added to `ext2_ino_held`, or its inode can be freed under it.
- **Crash**: the table is in-core only (ext2 has no on-disk orphan list; ext3/4's `s_last_orphan` is not built). A
  crash with such a file open leaves an allocated links-0 inode — e2fsck frees it ("Deleted inode has zero dtime" +
  bitmap differences), fsck-repairable like every cut of this driver.
- **Limit**: a last-link removal (`unlink`#30, `rmdir`#10, the victim of `rename`#31) that would need a 33rd slot is
  refused (-1) BEFORE anything changes (`ext2_orphan_room`).
- Users: `ext2_unlink`, `ext2_rmdir`, `ext2_rename_replace`. Mutation M3 (free under the holder) makes the next create
  take the inode number and the old fd read its bytes.
