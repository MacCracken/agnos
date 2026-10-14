#!/bin/bash
# sweep-row-timeout: 7200
#   ^ read by scripts/sweep.sh (sweep_row_ceiling; ZFS write design k.134): this smoke ran 81 min alone at the B10/B11
#     merge, over the parallel sweep's 1500 s default row ceiling. 7200 s = one attempt with ~1.5x margin.
# ZFS write smoke (agnos 1.57.12; design docs/development/proposals/2026-10-09-zfs-write.md § i.5) — the writer
# against pools that REAL OpenZFS built, and OpenZFS as the judge of what it wrote.
#
# The kernel is the ZFS_WRITE_OPS op list (core/zfs_write.cyr zfs_wtest), built with ZFS_SELFTEST + ZFS_WRITE_SELFTEST
# so the read walk runs right after it and reads back what it wrote. The list (B3b, B4) commits, in order:
#   T0 + 1  the uberblock-only commit (B2) — uberblock T0 + 1 naming T0's rootbp, slot (T0 + 1) % N of all four labels,
#           between two device flushes — and an in-kernel read-back of all four rings
#   then C DATASET COWs (B4, zfs_wt_cow; C per lane: --cows) — one block of a file rewritten with IDENTICAL content in
#           a snapshot-free dataset, each its own txg: the dataset phase (the file's indirects, its dnode block, the
#           meta-dnode chain, the objset_phys, ds_bp; born / killed into the dataset and up its dsl_dirs with
#           parent_delta; user / group / project deltas) before the MOS phase; then the read-back and, through the
#           reader at T, the dataset's objset re-read from its new ds_bp, the file's top BP born in T, the block's
#           SHA-256 unchanged; the FIRST COW's MOS chain re-planned on disk (zfs_wc_tight, k.25 — B4 review). Targets
#           (zfs_wt_cows): agnos9 rand-2m.bin; agnoswr quota/q.bin (quota + refquota) and
#           resv/r.txt (reservation + refreservation: parent_delta 0, an embedded predecessor); agnostank
#           sha256/rand-256k.bin (sha256 metadata) and coff/kid/kid.txt (three dsl_dirs); agnosfull fill-0.bin
#   then three NULL txgs (B3b, zfs_commit; 8 on `full`): no dataset changes, every piece of a txg's MOS bookkeeping —
#           a new log space map recording every ALLOC and FREE of the txg, spacemap_histogram + 1, the log ZAP entry,
#           U[] where needed, the MOS's space up the dsl_dirs, the MOS COWed to a new rootbp — each followed by the
#           in-kernel read-back (zfs_wt_rb: the next mount's whole state load, re-run from the device, must equal what
#           the commit published). Three, so the guest's A4 rewinds to T - 1 and T - 2 land on agnos's own txgs. The
#           SECOND reserves 512 B for the MOS's chain indirects on its first attempt (zfs_wc_tight): its plan line must
#           show `replans=` >= 1 — the k.25 re-plan (restore the chain snapshot, undo its extents, plan again) on disk.
#   (B5, B6) between the COWs and the null txgs: each pool's CREATE / MKDIR / SYMLINK ops (b6_ops, zfs_wt_b6 — one txg
#           each; refusals by name; the meta-dnode grown past its dn_maxblkid on main's coff/kid, a microzap grown on
#           ashift9 and main) and then its FILE-DATA ops (b5_ops, zfs_wt_b5) — every successful op an op of the lane's
#           `.ops`, so zfs-expect.py's expected manifest holds the walk, the D / F / L lines and OpenZFS's phase B; the new
#           objects and their parents held to zfs_mknode's values and to a FreeBSD twin (zfs-sa-check.py), and in the
#           guest to OpenZFS's own stat(1) and getfacl (B-stat, B-acl)
# Later bites grow the op list, and this script grows with it (`.ops` / `.expect` per lane, design § i.5).
#
# Lanes (fixture images from scripts/tool/zfs-fixture.sh, one boot each, the zfs-smoke lane recipe — NVMe unless named):
#   rw       ashift9   agnos9    ashift 9: 1 KiB slots, 128 per ring
#            wr        agnoswr   the writer's own pool (RECIPE 3: clone / bookmark / formD / quota / ... children;
#                                RECIPE 7: snap2, two snapshots whose head's deadlist entries all name empty_bpobj)
#            main      agnostank ashift 12: 4 KiB slots, 32 per ring. agnostank/zpl4 (ZPL 4) is READ-ONLY; its root
#                                dataset (agnostank@snap1) is written since B9 — every kill of a block the snapshot
#                                owns deadlisted; the dataset COWs go to two writable children (sha256, coff/kid) whose
#                                dsl_dir chains end in the root's dir — its CHILD bytes move.
#            full      agnosfull the near-full pool (half of it is OpenZFS's slop): the commits' metadata goes into the
#                                slop, as OpenZFS's syncing context does (design § k.17), and the list holds the pool
#                                at ONE resident bitmap slot, so every commit loads, evicts and reloads metaslabs
#                                mid-txg (design § k.22: the no-pin rule on a real pool)
#            wr@u0     agnoswr   the wr image as an UPGRADED pool OpenZFS last ran at its slop with its logs kept:
#                                zfs-damage.py pre-defer (log T0 frees and re-allocates features_for_write's block, so
#                                its units are allocated AND deferred — the single-log form of what an export with
#                                zfs_keep_log_spacemaps_at_export leaves) then zero-u (U[] 0 for the metaslabs with a
#                                space map and no log entry — 1, 3, 5, exactly where the allocator goes; what EVERY pool
#                                created before log_spacemap keeps through any export for the metaslabs nothing touched
#                                since, design § c.3). The first commit (a dataset COW) presets U = T for them (B4,
#                                design § k.24: ONE round — until B4 it planned twice, the undo of round 1 evicting)
#                                and frees units already deferred (`pre>0`); OpenZFS must accept U = T there (design
#                                § c.3's review fix) and the overlap (§ c.2); verified against the forged start image
#                                (<lane>.pristine)
#            full@pre  agnosfull the full image + pre-defer, at the full lane's ONE bitmap slot: the already-deferred
#                                units of the first commit's FREE are RE-APPLIED when their metaslabs reload mid-txg
#                                (`reapply>0`, zfs_wxl_apply; design § c.2's B3a-review note: the overlap on disk)
#            logs      agnoslogs (fixture RECIPE 4) a pool OpenZFS last ran near its slop and exported with its log
#                                space maps KEPT (>= 8 logs, U[] spread by OpenZFS's own round-robin flush, FREEs later
#                                kept logs reallocate): ub-only + 3 null txgs on top of OpenZFS's many logs — the
#                                state load, the read-back and the verify on a real many-logs pool (no COW target)
#   variant  ashift9-torn   the ashift9 image with a TORN uberblock T0 + 1 in L0 (scripts/tool/zfs-damage.py tear-ub:
#                           T0+1's first sector over the old slot, eck stale — a crash part-way through a commit). The
#                           gate must skip it as OpenZFS does (core/zfs_write.cyr zfs_wub_scan) and the commit must
#                           rewrite the slot (B2 review N3: counting it left the pool read-only for agnos for good)
#            ashift9-grown  the partition 255 sectors LONGER than the image: psize rounds down to 256 KiB (zfs.cyr
#                           zfs_try), so L2/L3 stay where the pool put them and the 127.5 KiB tail is untouched (h5)
#            ashift9-ahci   the disk on the q35 AHCI port (backend 3: FLUSH CACHE EXT, one command per sector)
#            ashift9-usb    the disk on usb-storage behind qemu-xhci, booted from it (backend 4: msc WRITE(10) per
#                           sector, SYNCHRONIZE CACHE)
#                           Each variant's pool partition must come out BYTE-IDENTICAL to the ashift9 lane's (the op
#                           list's clock is deterministic), so OpenZFS's verdict on ashift9 covers them: no guest lane.
#   wfail    ashift9-ro     the NVMe drive readonly=on. QEMU 11.1's nvme does not report it (NSATTR.WP 0), so the gate
#                           says rw and the commit's first write fails: `zfs: commit txg T0+1 failed: uberblock write
#                           to label L0 - pool read-only until reboot` (zfs_wfail), the op FAILS by name, the walk still
#                           reads the pool, nothing is written (h4). The only lane through the commit's error path.
#   refused  v28       agnosv28  pool version 28                    } the op must be REFUSED, nothing written: the
#            mirror-a  agnosmir  vdev type mirror (one side alone)  } pool partition stays byte-identical (h4, G1)
#            makefs    agnosmk   no log_spacemap (makefs -t zfs)    }
#   nopool   raidz-0             a raidz child: no pool mounts (`zfs-wtest: no pool`), h4
#   cut      ashift9@cut-data / @cut-mos / @cut-ub1 / @cut-ub3   (1.57.12 B11) the ashift9 image booted with /boot/cmdline
#                           `zfs_cut=data:1` / `chain:1` / `ub:1` / `ub:3` on the ESP: the cut list (zfs_wt_cutlist), the
#                           machine halted inside its last txg (T0+6) — the device must hold T0+5 exactly (or T0+6 once a
#                           copy of its uberblock landed: --cut-labels K), and OpenZFS must open it, rewinds included
# ⚠ Known gaps (no fixture or device here yet): ashift >= 13 (8 KiB slots: two <= 4 KiB commands per copy), a 4Kn
# device (lb 4096; the gate refuses ashift 9 there), virtio-blk (OVMF on this box does not boot from it, and a pool on
# a SECONDARY backend has no device size — zfs_init knows only blk_active's capacity — so the gate refuses it `device
# size unknown`), and a USB stick without SYNCHRONIZE CACHE (QEMU's scsi-disk implements it; msc_blk_flush's
# ILLEGAL REQUEST path was proven once with a scratch build that sent an unimplemented opcode — B2 review). `full`
# (ENOSPC / slop, design § i.5) joins with B3, the first bite that allocates.
# Per lane, from the serial log: the pool line's txg is the image's pristine best (T0, computed on the host); the
# verdict line is the expected one; an rw lane prints `zfs-wtest: commit txg T0+1` and `ub-only commit ok`, then per
# dataset COW and null txg its plan line (`zfs-wtest: txg T plan: blocks=… ds=… dsu=… rounds=1 replans=… loads=…
# pre=0 reapply=0 … defer=…` — pre>0 or reapply>0 in the first where a lane says so: pre / reapply are the overlap
# rule's units, which no unforged fixture has, design § c.2; replans>=1 in the first dataset COW and the second null
# txg), `commit txg T`, `dataset cow
# ok` / `null txg ok`, and `zfs-wtest: done txg=T ops=N fails=0` (no `zfs: commit txg ... failed`); a refused lane
# refuses all four (`… ok refused (pool read-only)`, `done txg=T0 ops=4 fails=0`); the walk after the op list
# reproduces the fixture manifest exactly (scripts/smoke/lib/zfs-manifest-diff.py — agnos reading its own writes: a
# null txg changes no dataset). An rw lane also prints `commit hold:` per commit (the kernel's own timestamps, begin ->
# commit line: the plan, two flushes and four slot writes under fs_lock with IF=0 — design § k.8; the QEMU flush is a
# host fdatasync). Then the host audit, scripts/smoke/lib/zfs-image-audit.py, on the whole disk: h1 label fronts, h2
# boot region, h3 uberblock rings (rw: ONLY slots (T0+1..T0+4) % N changed, in all four labels, a valid eck at each
# copy's offset, ending at --final-txg T0+4; T0+1 naming T0's rootbp byte for byte and every later one another —
# --same-rootbp T0+1; refused: no ring changed), h4 (refused: the partition byte-identical), h5 nothing outside the
# partition; and on an rw lane `space`: the written pool's space record replayed on the host in OpenZFS's model
# (scripts/smoke/lib/zfs-wms-check.py --replay — the audit's h6, which the guest's H also runs): the U[] rule zdb and
# the imports let through (design § i.4, B3b's N3) is judged there; and `uacct` (B4): the host recount of every
# dnode's dn_used, every dataset's referenced and unique bytes, the user / group / project ZAPs, every snapshot-free
# dsl_dir's compressed / uncompressed and (B4 review) every dsl_dir's breakdown — CHILD / CHILD_RSRV from its child
# dirs, REFRSRV from the refreservation and ds_unique_bytes, HEAD == referenced (scripts/smoke/lib/zfs-uacct-check.py
# — the audit's h7). After the verify, `uspace`: phase
# B's `zfs userspace / groupspace / projectspace` (OpenZFS's own reading) against that recount.
# Finally the rw lanes' partitions go to $VDIR as <lane>.img + <lane>.txg (+ <lane>.pristine for a forged start) and
# `zfs-fixture.sh --verify` boots the FreeBSD 15.1 guest — once per batch of at most 8 lanes (B11: the 12 rw lanes go in
# two, $VDIR/b1 and b2, hard links to the lanes' files): A1-A6 (zdb -lu / -u txg == T0+4 / -bcc -d -m -s
# -y / -mmmm / -t T0+3 and T0+2 rewinds — agnos's own null txgs / per-dataset and MOS accounting), B (read-only import,
# manifest, xattrs, dirsize, status, Δ allocated == Δ root used minus unused reservations), C (read-write import,
# scrub, OpenZFS writes on top — on <lane>.touched first,
# export, zdb again), D (destroy everything, freeing/leaked 0) — design § i.3.
# ZWS_LANES="a b ..." runs only the named lanes (the negative proofs: a mutant kernel on one lane, design § i.4) and
# the verdict is PARTIAL — never a PASS.
# ZWS_SPACE=advisory (negative proofs only): a red `space` check — and (B5) a red `uacct`, `holes`, F-line or walk check
# of an rw lane — is printed but no longer fails its lane, so the
# image still goes to the guest — the host replay (h6) catches N1, N3 and N4 before the guest otherwise (N2, a missing
# FREE, leaves every log self-consistent and reaches it anyway), and the proofs must show which GUEST phase goes red
# as well (design § i.4). The guest's H still runs h6. (B6) Any other red still fails the lane, but its image goes to the
# guest all the same (a mutant that breaks the op list's own lines). The verdict is PARTIAL — never a PASS.
# ZWS_CONTINUE=1 (negative proofs only, B4): the guest runs phases B-D after a red phase A (zfs-fixture.sh --continue),
# so a proof shows every phase its defect reaches. PARTIAL — never a PASS.
#
# Build first:  ZFS_SELFTEST=1 ZFS_WRITE_SELFTEST=1 ZFS_WRITE_OPS=1 sh scripts/build.sh
# Requires: everything zfs-smoke.sh does, plus KVM for the verify guest (zfs-fixture.sh). ⚠ 8 min 20 s measured at B2
# (twelve boots, three verified lanes); B3b boots fourteen and verifies five (13 min 16 s), its review fifteen and
# six. A firmware VOID ("gnoboot: fail @ EBS") now ends its dwell at once (QEMU_DWELL_VOID) and is retried; it used to
# burn the whole 300 s budget.
# Exit 0 PASS · 1 a lane FAILED (the kernel's lines, the audit, or the guest) · 2 infrastructure only (no fixture, a
# VOID boot, a verify that reached no verdict) and nothing failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "${ZWS_SPACE:-}" in ""|advisory) ;; *) echo "ERROR: ZWS_SPACE=$ZWS_SPACE — the one value is 'advisory'"; exit 2 ;; esac
GNOBOOT_ROOT="${GNOBOOT_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/gnoboot}"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 2; }
for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy python3 dd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 2; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 2; }
[ -f "$AGNOS" ] || { echo "ERROR: agnos not built — run ZFS_SELFTEST=1 ZFS_WRITE_SELFTEST=1 ZFS_WRITE_OPS=1 sh scripts/build.sh"; exit 2; }
smoke_require_image "$AGNOS" "ZFS_SELFTEST ZFS_WRITE_SELFTEST ZFS_WRITE_OPS"

WORK="$ROOT/build/zfs-write-smoke"
LOGS="$ROOT/build/zfs-write-smoke-logs"
VDIR="$WORK/verify"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS" "$VDIR"
AUDIT="$ROOT/scripts/smoke/lib/zfs-image-audit.py"
POFF=$(( 67584 * 512 ))                                    # the pool partition's byte offset in the lane disk

