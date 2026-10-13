#!/bin/bash
# ZFS fixture generator — the test ORACLE for AGNOS's ZFS driver: the pools the reader reads, and (RECIPE 2,
# agnos 1.57.12) the WRITE oracle that judges a pool after agnos wrote to it.
#
# This box has no ZFS tooling (no zpool/zfs/zdb/makefs) and a ZFS reader checked only against
# itself proves nothing, so the pools are built by a REAL OpenZFS: a throwaway FreeBSD 15.1 guest
# (OpenZFS in base) under QEMU/KVM builds every recipe pool directly on whole raw disk files, re-reads
# each one through a read-only import, records a manifest of what that import shows, and exports it.
# The kernel smoke boots AGNOS against the images and compares what the kernel reads to the manifest.
#
# usage: scripts/tool/zfs-fixture.sh [--ensure | --rebuild] [--payload DIR]
#        scripts/tool/zfs-fixture.sh --verify DIR [--payload DIR | --fixture FIXDIR] [--continue] [--force-a4]
#        scripts/tool/zfs-fixture.sh --fixture-key [--payload DIR]     print the fixture directory name and exit
#   --ensure     (default) reuse the fixture if its DONE stamp exists, else build it
#   --rebuild    always build (the old fixture is replaced only once the new one has verified)
#   --payload D  also put D's files (recursive, regular files + dirs, mode 0755) in agnostank/payload
#   --verify DIR the write oracle (VERIFY below) on DIR's lane images, against the fixture --payload (or
#                --fixture) names — ensured first, like --ensure
# stdout carries exactly one line, the fixture directory, and only on success (smokes:
# `dir=$(bash zfs-fixture.sh --ensure 2>log | tail -1)`, then check "$dir/DONE"). Progress and every
# `ERROR:` line go to stderr; any failure exits non-zero with stdout empty. A fixture directory
# without DONE is never produced — the build happens in `<dir>.work.<pid>` and is renamed into place
# only after every check below has passed (a failed build's work dir is kept for diagnosis and swept
# by the next run). bash, not sh: arrays.
#
# Cache:   ${ZFS_FIXTURE_DIR:-$HOME/.cache/agnos/zfs-fixtures}
#            base/                      the downloaded FreeBSD image (untrusted data: never executed
#                                       on the host, only booted inside QEMU through an overlay)
#            r<RECIPE>-<payloadhash>-<buildhash>/   one fixture; payloadhash = 12 hex of sha256 over the payload's
#                                       sorted "sha256  relpath" listing, or `nopayload`; buildhash = 8 hex of sha256
#                                       over zfs-fixture-guest.sh WITHOUT its "VERIFY HALF" + the disk table + RECIPE —
#                                       ⛔ B0 review: RECIPE alone did not key on the script, so r2 was built by an
#                                       older guest script than the one that then judged lanes against it
# Fixture: <image>.img        main ashift9 v28 mirror-a mirror-b makefs raidz-0 raidz-1 raidz-2 — the READ
#                             lanes — and (RECIPE 2) the WRITER's pools:
#                               wr    agnoswr: NO root snapshot, only writer-listed features active, children
#                                     that each hit one write gate (snapshot, readonly=on, normalization=formD,
#                                     utf8only=on, quota+refquota, reservation+refreservation, recordsize=4K,
#                                     dnodesize=auto), a microzap and a fat-ZAP dir, hard link, short + 300-byte
#                                     symlinks, embedded / sparse / one- and multi-record files; (RECIPE 4) resv4k
#                                     (reservation = its used + 4 KiB), refresv4k (refreservation = its referenced +
#                                     4 KiB), resv4k/owned.bin (uid 1001, gid 1002, project 1003); (RECIPE 7) snap2;
#                                     (RECIPE 8) edge + its clone edgec: blocks born IN their snapshots' own txgs
#                                     (the four boundaries B9 compares against) and block 0 paths of p.bin / q.bin
#                                     that reach four deadlist intervals
#                               full  agnosfull: 128 MiB filled until `available` < 2 MiB (only the slop
#                                     left) — the ENOSPC lane
#                               logs  (RECIPE 4) agnoslogs: 256 MiB filled near the slop, churned (deletes across
#                                     every stripe of the fill order + fewer writes, one sync a round, best fit) and
#                                     exported with vfs.zfs.keep_log_spacemaps_at_export=1 — the log space maps
#                                     survive (>= 8), U[] as OpenZFS's one-flush-per-txg round robin left it (>= 4
#                                     metaslabs with U != T0), FREEs that later kept logs reallocate; the summary
#                                     carries the census (zdb -mmmm; zfs-fixture-guest.sh logs_census)
#                               fz    (RECIPE 7, agnos 1.57.12 B8) agnosfz: the FAT-ZAP pool, ashift 9, snapshot-free —
#                                     dir3000/ (3,000 names: OpenZFS's own upgrade + 16 leaves), longn/ (60 x 255-byte
#                                     names, 2 leaves), micro/ (a microzap), uids (1,100 owners: fat user / group
#                                     accounting ZAPs), uidm (a userused microzap of 2,046 keys, one chunk free), no
#                                     symlink (the first one agnos makes is a LAYOUTS add), spread (a space map on
#                                     every metaslab)
#                             Every pool ends EXPORTED (label state 1): the writer accepts only exported pools.
#          <image>.manifest   THE CONTRACT — lines sorted bytewise by path, then type letter; paths are
#                             relative to the read-only import's altroot, which is "/":
#                               D <path>                  directory (the altroot itself is "D /")
#                               F <path> <size> <sha256>  regular file (hard links under every name)
#                               L <path> <target>         symlink; target verbatim to end of line
#                               M <path> <dataset>        mount point of every MOUNTED dataset
#                             i.e. exactly what `zpool import -o readonly=on -R /mnt/m -d <disk(s)>
#                             <pool>` + `zfs mount -a` shows. Multi-disk pools (mirror, raidz) carry
#                             an identical copy under every member image's name.
#          <image>.summary    zpool/zfs properties, feature@ states, zdb -l / -C / -uuu / -d / -bb / -m, and for
#                             main + wr the zdb -dddd(d) object dumps (EMBEDDED, fat ZAP, gang, SA/spill)
#          <image>.xattrs     X <path> user <name> <len> <sha256>  (not part of the manifest contract)
#          <image>.objects    <object id> <path> — stat's inode is the ZFS object id within its dataset
#          <image>.acct       (RECIPE 2) the pristine ACCOUNTING baseline: zfs get -Hp used / referenced /
#                             usedby* / logicalreferenced / written / quotas / origin of every filesystem AND volume,
#                             zfs user|group|projectspace -Hp, objects visible per dataset, the pool's freeing /
#                             leaked, `alloc zdb` (zdb -bb's bp allocated, tagged clean only under "No leaks" — the
#                             makefs pool is measured NOT clean, 112 KiB "leaked space" on the pristine image), `alloc
#                             rwimport` (a writable import of a malloc COPY, exported at once — NEVER a read-only
#                             import, which reads allocated 0) and (RECIPE 3) `mos`: $MOS's exact dd_used, Σ dsize of
#                             the MOS objects, the MOS objset block's asize; (RECIPE 4) user / group ids NUMERIC
#                             (zfs userspace / groupspace -n). Format: zfs-fixture-guest.sh acct_capture.
#          <image>.snaps      (RECIPE 7) every snapshot's own tree, `S <snapshot>` + its D / F / L lines (mounted
#                             read-only: snap_manifests) — the baseline of the verify's B-snap (1.57.12 B9)
#          INDEX, SHA256SUMS, RECIPE, log/ (serial + guest logs, the expected-content registries, the
#          pristine <pool>.dirsize), DONE
#
# VERIFY (`--verify DIR`, design docs/development/proposals/2026-10-09-zfs-write.md § i.3): DIR holds lane
# images after a writer ran on them — <lane>.img, a copy of a single-disk fixture image (a lane name may carry
# a variant, `main@flip.img` is lane `main@flip` of base image `main`) — and optionally, per lane:
#   <lane>.expect   the expected manifest (default: the fixture's own, i.e. "nothing changed")
#   <lane>.ops      an op list for scripts/smoke/lib/zfs-expect.py (expected = fixture manifest + ops; with
#                   <lane>.orig/ as --orig) — used when there is no <lane>.expect; it also derives the expected
#                   xattrs and the k.15 list
#   <lane>.txg      the writer's final txg. ⛔ REQUIRED for a writer lane (one with .ops or .expect): without it the
#                   expected txg was the highest that verifies, read off the image itself, so a writer whose final
#                   uberblock write was lost (pool consistent at T-1) passed A1, A2 and H (B0 review). A lane with
#                   neither is a "nothing changed" lane: its expected txg is the PRISTINE best. H gets --final-txg.
#   <lane>.xattrs   the expected xattr listing (default: the fixture's <image>.xattrs, or zfs-expect's with .ops)
#   <lane>.touched  "<D|F|L> <manifest path>" the writer touched, for phase C (default: derived from .ops; none)
#   <lane>.leakok   design k.15: manifest PATHS of the objects whose stale PARENT the ops predict (default: derived
#                   from .ops by zfs-expect.py; none). A5 tolerates exactly their objects — never a count.
#   <lane>.pristine the image the writer STARTED from, when it is not the fixture's own (1.57.12 B3b: a lane whose
#                   start state zfs-damage.py forged in place — e.g. `zero-u`, an upgraded pool's U[] — rewrites the
#                   best uberblock at its own txg, which H would read as a writer's defect): H and the pristine best
#                   txg are taken from it. Everything else (manifest, xattrs, .acct baselines) stays the base image's,
#                   so a forge may change no file content and no space.
#   <lane>.cutlabels  (1.57.12 B11) K: the lane is a CRASH CUT whose final txg's uberblock reached only labels 0 .. K-1
#                   (zfs-write-smoke's ashift9@cut-ub1 / -ub3): H passes --cut-labels K to zfs-image-audit.py
# Per lane the host first JUDGES what it can alone: an image of the wrong size, an op list zfs-expect.py calls
# inconsistent, or no verifying uberblock is a FAIL of THAT lane; a missing input (no .txg on a writer lane, an
# unknown base image) VOIDs that lane — the other lanes still boot (B0 review: one bad lane voided the whole run).
# Then H, scripts/smoke/lib/zfs-image-audit.py against the pristine image (h1-h3: labels, boot region and uberblock
# rings changed only as a txg commit changes them; h6, 1.57.12 B3b: the space record replayed on the host — the
# U[] rules zdb and the imports let through; seconds, no guest). Then one guest boot verifies every remaining
# lane (at most 8: three disks each). Per lane the host attaches the image READ-ONLY plus two copies it makes in
# DIR/verify.out/work (phases C and D write; never the cache's files); the guest runs phases A (zdb only) · B
# (read-only import) · C (read-write round trip) · D (destroy + freeing), printing `zfsfix: verify <lane> <step>
# PASS|FAIL|SKIP|INFO <why>` the moment each step is decided. Phase E (agnos's own read-back of <lane>.rt.img) is a
# hook for the writer's bites: printed SKIP.
# The VERDICT (judge_lanes below): the guest's verify.steps file is authoritative once the results tar arrives — a
# console line can be lost or split by syslog writing to the same console, and a lost FAIL line used to read as a
# PASS (B0 review) — and is cross-checked against the serial lines; a lane PASSes only with DONE PASS, no FAIL, and
# every required step present exactly once. Without the tar (a panic) the serial log is all there is.
# stdout: one `zfs-fixture: verify <lane> PASS|FAIL|VOID ...` line per lane, then `zfs-fixture: verify PASS|FAIL|VOID`.
# Exit 0 every lane PASS · 1 a lane FAILed (a guest `panic:` and a zdb killed by a signal are FAILs) · 2 VOID:
# infrastructure only (no guest, no verdict, a disk the guest could not identify), and no lane FAILed. Results in
# DIR/verify.out/: serial.log, guest.log, verify.steps, per-lane zdb outputs, <lane>.B.manifest, <lane>.rt.manifest
# and <lane>.rt.img (the round-tripped copy, for phase E). --continue runs B-D after a red A (a broken pool can
# panic the guest); --force-a4 runs A4's rewind checks (zdb -t at the two verifying uberblocks below the selected
# one) on lanes without txgs past the pristine best too.
# Takes the cache lock for its whole run: one KVM guest at a time, and no rebuild under a running verify.
#
# Bump RECIPE whenever zfs-fixture-guest.sh (or the disk set below) changes what gets built: the
# fixture directory is keyed on it, so a stale cache can never satisfy --ensure for a new recipe. The build hash in the
# key catches a script edit that forgot to (it rebuilds on ANY build-half edit, comments included — that is the point).
# RECIPE 2 (agnos 1.57.12 B0): + wr, + full, + <image>.acct, + zdb -m in every summary.
# RECIPE 3 (B0 review): wr + clone / bmark / insens / copies2 / vol; .acct + origin, type, volumes, the pool's
# freeing / leaked and the exact $MOS figures.
# RECIPE 4 (1.57.12, design k.37 + the B3 review): wr + resv4k / refresv4k (a writer's COW crosses a reservation and a
# refreservation boundary ON DISK) + resv4k/owned.bin (non-zero user / group / project keys); .acct's user / group ids
# numeric; + logs — a pool OpenZFS last ran near its slop, exported with its logs kept: the real many-logs replay (B1's
# state load). MEASURED: the allocated-AND-deferred overlap zfs-damage.py pre-defer forges is NOT reachable through an
# export (its last txgs before T0 are empty), so the forge stays; the census reports pre_deferred = 0.
# RECIPE 5 (1.57.12 B6 review, finding 7): main's agnostank/custom + custom-link -> custom.txt, a FreeBSD symlink — the
# only WRITABLE dataset the ring-3 gate reaches (the root is snapshotted) then holds the symlink SA layout, so zfsx's
# symlink#63 succeeds there (and has a FreeBSD twin); agnostank/coff/kid keeps the no-layout refusal. main also gets a
# SPREAD — a fill to the slop in a scratch dataset, then destroyed — so most metaslabs carry a space map (agnos allocates
# in no other, design k.46): which ones the recipe touched varied between builds (8 of 15 on r4, 7 on the first r5 —
# where the main lane's ~95 MB op list ran out at its 244th burst write); measured 15 of 15 after it, held >= 12. And
# wr's zvol minor-node wait 30 -> 120 s (the first r5 build died "never appeared" at host load 14 on 16 cores).
# RECIPE 6 (1.57.12 B7 review, finding 3): ashift9's agnos9/xd.txt, a file whose xattr lives in an extended-attribute
# DIRECTORY (xattr=dir for it alone) — no fixture object a B7 op could reach had one (agnostank/xattr.txt is in the
# snapshotted root, agnostank/dnode uses xattr=sa), so the writer's ZPL_XATTR rule (such an object's unlink takes the
# DELETE_QUEUE: zfs_rmnode purges the directory) never ran on disk.
# RECIPE 7 (1.57.12 B8 and B9 — each track bumped 6 -> 7 on its own, and their caches differed by build hash; the merge
# made them ONE recipe, design k.81): B8's fz — agnosfz above, the FAT-ZAP pool: every fat ZAP the writer touches and
# room for ≈ 600 txgs; the verify's 8th rw lane, which FILLS q35's root bus. B9's wr snap2 — two snapshots and nothing
# written after the second, so every entry of its head's deadlist names the shared empty_bpobj: no other fixture entry a
# writer's kill can reach does (agnostank's and snap's became bpobjs when OpenZFS wrote after their snapshots), so the
# writer's MATERIALISATION (bpobj_alloc + bpobj_decr_empty) never ran on disk. And <image>.snaps — every snapshot's own
# tree (snap_manifests), the baseline of the verify's B-snap; and acct_capture's `snaps <fs> <n>` lines (B-acct's clone
# identity). And wr's SPREAD (64 MiB written and destroyed: every metaslab gets a space map — OpenZFS's segment weight
# sends each next chunk to an untouched one, so a bounded spread measured 15 of 15): agnos allocates only in metaslabs
# with a space map, wr's B5 / B7 gates are tuned to the room of 5, and how many a build left was luck (design k.69: 3 on
# RECIPE 7's first build — B7's truncation then ran out of room at its third txg — 5 on RECIPE 6's); the op list now
# caps agnos's allocation on wr at the first 5 (zfs_wt_msmax) and oracle_wr_objects holds >= 5.
# RECIPE 8 (1.57.12 B9 review, findings 3 and 5 — design k.103): wr's edge (recordsize=4K, @e1..@e4) and its clone edgec
# (@c1). No fixture block a writer kills was born AT a boundary B9 compares against — a snapshot's own txg (ds_prev_snap
# _txg), a deadlist key, the previous snapshot's ds_prev_snap_txg, a clone's dd_origin_txg — so an off-by-one in any of
# the four passed every lane; edge's e3.bin / e4.bin and edgec's e4.bin / c1.bin are written and snapshotted in ONE txg
# (build_wr_edge; oracle_wr_objects holds each birth to its snapshot's createtxg). And no fixture path reached more than
# two deadlist intervals: edge's p.bin (2 levels) and q.bin (3, sparse) reach four with their block 0. Additive: every
# RECIPE 7 object is unchanged (the spread still runs last). (The merge: B9's review moved its own track to 8 before the
# tracks met, so the merged recipe is 8 — both RECIPE 7 additions and edge / edgec — under a build hash neither track's
# cache holds: one cold build. Its first build showed the op list's exact counts on edgec followed the build's luck —
# per-CPU object numbers decided whether e4.bin's / c1.bin's dnode blocks moved on after @c1 — so build_wr_edge now
# touches both after @c1, design k.107 (g): a second cold build.)

