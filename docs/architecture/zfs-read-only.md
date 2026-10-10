# Read-only ZFS — the invariants (agnos 1.57.11)

`kernel/core/zfs.cyr` (+ `zfs_codec.cyr`) reads OpenZFS pools. The on-disk format, the reference readers it was
grounded in (OpenZFS headers, FreeBSD's loader, GRUB/U-Boot) and every departure are in agnosticos
`docs/development/prior-art/zfs-prior-art.md`; the ring-3 contract is ABI §3.6. This page is what reading the
code alone will not tell you. **The write path is 1.57.12** (operator ruling 2026-10-09) — read § 7 before
starting it.

## 1. One walker, module scratch

Every entry point runs under `fs_spin_lock` (the vfs.cyr / syscall.cyr arms take it; `zfs_selftest` takes it
itself). That is what makes the module's scratch safe: the resolver's three path buffers, the dnode slots, the
ZAP query/iteration globals (`zfs_q_*`, `zfs_it_*`), the gang-depth counter, the SA-layout cache and the block
cache. A new caller that does not hold the lock corrupts another walk silently. `fs_spin_lock` is not reentrant
— a ZFS function must never call a locked VFS boundary function.

## 2. Memory: a 6 MiB area, allocated only on a hit

No large `.bss` (the image wall, CLAUDE.md). `zfs_try` allocates three contiguous 2 MiB regions
(`pmm_alloc_2mb_run(3)`) only after the cheap probe (the 12-byte XDR nvlist header at device +16 KiB) has
matched, and reaches them through the direct map — so `zfs_init` must run after `cr3_load(0x1000)` (the
`kfont_init` rule). A box without ZFS pays nothing; a probe that later fails frees the regions. The layout is the
`ZfsR` enum: 1 MiB raw I/O, 1 MiB decompressed data block, 16 × 128 KiB metadata cache, then labels, uberblock,
gang headers, a 128 KiB **zero area that is never written after init** (metadata holes return it), six 16 KiB
dnode slots (a full large dnode), dataset slots, graft entries, path buffers. Blocks over 1 MiB (data) / 128 KiB
(metadata) are refused by name, not truncated.

## 3. The block cache key is the block's identity

Slots 0–15 hold metadata, slot 16 the last data block. A normal BP is keyed by **DVA0 + logical birth + prop**
(the ARC's identity — two BPs naming the same DVA at the same birth are the same bytes); an embedded BP by its
whole 128 bytes. A pointer returned by `zfs_mc_get` is valid only until the next cache fill — callers copy the
BP they need (`var bp[128]`) before descending. A hole in metadata is the zero area; a hole in data returns `1`
and the caller zero-fills. Nothing is ever invalidated because nothing is ever written — **this is the first
thing the write path must change** (§ 7).

## 4. Checksums and decompression

`zfs_bp_read` tries each DVA (only those on our top-level vdev id), verifies the checksum of the PHYSICAL bytes,
then decompresses. ⚠ Word order is per algorithm: SHA-256 words are big-endian u64s of the digest, but native
SHA-512/256 stores the digest BYTES (`sha2_zfs.c`), hence `zfs_sha512_256_le_words`. lz4 and gzip must produce
exactly `lsize` bytes (`zfs_codec_outlen`). Unsupported algorithms fail the block with `zfs_why` set and a named
line upstream — never an unverified read.

## 5. The namespace is a graft table, not a mount per dataset

The VFS sees one backend (`FS_ZFS`, `/mnt/zfs`). Inside it, `zfs_dsl_walk` computes every dataset's effective
`mountpoint` (local, `$recvd`, inherited) and `canmount`, and grafts the ones `zfs mount -a` would mount (plus
`bootfs`). `zfs_build_namespace` adds a **virtual directory** for every strict ancestor of a graft that is not
itself one, and records each entry's parent ref. Resolution (`zfs_resolve`) keeps a canonical textual path:
a graft at the canonical path shadows whatever the parent dataset holds there; a real on-disk directory beats a
virtual one; `..` pops the canonical stack (ZFS has no hard-linked directories, so textual parent == physical
parent); a symlink splices its target into the remaining path — absolute targets restart at the namespace root.
A ref is `(dataset slot + 1) << 48 | object` or a virtual-dir index; object numbers are 48-bit.

## 6. What is refused, and where

Import (`zfs_config`, `zfs_mount_pool`): an unknown or layout-changing `features_for_read` entry, >1 top-level
vdev, raidz/dRAID/indirect, a big-endian pool, a destroyed pool. Graft (`zfs_ds_open`): an encrypted dataset
(the objset BP's crypt bit), an incomplete receive, a non-filesystem objset, a dataset whose metadata uses an
unimplemented checksum. Read: a zstd / skein / edonr / blake3 / redacted block. Each says why
(`zfs_why_msg`). The ZIL is not replayed.

## 7. Before the write path (1.57.12)

- The cache keys assume immutability: a write must invalidate (or update) every slot naming a rewritten block,
  and the data-block slot.
- `zfs_txg` / the chosen uberblock are read once at mount; a writer owns the txg and must write uberblocks to
  every label's ring with the embedded checksum (§ 1.1 of the prior art).
- The gang depth, the SA-layout cache key and `zfs_q_*` are single-walker globals: keep the fs_lock rule or
  move them per-call.
- `zfs_open` refuses `0x303`; `vfs_write` has no ZFS arm; every mutation arm returns -1 for `FS_ZFS` today.

## Gates

`scripts/smoke/zfs-smoke.sh` (seven OpenZFS-built pools, exact manifest diff), `scripts/harness/zfs-ring3-test.py`
(+ `tests/zfs/zfsx.cyr`, exec'd from the pool), `scripts/check/host-zfs-oracles.sh` (check.sh gate 37: the codec
on the host, mutation-proven). Fixture: `scripts/tool/zfs-fixture.sh` (a FreeBSD 15.1 guest under KVM; cached).
