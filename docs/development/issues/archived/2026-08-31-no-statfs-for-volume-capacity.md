# There is no `statfs`, so no ring-3 program can report a filesystem's size or free space

**Status:** ✅ **SHIPPED 1.56.56 as `statfs`#103, mutation-gated. Archived 2026-08-31.**
`sys_statfs(path, pathlen, buf) -> 0 / -1`, filling the 32-byte §4.7 record — `f_bsize` @0,
`f_blocks` @8, `f_bfree` @16, `f_bavail` @24, all u64 LE. Path-based and mount-routed, matching
`stat`#33. ⭐ **The free count is LIVE**, read from the resident superblock the allocator maintains —
not a mount-time snapshot, which is what a capacity bar actually needs.
**Measured on the gate`s own image** (67 MiB, `mkfs.ext2 -b 4096 -m 0`): `bsize=4096 blocks=17152
free=16042 avail=16042`, and free drops to `16041` after a 23-byte write. `avail == free` because the
image reserves nothing; `blocks` matches 67 MiB / 4096 exactly.
⛔ **Two mutations, each caught by its own named arm**: reporting total as free →
`f_bfree did not drop after a write`; removing the path lookup →
`answered for a NONEXISTENT path`. That second arm is the one that matters — an implementation
ignoring its path argument would answer the root volume and pass every check about the numbers.
⚠ **ext2-only**, and it says so rather than guessing: a non-ext2 mount returns -1, the same posture
`stat`#33 shipped with. FAT/exFAT can answer this (total/free clusters x sectors-per-cluster) but that
is a second backend and a second set of controls — filed as a follow-on rather than half-built.
⚠ **The record size is frozen ABI**: 3-arg with no length parameter, so a wider record needs a new
number. Four fields is what was asked for. ⚠ **The cyrius `sys_statfs`#103 peer is owed and FILED** — cyrius `issues/2026-09-01-agnos-sys-statfs-103-peer.md` (2026-09-01), the third of three in the ABI gap alongside `#96 fork` and `#102 lstat`.

**Original status:** 🟡 OPEN — a missing syscall, not a defect in an existing one.
**Placement:** a new number beside `stat`#33 / `lstat`#102, and a matching cyrius wrapper in
`lib/syscalls_x86_64_agnos.cyr` (same kernel-mints-it / cyrius-owns-the-peer split as
`sys_lstat`#102).
**Filed:** 2026-08-31, by **crab**.
**Affects:** every agnos release.
**Severity:** **Medium as a capability gap.** Nothing is broken; a whole class of ordinary desktop UI
simply cannot be written.

## The consumer

crab's M6 sidebar is drawn in its design canvas with a **VOLUMES** section: each mount with a
capacity bar. dhancha has shipped everything needed to *draw* it — `LIST` for the rows, `PROGRESS`
(0.9.22) for the bars, `DH_FLAG_INERT` (0.9.23) for the section headers. What crab cannot do is
**fill it in**: there is no way to ask how large a filesystem is, how much is free, or what is
mounted.

Checked 2026-08-31 across the whole stack:

```
$ grep -oE 'fn sys_[a-z_]*statfs[a-z_]*|fn sys_statvfs' cyrius lib/syscalls_*.cyr   ->  no hits
$ grep -inE 'statfs|statvfs' agnos/docs/development/agnos-userland-abi.md            ->  no rows
```

…and the two related numbers that *do* exist are stubs, per the ABI table itself:

| # | name | status |
|---|---|---|
| 11 | `mount` | 🔧 **stub (no-op)** |
| 24 | `umount` | 🔧 **stub → 0** |

So a program cannot enumerate mounts either. ⚠ `open`(7) has been **mount-routed** since 1.41.3 via
`vfs_resolve_mount`, so the kernel plainly knows what is mounted and where — the information exists
and is simply not askable.

## The ask

```
sys_statfs(path, pathlen, buf) -> 0 / -1
```

Filling a small fixed record. The four fields that carry a capacity bar are the whole ask:

| field | meaning |
|---|---|
| `f_bsize` | block size |
| `f_blocks` | total blocks |
| `f_bfree` | free blocks |
| `f_bavail` | blocks available to an unprivileged caller |

⚠ **A `path`-based call rather than an fd-based one** matches how crab already asks about the
filesystem (`stat`#33 takes a path), and avoids needing an open descriptor just to read a number.
⚠ A mount enumeration would serve the same UI better still, but it is a larger ask; capacity for a
path crab already has is the small version, and it is enough to draw the section.

## Why this and not a workaround

There is none. Size and free space are not derivable from anything ring 3 can reach: `stat` reports a
file, not the filesystem under it, and walking a tree to sum sizes answers a different question
(what is used *here*) at a cost proportional to the disk.

## Until then

crab is **not building a half-populated sidebar.** Its canvas draws four sections and only PLACES is
reachable today — VOLUMES needs this syscall, SMART FOLDERS and TAGS need `daimon` — and a panel with
one working section and three empty headers is the painted-but-inert failure this stack's own docs
keep naming. The roadmap's gate for that row has been re-aimed from *"dhancha TREE widget"* (which
was false — the widgets all exist) to the data, which is where it actually is.