# The payload keys the fixture (zfs-smoke.sh builds the same one): tests/zfs's exerciser, rebuilt every run.
echo "Building the payload (tests/zfs zfsx)..."
( cd "$ROOT/tests/zfs" && rm -f build/zfsx && cyrius build --agnos zfsx.cyr build/zfsx ) > "$LOGS/payload-build.log" 2>&1 \
    || { echo "ERROR: tests/zfs did not build:"; tail -5 "$LOGS/payload-build.log"; exit 2; }
mkdir -p "$WORK/payload" && cp "$ROOT/tests/zfs/build/zfsx" "$WORK/payload/zfsx"
echo "Ensuring the OpenZFS fixture (cold: boots FreeBSD under KVM; warm: reuses the cache)..."
FIX=$(bash "$ROOT/scripts/tool/zfs-fixture.sh" --ensure --payload "$WORK/payload" 2>"$LOGS/fixture.log" | tail -1)
if [ -z "$FIX" ] || [ ! -f "$FIX/DONE" ]; then
    echo "ERROR: no fixture (scripts/tool/zfs-fixture.sh failed — $LOGS/fixture.log):"; grep -a "ERROR" "$LOGS/fixture.log" | tail -3
    exit 2
fi
echo "  fixture: $FIX"

ACCEL="-cpu max"
if [ -w /dev/kvm ] && [ "${SMOKE_KVM:-1}" = "1" ]; then ACCEL="-enable-kvm -cpu host"; fi
echo "  accel: $ACCEL"

rc=0; lanes=0; voids=0; rwlanes=""
# B5 (design § h B5): the op list's FILE-DATA ops per fixture pool (core/zfs_write.cyr zfs_wt_b5 — the same list) as
# scripts/smoke/lib/zfs-expect.py ops: every op that SUCCEEDS; the refused ones (agnostank's zstd partial overwrite,
# agnosfull's last write) change nothing. (B7) gang/gang.bin's truncation — to 1 MiB, its 8 freed GANG L0s deferred to
# free_bpobj — lands now (refused until B7). agnosfull's fill is a SHORT write at the slop: its
# line is added from the kernel's own `-> <bytes>` (b5_fill). b5_nops: every op the list runs on the pool, refused ones
# included (agnos9 / agnostank / agnoswr / agnosfull; every other pool runs none).
b5_ops() {
    case "$1" in
    agnos9) cat <<'OPS'
write /agnos9/dir20/e00 3 10 b5/tiny
write /agnos9/rand-2m.bin 393216 131072 b5/rec
write /agnos9/hello.txt 0 300000 b5/multi
write /agnos9/dir20/e01 1048581 777 b5/sparse
trunc /agnos9/rand-2m.bin
OPS
    ;;
    agnostank) cat <<'OPS'
write /agnostank/off/rand-200k.bin 29672 6000 b5/off
write /agnostank/big1m/rand-3m.bin 1052897 10000 b5/big1m
truncate /agnostank/big1m/rand-3m.bin 1572987
write /agnostank/gz/text-1m.txt 1047576 5000 b5/gz
write /agnostank/lzjb/text-1m.txt 500000 100 b5/lzjb
zero /agnostank/sha256/rand-256k.bin 131072 131072
truncate /agnostank/gang/gang.bin 1048576
trunc /agnostank/sha512/text-64k.txt
write /agnostank/off/rand-200k.bin 204800 737280 b5/burst
truncate /agnostank/off/rand-200k.bin 204800
OPS
    ;;
    agnoswr) cat <<'OPS'
write /agnoswr/empty 0 1000 b5/empty
write /agnoswr/copies2/c512k.bin 100 50 b5/c2
write /agnoswr/rs4k/r64k.bin 4194404 100 b5/rs4k
write /agnoswr/quota/q.bin 524288 4096 b5/q
write /agnoswr/rs4k/r64k.bin 8388608 20971520 b5/l1s
trunc /agnoswr/rs4k/r64k.bin
OPS
    ;;
    esac
}
b5_nops() { case "$1" in agnos9) echo 5 ;; agnostank) echo 11 ;; agnoswr) echo 7 ;; agnosfull) echo 2 ;; *) echo 0 ;; esac; }
# B6 (design § h B6): the op list's CREATE / MKDIR / SYMLINK ops per fixture pool (core/zfs_write.cyr zfs_wt_b6 — the same
# list), run BEFORE the file-data ops (b5_ops), as zfs-expect.py ops: every op that SUCCEEDS, the writes into the new
# files included (B6 review: ashift9's b6/l144, a 144-byte target — the 320-byte bonus exactly full); the refused ones
# (a 145-byte symlink target, AO_EXCL on an existing name, a 50-byte name, a symlink where the dataset has no symlink
# layout, creates in read-only / case-insensitive / normalised datasets and in a fat-ZAP directory, a mkdir in
# agnostank's snapshotted root) change nothing. b6_nops: the create / mkdir / symlink ops the list
# runs, refused ones included; b6_nw: the write ops among the B6 list (counted with B5's).
b6_ops() {
    case "$1" in
    agnos9) cat <<'OPS'
mkdir /agnos9/b6
create /agnos9/b6/new.txt
write /agnos9/b6/new.txt 0 7 b6/new
mkdir /agnos9/b6/p
mkdir /agnos9/b6/p/q
mkdir /agnos9/b6/p/q/r
create /agnos9/b6/p/q/r/deep.bin
write /agnos9/b6/p/q/r/deep.bin 0 200000 b6/deep
symlink /agnos9/b6/link new.txt
symlink /agnos9/b6/l144 a-symlink-target-of-exactly-144-bytes-the-most-a-512-byte-dnode-bonus-holds-with-3-aces-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
create /agnos9/b6/a-name-of-fifty-bytes-past-the-microzap-limit-nnnn
mkdir /agnos9/b6empty
mkdir /agnos9/b6/many
OPS
        for _i in 00 01 02 03 04 05 06 07 08; do echo "create /agnos9/b6/many/f$_i"; done ;;
    agnoswr) cat <<'OPS'
mkdir /agnoswr/b6
create /agnoswr/b6/a.txt
write /agnoswr/b6/a.txt 0 10 b6/a
symlink /agnoswr/b6/sym a.txt
mkdir /agnoswr/rs4k/b6d
create /agnoswr/rs4k/b6d/c.bin
write /agnoswr/rs4k/b6d/c.bin 0 9000 b6/c
symlink /agnoswr/rs4k/b6d/s c.bin
create /agnoswr/fat/x
create /agnoswr/utf8/plain.txt
create /agnoswr/dnode/one.txt
mkdir /agnoswr/quota/b6q
mkdir /agnoswr/b6empty
OPS
    ;;
    agnostank)
        echo "mkdir /agnostank/coff/kid/b6"
        _i=0; while [ "$_i" -lt 56 ]; do printf 'create /agnostank/coff/kid/b6/f%02d\n' "$_i"; _i=$((_i + 1)); done
        cat <<'OPS'
symlink /agnostank/coff/kid/b6/s f00
create /agnostank/coff/kid/b6/a-name-of-fifty-bytes-past-the-microzap-limit-nnnn
mkdir /agnostank/coff/kid/b6e
create /agnostank/coff/kid/b6/w.txt
write /agnostank/coff/kid/b6/w.txt 0 100 b6/w
OPS
    ;;
    agnosfull|agnoslogs) printf 'mkdir /%s/b6\ncreate /%s/b6/a.txt\nwrite /%s/b6/a.txt 0 10 b6/a\nmkdir /%s/b6e\n' "$1" "$1" "$1" "$1" ;;
    esac
}
b6_nops() { case "$1" in agnos9) echo 22 ;; agnoswr) echo 14 ;; agnostank) echo 62 ;; agnosfull|agnoslogs) echo 3 ;; *) echo 0 ;; esac; }
b6_nw() { case "$1" in agnos9|agnoswr) echo 2 ;; agnostank|agnosfull|agnoslogs) echo 1 ;; *) echo 0 ;; esac; }
# B7 (design § h B7): the op list's UNLINK / RMDIR / RENAME / LINK ops per fixture pool (core/zfs_write.cyr zfs_wt_b7pre —
# on agnoswr / agnostank / agnoslogs right after the B6 ops, before B5's — and zfs_wt_b7, on agnos9 / agnostank /
# agnosfull after B5's — agnosfull's at the slop B5's fill leaves: the rename there is REFUSED; the same lists) as
# zfs-expect.py ops: every op that SUCCEEDS, the creates / writes among them
# included (the D11 fd tests' creates into a freed number, agnostank's off/lazy.bin that the unlink puts on the
# DELETE_QUEUE). b7_nops: the unlink / rmdir / rename / link ops the list runs, refused ones included; b7_nc / b7_nw: its
# creates / writes; b7_nfd: its `zfs-wtest: fd ... ok` lines.
b7_pre() {
    case "$1" in
    agnoswr) cat <<'OPS'
rmdir /agnoswr/b6empty
mkdir /agnoswr/b6e2
unlink /agnoswr/hello-link.txt
unlink /agnoswr/sym-long
rename /agnoswr/b6/a.txt /agnoswr/b6/a2.txt
rename /agnoswr/micro/m00 /agnoswr/b6/m00
rename /agnoswr/deep/a/b /agnoswr/b6/b
rmdir /agnoswr/deep/a
link /agnoswr/micro/m01 /agnoswr/micro/m01-link
link /agnoswr/micro/m02 /agnoswr/b6/m02
unlink /agnoswr/b6/m02
unlink /agnoswr/fat/f0
rename /agnoswr/fat/f1 /agnoswr/fat/f1-renamed-to-a-name-of-fifty-two-bytes-in-the-fat-zap
link /agnoswr/micro/m03 /agnoswr/fat/m03-link
OPS
        printf 'rename /agnoswr/utf8/plain.txt /agnoswr/utf8/caf\303\251.txt\n' ;;   # (B11) valid UTF-8: renamed
    agnostank) cat <<'OPS'
unlink /agnostank/coff/kid/b6/f00
rmdir /agnostank/coff/kid/b6e
rename /agnostank/coff/kid/b6/f01 /agnostank/coff/kid/f01
rename /agnostank/coff/kid/b6/w.txt /agnostank/coff/kid/b6/w2.txt
create /agnostank/off/lazy.bin
write /agnostank/off/lazy.bin 0 65536 b7/lazy
unlink /agnostank/off/lazy.bin
OPS
    ;;
    agnoslogs) printf 'unlink /agnoslogs/churn/c000-0\nrmdir /agnoslogs/b6e\n' ;;
    esac
}
b7_ops() {
    case "$1" in
    agnos9) cat <<'OPS'
unlink /agnos9/b6/many/f03
create /agnos9/b6/many/r03
unlink /agnos9/b6/many/f00
unlink /agnos9/dir20/e02
unlink /agnos9/b6/link
rmdir /agnos9/b6empty
rename /agnos9/b6/many/f01 /agnos9/b6/many/g01
rename /agnos9/b6/many/f02 /agnos9/b6/f02
rename /agnos9/dir20/e03 /agnos9/dir20/e04
rename /agnos9/b6/p /agnos9/b6/many/p
link /agnos9/dir20/e05 /agnos9/b6/e05
link /agnos9/dir20/e07 /agnos9/b6/e07
unlink /agnos9/b6/e07
rename /agnos9/dir20/e09 /agnos9/dir20/e09
create /agnos9/lz2.bin
write /agnos9/lz2.bin 0 8192 b7/lz2
create /agnos9/rs.txt
mkdir /agnos9/lzd
rename /agnos9/rs.txt /agnos9/lz2.bin
rmdir /agnos9/lzd
mkdir /agnos9/b7s
mkdir /agnos9/b6/b7t
rename /agnos9/b7s /agnos9/b6/b7t
unlink /agnos9/xd.txt
OPS
    ;;
    agnostank) cat <<'OPS'
unlink /agnostank/gang/gang.bin
unlink /agnostank/dnode/n00
OPS
    ;;
    agnosfull) printf 'unlink /agnosfull/b6/a.txt\nrmdir /agnosfull/b6e\nrename /agnosfull/dir/s1.txt /agnosfull/b6/s1.txt\n' ;;
    esac
}
b7_nops() { case "$1" in agnos9) echo 23 ;; agnoswr) echo 20 ;; agnostank) echo 9 ;; agnosfull) echo 3 ;; agnoslogs) echo 2 ;; *) echo 0 ;; esac; }
b7_nc() { case "$1" in agnos9) echo 6 ;; agnoswr|agnostank) echo 1 ;; *) echo 0 ;; esac; }
b7_nw() { case "$1" in agnos9|agnostank) echo 1 ;; *) echo 0 ;; esac; }
b7_nfd() { case "$1" in agnos9) echo 3 ;; agnoswr) echo 2 ;; agnostank) echo 1 ;; *) echo 0 ;; esac; }
# B8 (design § h B8): the fat-ZAP pool's op list (core/zfs_write.cyr zfs_wt_b8, fixture RECIPE 7's agnosfz) as
# zfs-expect.py ops — re-derived on the host by scripts/smoke/lib/zfs-fz-ops.py: b8/'s names chosen by their ZAP hash
# under the list's salt, the `a` count until the pointer table began doubling from the fat-ZAP model, dir3000/'s smallest
# leaf from the PRISTINE image; every op succeeds. b8_nc / b8_nu / b8_nw: its creates, removals / renames / links, writes.
b8_cache() {
    [ -f "$WORK/b8.$1.ops" ] && return 0
    : > "$WORK/b8.$1.ops"
    [ "$1" = agnosfz ] || return 0
    python3 -I "$ROOT/scripts/smoke/lib/zfs-fz-ops.py" "$FIX/fz.img" > "$WORK/b8.$1.ops" 2> "$LOGS/b8.$1.ops.err" \
        || { echo "  FAIL: zfs-fz-ops.py: $(tail -1 "$LOGS/b8.$1.ops.err")"; : > "$WORK/b8.$1.ops"; rc=1; }
}
b8_ops() { b8_cache "$1"; cat "$WORK/b8.$1.ops"; }
b8_nc() { b8_cache "$1"; grep -cE '^(create|mkdir|symlink) ' "$WORK/b8.$1.ops"; }
b8_nu() { b8_cache "$1"; grep -cE '^(unlink|rmdir|rename|link) ' "$WORK/b8.$1.ops"; }
b8_nw() { b8_cache "$1"; grep -cE '^write ' "$WORK/b8.$1.ops"; }
# B9 (design § h B9): the op list's SNAPSHOTTED-DATASET ops per fixture pool (core/zfs_write.cyr zfs_wt_b9 — the same
# list), right after b7_pre's and before B5's, as zfs-expect.py ops — every one that lands: in agnostank's root (@snap1;
# its directory a fat ZAP, so the namespace ops are under deep/), in agnoswr's snap (@s1), clone (of snap@s1, no
# livelist), snap2 (RECIPE 7: @a, @b, every head deadlist entry the empty_bpobj until the first write materialises two)
# and (B9 review, RECIPE 8) edge / edgec: the boundary births, block 0 paths in four deadlist intervals, a truncation of
# four kills a txg — and three refusals by name the lane's --want lines name (nothing written). b9_nw:
# its writes / truncations (counted with B5's) · b9_nu: its unlink / rename ops (with B7's) · b9_nc: its creates /
# mkdirs (with B6's).
b9_ops() {
    case "$1" in
    agnostank) cat <<'OPS'
write /agnostank/small.txt 100 10 b9/small
write /agnostank/rand-1m.bin 300000 5000 b9/r1m
write /agnostank/snap-changed.txt 0 5 b9/sc
truncate /agnostank/big.bin 1000000
trunc /agnostank/text-3m.txt
unlink /agnostank/deep/a/b/c/d/e/leaf.txt
rename /agnostank/deep/a/b/c/d/e /agnostank/deep/a/e2
mkdir /agnostank/deep/b9
create /agnostank/deep/b9/n.txt
write /agnostank/deep/b9/n.txt 0 100 b9/n
OPS
    ;;
    agnoswr) cat <<'OPS'