set -u

RECIPE=8

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUEST_SCRIPT="$ROOT/scripts/tool/zfs-fixture-guest.sh"
FIXROOT="${ZFS_FIXTURE_DIR:-$HOME/.cache/agnos/zfs-fixtures}"
# A healthy cold build takes ~5 minutes; under host load (B0 review: load 8 on 16 cores) it outran a flat 1200 s while
# still printing progress. So two deadlines: the build may take GUEST_TIMEOUT in all, but the guest may never be silent
# on its serial console for GUEST_IDLE — a hung guest is told apart from a slow one by that, not by the clock.
GUEST_TIMEOUT="${ZFS_FIXTURE_TIMEOUT:-3600}"     # seconds, the whole build
GUEST_IDLE="${ZFS_FIXTURE_IDLE:-600}"            # seconds without one new serial line

FBSD_URL="https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest"
FBSD_QCOW="FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2"
# Pinned as well as checked against the directory's CHECKSUM.SHA256: the oracle must not drift because
# the mirror re-rolled the image. A mismatch between the two is an error, not a choice.
FBSD_XZ_SHA256="e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f"

# image basename, virtio serial (<= 20 chars: virtio-blk's ID field), size in MiB, pool
IMAGES="
main      ZFX-main      256 agnostank
ashift9   ZFX-ashift9    96 agnos9
v28       ZFX-v28        96 agnosv28
mirror-a  ZFX-mirror-a   96 agnosmir
mirror-b  ZFX-mirror-b   96 agnosmir
makefs    ZFX-makefs     96 agnosmk
raidz-0   ZFX-raidz-0    96 agnosrz
raidz-1   ZFX-raidz-1    96 agnosrz
raidz-2   ZFX-raidz-2    96 agnosrz
wr        ZFX-wr        256 agnoswr
full      ZFX-full      128 agnosfull
logs      ZFX-logs      256 agnoslogs
fz        ZFX-fz        256 agnosfz
"
RESULTS_MB=64
# 3 virtio-blk disks per lane + system/seed/results, one slot each on q35's root bus: of its 32 slots the host bridge
# (00), the default VGA (01) and the ICH9 functions (1f) take 3, so 3 + 3 x 8 = 27 fit (RECIPE 4: zfs-write-smoke
# verifies 7 rw lanes since the logs pool joined; it was 6. RECIPE 7: 8 with fz — the bus is FULL: a ninth rw lane
# needs a second verify run or a PCIe bridge)
VERIFY_MAX_LANES=8

