# 2026-09-02 — ring-3 cannot enumerate mounts, and the table already exists

**Status:** ✅ **RESOLVED — SHIPPED 1.56.59 as `mountlist`#104, boot-proven. Archived 2026-09-02.**
The ask was item 1 only ("Item 1 alone unblocks us completely"); items 2 (volume label) and 3 were
explicitly *not* requested and are not built. Nothing is carried.

**What shipped.** `mountlist(buf, max) -> count / -1`, arm at `kernel/core/syscall.cyr` (`num == 104`),
80-byte all-u64 records: `backend` @0 · `prefixlen` @8 · `prefix` @16 (64 B, **NUL-padded**). A new
number rather than a widening of `mount`#11, for the reason crab named and this tree has measured
twice (`#100`, `#101`): unused argument registers carry stale values, not zero.

**Boot-proven, not merely compiled.** `scripts/harness/mountlist-test.py` + `tests/mountlist/mlist.cyr`
— exit **95**. The oracle is the table's SHAPE, not `count > 0`: a stub returning one zeroed record
would pass a count check.

⚠ **WHAT THIS SHIPPED CHANGE BROKE, checked before archiving per the folder rule.**
1. `scripts/check/syscall-abi-check.sh` is now **RED**: `kernel 105 · abi-doc 105 · cyrius 104`. This is
   the documented, expected state for a newly minted number (`symlink`#63 and `readlink`#70 both
   shipped in it). The cyrius peer is filed at
   `cyrius/docs/development/issues/2026-09-02-agnos-syscall-104-mountlist-wrapper.md`. ⛔ Do not "fix"
   the gate by editing cyrius, and do not weaken the gate.
2. Nothing else. `check.sh` is otherwise 32/32, `test.sh` 4/4, and the boot smokes are unchanged.

⚠ **ONE ASSERTION IN THE NEW GATE CANNOT CURRENTLY FAIL, and it is labelled as such in-file.** The
NUL-padding check (exit 86) was mutation-tested by making the kernel copy all 64 bytes unconditionally
and the test still passed — `vfs_mnt_prefix` is zero-initialised and each slot is written once per
boot, so there is no stale tail to read yet. It is a regression guard for the day `mount`#11 stops
being a no-op, not a live oracle. Exit 89 (the `max` budget) is what bites, and is mutation-proven.

⛔ **A NOTE THE NEXT PERSON NEEDS: THE ARM TAKES NO LOCK, AND THAT IS ONLY SAFE TODAY.** `mount`#11 and
`umount`#24 are unconditional `return 0;`, so the table is written once by `vfs_mount_init` and is
immutable after. The day `mount` becomes real, this arm needs `fs_spin_lock` or it hands ring 3 a torn
prefix. The note is carried in the arm itself; do not delete it when implementing mount.

⭐ **AND THE PART WORTH KEEPING: TWO CONSUMERS DISAGREED AND THE SECOND ONE WAS RIGHT.** chakshu's
telemetry filing the same day listed mount enumeration as its §6 and said **"do not prioritise this"**,
on the grounds that a monitor can `statfs` the three known prefixes. crab's filing is what overturned
that, with a case chakshu did not have: **aliasing**. `vfs_mount_init` (`core/vfs.cyr:396`) gives an
ext2-less boot the same backend under BOTH `/` and its `/mnt/…` prefix — "harmless redundant aliases"
to routing, one volume listed twice to a sidebar, and a probe cannot tell. Enumeration can, because the
backend id travels with the prefix. ⇒ A "do not prioritise" from one consumer is not a verdict on the
capability; it is one consumer's use case.

---

**Filed by:** crab (the AGNOS file manager), during the M6 cut that put a PLACES
sidebar on screen for the first time.
**Checked against:** agnos **1.56.59** (in-development; `VERSION` is uncommitted at time of
writing, `HEAD` is 1.56.58). `kernel/core/syscall.cyr` `fn ksyscall` at :8300 and
`kernel/core/vfs.cyr`. Read, not inferred; every line number below was opened.
⚠ **The line numbers cited here are stable across both**: we re-checked each against
`HEAD` as well as the working tree, and the in-flight edits in `syscall.cyr` all sit
below :9343 — clear of everything we cite. Where a citation would have been unstable we
name the symbol instead of the line.
**Consumer:** `crab` — the sidebar ships today with PLACES; VOLUMES is the section
that cannot be built.

> **This is an ask to EXPOSE something you already have, not to build one.** The
> kernel keeps a `{prefix → backend}` mount table and fills it on every boot. Ring 3
> has no way to read it. That is the whole gap, and the smallest fix is a getter.
>
> ⚠ **We nearly filed the wrong issue.** Our roadmap said "mount#23/umount#24 are
> no-op stubs". The number was wrong — `mount` is **#11**; **#23 is `timerfd_settime`**
> — and we would have sent you hunting in the wrong row. Corrected on our side. Your
> own tracker records chakshu almost filing a phantom capability gap against `statfs`,
> and crab carrying a blocker for five releases after you shipped its fix. Same family.
> We re-read the kernel before writing this.

---

## 0. First, the things that are NOT gaps