write /agnoswr/snap/keep.txt 0 10 b9/keep
write /agnoswr/snap/rewritten.bin 0 131072 b9/rw
unlink /agnoswr/snap/moved.txt
write /agnoswr/clone/keep.txt 0 10 b9/ckeep
unlink /agnoswr/clone/own.txt
write /agnoswr/snap2/a.bin 0 4096 b9/a
write /agnoswr/snap2/b.bin 4096 4096 b9/b
trunc /agnoswr/snap2/a.bin
write /agnoswr/edge/p.bin 0 4096 b9/p
write /agnoswr/edge/e4.bin 0 4096 b9/e4
write /agnoswr/edge/e3.bin 0 4096 b9/e3
write /agnoswr/edgec/e4.bin 0 4096 b9/ce4
write /agnoswr/edgec/c1.bin 0 4096 b9/c1
trunc /agnoswr/edgec/t.bin
OPS
    ;;
    esac
}
# agnoswr's 15: B9's 6, then (B9 review, RECIPE 8) edge / edgec's 9 — three of them refused (the FAT knob's p.bin,
# q.bin's three-level path, t.bin under the capped deadlist table), so not in b9_ops
b9_nw() { case "$1" in agnostank) echo 6 ;; agnoswr) echo 15 ;; *) echo 0 ;; esac; }
b9_nu() { case "$1" in agnostank|agnoswr) echo 2 ;; *) echo 0 ;; esac; }
b9_nc() { case "$1" in agnostank) echo 2 ;; *) echo 0 ;; esac; }
# B10 (design § h B10, k.63): the op list's DRAIN ops (core/zfs_write.cyr zfs_wt_b10, after B8's, before the null txgs) —
# agnos9's root DELETE_QUEUE (B7's lz2.bin and lzd freed; xd.txt refused by name: an extended-attribute directory) and
# agnostank/off's (lazy.bin in bounded parts), then the production path: b10.bin created, written and unlinked with the
# op's own drain — as zfs-expect.py ops (the drains change no name). b10_nd: its `drain` ops · b10_nc / b10_nw / b10_nu:
# its creates / writes / unlinks (counted with B6's / B5's / B7's)
b10_ops() {
    case "$1" in
    agnostank) printf 'create /agnostank/off/b10.bin\nwrite /agnostank/off/b10.bin 0 12288 b10/q\nunlink /agnostank/off/b10.bin\n' ;;
    esac
}
b10_nd() { case "$1" in agnos9|agnostank) echo 1 ;; *) echo 0 ;; esac; }
b10_nc() { case "$1" in agnostank) echo 1 ;; *) echo 0 ;; esac; }
b10_nw() { case "$1" in agnostank) echo 1 ;; *) echo 0 ;; esac; }
b10_nu() { case "$1" in agnostank) echo 1 ;; *) echo 0 ;; esac; }
# B11 (design § h B11): the op list's POLICY-B / RELEASE ops (core/zfs_write.cyr zfs_wt_b11 — the same list), after B8's and
# before the null txgs, as zfs-expect.py ops — on agnos9: b11/ made, a.bin written 8 x 64 KiB through one fd under policy
# A (8 txgs) and b.bin under policy B (ONE txg, at close), the commit-before-observe / sync / age writes into b.bin,
# big.bin 4.5 MiB through one fd (its txgs at the arena threshold), the release op's four writes (a.bin's blocks 0, 1, 2
# and hello.txt), then (B11 review) the RACE op: big.bin rewritten by ONE 4.5 MiB write#1 while the yield hook writes
# a.bin's first 4 KiB in its gap, pending — committed by the re-check after the yield (by=yield), never dropped;
# on agnoswr the UTF-8 creates in utf8 (one lands: a 4-byte character; five refused by u8_validate's
# class); (k.64) on agnostank a rename after the burst. b11_nw: its writes · b11_nc: its creates / mkdirs (refused ones
# included) · b11_nu: its renames.
b11_ops() {
    case "$1" in
    agnos9) cat <<'OPS'