say() { echo "zfs-fixture: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
void() { echo "ERROR: $*" >&2; echo "zfs-fixture: verify VOID ($*)"; exit 2; }

MODE=ensure
KEYONLY=0
PAYLOAD=""
VDIR=""
VFIX=""
VCONT=0
VFORCEA4=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ensure)  MODE=ensure ;;
        --rebuild) MODE=rebuild ;;
        --payload) [ $# -ge 2 ] || die "--payload needs a directory"; PAYLOAD="$2"; shift ;;
        --verify)  [ $# -ge 2 ] || die "--verify needs a directory"; MODE=verify; VDIR="$2"; shift ;;
        --fixture) [ $# -ge 2 ] || die "--fixture needs a fixture directory"; VFIX="$2"; shift ;;
        --continue) VCONT=1 ;;
        --force-a4) VFORCEA4=1 ;;
        --fixture-key) KEYONLY=1 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
        *) die "unknown argument '$1' (usage: zfs-fixture.sh [--ensure | --rebuild] [--payload DIR] | --verify DIR [--payload DIR | --fixture FIXDIR] [--continue] [--force-a4])" ;;
    esac
    shift
done
if [ "$MODE" != verify ] && { [ -n "$VFIX" ] || [ "$VCONT" = 1 ] || [ "$VFORCEA4" = 1 ]; }; then
    die "--fixture / --continue / --force-a4 belong to --verify"
fi
# a verify's own infrastructure failures are VOID (exit 2), never a verdict on the lanes
[ "$MODE" = verify ] && die() { void "$*"; }

for tool in qemu-system-x86_64 qemu-img mkfs.vfat mcopy xz curl sha256sum tar python3 truncate awk; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool '$tool'"
done
[ -f "$GUEST_SCRIPT" ] || die "guest script not found at $GUEST_SCRIPT"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm is not read-write for $(id -un) — the guest needs KVM"

# ---------------------------------------------------------------------------------------------
# VERIFY, part 1: the fixture is ensured by a child run (it takes and releases the cache lock itself); the
# lock is then taken HERE for the verify's own guest. Exits 2 (VOID) when there is no fixture to judge against.
if [ "$MODE" = verify ]; then
    [ -d "$VDIR" ] || void "--verify $VDIR is not a directory"
    VDIR="$(cd "$VDIR" && pwd)"
    if [ -z "$VFIX" ]; then
        VFIX=$(bash "$0" --ensure ${PAYLOAD:+--payload "$PAYLOAD"} | tail -1)
        [ -n "$VFIX" ] && [ -f "$VFIX/DONE" ] || void "no fixture (zfs-fixture.sh --ensure failed)"
    fi
    [ -f "$VFIX/DONE" ] || void "--fixture $VFIX has no DONE stamp"
    VFIX="$(cd "$VFIX" && pwd)"
fi