**`statfs` #103 is the fix for capacity, and it works.** Filed by us on 2026-08-31,
resolved, archived. All three backends answer, it is mount-routed through
`vfs_resolve_mount` in the `#103` arm (searchable as `vfs_resolve_mount(arg1, arg2)` —
line number omitted deliberately, that region is being edited right now), and it
validates its path argument on every arm. Nothing about capacity is missing. crab draws a bar for any path it is *told*
about.

**And the mount table exists.** This is the finding that reshaped this issue:

| what | where |
|---|---|
| `vfs_mnt_count` | `kernel/core/vfs.cyr:373` |
| `vfs_mnt_backend[8]` — `FsBackend` id per slot | `:374` |
| `vfs_mnt_prefix_len[8]` — prefix byte length per slot | `:375` |
| `vfs_mnt_prefix[64]` — prefix strings, 64 bytes/slot | `:376` |
| `enum FsBackend { FS_NONE=0; FS_EXT2=1; FS_FAT=2; FS_EXFAT=3; }` | `:363-367` |
| filled by `vfs_mount_init()` | `:396`, called from `kernel/core/main.cyr:922` |

So the ask below is a **read-only getter over live state**, not a feature.

---

## 1. The gap, stated exactly

`mount` **#11** and `umount` **#24** are unconditional no-op stubs:

```
syscall.cyr:8658    if (num == 24) { return 0; }             # umount
syscall.cyr:8660    if (num == 11) { return 0; }             # mount (noop for now)
```

Both return 0, read no argument, and mutate nothing. `docs/development/agnos-userland-abi.md`
says so plainly — `:101` and `:114` mark them 🔧 stub in the frozen table, and `:122`
warns the cyrius peer "may expose them but must not rely on real behavior". **We are
not reporting a surprise, and we are not asking you to implement mounting.**

What we cannot do is *ask what is mounted*. There is no syscall in the allocated
`#0`–`#103` range that reports the mount table, and `§3` plans none.

## 2. Why the workaround is not good enough to leave alone

crab **can** ship something today, and we want to be honest that we could: the mount
namespace is a fixed set of three prefixes built at boot — `"/"`, `"/mnt/fat"`,
`"/mnt/exfat"` (`vfs.cyr:401,404,405,411,412`) — and `statfs` validates its path, so
`statfs("/mnt/fat", 8, buf) == 0` is a decent proxy for "FAT is mounted". Your own
smoke does this probe (`main.cyr:1837`).

We would rather not, and the reasons are specific:

1. **It hardcodes your mount namespace into our binary.** The day `vfs_mount_init`
   gains a fourth mountpoint, or renames one, crab is silently wrong and nothing
   fails — it simply stops listing a volume. That is the exact shape of the stale
   cross-repo claim both our trackers keep recording.
2. **It is a probe, not an enumeration.** It can only confirm paths we already
   guessed. It cannot answer "what is mounted", only "is this specific string".
3. **It cannot see aliasing.** When ext2 is absent, `vfs_mount_init` gives the
   FAT/exFAT volume `"/"` *and* its `/mnt/...` prefix — your comment at `:409-410`
   calls them "harmless redundant aliases". Harmless to routing; to a sidebar they
   are **the same volume listed twice**, and probing cannot tell.

## 3. The ask, smallest first

Ordered by (value to us) ÷ (kernel work). **Treat this as a menu.** Item 1 alone
unblocks us completely; everything below it is want, not need.

### 1. A mount-table getter — the only thing we actually need

One new syscall that copies the existing table out. Shape we would find sufficient,
though the design is yours:

```
mountlist(buf, buflen) -> count written, or -1
    per entry: backend id (u32) + prefix length (u32) + prefix bytes
```

Everything it returns already sits in `vfs_mnt_*`. No new bookkeeping.

⚠ **A new number rather than widening #11.** Your ABI gives #11 `—` in all three
argument columns (`abi.md:101`), and your own stated preference (`:234-235`) is to
mint rather than extend, because a 4th argument rides `r10` and the entry stub passes
whatever `r10` happened to hold — garbage for existing callers, not 0. You did widen
#13 `reboot` in place, but behind a magic-pair gate that fails closed
(`power.cyr:381-383`). We are not asking for that treatment; a new number is simpler
for both of us. **Which number, and whether to do it at all, is yours to decide.**

### 2. Nice, not needed: a volume label

`vfs_mnt_*` carries routing data only — backend id and prefix. No label, no device
identity, no removable flag. A sidebar reading `Root / FAT / exFAT` is honest and
fine; `AGNOS-BOOT` would be nicer. **Do not add bookkeeping for this on our account.**

### 3. Explicitly NOT asking for

- Real `mount`/`umount`. crab has no UI for mounting and no plans for one.
- Hotplug or change notification. Re-reading on a refresh key is fine.
- Anything about `blk_enum` #75 / `blk_info` #79. Block devices are a different
  question from mounted filesystems, and conflating them is how you end up listing a
  partition nobody can open.

## 4. What crab does in the meantime

The sidebar ships with **PLACES only** — `$HOME`, the well-known subdirectories that
actually stat, and `/`. VOLUMES is absent rather than approximated, and our roadmap
records it as blocked here with a pointer to this file. **Nothing in crab is waiting
on a reply**; we would just rather build the real thing once than build the probe now
and delete it later.

Thanks for `statfs` — it landed clean and we had it working the day we pinned it.