mkdir /agnos9/b11
create /agnos9/b11/a.bin
create /agnos9/b11/b.bin
write /agnos9/b11/a.bin 0 524288 b11/cp
write /agnos9/b11/b.bin 0 524288 b11/cp
write /agnos9/b11/b.bin 1000 3000 b11/obs
write /agnos9/b11/b.bin 600000 5000 b11/sync
write /agnos9/b11/b.bin 700000 5000 b11/age
create /agnos9/b11/big.bin
write /agnos9/b11/big.bin 0 4718592 b11/big
write /agnos9/b11/a.bin 0 131072 b11/r0
write /agnos9/hello.txt 0 10 b11/r1
write /agnos9/b11/a.bin 131072 131072 b11/r2
write /agnos9/b11/a.bin 262144 131072 b11/r3
write /agnos9/b11/big.bin 0 4718592 b11/race
write /agnos9/b11/a.bin 0 4096 b11/race2
OPS
    ;;
    agnostank) echo "rename /agnostank/coff/kid/f01 /agnostank/coff/kid/f01-late" ;;
    esac
}
# (B11) its EARLY ops (zfs_wt_b11pre: right after b7_pre's, before B5's exhaustion of wr's room) — wr's UTF-8 creates
b11_pre() {
    case "$1" in
    agnoswr) printf 'create /agnoswr/utf8/emoji-\360\237\230\200.txt\n' ;;
    esac
}
b11_nw() { case "$1" in agnos9) echo 11 ;; *) echo 0 ;; esac; }
b11_nc() { case "$1" in agnos9) echo 4 ;; agnoswr) echo 6 ;; *) echo 0 ;; esac; }
b11_nu() { case "$1" in agnostank) echo 1 ;; *) echo 0 ;; esac; }
# B11 (design § h B11, § b.3): the CUT lanes' list (core/zfs_write.cyr zfs_wt_cutlist, armed by /boot/cmdline zfs_cut=...
# on the ESP) — its ops through txg T0 + $1 (5: the cut txg T0 + 6 never became durable; 6: one copy of its uberblock
# landed, so OpenZFS opens T0 + 6) as zfs-expect.py ops
cut_ops() {
    cat <<'OPS'
mkdir /agnos9/b11c
create /agnos9/b11c/f.bin
write /agnos9/b11c/f.bin 0 262144 b11c/f
write /agnos9/b11c/f.bin 0 131072 b11c/g
write /agnos9/hello.txt 0 10 b11c/h
OPS
    [ "$1" = 6 ] && echo "write /agnos9/b11c/f.bin 131072 131072 b11c/k"
    return 0
}
# slog <log> — the serial log as text: NULs and CRs dropped, invalid UTF-8 replaced (U+FFFD). (B11) It replaced `strings`,
# which cuts a line at every non-ASCII byte — so a VALID UTF-8 name (`café.txt`, the 4-byte one B11 creates on wr's
# utf8only dataset) split its op's line in two and its `-> r txgs=k` was not counted
slog() {
    python3 -I -c 'import sys; sys.stdout.write(open(sys.argv[1], "rb").read().replace(b"\0", b"").replace(b"\r", b"").decode("utf-8", "replace"))' "$1" 2>/dev/null
}
# want <log> <ERE> <what> — one serial line matching ^(timestamp )?<ERE>$ must be present
want() {
    if slog "$1" | grep -qE "^(\[[^]]*\] )?$2\$"; then echo "    ok: $3"; return 0; fi
    echo "    FAIL: $3 — no line matching '$2'"; return 1
}
# lane <name> <pool> rw|wfail|nopool [options]  |  lane <name> <pool> refused <why> [options]
#   --img I       the fixture image (default: <name>)   --extra N   the partition N sectors longer than the image
#   --dev D       nvme (default) | nvme-ro | ahci | usb --tear      tear uberblock T0+1 in L0 first (zfs-damage.py)
#   --same-as L   the pool partition must come out byte-identical to lane L's (L is an rw lane that ran first, passed)
#   --forge V[,W] start from the image after `zfs-damage.py V` (then W, ...: STATES, not defects — zero-u, pre-defer):
#                 the audit and the guest's H judge against that forged start (<lane>.pristine), not the fixture's
#   --loads1 E / --pre1 E / --reapply1 E   the FIRST commit's (after the ub-only one) loads= / pre= / reapply= must
#                 match the ERE E (defaults [0-9]+ / 0 / 0; every later one: pre=0 reapply=0). Every commit plans ONE
#                 round since B4 (design § k.24: the first commit presets U = T wherever U is 0 — zero-u included)
#   --cows N      the list commits N dataset COWs on this pool first (default 0; zfs_wt_cows' targets), each `ds=1`
#   --nulls N     the list commits N null txgs on this pool (default 3; the full fixture's 8); the second must re-plan
#   --touched "P ..."   manifest paths of the files the COWs rewrote: <lane>.touched for the guest's phase C
#   --want ERE    one more serial line this lane must print
#   --timeout S   the boot's budget in seconds (default QEMU_TIMEOUT or 300; B5 review: main's 250-txg burst, 180 since B10)
#   --room "OP PATH B COPIES [MSMAX]"   (B5 review) the first SHORT OP (write | burst) to PATH stopped where the space
#                 record says it must (zfs-room-check.py; B = one block's asize; MSMAX (B9): the op list's allocation cap,
#                 zfs_wt_msmax — the first MSMAX metaslabs with a space map are the room)
#   --fbpo N      (B7) the txgs whose plan line has fbpo > 0 — kills deferred to free_bpobj (gang / dedup / clone blocks,
#                 design § e.2) — are exactly N (default 0), and $FREE on the image holds their Σ (uacct --freeing)
#   --hist E      (B7, design k.68) the txgs whose plan line has hist > 0 — space map histograms LOWERED because the txg
#                 consumed a metaslab's largest free segments — must number E (an ERE; default any): the path runs on
#                 disk (the space check's histogram rule judges every metaslab of every lane)
lane() {
    _name="$1"; _pool="$2"; _kind="$3"; shift 3
    _why=""; [ "$_kind" = refused ] && { _why="$1"; shift; }
    _img="$_name"; _extra=0; _dev=nvme; _tear=0; _same=""; _forge=""; _nc=0; _nn=3; _wants=(); _touch=""
    _l1='[0-9]+'; _p1=0; _q1=0; _tmo="${QEMU_TIMEOUT:-300}"; _room=""; _fbt=0; _fbs=0; _hst='[0-9]+'; _dlt=0; _mtt=0
    _cut=""; _cfin=0; _clab=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --img) _img="$2"; shift 2 ;;
            --extra) _extra="$2"; shift 2 ;;
            --dev) _dev="$2"; shift 2 ;;
            --tear) _tear=1; shift ;;
            --same-as) _same="$2"; shift 2 ;;
            --forge) _forge="$2"; shift 2 ;;
            --cows) _nc="$2"; shift 2 ;;
            --touched) _touch="$2"; shift 2 ;;
            --loads1) _l1="$2"; shift 2 ;;
            --pre1) _p1="$2"; shift 2 ;;
            --reapply1) _q1="$2"; shift 2 ;;
            --nulls) _nn="$2"; shift 2 ;;
            --want) _wants+=("$2"); shift 2 ;;
            --timeout) _tmo="$2"; shift 2 ;;
            --room) _room="$2"; shift 2 ;;
            --fbpo) _fbt="$2"; shift 2 ;;
            --hist) _hst="$2"; shift 2 ;;
            --dl) _dlt="$2"; shift 2 ;;
            --mat) _mtt="$2"; shift 2 ;;
            --cut) _cut="$2"; shift 2 ;;
            --cutfinal) _cfin="$2"; shift 2 ;;
            --cutlabels) _clab="$2"; shift 2 ;;
            *) echo "  FAIL [$_name]: unknown lane option $1"; rc=1; lanes=$((lanes + 1)); return ;;
        esac
    done
    if [ -n "${ZWS_LANES:-}" ]; then case " $ZWS_LANES " in *" $_name "*) ;; *) return ;; esac; fi
    _fi="$FIX/$_img.img"
    lanes=$((lanes + 1))
    [ -f "$_fi" ] || { echo "  FAIL [$_name]: $_fi missing from the fixture"; rc=1; return; }
    # T0, the pristine best txg, read off the image by the host — the kernel must mount exactly that
    _t0=$(python3 -I "$AUDIT" "$_fi" "$_fi" | sed -n 's/.*pristine best txg \([0-9]*\).*/\1/p')
    [ -n "$_t0" ] || { echo "  VOID [$_name]: could not read the pristine best txg of $_fi"; voids=$((voids + 1)); return; }
    _nb=$(( $(b5_nops "$_pool") + $(b6_nw "$_pool") + $(b7_nw "$_pool") + $(b8_nw "$_pool") + $(b9_nw "$_pool") + $(b10_nw "$_pool") + $(b11_nw "$_pool") ))
    _n6=$(( $(b6_nops "$_pool") + $(b7_nc "$_pool") + $(b8_nc "$_pool") + $(b9_nc "$_pool") + $(b10_nc "$_pool") + $(b11_nc "$_pool") ))
    _n7=$(( $(b7_nops "$_pool") + $(b8_nu "$_pool") + $(b9_nu "$_pool") + $(b10_nu "$_pool") + $(b11_nu "$_pool") )); _nfd=$(b7_nfd "$_pool")
    _nd=$(b10_nd "$_pool")
    _t1=$((_t0 + 1))
    _src="$_fi"; _ref="$_fi"
    _pc="${WORK:?}/${_name:?}.pool"
    _d="${WORK:?}/${_name:?}.disk"
    _bf="${WORK:?}/${_name:?}.before"
    if [ "$_tear" = 1 ] || [ -n "$_forge" ]; then
        _src="$_pc"
        cp --sparse=always "$_fi" "$_src"
        _verb=tear-ub; [ -n "$_forge" ] && { _verb="$_forge"; _ref="$_src"; }
        : > "$LOGS/$_name.damage"
        for _v in ${_verb//,/ }; do
            python3 -I "$ROOT/scripts/tool/zfs-damage.py" "$_v" "$_src" >> "$LOGS/$_name.damage" 2>&1 \
                || { echo "  FAIL [$_name]: zfs-damage.py $_v failed:"; sed 's/^/    /' "$LOGS/$_name.damage"; rc=1; return; }
        done
    fi
    _sec=$(( $(stat -c %s "$_fi") / 512 ))
    _psec=$(( _sec + _extra ))
    truncate -s $(( (67584 + _psec + 2048) * 512 )) "$_d"
    parted -s "$_d" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart zfs 67584s $((67584 + _psec - 1))s
    sgdisk -t 2:a504 "$_d" >/dev/null                      # FreeBSD ZFS (the probe reads the label, not the type)
    mformat -i "$_d"@@1048576 -F
    mmd -i "$_d"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$_d"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$_d"@@1048576 "$AGNOS" ::boot/agnos
    if [ -n "$_cut" ]; then
        # (B11) the cut lane's knob, as the boot command line gnoboot loads (\boot\cmdline) — the op list reads it back
        # through the ESP's FAT mount (zfs_wt_cmdline)
        printf 'zfs_cut=%s\n' "$_cut" > "${WORK:?}/${_name:?}.cmdline"
        mcopy -i "$_d"@@1048576 "$WORK/$_name.cmdline" ::boot/cmdline
    fi
    dd if="$_src" of="$_d" bs=512 seek=67584 conv=notrunc status=none
    cp --sparse=always "$_d" "$_bf"                         # h5: the disk as it was before the boot
    case "$_dev" in
        nvme)    _devargs="-drive file=$_d,format=raw,if=none,id=disk0 -device nvme,drive=disk0,serial=AGNOS-ZFS" ;;
        nvme-ro) _devargs="-drive file=$_d,format=raw,if=none,id=disk0,readonly=on -device nvme,drive=disk0,serial=AGNOS-ZFS" ;;
        ahci)    _devargs="-drive file=$_d,format=raw,if=none,id=disk0 -device ide-hd,drive=disk0,bus=ide.0" ;;
        usb)     _devargs="-device qemu-xhci,id=xhci -drive file=$_d,format=raw,if=none,id=disk0 -device usb-storage,bus=xhci.0,drive=disk0,bootindex=0" ;;
        *) echo "  FAIL [$_name]: unknown --dev $_dev"; rc=1; return ;;
    esac
    _mark="zfs-walk: done"; [ "$_kind" = nopool ] && _mark="zfs-walk: no pool"
    [ "$_kind" = cut ] && _mark='zfs-wtest: cut \(txg [0-9]* after\|list done\)'
    _log="$LOGS/$_name.log"
    # shellcheck disable=SC2086 # ACCEL and _devargs are deliberately word-split (no spaces: the paths are under $ROOT/build)
    QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @|BootManagerMenuApp|Please select boot device}" \
    qemu_dwell_kernel "$_log" "$_mark" "$_tmo" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 1024M $ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        $_devargs \
        -serial stdio -display none -no-reboot
    if [ "$(qemu_boot_class "$_log")" = "void" ]; then
        echo "  VOID [$_name]: the firmware never handed off — infrastructure, not ZFS ($_log)"; voids=$((voids + 1))
        rm -f "$_d" "$_bf" "$_pc"; return
    fi
    _note=""; [ "$_extra" != 0 ] && _note=", partition +$_extra sectors"
    { [ "$_tear" = 1 ] || [ -n "$_forge" ]; } && _note="$_note; $(sed -n 's/^zfs-damage: //p' "$LOGS/$_name.damage" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    echo "  --- $_name ($_kind, $_dev, pristine txg $_t0$_note) ---"
    slog "$_log" | grep -E "^(\[[^]]*\] )?(zfs: (pool|commit|$_pool (rw|read-only))|zfs-wtest:|msc: SYNC)" | sed 's/^/    | /'
    _ok=1; _hlast=""
    # B5: the txgs the file-data ops committed (`zfs-wtest: write|trunc <path> -> <r> txgs=<k>`, Σ k) sit between the
    # dataset COWs and the null txgs
    _nw=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: (write|trunc|burst|create|mkdir|symlink|unlink|rmdir|rename|link|drain) \/.* -> -?[0-9]+ txgs=([0-9]+)$/\3/p' | awk '{s += $1} END {print s + 0}')
    _t4=$((_t0 + 1 + _nc + _nw + _nn)); _ops=$((1 + _nc + _nb + _n6 + _n7 + _nn + _nd))
    # the EXPECTED manifest: the fixture's + the lane's successful ops (zfs-expect.py, the in-place files' original
    # bytes regenerated from the recipe — zfs-orig.py); the walk after the op list and every op's F line are held to it
    _exp="$FIX/$_img.manifest"; _opsf="${WORK:?}/${_name:?}.ops"; _orig="${WORK:?}/${_name:?}.orig"; rm -rf "$_orig"; : > "$_opsf"
    if [ "$_kind" = rw ] && [ $((_nb + _n6 + _n7)) -gt 0 ]; then
        { b6_ops "$_pool"; b7_pre "$_pool"; b11_pre "$_pool"; b9_ops "$_pool"; b5_ops "$_pool"; b7_ops "$_pool"; b8_ops "$_pool"; b10_ops "$_pool"; b11_ops "$_pool"; } > "$_opsf"
        _fr=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: write \/agnosfull\/fill-5\.bin -> ([0-9]+) txgs=[0-9]+$/\2/p' | head -1)
        [ "$_pool" = agnosfull ] && [ -n "$_fr" ] && [ "$_fr" -gt 0 ] && echo "write /agnosfull/fill-5.bin 917504 $_fr b5/fill" >> "$_opsf"
        # (B5 review) wr's exhausting burst: the bytes that landed before ENOSPC, from the kernel's `-> <bytes>` too — the
        # host's room check (zfs-room-check.py, below) then holds where it stopped to the space record
        _fx=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: burst \/agnoswr\/rs4k\/r64k\.bin -> ([0-9]+) txgs=[0-9]+$/\2/p' | head -1)
        [ "$_pool" = agnoswr ] && [ -n "$_fx" ] && [ "$_fx" -gt 0 ] && echo "write /agnoswr/rs4k/r64k.bin 8388608 $_fx b5/exhaust" >> "$_opsf"
        _ip=$(awk 'FILENAME == ARGV[1] { if ($1 == "F" && $(NF - 1) > 0) sz[$2] = 1; next }
                   ($1 == "write" || $1 == "zero" || $1 == "truncate") && ($2 in sz) { print $2 }' "$FIX/$_img.manifest" "$_opsf" | sort -u)
        # shellcheck disable=SC2086 # one argument per path (no spaces: the manifest contract)
        # (B6) a lane whose ops only create (logs) modifies no fixture file in place: nothing to regenerate
        [ -z "$_ip" ] || python3 -I "$ROOT/scripts/smoke/lib/zfs-orig.py" "$_orig" $_ip > "$LOGS/$_name.orig" 2>&1 \
            || { echo "    FAIL: zfs-orig.py could not regenerate the original bytes: $(head -1 "$LOGS/$_name.orig")"; _ok=0; }
        mkdir -p "$_orig"
        if python3 -I "$ROOT/scripts/smoke/lib/zfs-expect.py" "$FIX/$_img.manifest" "$_opsf" --objects "$FIX/$_img.objects" \
            --orig "$_orig" -o "${WORK:?}/${_name:?}.expect" > "$LOGS/$_name.expect" 2>&1; then
            _exp="$WORK/$_name.expect"
            echo "    expect: $(tail -1 "$LOGS/$_name.expect" | cut -c1-160)"
        else echo "    FAIL: zfs-expect.py: $(grep -E 'FAIL|UNUSABLE' "$LOGS/$_name.expect" | head -1 | cut -c1-200)"; _ok=0; fi
    fi
    # (B11) a cut lane's expected manifest: its list's ops through the txg the device holds (cut_ops)
    _slog="$_log"
    if [ "$_kind" = cut ]; then
        cut_ops "$_cfin" > "$_opsf"
        rm -rf "$_orig"; mkdir -p "$_orig"
        python3 -I "$ROOT/scripts/smoke/lib/zfs-orig.py" "$_orig" /agnos9/hello.txt > "$LOGS/$_name.orig" 2>&1 \
            || { echo "    FAIL: zfs-orig.py could not regenerate the original bytes: $(head -1 "$LOGS/$_name.orig")"; _ok=0; }
        if python3 -I "$ROOT/scripts/smoke/lib/zfs-expect.py" "$FIX/$_img.manifest" "$_opsf" --objects "$FIX/$_img.objects" \
            --orig "$_orig" -o "${WORK:?}/${_name:?}.expect" > "$LOGS/$_name.expect" 2>&1; then
            _exp="$WORK/$_name.expect"
            echo "    expect: $(tail -1 "$LOGS/$_name.expect" | cut -c1-160)"
        else echo "    FAIL: zfs-expect.py: $(grep -E 'FAIL|UNUSABLE' "$LOGS/$_name.expect" | head -1 | cut -c1-200)"; _ok=0; fi
        # the attribute / hole checks read the op list's ops off the log: when the cut txg's uberblock landed (--cutfinal
        # 6) its op — halted before its `write ok` — is durable all the same
        _slog="${WORK:?}/${_name:?}.slog"
        cp "$_log" "$_slog"
        [ "$_cfin" = 6 ] && printf 'zfs-wtest: write ok\n' >> "$_slog"
    fi
    case "$_kind" in
    cut)
        # (B11, design § b.3) the crash: the list's txgs T0+1 .. T0+5 committed, each a policy-B close (or a namespace op);
        # the knob armed for T0+6; the kernel halted after N device writes of it, before the next — the device holds T0+5
        # exactly (every T0+6 block went to space T0+5 calls free) or, once a copy of uberblock T0+6 landed, T0+6
        want "$_log" "zfs: pool $_pool txg $_t0 .*" "mounted at the pristine best txg $_t0" || _ok=0
        want "$_log" "zfs: $_pool rw" "the pool passed the write gate" || _ok=0
        want "$_log" "zfs-wtest: cut armed for txg $((_t0 + 6)): .*" "the knob armed for the list's last txg ($_cut)" || _ok=0
        for _tk in $(seq $_t1 $((_t0 + 5))); do
            _wo=$(want "$_log" "zfs-wtest: commit txg $_tk" "committed txg $_tk") || { echo "$_wo"; _ok=0; }
        done
        echo "    ok: txgs $_t1..$((_t0 + 5)) committed (mkdir, create, three policy-B closes)"
        want "$_log" "zfs-wtest: cut txg $((_t0 + 6)) after [0-9]+ device writes .* - halted" "halted inside txg $((_t0 + 6)): $(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: cut txg [0-9]+ after (.*) - halted$/\2/p' | head -1)" || _ok=0
        for _w in "${_wants[@]}"; do want "$_log" "$_w" "$_w" || _ok=0; done
        _t4=$((_t0 + _cfin))
        _aud="--final-txg $_t4"
        [ "$_clab" -gt 0 ] && _aud="$_aud --cut-labels $_clab" ;;
    rw)
        want "$_log" "zfs: pool $_pool txg $_t0 .*" "mounted at the pristine best txg $_t0" || _ok=0
        want "$_log" "zfs: $_pool rw" "the pool passed the write gate" || _ok=0
        want "$_log" "zfs-wb3: done ok" "B3a's in-memory exercise (dirty set, allocator, frees, BP builder) passed and undid itself" || _ok=0
        want "$_log" "zfs-wb3: uacct .* new keys=[0-9]+ user ZAP [0-9]+->[0-9]+ B, reversed to T-1 ok" "accounting microzaps in memory: new keys, growth, removal at 0 (B4 review) — $(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wb3: uacct (.*), reversed.*$/\2/p' | head -1)" || _ok=0
        want "$_log" "zfs-wb3: resv .* dsl_dirs=[0-9]+ crossing / absorbed / above, each there and back ok" "reservation boundaries crossed in memory (B4 review) — $(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wb3: resv (.*) crossing.*$/\2/p' | head -1)" || _ok=0
        # B10 (design k.118, k.110): a flush whose append outgrows its space map's block, in memory (blocks past the
        # first and the level growth only on an ashift-9 pool, whose 16 MiB metaslab has 32,768 units); on main a MOS
        # gang predecessor's free over gang.bin's real tree
        want "$_log" "zfs-wb3: flush ms [0-9]+: [0-9]+ word\(s\) appended, space map [0-9]+ -> [0-9]+ B, blocks [0-9]+\.\.[0-9]+, nlevels [0-9]+, replayed back ok" "a flush in memory — $(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wb3: flush (.*), replayed.*$/\2/p' | head -1)" || _ok=0
        [ "$_pool" = agnostank ] && { want "$_log" "zfs-wb3: gang /agnostank/gang/gang.bin L0 [0-9]+: [0-9]+ extent\(s\) freed \([1-9][0-9]* gang header\(s\)\), undone ok; [2-3] header copies verified against DVA\[0\]'s identity \(1 against their own\) ok" "a MOS gang predecessor's free over a real gang tree, in memory; (B10 review, k.120) every header copy verified against DVA[0]'s identity, only DVA[0]'s against its own" || _ok=0; }
        want "$_log" "zfs-wtest: commit txg $_t1" "committed txg $_t1 (uberblock-only)" || _ok=0
        want "$_log" "zfs-wtest: ub-only commit ok" "ub-only commit ok (incl. the in-kernel read-back)" || _ok=0
        _l=$_l1; _p=$_p1; _q=$_q1; _fq=0
        for _tk in $(seq $((_t0 + 2)) $_t4); do
            # a dataset COW's txg changes one dataset (ds=1, dsu: its born - killed), a null txg none; the FIRST dataset
            # COW and the second null txg must re-plan their chains (k.25, the op list's zfs_wc_tight — B4 review: a
            # re-plan in a txg with a dataset phase), every other may (an estimate that missed); defer: the deferred
            # bytes zfs_wroom keeps back once the txg is published (B4 review)
            _what="dataset cow"; _ds=1; _rp='[0-9]+'
            [ "$_tk" -gt $((_t0 + 1 + _nc)) ] && _what="file-data op"
            [ "$_tk" -gt $((_t0 + 1 + _nc + _nw)) ] && { _what="null txg"; _ds=0; }
            [ "$_tk" = $((_t0 + 3 + _nc + _nw)) ] && _rp='[1-9][0-9]*'
            [ "$_nc" -gt 0 ] && [ "$_tk" = $((_t0 + 2)) ] && _rp='[1-9][0-9]*'
            _pl="zfs-wtest: txg $_tk plan: blocks=[0-9]+ chain=[0-9]+ extents=[0-9]+ alloc=[0-9]+ free=[0-9]+ log=[0-9]+ mos=-?[0-9]+ ds=$_ds dsu=-?[0-9]+ rounds=1 replans=$_rp loads=$_l pre=$_p reapply=$_q obj=[0-9]+ defer=[0-9]+ udata=[0-9]+ charged=[0-9]+ fbpo=[0-9]+ hist=[0-9]+ dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=0"
            if [ "$_what" = "file-data op" ]; then
                # (B5 review) a burst commits hundreds: each one checked, only a failure printed, then one summary line
                _wo=$(want "$_log" "$_pl" "$_what $_tk planned") || { echo "$_wo"; _ok=0; }
                _wo=$(want "$_log" "zfs-wtest: commit txg $_tk" "committed $_what $_tk") || { echo "$_wo"; _ok=0; }
                _fq=$((_fq + 1))
            else
                want "$_log" "$_pl" "$_what $_tk planned: ds=$_ds, one round, replans=$_rp loads=$_l pre=$_p reapply=$_q" || _ok=0
                want "$_log" "zfs-wtest: commit txg $_tk" "committed $_what $_tk" || _ok=0
            fi
            _l='[0-9]+'; _p=0; _q=0
        done
        [ "$_fq" -gt 0 ] && echo "    ok: $_fq file-data op txg(s) planned (ds=1, one round) and committed"
        # (B5 review, finding 5) every plan line's user data ALLOCATED <= the raw allocation the space predicates CHARGED
        # before the txg was dirtied (udata / charged): user data that never passed them — a grown block 0 the write
        # starts past, a truncation's boundary block — could fail its commit at the slop, the pool then read-only
        _uc=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg ([0-9]+) plan: .* udata=([0-9]+) charged=([0-9]+) fbpo=[0-9]+ hist=[0-9]+ dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2 \3 \4/p' \
            | awk '{ n++ } $2 > $3 { print "txg " $1 ": udata " $2 " > charged " $3 } END { print "n " n + 0 }')
        if [ "$(echo "$_uc" | grep -c '^txg ')" = 0 ]; then echo "    ok: every txg's user data was charged before it was dirtied (udata <= charged on $(echo "$_uc" | sed -n 's/^n //p') plan lines)"
        else echo "    FAIL: user data the space predicates never charged:"; echo "$_uc" | grep '^txg ' | head -5 | sed 's/^/      /'; _ok=0; fi
        _cok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: dataset cow ok\$")
        if [ "$_cok" = "$_nc" ]; then echo "    ok: $_nc dataset COW(s) ok (each incl. the read-back, the objset re-read from its new ds_bp, the top BP born in its txg, the block's SHA-256 unchanged)"
        else echo "    FAIL: $_cok of $_nc dataset COWs ok"; _ok=0; fi
        _nok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: null txg ok\$")
        if [ "$_nok" = "$_nn" ]; then echo "    ok: $_nn null txgs ok (each incl. the in-kernel read-back: the next mount's state load == what was published)"
        else echo "    FAIL: $_nok of $_nn null txgs ok"; _ok=0; fi
        # B5: every file-data op ok (or refused where the lane says so, --want), its txgs read back, its F line
        _bok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (write|trunc|burst) ok( refused \(.*\))?\$")
        if [ "$_bok" = "$_nb" ]; then echo "    ok: $_nb file-data op(s) as expected in $_nw txg(s) (each incl. the read-back of its last txg)"
        else echo "    FAIL: $_bok of $_nb file-data ops ok"; _ok=0; fi
        # B6: every create / mkdir / symlink op ok (or refused where the lane says so, --want), its txg read back; the
        # objects it made — `zfs-wtest: D <path>` / `L <path> <target>` as the reader sees them at T — in the expected
        # manifest (its F lines are held below with the writes')
        _c6=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (create|mkdir|symlink) ok( refused \(.*\))?\$")
        if [ "$_c6" = "$_n6" ]; then echo "    ok: $_n6 create / mkdir / symlink op(s) as expected (each incl. the read-back of its txg)"
        else echo "    FAIL: $_c6 of $_n6 create / mkdir / symlink ops ok"; _ok=0; fi
        # B7: every unlink / rmdir / rename / link op ok (or refused by name, --want), its txg read back and the namespace
        # after it checked in the kernel (`X <path>` gone, the new name's D / F / L line); every D11 fd line ok
        _c7=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (unlink|rmdir|rename|link) ok( refused \(.*\))?\$")
        if [ "$_c7" = "$_n7" ]; then echo "    ok: $_n7 unlink / rmdir / rename / link op(s) as expected (each incl. the read-back of its txg)"
        else echo "    FAIL: $_c7 of $_n7 unlink / rmdir / rename / link ops ok"; _ok=0; fi
        _cfd=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: fd /.* ok\$")
        if [ "$_cfd" = "$_nfd" ]; then [ "$_nfd" = 0 ] || echo "    ok: $_nfd fd check(s) — an fd across its object's removal / its number's reuse answers -1 (D11, k.41 / k.50)"
        else echo "    FAIL: $_cfd of $_nfd fd checks ok"; _ok=0; fi
        if [ $((_nb + _n6 + _n7)) -gt 0 ]; then
            # the namespace lines the ops printed (B6 / B7): the LAST D / F / L line of each path the expected manifest has
            # == its line there; a path it no longer has must be gone by a LATER op — an `X` line (unlink / rmdir /
            # rename's old name) for it or an ancestor after its last line; a file the reader cannot hash (zstd) prints
            # ERR and is the walk's to judge
            _nsb=$(slog "$_log" | python3 -I -c '
import io, re, sys
exp = {}
for l in open(sys.argv[1], encoding="utf-8", errors="surrogateescape"):
    l = l.rstrip("\n")
    if l[:2] in ("D ", "L "):
        exp[l[2:].split(" ", 1)[0]] = l
    elif l[:2] == "F ":
        exp[l[2:].rsplit(" ", 2)[0]] = l
last, gone, n, bad = {}, {}, 0, []
for raw in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="surrogateescape"):
    m = re.match(r"^(?:\[[^]]*\] )?zfs-wtest: ([DFLX]) (/.*)$", raw.rstrip("\n"))
    if not m:
        continue
    n += 1
    t, rest = m.group(1), m.group(2)
    if t == "X":
        gone[rest] = n
        continue
    if t == "F" and " ERR " in rest:
        continue
    p = rest.rsplit(" ", 2)[0] if t == "F" else rest.split(" ", 1)[0]
    last[p] = (n, t + " " + rest)