# ---------------------------------------------------------------------------------------------
# Payload identity. The manifest is whitespace-separated, so a payload name it cannot represent is
# refused here rather than discovered as a corrupt manifest line later.
PHASH=nopayload
if [ -n "$PAYLOAD" ] && [ "$MODE" != verify ]; then
    [ -d "$PAYLOAD" ] || die "--payload $PAYLOAD is not a directory"
    PAYLOAD="$(cd "$PAYLOAD" && pwd)"
    odd=$(cd "$PAYLOAD" && find . ! -type f ! -type d -print | head -5)
    [ -z "$odd" ] || die "payload may hold only regular files and directories; found: $odd"
    ws=$(cd "$PAYLOAD" && find . -print | grep '[[:space:]]' | head -5)
    [ -z "$ws" ] || die "payload names may not contain whitespace (manifest contract): $ws"
    [ -n "$(cd "$PAYLOAD" && find . -type f -print -quit)" ] || die "payload $PAYLOAD has no files"
    PHASH=$(cd "$PAYLOAD" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum \
        | sha256sum | cut -c1-12)
    [ ${#PHASH} -eq 12 ] || die "could not hash payload $PAYLOAD"
fi

# the guest script's BUILD half (its VERIFY HALF ships fresh on every --verify and is left out), the disk table and the
# recipe number: any change there is a different fixture
BHASH=$( { sed '/^# >>> VERIFY HALF/,/^# <<< VERIFY HALF/d' "$GUEST_SCRIPT"; echo "$IMAGES"; echo "RECIPE=$RECIPE"; } \
    | sha256sum | cut -c1-8)
[ ${#BHASH} -eq 8 ] || die "could not hash $GUEST_SCRIPT"
grep -q '^# >>> VERIFY HALF' "$GUEST_SCRIPT" && grep -q '^# <<< VERIFY HALF' "$GUEST_SCRIPT" \
    || die "$GUEST_SCRIPT lost its VERIFY HALF markers (the cache key depends on them)"
[ "$KEYONLY" = 1 ] && { echo "r$RECIPE-$PHASH-$BHASH"; exit 0; }
mkdir -p "$FIXROOT" || die "cannot create $FIXROOT"
FIXROOT="$(cd "$FIXROOT" && pwd)"          # the printed path must be absolute
FIX="$FIXROOT/r$RECIPE-$PHASH-$BHASH"

# One guest at a time per cache (parallel sweep rows may --ensure together; a verify must not race a build or
# another verify): the second waits.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$FIXROOT/.lock" || die "cannot open $FIXROOT/.lock"
    flock -n 9 || { say "another zfs-fixture run holds $FIXROOT/.lock — waiting"; flock 9; }
fi

if [ "$MODE" = ensure ] && [ -f "$FIX/DONE" ]; then
    say "fixture present (DONE): $FIX"
    echo "$FIX"
    exit 0
fi

T0=$(date +%s)

# ---------------------------------------------------------------------------------------------
# FreeBSD base image: download once, verify, decompress once, never modify (every boot goes through
# a throwaway qcow2 overlay; the base is also made read-only on disk).
BASE="$FIXROOT/base"
mkdir -p "$BASE" || die "cannot create $BASE"
QCOW="$BASE/$FBSD_QCOW"
XZ="$QCOW.xz"

ensure_base() {
    if [ -f "$QCOW" ] && [ -f "$QCOW.sha256" ]; then
        have=$(sha256sum < "$QCOW" | cut -d' ' -f1)
        [ "$have" = "$(cat "$QCOW.sha256")" ] && return 0
        say "base image $QCOW does not match its recorded sha256 — re-extracting it"
        chmod u+w "$QCOW" 2>/dev/null; rm -f "$QCOW" "$QCOW.sha256"
    fi
    if [ ! -f "$BASE/CHECKSUM.SHA256" ]; then
        say "fetching $FBSD_URL/CHECKSUM.SHA256"
        curl -fsSL --retry 3 -o "$BASE/CHECKSUM.SHA256.part" "$FBSD_URL/CHECKSUM.SHA256" \
            || die "download of CHECKSUM.SHA256 failed"
        mv "$BASE/CHECKSUM.SHA256.part" "$BASE/CHECKSUM.SHA256"
    fi
    want=$(awk -v f="($FBSD_QCOW.xz)" '$1 == "SHA256" && $2 == f {print $4}' "$BASE/CHECKSUM.SHA256")
    [ -n "$want" ] || die "$FBSD_QCOW.xz is not listed in $BASE/CHECKSUM.SHA256"
    [ "$want" = "$FBSD_XZ_SHA256" ] \
        || die "CHECKSUM.SHA256 says $want for $FBSD_QCOW.xz but this script pins $FBSD_XZ_SHA256"
    if [ -f "$XZ" ] && [ "$(sha256sum < "$XZ" | cut -d' ' -f1)" = "$want" ]; then
        :
    else
        say "downloading $FBSD_QCOW.xz (~665 MB, once)"
        rm -f "$XZ"
        curl -fL --retry 3 --progress-bar -o "$XZ.part" "$FBSD_URL/$FBSD_QCOW.xz" >&2 \
            || die "download of $FBSD_QCOW.xz failed"
        got=$(sha256sum < "$XZ.part" | cut -d' ' -f1)
        [ "$got" = "$want" ] || { rm -f "$XZ.part"; die "$FBSD_QCOW.xz sha256 $got != $want"; }
        mv "$XZ.part" "$XZ"
    fi
    say "decompressing the base image"
    xz -T0 -dc "$XZ" > "$QCOW.part" || { rm -f "$QCOW.part"; die "xz -d of $XZ failed"; }
    # A qcow2 can name a backing file or an external data file — a downloaded one that did would have
    # QEMU read a host file of ITS choosing into the guest. Refuse anything but a self-contained qcow2.
    qemu-img info -f qcow2 --output=json "$QCOW.part" > "$BASE/info.json" 2>&1 \
        || { rm -f "$QCOW.part"; die "qemu-img info rejected the base image: $(cat "$BASE/info.json")"; }
    python3 -I - "$BASE/info.json" <<'PY' || { rm -f "$QCOW.part"; die "base image is not a plain self-contained qcow2"; }
import json, sys
i = json.load(open(sys.argv[1]))
bad = []
if i.get("format") != "qcow2": bad.append("format=%r" % i.get("format"))
if "backing-filename" in i or "full-backing-filename" in i: bad.append("has a backing file")
if "data-file" in json.dumps(i.get("format-specific", {})): bad.append("has an external data file")
if bad:
    print("base image refused: " + ", ".join(bad), file=sys.stderr); sys.exit(1)
PY
    mv "$QCOW.part" "$QCOW"
    chmod a-w "$QCOW"
    sha256sum < "$QCOW" | cut -d' ' -f1 > "$QCOW.sha256"
}
ensure_base

# ---------------------------------------------------------------------------------------------
# The guest: a NoCloud seed + a results disk + the caller's drives, booted under KVM through a throwaway overlay.
# write_seed WORK MODE   — meta-data + user-data (+ the guest script) into WORK/seed
# boot_guest WORK TIMEOUT IDLE DRIVE-ARGS...   — boot, relay the guest's `zfsfix:` lines, enforce both deadlines;
#                                          returns QEMU's status (124 = TIMEOUT, 125 = IDLE seconds without progress)
write_seed() {
    _w=$1; _mode=$2
    # seed disk (NoCloud). FreeBSD's nuageinit (rc.d/nuageinit, 15.1) probes /dev/msdosfs/[cC][iI][dD][aA][tT][aA]
    # and mounts it READ-WRITE — a read-only QEMU drive makes that mount fail and nuageinit silently does
    # nothing. meta-data must be valid YAML; a user-data starting `#!` is run once at rc 'local' time.
    cat > "$_w/seed/meta-data" <<'EOF'
instance-id: agnos-zfs-fixture
local-hostname: zfsfix
EOF
    cat > "$_w/seed/user-data" <<EOF
#!/bin/sh
# AGNOS zfs-fixture user-data: hand off to zfs-fixture-guest.sh ($_mode), then ALWAYS ship OUT back on the
# results disk and power off, so even a guest script that dies reports why.
OUT=/var/tmp/zfsfix-out
SEED=/var/tmp/zfsfix-seed
EOF
    cat >> "$_w/seed/user-data" <<'EOF'
mkdir -p "$OUT" "$SEED"
echo "zfsfix: user-data started" > /dev/console
if mount_msdosfs -o ro /dev/msdosfs/CIDATA "$SEED"; then
    sh "$SEED/zfs-fixture-guest.sh" "$SEED" "$OUT" "$(cat "$SEED/mode.conf" 2>/dev/null || echo build)" 2>&1 \
        | tee "$OUT/guest.log" > /dev/console
else
    echo "FAIL could not mount the CIDATA seed read-only" > "$OUT/STATUS"
fi
[ -f "$OUT/STATUS" ] || echo "FAIL guest script exited without a verdict" > "$OUT/STATUS"
echo "zfsfix: STATUS $(cat "$OUT/STATUS")" > /dev/console
res=""
for d in $(sysctl -n kern.disks); do
    [ "$(diskinfo -s "$d" 2>/dev/null)" = AGNRESULT ] && res=$d
done
if [ -n "$res" ]; then
    tar -cf /var/tmp/zfsfix-results.tar -C "$OUT" .
    sz=$(stat -f %z /var/tmp/zfsfix-results.tar)
    cap=$(diskinfo "$res" | awk '{print $3}')
    if [ $((sz + 1048576)) -le "$cap" ]; then
        dd if=/var/tmp/zfsfix-results.tar of="/dev/$res" bs=1m conv=sync 2>/dev/null \
            && echo "zfsfix: results ($sz bytes) written to /dev/$res" > /dev/console
    else
        echo "zfsfix: ERROR: results tar is $sz bytes, results disk only $cap" > /dev/console
    fi
else
    echo "zfsfix: ERROR: no AGNRESULT disk" > /dev/console
fi
sync
echo "zfsfix: powering off" > /dev/console
poweroff
EOF
    echo "$_mode" > "$_w/seed/mode.conf"
    cp "$GUEST_SCRIPT" "$_w/seed/zfs-fixture-guest.sh" || die "copy guest script"
}

pack_seed() {   # WORK MB
    truncate -s $(($2 * 1048576)) "$1/seed.img" || die "truncate seed.img"
    mkfs.vfat -n CIDATA "$1/seed.img" >/dev/null || die "mkfs.vfat seed.img"
    ( cd "$1/seed" && mcopy -i "$1/seed.img" * ::/ ) || die "mcopy onto seed.img"
}

boot_guest() {   # WORK TIMEOUT IDLE DRIVE-ARGS... — returns QEMU's status, 124 = the TIMEOUT, 125 = IDLE s silent
    _w=$1; _to=$2; _idle=$3; shift 3
    qemu-img create -q -f qcow2 -b "$QCOW" -F qcow2 "$_w/overlay.qcow2" || die "cannot create the overlay"
    say "booting FreeBSD 15.1 (KVM, 4 vCPU, 4 GiB; timeout ${_to}s, or ${_idle}s without serial output; serial log $_w/log/serial.log)"
    SERIAL="$_w/log/serial.log"
    : > "$SERIAL"
    qemu-system-x86_64 -name agnos-zfs-fixture \
        -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
        -display none -monitor none -serial "file:$SERIAL" -nic none -no-reboot \
        -drive "if=none,id=sys,file=$_w/overlay.qcow2,format=qcow2" \
        -device "virtio-blk-pci,drive=sys,bootindex=0,serial=AGNSYS" \
        -drive "if=none,id=seed,file=$_w/seed.img,format=raw" \
        -device "virtio-blk-pci,drive=seed,serial=AGNSEED" \
        -drive "if=none,id=res,file=$_w/results.img,format=raw" \
        -device "virtio-blk-pci,drive=res,serial=AGNRESULT" \
        "$@" \
        > "$_w/log/qemu.log" 2>&1 &
    QPID=$!
    # an interrupted or failed run must not leave the VM behind holding the work dir's images
    trap 'kill "$QPID" 2>/dev/null' EXIT
    # relay the guest's `zfsfix:` progress lines while waiting; enforce the deadline ourselves
    _seen=0; _bytes=0
    _deadline=$(( $(date +%s) + _to )); _heard=$(date +%s)
    while kill -0 "$QPID" 2>/dev/null; do
        sleep 2
        _lines=$(wc -l < "$SERIAL")
        if [ "$_lines" -gt "$_seen" ]; then
            tail -n +$((_seen + 1)) "$SERIAL" | head -n $((_lines - _seen)) | tr -d '\r' \
                | grep '^zfsfix: ' | sed 's/^zfsfix: /  guest: /' >&2
            _seen=$_lines
        fi
        # progress = a serial line that is not the verify guest's heartbeat (which names a hung command, not progress)
        _b=$(tr -d '\r' < "$SERIAL" | grep -a -c -v '^zfsfix: heartbeat '); [ "$_b" -gt "$_bytes" ] && { _bytes=$_b; _heard=$(date +%s); }
        _rc=0
        [ "$(date +%s)" -ge "$_deadline" ] && _rc=124
        [ $(( $(date +%s) - _heard )) -ge "$_idle" ] && _rc=125
        if [ "$_rc" != 0 ]; then
            kill "$QPID" 2>/dev/null; sleep 2; kill -9 "$QPID" 2>/dev/null
            wait "$QPID" 2>/dev/null
            serial_tail
            return "$_rc"
        fi
    done
    wait "$QPID"
    _qrc=$?
    tail -n +$((_seen + 1)) "$SERIAL" | tr -d '\r' | grep '^zfsfix: ' | sed 's/^zfsfix: /  guest: /' >&2
    trap - EXIT
    return $_qrc
}

serial_tail() {
    say "---- last 60 lines of the guest serial log ($SERIAL) ----"
    tr -d '\r' < "$SERIAL" | tail -60 >&2
    say "---- end serial log ----"
}

# The tar comes from a guest, so its member names are checked before anything is extracted: the guest's
# OUT dir is flat by construction, anything else is refused.
extract_results() {   # WORK DEST — 0 extracted, 1 no readable tar
    tar -tf "$1/results.img" > "$1/log/results.list" 2>/dev/null || return 1
    _bad=$(grep -v -E '^\./([A-Za-z0-9._@+-]+)?$' "$1/log/results.list" | head -3)
    [ -z "$_bad" ] || die "results tar has unexpected member names: $_bad"
    tar -xf "$1/results.img" -C "$2" --no-same-owner --no-same-permissions || die "cannot extract the results tar"
}

# =============================================================================================
# VERIFY, part 2 (design § i.3; the guest half is zfs-fixture-guest.sh's VERIFY MODE)
if [ "$MODE" = verify ]; then
    TV0=$(date +%s)
    say "verify: $VDIR against $VFIX"
    VOUT="$VDIR/verify.out"
    rm -rf "$VOUT"
    mkdir -p "$VOUT/work/seed" "$VOUT/work/log" || void "cannot create $VOUT"
    W="$VOUT/work"
    grep -q '^mos ' "$VFIX/main.acct" 2>/dev/null || void "$VFIX predates RECIPE 3 (its .acct files carry no exact \$MOS line)"
    # ---- per-lane judgement before any boot: LST[lane] = "" (boots) | "FAIL <why>" | "VOID <why>". A defect only the
    # writer can have caused is that lane's FAIL; a missing input is that lane's VOID; neither stops the other lanes
    # (B0 review: an image 512 KiB short voided the whole run before any lane was judged).
    declare -A LST LSHA HAUD
    lfail() { LST[$1]="FAIL $2"; say "  $1: FAIL before the boot — $2"; }
    lvoid() { LST[$1]="VOID $2"; say "  $1: VOID before the boot — $2"; }
    lanes=()
    for img in "$VDIR"/*.img; do
        [ -f "$img" ] || continue
        lane=$(basename "$img" .img); base=${lane%%@*}
        lanes+=("$lane"); LST[$lane]=""; HAUD[$lane]=""
        case "$lane" in *[!A-Za-z0-9._@+-]*) lvoid "$lane" "the lane name has characters the results tar refuses"; continue ;; esac
        # The fixture's INDEX says which images are single-disk pools (the only ones a writer may touch): an image
        # whose pool appears under two image names is a mirror / raidz member — h4 (byte-identical) is its oracle.
        pool=$(awk -v i="$base" '$1 == i {print $2}' "$VFIX/INDEX")
        bytes=$(awk -v i="$base" '$1 == i {print $3}' "$VFIX/INDEX")
        [ -n "$pool" ] || { lvoid "$lane" "base image '$base' is not in $VFIX/INDEX"; continue; }
        [ "$(awk -v p="$pool" '$2 == p' "$VFIX/INDEX" | wc -l)" = 1 ] \
            || { lvoid "$lane" "pool $pool spans several images (mirror/raidz) — audit it with zfs-image-audit.py --identical, not --verify"; continue; }
        [ "$(stat -c %s "$img")" = "$bytes" ] \
            || lfail "$lane" "$img is $(stat -c %s "$img") bytes, the fixture's $base.img $bytes (a writer never changes the device size)"
    done
    [ ${#lanes[@]} -gt 0 ] || void "no <lane>.img in $VDIR"
    nboot=0; for lane in "${lanes[@]}"; do [ -z "${LST[$lane]}" ] && nboot=$((nboot + 1)); done
    [ "$nboot" -le $VERIFY_MAX_LANES ] || void "$nboot lanes to boot; at most $VERIFY_MAX_LANES per run (three disks each)"

    # per lane: expected manifest + xattrs + k.15 list, baselines, txgs, H, the image hash; the A drive is the caller's
    # file (read-only)
    : > "$W/seed/verify.conf"
    DRIVES=()
    n=0
    for lane in "${lanes[@]}"; do
        [ -z "${LST[$lane]}" ] || continue
        base=${lane%%@*}
        pool=$(awk -v i="$base" '$1 == i {print $2}' "$VFIX/INDEX")
        img="$VDIR/$lane.img"
        writer=0; { [ -f "$VDIR/$lane.expect" ] || [ -f "$VDIR/$lane.ops" ]; } && writer=1
        if [ -f "$VDIR/$lane.expect" ]; then
            cp "$VDIR/$lane.expect" "$W/seed/$lane.expect"
        elif [ -f "$VDIR/$lane.ops" ]; then
            python3 -I "$ROOT/scripts/smoke/lib/zfs-expect.py" "$VFIX/$base.manifest" "$VDIR/$lane.ops" \
                --objects "$VFIX/$base.objects" --xattrs "$VFIX/$base.xattrs" --xattrs-out "$W/seed/$lane.xattrs" \
                --leakok "$W/seed/$lane.leakok" --stat "$W/seed/$lane.stat" ${ZFS_EXPECT_ORIG:+--orig "$ZFS_EXPECT_ORIG"} \
                $( [ -d "$VDIR/$lane.orig" ] && echo "--orig $VDIR/$lane.orig" ) \
                -o "$W/seed/$lane.expect" 2>"$W/log/$lane.expect.err"
            case $? in
                0) ;;
                1) cat "$W/log/$lane.expect.err" >&2
                   lfail "$lane" "the op list is inconsistent with the fixture manifest: $(grep -m1 'FAIL' "$W/log/$lane.expect.err" | cut -c1-200)"; continue ;;
                *) cat "$W/log/$lane.expect.err" >&2
                   lvoid "$lane" "zfs-expect.py could not build the expected manifest: $(grep -m1 'UNUSABLE' "$W/log/$lane.expect.err" | cut -c1-200)"; continue ;;
            esac
            # what the ops touched, for phase C to work on: "<D|F|L> <path>" of every op operand still present
            awk '!/^#/ && NF >= 2 { for (i = 2; i <= NF && i <= 3; i++) if ($i ~ /^\//) print $i }' "$VDIR/$lane.ops" | sort -u \
                | awk 'FILENAME == ARGV[1] { if ($1 != "M") t[$2] = $1; next } ($1 in t) { print t[$1], $1 }' "$W/seed/$lane.expect" - \
                > "$W/seed/$lane.touched"
            # (1.57.12 B6) what stat(1) must say in phase B of every object the ops CREATED: "<path> <mode> <links> <size>"
            # (uid 0 and the parent directory's gid are the guest's to add) — a file the expected manifest's size, a
            # directory 2 + its entries and links 2 + its subdirectories, a symlink its target's length (B-stat). (B7) It
            # comes from zfs-expect.py --stat (above): the created objects at their FINAL names, a file's links its live
            # names — an awk over the create lines here was falsified by a later rename, link or unlink.
        else
            cp "$VFIX/$base.manifest" "$W/seed/$lane.expect"
        fi
        [ -f "$VDIR/$lane.xattrs" ] && cp "$VDIR/$lane.xattrs" "$W/seed/$lane.xattrs"
        [ -f "$W/seed/$lane.xattrs" ] || cp "$VFIX/$base.xattrs" "$W/seed/$lane.xattrs"
        [ -f "$VDIR/$lane.leakok" ] && cp "$VDIR/$lane.leakok" "$W/seed/$lane.leakok"
        # 1.57.12 B4: a writer lane without an op list names what it rewrote itself (phase C works on those first)
        [ -f "$VDIR/$lane.touched" ] && [ ! -f "$VDIR/$lane.ops" ] && cp "$VDIR/$lane.touched" "$W/seed/$lane.touched"
        cp "$VFIX/$base.acct" "$W/seed/$lane.base.acct" 2>/dev/null || { lvoid "$lane" "$VFIX has no $base.acct"; continue; }
        # RECIPE 7 (1.57.12 B9): every snapshot's own tree, pristine — what B-snap holds the lane's snapshots to
        cp "$VFIX/$base.snaps" "$W/seed/$lane.snaps" 2>/dev/null || { lvoid "$lane" "$VFIX has no $base.snaps (a fixture older than RECIPE 7)"; continue; }
        cp "$VFIX/log/$pool.dirsize" "$W/seed/$lane.base.dirsize" 2>/dev/null || : > "$W/seed/$lane.base.dirsize"
        # RECIPE 4: the ASSERT the base image's pristine pool trips in zdb -mmmm's metaslab load (logs_census's probe), if any
        sed -n 's/^load-probe ASSERT //p' "$VFIX/$base.summary" > "$W/seed/$lane.mload"; [ -s "$W/seed/$lane.mload" ] || rm -f "$W/seed/$lane.mload"
        # encrypted datasets: no key in the guest, zdb cannot walk their objects (A5 leaves them out)
        awk -F '\t' '$2 == "encryption" && $3 != "off" && $3 != "-" {print $1}' "$VFIX/$base.summary" > "$W/seed/$lane.skipds"
        # uberblock txgs: highest that VERIFIES (what an import selects), highest that merely carries the magic, and
        # the two verifying txgs below the highest (A4's rewind targets)
        read -r vtxg mtxg prev1 prev2 < <(python3 -I - "$img" <<'PY'
import hashlib, os, struct, sys
L = 256 * 1024
p = sys.argv[1]; sz = os.path.getsize(p) // L * L
f = open(p, "rb")
f.seek(16384); lab = f.read(L)
def nv(b, off):
    off += 8; out = {}
    while True:
        es, ds = struct.unpack_from(">ii", b, off)
        if es == 0 and ds == 0: return out
        q = off + 8; n = struct.unpack_from(">I", b, q)[0]; q += 4
        name = b[q:q + n].decode(); q += (n + 3) & ~3
        t, ne = struct.unpack_from(">ii", b, q); q += 8
        if t == 8: out[name] = struct.unpack_from(">Q", b, q)[0]
        elif t == 19: out[name] = nv(b, q)
        off += es
try:
    ashift = nv(lab, 4).get("vdev_tree", {}).get("ashift", 9)
except Exception:
    ashift = 9                                   # a label the writer damaged: h1 says so, the scan still runs
slot = 1 << min(max(ashift, 10), 13)
best = mag = 0
ok = set()
for base in (0, L, sz - 2 * L, sz - L):
    for s in range(128 * 1024 // slot):
        o = base + 128 * 1024 + s * slot
        f.seek(o); b = f.read(slot)
        if struct.unpack_from("<Q", b, 0)[0] != 0x00bab10c: continue
        txg = struct.unpack_from("<Q", b, 16)[0]; mag = max(mag, txg)
        if struct.unpack_from("<Q", b, slot - 40)[0] != 0x0210da7ab10c7a11: continue
        want = list(struct.unpack_from("<4Q", b, slot - 32))
        t = bytearray(b); struct.pack_into("<4Q", t, slot - 32, o, 0, 0, 0)
        d = hashlib.sha256(bytes(t)).digest()
        if [int.from_bytes(d[i:i + 8], "big") for i in range(0, 32, 8)] == want: best = max(best, txg); ok.add(txg)
prev = sorted((t for t in ok if t < best), reverse=True) + ["-", "-"]
print(best, mag, prev[0], prev[1])
PY
)
        [ -n "${vtxg:-}" ] && [ "$vtxg" -gt 0 ] || { lfail "$lane" "no uberblock in any label verifies — no OpenZFS can import this pool"; continue; }
        pimg="$VFIX/$base.img"
        [ -f "$VDIR/$lane.pristine" ] && pimg="$VDIR/$lane.pristine"
        ptxg=$(python3 -I "$ROOT/scripts/smoke/lib/zfs-image-audit.py" "$pimg" "$pimg" \
            | sed -n 's/.*pristine best txg \([0-9]*\).*/\1/p')
        [ -n "$ptxg" ] || { lvoid "$lane" "could not read the pristine best txg of $pimg"; continue; }
        # the expected txg: a writer lane MUST name it; a "nothing changed" lane expects the pristine best
        if [ -f "$VDIR/$lane.txg" ]; then
            etxg=$(tr -dc 0-9 < "$VDIR/$lane.txg")
            [ -n "$etxg" ] || { lvoid "$lane" "$lane.txg holds no number"; continue; }
        elif [ "$writer" = 1 ]; then
            lvoid "$lane" "a writer lane (.ops / .expect) must name its final txg in $lane.txg"; continue
        else
            etxg=$ptxg
        fi
        # H (host, seconds, before any boot): zfs-image-audit.py against the pristine image — labels, boot region and
        # uberblock rings changed only the way commits up to the expected txg change them (design § i.2 h1-h3)
        hcut=""; [ -f "$VDIR/$lane.cutlabels" ] && hcut="--cut-labels $(tr -dc 0-9 < "$VDIR/$lane.cutlabels")"
        # shellcheck disable=SC2086 # hcut is "" or two words
        python3 -I "$ROOT/scripts/smoke/lib/zfs-image-audit.py" "$pimg" "$img" --final-txg "$etxg" $hcut --space > "$VOUT/$lane.H.txt" 2>&1
        case $? in
            0) HAUD[$lane]="PASS $(grep -m1 '^audit: h3 ' "$VOUT/$lane.H.txt" | sed 's/^audit: h3 PASS //')" ;;
            1) HAUD[$lane]="FAIL $( { grep '^audit: h[0-9] FAIL' "$VOUT/$lane.H.txt" | sed 's/^audit: //' | cut -d' ' -f1-2;
                                         grep -m1 '^audit:   h' "$VOUT/$lane.H.txt" | sed 's/^audit: *//'; } | tr '\n' ' ')" ;;
            *) lvoid "$lane" "the image audit could not read its inputs ($VOUT/$lane.H.txt)"; continue ;;
        esac
        echo "zfs-fixture: verify $lane H ${HAUD[$lane]}" >&2
        # (1.57.12 B10, design § c.5) the live log space maps the host replay counts — the guest's A3y holds zdb -m's list
        # to it (empty when the replay finds the image inconsistent: H says why, A3y then fails)
        python3 -I "$ROOT/scripts/smoke/lib/zfs-wms-check.py" --replay "$img" 2>/dev/null \
            | sed -n 's/.* logs=\([0-9]*\) sm_alloc=.*/\1/p' | head -1 > "$W/seed/$lane.logs"
        say "verify: lane $lane (pool $pool) — copying two working images"
        cp --sparse=always "$img" "$W/$lane.C.img" && cp --sparse=always "$img" "$W/$lane.D.img" \
            || { lvoid "$lane" "cannot copy $img into $W"; continue; }
        LSHA[$lane]=$(sha256sum < "$img" | cut -d' ' -f1)
        [ "$(sha256sum < "$W/$lane.C.img" | cut -d' ' -f1)" = "${LSHA[$lane]}" ] || { lvoid "$lane" "the C copy differs from $img"; continue; }
        sa="ZFV$n-A"; sc="ZFV$n-C"; sd="ZFV$n-D"
        echo "$lane $pool $sa $sc $sd ${LSHA[$lane]} $etxg $ptxg $vtxg $mtxg $prev1 $prev2" >> "$W/seed/verify.conf"
        DRIVES+=(-drive "if=none,id=v${n}a,file=$img,format=raw,readonly=on"
                 -device "virtio-blk-pci,drive=v${n}a,serial=$sa"
                 -drive "if=none,id=v${n}c,file=$W/$lane.C.img,format=raw"
                 -device "virtio-blk-pci,drive=v${n}c,serial=$sc"
                 -drive "if=none,id=v${n}d,file=$W/$lane.D.img,format=raw"
                 -device "virtio-blk-pci,drive=v${n}d,serial=$sd")
        say "  $lane: expected txg $etxg (verifying $vtxg, magic $mtxg, pristine $ptxg), $(wc -l < "$W/seed/$lane.expect") expected manifest lines, $(wc -l < "$W/seed/$lane.xattrs") xattr lines, $( [ -f "$W/seed/$lane.leakok" ] && wc -l < "$W/seed/$lane.leakok" || echo 0) k.15 path(s)"
        n=$((n + 1))
    done

    qrc=-
    if [ "$n" -gt 0 ]; then
        printf 'continue=%s\nforce_a4=%s\n' "$VCONT" "$VFORCEA4" > "$W/seed/verify.opts"
        echo "$RECIPE verify" > "$W/seed/recipe.conf"
        write_seed "$W" verify
        pack_seed "$W" $(( $(du -sm "$W/seed" | cut -f1) + 16 ))
        truncate -s $((128 * 1048576)) "$W/results.img" || void "truncate results.img"
        VTO=${ZFS_VERIFY_TIMEOUT:-$((600 + 600 * n))}
        # silence allowed: one zdb may run its whole ZDB_TIMEOUT (900 s) without a line; the heartbeat does not count
        boot_guest "$W" "$VTO" "${ZFS_VERIFY_IDLE:-1200}" "${DRIVES[@]}"
        qrc=$?
        cp "$W/log/serial.log" "$VOUT/serial.log" 2>/dev/null
        extract_results "$W" "$VOUT" || say "results disk holds no readable tar"
    else
        say "no lane left to boot"
    fi
    # the lane images themselves: attached read-only, so still byte-identical (else the run proves nothing about
    # them: VOID); the C copy is kept as <lane>.rt.img only when the round trip produced its manifest (phase E reads it)
    for lane in "${lanes[@]}"; do
        [ -n "${LSHA[$lane]:-}" ] || continue
        [ "$(sha256sum < "$VDIR/$lane.img" | cut -d' ' -f1)" = "${LSHA[$lane]}" ] \
            || { say "$VDIR/$lane.img changed during the verify run although QEMU attached it readonly=on"; LST[$lane]="VOID the image changed during the run"; }
        if [ -f "$W/$lane.C.img" ] && grep -a -q "^zfsfix: verify $lane C-rt PASS" "$W/log/serial.log" 2>/dev/null; then
            mv "$W/$lane.C.img" "$VOUT/$lane.rt.img"
        fi
        rm -f "$W/$lane.C.img" "$W/$lane.D.img"
    done
    rm -f "$W/overlay.qcow2" "$W/seed.img" "$W/results.img"

    # ---- verdicts (judge_lanes): verify.steps authoritative, the serial log cross-checked against it ----
    ser="$VOUT/serial.log"
    tr -d '\r' < "$ser" 2>/dev/null | grep -a '^zfsfix: verify ' > "$VOUT/verify.serial.lines"
    panicked=$(tr -d '\r' < "$ser" 2>/dev/null | grep -a -m1 -E '(^|[^a-z_])panic: ')
    for lane in "${lanes[@]}"; do
        printf '%s\t%s\t%s\n' "$lane" "${LST[$lane]:-BOOT}" "${HAUD[$lane]:-}"
    done > "$VOUT/lanes.pre"
    [ "$qrc" = 124 ] || [ "$qrc" = 125 ] && serial_tail
    python3 -I - "$VOUT/lanes.pre" "$VOUT/verify.serial.lines" "$VOUT/verify.steps" "$qrc" "$panicked" > "$VOUT/verdict.txt" <<'PY'
