# 2026-11-06 — open has no create mode, so a private file lands 0644

**Status:** ✅ **RESOLVED in agnos 1.57.18** (2026-11-08, both asks). **`open`#7 `AO_MODE` (`0x4000`)**: bits 32..63 of a3 are a
create's mode, 0..07777, stored as given (agnos has no umask; set-id and sticky kept, Linux's root rules) — applied only
when the call creates, an existing file keeps its mode, a field above 07777 is -1 with nothing made, and an old caller
(no bit) gets today's default (ext2 0644, ZFS 0100644). ext2 writes the i_mode; ZFS the SA MODE plus `zfs_acl_chmod`'s
full ACL (a non-nested mode such as 0604 was refused before); FAT / exFAT check and ignore it, as vfat does. `mkdir`#9 is
unchanged: it has no flags argument and a stale a3, so no clean opt-in exists. **The Related ask — a per-file sync —
is `fsync`#115**: ext2 (write-through) one device flush and no sector; ZFS commits the fd's own object's pending txg and
nothing else; a FAT / exFAT write-back fd writes its buffer and flushes (measured: an ext2 fsync with another ZFS file's
txg pending 0 sectors / 2.2 ms, against `sync`#12's 634 sectors / 26.1 ms). Gates `scripts/smoke/fs-create-mode-smoke.sh`
(debugfs + e2fsck after a crash cut), fssys, exfat-write and zfs-ring3 (zfsx clauses 162–174, OpenZFS verify). The cyrius
peer is filed (`cyrius/docs/development/issues/2026-11-08-agnos-sys-fsync-115-peer.md`).
*(Filed from thoth **0.55.1**, where it has been a standing row on the roadmap's waiting table.)*
**Checked against:** agnos **107ad763** (1.57.17), `ext2_create`; cyrius **6.7.18**, `sys_open(name, namelen, ao_flags)`.
**Severity:** low today, with one user. It becomes real the day `getuid` stops being a stub.

## What happens

`sys_open` carries no mode, and a created file gets the kernel's default. thoth writes its tool pins, session store and session log at 0600 on Linux and macOS, and hoosh and daimon keep credentials and stores the same way. On agnos all of them land at the default, and a consumer cannot ask otherwise.

## The ask

A create mode on `open`, honoured by `ext2_create`, in a way an old caller keeps today's default.

**Related:** `fsync` syncs the whole filesystem, so an atomic store write costs more than it should. A per-file sync would help every store that writes through a temp and a rename.

## What thoth does meanwhile

Nothing it can do. It never claims a mode it cannot enforce, and its config example says so.
