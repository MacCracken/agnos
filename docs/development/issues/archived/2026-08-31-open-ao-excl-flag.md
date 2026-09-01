# `open`#7 has no `AO_EXCL`, so an application's "do not overwrite" guard cannot exist on agnos

**Status:** ✅ **SHIPPED 1.56.56 as `AO_EXCL = 0x2000`, mutation-gated. Archived 2026-08-31.**
The kernel arm is in `sys_open_ext2_inner` beside `AO_NOFOLLOW`, FAT/exFAT answer it through
`fatfs_create`/`exfat_create`s existing-name refusal, and §3.3 of the userland ABI carries the row.
⛔ **THE POSITION OF THE CHECK IS THE LOAD-BEARING PART, AND THE GATE ASSERTS IT.** The arm sits ABOVE
the `AO_TRUNC` one: placed below it, an `AO_CREAT|AO_TRUNC|AO_EXCL` open — precisely what the filed
consumer sends on every copy — would zero the file and *then* refuse it, destroying exactly what the
flag protects. So `ext2w: Wexcl` asserts the surviving SIZE, not just the refusal. **Measured**: moving
the check below the truncate reports `ext2w: Wexcl TRUNC|EXCL TRUNCATED the file it refused` and a
second arm besides. Five arms in total — the refusal plus three controls, because a flag that refused
everything, or nothing, would satisfy a lesser test.
⚠ **Returns -1, not -17.** agnos has no `-errno`; crab`s `-17` assertion is its LINUX arm, and the
translation belongs in the cyrius wrapper. ⚠ **The cyrius `AO_EXCL` peer constant is still owed** — as
is `AO_NOFOLLOW`s from 1.56.53 — and is cyrius-side work, tracked there rather than here.
⭐ **The bit was wrong as filed and that is the durable lesson**: `0x400` is `AO_APPEND`, declared in
the ABI and SET AT RUNTIME by cyrius `lib/io.cyr` on every append-open. The kernel tests no `0x400`
today, so reading the kernel alone made it look free. **The kernel is canonical for the syscall NUMBER
set but not for the FLAG set** — the ABI table and the cyrius enum are.

**Original status:** 🟡 OPEN — the ask is valid, the proposed bit was not. Corrected 2026-08-31 (1.56.55).
⛔ **This filing asked for `AO_EXCL = 0x400` on the stated premise that "0x400 is unused". It is not:
`0x400` is `AO_APPEND`**, declared in [`agnos-userland-abi.md`](../agnos-userland-abi.md) §3.3 and in
cyrius `lib/syscalls_x86_64_agnos.cyr`, and **set at runtime today** — cyrius `lib/io.cyr` bridges
Linux `O_APPEND` to `0x400` on every append-open. Minting `AO_EXCL` there would have turned every
existing append-open on agnos into `EEXIST`: the exact opposite of the "⚠ Additive" claim this issue
rests on. ⭐ **The error is instructive and not careless** — the author read the KERNEL, where nothing
tests `0x400` (`AO_APPEND` is declared-but-unimplemented, `syscall.cyr` says *"AO_APPEND TODO"*), and
concluded the bit was free. The kernel is canonical for the number SET but not for the FLAG set; the
ABI table and the cyrius enum are, and both had it allocated. ⇒ **The correct bit is `0x2000`**, and
§3.3's `AO_APPEND` row now carries this hazard so the next reader cannot repeat it.
⚠ Everything else in this filing checks out and it remains a live request: the consumer is real, the
branch is where it says it is, and `ext2.cyr`'s "an existing name is RETURNED, not created" comment is
the exact site. **Nothing is implemented yet** — the kernel arm, the gate and the cyrius peer are all
still owed. What changed at 1.56.55 is only that the ask is now correctly specified.
**Placement:** `kernel/core/syscall.cyr`, beside the `AO_NOFOLLOW` (0x1000) arm added in 1.56.53 —
and a matching `AO_EXCL` constant in cyrius `lib/syscalls_x86_64_agnos.cyr` — whose `AgnosOpenFlag`
enum today stops at `AO_DIRECTORY = 0x800` (see *Also needs a cyrius peer* below for the full list and
for the `AO_NOFOLLOW` constant owed alongside it).
**Filed:** 2026-08-31, by **crab**.
**Affects:** every agnos release. `AO_NOFOLLOW` (1.56.53) closed the *symlink* half of the same
problem; this is the other half.
**Severity:** **Medium, and it is a silent behavioural divergence rather than a missing feature.** An
application that guards against overwriting on Linux gets that guard; the same source built
`--agnos` gets a truncate. Nothing errors, so nothing surfaces it.

⭐ **agnos already knows.** `kernel/core/syscall.cyr:1138`, in the `AO_NOFOLLOW` comment:

> *"`open`(7) had no way to write a file without following a link at the last component, and **no
> AO_EXCL either** — so neither standard way to make a check-then-write safe was available."*

That note was written with `whirl -r` as the filed consumer. This issue is a **second** consumer
arriving at the same gap from a different direction, which is the bar the roadmap sets for minting a
flag.

## The consumer

crab's write layer (`src/app.cyr`) has one entry point for creating a file:

```cyrius
fn crab_fs_open_w(path, plen): i64 {
    #ifdef CYRIUS_TARGET_AGNOS
    return sys_open(path, plen, AO_WRONLY | AO_CREAT | AO_TRUNC);
    #else
    return sys_open(path, O_WRONLY | O_CREAT | O_EXCL, 0x1A4);   # 0644
    #endif
}
```

The host arm is deliberate: it is crab's **overwrite guard**, shipped in M4 (v0.7.1). A copy or move
whose destination name already exists must refuse, because the alternative is destroying a file the
operator did not name. It is asserted in crab's suite —
`assert_eq(crab_fs_open_w(...), -17, "the host write-open REFUSES an existing file (EEXIST)")`.

**On agnos that assertion is a claim about the host only.** With no `AO_EXCL` to express it, the
agnos arm falls back to `AO_TRUNC`, so the identical `crab_fs_copy` call that refuses on Linux
**truncates the destination** on the target that ships. The consequence is worst exactly where crab
is most destructive: a recursive copy walks a tree calling this per file, and a collision anywhere in
that tree is an overwrite nobody was asked about.

⚠ crab cannot work around it in ring 3 for the same reason `whirl` could not work around
`AO_NOFOLLOW`: a `stat`-then-`open` pre-check is a TOCTOU window, and crab's copy is *stepped off an
idle tick*, so that window is not microseconds — it is however long the operator leaves the transfer
running.

## The ask

```
AO_EXCL = 0x2000       # 0x800 = open-dir, 0x1000 = AO_NOFOLLOW, 0x2000 = first free bit
```

With `AO_CREAT`, fail the open when the final component **already resolves**, rather than opening it.
POSIX semantics: `EEXIST`. Without `AO_CREAT`, undefined/ignored, as POSIX has it.

The lookup that decides this already runs — `ext2_path_lookup_ex` resolves the final component before
`vfs_create_on` is reached, and `kernel/core/ext2.cyr:2715` documents the current behaviour
explicitly:

> *"POSIX open(O_CREAT)-without-O_EXCL: an existing name is RETURNED, not [created]"*

So the branch that would answer `EEXIST` is the one that currently returns the existing inode. This
looks like the same shape and size as the `AO_NOFOLLOW` change: no new path resolution, just a flag
selecting between two outcomes the lookup already distinguishes.

⚠ **Additive at `0x2000`**: no existing caller sets that bit, so every current `open` is
byte-identical. ⛔ **This line originally claimed the same of `0x400` and was wrong** — see the Status
header. `0x400` is `AO_APPEND` and cyrius `lib/io.cyr` sets it on every append-open.
⚠ **FAT/exFAT**: the same directory-entry lookup exists there, so the flag is answerable on all three
filesystems rather than being ext2-only.

## Also needs a cyrius peer

`lib/syscalls_x86_64_agnos.cyr`'s `enum AgnosOpenFlag` defines seven constants — `AO_RDONLY`,
`AO_WRONLY`, `AO_RDWR`, `AO_CREAT`, `AO_TRUNC`, `AO_APPEND`, `AO_DIRECTORY` — and nothing for
exclusivity, so ring 3 cannot name the flag even once the kernel honours it. ⛔ **It does NOT define
`AO_NOFOLLOW` either**, which this paragraph originally claimed: that flag shipped in agnos 1.56.53
and never got a cyrius peer, so it too is unnameable from ring 3 today and is a second constant owed
by the same edit. Same
kernel-mints-it/cyrius-owns-the-peer split as `sys_lstat`#102
(`cyrius/docs/development/issues/2026-08-30-agnos-sys-lstat-102-peer.md`).

## Until then

crab has **flagged rather than changed** its behaviour: the divergence is recorded in
`docs/development/state.md` under *Known gaps* and pinned by the host assertion above, so the next
person to read "crab will not overwrite" is told which target that is true on. Changing the agnos arm
to match the host is not possible; changing the host arm to match agnos would be deleting a working
guard to achieve consistency, which is the wrong direction.
