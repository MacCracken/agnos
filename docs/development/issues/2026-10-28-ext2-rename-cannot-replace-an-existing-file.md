# 2026-10-28 — ext2 `rename#31` cannot replace an existing file, so ring 3 has no atomic way to rewrite one

**Status:** 🟡 OPEN — the kernel already names the gap ("rename-replace is a follow-on bite",
`kernel/core/ext2.cyr:3058-3061`); this file records the consumer it blocks.
*(Filed from hapi **1.1.1**: its 2026-10-28 P(-1) audit, finding F-059, running hapi's agnos build on agnos 1.57.14
booted in QEMU.)*
**Checked against:** agnos **839e8d54** (1.57.14) — `ext2_rename` refuses when `ext2_dir_lookup(dst_parent,
dst_name)` finds the destination; flock#59 at `kernel/core/syscall.cyr:12376` accepts only a `VFS_EXT2_FILE` fd.
**Severity:** feature gap, medium for the consumer. `hapi adopt` cannot succeed on agnos at all. It fails closed:
nothing is lost, and the file is put back where it was.

## What happens

The standard way to rewrite a file without a crash window is: write a staging file beside it, fsync it, and
`rename(2)` it over the original. POSIX makes that rename atomic, so after a crash a reader sees either the old
file or the new one, never a torn one. hapi's manifest writer does exactly this for every `hapi adopt` (and for
`rollback` of an adopt):

1. Lock the package directory, so two writers cannot interleave.
2. Write `hapi.cyml.<pid>.tmp` with `O_CREAT | O_EXCL`, then fsync it.
3. `rename(hapi.cyml.<pid>.tmp, hapi.cyml)`.

On agnos step 3 returns **-1** every time, because the destination exists — which, for a rewrite, it always does.
There is no other atomic primitive to fall back on:

- **Unlink, then rename.** A crash between the two leaves no file at all.
- **Rewrite in place.** A crash mid-write leaves a torn file.

hapi refuses rather than take either window, so on agnos the verb never succeeds.

Step 1 also fails on agnos, independently: hapi opens the directory `O_RDONLY` (no `AO_DIRECTORY` → -1), and
with `AO_DIRECTORY` the open succeeds but flock#59 refuses a directory fd (-1). hapi locks the directory, not the
manifest, on purpose. The manifest is replaced by the rename, so two writers that lock it by path can end up
holding locks on two different inodes. A lock *file* beside it would work, at the cost of an artifact in every
user's dotfiles repo. This half is hapi's to solve once rename can replace.

None of this shows under mirshi, which forwards rename#31 and flock#59 to Linux, where both succeed. That gap is
filed in mirshi's roadmap (*Open defects — kernel fidelity*, 2026-10-28).

## The fix (agnos's call)

`rename#31` on ext2 replacing an existing destination, with POSIX's guarantees:

- **Atomic with respect to a crash.** After recovery the destination names either the old inode or the new one.
  This is the property the staging pattern exists for, so a replace that unlinks and then links is no better
  than the two ring-3 fallbacks above.
- **Old inode freed only when nothing holds it.** An open fd on the old file keeps reading the old contents.
- **A directory over a non-empty directory still refused**, and a file over a directory refused, as POSIX does.

Optionally, flock#59 on a directory fd (`AO_DIRECTORY`). Linux allows it, and it is the cleanest lock for "one
writer per directory". This is not needed if hapi moves to a lock file.

## How to confirm the fix

hapi's suite already carries the case. `tests/agnos.tcyr`'s `manifest_write: append, remove, and a staging
leftover` group does an append and a remove — each one a rename over `hapi.cyml`. Built with `cyrius build --agnos
tests/agnos.tcyr` and run on the kernel, it should pass once rename can replace (with the lock moved off the
directory, or flock#59 taking a directory fd). Today it cannot: the audit's run of the same writer on 1.57.14
returned -1 from the lock and -3 (the rename) from the unlocked append.
