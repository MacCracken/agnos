# `open`(7) has no no-follow flag — a check-then-write TOCTOU that ring 3 cannot close

**Status:** ✅ **RESOLVED — `AO_NOFOLLOW` SHIPPED 1.56.53, RESIDUALS SWEPT 1.56.55. Archived 2026-08-31.** The flag works and now has everything a shipped flag needs on the agnos side: an ABI row in §3.3 (missing for two cuts), and a real gate — `ext2-write-smoke.sh` asserted every other `ext2w:` marker but not `Wlstat no-follow`, so a kernel ignoring the flag entirely would have scored a PASS. Both fixed; `PASS: Wlstat (AO_NOFOLLOW refuses a symlink at the final component)` runs in the sweep.
⚠ **Two items live elsewhere, deliberately, and neither belongs in an agnos issue:** the cyrius `AO_NOFOLLOW = 0x1000` constant is cyrius`s (ring 3 cannot name the flag until it lands; no peer issue was ever filed for it, unlike `#63`/`#70`/`#96`/`#102`), and `whirl` 0.6.13 still carries this as open kernel ask **B2**, unaware the flag shipped — that is a note for whirl, not open agnos work.
⇒ **`AO_EXCL` moved out** to [`2026-08-31-open-ao-excl-flag.md`](2026-08-31-open-ao-excl-flag.md), filed by a second consumer (crab). ⚠ That filing asked for `0x400`, which is **`AO_APPEND`** — this file`s own flag table shows it. Corrected to `0x2000`.

**Superseded status (kept for the arc):** 🟠 `AO_NOFOLLOW` SHIPPED 1.56.53 AND WORKS; THIS FILE NOW TRACKS ITS THREE UNSWEPT RESIDUALS. Re-audited 2026-08-31 against 1.56.55.
⇒ **`AO_EXCL` has moved out.** It is its own record now — [`2026-08-31-open-ao-excl-flag.md`](2026-08-31-open-ao-excl-flag.md), filed by a second consumer (crab) — so this file no longer carries it. ⚠ Note for whoever implements it: that filing originally asked for `0x400`, which is **`AO_APPEND`**; the corrected bit is `0x2000`. This issue's own flag table below shows `AO_APPEND = 0x400` and is what should have been read.
⛔ **What shipped reached the kernel and nothing else, which is why the flag is still unusable from ring 3 by name:**
1. **No ABI row.** §3.3's flag table stopped at `AO_DIRECTORY 0x800` for two cuts — the flag shipped and the one artifact ring-3 authors read never mentioned it. `lstat`#102, minted by the *same* cut, got a full row. ✅ **Fixed 1.56.55.**
2. **No cyrius constant.** `lib/syscalls_x86_64_agnos.cyr`'s `AgnosOpenFlag` enum still ends at `AO_DIRECTORY`, so ring 3 cannot name `AO_NOFOLLOW` at all. Unlike `#63`/`#70`/`#102`/`#96`, **no peer issue was ever filed for it** — that is the outstanding cross-repo debt on this record.
3. **The gate could not go red.** `ext2.cyr` prints `ext2w: Wlstat no-follow OK` / `... MISMATCH`, and `ext2-write-smoke.sh` asserted every other `ext2w:` marker but not that one. A kernel ignoring the flag entirely would print MISMATCH and still score a PASS — so the gate the CHANGELOG and this header both cite as proof of the flag was never an assertion. ✅ **Fixed 1.56.55**, with the MISMATCH arm grepped separately so "failing" and "absent" do not share a message.
⚠ **And the filed consumer was never told.** `whirl` (0.6.13) still carries this as open kernel ask **B2** — *"the one open kernel ask is B2 — an AO_NOFOLLOW flag on open(7)"* — unaware the flag shipped four cuts ago and that its TOCTOU is now closable.

**Original status:** ✅ **FIXED 1.56.53** — `AO_NOFOLLOW = 0x1000` landed on `open`(7), routing to `ext2_path_lookup_ex(..., follow_last=0)` and refusing when the final component is `0xA000`, exactly as proposed. Gated by `ext2w: Wlstat no-follow OK` (mutation-tested: ignoring the flag reports `AO_NOFOLLOW opened a SYMLINK`). ⭐ The cut also minted **`lstat`#102**, which this issue's own "Related" section anticipated — an iron burn supplied the consumer, in the form of two entries that could be listed but neither stat'd nor removed. `AO_EXCL` was NOT added and remains open.

**Original status:** 🟡 OPEN — request. The kernel already has the machinery (`ext2_path_lookup_ex(path, len, follow_last)`, `kernel/core/ext2.cyr:3032`); it is reachable from ring 3 only through `readlink`#70. Exposing it on `open`(7) as an `AO_NOFOLLOW` flag would close the race.
**Repo owning the design:** agnos.
**Cross-repo:** cyrius needs no new wrapper — `sys_open(name, namelen, flags)` already passes flags in a3 (`lib/syscalls_x86_64_agnos.cyr:560`). A new flag constant is additive.
**Consumer:** `whirl` — `-r` recursive fetch, `_save_tree` (`src/main.cyr`) / `fs_is_symlink` (`src/output.cyr`). Its roadmap carries this as **B2**.
**Precedent:** `readlink`#70 (agnos 1.5x) introduced the no-follow lookup this asks to reuse. Its own ABI note anticipated the reuse: *"the no-follow lookup it introduces is exactly what a future `lstat` would reuse if a consumer ever needs no-follow"*.
**Severity:** Medium — a real race with security consequence, but narrow (needs local write access to the output directory and a timing win), and the consumer already mitigates the wide case.