# judge_lanes — a lane PASSes only when (a) its DONE says PASS, (b) no step says FAIL, (c) every REQUIRED step is there
# exactly once (A4 once per rewind target) and SKIPs only where MAY_SKIP allows. The guest's verify.steps (a file,
# shipped in the results tar) is authoritative once it holds the lane's DONE; the serial lines must then be a subset
# of it — a line only on the console means the file is incomplete (FAIL), a line only in the file was lost from the
# console (noted). Without the file (a guest that panicked never ships it) the serial log is judged alone.
import collections, os, sys
pre_f, ser_f, steps_f, qrc, panicked = sys.argv[1:6]
REQUIRED = ["SETUP", "A1", "A2", "A3", "A3m", "A3y", "A4", "A5", "A6", "B-import", "B-mounts", "B-manifest", "B-dirsize",
            "B-xattrs", "B-status", "B-acct", "B-snap", "B-snapacct", "B-stat", "B-acl", "C-import", "C-scrub", "C-ops",
            "C-export", "C-zdb", "C-zdbm", "C-k15", "C-rt", "D-drain", "D-destroy", "D-scrub", "D-root", "D-free", "D-zdb"]
MAY_SKIP = {"A4", "D-destroy", "D-root", "B-stat", "B-acl", "B-snap", "B-snapacct"}
MAX_TIMES = {"A4": 2}