for p, (k, line) in sorted(last.items()):
    if p in exp:
        if exp[p] != line:
            bad.append("%s (expected %s)" % (line, exp[p]))
        continue
    q = p
    while q and gone.get(q, 0) <= k:
        q = q.rsplit("/", 1)[0]
    if not q:
        bad.append("%s: not in the expected manifest, and no later op removed it" % line)
print("n %d %d" % (len(last), len(gone)))
for b in bad:
    print("bad " + b)
' "$_exp")
            if [ "$(echo "$_nsb" | grep -c '^bad ')" = 0 ]; then echo "    ok: every D / F / L line the ops printed is the expected manifest's or a later op removed it ($(echo "$_nsb" | sed -n 's/^n \([0-9]*\) \([0-9]*\)$/\1 paths, \2 X lines/p'))"
            else
                echo "    FAIL: D / F / L lines the expected manifest does not have:"; echo "$_nsb" | grep '^bad ' | head -5 | sed 's/^bad /      /' | cut -c1-200
                if [ "${ZWS_SPACE:-}" = advisory ]; then echo "    D / F / L lines: red but ADVISORY (ZWS_SPACE=advisory, a negative proof)"; else _ok=0; fi
            fi
        fi
        # B7 (design § e.2): the txgs that DEFERRED kills to free_bpobj (plan line fbpo > 0 — gang / dedup / clone blocks)
        # are exactly the ones the lane says (--fbpo), and Σ fbpo is what $FREE must hold on the image (uacct --freeing)
        _fbn=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* fbpo=([1-9][0-9]*) hist=[0-9]+ dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2/p' | wc -l)
        _fbs=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* fbpo=([0-9]+) hist=[0-9]+ dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2/p' | awk '{s += $1} END {print s + 0}')
        if [ "$_fbn" = "$_fbt" ]; then [ "$_fbt" = 0 ] || echo "    ok: $_fbn txg(s) deferred kills to free_bpobj, $_fbs B in all (gang blocks: design § e.2)"
        else echo "    FAIL: $_fbn txg(s) deferred kills to free_bpobj (fbpo > 0), the lane says $_fbt"; _ok=0; fi
        # B7 (design k.68): the txgs that LOWERED a metaslab's space map histogram (plan line hist > 0)
        _hn=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* hist=([1-9][0-9]*) dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2/p' | wc -l)
        _hs=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* hist=([0-9]+) dl=[0-9]+ dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2/p' | awk '{s += $1} END {print s + 0}')
        if echo "$_hn" | grep -qxE "$_hst"; then echo "    ok: $_hn txg(s) lowered $_hs space map histogram(s) — the metaslabs whose largest free segments they consumed (design k.68)"
        else echo "    FAIL: $_hn txg(s) lowered a space map histogram (hist > 0), the lane says /$_hst/"; _ok=0; fi
        # B9 (design § e.2 branch B): the txgs that DEADLISTED kills (plan line dl > 0 — blocks a snapshot or a clone's
        # origin still owns: appended to the head's deadlist, never freed) number what the lane says (--dl, an ERE;
        # default 0 — a pool with no snapshotted dataset deadlists nothing), and so do the entries they MATERIALISED from
        # the shared empty_bpobj (Σ mat, --mat)
        _dln=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* dl=([1-9][0-9]*) dlu=[0-9]+ mat=[0-9]+ dlx=[0-9]+$/\2/p' | wc -l)
        _dls=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* dl=[0-9]+ dlu=([0-9]+) mat=[0-9]+ dlx=[0-9]+$/\2/p' | awk '{s += $1} END {print s + 0}')
        _mts=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg [0-9]+ plan: .* dl=[0-9]+ dlu=[0-9]+ mat=([0-9]+) dlx=[0-9]+$/\2/p' | awk '{s += $1} END {print s + 0}')
        if echo "$_dln" | grep -qxE "$_dlt" && echo "$_mts" | grep -qxE "$_mtt"; then [ "$_dln" = 0 ] || echo "    ok: $_dln txg(s) deadlisted the kills of blocks a snapshot owns, $_dls B in all; $_mts deadlist entr(ies) materialised from empty_bpobj"
        else echo "    FAIL: $_dln txg(s) deadlisted kills (dl > 0) with $_mts materialised, the lane says /$_dlt/ and $_mtt"; _ok=0; fi
        # (B9 review, design k.100) every deadlist append of every txg was COUNTED by an admission (plan line dlx=0): its
        # deadlist loaded, and every refusal of it judged, before the commit — never inside it, where a refusal fails
        # the pool (each plan line above is held to dlx=0 too; this names the txgs)
        _dlx=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: txg ([0-9]+) plan: .* dlx=([0-9]+)$/\2 \3/p' | awk '$2 != 0 { printf "%s txg %s dlx=%s", s, $1, $2; s = ";" }')
        if [ -z "$_dlx" ]; then [ "$_dln" = 0 ] || echo "    ok: every deadlist append was counted at its op's admission (dlx=0 on every plan line)"
        else echo "    FAIL: deadlist appends no admission counted —$_dlx"; _ok=0; fi
        # B10 (design § c.5, k.63): every drain op ok — its objects freed, the named refusals the lane's --want lines name
        _cdq=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: drain ok( refused \(.*\))?\$")
        if [ "$_cdq" = "$_nd" ]; then [ "$_nd" = 0 ] || echo "    ok: $_nd drain op(s) — the DELETE_QUEUE objects agnos frees itself (k.63), each read back"
        else echo "    FAIL: $_cdq of $_nd drain ops ok"; _ok=0; fi
        # B10 (design § c.5): every commit's HYGIENE line — metaslabs flushed / bumped, logs destroyed, logs alive after it
        # (zfs_wt_stats): one per plan line; never more than the design's 16 logs alive after a txg (the kernel aims at
        # ZWL_TXGMAX 14 — two txgs of slack for txgs too full to flush, design k.115); a lane of 20+ txgs
        # flushed and destroyed; the final image holds exactly the last line's logs (the host replay counts them, below)
        _hy=$(slog "$_log" | awk '{ sub(/^\[[^]]*\] /, "") } $1 == "zfs-wtest:" && $2 == "txg" && $4 == "hygiene:" {
                for (i = 5; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
                n++; f += v["flushed"]; b += v["bumped"]; d += v["destroyed"]; fo += v["fonly"]; sf += v["self"]; sk += (v["skip"] > 0)
                if (v["skip"] > 0 && v["flushed"] == 0) { z++; zr++; if (zr > zm) zm = zr } else zr = 0
                if (v["rsv"] > rv) rv = v["rsv"]
                if (v["ghosts"] > gm) gm = v["ghosts"]
                if (v["logs"] > mx) mx = v["logs"]; last = v["logs"]; g = v["ghosts"]; gg = v["gang"] }
            END { printf "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", n, f, b, d, mx, last, fo, sf, sk, g, gg, z, rv, zm, gm }')
        read -r _hn _hf _hb _hd _hmx _hlast _hfo _hsf _hsk _hg _hgg _hz _hrv _hzm _hgm <<< "$_hy"
        # (the merge, k.133 (a)) the GHOSTS are bounded: a destroyed log is kept only while its txg is inside B11's
        # deferral window and zfs_wdef_rel retires it — at most the window's logs (3: the mount's T0 - 2 .. T0) alive on
        # any hygiene line, and the list's `ghost logs:` line made = retired + alive (B10 alone kept every ghost for the
        # boot: ~2,000 txgs to its table's limit, k.122)
        _gl=$(slog "$_log" | sed -n -E 's/^(\[[^]]*\] )?zfs-wtest: ghost logs: made=([0-9]+) retired=([0-9]+) alive=([0-9]+)$/\2 \3 \4/p' | tail -1)
        read -r _gmk _gret _galv <<< "${_gl:-x x x}"
        _np=$((_t4 - _t0 - 1))
        if [ "$_hn" != "$_np" ]; then echo "    FAIL: $_hn hygiene line(s) for $_np planned txg(s)"; _ok=0
        elif [ "$_hmx" -gt 16 ]; then echo "    FAIL: up to $_hmx log space maps alive after a txg (the design's bound is 16)"; _ok=0
        elif [ "$_hgm" -gt 3 ]; then echo "    FAIL: up to $_hgm ghost logs on a hygiene line (the window holds 3, k.133 (a))"; _ok=0
        elif [ "$_gmk" = x ] || [ "$_galv" -gt 3 ] || [ "$_gmk" -ne $((_gret + _galv)) ]; then echo "    FAIL: ghost logs made=$_gmk retired=$_gret alive=$_galv (want alive <= 3 = made - retired, k.133 (a))"; _ok=0
        # (B10 review, k.119) every admission after a txg's first unit holds hygiene's minimum back (the hygiene line's
        # rsv=), so no TWO txgs in a row may skip their first flush (skip > 0 with flushed=0: a txg that moved no U) —
        # the review's case, a long truncation / drain / deferred-kill run growing the logs by one a txg up to
        # ZWK_MAXLOG; one alone is an op whose first unit filled its txg (B9's edge p.bin on wr: bounded slack)
        elif [ "$_hzm" -gt 1 ]; then echo "    FAIL: $_hzm txgs in a row skipped their first flush (skip > 0, flushed=0): hygiene's minimum did not hold"; _ok=0
        elif [ "$_np" -ge 20 ] && { [ "$_hf" = 0 ] || [ "$_hd" = 0 ]; }; then echo "    FAIL: $_np txgs flushed $_hf metaslab(s) and destroyed $_hd log(s)"; _ok=0
        else echo "    ok: log hygiene on $_hn txg(s): $_hf flush(es) ($_hfo of FREEs only, $_hsf of a metaslab holding its own space map's block), $_hb bump(s), $_hd log(s) destroyed (ghosts: $_gmk made, $_gret retired, at most $_hgm on a line, $_galv at the end), at most $_hmx alive, $_hlast at the end; $_hsk txg(s) skipped a flush ($_hz their first, never two in a row); $_hgg MOS gang predecessor(s) freed; hygiene's minimum held back up to $_hrv B"; fi
        for _w in "${_wants[@]}"; do want "$_log" "$_w" "$_w" || _ok=0; done
        want "$_log" "zfs-wtest: done txg=$_t4 ops=$_ops fails=0" "op list done, txg $_t4, no failure" || _ok=0
        _aud="--final-txg $_t4 --same-rootbp $_t1"         # T0+1 names T0's rootbp, every null txg a new MOS
        # each commit's hold time from the kernel's own log timestamps (design § k.8 — a measurement, not a gate): the
        # ub-only commit begin -> its commit line; every other txg from its op's begin (its first) or the txg before
        # (B5 review: a multi-txg write or a burst prints its commit lines at its end) to its plan line, printed at the
        # publish = the dirtying + the plan + flush + 4 slot writes + flush, under fs_lock with IF=0 — fs_lock is
        # released between two txgs of one write (zfs_wf_yield), so this is the longest any other CPU waits. (B10) A txg
        # after another of the same op counts from the other's HYGIENE line (the op list's stats, printed after its plan
        # line — not commit work), and a drain's (k.63) from its begin or the object line before it
        _ms=$(slog "$_log" | awk -F'[][]' '
            /zfs-wtest: begin txg=/ {b = $2; ub = 1}
            /zfs-wtest: commit txg/ && ub {u = ($2 - b) * 1000; ub = 0}
            /zfs-wtest: (null txg|dataset cow|write|trunc|burst|create|mkdir|symlink|unlink|rmdir|rename|link|drain) begin/ {p = $2}
            /zfs-wtest: drain \/.* object [0-9]+: / {p = $2}
            /zfs-wtest: txg [0-9]+ plan:/ { if (p != "") { d = ($2 - p) * 1000; n++; if (n == 1 || d < mn) mn = d; if (d > mx) mx = d; t += d }; p = $2 }
            /zfs-wtest: txg [0-9]+ hygiene:/ {p = $2}
            END { if (n) printf "ub-only %d ms; %d txgs %d-%d ms each (mean %d)", u, n, mn, mx, t / n }')
        [ -n "$_ms" ] && echo "    commit hold: $_ms ($_dev)" ;;
    wfail)
        want "$_log" "zfs: pool $_pool txg $_t0 .*" "mounted at the pristine best txg $_t0" || _ok=0
        want "$_log" "zfs: $_pool rw" "the gate saw no write protection (QEMU's nvme reports none)" || _ok=0
        want "$_log" "zfs-wb3: done ok" "B3a's in-memory exercise passed (it writes nothing)" || _ok=0
        want "$_log" "zfs: commit txg $_t1 failed: uberblock write to label L0 - pool read-only until reboot" "the commit's first write failed by name (zfs_wfail)" || _ok=0
        want "$_log" "zfs-wtest: ub-only commit FAIL uberblock write to label L0" "the op failed by name" || _ok=0
        _nok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: null txg ok refused \(pool read-only\)\$")
        if [ "$_nok" = 3 ]; then echo "    ok: the 3 null txgs refused (the pool went read-only)"; else echo "    FAIL: $_nok of 3 null txgs refused"; _ok=0; fi
        _cok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: dataset cow ok refused \(pool read-only\)\$")
        if [ "$_cok" = "$_nc" ]; then echo "    ok: the $_nc dataset COW(s) refused (the pool went read-only), nothing written"; else echo "    FAIL: $_cok of $_nc dataset COWs refused"; _ok=0; fi
        _bok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (write|trunc|burst) ok refused \(pool read-only\)\$")
        if [ "$_bok" = "$_nb" ]; then echo "    ok: the $_nb file-data op(s) refused (the pool went read-only), nothing written"; else echo "    FAIL: $_bok of $_nb file-data ops refused"; _ok=0; fi
        # B6: every create / mkdir / symlink refused — "pool read-only", or an earlier reason open#7 gives first (AO_EXCL
        # on an existing name); h4 below holds the partition byte-identical whatever the reason
        _c6=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (create|mkdir|symlink) ok refused \(.*\)\$")
        if [ "$_c6" = "$_n6" ]; then echo "    ok: the $_n6 create / mkdir / symlink op(s) refused, nothing written"; else echo "    FAIL: $_c6 of $_n6 create / mkdir / symlink ops refused"; _ok=0; fi
        _c7=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: (unlink|rmdir|rename|link) ok refused \(.*\)\$")
        if [ "$_c7" = "$_n7" ]; then echo "    ok: the $_n7 unlink / rmdir / rename / link op(s) refused, nothing written"; else echo "    FAIL: $_c7 of $_n7 unlink / rmdir / rename / link ops refused"; _ok=0; fi
        want "$_log" "zfs-wtest: done txg=$_t0 ops=$_ops fails=1" "op list done, txg unchanged, the one failure counted" || _ok=0
        _aud="--identical" ;;
    refused)
        want "$_log" "zfs: pool $_pool txg $_t0 .*" "mounted at the pristine best txg $_t0" || _ok=0
        want "$_log" "zfs: $_pool read-only \\($_why\\)" "refused by the gate: $_why" || _ok=0
        want "$_log" "zfs-wtest: ub-only commit ok refused \\(pool read-only\\)" "the commit refused on a read-only pool" || _ok=0
        _nok=$(slog "$_log" | grep -cE "^(\[[^]]*\] )?zfs-wtest: null txg ok refused \(pool read-only\)\$")
        if [ "$_nok" = 3 ]; then echo "    ok: the 3 null txgs refused"; else echo "    FAIL: $_nok of 3 null txgs refused"; _ok=0; fi
        want "$_log" "zfs-wtest: done txg=$_t0 ops=4 fails=0" "op list done, txg unchanged" || _ok=0
        _aud="--identical" ;;
    nopool)
        want "$_log" "zfs-wtest: no pool" "no pool mounted, the op list did nothing" || _ok=0
        _aud="--identical" ;;
    esac
    if [ "$_kind" != wfail ] && slog "$_log" | grep -qE "zfs: commit txg [0-9]+ failed"; then echo "    FAIL: a commit failed (above)"; _ok=0; fi
    # agnos reads back its own write: the walk runs after the op list (a ub-only commit changes no content); a raidz
    # child mounts nothing, and the walk must say why (zfs-smoke.sh's raidz-0 rule)
    if [ "$_kind" = cut ]; then
        echo "    (no walk: the kernel halted inside the cut txg — OpenZFS's phase B holds the pool to the expected manifest)"
        true
    elif [ "$_kind" = nopool ]; then
        python3 -I "$ROOT/scripts/smoke/lib/zfs-manifest-diff.py" "$_log" "$FIX/$_img.manifest" "$FIX/$_img.summary" \
            --expect-refusal "vdev type raidz unsupported" 2>&1 | sed 's/^/    /'
    else
        python3 -I "$ROOT/scripts/smoke/lib/zfs-manifest-diff.py" "$_log" "$_exp" "$FIX/$_img.summary" 2>&1 \
            | sed 's/^/    /'
    fi
    if [ "${PIPESTATUS[0]}" != "0" ]; then
        # B5: a writer lane's walk is held to the EXPECTED manifest — red under a negative proof is advisory too
        if [ "${ZWS_SPACE:-}" = advisory ] && [ "$_kind" = rw ]; then echo "    walk: red but ADVISORY (ZWS_SPACE=advisory, a negative proof)"; else _ok=0; fi
    fi
    # the host audit on the whole disk: h1-h3 (+ h4 when nothing may change) on the partition against the PRISTINE
    # fixture image — so a torn lane's tear must be gone, rewritten by the commit — and h5 outside it (a grown
    # partition's tail included) against the disk as it was before the boot
    # shellcheck disable=SC2086 # _aud is deliberately word-split
    python3 -I "$AUDIT" "$_ref" "$_d" --offset "$POFF" --before "$_bf" $_aud > "$LOGS/$_name.audit" 2>&1
    _arc=$?
    sed 's/^/    /' "$LOGS/$_name.audit"
    [ "$_arc" = 0 ] || _ok=0
    # the space record of what the lane wrote, replayed on the host in OpenZFS's model (scripts/smoke/lib/
    # zfs-wms-check.py --replay — the audit's h6): every log strict, smp_alloc == entries, the refcount, and no log
    # entry for a metaslab whose U is 0, which zdb and the guest's imports let through (design § i.4, B3b's N3)
    _fin="${WORK:?}/${_name:?}.final"
    if [ "$_kind" = rw ] || [ "$_kind" = cut ]; then
        dd if="$_d" of="$_fin" bs=512 skip=67584 count="$_sec" conv=sparse status=none
        python3 -I "$ROOT/scripts/smoke/lib/zfs-wms-check.py" --replay "$_fin" > "$LOGS/$_name.space" 2>&1
        _src_rc=$?
        sed 's/^/    /' "$LOGS/$_name.space" | cut -c1-200
        # (B10) the image holds exactly the logs the last commit left alive (its hygiene line)
        _ilogs=$(sed -n 's/.* logs=\([0-9]*\) sm_alloc=.*/\1/p' "$LOGS/$_name.space" | head -1)
        if [ "$_src_rc" = 0 ] && [ -n "${_hlast:-}" ] && [ "$_ilogs" != "$_hlast" ]; then
            echo "    FAIL: the image holds $_ilogs log space map(s), the last commit's hygiene line $_hlast"; _src_rc=1
        fi
        if [ "$_src_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
            echo "    space: red but ADVISORY (ZWS_SPACE=advisory, a negative proof) — the image still goes to the guest"
        elif [ "$_src_rc" != 0 ]; then _ok=0; fi
        # B4: what no zfs tool checks, recounted on the host from every dnode (scripts/smoke/lib/zfs-uacct-check.py —
        # the audit's h7): every dn_used == Σ dsize of its tree (design § k.14), every head dataset's referenced ==
        # Σ dn_used + its objset block, and the user / group / project-used ZAPs == a recount (design § e.3); every
        # dsl_dir's breakdown and every head's ds_unique_bytes (B4 review: the refreservation split)
        python3 -I "$ROOT/scripts/smoke/lib/zfs-uacct-check.py" "$_fin" --freeing "${_fbs:-0}" > "$LOGS/$_name.uacct" 2>&1
        _uac_rc=$?
        grep -E '^uacct: (PASS|FAIL)|FAIL' "$LOGS/$_name.uacct" | sed 's/^/    /' | cut -c1-240
        if [ "$_uac_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
            echo "    uacct: red but ADVISORY (ZWS_SPACE=advisory, a negative proof) — the image still goes to the guest"
        elif [ "$_uac_rc" != 0 ]; then _ok=0; fi
        # B5: hole births (scripts/smoke/lib/zfs-hole-check.py — the audit's h8, design § k.12): every hole a changed
        # object holds where the start image had a block (or a punched hole) carries a birth; zdb never looks
        # (B5 review, finding 7(4)) every hole the writer punched carries free_blocks' LSIZE, and — with the serial log —
        # its birth is the txg of an op that freed or zeroed that file (no extra birth: a plain write stamps none)
        _hops=(); [ -s "$_opsf" ] && _hops=(--log "$_slog" "$_exp" "$FIX/$_img.objects")
        python3 -I "$ROOT/scripts/smoke/lib/zfs-hole-check.py" "$_fin" "$_ref" "${_hops[@]}" > "$LOGS/$_name.holes" 2>&1
        _hol_rc=$?
        grep -E '^holes:' "$LOGS/$_name.holes" | head -6 | sed 's/^/    /' | cut -c1-240
        if [ "$_hol_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
            echo "    holes: red but ADVISORY (ZWS_SPACE=advisory, a negative proof) — the image still goes to the guest"
        elif [ "$_hol_rc" != 0 ]; then _ok=0; fi
        # (B8) every ZAP of the written pool held to the fat-ZAP structure rules (scripts/smoke/lib/zfs-fatzap-check.py — the
        # audit's h9): the pointer table's coverage (each leaf exactly its prefix's range), every leaf's free list, counts,
        # hash chains and arrays, zap_num_entries == Σ lh_nentries, the hashes recomputed from the names, every salt
        # non-zero and an upgraded microzap's salt kept (against the start image)
        python3 -I "$ROOT/scripts/smoke/lib/zfs-fatzap-check.py" "$_fin" "$_ref" > "$LOGS/$_name.fatzap" 2>&1
        _fz_rc=$?
        grep -E '^fatzap:' "$LOGS/$_name.fatzap" | head -6 | sed 's/^/    /' | cut -c1-240
        if [ "$_fz_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
            echo "    fatzap: red but ADVISORY (ZWS_SPACE=advisory, a negative proof) — the image still goes to the guest"
        elif [ "$_fz_rc" != 0 ]; then _ok=0; fi
        # (B5 review, finding 7(1)) what the stamps say: every written file's MTIME / CTIME == the op list's clock, FLAGS
        # | ARCHIVE | AV_MODIFIED, SIZE, the rest of its SA untouched; a COW-only file SA-identical (zfs-sa-check.py)
        if [ $((_nb + _n6)) -gt 0 ] || [ "$_kind" = cut ]; then
            python3 -I "$ROOT/scripts/smoke/lib/zfs-sa-check.py" "$_ref" "$_fin" "$_exp" "$FIX/$_img.objects" "$_slog" > "$LOGS/$_name.sa" 2>&1
            _sa_rc=$?
            grep -E '^sa:' "$LOGS/$_name.sa" | head -6 | sed 's/^/    /' | cut -c1-240
            if [ "$_sa_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
                echo "    sa: red but ADVISORY (ZWS_SPACE=advisory, a negative proof) — the image still goes to the guest"
            elif [ "$_sa_rc" != 0 ]; then _ok=0; fi
        fi
        # (B5 review, finding 7(2)) a write cut SHORT at ENOSPC (--room "<op> <path> <block asize> <copies>"): its length
        # held to the space record on the host — at most the room it started with, and less than one block left when it
        # stopped (zfs-room-check.py)
        if [ -n "$_room" ]; then
            set -- $_room
            _rm=$(slog "$_log" | awk -v k="$1" -v p="$2" '{ sub(/^\[[^]]*\] /, "") }
                $1 == "zfs-wtest:" && $2 == k && $3 == "begin" && $5 == p { split($4, a, "="); t = a[2] }
                $1 == "zfs-wtest:" && $2 == k && $3 == p && $4 == "->" && $5 > 0 && !d { split($6, b, "="); print t, t + b[2] - 1, $5; d = 1 }')
            if [ -z "$_rm" ]; then echo "    FAIL: room — no short $1 to $2 in the log"; _ok=0
            else
                # shellcheck disable=SC2086 # _rm is "TF TL L"
                python3 -I "$ROOT/scripts/smoke/lib/zfs-room-check.py" "$_ref" "$_fin" $_rm $(( $3 * $4 )) "$4" ${5:+"$5"} --log "$_log" > "$LOGS/$_name.room" 2>&1
                _rm_rc=$?
                grep -E '^room:' "$LOGS/$_name.room" | head -4 | sed 's/^/    /' | cut -c1-260
                if [ "$_rm_rc" != 0 ] && [ "${ZWS_SPACE:-}" = advisory ]; then
                    echo "    room: red but ADVISORY (ZWS_SPACE=advisory, a negative proof)"
                elif [ "$_rm_rc" != 0 ]; then _ok=0; fi
            fi
        fi
    fi
    if [ -n "$_same" ]; then
        if [ ! -f "$VDIR/$_same.img" ]; then echo "    FAIL: no $_same result to compare with (that lane did not pass)"; _ok=0
        elif cmp -s -n "$(( _sec * 512 ))" -i "$POFF:0" "$_d" "$VDIR/$_same.img"; then
            echo "    same: the pool partition is byte-identical to lane $_same's (which OpenZFS judges below)"
        else
            echo "    FAIL: the pool partition differs from lane $_same's: $(cmp -n "$(( _sec * 512 ))" -i "$POFF:0" "$_d" "$VDIR/$_same.img" 2>&1 | head -1)"
            _ok=0
        fi
    elif { [ "$_kind" = rw ] || [ "$_kind" = cut ]; } && { [ "$_ok" = 1 ] || [ "${ZWS_SPACE:-}" = advisory ]; }; then
        # (B6) under ZWS_SPACE=advisory (a negative proof, PARTIAL) a FAILED rw lane's image goes to the guest too — a
        # mutant that breaks the op list's own lines (a reused dnode slot) must still show which OpenZFS phase sees it
        [ "$_ok" = 1 ] || echo "    image: the lane FAILED, but goes to the guest (ZWS_SPACE=advisory, a negative proof)"
        mv "$_fin" "$VDIR/$_name.img"
        echo "$_t4" > "$VDIR/$_name.txg"
        # what the op list rewrote, for the guest's phase C to work on (appends / overwrites / removes agnos's blocks
        # through OpenZFS's own space maps — C acts on the ROOT dataset's files only)
        for _tp in $_touch; do echo "F $_tp"; done > "$VDIR/$_name.touched"
        if [ -s "$_opsf" ]; then
            cp "$_opsf" "$VDIR/$_name.ops"
            [ -d "$_orig" ] && cp -r "$_orig" "$VDIR/$_name.orig"
        fi
        [ "$_ref" != "$_fi" ] && cp --sparse=always "$_ref" "$VDIR/$_name.pristine"
        [ "$_clab" -gt 0 ] && echo "$_clab" > "$VDIR/$_name.cutlabels"   # (B11) the guest's H: --cut-labels
        rwlanes="$rwlanes $_name"
    fi
    if [ "$_ok" = "1" ]; then echo "  PASS (boot + audit): $_name"; else echo "  FAIL: $_name ($_log)"; rc=1; fi
    rm -f "$_d" "$_bf" "$_pc" "$_fin"
    rm -rf "${_orig:?}"
}

# B6: what each pool's create ops must show on disk — the parent microzap's growth (ashift9's b6/many: 9 entries,
# 512 -> 1024 B), the meta-dnode's growth past its dn_maxblkid (main's coff/kid: 55 free slots in 2 blocks, the 56th
# create in a NEW dnode block 2 of 3) — and every refusal by its name
B6A=(--want "zfs-wtest: create /agnos9/b6/many/f08 object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 1024 B"
     --want "zfs-wtest: symlink /agnos9/b6/link object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 512 B"
     --want "zfs-wtest: symlink /agnos9/b6/l144 object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 512 B"
     --want "zfs-wtest: L /agnos9/b6/l144 a-symlink-target-of-exactly-144-bytes-the-most-a-512-byte-dnode-bonus-holds-with-3-aces-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
     --want "zfs-wtest: symlink ok refused \(symlink target empty or over 144 bytes \(spill creation not built\): 145\)"
     --want "zfs-wtest: create ok refused \(name exists \(AO_CREAT \| AO_EXCL: EEXIST\)\)"
     --want "zfs-wtest: create /agnos9/b6/a-name-of-fifty-bytes-past-the-microzap-limit-nnnn object [0-9]+, dnode block [0-9]+ of [0-9]+, parent fat ZAP 16384 B: 1 leaf\(s\), table 2\^10 embedded, freeblk 2, 5 entries; 1 ZAP upgrade\(s\)")
# B7: what each pool's unlink / rmdir / rename / link ops must show — where each object went (freed, links left, moved,
# the target freed, nothing to do), and every refusal by its name
# (B7 review, finding 3) and the paths the first list never ran: a rename of an empty directory over another across
# parents (b7s -> b6/b7t: the target freed, both parents' LINKS); the LAZY route (the knob zfs_wu_tight at 1) for a
# rename's target (rs.txt -> lz2.bin) and for a DIRECTORY (lzd, an rmdir under an AO_DIRECTORY fd: getdents -1 although
# its generation matches — finding 4's zfs_fd_live); an object holding an extended-attribute DIRECTORY (xd.txt, fixture
# RECIPE 6: xattr=dir) — LAZY by ZPL_XATTR, as zfs_rmnode purges it
B7A=(--want "zfs-wtest: unlink /agnos9/b6/many/f00 object [0-9]+: freed"
     --want "zfs-wtest: rmdir /agnos9/b6empty object [0-9]+: freed"
     --want "zfs-wtest: rename /agnos9/dir20/e03 object [0-9]+: moved \(the target object [0-9]+ freed\)"
     --want "zfs-wtest: rename /agnos9/rs.txt object [0-9]+: moved \(the target object [0-9]+ on the DELETE_QUEUE\)"
     --want "zfs-wtest: rmdir /agnos9/lzd object [0-9]+: on the DELETE_QUEUE"
     --want "zfs-wtest: fd /agnos9/lzd object [0-9]+ after its removal: getdents -1 ok"
     --want "zfs-wtest: rename /agnos9/b7s object [0-9]+: moved \(the target object [0-9]+ freed\)"
     --want "zfs-wtest: unlink /agnos9/xd.txt object [0-9]+: on the DELETE_QUEUE"
     --want "zfs-wtest: rename /agnos9/dir20/e09 object [0-9]+: nothing to do \(one object\)"
     --want "zfs-wtest: link /agnos9/dir20/e05 object [0-9]+: 2 link\(s\)"
     --want "zfs-wtest: unlink /agnos9/b6/e07 object [0-9]+: 1 link\(s\)"
     --want "zfs-wtest: rmdir ok refused \(directory not empty \(ENOTEMPTY\): SIZE [0-9]+\)"
     --want "zfs-wtest: rename ok refused \(a directory into its own subtree \(EINVAL\)\)"
     --want "zfs-wtest: unlink ok refused \(unlink of a directory \(EPERM: rmdir\)\)"
     --want "zfs-wtest: rmdir ok refused \(rmdir of a non-directory \(ENOTDIR\)\)"
     --want "zfs-wtest: link ok refused \(link of a directory \(EPERM\)\)"
     --want "zfs-wtest: rename ok refused \(rename of a non-directory over a directory \(EISDIR\)\)")
# B10 (design § c.5, k.63): ashift9's drain of the root DELETE_QUEUE B7 left — two objects freed, xd.txt refused by name —
# and both of § c.5's flush cases on disk: a delta of FREEs only, and a metaslab holding a copy of its own space map's
# block (whose COW frees it in log T)
B10A=(--want "zfs-wtest: drain /agnos9 object [0-9]+: freed txgs=1 parts=0"
      --want "zfs-wtest: drain /agnos9 object [0-9]+: refused \(an object holding an extended-attribute directory \(zfs_rmnode's purge: not built\)\)"
      --want "zfs-wtest: txg [0-9]+ hygiene: flushed=[1-9][0-9]* .* fonly=[1-9][0-9]* .*"
      --want "zfs-wtest: txg [0-9]+ hygiene: flushed=[1-9][0-9]* .* self=[1-9][0-9]* .*"
      --want "zfs-wtest: ghost logs: made=[1-9][0-9]* retired=[1-9][0-9]* alive=[0-3]")
# (the merge, k.133 (a)) the last want: agnos9's last null txg flushes every dirty metaslab (zfs_wt_flall), so logs T - 1
# and T - 2 are destroyed inside B11's deferral window — GHOSTS made, T - 2's released and retired by T's own publish
# B11 (design § h B11, § b.2 D1 (b)): what each policy-B op must show — 8 x 64 KiB through one fd is 8 txgs under policy
# A and ONE under B (committed by the close); a read through another fd of the pending object commits it first, a read of
# another file does not; sync#12 and the age bound commit a pending write; 4.5 MiB through one fd commits at the arena's
# threshold and goes on; (k.40) a block freed in txg P is not reused by P + 2 and is by P + 3 — the release op's own check
B11A=(--want "zfs-wtest: b11 cp /agnos9/b11/a.bin: 8 x 65536 through one fd, policy A, 8 txg\(s\): 8 during the writes, pending at close 0"
      --want "zfs-wtest: b11 cp /agnos9/b11/b.bin: 8 x 65536 through one fd, policy B, 1 txg\(s\): 0 during the writes, pending at close 1"
      --want "zfs-wtest: b11 observe /agnos9/b11/b.bin: write pending \(txg 0 committed\), a read of another file left it pending \(0\), a read through another fd committed it first \(1\) and read the new bytes: ok"
      --want "zfs-wtest: b11 sync /agnos9/b11/b.bin: a pending write committed by the sync hook, the fd open; its close committed nothing: ok"
      --want "zfs-wtest: b11 age /agnos9/b11/b.bin: a pending write committed by the age hook, the fd open; its close committed nothing: ok"
      --want "zfs-wtest: b11 arena /agnos9/b11/big.bin: 72 x 65536 through one fd, policy B, [2-9] txg\(s\): [1-8] during the writes, pending at close 1"
      --want "zfs-wtest: b11 release /agnos9/b11/a.bin: block 0 at [0-9]+ \(131072 B\) freed in txg [0-9]+; txg [0-9]+'s block at [0-9]+ \(deferred\), txg [0-9]+'s at [0-9]+ \(released\): ok"
      --want "zfs-wtest: b11 race /agnos9/b11/big.bin: 4718592 bytes in ONE write#1 through fd X, [2-9] txgs; /agnos9/b11/a.bin: 4096 bytes written through fd Y in the gap \(pending\) committed before X went on, read back: ok"
      --want "zfs-wtest: txg [0-9]+ b11: hold=[0-9]+ irqmax=[0-9]+ windows=0 rel=[0-9]+ lo=[0-9]+ defer=[0-9]+ by=yield"
      --want "zfs-wtest: txg [0-9]+ b11: hold=[0-9]+ irqmax=[0-9]+ windows=0 rel=[0-9]+ lo=[0-9]+ defer=[0-9]+ by=close"
      --want "zfs-wtest: txg [0-9]+ b11: hold=[0-9]+ irqmax=[0-9]+ windows=0 rel=[0-9]+ lo=[0-9]+ defer=[0-9]+ by=observe"
      --want "zfs-wtest: txg [0-9]+ b11: hold=[0-9]+ irqmax=[0-9]+ windows=0 rel=[0-9]+ lo=[0-9]+ defer=[0-9]+ by=sync"
      --want "zfs-wtest: txg [0-9]+ b11: hold=[0-9]+ irqmax=[0-9]+ windows=0 rel=[0-9]+ lo=[0-9]+ defer=[0-9]+ by=age")
# (B11) agnos9's list grew by B11's ops (≈ 30 txgs, 4.5 MiB through one fd): 600 s, the per-sector AHCI / USB paths 900
lane ashift9       agnos9    rw      --cows 1 --timeout 600 --touched "/agnos9/rand-2m.bin" "${B6A[@]}" "${B7A[@]}" "${B10A[@]}" "${B11A[@]}"
lane ashift9-torn  agnos9    rw      --cows 1 --timeout 600 --img ashift9 --tear      --same-as ashift9
lane ashift9-grown agnos9    rw      --cows 1 --timeout 600 --img ashift9 --extra 255 --same-as ashift9
lane ashift9-ahci  agnos9    rw      --cows 1 --timeout 900 --img ashift9 --dev ahci  --same-as ashift9
lane ashift9-usb   agnos9    rw      --cows 1 --timeout 900 --img ashift9 --dev usb   --same-as ashift9
lane ashift9-ro    agnos9    wfail   --cows 1 --timeout 600 --img ashift9 --dev nvme-ro
# ⭐ B11 (design § b.3, § h B11): CRASH CUTS. The agnos9 image booted with /boot/cmdline `zfs_cut=CLASS:N` runs the cut
# list (zfs_wt_cutlist): mkdir, create, three policy-B closes (txgs T0+1 .. T0+5), then — the allocator's cursor on a
# 128 KiB block txg T0+4 freed — the knob armed and txg T0+6 committed until N device writes of CLASS, where the kernel
# halts. OpenZFS must import EXACTLY T0+5 (ashift9@cut-data: after its first data block; ashift9@cut-mos: after its first MOS-chain
# block) — every T0+6 block went to space T0+5 calls free, nothing T0+5, T0+4 or T0+3 references was written (A4 rewinds
# to T0+4 and T0+3: a free released one txg early puts T0+6's block on the one T0+3 still names) — or, once a copy of
# uberblock T0+6 landed (ashift9@cut-ub1: L0 only; ashift9@cut-ub3: L0-L2 — the verify takes a lane's base image from
# its name before the '@'), T0+6, whose blocks the commit's first flush made durable.
# (the merge, k.133 (e)) every cut txg runs B10's hygiene first: its flush is cut before its appends are written (data),
# after them (mos) or lands with uberblock T0+6 (ub1 / ub3) — each lane requires the halt's own hygiene line, flushed >= 1
lane ashift9@cut-data   agnos9    cut     --img ashift9 --cut data:1 --cutfinal 5 --timeout 600 \
                                     --want "zfs-wtest: cut txg [0-9]+ after 1 device writes \(data 1, dataset metadata 0, MOS 0, MOS chain 0, uberblock 0\), before a .* write - halted" \
                                     --want "zfs-wtest: cut txg [0-9]+ hygiene: flushed=[1-9][0-9]* .*"

lane ashift9@cut-mos    agnos9    cut     --img ashift9 --cut chain:1 --cutfinal 5 --timeout 600 \
                                     --want "zfs-wtest: cut txg [0-9]+ after [0-9]+ device writes \(data [1-9][0-9]*, dataset metadata [1-9][0-9]*, MOS [1-9][0-9]*, MOS chain 1, uberblock 0\), before a .* write - halted" \
                                     --want "zfs-wtest: cut txg [0-9]+ hygiene: flushed=[1-9][0-9]* .*"

lane ashift9@cut-ub1    agnos9    cut     --img ashift9 --cut ub:1 --cutfinal 6 --cutlabels 1 --timeout 600 \
                                     --want "zfs-wtest: cut txg [0-9]+ after [0-9]+ device writes \(.*, uberblock 1\), before a uberblock write - halted" \
                                     --want "zfs-wtest: cut txg [0-9]+ hygiene: flushed=[1-9][0-9]* .*"

lane ashift9@cut-ub3    agnos9    cut     --img ashift9 --cut ub:3 --cutfinal 6 --cutlabels 3 --timeout 600 \
                                     --want "zfs-wtest: cut txg [0-9]+ after [0-9]+ device writes \(.*, uberblock 3\), before a uberblock write - halted" \
                                     --want "zfs-wtest: cut txg [0-9]+ hygiene: flushed=[1-9][0-9]* .*"

# (B7 review, finding 3 / design k.70) wr's AO_TRUNC runs as on a pool with block_cloning ACTIVE: every kill DEFERRED to
# free_bpobj, which grows past its first block and a level (`free_bpobj <n> BPs, <b> block(s), nlevels 2`); its six txgs
# are what the metadata arena holds once their free_bpobj appends are budgeted (B7 as built ran the first commit out of
# the arena: `dirty metadata full`, the pool read-only)
# (B5 review) wr's list ends with finding 1's gate — 20 MiB of 4 KiB records into rs4k through an fd, then AO_TRUNC, which
# frees all 5,120 blocks: >= 2 txgs, the extent list measured — and finding 3's: one-block appends until the metaslabs
# agnos allocates in are full, refused by the write's predicate (never by a commit); main's with finding 2's: 180
# appends (250 until B10: each txg's flush leaves ~45 KB more deferred for the boot, design k.113), each its own txg,
# then the truncation that frees all 180 in ONE txg whose log holds >= 180 extents
WRB=(--timeout 450
     --want "zfs-wtest: write /agnoswr/rs4k/r64k.bin -> 20971520 txgs=[0-9]+"
     --want "zfs-wtest: trunc /agnoswr/rs4k/r64k.bin -> 0 txgs=([2-9]|[1-9][0-9]+)"
     --want "zfs-wtest: burst stopped at write [0-9]+: no space: .*"
     --want "zfs-wtest: burst /agnoswr/rs4k/r64k.bin -> [0-9]+ txgs=[0-9]+"
     --room "burst /agnoswr/rs4k/r64k.bin 4096 1 5"
     --want "zfs-wtest: allocation capped at the first 5 metaslabs with a space map"
     --want "zfs-wtest: symlink /agnoswr/rs4k/b6d/s object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 512 B; a new SA layout [0-9]+"
     --want "zfs-wtest: create /agnoswr/fat/x object [0-9]+, dnode block [0-9]+ of [0-9]+, parent fat ZAP 16384 B: 1 leaf\(s\), table 2\^10 embedded, freeblk 2, 12 entries"
     --want "zfs-wtest: mkdir ok refused \(dataset read-only\)"
     --want "zfs-wtest: create /agnoswr/dnode/one.txt object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 512 B"
     --want "zfs-wtest: unlink /agnoswr/hello-link.txt object [0-9]+: 1 link\(s\)"
     --want "zfs-wtest: unlink /agnoswr/sym-long object [0-9]+: freed"
     --want "zfs-wtest: rmdir /agnoswr/deep/a object [0-9]+: freed"
     --want "zfs-wtest: rename ok refused \(rename across datasets \(EXDEV\)\)"
     --want "zfs-wtest: rename ok refused \(a mount point or another dataset's object \(EBUSY / EXDEV\)\)"
     --want "zfs-wtest: unlink ok refused \(dataset read-only\)"
     --want "zfs-wtest: unlink /agnoswr/fat/f0 object [0-9]+: freed"
     --want "zfs-wtest: rename /agnoswr/fat/f1 object [0-9]+: moved"
     --want "zfs-wtest: link /agnoswr/micro/m03 object [0-9]+: 2 link\(s\)"
     --want "zfs-wtest: link ok refused \(link of a directory \(EPERM\)\)"
     --want "zfs-wtest: link ok refused \(link across datasets \(EXDEV\)\)"
     --want "zfs-wtest: link ok refused \(name is not valid UTF-8 on a utf8only dataset \(EILSEQ\): u8_validate class 2\)"
     --want "zfs-wtest: rename /agnoswr/utf8/plain.txt object [0-9]+: moved"
     --want "zfs-wtest: create /agnoswr/utf8/emoji-.*\.txt object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap [0-9]+ B"
     --want "zfs-wtest: create ok refused \(name is not valid UTF-8 on a utf8only dataset \(EILSEQ\): u8_validate class 1\)"
     --want "zfs-wtest: create ok refused \(name is not valid UTF-8 on a utf8only dataset \(EILSEQ\): u8_validate class 2\)"
     --want "zfs-wtest: create ok refused \(name is not valid UTF-8 on a utf8only dataset \(EILSEQ\): u8_validate class 3\)"
     --want "zfs-wtest: lazy probe /agnoswr/rs4k/r64k.bin object [0-9]+: too big for one txg at [0-9]+ kill entries / [0-9]+ DVAs \(kill list 4096, extent list 4096\) ok"
     --fbpo 6 --want "zfs-wtest: trunc /agnoswr/rs4k/r64k.bin -> 0 txgs=6"
     --want "zfs-wtest: free_bpobj [0-9]+ BPs, [4-9] block\(s\), nlevels 2"
     --dl '[1-9][0-9]*' --mat '6|7'
     --want "zfs-wtest: txg [0-9]+ plan: .* dl=[1-9][0-9]* dlu=[0-9]+ mat=2 dlx=0"
     --want "zfs-wtest: write ok refused \(deadlist is a fat ZAP \(B8\)\)"
     --want "zfs-wtest: write ok refused \(one block does not fit a txg: the snapshot intervals its path reaches, 4\)"
     --want "zfs-wtest: write /agnoswr/edge/p.bin -> 4096 txgs=1"
     --want "zfs-wtest: txg [0-9]+ plan: .* dl=[1-9][0-9]* dlu=[0-9]+ mat=4 dlx=0"
     --want "zfs-wtest: trunc ok refused \(deadlist entries in one txg over 3\)"
     --want "zfs-wtest: trunc /agnoswr/edgec/t.bin -> 0 txgs=4"
     --want "zfs-wtest: deadlist /agnoswr/edge object [0-9]+: 5 entries \(1 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP [0-9]+"
     --want "zfs-wtest: deadlist /agnoswr/edgec object [0-9]+: 6 entries \(3 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP [0-9]+"
     --want "zfs-wtest: deadlist /agnoswr/snap object [0-9]+: 2 entries \(1 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP [0-9]+"
     --want "zfs-wtest: deadlist /agnoswr/clone object [0-9]+: 2 entries \(1 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP 0"
     --want "zfs-wtest: deadlist /agnoswr/snap2 object [0-9]+: 3 entries \(1 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP [0-9]+"
     --want "zfs-wtest: unlink /agnoswr/clone/own.txt object [0-9]+: freed")
# (B7, design k.68) agnoswr's two COWs force the histogram set (zfs_wh_force): the plan-time path — on wr@u0 the U
# preset's dirty dnode block DEMOTED out of step (1) — and the post-chain path, a chain re-plan
lane wr            agnoswr   rw      --cows 2 --touched "/agnoswr/quota/q.bin /agnoswr/resv/r.txt" --hist '[1-9][0-9]*' "${WRB[@]}" \
                                     --want "zfs-wtest: histogram set forced on 2 COWs: [0-9]+ step-\(1\) block\(s\) demoted, [1-9][0-9]* chain re-plan\(s\) ok"
lane wr@u0         agnoswr   rw      --cows 2 --img wr --forge pre-defer,zero-u --pre1 '[1-9][0-9]*' "${WRB[@]}" \
                                     --want "zfs-wtest: histogram set forced on 2 COWs: [1-9][0-9]* step-\(1\) block\(s\) demoted, [1-9][0-9]* chain re-plan\(s\) ok"
lane main          agnostank rw      --cows 2 --touched "/agnostank/sha256/rand-256k.bin /agnostank/coff/kid/kid.txt" \
                                     --want "zfs-wtest: write ok refused \(partial overwrite of a zstd block \(no decompressor\): object [0-9]+\)" \
                                     --want "zfs-wtest: trunc /agnostank/gang/gang.bin -> 0 txgs=1" --fbpo 2 \
                                     --want "zfs-wtest: unlink /agnostank/gang/gang.bin object [0-9]+: freed" \
                                     --want "zfs-wtest: unlink /agnostank/dnode/n00 object [0-9]+: freed" \
                                     --want "zfs-wtest: unlink /agnostank/off/lazy.bin object [0-9]+: on the DELETE_QUEUE" \
                                     --want "zfs-wtest: rmdir /agnostank/coff/kid/b6e object [0-9]+: freed" \
                                     --want "zfs-wtest: rename ok refused \(rename across datasets \(EXDEV\)\)" \
                                     --want "zfs-wtest: unlink ok refused \(dataset read-only\)" \
                                     --want "zfs-wtest: burst /agnostank/off/rand-200k.bin -> 737280 txgs=180" \
                                     --want "zfs-wtest: trunc /agnostank/off/rand-200k.bin -> 0 txgs=1" --timeout 720 \
                                     --want "zfs-wtest: create /agnostank/coff/kid/b6/f55 object [0-9]+, dnode block 2 of 3, parent microzap 4096 B" \
                                     --want "zfs-wtest: mkdir ok refused \(dataset read-only\)" \
                                     --want "zfs-wtest: symlink /agnostank/coff/kid/b6/s object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap 4096 B; a new SA layout [0-9]+" \
                                     --want "zfs-wtest: create /agnostank/coff/kid/b6/a-name-of-fifty-bytes-past-the-microzap-limit-nnnn object [0-9]+, dnode block [0-9]+ of [0-9]+, parent fat ZAP 16384 B: 1 leaf\(s\), table 2\^10 embedded, freeblk 2, 58 entries; 1 ZAP upgrade\(s\)" \
                                     --dl '[1-9][0-9]*' --mat 0 \
                                     --want "zfs-wtest: deadlist /agnostank object [0-9]+: 2 entries \(1 naming empty_bpobj\), dl_used [0-9]+, prev snapshot unique [0-9]+, dir SNAP [0-9]+" \
                                     --want "zfs-wtest: unlink /agnostank/deep/a/b/c/d/e/leaf.txt object [0-9]+: freed" \
                                     --want "zfs-wtest: rename /agnostank/deep/a/b/c/d/e object [0-9]+: moved" \
                                     --want "zfs-wtest: drain /agnostank/off object [0-9]+: freed txgs=[0-9]+ parts=[1-9][0-9]*" \
                                     --want "zfs-wtest: unlink /agnostank/off/b10.bin object [0-9]+: freed \(queued by its txg, drained by [1-9][0-9]* more\)" \
                                     --want "zfs-wtest: txg [0-9]+ hygiene: flushed=[1-9][0-9]* .* fonly=[1-9][0-9]* .*" \
                                     --want "zfs-wtest: txg [0-9]+ hygiene: flushed=[1-9][0-9]* .* self=[1-9][0-9]* .*" \
                                     --want "zfs-wtest: rename /agnostank/coff/kid/f01 object [0-9]+: moved"
lane full          agnosfull rw      --cows 1 --nulls 8 --touched "/agnosfull/fill-0.bin" --room "write /agnosfull/fill-5.bin 131072 1" \
                                     --want "zfs-wtest: residency capped at 1 bitmap slot; 8 null txgs" \
                                     --want "zfs-wtest: write /agnosfull/fill-5.bin -> [0-9]+ txgs=[0-9]+" \
                                     --want "zfs-wtest: write ok refused \(no space: the pool is at its slop\)" \
                                     --want "zfs-wtest: unlink /agnosfull/b6/a.txt object [0-9]+: freed" \
                                     --want "zfs-wtest: rmdir /agnosfull/b6e object [0-9]+: freed" \
                                     --want "zfs-wtest: rename /agnosfull/dir/s1.txt object [0-9]+: moved"
lane full@pre      agnosfull rw      --cows 1 --img full --forge pre-defer --nulls 8 --pre1 '[1-9][0-9]*' --reapply1 '[1-9][0-9]*' \
                                     --room "write /agnosfull/fill-5.bin 131072 1" \
                                     --want "zfs-wtest: residency capped at 1 bitmap slot; 8 null txgs"
lane logs          agnoslogs rw
# B8 (design § h B8, fixture RECIPE 7): the FAT-ZAP pool — b8/'s microzap upgraded by a 60-byte name, its leaf split
# down to the pointer table's prefix, the embedded table moved out and DOUBLED (at once, then one block per op: a
# mid-grow across txgs and a split inside it), dir3000/'s smallest leaf emptied, longn/ emptied and removed, micro/
# upgraded, uids/' fat accounting ZAPs updated and a last owner's keys removed (no agnos op ADDS a key to a fat one on
# disk — k.86: the boot's in-memory `zfs-wb3: uafat` does), uidm's full microzap upgraded, the first symlink a LAYOUTS
# add — each checkpoint the fat-ZAP model predicts (scripts/smoke/lib/zfs-fz-ops.py)
FZB=(--timeout 2700
     --want "zfs-wtest: zap /agnosfz/b8: microzap 512 B"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 1 leaf\(s\), table 2\^10 embedded, freeblk 2, 7 entries"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 2 leaf\(s\), table 2\^10 embedded, freeblk 3, 49 entries"
     --want "zfs-wtest: b8: 79 a-names until the pointer table began doubling"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 14 leaf\(s\), table 2\^13 in 4 block\(s\) at 17 doubling to 22, 1 copied, freeblk 30, 128 entries"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 15 leaf\(s\), table 2\^13 in 4 block\(s\) at 17 doubling to 22, 3 copied, freeblk 31, 130 entries"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 15 leaf\(s\), table 2\^14 in 8 block\(s\) at 22, freeblk 31, 140 entries"
     --want "zfs-wtest: zap /agnosfz/b8: fat ZAP 16384 B: 15 leaf\(s\), table 2\^14 in 8 block\(s\) at 22, freeblk 31, 118 entries"
     --want "zfs-wtest: the smallest leaf of /agnosfz/dir3000: block [0-9]+, [0-9]+ entries"
     --want "zfs-wtest: rmdir /agnosfz/longn object [0-9]+: freed"
     --want "zfs-wtest: zap /agnosfz/micro: fat ZAP 16384 B: 1 leaf\(s\), table 2\^10 embedded, freeblk 2, 21 entries"
     --want "zfs-wtest: create /agnosfz/uidm/new.txt object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap [0-9]+ B; 1 ZAP upgrade\(s\)"
     --want "zfs-wtest: symlink /agnosfz/sym object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap [0-9]+ B; a new SA layout [0-9]+"
     --want "zfs-wtest: symlink /agnosfz/sym2 object [0-9]+, dnode block [0-9]+ of [0-9]+, parent microzap [0-9]+ B")
lane fz            agnosfz   rw      --nulls 3 "${FZB[@]}"
lane v28           agnosv28  refused "pool version 28"
lane mirror-a      agnosmir  refused "vdev type mirror"
lane makefs        agnosmk   refused "no log_spacemap"
lane raidz-0       -         nopool

# ⭐ OpenZFS judges the rw lanes (zfs-fixture.sh --verify: phases A-D, design § i.3) — in as few guest boots as the
# guest's disks allow: one boot verifies at most 8 lanes (three disks each, zfs-fixture.sh VERIFY_MAX_LANES), so
# (1.57.12 B11: 12 rw lanes with the four crash cuts) the lanes go in BATCHES of equal size, each its own directory
# $VDIR/b<k> of hard links to the lane's files (<lane>.img / .ops / .txg / .touched / .orig / .pristine / .cutlabels —
# the verify reads them, never writes them) with its own verify.out. Every batch's verdict counts: one FAIL fails the
# smoke, one VOID voids it.
vrc=-; vpass=0
declare -A VBDIR
if [ -n "$rwlanes" ]; then
    echo ""
    echo "  OpenZFS verify (FreeBSD 15.1 guest) of:$rwlanes"
    _vl=($rwlanes); _vn=${#_vl[@]}; _vb=$(( (_vn + 7) / 8 )); _vs=$(( (_vn + _vb - 1) / _vb ))
    : > "$LOGS/verify.out"; : > "$LOGS/verify.err"
    vrc=0; _vk=0
    while [ $((_vk * _vs)) -lt "$_vn" ]; do
        _vk=$((_vk + 1)); _bd="$VDIR/b$_vk"
        rm -rf "$_bd"; mkdir -p "$_bd"
        _bl=""
        for l in "${_vl[@]:$(((_vk - 1) * _vs)):$_vs}"; do
            cp -al "$VDIR/$l".* "$_bd/" || { echo "  cannot link lane $l's files into $_bd"; vrc=2; }
            VBDIR[$l]="$_bd"; _bl="$_bl $l"
        done
        [ "$_vb" = 1 ] || echo "  batch $_vk of $_vb:$_bl"
        bash "$ROOT/scripts/tool/zfs-fixture.sh" --verify "$_bd" --fixture "$FIX" ${ZWS_CONTINUE:+--continue} > "$LOGS/verify-b$_vk.out" 2> "$LOGS/verify-b$_vk.err"
        _brc=$?
        sed 's/^/    /' "$LOGS/verify-b$_vk.out"
        cat "$LOGS/verify-b$_vk.out" >> "$LOGS/verify.out"; cat "$LOGS/verify-b$_vk.err" >> "$LOGS/verify.err"
        case "$_brc" in
            0) ;;
            1) vrc=1 ;;
            *) echo "  batch $_vk: the verify reached no verdict (exit $_brc — $LOGS/verify-b$_vk.err)"; [ "$vrc" = 1 ] || vrc=2 ;;
        esac
    done
    for l in $rwlanes; do
        grep -q "^zfs-fixture: verify $l PASS" "$LOGS/verify.out" && vpass=$((vpass + 1))
    done
    case "$vrc" in
        0) ;;
        1) rc=1 ;;
        *) echo "  the verify reached no verdict (exit $vrc — $LOGS/verify.err)"; voids=$((voids + 1)) ;;
    esac
    # B4 (design § k.34): OpenZFS's OWN reading of the user / group / project ZAPs — phase B's `zfs userspace /
    # groupspace / projectspace -Hp` capture — against the host recount of the same image (h7): the recount reads the
    # ZAPs with the image tool's parser, so only this makes OpenZFS the judge of the values agnos wrote
    if [ "$vrc" = 0 ] || [ "$vrc" = 1 ]; then
        for l in $rwlanes; do
            _bd=${VBDIR[$l]}
            if [ ! -f "$_bd/verify.out/$l.B.acct" ]; then echo "  FAIL [$l]: no phase-B accounting capture to hold the recount to"; rc=1; continue; fi
            python3 -I "$ROOT/scripts/smoke/lib/zfs-uacct-check.py" "$VDIR/$l.img" --space "$_bd/verify.out/$l.B.acct" > "$LOGS/$l.uspace" 2>&1
            _usrc=$?
            echo "  uspace [$l]: $(tail -1 "$LOGS/$l.uspace" | cut -c1-200)"
            grep '^uacct:   FAIL' "$LOGS/$l.uspace" | head -3 | sed 's/^/    /' | cut -c1-220
            [ "$_usrc" = 0 ] || rc=1
        done
    fi
