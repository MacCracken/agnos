# ZFS — the invariants (agnos 1.57.11 read, 1.57.12 write)

`kernel/core/zfs.cyr` (+ `zfs_codec.cyr`) reads OpenZFS pools (1.57.11); `kernel/core/zfs_write.cyr` (+
`zfs_wenc.cyr`) writes them (1.57.12). The on-disk format, the reference readers and writers it was grounded in
(OpenZFS, FreeBSD's loader and `makefs`, GRUB/U-Boot) and every departure are in agnosticos
`docs/development/prior-art/zfs-prior-art.md` (read) and `zfs-write-prior-art.md` (write); the write design — scope,
every refusal by name, the commit order, the oracle, and each bite's gate, review and decision record — is
[`../development/proposals/2026-10-09-zfs-write.md`](../development/proposals/2026-10-09-zfs-write.md) ("the
design"); the ring-3 contract is ABI §3.6. This page is what reading the code alone will not tell you: §§ 1–6 the
reader, **§ 7 the write path's rules in one place**, §§ 8–17 each write bite's invariants as built. (This page was
`zfs-read-only.md` until 1.57.12; its section numbers did not change.)

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
and the caller zero-fills. Nothing is ever invalidated — and since 1.57.12 that still holds: the writer never
rewrites a block in place, so a cached identity never names changed bytes (§ 7).

## 4. Checksums and decompression

`zfs_bp_read` tries each DVA (only those on our top-level vdev id), verifies the checksum of the PHYSICAL bytes,
then decompresses. ⚠ Word order is per algorithm: SHA-256 words are big-endian u64s of the digest, but native
SHA-512/256 stores the digest BYTES (`sha2_zfs.c`), hence `zfs_sha512_256_le_words`. lz4 and gzip must produce
exactly `lsize` bytes (`zfs_codec_outlen`). Unsupported algorithms fail the block with `zfs_why` set and a named
line upstream — never an unverified read.

## 5. The namespace is a graft table, not a mount per dataset

The VFS sees one backend (`FS_ZFS`, `/mnt/zfs`). Inside it, `zfs_dsl_walk` computes every dataset's effective
`mountpoint` and `canmount` — per dsl_dir in `dsl_prop_get_dd`'s order (`zfs_prop_find`: `$iuv`, local, then `$recvd`
unless a `$inherit` key masks it — `zfs inherit` over a received value; inherited from the parent otherwise) — and grafts the ones `zfs mount -a` would mount (plus
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

## 7. The write path: the rules every commit keeps (1.57.12)

Until 1.57.12 this section was the pre-write checklist (cache invalidation, a txg the writer owns, the single-walker
globals, the mutation arms); each item is answered by a rule below. §§ 8–17 hold each bite's detail; the design's § b
(the txg model), § c (the allocator), § d (the commit order) and § a.3 (every refusal) are the long form.

- **G1 — a read-only mount writes not one byte.** The verdict is the gate's, at mount, per pool and per dataset
  (§ 8); `zfs_wr` is the only device write and refuses by region before any I/O (§ 9). A pool that is not rw — refused
  at its gate, or after a failed commit — is never written again that boot. `zfs-smoke.sh` holds every read-only lane's
  partition byte-identical to the fixture after the boot.
- **One txg is the dirty set; `zfs_commit` turns it into txg T = previous + 1 under `fs_lock`** — a helper: every
  caller holds the lock, the commit never takes it. The engine is policy-free; policy B (§ 17) decides WHEN it runs.
  The writer's own reads go dirty-first, then the reader (a block fetched for change is copied out of the cache, never
  edited in its slot); the READER never consults the dirty set, so an entry that runs before the commit sees T − 1 —
  hence commit-before-observe.
- **The commit order** (design § d): the DATASET phase per dirty objset — data and dataset metadata finalised bottom-up
  and written, born / kill, the user / group / project deltas, the meta-dnode's dnode blocks and indirects, the
  `objset_phys`, `ds_bp` and the dsl_dir chain (§ 10) — then the MOS phase: the MOS mutations (deadlists, `free_bpobj`,
  refcounts, `U[]`, hygiene's space-map appends and log destroys, log T's dnode and its log-ZAP entry), the non-chain
  blocks written, then the CHAIN (log T, the MOS dnode blocks holding the log / `$MOS` / root dir, the meta-dnode
  indirects, the MOS `objset_phys`) filled bottom-up once every allocation and free of T is known · **FLUSH** ·
  uberblock T into slot `T % N` of L0, L1, L2 and L3, each copy its own eck (a label's `[0, 128 KiB)` and the boot
  region are never written) · **FLUSH** · publish (`zfs_wc_pub`: the uberblock, the MOS, every touched dataset slot,
  `zfs_txg`), then its tail (`zfs_wc_tail`: the deferral release, hygiene's reservation for T + 1).
- **Every allocation of T is made in its plan, before any of its writes, and only from units T − 1's publish
  released.** Until one whole copy of uberblock T is on the device the pool IS T − 1 — T − 2 and T − 3 whole too,
  OpenZFS's rewind window — every block of T unreferenced free space; a torn copy fails its eck and loses to T − 1's
  slot (a different index); the first FLUSH precedes every uberblock copy, so a landed copy names durable blocks. A crash
  leaves one of two consistent pools. Proved on disk by the four crash-cut lanes (§ 17; design k.127).
- **Durability points.** A `write`#1 through an fd is coalesced (policy B, § 17) and durable at `close`#6 of an fd of
  its file, `sync`#12, the death of its process (committed before the death is published), `power_flush`, a threshold
  (the 4 MiB data arena, the metadata arena, `ZWF_TXGBLK`, OpenZFS's in-flight reserve), the 5 s age bound seen at a ZFS
  entry, and before any entry that would observe it (a read / `SEEK_END` / `stat` / `open` / exec of the object,
  `statfs`, every mutation, a write to another object). Every other write verb — create, `mkdir`, `symlink`, `unlink`,
  `rmdir`, `rename`, `link`, `AO_TRUNC` — commits its own txg(s) before it returns. Nothing commits inside an interrupt
  handler: the commit is owed to the next B1 (`zfs_wp_owed`). A pending txg is never dropped — a backstop that should
  never fire names the loss and the owner's close / sync answers -1.
- **Deferral = TXG_DEFER_SIZE (2), exactly OpenZFS's.** A unit freed in txg T is released when T + 2 is durable and is
  allocatable from T + 3 (`zfs_wdef_rel`, `metaslab_sync_done`'s `ms_defer` rotation); the mount's own window (T0 − 2 ..
  T0) is released by evicting every resident metaslab (OpenZFS at its slop may have reallocated those units). A log
  destroyed while its txg is inside the window keeps its FREEs deferred as a GHOST, retired with the window (≤ 3, § 16;
  design k.133 (a)). Two bitmaps per resident metaslab — allocated and deferred — never conflated (§ 8).
- **Kills are OpenZFS's** (`dsl_dataset_block_kill`): freed in T and deferred as above; a block a snapshot (or a
  clone's origin) still owns onto the dataset's deadlist (§ 15); a gang / dedup / cloned block — and every kill while
  `block_cloning` or `fast_dedup` is active — appended to `free_bpobj` for OpenZFS's async destroy (§ 13). Accounting is
  exact deltas: dataset, the dsl_dir chain with `parent_delta`, `$MOS`, `$FREE`, user / group / project, feature
  refcounts (§ 10).
- **Nothing a commit dirties may refuse it.** Every policy refusal is judged at ADMISSION — when the op dirties — and
  changes nothing. What can still fail inside a commit (an I/O or flush error, a reservation that did not hold) fails
  the pool read-only until reboot, by name (`zfs: commit txg N failed: <why> - pool read-only until reboot`, § 9); a
  failure after uberblock T is durable (the deferral release) does the same but the commit answers 0 — the writes are
  on disk.
- **The logs stay bounded** (§ 16): every txg bumps clean metaslabs, flushes the dirty one of least U, and destroys the
  logs older than every U; the first flush and every live log's destruction are reserved out of what admissions may
  take (`ZWL_HAR`). ≤ 16 alive after every txg on every lane; `ZWK_MAXLOG` (1,024) is the named failure bound.
- **`fs_lock` is held for a whole commit** — ≈ 20 ms a txg on QEMU/KVM NVMe, ≈ 80 ms on AHCI, tails to 2.5 s in a
  device stall (design k.126; iron unmeasured). The committing CPU opens interrupt windows inside it on NVMe and AHCI
  (`kirqw_point`, ≤ 3 ms between two); another CPU that wants `fs_lock` waits for all of it — the ZFS ownership lock
  that would end that is open (design k.132 (1)). A `write`#1 or truncation of several txgs releases `fs_lock` between
  them (`zfs_wf_yield`), re-checks its fd, and re-runs the entry rule.
- **Every refusal has a name** — the design's § a.3 is the list: a pool or dataset left read-only at mount
  (`zfs: <pool> read-only (<why>)`, `zfs: <pool>/<ds> read-only (<why>)`), an op refused per call (-1, `zfs_why`, and
  `zfs: <verb> refused (<why>)` on the console). Never a silent refusal and never a silent drop.
- **The block cache needs no invalidation** (§ 3): it is keyed by a block's identity, and COW never rewrites a block in
  place — a changed block is a new DVA with birth T, and a freed unit is reused only after the deferral window, at a
  new birth. `zfs_txg` moves with every commit; `zfs_t0` (the mount txg) does not (§ 9). The single-walker globals keep
  the `fs_lock` rule of § 1.

## 8. The write gate (1.57.12 bite B1, `kernel/core/zfs_write.cyr`)

`zfs_init` calls `zfs_wmount` once, after the reader mounted the pool (whose `zfs: pool …` line no longer says
"read-only": the access verdict is the gate's). It **writes nothing** (gate G1: `zfs-smoke.sh` compares every lane's
pool partition with the fixture image after the boot) and prints `zfs: <pool> rw` or `zfs: <pool> read-only (<why>)`,
then `zfs: <pool>/<ds> read-only (<why>)` per refused grafted dataset — the root dataset prints as `<pool>/` (zdb's
spelling) so it cannot be mistaken for the pool line. The verdict is the dataset slot's `+1016` word (1 = writable).
The rules are the design's § a.2/a.3 (`docs/development/proposals/2026-10-09-zfs-write.md`); what code alone hides:

- **A second, lazy 8 MiB area** (`pmm_alloc_2mb_run(4)`, layout `ZfsWA`) is taken only after the label-level gate
  passed, and given back when the pool ends read-only. Its first 4 MiB are mount-time scratch until B3 owns them.
- **An unreadable key is never "absent".** Every gate lookup tells a read error from a missing key (`zfs_wzu64`,
  `zfs_wzno`, `zfs_wprop`): the reader may fall back to a default, but a gate that did would pass a checkpoint, a
  redacted dataset or `readonly=on` it could not read. A dataset or dsl_dir object has keys only once **zapified**
  (`dn_type` `DMU_OTN_ZAP_METADATA` = `0xC4`); that is where per-dataset feature flags live
  (`com.delphix:redacted_datasets` — present with any value, even a u64 array, refuses the dataset).
- **A mount reads each log space map once and each metaslab's space-map header — never every space map.** The one
  log scan checks every log and sums, per metaslab, the entries the import would replay (txg ≥ `U[i]`); allocated =
  `smp_alloc` + that net (the slop baseline). Bitmaps load on first use (`zfs_ms_load`, OpenZFS's `metaslab_load`)
  and must then count exactly that number. `ZFS_WRITE_SELFTEST` replays EVERY metaslab at mount and dumps it, and
  `zfs-smoke.sh` diffs the dump against an independent host replay (`scripts/smoke/lib/zfs-wms-check.py`).
- **`spacemap_histogram`'s refcount is zdb's count**: space maps with a 320-byte bonus — the metaslabs' and the leaf's
  DTL (created by the first scrub or resilver, MOS config `DTL`) — plus every log space map. B3 adds one per log it
  creates, so a pool where it is already off is refused ("space map refcount mismatch"), as is `log_spacemap` ≠ 1.
- **Two bitmaps per resident metaslab, never conflated.** *Allocated* is the pool's true state: the metaslab SM in
  file order, then every log space map with txg ≥ `U[i]`, ascending, entries of that metaslab only — ALLOC demands
  every bit clear, FREE every bit set, and every SM's `smp_alloc` must equal its net. *Deferred* marks what this boot
  must never hand out: FREEs in any log with txg ≥ T0 − 2 (whatever `U` says) and FREEs appended to an SM after T0.
  Allocatable = neither. Σ allocated = zdb's "Normal class" + the unflushed net = "bp allocated" on a leak-free pool.
- **The ZIL is classified for every head dataset in the DSL**, grafted or not: a live chain's blocks are outside the
  space maps wherever its dataset lives. A dataset whose metadata checksum the codec lacks (skein / edonr / blake3)
  has its objset read **unverified** for this purpose only; the ZIL head block is verified on its own (ZILOG2 =
  fletcher4 with the BP's checksum as verifier). ⛔ That is sound only because the pool is EXPORTED (ruling D7 a): an
  exported pool holds no live chain, so a misread header can only land in a class that accepts the pool. Any D7 (b)
  work (forced ACTIVE pools) must refuse pools holding such a dataset, or implement those checksums, first. An
  encrypted dataset's objset is authenticated, not encrypted — read with the crypt bit cleared in a copy of the BP.
- The DSL walk is iterative (a stack in the mount scratch, 1,024 deep — OpenZFS nests 50 by default, a tunable).
- `$ORIGIN@$ORIGIN` is every non-clone filesystem's `dd_origin_obj` and first `ds_prev_snap_obj`: "clone" and
  "has snapshots" are both "≠ 0 and ≠ that object".

## 9. The first write: the uberblock-only commit (1.57.12 bite B2, `kernel/core/zfs_write.cyr`)

`zfs_commit_ub` writes uberblock T = T0 + 1 naming T0's `ub_rootbp` — what OpenZFS itself writes when only the config
is dirty (`vdev_label.c:2069-2077`), and accepted by every oracle phase (design § k.1). **Only the `ZFS_WRITE_OPS` op
list calls it** (`zfs_wtest`, from `main.cyr` right before the `ZFS_SELFTEST` walk), so G1 still holds for every other
kernel. What the code alone will not tell you:

- **`zfs_wr` is the only device write, and it refuses by region before any I/O**: a non-rw pool, a range outside the
  device or off LBA boundaries (the gate refuses ashift below the LBA size, so an aligned extent is the only kind a
  commit has), and — until B3 admits extents allocated in the open txg — anything but one label's 128 KiB uberblock
  ring. A label's `[0, 128 KiB)` and the boot region are never written (WPA § 2.2).
- **The order is `vdev_config_sync`'s without its label phases**: flush · slot `T % N` into L0, L1, L2, L3 (each copy
  its own eck, verifier = that copy's partition-relative offset, `zfs_eck_set`) · flush · publish (`ZR_UB`, `zfs_txg`).
  Until a copy is durable the pool IS T0 (T0's slot is a different index and untouched); a torn copy fails its eck; any
  one whole copy selects T — so any crash leaves one of two consistent pools.
- **The gate scores the rings the way OpenZFS does, so a torn copy never locks agnos out** (`zfs_wub_scan`). A slot
  with a txg above T0 that OpenZFS would select makes the pool read-only (agnos's txgs would vanish behind it), but
  OpenZFS selects only slots whose eck verified (`vdev_uberblock_load_done`, `vdev_label.c:1546`): a NATIVE slot
  counts only then. Until the B2 review it counted on its magic alone, so one crash part-way through a commit (T0 + 1's
  first sector landed, its eck stale) left the pool read-only for agnos until another OS synced past it. Now the next
  mount is rw at T0 and its first commit rewrites that slot (`zfs-write-smoke.sh` lane `ashift9-torn`). A
  BYTE-SWAPPED slot still counts on its magic (this reader cannot verify one; fail closed). The same scan refuses a
  pool whose T0 copies are not zero from byte 216 (`uberblock has fields past 216 bytes`): a newer OpenZFS's longer
  `uberblock_t` would lose fields to a commit that copies 216 bytes.
- **A failed write or flush makes the pool read-only until reboot** (`zfs_wfail`: `zfs_rw` 0, every dataset verdict 0,
  the writer area returned, `zfs: commit txg N failed: <why> - pool read-only until reboot`; lane `ashift9-ro`, a
  `readonly=on` NVMe drive, is that path end to end). OpenZFS ignores flush errors (`zio.c:1731-1743`); agnos fails
  the commit (an open operator question). A device with NO cache to flush is not an error: the block layer answers 0
  for it — virtio without `VIRTIO_BLK_F_FLUSH`, the ramdisk, and since the B2 review a USB stick whose SYNCHRONIZE
  CACHE draws ILLEGAL REQUEST / INVALID COMMAND OPERATION CODE (`msc_blk_flush` records it in row +86 and stops
  issuing the command — OpenZFS's `vdev_nowritecache`, Linux's `sd_sync_cache`). Before that fix this bullet's claim
  was false for USB: `msc_blk_flush` returned -1 for such a stick, and every commit on it would have failed.
- **A write-protected device is refused at the gate** (`device is write-protected`, `blk_readonly_on`: virtio
  `VIRTIO_BLK_F_RO`, NVMe NSATTR bit 0). AHCI and USB report none; QEMU 11.1's nvme does not set NSATTR for a
  `readonly=on` drive either, so there the first commit fails instead (the bullet above) — safe, only later.
- **`zfs_txg` now moves; T0 does not.** Every rule keyed on the mount txg — design § c.2's deferral (FREEs in logs with
  txg ≥ T0 − 2, FREEs appended to an SM after T0) — reads `zfs_t0`, set once by `zfs_wmount`. Before B2 the two were
  the same number, and a metaslab loaded after a commit would have stopped deferring T0 − 2's frees.
- **All four labels must verify, and name this vdev, for the pool to be rw** (`zfs_lbl_ok`, recorded by
  `zfs_label_load`; refused `no valid label of this vdev at L<n>`): L2/L3 sit at psize − 512 / − 256 KiB, so a grown
  partition or a cut image would put the slot writes outside any label. psize is the partition rounded DOWN to 256
  KiB (`zfs_try`), so a partition up to 255 sectors longer than the pool still has its labels in place (lane
  `ashift9-grown`); 256 KiB longer moves L2 onto the old L3 — which verifies, its eck verifier being only the offset —
  and L3 onto nothing (refused). Each label must also carry the chosen label's `pool_guid` and leaf `guid`
  (`vdev_validate`'s identity test), so an intact label of another pool at a computed L2/L3 offset is not taken for
  this one's.
- **The timestamp is `max(ntp_now(), previous)`** (WPA § 2.1, a SHOULD); under `ZFS_WRITE_OPS` it is deterministic —
  `max(the mounted uberblock's timestamp + the ops started, previous)` — so the op list's images are
  byte-reproducible: the torn / grown / AHCI / USB lanes must write a pool byte-identical to the NVMe lane's. The
  host audit's h3 requires every new uberblock's timestamp to be at least the pristine best's and non-decreasing in
  txg order.
- On a read-only pool the op list must be REFUSED (`zfs-wtest: ub-only commit ok refused (pool read-only)`), not
  skipped: the refused lanes of `zfs-write-smoke.sh` exercise that path and must stay byte-identical.
- **The op list runs only on a fixture pool** (name `agnos*`, the fixture recipe's; anything else prints
  `zfs-wtest: skipped (pool <name> is not a fixture pool)` and is not touched), because it runs on every boot of a
  `ZFS_WRITE_OPS` image. The design's marker skip (§ i.1) needs a file the list creates: it arrives with B6's create.

## 10. The dataset COW (1.57.12 bite B4, `kernel/core/zfs_write.cyr` § "B4")

`zfs_commit` turns dirty DATASET blocks into a new `ds_bp` (the dataset phase) before it plans the MOS; the design's
§ d / § e B4 notes have the walk. What the code alone hides:

- **A POLICY refusal happens when the operation is DIRTIED, never at the commit.** `zfs_wblk` judges the BP each
  dirtied dataset block replaces (`zfs_wd_okbp`): an encrypted predecessor would need keys, and a commit that met one
  would have to fail the whole pool read-only — (B7) a gang, dedup or possibly-cloned one (`block_cloning` active) is
  no longer refused: the commit DEFERS its kill to `free_bpobj` (§ 13); (B9) nor a snapshot-owned one: its kill goes to
  the head's deadlist (§ 15), its append counted when the block is dirtied.
  The blocks the COMMIT dirties are judged ahead too (B4 review): `zfs_wds_open`
  runs `zfs_wd_okbp` on every user / group / project accounting ZAP's top BPs and refuses a MICROZAP of more than one
  block; every operation reserves (`zfs_wd_urs1` → `zfs_wz_urs`, B8) the delta-table entries and what its dnode's
  accounting can add — a microzap's new keys from its room, a microzap without room UPGRADED there and then, a fat ZAP's
  header and key leaves dirtied now plus a leaf and a table block per new key (`zfs_wz_mres`), a fat ZAP whose pointer
  table is already external refused (§ 14). The space and quota predicates
  run there too (`zfs_wd_space`, against `zfs_wroom` — the normal class less the slop AND the boot's deferred frees,
  `dsl_pool_unreserved_space`'s rule; agnos defers every free for the whole boot). A refused operation leaves the dirty
  set and the reservations EXACTLY as they were (`zfs_dirty_trunc`: entries popped newest first — each the head of its
  hash chain and the end of its arena, because only a commit ever grows a slot). What can still fail inside a commit is
  not policy: an I/O error, a metadata run that finds no contiguous space (no gang fallback), the dirty arenas filling
  with what the commit itself dirties (B5's thresholds must leave that room) — design § k.37.
- **The reader's dataset slot is the T − 1 view until the publish.** `zfs_ds(di) + 0` (the meta-dnode copy every read
  goes through) is replaced at `zfs_wc_pub` with the new objset's; until then the user-accounting step diffs every
  dirty dnode block against it to find the dnodes that changed (OpenZFS's "synced dnodes"), so nothing may refresh it
  earlier.
- **One dataset's born − killed is applied once per txg**, not per block (`zfs_wd_dsdelta`): every term is linear and
  `parent_delta` telescopes, so the dsl_dataset / dsl_dir fields equal OpenZFS's block-by-block result. Through a
  reservation (`agnoswr/resv`) the change can stop at the dataset (refreservation) or its dir (`dd_reserved`): the
  root's used then does not move while the pool's allocated bytes do — which is correct, and which the write oracle's
  allocated identity has to (and since B4 does) subtract.
- **Log T is encoded from a SORTED COPY of the extent list** (`ZWA_XLS`): the k.25 re-plan undoes the chain's extents
  by position (`zfs_wxl_undo` to a mark), so the list itself must keep allocation order. A re-plan restores every
  MOS chain block's bytes, the rootbp and the MOS's space from the snapshot taken before step (2) — everything steps
  (2)-(4) change lives there (a chain block's object is the log object or the meta-dnode, whose dnodes sit in chain
  blocks).
- **U = T is preset at the first commit after the mount** for every metaslab with a space map and U 0 (k.24): a txg
  can no longer be planned twice (its dataset blocks are already written), so the U rule has to be met in one round.
- The host recount (`scripts/smoke/lib/zfs-uacct-check.py`, the audit's h7) is the oracle for `dn_used`,
  `ds_referenced` and `ds_unique_bytes` against their blocks, every dsl_dir's breakdown (Σ == used, CHILD /
  CHILD_RSRV from the child dirs, REFRSRV == max(0, refreservation − unique), HEAD == referenced), and the user / group /
  project ZAPs — zdb checks none of them. The REFRSRV split also has an OpenZFS-side judge: the verify's B-acct holds
  `usedbyrefreservation` to max(0, refreservation − `written`), which OpenZFS derives from the deadlist (B4 review:
  every other identity summed a wrong split back together, so only a `zfs destroy` of that very dataset saw it).

## 11. File data (1.57.12 bite B5, `kernel/core/zfs_write.cyr` § "B5")

`write`#1 on a writable fd and `AO_TRUNC` at open go through the B4 dataset phase; the design's § h B5 record has the
rules (OpenZFS's block-size, level, hole and SA behaviour, rule for rule). What the code alone hides:

- **A ZFS fd carries the object's GENERATION, never its size** (`VFS_ZFS_FILE` payload[1] = `ZPL_GEN` | `ZK_FDW`). Every
  read, write and `SEEK_END` re-reads the dnode, compares `ZPL_GEN` (D11 — once B7 frees objects, a reused object number
  fails the fd -1) and takes the size from the SA (`zfs_fd_size`; `lseek`#58 takes `fs_lock` for it). A cached size went
  stale the moment another fd wrote; ext2's fd keeps that defect. `zfs_ds_open` records the `ZPL_GEN` / `ZPL_CTIME` /
  `ZPL_FLAGS` attribute numbers at slot `+992 / +1000 / +1008` (the dataset name is capped at 136 bytes for it — it is
  only printed).
- **Policy A: every `write`#1 and every truncating open COMMITS inside the syscall** — under `fs_lock`, IF=0, ≈ 0.6 s a
  txg on QEMU/KVM (design § k.8; that figure had the op list's own console inside it — B11's measure is in § 17) — and
  (until B11, § 17: policy B continues the open txg for a write through an fd; a truncation still commits) starts from an EMPTY dirty set (`zfs_wf_begin` refuses one that is not: one op
  per txg until B11's coalescing). A write the open txg cannot hold is cut into several txgs, each durable: at
  `ZWF_TXGBLK` (512) dirty blocks (k.28's log bound and the extent list), at the arenas less `ZWF_MRSV` (512 KiB of
  metadata kept for what the commit dirties itself, k.37), and where the space predicates answer ERESTART (in-flight
  bytes, k.36). A predicate refusing with nothing in flight ends the write SHORT.
- **`fs_lock` is held for ONE commit, never for a whole request** (B5 review). A write or truncation of several txgs
  releases and retakes the lock between them (`zfs_wf_yield`) and re-checks what another CPU may have changed: a write
  its fd (tag, object, `ZPL_GEN`, writable bit, the position it left) — else it ends SHORT; a truncation the object's
  `ZPL_GEN`. A truncating open RESERVES its fd slot (tagged read-only before the first txg, cleared on failure) because
  an untagged slot would be another open's to take while the lock is out. The calling CPU stays IF=0 throughout, as in
  every syscall: the release bounds every OTHER CPU's wait, not this one's (design § k.48).
- **Nothing may fail INSIDE a commit that an op could have refused** (B5 review: each of these failed the commit, the
  pool then read-only until reboot). The extent list (`ZWK_MAXXL`) is measured as a truncation lists its kills — every
  dirty block and `ZWF_CRSV` more the commit may add count 6 extents, every killed DVA one (`zfs_wf_xfit`), so a big
  truncation is cut into txgs — and log T's block is sized from the extents ALREADY recorded plus 6 per MOS block still
  to finalise (`zfs_wc_plan`; ≤ 98,320 B by `ZWK_MAXXL`). User data is charged before it is dirtied — a grown block 0
  the write starts past and a truncation's boundary block included (the op list's plan line prints `udata` ≤
  `charged`). The space rule is the ALLOCATOR's (`zfs_wroom` = min(OpenZFS's figure, `zfs_wphys`: the metaslabs with a
  space map less `zfs_w_defer` less `ZWK_MDRES`, one commit's worst-case metadata), and a txg opens only while
  `ZWK_MDRES` is left (`zfs_wf_begin`). OpenZFS's own quota model on `dd_used` keeps OpenZFS's figure (`zfs_wroomz`):
  `dd_used` counts reservations no metaslab holds. A truncation judges every block it will free BEFORE its first txg
  (`zfs_wf_okscan`), so a refusal by name changes nothing.
- **A free in open context is a DEFERRED kill.** No extent may exist outside a commit (the commit's re-plan and failure
  paths rely on it), so a truncation turns each freed L0 BP into its birth-T hole in the parent's dirty copy and parks
  the old BP on the txg's kill list — 144-byte entries in the data arena's UPPER half (`ZWF_FRL`; `zfs_dx_lim()` gives a
  truncation txg only the lower 2 MiB for data) — which `zfs_wd_phase` kills first, as `free_blocks` does at the sync.
  Each freed BP is judged killable when it is listed (`zfs_wd_okbp`): `gang/gang.bin` was refused by name until B7,
  whose `free_bpobj` deferral takes its gang blocks.
- **A partially written block is READ, a wholly written one is not** (`zfs_wblk_nr`): so a zstd (no decompressor) or
  skein / edonr / blake3 (no checksum) block can be overwritten whole but never in part — the refusal is named.
- **Holes keep their births.** A re-materialised hole indirect of birth B gives its children holes of birth B
  (`zfs_wblk`, `dbuf_handle_indirect_hole`); a freed block's hole carries T; an all-zero block of a compressing dataset
  becomes a birth-T hole when it replaced a born block. zdb checks none of it: the host's h8
  (`scripts/smoke/lib/zfs-hole-check.py`, run by the audit's `--space`, so by the verify's H too) compares every hole of
  every changed object with the pristine image; with the op list (zfs-write-smoke) also each writer-punched hole's
  LSIZE and that no hole got a birth where nothing was ever freed.
- **User / group / project quotas are enforced** (B5 review): before each txg, as OpenZFS before each chunk
  (`zfs_wd_idq`: the owner's `%llx` key in the master node's `userquota@` / `groupquota@` / `projectquota@` ZAP, else
  its `default…quota` entry, against the COMMITTED user / group / project-used ZAP) — EDQUOT, a short write.

## 12. Creates (1.57.12 bite B6, `kernel/core/zfs_write.cyr` § "B6")

`open`#7's `AO_CREAT`, `mkdir`#9 and `symlink`#63 make a new znode in a microzap directory in ONE txg each (`zfs_wcreate`
→ `zfs_wc1` → `zfs_commit`); the design's § f.1–f.3 "(B6, as built)" notes and § h B6 record have the rules. What the code
alone hides:

- **The new object is accounted by the commit's existing diff, not by a create path.** `zfs_wd_uacct` compares every
  dirty dnode block with T − 1's; a slot that was all zero and is now a dnode has no old side, so the new object gets
  `+1` in `obj-<uid/gid/projid>` and `512 + dn_used` bytes like any synced dnode — the create only RESERVES what that will
  add (12 delta entries, up to 4 new keys). A new dnode starts with `dn_flags` 0: USED_BYTES comes with its first born
  block (`zfs_wdn_used`), the accounted bits from the diff — FreeBSD's empty files and symlinks carry exactly `0xa`.
- **Object numbers are FIRST FIT and are reused.** `zfs_wc_slot` takes the lowest free slot of the meta-dnode (OpenZFS's
  128-object chunk cursor leaves every fixture dataset full of free slots and hole blocks); a block past `dn_maxblkid`
  grows the meta-dnode. Reuse is why every ZFS fd carries `ZPL_GEN` and a create stamps `GEN = T` (D11): once B7 frees
  objects, a number can come back within a boot.
- **What the bonus looks like is the DATASET's choice, not agnos's.** The attribute numbers are read by name from that
  dataset's REGISTRY at each create (`zfs_wc_regs`; an attribute it lacks is refused by name), and the layout is matched
  against its LAYOUTS (`zfs_wc_layout`) — since B8 a missing one is REGISTERED in the create's txg as
  `sa_add_layout_entry` does (number = the LAYOUTS ZAP's count + 2, a decimal key, a u16 array; design k.79). Every
  fixture CHILD dataset but `agnostank/custom` holds only the file / directory layout (design § k.2): a symlink there
  is the dataset's first, and adds the symlink layout. Files and directories get PROJID (+ `ZFS_PROJID`) exactly
  where the dataset has project accounting on disk (`dse +104` value 4), a symlink never — and where FreeBSD would grow
  a smaller objset_phys IN MEMORY at open (2 KiB on a `project_quota` pool: `dmu_objset_open_impl`), which makes its
  creates carry PROJID too, a create is REFUSED (value 64; design § f.1, k.60). The trivial ACL is
  `acl_trivial_access_masks`' (owner base `0x1E0198`, w = `0x6` in every class) and the flags follow the mode, which is
  fixed (`0100644` / `040755` / `0120755`: the ABI carries no mode); a mode whose ACL would need `zfs_acl_chmod`'s
  allow0 / deny entries is refused (`zfs_wc_trivok`). `zfs-sa-check.py` holds every new object to a FreeBSD-made twin
  of the same kind in the same dataset — layout number, attribute array, flags, ACL bytes — and to an ACL it derives
  from OpenZFS's own C, not from agnos's helper.
- **The final component is never followed** — not by `AO_CREAT` either: a name that resolves at all (a dangling
  symlink, a graft) EXISTS, and `zfs_open` sends EVERY failed `AO_CREAT` lookup to `zfs_wcreate`, which creates only
  where its own no-follow lookup says absent and otherwise refuses by name. A parent that is a virtual directory (no
  dataset holds it) is refused, and so is a microzap ALREADY past 128 KiB (`large_microzap`), judged on the parent's
  dnode BEFORE the name lookup: the reader's 128 KiB block cache cannot load such a block at all (so even reads there
  fail — design k.57). Since B8 a microzap parent is UPGRADED by a 50+-byte name, a full 128 KiB block or too many
  same-hash names, and a fat parent takes the name (§ 14).
- **A refused syscall says why on the console.** `open`#7 with a write flag, `mkdir`#9, `symlink`#63 and `write`#1 on
  the ZFS mount clear `zfs_wr_lit` before the verb and, on -1, print `zfs: <verb> refused (<why>)` (`zfs_wr_say`, under
  `fs_lock` — the path is user bytes and is not printed). The ring-3 gate holds zfsx's 14 refusals to that list by
  name and in order (design k.58).
- **Every refusal is decided before the commit** (§ 11's rule): the dirty set the create built is dropped
  (`zfs_wf_drop`) and nothing is allocated; only an I/O error or a commit-internal shortage can still fail the commit.

## 13. Removals and renames (1.57.12 bite B7, `kernel/core/zfs_write.cyr` § "B7")

`unlink`#30, `rmdir`#10, `rename`#31 and `link`#32 edit microzap directories in ONE txg each (`zfs_wunlink` /
`zfs_wrmdir` / `zfs_wrename` / `zfs_wlink` → `zfs_commit`); the design's § e.2 / f.2–f.5 "(B7, as built)" notes and § h
B7 record have the rules. What the code alone hides:

- **A freed object's blocks are killed through the TRUNCATION's kill list, not by dirtying them.** `zfs_wu_free` walks
  the committed tree read-only (every level, children first, the spill last) and queues each BP with `ZWU_FREED`, then
  zeroes the dnode's slots; `zfs_wd_phase` kills the queue inside the commit with no dnode to charge (`dn` 0). The
  user accounting needs no removal path: `zfs_wd_uacct`'s diff sees a dnode that became a zeroed slot — an old side
  and no new one — exactly OpenZFS's `DN_ID_OLD_EXIST` without `NEW_EXIST`. The same kill list bounds it: an object whose
  frees (and DVAs — `zfs_wf_xfit`) do not fit one txg goes the LAZY way instead (links 0 and the DELETE_QUEUE, design
  § f.5), as does one holding an extended-attribute directory; nothing ever splits a free across txgs.
- **Every kill decides "free or defer" in ONE place, `zfs_wd_defer`.** A gang or dedup block — or any block while
  `block_cloning` / `fast_dedup` is active — is appended to the pool's `free_bpobj` (checksum zeroed unless dedup, fill
  0) and charged to `$FREE` once per txg (`zfs_wfb_charge`, before the MOS phase plans): the dataset side of the kill
  is unchanged, so `$FREE` and the root's `CHILD` carry what is still allocated until OpenZFS's async destroy frees it
  (`zpool get freeing`). The MOS's own kills never defer — a MOS gang still fails its commit by name (design k.27).
- **Object numbers come back, and the fd is what notices.** First fit (§ 12) takes a freed number in the next create;
  every ZFS fd — files since B5, `AO_DIRECTORY` fds since B7 — carries the object's `ZPL_GEN` and answers -1 once the
  object is gone, on the DELETE_QUEUE (links 0), or another object with that number (D11). ONE rule decides it,
  `zfs_fd_live` (B7 review: a directory fd and a truncation's between-txg re-check tested the generation alone, so a
  directory an `rmdir` put on the DELETE_QUEUE still listed) — `zfs_fd_size`, `zfs_getdents` and `zfs_wtrunc` call it.
- **A NEW name is judged by its BYTES, wherever it comes from** (`zfs_wname`: a create's, a link's, a rename's target —
  B7 review: link and rename checked none). No NUL: the microzap chunk keeps a C string, so `"e04\0x"` would read as
  `e04` beside the real one (OpenZFS's `mzap_open` VERIFYs on two equal hash / cd keys) and a name starting with NUL as a
  FREE chunk; on a `utf8only` dataset no byte ≥ 128 (no UTF-8 validation here; FreeBSD answers EILSEQ for an invalid
  name, so it could never be looked up or removed there).
- **Every path operand is read ONCE** (`zfs_upath`, `ZR_UP`, B7 review): `open`#7 and the write verbs copy the caller's
  path (ring-3 memory, ≤ 1,023 bytes — the resolver's bound) into the reader's area before any check or lookup, so a
  second thread rewriting the buffer cannot make the name kept differ from the name checked and looked up (a `..` or a
  `/` entry); everything after works on that copy, under `fs_lock`.
- **PARENT is written on every link and rename and never repaired.** `link A/f B/g` points f's `PARENT` at B; unlinking
  `B/g` leaves it there (FreeBSD's own state — zdb `-ddddd` calls such an object "possibly leaked": the verify's A5
  tolerates exactly the ones `zfs-expect.py --leakok` predicts, design k.15). A rename's cycle check walks those
  `PARENT`s up from the target directory (committed state, before anything is dirtied).
- **Grafts and virtual directories are judged by the RESOLVER's canonical path** (`zfs_res_cl`, ZR_PC): a name that
  resolves to another dataset or to a graft, the dataset's own root, a directory with a dataset grafted below it, and a
  virtual parent are refused by name — never touched in the parent dataset that a graft shadows.
- **A txg that takes a metaslab's weight below its stored space map histogram LOWERS that histogram** (design k.68;
  found by B7's gate, but every commit since B3b allocates). OpenZFS's stored histogram never claims more than a load
  finds — it allocates only in loaded metaslabs and rewrites their histograms at every sync — and `metaslab_load_impl`
  ASSERTs it; agnos allocates from its bitmaps and logs T only, so its commit keeps the rule itself: after step (1)
  `zfs_wh_plan` compares each metaslab T allocated in (the exact histogram of its allocated bitmap) with the stored
  one, and only the ones whose weight dropped get their space map dnode into the chain (a dnode block step (1) already
  wrote is DEMOTED: its DVAs taken back out of T); `zfs_wh_check` adds a metaslab the chain's own allocations dropped
  (re-planning the chain when its space map dnode was not in it), and `zfs_wh_fill` writes the exact histograms after
  the last allocation. A weight is never raised (a read-only zdb loads the space map without the logs, and the stored
  histogram bounds that too). Most txgs dirty nothing for it: a weight drops when a largest segment crosses a power of
  two.

## 14. Fat ZAPs (1.57.12 bite B8, `kernel/core/zfs_wenc.cyr` § "B8: the FAT ZAP", `zfs_write.cyr` § "B8: ZAPs of every shape")

Directories of any size, the user / group / project-used ZAPs, SA LAYOUTS, the DELETE_QUEUE and the MOS log ZAP all go
through ONE path: `zfs_wz_open` (objset, object, its dirty dnode) + `zfs_wz_get` / `zfs_wz_op`, micro or fat by block
0; the design's § f.2 "(B8, as built)" note and § h B8 record have the rules. What the code alone hides:

- **The fat-ZAP code is OpenZFS 2.4.2's, and it does not know where its blocks live.** `zfs_zl_*` / `zfs_zf_*` reach
  blocks only through four resolvers — `zfs_zf_blk(k)` (dirtied; past `dn_maxblkid` the object grows, levels and
  all), `zfs_zf_rblk(k)` (dirty-first, READ ONLY: the reader's cache slot is good until the next block access, so no
  caller holds an `rblk` address across another block access), `zfs_zf_kill(k, n)` (`dmu_free_range` of a range: all
  of it or a failure) and `zfs_zf_gok()` (may the pointer table grow here?) — which the writer defines over the dirty
  set and `tests/zfscodec` over a flat image: check.sh gate 37 runs the SAME code against blocks OpenZFS wrote, byte
  for byte. The 2.4 details that make the bytes match are deliberate: an array chain freed IN ORDER, an entry's
  value freed before its name, a split rehashing in chunk order.
- **A freed ZAP block goes through the KILL LIST (B8 review).** `zap_table_grow`'s last call frees the old pointer
  table (`dmu_free_range`): a block already dirty in the txg is zeroed in place (the commit turns an all-zero metadata
  block into a hole of birth T, killing its predecessor — design § d.1), every other one's BP is killed through B5's
  kill list (a hole of birth T in the dirtied L1, the kill inside the commit) — no metadata-arena slot per block, so a
  1,024-block table still switches in one txg (design k.88). The free comes BEFORE the header is written: a failure
  leaves the doubling where it was. The MOS has no such path: a growth of either kind in a MOS ZAP is refused before
  anything changes (`zfs_zf_gok`), and the write gate refuses a log ZAP whose table is external or mid-grow.
- **No failure inside a ZAP op is swallowed (B8 review).** OpenZFS ignores `zap_put_leaf_maybe_grow_ptrtbl`'s grow
  error; agnos ignores only a refusal that changed nothing (`ZZ_NOSPC`, `ZZ_NOGROW`) — any other fails the op and its
  txg is dropped (a swallowed failed switch would have committed `zt_blks_copied == zt_numblks` with `zt_nextblk`
  set, from which OpenZFS's next grow copies a leaf over the new table).
- **An emptied leaf stays.** `zap_shrink` is not built (design k.76); h9 counts empty leaves, OpenZFS reads them.
- **Accounting ZAPs are shaped at ADMISSION, never in the commit.** The commit adds and removes accounting keys inside
  blocks the op already dirtied; a microzap that cannot take the op's new keys is upgraded when the op is admitted
  (design k.78), a fat one's header and key leaves are dirtied then and its splits reserved (`zfs_wz_mres`, part of
  `zfs_wf_mfit`'s budget), and one whose table is external is refused (k.77). (B8 review) A shape the commit's
  `zap_increment` would refuse — a normalised microzap, a fat one with `zap_flags` or an odd block size — is refused
  when the dataset is opened (`zfs_wds_open`), never inside the commit (design k.89); the boot's `zfs-wb3: uafat`
  selftest drives the commit's own fat ADD in memory (splits, a special dnode's level, the reservation — k.90).
- **The salt.** Production's new-directory salt is UNPREDICTABLE (RDRAND mixed with the objset, object and txg — B8
  review, design k.88), as OpenZFS's address-derived one is, so no writer can choose names that share a hash prefix.
  The `ZFS_WRITE_OPS` build alone keeps the derived salt (byte-reproducible images) and the knob `zfs_wc_fsalt`, which
  gives the op list's `b8/` a fixed salt so it can choose names that drive the pointer table external, through a
  doubling and a mid-grow (design k.75): by size alone that takes ≈ 10^5 names.
- **Names to 255 bytes everywhere.** The B7 operand copies hold 256 bytes each (`zfs_wu_nm`); the create's name buffer
  too.

## 15. Snapshotted datasets (1.57.12 bite B9, `kernel/core/zfs_write.cyr` § "B9")

A head with snapshots — and a clone without a livelist — is written; the design's § e.2 "(B9, as built)" has the
rules. What the code alone hides:

- **A block a snapshot owns is NEVER freed.** `zfs_wd_kill` tests branch B first: birth (`BP_GET_BIRTH`) at or before
  `ds_prev_snap_txg` — an embedded BP too, a gang / dedup / cloned one too (`free_bpobj`'s deferral is branch A's) —
  appends the BP to the head's DEADLIST entry for that birth. Freeing it instead looks right to everything that reads
  the head; the snapshot's data is gone the first time the space is reused, and OpenZFS's next destroy of the
  snapshot frees it twice. The oracle for it is outside the head: the verify's B-snap (every snapshot's own tree ==
  the pristine one), D-destroy + D-scrub (OpenZFS processes the deadlists), h6's `owned_allocated` (every block of
  every snapshot, every deadlisted BP allocated after the replay).
- **The deadlist entries are read from the COMMITTED deadlist once per txg** (`zfs_wdl_load` into `ZWA_DLE`): nothing
  agnos does adds or removes a key, so the only thing that differs inside a txg is an entry it MATERIALISED from the
  shared `empty_bpobj` (a new MOS bpobj, the microzap value and `features_for_write`'s `com.delphix:empty_bpobj` − 1,
  in place) — kept in the table. The materialisation is the only MOS object a dataset phase creates
  (`zfs_wmos_free` there, log T's after it: the scan is dirty-first, so they never collide).
- **`ds_unique_bytes` and the `dsl_dir`s move by born − branch A only**; a branch-B kill moves the dataset's referenced
  bytes, the head dir's breakdown HEAD → SNAP (blocks born after `dd_origin_txg`: always for a non-clone, never for a
  clone's origin blocks) and the previous snapshot's `ds_unique_bytes` (when the head is its next). The snapshot side
  of each open dataset (`ZWA_DSB`, indexed like `ZWA_DSX`) carries the sums; `zfs_wd_dsdelta` applies them once.
- **A deadlist append is metadata the commit dirties**, budgeted like `free_bpobj`'s (k.70) — and since the B9 review
  every load and every refusal of a deadlist is an OP's, never the commit's (design k.99 / k.100): each snapshot-owned
  kill is counted per entry when its block is dirtied or its kill listed (`zfs_wdl_q`), the commit's own COWs of the
  accounting microzaps when the dataset is opened (`zfs_wds_open`), and the first count of an entry naming the
  `empty_bpobj` judges its materialisation (`zfs_wdl_matok`). A write or a truncation PREDICTS each block's whole path
  before dirtying it (`zfs_wdl_path`: no reserve) and ends its txg where the next block does not fit; a truncation
  resolves every snapshot-owned block's entry before its first txg (`zfs_wf_okscan`, `zfs_wf_dlscan` — which also
  refuses, before txg 1 commits, one whose later txgs might not hold their first step). The op list's plan line
  `dlx=` counts the appends no admission counted: 0 on every txg (the write smoke holds it).
- **The arena bounds a path's intervals.** Each counted entry dirties at least one 128 KiB bpobj block; a fresh txg's
  path (the meta-dnode's five indirects, the dnode block, the objset, the file's indirects) already holds ≈ 0.8 MB
  (2 levels) / 0.94 MB (3 levels) of the 1.375 MB an op may use — so about four intervals on one block's path fit a
  2-level file and not a 3-level one (refused by name, `one block does not fit a txg: …`).
- **Branch B needs `ds_prev_snap_txg` ≥ TXG_INITIAL (4)**, whatever object `ds_prev_snap_obj` names: `$ORIGIN@$ORIGIN`
  is born in txg 1 and every head attached to it — created or upgraded — carries that 1 (k.101), so the gate reads the
  deadlist exactly when a kill can be snapshot-owned.
- **Refused by name:** a clone WITH a livelist (its ALLOC / FREE records are not built), a deadlist that is neither a
  DEADLIST ZAP nor the old BPOBJ, the `empty_bpobj`'s last reference and a materialisation in a fat deadlist ZAP (both
  fat-ZAP edits: B8's code is in the tree since the merge, not yet wired to them — design k.93), a txg whose deadlists hold more than 256 keys (`ZWA_DLE` keeps every key of each loaded
  deadlist: a head or clone with 256+ snapshot intervals — k.104), a snapshot-owned block born before every entry
  (OpenZFS's `zfs_panic_recover`), a block whose path's deadlist blocks no txg holds. Bookmarks stay refused at the gate
  (their FBN accounting, `dsl_bookmark_block_killed`).

## 16. Log hygiene, the drain and MOS gangs (1.57.12 bite B10, `kernel/core/zfs_write.cyr` § "B10")

Each txg leaves a log space map until every metaslab's unflushed txg U has passed it; B10 bounds them exactly as
OpenZFS does (design § c.5, D10 (a)). What the code alone hides:

- **The flush's delta is taken before anything of T is allocated or freed.** `zfs_wl_plan` runs first in
  `zfs_commit1` — before the dataset phase — as `spa_flush_metaslabs` runs before `vdev_sync` writes T's entries: the
  ALLOCATED (true-state) bitmap against the space map ALONE (replayed into `ZWA_FSB`, no third resident bitmap), its
  net equal to the log scan's (`msent +56`, checked). A delta taken later would put T's own ALLOCs (the COW of this very
  space map's block, among others) both in the space map and in log T — "overlapping" at OpenZFS's next writable import.
- **U = T for every flushed or bumped metaslab, and only then are logs destroyed.** The least U after the walk decides
  which logs go (`zfs_wl_kill_logs`, in `zfs_wc_plan` once log T's object is chosen — a slot freed in T is not reused in
  T). A destroyed log a U still names is the import's ENOENT; a flush whose U did not move is replayed twice (the host
  replay h6 holds both: every debug txg of a space map ≤ its U, no log older than the least U).
- **How many flush: `spa_estimate_metaslabs_to_flush` with `zfs_unflushed_log_txg_max` = `ZWL_TXGMAX` 14, and every
  metaslab whose U is 14 txgs old** — two below the design's bound of 16, because a flush is a heuristic that can wait:
  one whose space-map blocks the metadata arena cannot hold beside every reservation an admission counts
  (`zfs_wf_mfit` — fat-ZAP splits, the B9 deadlists, `ZWF_MRSV`) skips to a later txg, and each such txg leaves one
  more log. What destroying EVERY live log takes (a MOS dnode block each distinct one, their blocks' DVAs as FREE
  extents) is reserved before any U moves; a txg that cannot hold it moves none (`skip=3`), so a flush never strands a
  log older than every U (design k.115).
- **Hygiene has its own room (B10 review, design k.119).** A txg its admissions filled to a bound — a long truncation,
  a k.63 drain, a run of deferred kills — used to leave no room for even one flush: `skip=1` with nothing flushed, one
  more log every txg for the whole run, and at `ZWK_MAXLOG` every commit refused for the rest of the boot. Since the
  review the metadata arena is 384 KiB larger (`ZWL_HAR`; `ZWA_CMP` follows it to `0x640000`, the bitmaps moved to
  `0x8C0000`) and NO admission reaches that part (`zfs_wf_alim`: every admission's limit is the pre-review one, so no
  op and no pinned txg count changes); only the commit's plan — the first flush, every live log's destruction — sees
  it, beside what an op dirties past its last admission check. The extent list has no such slack, so there every
  admission holds back the next txg's exact need (`zfs_wl_hres` at each publish and the rw mount: every live log's
  destruction and the FIRST flush the plan will try, measured by a dry `zfs_wl_flush` — nothing of that txg is
  allocated or freed before its commit, so the delta is already the one it will append; `zfs_wf_xfit`). The log limit
  is judged after the plan: a commit at `ZWK_MAXLOG` runs when its hygiene destroys a log and fails by name before its
  uberblock when it destroys none; only a full ghost table refuses it up front. The destroy's backstop is a named
  commit failure, never a log left below the least U (k.121).
- **A destroyed log's FREEs stay deferred while its txg is inside the deferral window: it becomes a GHOST**
  (`ZWA_GHO`: its txg, its FREE bytes, the dnode bytes that reach its block), which `zfs_ms_load` and `zfs_wscan_logs`
  keep reading. B1's rule "a FREE appended to a space map after T0 is deferred" is gone: a range allocated and freed
  between two flushes nets to zero and is in no append (design k.108). Since the B10 / B11 merge (design k.133 (a)) the
  window is B11's (§ 17): a ghost is made only for a log whose txg is ≥ `zfs_wdef_lo` when its destroying txg D runs
  (L ∈ {D − 2, D − 1}), and `zfs_wdef_rel` releases its FREEs with its txg's and RETIRES it — at the latest at D + 1's
  publish, while its blocks (freed in D) are released only at D + 2's, so every walk of it reads intact blocks. The
  table holds at most the window's logs (3, the mount's T0 − 2 .. T0); B10 alone kept every ghost for the boot and
  stopped hygiene at `ZWL_MAXGHO` (1,024) after ≈ 2,000 txgs (k.122). zfs-write-smoke holds every hygiene line to
  ≤ 3 ghosts and the op list's `ghost logs:` line to made = retired + alive; agnos9's last null txg flushes every
  dirty metaslab (`zfs_wt_flall`), so ghosts are made and retired on disk there.
- **The flushed histogram is the exact one of the pre-T state** (`zfs_wh_exact`): what the read-only load of the space
  map alone sees, and never above the writable load of SM + log T; T's own allocations may still LOWER it (k.68's
  `zfs_wh_need`, for `zfs_wh_plan` and `zfs_wh_check`, reads the stored histogram DIRTY-FIRST since B10).
- **The writer area is 10 MiB since B10** (five 2 MiB runs): `ZWA_GHO` 256 KiB at 8 MiB, `ZWA_FSB` 512 KiB at 8.25 MiB;
  since the B10 review the bitmaps (`ZWA_BM`, 1 MiB) at 8.75 MiB, the metadata arena 2.25 MiB, `ZWA_CMP` at
  `0x640000`; free: `[0x660000, 0x700000)`, `[0x9C0000, END)`.
- **The drain (k.63):** an op that put an object on a DELETE_QUEUE drains it in the txgs after its own (`zfs_wu_end` →
  `zfs_wq_obj`, fs_lock released between them): whole when its free fits one txg, else its data from the top in bounded
  truncation txgs first (`zfs_wf_trunc1` — zfs_rmnode's `dmu_free_long_range`), then the object and its queue entry. A
  mount drains nothing (G1); an object holding an extended-attribute directory is refused by name and stays queued for
  OpenZFS's next writable mount (zfs_rmnode's purge is not built).
- **A MOS GANG predecessor is freed in its txg, tree and all** (`zfs_wgang`, k.27 decided): OpenZFS drains
  `spa_free_bplist` in the same sync while log_spacemap is active — every header at one allocation unit
  (`vdev_gang_header_asize`), every child. Log T's size bound counts the excess (`zfs_wgang_xs`). A MOS dedup block stays
  refused. No fixture's MOS holds a gang block: the code runs in memory on gang.bin's real tree (`zfs-wb3: gang`).
- **A gang header COPY is verified against DVA[0]'s identity, whichever DVA it is read from** (B10 review, design
  k.120; the reader's `zfs_gang_read` and the writer's `zfs_wgang`): OpenZFS's `zio_checksum_gang_verifier` takes
  `BP_IDENTITY(bp)` — `&blk_dva[0]` — and the physical birth for every copy. Verifying copy d against its own vdev and
  offset made every ditto copy of a gang header unreadable, so a lost DVA[0] header failed the read (and a MOS gang's
  commit) with an intact copy beside it. gang.bin's header has two copies; `zfs-wb3: gang` verifies both against
  DVA[0]'s identity (and shows the second does not verify against its own).

## 17. Policy B, the deferral window and the crash cut (1.57.12 bite B11, `kernel/core/zfs_write.cyr` § "B11")

The engine (§§ 9–16) stays policy-free; B11 is the layer that decides WHEN `zfs_commit` runs (design § b.2 D1 (b), § b.3).

- **A write through an fd leaves its txg OPEN** (`zfs_wp_ref` names the object); the next `write`#1 of the same object
  continues it (`zfs_wf_begin`: its dirty blocks, its in-flight bytes and its user-accounting reservation stay — the
  reservation is per synced dnode, so a second `zfs_wd_urs1` would double it). It commits at `close`#6 of an fd of the
  object, the process's DEATH before it is published (B11 review: `zfs_release_pid` from `proc_death_release` — a
  parent that never reaps cannot hold it; from the timer ISR the commit is OWED to the next B1, `zfs_wp_owed`), the fd
  table's teardown (`proc_destroy_fd_table` — never a commit inside an interrupt handler: owed too), `sync`#12,
  `power_flush`, a threshold (the write could not take its next block whole — the arenas, `ZWF_TXGBLK`, ERESTART), the
  5 s age bound seen at a ZFS entry, and **before any entry that could observe it**. ⚠ The reader never consults the
  dirty set, so "observe" is decided by what a pending txg changes AS THE ABI SEES IT: only its object's content and
  attributes, and the pool's space. So the hooks are `zfs_wp_obs(ref)` in `zfs_fd_read`, lseek's `SEEK_END`,
  `zfs_stat_ref`, `zfs_file_size` (exec), `zfs_open` of it (and every `AO_CREAT` / `AO_TRUNC`), `zfs_wp_flush` in
  `zfs_fill_statfs` and at the top of every mutation verb (they need the dirty set to themselves) and of a write to
  another object. A read of ANOTHER file, `getdents`, `readdir`, `readlink` never commit (only the age bound) — a ZFS →
  ZFS `cp` stays one txg per file (design k.124 (B11)).
- **A continued txg is never dropped.** A write that cannot take its first byte there answers -2: the caller commits
  the pending txg and asks again in a fresh one (`zfs_wf_txflush`). It may grow the file's block 0 (a dirty block 0
  grows with `zfs_dirty_grow`) and its levels by ONE (`dnode_increase_indirection` under children dirtied earlier in
  the txg — what policy A's single write already did); a growth of two or more commits first. A block already charged
  in the txg is not charged again (`ZWD_CHG`), and a block 0 that grows is charged again at its new size — (B11 review)
  BEFORE the growth is applied (`zfs_wf_gsz`), so a -2 never commits a growth charged at the old size.
- **A pending txg is never dropped by ANOTHER op either** (B11 review, design k.131 (a)): a write#1 or truncation of
  several txgs releases `fs_lock` between them, and another CPU's write#1 may leave a pending txg in that gap — the
  entry rule runs again after every yield (`by=yield`), every op that opens a txg of its own commits a pending one
  first (`zfs_wp_own`, `by=begin`), and `zfs_wf_drop` never discards one silently (named, EIO at the owner's close).
- **Deferred frees are released after TXG_DEFER_SIZE = 2 txgs** (`zfs_wdef_rel`, design k.125 (B11)): once txg t is
  durable, the window's low txg `zfs_wdef_lo` becomes t − 1 and every log below it leaves `zfs_w_defer` and the deferred
  bitmap of every resident metaslab (a strict clear — a unit freed by agnos is deferred by exactly one log; a load
  rebuilds the window from the logs ≥ `zfs_wdef_lo`); the mount's own logs (≤ T0) are released by evicting every
  resident metaslab, since OpenZFS at its slop may have reallocated their units. A free of txg T is allocatable from
  txg T + 3 — metaslab_sync_done's rotation — so whatever a txg's partial writes did, its three predecessors are whole:
  OpenZFS's safe rewind window. The read-back (`zfs_wt_rb`, re-running the mount's scan with the live window) holds the
  release's accounting, bit by bit, after every op of the op list.
- **The commit's hold is measured and windowed** (design k.126 (B11)): `kirqw_point` (io.cyr) between the commit's
  device commands and inside the NVMe / AHCI completion polls opens one-instruction interrupt windows on the
  committing CPU once the scheduler is live — never inside an interrupt handler (`apic_in_service`), never on USB
  mass storage (its xHCI ring is the keyboard's) — so that CPU's timer and devices are served every ≥ 20 µs instead of
  once per commit. Since the B10 / B11 merge (design k.133 (b)) the publish's tail — the release's log and ghost
  walks and hygiene's dry flush for the next txg (`zfs_wl_hres`, a metaslab load), which still hold `fs_lock` —
  is inside the hold and its windows too (`zfs_wc_tail`). Other CPUs that want `fs_lock` still wait for the whole
  commit.
- **The crash cut** (`ZFS_WRITE_OPS` only): `/boot/cmdline` on the ESP, `zfs_cut=[CLASS:]N`, runs the cut list and halts
  the machine after N device writes of its last txg (`zfs_wt_cutw` in `zfs_wr`: data · dataset metadata · MOS · MOS
  chain · uberblock slot). OpenZFS must open the txg before it exactly — or, once one copy of the uberblock landed, the
  txg itself (zfs-write-smoke's cut lanes, the audit's `--cut-labels`). Every cut txg runs § 16's hygiene first, so the
  cut lanes also cut a FLUSH mid-way — before its space-map appends (data), after them (MOS chain), or with its
  uberblock landed (ub1 / ub3); the halt prints the cut txg's hygiene line and each lane requires a flush in it (the
  B10 / B11 merge, design k.133 (e)).
- **UTF-8 on a `utf8only` dataset** (`zfs_wname` → `zfs_wenc.cyr` `zfs_u8_valid`, u8_validate's rules): a well-formed
  name is accepted, anything else refused by name with u8_validate's class; a normalised dataset still refuses every
  non-ASCII name (no normalisation tables — and it is read-only at its gate anyway).

## Gates

`scripts/smoke/zfs-smoke.sh` (seven OpenZFS-built pools, exact manifest diff; since 1.57.12 B1 also each lane's
write-gate verdict lines, G1, and the rw lanes' state dump vs `zfs-wms-check.py`), `scripts/smoke/zfs-write-smoke.sh`
(1.57.12 B2: the op list on ashift9 / wr / main — the kernel's lines, its own read-back walk, the host audit h1-h5
with `--same-rootbp`, then ONE `zfs-fixture.sh --verify` guest for phases A-D; ashift9 again torn / on a grown
partition / on AHCI / on usb-storage, each byte-identical to the NVMe result, and on a read-only drive (the error
path); v28 + mirror-a + makefs refused and raidz-0 unmounted, all byte-identical; since B3 / B4 the null txgs and the
dataset COWs, the host replay h6 and recount h7 per rw lane; since B5 the file-data ops — their F lines and the walk
held to the expected manifest, h8 hole births — and OpenZFS's phase B against `zfs-expect.py`'s expected manifest; since
the B5 review every plan line's `udata` ≤ `charged`, the written files' SA stamps (`zfs-sa-check.py`), a short write's
length against the space record (`zfs-room-check.py`), h8's LSIZE / birth-txg rules, and phase C on a child dataset;
since B6 the create ops — their D / F / L lines held to the expected manifest, every new object and changed parent held
to zfs_mknode's values and to a FreeBSD twin (`zfs-sa-check.py`), OpenZFS's own `stat(1)` of each (the verify's
B-stat), and phase C appending to an agnos file and `rmdir`-ing an agnos directory; since B7 the unlink / rmdir / rename /
link ops — `X` lines for every removed name, one namespace model in `zfs-sa-check.py` (every touched object's LINKS /
PARENT / SIZE / times, a freed object's slot, a lazy one's DELETE_QUEUE entry), `free_bpobj` == `$FREE` == the kernel's
`fbpo=` sums (h7), the verify's D-drain: `freeing` back to 0 after OpenZFS's own async destroy, and h6's histogram
rule: no metaslab's space map histogram claims more than the replayed space holds; since B8 fixture RECIPE 7's fat-ZAP
pool `fz` — a new directory's upgrade, splits, an external pointer table doubling across txgs, `dir3000`'s smallest
leaf emptied, 255-byte names, fat accounting ZAPs written and a full one upgraded, the first symlink's new SA layout —
each checkpoint the host model predicts, and h9 (`zfs-fatzap-check.py`: every ZAP's structure, every hash recomputed,
an upgraded microzap's salt kept) on every rw lane; since B9 the snapshotted-dataset ops — agnostank's root @snap1,
wr's snap / clone / snap2 (fixture RECIPE 7: two entries materialised in one txg) and (B9 review, RECIPE 8) edge /
edgec (the four boundary births, block 0 paths reaching four deadlist intervals — four entries materialised in one
txg, a three-level one refused by name — and a truncation refused at its scan) — with each txg's `dl=` / `mat=` held
to the lane and `dlx=0` on every plan line, h6's every-snapshot-block-allocated rule, h7's deadlist recount (each
entry's bpobj, `dl_used`, the empty_bpobj refcount, every snapshot's unique and the dir's SNAP against the deadlists),
and the verify's B-snap, B-snapacct (`zfs destroy -nvpd`'s reclaim == usedbysnapshots / used) and D-scrub after the
destroys; since B10 every commit's hygiene line (flushes, bumps, destroyed logs, ≤ 16 logs alive after every txg, both
of § c.5's flush cases on ashift9 and main, the image's log count == the last line's), the drains (`drain ok`), h6's
hygiene rules (an entry's type under its debug word, no space-map debug txg past its U, no log older than every U),
the room check from the plan lines of destroyed logs, the in-memory `zfs-wb3: flush` / `gang` stages and the verify's
A3y — zdb's own log set held to the host's; since the B10 review no txg that skips its first flush);
since B11 the policy-B ops (8 × 64 KiB through one fd = 8 txgs under A, ONE under B; commit-before-observe,
sync, the age bound, the arena threshold, the release op), every commit's `b11:` line (hold, the longest stretch without
an interrupt window, the bytes released), wr's UTF-8 names, and FOUR CRASH-CUT lanes (`ashift9@cut-data` / `-mos` /
`-ub1` / `-ub3`: the machine halted inside a txg, OpenZFS opening the txg before it exactly — A4's rewinds included —
or, once a copy of its uberblock landed, the txg itself; the audit's `--cut-labels`); since the B10 / B11 merge the ghost bound (k.133 (a): ≤ 3 on every hygiene
line, made = retired + alive, made and retired on disk on ashift9); 21 lanes, 12 OpenZFS-verified),
`scripts/harness/zfs-ring3-test.py`
(+ `tests/zfs/zfsx.cyr`, exec'd from the pool; since B5 it writes a writable dataset, since B6 it creates there — a
symlink too, since the B6 review and fixture RECIPE 5; since B8 in a child dataset with no symlink layout, and names
of 50 and 255 bytes; since B11 it writes under policy B — a cp of 8 × 64 KiB through one fd, a read through another fd
and a stat that must see coalesced writes, sync#12, a file the exit's teardown commits, and the per-CPU tick probe around
a 2 MiB commit — the run's exact final txg proving the coalescing — and the harness holds the kernel's refusal log to its list by
name, the created objects to zfs_mknode's values with the production clock (`zfs-sa-check.py`'s ring-3 form), and has
OpenZFS verify the pool after the run, B-stat / B-acl required), `scripts/check/host-zfs-oracles.sh` (check.sh gate 37: the codec
on the host, mutation-proven). Fixture: `scripts/tool/zfs-fixture.sh` (a FreeBSD 15.1 guest under KVM; cached).