def parse(path, serial):
    by = collections.defaultdict(lambda: {"steps": [], "done": [], "begin": 0})
    if not os.path.isfile(path):
        return None
    for raw in open(path, encoding="utf-8", errors="replace"):
        f = raw.split()
        if serial:
            if len(f) < 4 or f[0] != "zfsfix:" or f[1] != "verify":
                continue
            f = f[2:]
        if len(f) < 3:
            continue
        lane, step, verdict = f[0], f[1], f[2]
        if step == "BEGIN":
            by[lane]["begin"] += 1
        elif step == "DONE":
            by[lane]["done"].append(verdict)
        elif verdict in ("PASS", "FAIL", "SKIP", "INFO"):
            by[lane]["steps"].append((step, verdict))
    return by


ser = parse(ser_f, True) or {}
stp = parse(steps_f, False)
began = sum(v["begin"] for v in ser.values())
rc, voids, out = 0, 0, []
for raw in open(pre_f, encoding="utf-8"):
    lane, st, haud = (raw.rstrip("\n").split("\t") + ["", ""])[:3]
    if st.startswith("FAIL ") or st.startswith("VOID "):
        out.append("zfs-fixture: verify %s %s (%s)" % (lane, st[:4], st[5:]))
        rc, voids = (1, voids) if st.startswith("FAIL") else (rc, voids + 1)
        continue
    s = ser.get(lane, {"steps": [], "done": [], "begin": 0})
    t = stp.get(lane) if stp is not None else None
    have_file = t is not None and len(t["done"]) > 0
    auth = t if have_file else s
    src = "verify.steps" if have_file else "the serial log"
    if not auth["steps"] and not auth["done"]:
        if began == 0 and panicked:
            out.append("zfs-fixture: verify %s FAIL (the guest panicked before the first lane began — GEOM and ZFS taste "
                       "every attached disk at boot, so any lane can be the cause: %s)" % (lane, panicked)); rc = 1
        elif panicked:
            out.append("zfs-fixture: verify %s FAIL (never ran: the guest panicked on an earlier lane)" % lane); rc = 1
        else:
            out.append("zfs-fixture: verify %s VOID (never ran; QEMU status %s)" % (lane, qrc)); voids += 1
        continue
    if any(v == "FAIL" and k == "SETUP" for k, v in auth["steps"]):
        out.append("zfs-fixture: verify %s VOID (setup: the guest could not attach or identify the lane's disks)" % lane)
        voids += 1
        continue
    notes, red = [], []
    if have_file:
        cs, ct = collections.Counter(s["steps"]), collections.Counter(t["steps"])
        extra, lost = cs - ct, ct - cs
        if extra:
            red.append("CONSOLE")
            notes.append("console lines missing from verify.steps: %s" % ", ".join("%s %s" % k for k in sorted(extra)))
        if lost:
            notes.append("%d step line(s) lost from the console, read from verify.steps" % sum(lost.values()))
        if "FAIL" in s["done"] and "FAIL" not in t["done"]:
            red.append("DONE(console)")
    fails = []
    for k, v in auth["steps"]:
        if v == "FAIL" and k not in fails:
            fails.append(k)
    if haud.startswith("FAIL"):
        fails.insert(0, "H")
    if not auth["done"]:
        why = "did not finish"
        if panicked:
            why = "guest PANIC during the lane: %s" % panicked
        elif qrc == "124":
            why = "guest timed out during the lane"
        elif qrc == "125":
            why = "guest went silent during the lane"
        out.append("zfs-fixture: verify %s FAIL (%s; red so far: %s; judged from %s)" % (lane, why, ",".join(fails) or "none", src))
        rc = 1
        continue
    if "FAIL" in auth["done"] and not fails:
        fails.append("DONE")
    fails += [r for r in red if r not in fails]
    cnt = collections.Counter(k for k, v in auth["steps"] if v in ("PASS", "FAIL", "SKIP"))
    nsteps = sum(cnt.values()) + 2                       # + H and E (host)
    print("zfs-fixture: verify %s E SKIP not built yet (the writer's bites boot agnos on verify.out/%s.rt.img and diff %s.rt.manifest)"
          % (lane, lane, lane), file=sys.stderr)
    if fails:
        out.append("zfs-fixture: verify %s FAIL (%d steps; red: %s%s)" % (lane, nsteps, ",".join(fails), "; " + "; ".join(notes) if notes else ""))
        rc = 1
        continue
    missing = [r for r in REQUIRED if cnt[r] == 0]
    dup = ["%s x%d" % (r, cnt[r]) for r in REQUIRED if cnt[r] > MAX_TIMES.get(r, 1)]
    badskip = sorted({k for k, v in auth["steps"] if v == "SKIP" and k not in MAY_SKIP})
    if missing or dup or badskip:
        out.append("zfs-fixture: verify %s FAIL (%d steps, none red, but not a complete run: %s%s)"
                   % (lane, nsteps, "; ".join(x for x in ("missing " + ",".join(missing) if missing else "",
                                                          "repeated " + ",".join(dup) if dup else "",
                                                          "skipped " + ",".join(badskip) if badskip else "") if x),
                      "; " + "; ".join(notes) if notes else ""))
        rc = 1
        continue
    out.append("zfs-fixture: verify %s PASS (%d steps%s)" % (lane, nsteps, "; " + "; ".join(notes) if notes else ""))