fi

# ⚠ VACUITY FLOOR (the exfat-smoke rule): a lane that silently did not run must not read as a pass, and the guest
# must have passed every rw lane BY NAME.
EXPECT=21; EXPECT_RW=12                                  # (B11) + the four crash-cut lanes, each OpenZFS-verified
echo ""
echo "  lanes scored: $lanes/$EXPECT (VOID: $voids) · rw lanes verified by OpenZFS: $vpass/$EXPECT_RW (verify exit $vrc)"
if [ -n "${ZWS_LANES:-}" ] || [ -n "${ZWS_SPACE:-}" ] || [ -n "${ZWS_CONTINUE:-}" ]; then
    echo "=========================================="
    echo "ZFS write smoke: PARTIAL (ZWS_LANES=${ZWS_LANES:-all} ZWS_SPACE=${ZWS_SPACE:-strict} ZWS_CONTINUE=${ZWS_CONTINUE:-0}) — $lanes lane(s), rc $rc, $vpass verified; never a PASS"
    echo "Logs: $LOGS  (verify results: $VDIR/b*/verify.out)"
    echo "=========================================="
    [ "$rc" = 0 ] && exit 2
    exit $rc
fi
[ "$lanes" -lt "$EXPECT" ] && { echo "  FAIL: only $lanes of $EXPECT lanes ran"; rc=1; }
[ "$rc" = 0 ] && [ "$voids" = 0 ] && [ "$vpass" -lt "$EXPECT_RW" ] && { echo "  FAIL: only $vpass of $EXPECT_RW rw lanes PASSED the guest verify"; rc=1; }
echo "=========================================="
if [ "$rc" = "0" ] && [ "$voids" = "0" ]; then
    echo "ZFS write smoke: PASS — $lanes lanes, $vpass rw pools committed and accepted by OpenZFS ($FIX)"
elif [ "$rc" = "0" ]; then
    echo "ZFS write smoke: VOID — $voids lane(s) or the verify reached no verdict"; rc=2
else
    echo "ZFS write smoke: FAIL"
fi
echo "Logs: $LOGS  (verify results: $VDIR/b*/verify.out)"
echo "=========================================="
exit $rc