---

## Summary

A ring-3 program that wants to write a file **without following a symlink at the
final component** has no way to do it atomically. It can *detect* a link
beforehand — `readlink`#70 does exactly that, no-follow — but between the check
and the `open`(7) the path can be replaced with a symlink, and the write then
lands wherever the link points.

`open`(7)'s flag set (`§3.3`, and `lib/syscalls_x86_64_agnos.cyr:287-293`) is:

| flag | value |
|---|---|
| `AO_RDONLY` / `AO_WRONLY` / `AO_RDWR` | `0x0` / `0x1` / `0x2` |
| `AO_CREAT` | `0x100` |
| `AO_TRUNC` | `0x200` |
| `AO_APPEND` | `0x400` |
| `AO_DIRECTORY` | `0x800` |

There is no `AO_NOFOLLOW`, and no `AO_EXCL` either — so neither of the two
standard ways to make this safe is available.

## Why this is a small ask

The no-follow path lookup **already exists in the kernel** and is already
exercised in production by `readlink`#70:

```
kernel/core/ext2.cyr:3032
fn ext2_path_lookup_ex(path, path_len, follow_last) {
```

with the documented contract (`:3019-3028`) that `follow_last=0` resolves the
trailing component to *its own* inode, mid-path symlinks still resolve, and the
`follow_last=1` wrapper every existing caller uses is unchanged.

So this is not "add symlink-aware path resolution". It is: **plumb the flag that
already selects it through to `open`(7)**, on the same shape #70 uses.

## Reproduction (the race, on the consumer)

`whirl -r <url>` mirrors a crawled site into the working directory. For each
resource it currently does:

1. `fs_is_symlink(path)` → on agnos, `sys_readlink(path, …) >= 0` means "link"
2. if not a link, `file_write_all(path, …)` → `open`(7) with `AO_CREAT|AO_TRUNC`

Between (1) and (2), anything that can write to that directory can replace
`path` with a symlink to a file elsewhere, and step (2) writes through it. The
window is small but the primitive is unbounded: the attacker can retry, and a
crawl writes many files.

The same shape applies to any ring-3 program that writes into a directory it does
not exclusively own — installers, extractors, download tools.

## What the consumer does today

whirl (0.6.12) does the pre-check above on both targets — `lstat` on Linux,
`readlink`#70 on agnos — and refuses to write when it sees a link. That closes
the whole **pre-planted symlink** class, which is the realistic case, and it is
what shipped. It does **not** close the race, and cannot: there is no atomic
no-follow open on either target's frozen surface as whirl uses it.

Linux has `O_NOFOLLOW` available in principle, so on that target the fix is
consumer-side work (a private open/write path instead of the stdlib
`file_write_all`). On agnos there is no such flag, so the agnos half is a kernel
ask — which is why this is filed here rather than solved locally.

**Nothing is broken today** and no shipping build is blocked. This is a
hardening request with a documented consumer, filed so the residual race is on
the record rather than living only in whirl's roadmap.

## Proposed fix

Add one flag:

```
AO_NOFOLLOW = 0x1000    # fail with -1 if the FINAL component is a symlink
```

`open`(7) routes to `ext2_path_lookup_ex(..., follow_last=0)` when it is set, and
returns -1 if the resolved final component has the `0xA000` mode bits — mirroring
`ext2_readlink`'s existing check. Mid-path symlinks keep resolving, matching #70
and POSIX `O_NOFOLLOW`.

Two notes, both the maintainer's call:

1. **`AO_EXCL` would be a useful companion but is not a substitute.** `AO_CREAT|AO_EXCL`
   makes the *create-new* case safe, which covers a first crawl but not a re-crawl
   that overwrites its own earlier output. If only one lands, `AO_NOFOLLOW` is the
   one that closes the general case.
2. **Non-ext2 mounts.** `readlink`#70 returns -1 on a non-ext2 mount because
   symlinks need inodes. FAT/exFAT cannot represent a symlink at all, so
   `AO_NOFOLLOW` is trivially satisfied there — worth stating explicitly in the
   ABI row either way, so a consumer knows the flag is not silently ignored.

## Related

- `readlink`#70 — the no-follow primitive this reuses; ABI §, and
  [`archived/2026-07-08-cyrius-agnos-sys-readlink-peer.md`](./archived/2026-07-08-cyrius-agnos-sys-readlink-peer.md)
  for its cyrius peer.
- `symlink`#63 — the creation half, which is what makes a planted link possible
  from ring 3 in the first place.