if panicked:
    out.append("zfs-fixture: guest serial log shows a kernel panic: %s" % panicked)
    rc = 1
print("\n".join(out))
print("rc=%d voids=%d" % (rc, voids))
PY
    grep -v '^rc=' "$VOUT/verdict.txt"
    rc=$(sed -n 's/^rc=\([0-9]*\) .*/\1/p' "$VOUT/verdict.txt"); voids=$(sed -n 's/.* voids=\([0-9]*\)$/\1/p' "$VOUT/verdict.txt")
    [ -n "$rc" ] || void "the verdict step produced nothing ($VOUT/verdict.txt)"
    TV=$(( $(date +%s) - TV0 ))
    if [ "$rc" = 0 ] && [ "$voids" = 0 ]; then echo "zfs-fixture: verify PASS — ${#lanes[@]} lane(s) in ${TV}s ($VOUT)"; exit 0; fi
    if [ "$rc" = 0 ]; then echo "zfs-fixture: verify VOID — $voids lane(s) without a verdict, ${TV}s ($VOUT)"; exit 2; fi
    echo "zfs-fixture: verify FAIL — ${TV}s ($VOUT)"
    exit 1
fi

# =============================================================================================
# BUILD. Work directory: everything for this build lives here until it has verified.
# Under the cache lock no other build runs, so EVERY work / old dir is a leftover — not only this key's: a build of a
# key that no longer exists (a guest-script edit since) would otherwise keep its ~1 GB work dir forever.
for stale in "$FIXROOT"/r*.work.* "$FIXROOT"/r*.old.*; do
    [ -d "$stale" ] && { say "removing stale $stale"; rm -rf "$stale"; }
done
WORK="$FIX.work.$$"
mkdir -p "$WORK/img" "$WORK/seed" "$WORK/out" "$WORK/log" || die "cannot create $WORK"
say "building recipe $RECIPE ($PHASH) in $WORK"

