# 2026-11-06 — readlink#70 refuses a buffer shorter than the target, so a long link reads as no link

**Status:** 🔴 OPEN.
*(Filed from thoth **0.55.1**, whose hostile pass on AGNOS found it.)*
**Checked against:** agnos **107ad763** (1.57.17), `kernel/core/ext2.cyr:3596`, and cyrius **6.7.18**, `lib/fs.cyr`.
**Severity:** high for anything that asks whether a path is a link, which is every consumer of the stdlib's `is_symlink`.

## What happens

`ext2_readlink` answers `-1` when the target is longer than the caller's buffer (`if (tlen > cap) { return 0 - 1; }`). Linux truncates and returns the bytes it copied. The stdlib's `is_symlink` was written to that: it asks with an 8-byte buffer and only tests for success. So on agnos **a symlink whose target is longer than 8 bytes reads as not a link.**

Measured on 1.57.17: with `link-dir -> /etc`, thoth's jail refused it. With `link-out -> /etc/secret.txt`, `is_symlink` answered 0, the jail passed it, and the model read the file. `search` read through it as well.

## Why it lands here

Every check built on `is_symlink` is affected, in every consumer, and fixing the kernel fixes all of them at once. Nothing needs the refusal: a caller that wants the whole target compares the return with its buffer, as on Linux.

## The ask

`readlink#70` copies at most `cap` bytes and returns how many it copied, on ext2 and on ZFS (`zfs_readlink_ref`). The 1.56.51 bound on a fast symlink (60 bytes, from the format and not the caller) stays as it is. The kernel's own callers pass buffers as long as the longest target they accept and are unchanged.

## What thoth does meanwhile

Since 0.55.1 it asks `lstat#102` instead (`fs_is_link`, `src/util.cyr`), which has no buffer to outgrow. If the fix lands, cyrius's `is_symlink` is right again with no change there.