# fixture disks: created at their final size, all-zero (the guest refuses any disk that is not blank)
DRIVES=()
n=0
echo "$IMAGES" | while read -r img serial mb pool; do
    [ -n "$img" ] || continue
    echo "$serial $img $((mb * 1048576))"
done > "$WORK/seed/disks.conf"
while read -r serial img bytes; do
    truncate -s "$bytes" "$WORK/img/$img.img" || die "truncate $img.img"
    DRIVES+=(-drive "if=none,id=z$n,file=$WORK/img/$img.img,format=raw"
             -device "virtio-blk-pci,drive=z$n,serial=$serial")
    n=$((n + 1))
done < "$WORK/seed/disks.conf"

# results disk: the guest writes one tar of its flat OUT dir onto it, raw
truncate -s $((RESULTS_MB * 1048576)) "$WORK/results.img" || die "truncate results.img"

write_seed "$WORK" build
echo "$RECIPE $PHASH" > "$WORK/seed/recipe.conf"
SEED_MB=16
if [ -n "$PAYLOAD" ]; then
    # payload travels as a tar on the seed: VFAT would fold case, mangle names and drop modes
    tar --format=pax --sort=name --owner=0 --group=0 --numeric-owner -cf "$WORK/seed/payload.tar" \
        -C "$PAYLOAD" . || die "cannot tar the payload"
    SEED_MB=$(( $(stat -c %s "$WORK/seed/payload.tar") / 1048576 * 11 / 10 + 16 ))
fi
pack_seed "$WORK" "$SEED_MB"

# ---------------------------------------------------------------------------------------------
boot_guest "$WORK" "$GUEST_TIMEOUT" "$GUEST_IDLE" "${DRIVES[@]}"
QRC=$?
[ "$QRC" = 124 ] && die "guest did not power off within ${GUEST_TIMEOUT}s (work dir kept: $WORK)"
[ "$QRC" = 125 ] && die "guest printed nothing on its serial console for ${GUEST_IDLE}s — hung, not slow (work dir kept: $WORK)"
if [ "$QRC" -ne 0 ]; then
    cat "$WORK/log/qemu.log" >&2
    serial_tail
    die "QEMU exited with status $QRC (work dir kept: $WORK)"
fi

# ---------------------------------------------------------------------------------------------
# Results.
extract_results "$WORK" "$WORK/out" \
    || { serial_tail; die "results disk holds no readable tar — the guest never shipped results (work dir: $WORK)"; }
STATUS=$(cat "$WORK/out/STATUS" 2>/dev/null)
if [ "$STATUS" != OK ]; then
    if [ -f "$WORK/out/guest.log" ]; then
        say "---- guest.log tail ----"; tail -40 "$WORK/out/guest.log" >&2
    else
        serial_tail      # an all-zero results disk reads as an EMPTY tar: no guest.log, no STATUS
    fi
    die "guest reported: ${STATUS:-no STATUS file} (work dir kept: $WORK)"
fi

# every image: present in the guest's final device hashes, same bytes on the host (no write lost
# between the guest's last sync and QEMU's exit), and an exported ZFS label in all four label slots
while read -r serial img bytes; do
    for ext in manifest summary xattrs objects acct; do
        [ -s "$WORK/out/$img.$ext" ] || [ "$ext" = xattrs ] || die "guest produced no $img.$ext"
        [ -f "$WORK/out/$img.$ext" ] || die "guest produced no $img.$ext"
    done
    g=$(awk -v i="$img" '$1 == i {print $2}' "$WORK/out/images.sha256")
    h=$(sha256sum < "$WORK/img/$img.img" | cut -d' ' -f1)
    [ -n "$g" ] || die "guest recorded no device hash for $img"
    [ "$g" = "$h" ] || die "$img.img: host sha256 $h != the guest's device sha256 $g"
    [ "$(stat -c %s "$WORK/img/$img.img")" = "$bytes" ] || die "$img.img is no longer $bytes bytes"
done < "$WORK/seed/disks.conf"

echo "$IMAGES" | awk 'NF == 4 {print $1, $4}' > "$WORK/log/image-pools"
python3 -I - "$WORK/img" "$WORK/log/image-pools" > "$WORK/log/labels.txt" <<'PY' || { cat "$WORK/log/labels.txt" >&2; die "host-side label check failed"; }
# Independent of the guest's zdb: decode the four vdev labels of every image the way a reader must.
# Label l (256 KiB) sits at 0, 256K, size-512K, size-256K; its packed nvlist at +16 KiB starts with
# the header 01 01 00 00 (XDR encoding, little-endian host); its uberblock ring is the last 128 KiB.
import os, struct, sys
LABEL = 256 * 1024
def nvpairs(b, off):
    off += 8                                   # nvl_version, nvl_nvflag
    out = {}
    while True:
        esize, dsize = struct.unpack_from(">ii", b, off)
        if esize == 0 and dsize == 0:
            return out
        p = off + 8
        nlen = struct.unpack_from(">I", b, p)[0]; p += 4
        name = b[p:p + nlen].decode(); p += (nlen + 3) & ~3
        dtype, nelem = struct.unpack_from(">ii", b, p); p += 8
        if dtype == 8:                         # DATA_TYPE_UINT64
            out[name] = struct.unpack_from(">Q", b, p)[0]
        elif dtype == 9:                       # DATA_TYPE_STRING
            slen = struct.unpack_from(">I", b, p)[0]; p += 4
            out[name] = b[p:p + slen].decode()
        off += esize
imgdir, mapfile = sys.argv[1], sys.argv[2]
pools = dict(l.split() for l in open(mapfile) if l.strip())
guids = {}
bad = 0
for img, pool in sorted(pools.items()):
    path = os.path.join(imgdir, img + ".img")
    size = os.path.getsize(path) // LABEL * LABEL
    with open(path, "rb") as f:
        for l, base in enumerate((0, LABEL, size - 2 * LABEL, size - LABEL)):
            f.seek(base); lab = f.read(LABEL)
            hdr = lab[16384:16388]
            if hdr != b"\x01\x01\x00\x00":
                print("%s label %d @%#x: nvlist header %s" % (img, l, base + 16384, hdr.hex())); bad = 1; continue
            nv = nvpairs(lab, 16388)
            ubs = [o for o in range(128 * 1024, LABEL, 1024)
                   if struct.unpack_from("<Q", lab, o)[0] == 0x00bab10c]
            txgs = [struct.unpack_from("<Q", lab, o + 16)[0] for o in ubs]
            print("%-9s L%d @%#09x name=%s state=%s pool_guid=%s txg=%s version=%s uberblocks=%d max_ub_txg=%s"
                  % (img, l, base, nv.get("name"), nv.get("state"), nv.get("pool_guid"), nv.get("txg"),
                     nv.get("version"), len(ubs), max(txgs) if txgs else None))
            if nv.get("name") != pool or nv.get("state") != 1 or not ubs:
                print("  ^ BAD: want name=%s state=1 (EXPORTED) and at least one uberblock" % pool); bad = 1
            g = guids.setdefault(pool, nv.get("pool_guid"))
            if g != nv.get("pool_guid"):
                print("  ^ BAD: pool_guid differs from another label/member of %s" % pool); bad = 1
sys.exit(bad)
PY
say "host label check: all 4 labels of every image say EXPORTED, right pool, uberblocks present"

# ---------------------------------------------------------------------------------------------
# Assemble. DONE is written last, inside the work dir, and the dir is renamed into place in one step.
for f in "$WORK"/img/*.img; do mv "$f" "$WORK/"; done
rmdir "$WORK/img"
mv "$WORK"/out/*.manifest "$WORK"/out/*.summary "$WORK"/out/*.xattrs "$WORK"/out/*.objects "$WORK"/out/*.acct "$WORK"/out/*.snaps "$WORK/" \
    || die "cannot place the oracle files"
mv "$WORK"/out/* "$WORK/log/"
rmdir "$WORK/out"
rm -rf "$WORK/seed" "$WORK/seed.img" "$WORK/results.img" "$WORK/overlay.qcow2"
( cd "$WORK" && sha256sum -- *.img > SHA256SUMS ) || die "SHA256SUMS"
{
    echo "# image  pool  bytes  (members of one pool share an identical .manifest)"
    echo "$IMAGES" | awk 'NF == 4 {print $1, $4, $3 * 1048576}'
} > "$WORK/INDEX"
{
    echo "recipe $RECIPE"
    echo "payload $PHASH${PAYLOAD:+ $PAYLOAD}"
    echo "base $FBSD_QCOW.xz sha256 $FBSD_XZ_SHA256"
    echo "openzfs $(grep -m1 '^zfs-' "$WORK/log/guest-info.txt")"
    echo "guest build half sha256/8 $BHASH (zfs-fixture-guest.sh without its VERIFY HALF + the disk table + RECIPE)"
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) in $(( $(date +%s) - T0 ))s"
} > "$WORK/RECIPE"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/DONE"

OLD=""
if [ -e "$FIX" ]; then OLD="$FIX.old.$$"; mv "$FIX" "$OLD" || die "cannot move the old fixture aside"; fi
mv "$WORK" "$FIX" || die "cannot rename $WORK to $FIX"
[ -n "$OLD" ] && rm -rf "$OLD"
say "fixture built in $(( $(date +%s) - T0 ))s: $FIX"
echo "$FIX"
