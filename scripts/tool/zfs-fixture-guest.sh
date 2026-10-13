#!/bin/sh
# zfs-fixture-guest.sh — the FreeBSD half of scripts/tool/zfs-fixture.sh. NEVER run this on the host.
#
# Runs INSIDE the throwaway FreeBSD 15.1 guest, as root, once: nuageinit's user-data (written by
# zfs-fixture.sh) mounts the CIDATA seed read-only and hands off here, then ships OUT back on the
# results disk and powers off whatever this script did. It builds every recipe pool with the guest's
# own OpenZFS on WHOLE raw virtio disks, then re-reads each pool through a read-only import under an
# altroot and writes the manifest the AGNOS ZFS smoke compares the kernel's view against.
#
# usage: sh zfs-fixture-guest.sh SEED_DIR OUT_DIR [build | verify]
#   SEED_DIR  the mounted CIDATA disk: this script, disks.conf, recipe.conf, optional payload.tar
#             (verify: verify.conf, verify.opts and the per-lane expected manifests / baselines instead)
#   OUT_DIR   flat results directory (no subdirectories: the host extracts it with a name check)
#   build     (default) the recipe below; verify: the WRITE ORACLE (§ "VERIFY MODE" at the end of this file)
#
# ⛔ Every pool goes onto a disk found BY ITS VIRTIO SERIAL (diskinfo -s), cross-checked against the
# size the host promised in disks.conf and proven all-zero at both ends before the first write. The
# vtbdN numbering is an enumeration order, not a contract — never write a pool onto a guessed name.
#
# The oracle's chain of evidence, per pool:
#   create + populate (read-write, altroot /mnt/rw)    every file's sha256 is registered in
#                                                      <pool>.expect from a SECOND run of its
#                                                      generator, never by reading the pool back
#   zpool sync, zpool export
#   import -o readonly=on -R /mnt/m, zfs mount -a      the view the kernel smoke must reproduce
#   manifest from that view                            then every <pool>.expect line must match it
#   export; device sha256 must equal the pre-import    proves the image IS what the manifest says
#   zdb -l / -e ... dumps                              the kernel author's debugging oracle
#   <image>.acct (RECIPE 2; + origin / type / volumes,  the pristine ACCOUNTING baseline the write oracle
#   the pool's freeing / leaked and the exact $MOS       measures deltas against (see acct_capture, oracle)
#   figures since RECIPE 3; numeric owner ids since 4)
#   (RECIPE 4) the logs pool's log census             zdb -mmmm -L: the log space maps its export KEPT, U[] per
#                                                      metaslab, FREEs later txgs reallocated; + the metaslab-load
#                                                      probe (plain -mmmm, as A3m runs it) (logs_census)
#   (RECIPE 7) <image>.snaps                           every snapshot's own tree, mounted read-only (snap_manifests):
#                                                      what the verify's B-snap holds a writer's pool to

set -u

SEED=${1:?usage: zfs-fixture-guest.sh SEED_DIR OUT_DIR [build|verify]}
OUT=${2:?usage: zfs-fixture-guest.sh SEED_DIR OUT_DIR [build|verify]}
GUEST_MODE=${3:-build}
RW=/mnt/rw                  # altroot while building (keeps the guest's own / untouched)
RO=/mnt/m                   # altroot of the read-only re-import: the manifest's "/"
CA=/mnt/c                   # verify: altroot of phase C's read-write round trip
TMP=/var/tmp/zfsfix         # UFS scratch: makefs staging, payload staging
SECRET_PASS="agnos-zfs-fixture-passphrase"
RECIPE_IMAGES="main ashift9 v28 mirror-a mirror-b makefs raidz-0 raidz-1 raidz-2 wr full logs fz"
VERIFY_MODE=0               # 1: helpers shared with the build return non-zero instead of ending the run

log() { echo "zfsfix: $*"; }
# a helper's failure: fatal while building, a non-zero return (message in HELPER_ERR) while verifying, where one
# lane's defect must not stop the lanes after it
herr() { HELPER_ERR="$*"; [ "$VERIFY_MODE" = 1 ] && { log "  ($*)"; return 1; }; die "$*"; }
die() {
    echo "zfsfix: ERROR: $*"
    echo "FAIL $*" > "$OUT/STATUS"
    exit 1
}
run() { "$@" || die "command failed (rc=$?): $*"; }

# ---------------------------------------------------------------------------------------------
# Deterministic content. AES-128-CTR keystream keyed by sha256(seed) is a reproducible stand-in for
# "random": incompressible, and the same bytes on every rebuild.
rand_bytes() {    # SEED NBYTES
    _k=$(printf '%s' "$1" | sha256 -q | cut -c1-32)
    head -c "$2" /dev/zero | openssl enc -aes-128-ctr -K "$_k" -iv 00000000000000000000000000000000
}
text_bytes() {    # SEED NBYTES — compressible, but not trivially (the numbers vary per line)
    awk -v s="$1" -v n="$2" 'BEGIN {
        for (i = 0; i * 40 < n + 80; i++)
            printf "%s %07d the quick brown fox jumps over the lazy dog %d\n", s, i, (i * 7919) % 10007
    }' | head -c "$2"
}
zero_bytes() { head -c "$1" /dev/zero; }
# zle-friendly: per 128 KiB record, 8 KiB of keystream then 120 KiB of zeros
zle_bytes() {     # SEED NRECORDS
    _zi=0
    while [ "$_zi" -lt "$2" ]; do
        rand_bytes "$1-$_zi" 8192
        zero_bytes 122880
        _zi=$((_zi + 1))
    done
}
# sparse.bin's full logical content, generated end to end (the file itself is built with truncate +
# dd seek, so the two methods must agree byte for byte)
sparse_bytes() {
    rand_bytes sparse-0 4096
    zero_bytes $((3145728 - 4096))
    rand_bytes sparse-3m 4096
    zero_bytes $((8388608 - 4096 - 3145728 - 4096))
    rand_bytes sparse-end 4096
}

# put POOL ABSPATH-UNDER-ALTROOT GENERATOR ARGS...
#   write the file through the pool, then register the sha256 of an independent second run of the
#   generator. The manifest (read back after export + read-only import) must reproduce it.
put() {
    _pool=$1; _p=$2; shift 2
    "$@" > "$RW$_p" || die "write $_p"
    _h=$("$@" | sha256 -q) || die "hash $_p"
    echo "$_p $_h" >> "$OUT/$_pool.expect"
}
# a file that must NOT be visible in the read-only view (legacy mount, encrypted without key)
hidden() { echo "$2" >> "$OUT/$1.hidden"; }
# unput POOL ABSPATH-UNDER-ALTROOT: remove a file put registered, and its registry line (RECIPE 4's churn)
unput() {
    rm "$RW$2" || die "rm $2"
    awk -v p="$2" '$1 != p' "$OUT/$1.expect" > "$OUT/$1.expect.new" && mv "$OUT/$1.expect.new" "$OUT/$1.expect" \
        || die "unput $2: the registry"
}
# hash_tree DIR PREFIX: "<PREFIX>/<relpath> <sha256>" for every regular file under DIR. One sha256 -q
# per file on purpose: `sha256 -r` ESCAPES non-ASCII file names in its output (measured: the UTF-8
# name came back unmatchable), so a name is never parsed back out of a hashing tool's output.
hash_tree() {
    ( cd "$1" && find . -type f -print ) | while IFS= read -r _hp; do
        printf '%s %s\n' "$2${_hp#.}" "$(sha256 -q "$1/$_hp")"
    done
}

# ---------------------------------------------------------------------------------------------
# Disk mapping. disks.conf lines: "<virtio-serial> <image-basename> <bytes>".
ZERO1M=$(head -c 1048576 /dev/zero | sha256 -q)

map_disks() {
    : > "$OUT/disks.map"
    for d in $(sysctl -n kern.disks); do
        case "$d" in vtbd*) ;; *) continue ;; esac
        _id=$(diskinfo -s "$d" 2>/dev/null) || continue
        _sz=$(diskinfo "$d" | awk '{print $3}')
        echo "$_id $d $_sz" >> "$OUT/disks.map"
    done
    log "virtio disks (serial dev bytes):"
    sed 's/^/zfsfix:   /' "$OUT/disks.map"
    while read -r _id _img _sz; do
        [ -n "$_id" ] || continue
        _n=$(awk -v i="$_id" '$1 == i' "$OUT/disks.map" | wc -l | tr -d ' ')
        [ "$_n" = 1 ] || die "disk serial $_id ($_img) seen $_n times — refusing to guess"
        _dev=$(awk -v i="$_id" '$1 == i {print $2}' "$OUT/disks.map")
        _have=$(awk -v i="$_id" '$1 == i {print $3}' "$OUT/disks.map")
        [ "$_have" = "$_sz" ] || die "disk $_id is /dev/$_dev with $_have bytes, host promised $_sz"
        # blank at both ends: a boot disk, a reused image or a mis-mapped disk is never all-zero there
        _h1=$(dd if="/dev/$_dev" bs=1m count=1 2>/dev/null | sha256 -q)
        _h2=$(dd if="/dev/$_dev" bs=1m skip=$((_sz / 1048576 - 1)) count=1 2>/dev/null | sha256 -q)
        [ "$_h1" = "$ZERO1M" ] && [ "$_h2" = "$ZERO1M" ] \
            || die "disk $_id (/dev/$_dev) is not blank — refusing to write a pool over it"
        log "  $_img -> /dev/$_dev ($_sz bytes, blank) OK"
    done < "$SEED/disks.conf"
    # every image this recipe writes must have been handed over (dev() runs in $(...), where a die
    # would only end the subshell — so the whole set is proven here, in the main shell)
    for _img in $RECIPE_IMAGES; do
        awk -v i="ZFX-$_img" '$1 == i {f = 1} END {exit !f}' "$OUT/disks.map" \
            || die "the host attached no disk with serial ZFX-$_img"
    done
}
dev() {   # image basename -> /dev/vtbdN (the mapping map_disks already proved)
    awk -v i="ZFX-$1" '$1 == i {print "/dev/" $2}' "$OUT/disks.map"
}
hash_devs() { for _d in "$@"; do sha256 -q "$_d"; done | tr '\n' ' '; }

# ---------------------------------------------------------------------------------------------
# Manifest of the view under $RO. Format (sorted bytewise by path, then by type letter):
#   D <path>            directory            F <path> <size> <sha256>   regular file
#   L <path> <target>   symlink (verbatim)   M <path> <dataset>         mounted dataset
write_manifest() {   # POOL OUTFILE [DIRSIZE-OUT]
    _pool=$1; _mf=$2; _t="$TMP/mf.$_pool"; _dsz=${3:-$OUT/$_pool.dirsize}
    rm -rf "$_t"; mkdir -p "$_t"
    (
        cd "$RO" || exit 1
        # ⛔ EVERY walk here carries `-links +0` (always true) because that primary makes find(1) lstat
        # EVERY entry. Without one, fts(3) runs FTS_NOSTAT and, on "links-reliable" filesystems (zfs is
        # on its list), trusts a directory's link count to say how many subdirectories it holds: once
        # that many are seen, the rest are assumed to be files — not stat'ed, NOT DESCENDED. makefs -t zfs
        # writes its root directory with links=3 while it holds two subdirectories, and MEASURED: `find .
        # -type d` (which keeps FTS_NOSTAT) silently left dir500 out of the manifest while `-type f` (which
        # does not) still listed dir500's files. A walk that trusts on-disk link counts is not an oracle.
        # The manifest is whitespace-separated: a name with a space, tab or newline cannot be represented.
        _n1=$(find . -links +0 -print | wc -l | tr -d ' ')
        _n0=$(find . -links +0 -print0 | tr -dc '\000' | wc -c | tr -d ' ')
        [ "$_n1" = "$_n0" ] || { echo "a name under $RO contains a newline"; exit 1; }
        if find . -links +0 -print | grep -q '[[:space:]]'; then
            echo "names with whitespace under $RO:"; find . -links +0 -print | grep '[[:space:]]'; exit 1
        fi
        # one lstat per entry: "<mode string> <size> <./path>" — the type comes from lstat, never readdir
        find . -links +0 -exec stat -f '%Sp %z %N' {} + > "$_t/all"
        [ "$(wc -l < "$_t/all")" -eq "$_n1" ] || { echo "stat walk saw a different entry count"; exit 1; }
        awk '{ t = substr($1, 1, 1); if (t != "d" && t != "-" && t != "l") { print "unsupported type: " $0; bad = 1 } }
             END { exit bad }' "$_t/all" || exit 1
        awk '$1 ~ /^d/ { p = $3; sub(/^\./, "", p); if (p == "") p = "/"; print "D " p }' "$_t/all" > "$_t/d"
        # hashed one file at a time on purpose — see hash_tree
        awk '$1 ~ /^-/ { print $3, $2 }' "$_t/all" | while read -r _p _sz; do
            printf 'F %s %s %s\n' "${_p#.}" "$_sz" "$(sha256 -q "$_p")"
        done > "$_t/f"
        awk '$1 ~ /^l/ { print $3 }' "$_t/all" | while IFS= read -r _p; do
            printf 'L %s %s\n' "${_p#.}" "$(readlink "$_p")"
        done > "$_t/l"
        # a ZPL directory's st_size is its entry count + 2: an independent count to hold the walk to
        find . -links +0 -fstype zfs -type d -exec stat -f '%z %N' {} + > "$_t/dsz"
    ) || { herr "manifest walk of $_pool failed"; return 1; }
    zfs list -H -o name,mountpoint,mounted -r "$_pool" | awk -F '\t' -v ro="$RO" '
        $3 == "yes" { p = $2; if (p == ro) p = "/"; else if (index(p, ro "/") == 1) p = substr(p, length(ro) + 1);
                      else { print "BAD mountpoint outside altroot: " $0 > "/dev/stderr"; exit 1 }
                      print "M " p " " $1 }' > "$_t/m" || { herr "mount list of $_pool failed"; return 1; }
    cat "$_t/d" "$_t/f" "$_t/l" "$_t/m" | LC_ALL=C sort -t ' ' -k2,2 -k1,1 > "$_mf"
    grep -q '^F .* $' "$_mf" && { herr "manifest of $_pool has an F line without a hash"; return 1; }
    # directory-size cross-check: every ZFS directory's (st_size - 2) vs its children in the manifest
    awk 'NR == FNR { if ($1 == "M" || $2 == "/") next
                     p = $2; sub(/\/[^\/]*$/, "", p); if (p == "") p = "/"; n[p]++; next }
         { d = $2; sub(/^\./, "", d); if (d == "") d = "/"
           printf "%s %s size=%d entries=%d\n", (($1 - 2) == n[d] + 0 ? "OK      " : "MISMATCH"), d, $1, n[d] + 0 }' \
        "$_mf" "$_t/dsz" | LC_ALL=C sort -b -k2,2 > "$_dsz"
    log "  manifest: $(grep -c '^D ' "$_mf") D, $(grep -c '^F ' "$_mf") F, $(grep -c '^L ' "$_mf") L, $(grep -c '^M ' "$_mf") M"
    if grep -q '^MISMATCH' "$_dsz"; then
        grep '^MISMATCH' "$_dsz" | sed 's/^/zfsfix:   dir size /'
        # makefs's own directory accounting is checked against, not trusted (see build_makefs); an
        # OpenZFS-written pool whose directory sizes disagree with the walk means the WALK is wrong.
        # (verify: the B-dirsize step judges a mismatch against the PRISTINE dirsize instead)
        [ "$_pool" = agnosmk ] || [ "$VERIFY_MODE" = 1 ] || die "$_pool: directory sizes disagree with the manifest walk"
    fi
    return 0
}

# (RECIPE 7, agnos 1.57.12 B9) every SNAPSHOT of POOL as its own tree: a `S <snapshot>` line, then its D / F / L lines
# (paths from the snapshot's root, sorted like the manifest) — the snapshot mounted read-only (mount -t zfs) and walked
# the way write_manifest walks. The oracle's baseline (<image>.snaps) and the verify's B-snap measure with this one
# function: a writer that freed (and reused) or rewrote a block a snapshot still owns shows as the snapshot's own
# contents changed.
snap_manifests() {   # POOL OUTFILE
    : > "$2"
    _sm="$TMP/snapmnt"
    for _sn in $(zfs list -H -t snapshot -o name -s name -r "$1"); do
        rm -rf "$_sm"; mkdir -p "$_sm"
        mount -t zfs "$_sn" "$_sm" 2> "$TMP/snap.err" || { herr "mount -t zfs $_sn: $(head -1 "$TMP/snap.err")"; return 1; }
        echo "S $_sn" >> "$2"
        (
            cd "$_sm" || exit 1
            find . -links +0 -exec stat -f '%Sp %z %N' {} + > "$TMP/snap.all" || exit 1
            awk '$1 ~ /^d/ { p = $3; sub(/^\./, "", p); if (p == "") p = "/"; print "D " p }' "$TMP/snap.all"
            awk '$1 ~ /^-/ { print $3, $2 }' "$TMP/snap.all" | while read -r _p _sz; do
                printf 'F %s %s %s\n' "${_p#.}" "$_sz" "$(sha256 -q "$_p")"
            done
            awk '$1 ~ /^l/ { print $3 }' "$TMP/snap.all" | while IFS= read -r _p; do printf 'L %s %s\n' "${_p#.}" "$(readlink "$_p")"; done
        ) > "$TMP/snap.mf"
        _src=$?
        umount "$_sm" 2>/dev/null || umount -f "$_sm"
        [ "$_src" = 0 ] || { herr "walk of $_sn failed"; return 1; }
        LC_ALL=C sort -t ' ' -k2,2 -k1,1 "$TMP/snap.mf" >> "$2"
    done
    return 0
}

# extended attributes in the view (not part of the manifest contract): X <path> user <name> <len> <sha256>
write_xattrs() {     # OUTFILE
    : > "$1"
    ( cd "$RO" && find . -links +0 \( -type f -o -type d \) -exec lsextattr -f user {} + ) 2>/dev/null |
    while IFS="$(printf '\t')" read -r _p _names; do
        [ -n "$_names" ] || continue
        for _a in $(echo "$_names" | tr '\t' ' '); do
            _len=$(getextattr -qq user "$_a" "$RO/$_p" | wc -c | tr -d ' ')
            _h=$(getextattr -qq user "$_a" "$RO/$_p" | sha256 -q)
            echo "X ${_p#.} user $_a $_len $_h"
        done
    done | LC_ALL=C sort > "$1"
}

# every dataset that SHOULD be mounted in the read-only view must be, and nothing else
check_mounts() {     # POOL
    zfs list -H -o name,mountpoint,canmount,keystatus,mounted -r -t filesystem "$1" | awk -F '\t' '
        { want = ($3 == "on" && $2 != "legacy" && $2 != "none" && ($4 == "-" || $4 == "available")) ? "yes" : "no"
          if (want != $5) { print "dataset " $1 " mounted=" $5 " expected " want; bad = 1 } }
        END { exit bad }' || { herr "read-only import of $1 did not mount the expected set of datasets"; return 1; }
}

# every registered file must be in the manifest with the generator's hash; hidden ones must be absent
check_expect() {     # POOL MANIFEST
    [ -s "$OUT/$1.expect" ] || die "no expected-content registry for $1"
    awk 'NR == FNR { if ($1 == "F") h[$2] = $4; next }
         { if (!($1 in h)) { print "MISSING " $1; bad = 1 }
           else if (h[$1] != $2) { print "HASH MISMATCH " $1 " manifest=" h[$1] " expected=" $2; bad = 1 } }
         END { exit bad }' "$2" "$OUT/$1.expect" || die "$1: manifest disagrees with what was written"
    if [ -f "$OUT/$1.hidden" ]; then
        while read -r _h; do
            grep -E -q " $_h( |\$)" "$2" && die "$1: $_h must not be visible in the read-only view"
            grep -E -q "/$(basename "$_h")( |\$)" "$2" && die "$1: $(basename "$_h") leaked into the view"
        done < "$OUT/$1.hidden"
    fi
    log "  $(wc -l < "$OUT/$1.expect" | tr -d ' ') written files read back byte-exact through the read-only import"
}

zdb_sec() {          # SUMMARY ARGS... — append a zdb run (zdb never writes)
    _s=$1; shift
    { echo; echo "======== zdb $* ========"; zdb "$@" 2>&1; echo "======== rc=$? ========"; } >> "$_s"
}

# ---------------------------------------------------------------------------------------------
# ACCOUNTING (RECIPE 2). zdb never checks dd_used, ds_referenced, userused or object counts
# (zfs-write-prior-art.md § 12), so the write oracle proves them by DELTAS against a baseline taken here,
# once, from the pristine pool — the same capture code runs again in verify phase B, so the two sides
# can only differ by what the writer did. Line formats (dataset/user names carry no spaces here):
#   get <dataset> <property> <value>                  zfs get -Hp, every filesystem AND volume ('-' where none; a
#                                                     volume's used counts in its parent's usedbychildren)
#   pool <freeing|leaked> <bytes>                      zpool get -Hp: the $FREE / $LEAK dsl_dirs' dd_used_bytes
#                                                     (spa.c:517-533) — two of the root's hidden children
#   space <user|group|project> <dataset> <id> <used> <objused>      zfs {user,group}space -Hpn (RECIPE 4: NUMERIC ids —
#                                                     wr owns a file by 1001:1002, and a name is whatever the guest's
#                                                     passwd says; design k.34) and zfs projectspace -Hp (numeric by
#                                                     nature: it REFUSES -n), MOUNTED datasets
#                                                     only — ⛔ MEASURED (B0 review run): on the read-only import,
#                                                     `zfs groupspace agnostank/coff` (canmount=off: FreeBSD builds a
#                                                     temporary zfsvfs for it) hung the guest for 10 minutes,
#                                                     intermittently; the identity that reads these lines (acct_check
#                                                     3) needs the dataset's mounted view anyway
#   dev <dataset> <st_dev>                            every MOUNTED dataset's device in the read-only view
#   devobjs <st_dev> <n>                              distinct (st_dev, inode) pairs the view shows
#   alloc zdb <bp allocated> <Normal class> <clean | leaked:N>    zdb -bb; only a `clean` record (zdb said
#                                                     "No leaks") means bp allocated == every allocated byte
#   alloc rwimport <allocated> <free> <size> <freeing> <leaked>   zpool get -Hp, writable import of a COPY
#   mos <dd_used> <Σ dsize> <objset block asize>      (oracle(), exported pool) $MOS's dd_used_bytes exactly (zdb -P
#                                                     prints it raw on the "Dataset mos" line, zdb.c:4321-4325), the
#                                                     -dd dsize of every MOS object (the meta-dnode as object 0
#                                                     included) and the uberblock rootbp's asize: the third hidden
#                                                     child and the identity the verify's A6 holds the writer to
# ⛔ NEVER `allocated` from the read-only import: a read-only open loads no space map and skips the log
# space maps, so it reads 0 (RECIPE 1 main.summary: allocated 0 for a pool zfs list puts at 19.3M; design
# § i.3 B review fix). The rwimport line already contains that import's own txgs (history, config), so it
# is information; the delta identity uses the zdb line.
acct_capture() {    # POOL OUTFILE — pool imported read-only under $RO, every mountable dataset mounted
    _ap=$1; _ao=$2
    {
        zfs get -Hp -r -t filesystem,volume -o name,property,value \
            used,referenced,usedbydataset,usedbysnapshots,usedbychildren,usedbyrefreservation,logicalreferenced,written,reservation,refreservation,quota,refquota,mounted,encryption,origin,type \
            "$_ap" | awk -F '\t' '{ print "get", $1, $2, $3 }'
        zpool get -Hp -o property,value freeing,leaked "$_ap" | awk -F '\t' '{ print "pool", $1, $2 }'
        # (RECIPE 7) each filesystem's own snapshot count (B-acct's clone identity needs to know which have none)
        zfs list -H -t snapshot -o name -r "$_ap" | awk -F '@' '{ n[$1]++ } END { for (d in n) print "snaps", d, n[d] }'
        for _ads in $(zfs list -H -o name,mounted -t filesystem -r "$_ap" | awk -F '\t' '$2 == "yes" { print $1 }'); do
            for _ak in user group project; do
                _an=-n; [ "$_ak" = project ] && _an=""
                zfs ${_ak}space -Hp $_an -o name,used,objused "$_ads" 2>/dev/null \
                    | awk -F '\t' -v k="$_ak" -v d="$_ads" 'NF >= 3 { print "space", k, d, $1, $2, $3 }'
            done
        done
        zfs list -H -o name,mountpoint,mounted -r -t filesystem "$_ap" | awk -F '\t' '$3 == "yes" { print $1, $2 }' \
            | while read -r _ads _amp; do echo "dev $_ads $(stat -f %d "$_amp")"; done
        ( cd "$RO" && find . -links +0 -exec stat -f '%d %i' {} + ) | sort -u \
            | awk '{ c[$1]++ } END { for (d in c) print "devobjs", d, c[d] }'
    } > "$_ao"
    grep -q '^get ' "$_ao" && grep -q '^devobjs ' "$_ao" && grep -q '^pool freeing ' "$_ao" && grep -q '^pool leaked ' "$_ao" \
        && ! awk '$1 == "space" && $2 != "project" && $4 !~ /^[0-9]+$/ { bad = 1 } END { exit !bad }' "$_ao"
}

# ---- zdb parsers shared by the baseline (here) and the verify (below the VERIFY HALF marker) ----
# zdd_figures FILE — a `zdb -P -dd` dump of ONE objset (a dataset, or the MOS with an object range) →
#   "<header bytes> <header objects> <object rows >= 1> <Σ dsize over every object row>"
# The header is "Dataset <name> [<type>], ID n, cr_txg n, <bytes>, <N> objects[, rootbp ...]" (zdb.c:4343-4348):
# <bytes> is ds_referenced_bytes for a dataset (dmu_objset_space) and $MOS's dd_used_bytes for the MOS, raw under -P.
# Rows follow the "Object lvl iblk dblk dsize ..." header (dump_object, "%10lld  %3u ..."): the meta-dnode is object
# 0, the user/group/project-used objects are -1..-3; dsize = dn_used (doi_physical_blocks_512 << 9), raw under -P.
zdd_figures() {
    awk '/^Dataset / && !h { for (i = 2; i < NF; i++) if ($(i + 1) ~ /^objects/) { o = $i; b = $(i - 1); sub(/,$/, "", b) } h = 1; next }
         /^ +Object +lvl +iblk +dblk +dsize/ { t = 1; next }
         t && NF >= 9 && $1 ~ /^-?[0-9]+$/ && $2 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ { s += $5; if ($1 + 0 >= 1) n++ }
         END { if (!h || b == "") exit 1; printf "%s %s %d %.0f\n", b, o, n, s }' "$1"
}
# zdb_assert FILE — "<file>:<line>:<function>() <condition>" of the first libzpool ASSERT in a zdb output, '' when none.
# ⚠ MEASURED (RECIPE 4): the ASSERT text can land MID-LINE — stderr's "ASSERT at ..." appended to a half-flushed stdout
# line ("[  1496] A range: 000001007ASSERT at /usr/src/...") — so it is found anywhere on a line, never only at its start
zdb_assert() {
    awk '{ i = index($0, "ASSERT at "); if (i) { a = substr($0, i + 10); c = ""; getline c; print a " " c; exit } }' "$1" \
        | sed 's|/usr/src/sys/contrib/openzfs/||; s/ *$//'
}
# bp_asize FILE ERE — Σ asize of the DVAs on the first line matching ERE (snprintf_blkptr: DVA[i]=<vdev:offset:asize>,
# hex) — the objset block itself, which no object's dn_used counts
bp_asize() {
    awk -v pat="$2" 'function hex(h,  v, i) { v = 0; for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
        $0 ~ pat { l = $0; s = 0; n = 0
            while (match(l, /DVA\[[0-9]\]=<[0-9]+:[0-9a-f]+:[0-9a-f]+>/)) {
                d = substr(l, RSTART, RLENGTH); l = substr(l, RSTART + RLENGTH); sub(/>$/, "", d); sub(/^.*:/, "", d); s += hex(d); n++ }
            f = 1; exit }
        END { if (!f || !n) exit 1; printf "%.0f\n", s }' "$1"
}

# ⚠ MEASURED (RECIPE 1 and 2 alike): FreeBSD's `makefs -t zfs` pool is NOT leak-free by zdb — "leaked space:
# vdev 0, offset 0x424000, size 114688" / "block traversal size 4907008 != alloc 5021696 (leaked 114688)" on the
# pristine image, every build. So the record says which it is instead of failing the build; the writer refuses
# makefs pools (no log_spacemap) and verify's A3 would call such a lane red on its own.
acct_alloc_zdb() {  # SUMMARY ACCT — from the LAST zdb -bb section of SUMMARY
    awk '/^======== zdb .* -bb / { sec = 1; nl = 0; lk = ""; ba = ""; nc = ""; next }
         sec && /^======== rc=/ { sec = 0 }
         sec && /No leaks \(block sum matches space maps exactly\)/ { nl = 1 }
         sec && /^block traversal size / { lk = $NF; sub(/\)$/, "", lk) }
         sec && $1 == "bp" && $2 == "allocated:" { ba = $3 }
         sec && $1 == "Normal" && $2 == "class:" { nc = $3 }
         END { if (ba == "") exit 1
               print "alloc zdb", ba, nc, (nl ? "clean" : "leaked:" (lk == "" ? "?" : lk)); exit 0 }' "$1" >> "$2"
}

# a writable import of a malloc-backed COPY, exported again at once: never the fixture disk itself
acct_alloc_rwcopy() {   # POOL IMAGE ACCT
    _rp=$1; _rd=$(dev "$2"); _ra=$3
    _rmb=$(( $(diskinfo "$_rd" | awk '{print $3}') / 1048576 ))
    _md=$(mdconfig -a -t malloc -s "${_rmb}m") || { log "  (no md device — rwimport baseline skipped)"; return 0; }
    if dd if="$_rd" of="/dev/$_md" bs=1m 2>/dev/null && zpool import -N -d "/dev/$_md" "$_rp" 2>/dev/null; then
        echo "alloc rwimport $(zpool get -Hp -o value allocated,free,size,freeing,leaked "$_rp" | tr '\n' ' ' | sed 's/ $//')" >> "$_ra"
        zpool export "$_rp" 2>/dev/null || zpool export -f "$_rp"
        log "  $(tail -1 "$_ra") (writable import of a malloc copy)"
    else
        log "  (writable import of the md copy failed — rwimport baseline skipped)"
    fi
    mdconfig -d -u "$_md"
}

# the writer's accepted feature list (design § a.2): an ACTIVE feature outside it makes a pool read-only for
# agnos, so the `wr` pool — the one agnos must be able to write — may activate nothing else
WRITER_FEATURES="async_destroy empty_bpobj lz4_compress spacemap_histogram enabled_txg hole_birth extensible_dataset
 embedded_data filesystem_limits large_blocks large_dnode sha512 skein edonr blake3 userobj_accounting encryption
 project_quota spacemap_v2 log_spacemap zstd_compress zilsaxattr head_errlog vdev_zaps_v2 dynamic_gang_header
 bookmarks bookmark_v2 bookmark_written livelist longname large_microzap physical_rewrite block_cloning fast_dedup
 redaction_bookmarks redacted_datasets redaction_list_spill"

# oracle POOL IMAGE-BASENAMES... — the pool must already be exported (or never imported: makefs)
oracle() {
    _pool=$1; shift
    _imgs="$*"; _devs=""; _dargs=""; _pargs=""
    for _i in $_imgs; do
        _d=$(dev "$_i"); _devs="$_devs $_d"; _dargs="$_dargs -d $_d"; _pargs="$_pargs -p $_d"
    done
    _first=$(echo "$_imgs" | awk '{print $1}')
    _s="$OUT/$_first.summary"; _mf="$OUT/$_first.manifest"
    _pre=$(hash_devs $_devs)

    log "$_pool: read-only import under $RO"
    rm -rf "$RO"; mkdir -p "$RO"
    # shellcheck disable=SC2086
    zpool import -o readonly=on -R "$RO" $_dargs "$_pool" || log "  (zpool import rc=$? — checking what mounted)"
    zpool list -H "$_pool" > /dev/null 2>&1 || die "read-only import of $_pool failed"
    zfs mount -a 2> /dev/null
    check_mounts "$_pool"
    write_manifest "$_pool" "$_mf"
    write_xattrs "$OUT/$_first.xattrs"
    snap_manifests "$_pool" "$OUT/$_first.snaps" || die "$_pool: snapshot manifests failed"
    check_expect "$_pool" "$_mf"
    ( cd "$RO" && find . -links +0 -exec stat -f '%i %N' {} + ) | sed 's| \./| /|; s| \.$| /|' | LC_ALL=C sort -k2 > "$OUT/$_first.objects"
    acct_capture "$_pool" "$OUT/$_first.acct" || die "$_pool: accounting capture failed"

    {
        echo "# $_first.summary — $_pool (images: $_imgs)"
        echo "# guest: $(uname -rm); $(zfs version | tr '\n' ' ')"
        echo "# built by scripts/tool/zfs-fixture.sh recipe $(cat "$SEED/recipe.conf")"
        [ "$_pool" = agnostank ] && echo "# agnostank/secret passphrase (keyformat=passphrase): $SECRET_PASS"
        echo; echo "======== zpool status -v $_pool ========"; zpool status -v "$_pool"
        echo; echo "======== zpool get -H all $_pool ========"; zpool get -H all "$_pool"
        echo; echo "======== features (feature@ name / state) ========"
        zpool get -H all "$_pool" | awk -F '\t' '$2 ~ /^feature@/ {print $2 "\t" $3}'
        echo; echo "======== zfs get -H -r (filtered) ========"
        zfs get -H -r -o name,property,value,source \
            mountpoint,canmount,compression,checksum,recordsize,dnodesize,encryption,version,xattr "$_pool"
        echo; echo "======== zfs list -r -t all ========"
        zfs list -r -t all -o name,used,refer,recordsize,compressratio,mountpoint,mounted "$_pool"
        echo; echo "======== directory size cross-check (ZPL st_size - 2 vs children in the manifest) ========"
        cat "$OUT/$_pool.dirsize"
    } > "$_s" 2>&1

    # object numbers the zdb dumps below need (per-dataset object ids; stat's inode == ZFS object id)
    _OBJS=""
    if [ "$_pool" = agnostank ]; then
        for _f in agnostank/dir3000 agnostank/big.bin agnostank/small.txt agnostank/xattr.txt agnostank/sym-long \
                agnostank/sparse.bin agnostank/zeros-1m.bin; do
            _OBJS="$_OBJS $_f=$(stat -f %i "$RO/$_f")" || die "stat $_f"
        done
        _OBJS="$_OBJS agnostank/gang/gang.bin=$(stat -f %i "$RO/agnostank/gang/gang.bin")"
        _OBJS="$_OBJS agnostank/dnode/n00=$(stat -f %i "$RO/agnostank/dnode/n00")"
        _OBJS="$_OBJS agnostank/zpl4/old.txt=$(stat -f %i "$RO/agnostank/zpl4/old.txt")"
        _OBJS="$_OBJS agnostank/zpl4/old-sym-long=$(stat -f %i "$RO/agnostank/zpl4/old-sym-long")"
        { echo; echo "======== object ids used below ========"; echo "$_OBJS" | tr ' ' '\n' | sed '/^$/d'; } >> "$_s"
    fi
    if [ "$_pool" = agnosfz ]; then
        for _f in dir3000 longn micro; do
            _OBJS="$_OBJS agnosfz/$_f=$(stat -f %i "$RO/agnosfz/$_f")" || die "stat agnosfz/$_f"
        done
        { echo; echo "======== object ids used below ========"; echo "$_OBJS" | tr ' ' '\n' | sed '/^$/d'; } >> "$_s"
    fi
    if [ "$_pool" = agnoswr ]; then
        for _f in micro fat small.txt sym-long multi.bin sparse.bin copies2/c512k.bin resv4k/small.txt refresv4k/small.txt \
                edge/p.bin edge/q.bin edge/e1.bin edge/e3.bin edge/e4.bin edgec/e4.bin edgec/c1.bin; do
            _OBJS="$_OBJS agnoswr/$_f=$(stat -f %i "$RO/agnoswr/$_f")" || die "stat agnoswr/$_f"
        done
        {
            echo; echo "======== object ids used below ========"; echo "$_OBJS" | tr ' ' '\n' | sed '/^$/d'
            echo; echo "======== writer-gate properties (zfs get -H -r) ========"
            zfs get -H -r -t filesystem,volume -o name,property,value,source readonly,normalization,utf8only,casesensitivity,quota,refquota,reservation,refreservation,recordsize,dnodesize,copies,origin,volmode "$_pool"
            echo; echo "======== snapshots ========"; zfs list -H -t snapshot -o name -r "$_pool"
            echo; echo "======== bookmarks ========"; zfs list -H -t bookmark -o name -r "$_pool"
            echo; echo "======== volumes ========"; zfs list -H -t volume -o name,volsize,used -r "$_pool"
            echo; echo "======== RECIPE 4 edges (zfs get -Hp) ========"
            zfs get -Hp -o name,property,value used,referenced,reservation,refreservation,usedbyrefreservation \
                "$_pool/resv4k" "$_pool/refresv4k"
            echo; echo "======== RECIPE 4 owner ids (stat uid gid; zfs project) ========"
            echo "resv4k/owned.bin $(stat -f '%u %g' "$RO/agnoswr/resv4k/owned.bin")"
            zfs project "$RO/agnoswr/resv4k/owned.bin" 2>&1
        } >> "$_s"
    fi

    # spot check: the three largest files' manifest hashes against a second, independent hashing tool
    {
        echo; echo "======== spot check: manifest sha256 vs openssl dgst ========"
    } >> "$_s"
    for _p in $(awk '$1 == "F" {print $3, $2}' "$_mf" | sort -rn | head -3 | awk '{print $2}'); do
        _m=$(awk -v p="$_p" '$1 == "F" && $2 == p {print $4}' "$_mf")
        _o=$(openssl dgst -sha256 -r "$RO$_p" | awk '{print $1}')
        echo "$_p manifest=$_m openssl=$_o" >> "$_s"
        [ "$_m" = "$_o" ] || die "spot check $_p: manifest $_m vs openssl $_o"
    done

    export_ro "$_pool"
    _post=$(hash_devs $_devs)
    [ "$_pre" = "$_post" ] || die "$_pool: the read-only import + export changed the image bytes"
    log "  read-only import left the image(s) byte-identical"

    for _d in $_devs; do zdb_sec "$_s" -l "$_d"; done
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -C "$_pool"
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -uuu "$_pool"
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -d "$_pool"
    # the exact $MOS figures (RECIPE 3; see the acct format above): the MOS dump with an object range is the MOS alone
    # (zdb.c:10161-10162), and its rootbp is the uberblock's
    log "  zdb dumps (MOS figures, -bb, -m) ..."
    # shellcheck disable=SC2086
    zdb -e $_pargs -P -dd "$_pool" 0:281474976710655 > "$TMP/mos.dd" 2>&1 || die "$_pool: zdb -P -dd of the MOS failed"
    # shellcheck disable=SC2086
    zdb -e $_pargs -u "$_pool" > "$TMP/mos.u" 2>&1 || die "$_pool: zdb -u failed"
    _mosf=$(zdd_figures "$TMP/mos.dd") || die "$_pool: no 'Dataset mos' header in zdb -P -dd"
    _mosr=$(bp_asize "$TMP/mos.u" '^[[:space:]]*bp = ') || die "$_pool: no rootbp DVAs in zdb -u"
    echo "mos $(echo "$_mosf" | awk '{ print $1, $4 }') $_mosr" >> "$OUT/$_first.acct"
    { echo; echo "======== exact \$MOS figures (zdb -P -dd POOL 0:max, zdb -u) ========"; tail -1 "$OUT/$_first.acct"; } >> "$_s"
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -bb "$_pool"
    acct_alloc_zdb "$_s" "$OUT/$_first.acct" || die "$_pool: zdb -bb reported no 'bp allocated' (see $_first.summary)"
    grep -q '^alloc zdb .* clean$' "$OUT/$_first.acct" \
        || log "  NOTE: zdb -bb does not call the PRISTINE $_pool leak-free: $(grep '^alloc zdb' "$OUT/$_first.acct")"
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -m "$_pool"
    if [ "$_pool" = agnostank ]; then
        oracle_main_objects "$_s" "$_pargs" "$_OBJS"
    fi
    if [ "$_pool" = agnoswr ]; then
        oracle_wr_objects "$_s" "$_pargs" "$_OBJS"
    fi
    if [ "$_pool" = agnoslogs ]; then
        logs_census "$_s" "$_pargs" "$_pool"
    fi
    if [ "$_pool" = agnosfz ]; then
        oracle_fz_objects "$_s" "$_pargs" "$_OBJS"
    fi

    # the pool as a fresh system would see it: listed, ONLINE, importable
    {
        echo; echo "======== zpool import $_dargs (list only) ========"
        # shellcheck disable=SC2086
        zpool import $_dargs
    } >> "$_s" 2>&1
    # shellcheck disable=SC2086
    zpool import $_dargs 2>&1 | awk -v p="$_pool" '
        $1 == "pool:" { cur = $2 } $1 == "state:" && cur == p { st = $2 }
        END { if (st != "ONLINE") { print "pool " p " import state=" st; exit 1 } }' \
        || die "$_pool is not listed as importable/ONLINE from its own disks"
    for _d in $_devs; do
        zdb -l "$_d" | grep -q "^    state: 1$" || die "$_pool: label on $_d does not say state 1 (EXPORTED)"
        zdb -l "$_d" | grep -q "^    name: '$_pool'$" || die "$_pool: label on $_d names another pool"
    done
    [ "$(hash_devs $_devs)" = "$_pre" ] || die "$_pool: zdb / import listing changed the image bytes"
    [ "$(echo $_imgs | wc -w | tr -d ' ')" = 1 ] && acct_alloc_rwcopy "$_pool" "$_first" "$OUT/$_first.acct"
    [ "$(hash_devs $_devs)" = "$_pre" ] || die "$_pool: the writable import of a COPY changed the original image bytes"
    for _i in $_imgs; do
        echo "$_i $(sha256 -q "$(dev "$_i")")" >> "$OUT/images.sha256"
        if [ "$_i" != "$_first" ]; then
            cp "$_mf" "$OUT/$_i.manifest"; cp "$_s" "$OUT/$_i.summary"
            cp "$OUT/$_first.xattrs" "$OUT/$_i.xattrs"; cp "$OUT/$_first.objects" "$OUT/$_i.objects"
            cp "$OUT/$_first.acct" "$OUT/$_i.acct"
        fi
    done
    log "$_pool: exported, labels state=EXPORTED, oracle written"
}

oracle_fz_objects() {     # SUMMARY "-p DEV" "name=obj ..." — the promises the fz recipe makes (RECIPE 7)
    _s=$1; _pa=$2; _objs=$3
    _o() { echo "$_objs" | tr ' ' '\n' | awk -F= -v n="agnosfz/$1" '$1 == n {print $2}'; }
    # shellcheck disable=SC2086
    {
        zdb_sec "$_s" -e $_pa -dddd agnosfz/ "$(_o dir3000)"
        zdb_sec "$_s" -e $_pa -dddd agnosfz/ "$(_o longn)"
        zdb_sec "$_s" -e $_pa -dddd agnosfz/ "$(_o micro)"
    }
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnosfz/ "$(_o dir3000)" 2>&1 | grep -q 'Fat ZAP stats' || die "fz: dir3000/ is not a fat ZAP (see fz.summary)"
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnosfz/ "$(_o longn)" 2>&1 | grep -q 'Fat ZAP stats' || die "fz: longn/ is not a fat ZAP (see fz.summary)"
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnosfz/ "$(_o micro)" 2>&1 | grep -q 'microzap:' || die "fz: micro/ is not a microzap (see fz.summary)"
    # the accounting ZAPs: uids' user- and groupused FAT; uidm's userused a 128 KiB microzap holding 2,046 keys (one
    # chunk free). zdb -dddd of a whole dataset dumps its user / group / project-used objects first (zdb.c:4404-4417)
    # shellcheck disable=SC2086
    _uf=$(zdb -e $_pa -dddd agnosfz/uids 2>&1 | grep -c 'Fat ZAP stats')
    [ "$_uf" -ge 2 ] || die "fz: uids' user / group accounting ZAPs are not both fat ($_uf fat ZAP(s))"
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnosfz/uidm 2>&1 | grep -q 'microzap: 131072 bytes, 2046 entries' \
        || die "fz: uidm's userused ZAP is not a 128 KiB microzap of 2,046 entries (zdb: $(zdb -e $_pa -dddd agnosfz/uidm 2>&1 | grep -E 'microzap: |Fat ZAP stats|zap_num_entries' | head -4 | tr '\n\t' '  '))"
    _nu=$(awk '$1 == "space" && $2 == "user" && $3 == "agnosfz/uidm"' "$OUT/fz.acct" | wc -l | tr -d ' ')
    [ "$_nu" = 1023 ] || die "fz: uidm holds $_nu owners, not 1,023"
    awk '/^======== features/ { f = 1; next } /^========/ { f = 0 } f && /^feature@userobj_accounting\tactive$/ { ok = 1 } END { exit !ok }' "$_s" \
        || die "fz: userobj_accounting is not active (the obj- keys the uidm count assumes)"
    {
        echo; echo "======== recipe property checks ========"
        echo "dir3000/ and longn/ fat ZAPs, micro/ a microzap: yes"
        echo "uids: user and group accounting ZAPs fat ($_uf fat ZAPs in the dataset dump): yes"
        echo "uidm: userused a 128 KiB microzap of 2,046 entries, 1,023 owners: yes"
    } >> "$_s"
    log "  fz: dir3000/ + longn/ fat, micro/ micro, uids accounting fat, uidm userused 2,046 / 2,047 chunks"
}
oracle_main_objects() {   # SUMMARY "-p DEV" "name=obj ..."
    _s=$1; _pa=$2; _objs=$3
    _o() { echo "$_objs" | tr ' ' '\n' | awk -F= -v n="$1" '$1 == n {print $2}'; }
    _dir=$(_o agnostank/dir3000); _big=$(_o agnostank/big.bin)
    _small=$(_o agnostank/small.txt); _xa=$(_o agnostank/xattr.txt)
    _sl=$(_o agnostank/sym-long); _gang=$(_o agnostank/gang/gang.bin)
    _dn=$(_o agnostank/dnode/n00); _old=$(_o agnostank/zpl4/old.txt)
    _oldl=$(_o agnostank/zpl4/old-sym-long); _sp=$(_o agnostank/sparse.bin); _z=$(_o agnostank/zeros-1m.bin)
    # "agnostank/" (trailing slash) is the ROOT DATASET; plain "agnostank" would make zdb look the object
    # numbers up in the MOS (measured: "dmu_object_info() failed, errno 2" on every file object)
    # shellcheck disable=SC2086
    {
        zdb_sec "$_s" -e $_pa -dddd agnostank/ 1                       # ZPL master node
        zdb_sec "$_s" -e $_pa -dddd agnostank/ "$_dir"                  # dir3000: fat ZAP
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_big"                 # big.bin: L1 + 48 L0
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_small"               # small.txt: EMBEDDED
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_xa"                  # xattr.txt: SA xattrs / spill
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_sl"                  # sym-long: 400-byte target
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_sp"                  # sparse.bin: holes between L0s
        zdb_sec "$_s" -e $_pa -ddddd agnostank/ "$_z"                   # zeros-1m.bin: all holes
        zdb_sec "$_s" -e $_pa -ddddd agnostank/dnode "$_dn"            # large dnode + SA xattrs
        zdb_sec "$_s" -e $_pa -ddddd agnostank/zpl4 "$_old"            # pre-SA znode_phys_t
        zdb_sec "$_s" -e $_pa -ddddd agnostank/zpl4 "$_oldl"           # pre-SA long symlink
        zdb_sec "$_s" -e $_pa -ddddd agnostank/gang "$_gang"           # gang: compact DVAs
        zdb_sec "$_s" -e $_pa -ddddd -bbbbbb agnostank/gang "$_gang"   # gang: full BPs (gang/contiguous)
    }
    # properties the recipe PROMISES — a miss here is a recipe defect, not a footnote
    # shellcheck disable=SC2086
    zdb -e $_pa -ddddd agnostank/ "$_small" 2>&1 | grep -q 'EMBEDDED' \
        || die "small.txt did not become an EMBEDDED block pointer (see main.summary)"
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnostank/ "$_dir" 2>&1 | grep -q 'Fat ZAP stats' \
        || die "dir3000 is not a fat ZAP (see main.summary)"
    # shellcheck disable=SC2086
    _g=$(zdb -e $_pa -ddddd -bbbbbb agnostank/gang "$_gang" 2>&1 | grep -c ' L0 .* gang ')
    # shellcheck disable=SC2086
    _gt=$(zdb -e $_pa -ddddd -bbbbbb agnostank/gang "$_gang" 2>&1 | grep -c ' L0 ')
    {
        echo; echo "======== recipe property checks ========"
        echo "small.txt EMBEDDED block pointer: yes"
        echo "dir3000 fat ZAP: yes"
        echo "gang.bin L0 block pointers that are gang: $_g of $_gt"
        # shellcheck disable=SC2086
        if zdb -e $_pa -ddddd agnostank/ "$_xa" 2>&1 | grep -q 'SPILL_BLKPTR'; then
            echo "xattr.txt spill block: yes"
        else
            echo "xattr.txt spill block: no"
        fi
    } >> "$_s"
    [ "$_g" -gt 0 ] || die "forced ganging did not take: 0 of $_gt gang.bin L0 BPs are gang"
    # RECIPE 5: the spread left a space map on most metaslabs (the main lane's room, build_main)
    _smt=$(awk '$1 == "metaslab" && $3 == "offset" && $5 == "spacemap" { n++; if ($6 > 0) m++ } END { print m + 0, n + 0 }' "$_s")
    echo "metaslabs with a space map: $_smt (with, of)" >> "$_s"
    [ "${_smt%% *}" -ge 12 ] || die "main: only ${_smt%% *} of ${_smt##* } metaslabs have a space map after the spread"
    log "  main: small.txt EMBEDDED, dir3000 fat ZAP, gang.bin $_g/$_gt L0 BPs gang, $_smt metaslabs (with a space map, of)"
}

oracle_wr_objects() {     # SUMMARY "-p DEV" "name=obj ..." — and the promises the wr recipe makes
    _s=$1; _pa=$2; _objs=$3
    _o() { echo "$_objs" | tr ' ' '\n' | awk -F= -v n="agnoswr/$1" '$1 == n {print $2}'; }
    # shellcheck disable=SC2086
    {
        zdb_sec "$_s" -e $_pa -dddd agnoswr/ "$(_o micro)"            # microzap directory
        zdb_sec "$_s" -e $_pa -dddd agnoswr/ "$(_o fat)"              # fat ZAP (upgraded by a >= 50-byte name)
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/ "$(_o small.txt)"       # EMBEDDED
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/ "$(_o sym-long)"        # 300-byte target
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/ "$(_o multi.bin)"       # L1 + 8 L0 (the flip-data target)
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/ "$(_o sparse.bin)"      # holes
        zdb_sec "$_s" -e $_pa -ddddd -bbbbbb agnoswr/copies2 "$(_o copies2/c512k.bin)"   # copies=2: two DVAs per L0, three per L1
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/resv4k "$(_o resv4k/small.txt)"          # RECIPE 4: EMBEDDED under a reservation edge
        zdb_sec "$_s" -e $_pa -ddddd agnoswr/refresv4k "$(_o refresv4k/small.txt)"    # RECIPE 4: EMBEDDED under a refreservation edge
    }
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnoswr/ "$(_o micro)" 2>&1 | grep -q 'microzap:' || die "wr: micro/ is not a microzap (see wr.summary)"
    # shellcheck disable=SC2086
    zdb -e $_pa -dddd agnoswr/ "$(_o fat)" 2>&1 | grep -q 'Fat ZAP stats' || die "wr: fat/ is not a fat ZAP (see wr.summary)"
    # shellcheck disable=SC2086
    zdb -e $_pa -ddddd agnoswr/ "$(_o small.txt)" 2>&1 | grep -q 'EMBEDDED' || die "wr: small.txt is not an EMBEDDED BP"
    for _wk in resv4k refresv4k; do
        # shellcheck disable=SC2086
        zdb -e $_pa -ddddd agnoswr/$_wk "$(_o $_wk/small.txt)" 2>&1 | grep -q 'EMBEDDED' || die "wr: $_wk/small.txt is not an EMBEDDED BP"
    done
    _bad=$(awk -v ok=" $(echo $WRITER_FEATURES) " '
        /^======== features/ { f = 1; next } /^========/ { f = 0 }
        f && $2 == "active" { n = $1; sub(/^feature@/, "", n); if (index(ok, " " n " ") == 0) print n }' "$_s" | tr '\n' ' ')
    [ -z "$_bad" ] || die "wr: active feature(s) outside the writer's list: $_bad"
    # RECIPE 7 (1.57.12 B9): the spread left a space map on >= 5 metaslabs (build_wr) — the op list allocates in the first 5
    _smt=$(awk '$1 == "metaslab" && $3 == "offset" && $5 == "spacemap" { n++; if ($6 > 0) m++ } END { print m + 0, n + 0 }' "$_s")
    echo "metaslabs with a space map: $_smt (with, of)" >> "$_s"
    [ "${_smt%% *}" -ge 5 ] || die "wr: only ${_smt%% *} of ${_smt##* } metaslabs have a space map after the spread (the recipe promises >= 5)"
    for _f in log_spacemap spacemap_v2 spacemap_histogram; do
        grep -q "^feature@$_f	active\$" "$_s" || die "wr: feature $_f is not active"
    done
    awk '/^======== snapshots/ { f = 1; next } /^========/ { f = 0 } f && /^agnoswr@/ { bad = 1 } END { exit bad }' "$_s" \
        || die "wr: the ROOT dataset has a snapshot (the writer must see a snapshot-free root)"
    # RECIPE 3: each refusal child is what it claims to be
    awk -F '\t' '$1 == "agnoswr/clone" && $2 == "origin" && $3 == "agnoswr/snap@s1" { c = 1 }
        $1 == "agnoswr/insens" && $2 == "casesensitivity" && $3 == "insensitive" { i = 1 }
        $1 == "agnoswr/copies2" && $2 == "copies" && $3 == "2" { k = 1 }
        END { exit !(c && i && k) }' "$_s" || die "wr: clone / insens / copies2 do not carry their gate properties (see wr.summary)"
    # RECIPE 4: the two edges sit exactly 4 KiB above what their datasets hold, and the owner ids reached the ZAPs
    awk -F '\t' '/^======== RECIPE 4 edges/ { f = 1; next } /^========/ { f = 0 } f && NF == 3 { v[$1, $2] = $3 }
        END { r = "agnoswr/resv4k"; q = "agnoswr/refresv4k"
              exit !(v[r, "reservation"] == v[r, "used"] + 4096 && v[r, "refreservation"] == 0 \
                     && v[q, "refreservation"] == v[q, "referenced"] + 4096 && v[q, "usedbyrefreservation"] == 4096 \
                     && v[q, "reservation"] == 0) }' "$_s" \
        || die "wr: resv4k / refresv4k are not reservation = used + 4 KiB / refreservation = referenced + 4 KiB (see wr.summary)"
    grep -q '^resv4k/owned.bin 1001 1002$' "$_s" || die "wr: resv4k/owned.bin is not owned by 1001:1002 (see wr.summary)"
    awk '/^======== RECIPE 4 owner ids/ { f = 1; next } /^========/ { f = 0 } f && $1 == "1003" { ok = 1 } END { exit !ok }' "$_s" \
        || die "wr: resv4k/owned.bin does not carry project 1003 (see wr.summary)"
    for _wk in "user 1001" "group 1002" "project 1003"; do
        awk -v k="${_wk% *}" -v i="${_wk#* }" '$1 == "space" && $2 == k && $3 == "agnoswr/resv4k" && $4 == i && $5 > 0 { f = 1 } END { exit !f }' \
            "$OUT/wr.acct" || die "wr: no $_wk key with bytes in agnoswr/resv4k's accounting (wr.acct)"
        awk -v k="${_wk% *}" -v i="${_wk#* }" '$1 == "space" && $2 == k && $3 == "agnoswr" && $4 == i { f = 1 } END { exit f }' \
            "$OUT/wr.acct" || die "wr: agnoswr's own accounting holds a $_wk key (ZFS_WRITE_SELFTEST's new-owner exercise needs it absent)"
    done
    # RECIPE 8 (B9 review, k.103): each BOUNDARY block is born in its snapshot's own txg (build_wr_edge) — and q.bin is
    # three levels deep
    _eb=""
    for _bk in "edge e1.bin e1" "edge e3.bin e3" "edge e4.bin e4" "edgec e4.bin e4" "edgec c1.bin c1"; do
        set -- $_bk
        _want=$(echo "$WR_EDGE_TXG" | tr ' ' '\n' | sed -n "s/^$3=//p")
        _got=$(l0birth "$_pa" "agnoswr/$1" "$(_o "$1/$2")")
        [ -n "$_want" ] && [ "$_got" = "$_want" ] || die "wr: $1/$2's block is born in txg ${_got:-?}, not in its snapshot's own ${_want:-?} (a txg boundary fell between the write and the snapshot)"
        _eb="$_eb $1/$2=$_got"
    done
    # shellcheck disable=SC2086
    _ql=$(zdb -e $_pa -dddd agnoswr/edge "$(_o edge/q.bin)" 2>/dev/null | awk '$1 == "Object" && $2 == "lvl" { f = 1; next } f { print $2; exit }')
    [ "$_ql" = 3 ] || die "wr: edge/q.bin has ${_ql:-?} levels, not 3"
    # shellcheck disable=SC2086
    { zdb_sec "$_s" -e $_pa -ddddd agnoswr/edge "$(_o edge/p.bin)"; zdb_sec "$_s" -e $_pa -ddddd agnoswr/edge "$(_o edge/q.bin)"; }
    { echo; echo "======== RECIPE 8 boundary births (snapshots: $WR_EDGE_TXG) ========"; echo "$_eb" | tr ' ' '\n' | sed '/^$/d'; echo "edge/q.bin levels $_ql"; } >> "$_s"
    grep -q '^agnoswr/bmark#bm1$' "$_s" || die "wr: agnoswr/bmark has no bookmark #bm1"
    grep -q '^agnoswr/bmark@' "$_s" && die "wr: agnoswr/bmark still has a snapshot (it must carry ONLY the bookmark)"
    awk -F '\t' '$1 == "agnoswr/vol" { f = 1 } END { exit !f }' "$_s" || die "wr: no zvol agnoswr/vol"
    # shellcheck disable=SC2086
    # (plain -ddddd prints only DVA[0] of each block — MEASURED; -bbbbbb prints the whole BP)
    _c2=$(zdb -e $_pa -ddddd -bbbbbb agnoswr/copies2 "$(_o copies2/c512k.bin)" 2>&1 | grep -c ' L0 DVA\[0\]=<[^>]*> DVA\[1\]=<')
    [ "$_c2" -gt 0 ] || die "wr: copies2/c512k.bin has no L0 with two DVAs (see wr.summary)"
    {
        echo; echo "======== recipe property checks ========"
        echo "micro/ microzap: yes"; echo "fat/ fat ZAP: yes"; echo "small.txt EMBEDDED block pointer: yes"
        echo "active features all on the writer's list (design § a.2): yes"; echo "root dataset snapshots: none"
        echo "clone of snap@s1, bmark#bm1 without a snapshot, insens casesensitivity=insensitive, zvol vol: yes"
        echo "copies2/c512k.bin L0 BPs with two DVAs: $_c2"
        echo "resv4k reservation = used + 4 KiB, refresv4k refreservation = referenced + 4 KiB, each small.txt EMBEDDED: yes"
        echo "resv4k/owned.bin uid 1001 gid 1002 project 1003, each a key with bytes in agnoswr/resv4k's accounting ZAPs (none in agnoswr's): yes"
        echo "edge / edgec boundary births (each L0 born in its snapshot's own txg):$_eb; edge/q.bin 3 levels; no clone keeps a livelist: yes"
    } >> "$_s"
    log "  wr: micro/ microzap, fat/ fat ZAP, small.txt EMBEDDED, every active feature on the writer's list, root snapshot-free, clone / bookmark / insensitive / zvol children, copies2 $_c2 two-copy L0s, resv4k / refresv4k 4 KiB edges, resv4k/owned.bin 1001:1002 project 1003"
}

# logs_census SUMMARY "-p DEV" POOL — RECIPE 4's promises about the logs pool, read from OpenZFS's own zdb: `zdb -m` lists
# the log space maps the export kept and every metaslab's U ("unflushed txg="), `-mmmm -L` prints their entries
# (dump_spacemap: one "[id] A|F range: <start>-<end> size: ... vdev: ..." line per entry, logs in ascending txg) without
# loading a metaslab — ⚠ MEASURED (full RECIPE 4 builds 2 and 4 of 4; none of the nine prototypes): plain `zdb -mmmm`
# loads every metaslab and ABORTED on the OpenZFS-written pool, both times "ASSERT at module/zfs/metaslab.c:2670:
# metaslab_load_impl() VERIFY3U(weight, <=, msp->ms_weight) failed (378302368699121666 <= 378302368699121665)": the
# weight estimated from the on-disk space-map histogram (segment bucket 21, count 2) exceeded the loaded one (count 1)
# — a debug-only check (FreeBSD's zdb runs with ASSERTs live, the production kernel never evaluates it) that unflushed
# log entries can break; the pool itself was clean (zdb -bb No leaks, every import, the host replay), and C-zdbm
# (after OpenZFS's own export flushed every metaslab) passed on it. So the census also runs the LOAD PROBE —
# `zdb -mmmm` as the verify's A3m runs it — and records `load-probe clean` or `load-probe ASSERT <where> <condition>`
# in the summary: zfs-fixture.sh --verify hands a tripped probe to the guest (<lane>.mload), and A3m then judges a
# lane that trips the SAME assertion with -L (verify_lane). Per
# allocation unit the census follows the logs in txg order: a FREE at txg t followed by an ALLOC at t' > t is a
# reallocation (VALID when both logs are at or past the metaslab's U — the entries an import replays); a unit FREEd in a
# log at T0 - 2 or later whose last log event is an ALLOC is allocated AND deferred at T0 — the overlap a writer's
# deferred set must tolerate (design § c.2), which only zfs-damage.py pre-defer makes: an export cannot leave it
# (build_logs), so pre_deferred is reported, never promised. The full dump is logs.zdb-mmmm in the fixture's log/; the
# census goes into the summary, and the promises are checked here.
LOGS_MIN_LOGS=8; LOGS_MIN_UMS=4
logs_census() {
    _s=$1; _pa=$2; _lp=$3
    # shellcheck disable=SC2086
    zdb -e $_pa -mmmm -L "$_lp" > "$OUT/logs.zdb-mmmm" 2>&1 || die "logs: zdb -mmmm -L failed (see log/logs.zdb-mmmm)"
    # shellcheck disable=SC2086
    zdb -e $_pa -mmmm "$_lp" > "$OUT/logs.zdb-probe" 2>&1; _prc=$?
    _pa1=$(zdb_assert "$OUT/logs.zdb-probe")
    if [ "$_prc" = 0 ]; then _probe="load-probe clean"
    elif [ "$_prc" -gt 128 ] && [ -n "$_pa1" ]; then _probe="load-probe ASSERT $_pa1"
    else die "logs: zdb -mmmm (the load probe) exited $_prc without an ASSERT line (see log/logs.zdb-probe)"; fi
    # shellcheck disable=SC2086
    _t0=$(zdb -e $_pa -u "$_lp" | awk '$1 == "txg" && $2 == "=" { print $3; exit }')
    # shellcheck disable=SC2086
    _ash=$(zdb -e $_pa -C "$_lp" | awk '$1 == "ashift:" { print $2; exit }')
    [ -n "$_t0" ] && [ -n "$_ash" ] || die "logs: no uberblock txg / ashift from zdb"
    awk -v t0="$_t0" -v ash="$_ash" '
        function hex(h,  v, i) { v = 0; h = tolower(h); for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
        BEGIN { us = 2 ^ ash; msz = 0 }
        !inl && $1 == "metaslab" && $3 == "offset" && $5 == "spacemap" { cm = $2 + 0; if (cm + 1 > nms) nms = cm + 1; if (cm == 1) msz = hex($4); next }
        !inl && /^[[:space:]]*unflushed txg=/ { u = $0; sub(/.*unflushed txg=/, "", u); U[cm] = u + 0; next }
        /^Log Space Maps in Pool:/ { inl = 1; next }
        /^Log Space Map Obsolete Entry Statistics:/ { inl = 0; next }
        inl && $1 == "Log" && $2 == "Spacemap" && $3 == "object" { nl++; lo[nl] = $4; lt = $6 + 0; ltx[nl] = lt; next }
        inl && match($0, /\] [AF] range: [0-9a-f]+-[0-9a-f]+/) {
            if (msz == 0) { print "BAD no metaslab size (metaslab 1 offset) before the logs"; bad = 1; exit }
            ty = substr($0, RSTART + 2, 1); r = substr($0, RSTART + 11, RLENGTH - 11); split(r, b, "-")
            s = hex(b[1]); e = hex(b[2]) + 1; m = int(s / msz); val = (lt >= U[m] && U[m] > 0)
            if (val) vm[m] = 1
            for (x = int(s / us); x < int(e / us); x++) {
                if (ty == "A") {
                    na[nl]++
                    if (lst[x] == "F" && lsx[x] < lt) { ra++; if (val && lsv[x]) { rv++; rp[lsx[x] "->" lt]++ } }
                    lst[x] = "A"
                } else { nf[nl]++; lst[x] = "F"; if (lt >= t0 - 2) dfr[x] = 1 }
                lsx[x] = lt; lsv[x] = val
            }
            next }
        END {
            if (bad) exit 1
            nu = 0; ul = ""
            for (m = 0; m < nms; m++) { ul = ul " " (m in U ? U[m] : "-"); if (U[m] > 0 && U[m] != t0) nu++ }
            nv = 0; for (m in vm) nv++
            nd = 0; pd = 0; for (x in dfr) { nd++; if (lst[x] == "A") pd++ }
            np = 0; pl = ""; for (k in rp) { np++; if (np <= 12) pl = pl " " k ":" rp[k] }
            printf "logs %d (txg %d .. %d), T0 %d, %d metaslabs of %d B, allocation unit %d B\n", nl, ltx[1], ltx[nl], t0, nms, msz, us
            for (i = 1; i <= nl; i++) printf "  log txg %d (object %s): %d ALLOC unit(s), %d FREE unit(s)\n", ltx[i], lo[i], na[i], nf[i]
            printf "U[]:%s\n", ul
            printf "metaslabs with U != 0 and U != T0 (unflushed since an older txg): %d; with a valid log entry: %d\n", nu, nv
            printf "FREE -> later ALLOC of the same unit: %d valid (both logs >= U), %d in any log; (free txg->alloc txg:units)%s%s\n", rv, ra, pl, (np > 12 ? " ..." : "")
            printf "deferred at T0 (FREEd in a log >= T0 - 2): %d unit(s); allocated AND deferred (pre-deferred): %d\n", nd, pd
            printf "census logs=%d unflushed_ms=%d valid_ms=%d realloc=%d realloc_any=%d deferred=%d pre_deferred=%d\n", nl, nu, nv, rv, ra, nd, pd
        }' "$OUT/logs.zdb-mmmm" > "$TMP/logs.census" || { cat "$TMP/logs.census"; die "logs: the census of zdb -mmmm -L failed"; }
    { echo; echo "======== RECIPE 4 log census (zdb -mmmm -L; the full dump is log/logs.zdb-mmmm) ========"; cat "$TMP/logs.census"
      echo "$_probe"; } >> "$_s"
    { sed 's/^/zfsfix:   /' "$TMP/logs.census" | grep -v '^zfsfix:     log txg '; echo "zfsfix:   $_probe"; }
    _cl=$(sed -n 's/^census //p' "$TMP/logs.census")
    _v() { echo "$_cl" | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k { print $2 }'; }
    [ "$(_v logs)" -ge $LOGS_MIN_LOGS ] || die "logs: only $(_v logs) log space map(s) survived the export (want >= $LOGS_MIN_LOGS)"
    [ "$(_v unflushed_ms)" -ge $LOGS_MIN_UMS ] || die "logs: only $(_v unflushed_ms) metaslab(s) with U != T0 (want >= $LOGS_MIN_UMS)"
    [ "$(_v realloc)" -ge 1 ] || die "logs: no FREE in a kept log was reallocated by a later kept log"
}

# ⚠ After a walk of the whole read-only view, `zpool export` fails "pool is busy" for a few seconds and
# then succeeds with nothing changed — MEASURED in this guest: plain import + export is clean, but after
# a `find` over every file (or the manifest / xattr / object walks) the first export is refused and a
# retry 5 s later passes. Something in the guest is still letting go of the walked vnodes; it is not
# an open file of ours (every walk ran in a finished subshell). So: retry for a bounded time, say so
# in the log, and fail hard if the pool is still held after 60 s.
export_ro() {     # POOL
    _try=0
    until zpool export "$1" 2>/dev/null; do
        _try=$((_try + 1))
        [ $_try -lt 30 ] || { zpool export "$1"; herr "zpool export $1 still refused after 60 s"; return 1; }
        sleep 2
    done
    [ $_try -eq 0 ] || log "  (export of the read-only $1 needed $_try retr$( [ $_try -eq 1 ] && echo y || echo ies) — vnode release lag)"
    return 0
}

export_pool() {   # POOL — the read-write half is done
    run zpool sync "$1"
    run zpool export "$1"
}

# ---------------------------------------------------------------------------------------------
build_main() {
    _d=$(dev main); P=agnostank; A=/agnostank
    log "main: zpool create $P (ashift=12, lz4, atime=off) on $_d"
    run zpool create -o ashift=12 -O compression=lz4 -O atime=off -R "$RW" "$P" "$_d"

    put $P $A/hello.txt printf 'hello from zfs\n'
    put $P $A/empty true
    # ~300 B that lz4 squeezes far under the 112-byte embedded-BP payload limit
    put $P $A/small.txt awk 'BEGIN { for (i = 0; i < 10; i++) printf "embedded block pointer line\n" }'
    put $P $A/tiny.bin rand_bytes tiny 100
    put $P $A/rand-1m.bin rand_bytes rand-1m 1048576
    put $P $A/big.bin rand_bytes big 6291456
    put $P $A/text-3m.txt text_bytes text-3m 3145728
    put $P $A/zeros-1m.bin zero_bytes 1048576
    # sparse.bin: truncate to 8 MiB, then 4 KiB islands at 0, 3 MiB and 8 MiB - 4 KiB
    run truncate -s 8M "$RW$A/sparse.bin"
    rand_bytes sparse-0 4096 | dd of="$RW$A/sparse.bin" bs=4096 seek=0 conv=notrunc 2>/dev/null || die sparse0
    rand_bytes sparse-3m 4096 | dd of="$RW$A/sparse.bin" bs=4096 seek=768 conv=notrunc 2>/dev/null || die sparse3
    rand_bytes sparse-end 4096 | dd of="$RW$A/sparse.bin" bs=4096 seek=2047 conv=notrunc 2>/dev/null || die sparsee
    echo "$A/sparse.bin $(sparse_bytes | sha256 -q)" >> "$OUT/$P.expect"

    log "main: dir3000 (3000 entries — beyond a microzap's 2047)"
    run mkdir "$RW$A/dir3000"
    _i=0
    while [ $_i -lt 3000 ]; do
        _n=$(printf 'f%04d' $_i)
        put $P "$A/dir3000/$_n" printf '%s\n' "$_n"
        _i=$((_i + 1))
        [ $((_i % 1000)) = 0 ] && log "main: dir3000 $_i/3000"
    done

    run mkdir -p "$RW$A/deep/a/b/c/d/e"
    put $P $A/deep/a/b/c/d/e/leaf.txt printf 'leaf at depth 7\n'
    _long=$(awk 'BEGIN { s = "long-"; while (length(s) < 251) s = s "x"; print s ".txt" }')
    [ ${#_long} -eq 255 ] || die "255-byte name came out ${#_long} bytes"
    put $P "$A/$_long" printf 'a 255-byte file name\n'
    _utf=$(printf 'na\303\257ve-\303\274.txt')
    put $P "$A/$_utf" printf 'utf-8 name\n'
    run ln "$RW$A/hello.txt" "$RW$A/hello-link.txt"
    echo "$A/hello-link.txt $(printf 'hello from zfs\n' | sha256 -q)" >> "$OUT/$P.expect"

    run ln -s hello.txt "$RW$A/sym-short"
    run ln -s deep/a/b "$RW$A/sym-dir"
    _t400=$(awk 'BEGIN { for (i = 0; i < 49; i++) printf "seg-%03d/", i; printf "target00" }')
    [ ${#_t400} -eq 400 ] || die "sym-long target came out ${#_t400} bytes"
    run ln -s "$_t400" "$RW$A/sym-long"
    run ln -s /agnostank/hello.txt "$RW$A/sym-abs"

    put $P $A/xattr.txt printf 'file with extended attributes\n'
    run setextattr user agnos_color blue "$RW$A/xattr.txt"
    run setextattr user agnos.comment "zfs fixture extended attribute" "$RW$A/xattr.txt"
    text_bytes xattr-big 2048 | setextattr -i user agnos_big "$RW$A/xattr.txt" || die "setextattr big"

    # snapshot after the root files; snap-changed.txt then moves on, so the live view and the snapshot
    # differ — a reader that strays into the snapshot's blocks reads "before"
    printf 'before snapshot\n' > "$RW$A/snap-changed.txt" || die snap-changed
    run zpool sync $P
    run zfs snapshot $P@snap1
    put $P $A/snap-changed.txt printf 'after snapshot\n'

    log "main: child datasets"
    run zfs create -o compression=gzip-6 $P/gz
    put $P $A/gz/text-1m.txt text_bytes gz 1048576
    run zfs create -o compression=lzjb $P/lzjb
    put $P $A/lzjb/text-1m.txt text_bytes lzjb 1048576
    run zfs create -o compression=zle $P/zle
    put $P $A/zle/runs.bin zle_bytes zle 8
    run zfs create -o compression=off -o recordsize=4K $P/off
    put $P $A/off/rand-200k.bin rand_bytes off 204800
    run zfs create -o recordsize=1M $P/big1m
    put $P $A/big1m/rand-3m.bin rand_bytes big1m 3145728
    run zfs create -o checksum=sha256 $P/sha256
    put $P $A/sha256/hello.txt printf 'checksum=sha256\n'
    put $P $A/sha256/rand-256k.bin rand_bytes sha256 262144
    put $P $A/sha256/text-64k.txt text_bytes sha256 65536
    run zfs create -o checksum=sha512 $P/sha512
    put $P $A/sha512/hello.txt printf 'checksum=sha512\n'
    put $P $A/sha512/rand-256k.bin rand_bytes sha512 262144
    put $P $A/sha512/text-64k.txt text_bytes sha512 65536
    run zfs create -o checksum=skein $P/skein
    put $P $A/skein/rand-256k.bin rand_bytes skein 262144
    run zfs create -o checksum=blake3 $P/blake3
    put $P $A/blake3/rand-256k.bin rand_bytes blake3 262144
    run zfs create -o checksum=edonr $P/edonr
    put $P $A/edonr/rand-256k.bin rand_bytes edonr 262144
    run zfs create -o compression=zstd $P/zstd
    put $P $A/zstd/text-1m.txt text_bytes zstd 1048576

    run zfs create -o dnodesize=auto -o xattr=sa $P/dnode
    _i=0
    while [ $_i -lt 50 ]; do
        _n=$(printf 'n%02d' $_i)
        put $P "$A/dnode/$_n" printf 'dnode file %s\n' "$_n"
        run setextattr user a1 "v$_i" "$RW$A/dnode/$_n"
        text_bytes "a2-$_i" 64 | setextattr -i user a2 "$RW$A/dnode/$_n" || die "setextattr a2"
        text_bytes "a3-$_i" 200 | setextattr -i user a3 "$RW$A/dnode/$_n" || die "setextattr a3"
        _i=$((_i + 1))
    done

    run zfs create -o version=4 $P/zpl4
    put $P $A/zpl4/old.txt printf 'pre-SA znode (ZPL version 4)\n'
    put $P $A/zpl4/old-rand.bin rand_bytes zpl4 262144
    run mkdir "$RW$A/zpl4/olddir"
    for _n in 1 2 3 4 5; do put $P "$A/zpl4/olddir/o$_n" printf 'old dir entry %s\n' "$_n"; done
    run ln -s old.txt "$RW$A/zpl4/old-sym"
    run ln -s "$(awk 'BEGIN { for (i = 0; i < 25; i++) printf "old-%03d/", i }')end" "$RW$A/zpl4/old-sym-long"

    run zfs create -o mountpoint=legacy $P/legacy
    run mkdir -p "$TMP/legacy"
    run mount -t zfs $P/legacy "$TMP/legacy"
    printf 'legacy mountpoint\n' > "$TMP/legacy/legacy-only.txt" || die legacy
    run umount "$TMP/legacy"
    hidden $P /legacy-only.txt

    run zfs create -o mountpoint=/somewhere/else $P/custom
    put $P /somewhere/else/custom.txt printf 'custom mountpoint\n'
    # RECIPE 5 (agnos 1.57.12 B6 review): one FreeBSD symlink, so this WRITABLE child dataset holds the symlink SA layout
    # (every other child holds the file / directory one alone) — zfsx's symlink#63 then SUCCEEDS here from ring 3, and
    # the new link has a FreeBSD twin (zfs-sa-check.py, the verify's B-acl)
    run ln -s custom.txt "$RW/somewhere/else/custom-link"
    run zfs create -o canmount=off $P/coff
    run zfs create $P/coff/kid
    put $P $A/coff/kid/kid.txt printf 'child of a canmount=off parent\n'

    printf '%s\n' "$SECRET_PASS" | zfs create -o encryption=on -o keyformat=passphrase \
        -o keylocation=prompt $P/secret || die "zfs create $P/secret"
    printf 'encrypted\n' > "$RW$A/secret/secret.txt" || die secret
    hidden $P $A/secret/secret.txt

    if [ -f "$SEED/payload.tar" ]; then
        log "main: agnostank/payload from payload.tar"
        run zfs create $P/payload
        run mkdir -p "$TMP/payload"
        run tar -xf "$SEED/payload.tar" -C "$TMP/payload"
        run tar -xf "$SEED/payload.tar" -C "$RW$A/payload"
        ( cd "$RW$A/payload" && find . -exec chmod 0755 {} + ) || die "chmod payload"
        hash_tree "$TMP/payload" "$A/payload" >> "$OUT/$P.expect"
    fi

    # Gang blocks: OpenZFS only gangs when an allocation fails, so force it with the debug tunables —
    # every allocation >= 32 KiB fails over to a gang (force_ganging_pct defaults to 3 %, so it must go
    # to 100 as well). Sync first so nothing else rides in the forced txg, sync again before restoring.
    run zfs create $P/gang
    run zpool sync $P
    _fg=$(sysctl -n vfs.zfs.metaslab.force_ganging) || die "no vfs.zfs.metaslab.force_ganging"
    _fp=$(sysctl -n vfs.zfs.metaslab.force_ganging_pct) || die "no vfs.zfs.metaslab.force_ganging_pct"
    run sysctl vfs.zfs.metaslab.force_ganging=32768 vfs.zfs.metaslab.force_ganging_pct=100
    put $P $A/gang/gang.bin rand_bytes gang 2097152
    run zpool sync $P
    run sysctl vfs.zfs.metaslab.force_ganging="$_fg" vfs.zfs.metaslab.force_ganging_pct="$_fp"
    run zpool sync $P

    # RECIPE 5 (agnos 1.57.12 B6 review): SPACE MAPS ON MOST METASLABS. agnos allocates only in metaslabs that have a
    # space map (design k.46), and which ones this recipe's ~20 MB happened to touch varied between builds — 8 of 15 on
    # r4, 7 on the first r5 — while the main lane's op list (~330 txgs, each deferring ~0.27 MB for the boot) needs
    # ~95 MB: on 7 its 250-append burst ran out at write 244. A fill to the slop in a scratch dataset, synced, then the
    # dataset destroyed and its frees waited out: every metaslab the fill touched keeps a space map after the export's
    # flush. oracle_main_objects holds the result to >= 12 of 15.
    run zfs create $P/spread
    _av=$(zfs get -Hp -o value available $P) || die "zfs get available $P"
    _mb=$(( _av / 1048576 - 4 ))
    [ "$_mb" -gt 64 ] || die "main: only $_mb MiB to spread over the metaslabs"
    dd if=/dev/random of="$RW$A/spread/fill" bs=1m count="$_mb" 2>/dev/null || die "main: spread fill"
    run zpool sync $P
    run zfs destroy $P/spread
    timeout 600 zpool wait -t free $P || die "main: zpool wait -t free after the spread"
    run zpool sync $P
    log "main: spread $_mb MiB over the metaslabs and freed it (space maps for agnos's allocator)"

    export_pool $P
    oracle $P main
}

# RECIPE 4 — logs: a pool OpenZFS last ran NEAR ITS SLOP and exported with its log space maps KEPT
# (vfs.zfs.keep_log_spacemaps_at_export=1: spa_should_flush_logs_on_unload says no, spa.c:2058-2077, so the export never
# runs its flush-all txg) — the state a crash, or any OpenZFS running with that tunable, leaves: many logs, every
# metaslab's U wherever the one-flush-per-txg round robin left it, and FREEs that later kept logs reallocate.
# ⚠ MEASURED (nine prototype builds and four full builds of this recipe, FreeBSD 15.1 / zfs-2.4.2) — what shapes it:
#   * spa_flush_metaslabs (spa_log_spacemap.c:740-865) flushes ONE dirty metaslab per txg that changes anything
#     (want_to_flush = zfs_min_metaslabs_to_flush = 1 on a pool this small; a clean metaslab at the head is merely
#     bumped), an empty txg flushes nothing, and a clean metaslab's U moves to the txg of its next entry
#     (metaslab_sync, metaslab.c:4376-4379). So the logs that survive are about as many as the metaslabs holding
#     unflushed entries: each round must touch MANY metaslabs — LOGS_K fill files deleted, one per stripe of the fill
#     order (8 stripes: 9-12 logs; 16: 10-13 over five builds).
#   * AT the slop every write's dmu_tx_assign retries (ERESTART) into a txg of its own — ~55 txgs per round, each
#     touching the same 3 or 4 metaslabs — and 3-5 logs survived. So a round deletes more than it writes (LOGS_K
#     against LOGS_W records): the pool starts the churn LOGS_ROOM from the slop and ends it ~20 MiB from it.
#   * A freed range is reused inside the kept window only by best fit: the default first fit walks a cursor through
#     metaslabs whose free half is one tail, and no prototype re-allocated a freed unit with it (0 of 0). The churn
#     runs in the allocator's own best-fit mode (metaslab_df_alloc, metaslab.c:1917-1952), which OpenZFS enters by
#     itself below metaslab_df_free_pct (4 %) free in a metaslab — vfs.zfs.metaslab.df_free_pct=100 forces it, restored
#     after the churn: 11-180 valid FREE -> ALLOC units in the kept logs (t -> t + 3 and later: the 2-txg defer).
#   * The overlap a writer's deferred set must tolerate (units FREEd in a log >= T0 - 2 and allocated at T0, design
#     § c.2 — what zfs-damage.py pre-defer forges) is NOT reachable through an export: the unmount's and spa_export's
#     waits leave EMPTY txgs before its config txg T0 (the last log before T0 was 7-9 txgs older in every build), so
#     T0 - 1 and T0 - 2 hold no log and T0 cannot reallocate what T0 frees. The census reports it (pre_deferred = 0);
#     the forge stays the only source of that state.
# Recipe: fill with 128 KiB incompressible files (rounds of half of what is left, a sync each) until under LOGS_ROOM +
# 256 KiB is available; then LOGS_ROUNDS rounds — LOGS_K fill files removed (one per stripe), up to LOGS_W 128 KiB files
# written, one sync. A deleted file leaves the registry with it (unput). Both tunables are restored; logs_census reads
# the result back from zdb and holds it to LOGS_MIN_LOGS logs, LOGS_MIN_UMS metaslabs with U != T0 and >= 1 valid
# reallocation.
LOGS_K=16; LOGS_W=4; LOGS_ROUNDS=12; LOGS_ROOM=$((4 * 1048576))
build_logs() {
    _d=$(dev logs); P=agnoslogs; A=/agnoslogs
    _kl=$(sysctl -n vfs.zfs.keep_log_spacemaps_at_export) || die "no vfs.zfs.keep_log_spacemaps_at_export"
    _dfp=$(sysctl -n vfs.zfs.metaslab.df_free_pct) || die "no vfs.zfs.metaslab.df_free_pct"
    log "logs: zpool create $P (ashift=12, lz4, atime=off) on $_d — filled near the slop, churned, exported keeping its logs"
    run zpool create -o ashift=12 -O compression=lz4 -O atime=off -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from the logs pool\n'
    for _n in 1 2 3; do put $P "$A/s$_n.txt" printf 'small %s\n' "$_n"; done
    run mkdir "$RW$A/fill" "$RW$A/churn"
    _nf=0
    while :; do
        run zpool sync $P
        _av=$(zfs get -Hp -o value available $P)
        _n=$(( (_av - LOGS_ROOM) / 2 / 131072 ))
        [ "$_n" -ge 1 ] || break
        while [ "$_n" -gt 0 ]; do
            put $P "$A/fill/f$(printf '%04d' $_nf)" rand_bytes "logs-f$_nf" 131072
            _nf=$((_nf + 1)); _n=$((_n - 1))
        done
    done
    log "logs: $_nf fill files; available $(zfs get -Hp -o value available $P) B, free $(zpool get -Hp -o value free $P) B"
    [ $((_nf / LOGS_K)) -gt $LOGS_ROUNDS ] || die "logs: $_nf fill files are too few for $LOGS_ROUNDS rounds of $LOGS_K stripes"
    run sysctl vfs.zfs.metaslab.df_free_pct=100
    _r=0; _nc=0          # loop counters never _k: rand_bytes owns that name
    while [ $_r -lt $LOGS_ROUNDS ]; do
        _lk=0
        while [ $_lk -lt $LOGS_K ]; do
            unput $P "$A/fill/f$(printf '%04d' $(( _lk * _nf / LOGS_K + _r )))"
            _lk=$((_lk + 1))
        done
        _av=$(zfs get -Hp -o value available $P)
        _lk=0
        while [ $_lk -lt $LOGS_W ] && [ "$_av" -ge $((131072 + 65536)) ]; do
            put $P "$A/churn/c$(printf '%03d' $_r)-$_lk" rand_bytes "logs-c$_r-$_lk" 131072
            _av=$((_av - 131072)); _nc=$((_nc + 1)); _lk=$((_lk + 1))
        done
        run zpool sync $P
        _r=$((_r + 1))
    done
    run sysctl vfs.zfs.metaslab.df_free_pct="$_dfp"
    log "logs: $LOGS_ROUNDS churn rounds ($((LOGS_ROUNDS * LOGS_K)) fill files removed, $_nc written); available $(zfs get -Hp -o value available $P) B, free $(zpool get -Hp -o value free $P) B"
    run sysctl vfs.zfs.keep_log_spacemaps_at_export=1
    export_pool $P
    run sysctl vfs.zfs.keep_log_spacemaps_at_export="$_kl"
    oracle $P logs
}

build_ashift9() {
    _d=$(dev ashift9); P=agnos9; A=/agnos9
    log "ashift9: zpool create $P (ashift=9, lz4) on $_d"
    run zpool create -o ashift=9 -O compression=lz4 -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from zfs (ashift 9)\n'
    put $P $A/rand-2m.bin rand_bytes a9-2m 2097152
    run mkdir "$RW$A/dir20"
    _i=0
    while [ $_i -lt 20 ]; do
        put $P "$A/dir20/e$(printf '%02d' $_i)" printf 'entry %d\n' $_i
        _i=$((_i + 1))
    done
    run ln -s hello.txt "$RW$A/sym"
    # RECIPE 6 (1.57.12 B7 review, finding 3): an object holding an extended-attribute DIRECTORY in a WRITABLE dataset —
    # xattr=dir for its one xattr only (FreeBSD 15.1's default is sa; the property then goes back to it) — so the writer's
    # ZPL_XATTR rule (unlink -> the DELETE_QUEUE: zfs_rmnode purges the directory) runs on disk. The promise is checked
    # on the exported pool: zdb must show the object's xattr directory.
    run zfs set xattr=dir $P
    put $P $A/xd.txt printf 'a file whose xattr lives in a directory\n'
    run setextattr user agnos_xd 'an xattr in a directory' "$RW$A/xd.txt"
    run zfs inherit xattr $P
    _xo=$(stat -f %i "$RW$A/xd.txt") || die "ashift9: stat xd.txt"
    export_pool $P
    oracle $P ashift9
    zdb -e -p "$_d" -dddd "$P/" "$_xo" 2>&1 | grep -qE '^[[:space:]]+xattr[[:space:]]+[1-9][0-9]*$' \
        || die "ashift9: xd.txt (object $_xo) has no xattr directory (zdb -dddd shows no xattr)"
    log "ashift9: xd.txt (object $_xo) holds an xattr directory"
}

build_v28() {
    _d=$(dev v28); P=agnosv28; A=/agnosv28
    log "v28: zpool create $P (version=28, no feature flags, ashift=9, lzjb) on $_d"
    run zpool create -o version=28 -o ashift=9 -O compression=lzjb -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from a version 28 pool\n'
    put $P $A/rand-1m.bin rand_bytes v28-1m 1048576
    put $P $A/text-256k.txt text_bytes v28 262144
    run mkdir "$RW$A/dir100"
    _i=0
    while [ $_i -lt 100 ]; do
        put $P "$A/dir100/g$(printf '%03d' $_i)" printf 'v28 entry %d\n' $_i
        _i=$((_i + 1))
    done
    run ln -s hello.txt "$RW$A/sym"
    run zfs create -o version=4 $P/zpl4
    put $P $A/zpl4/old.txt printf 'pre-SA znode on a v28 pool\n'
    put $P $A/zpl4/old-text.txt text_bytes v28-zpl4 65536
    run mkdir "$RW$A/zpl4/olddir"
    put $P $A/zpl4/olddir/inner.txt printf 'inner\n'
    run ln -s old.txt "$RW$A/zpl4/old-sym"
    export_pool $P
    oracle $P v28
}

build_mirror() {
    _a=$(dev mirror-a); _b=$(dev mirror-b); P=agnosmir; A=/agnosmir
    log "mirror: zpool create $P mirror (ashift=12, lz4) on $_a $_b"
    run zpool create -o ashift=12 -O compression=lz4 -R "$RW" $P mirror "$_a" "$_b"
    put $P $A/hello.txt printf 'hello from a mirror\n'
    put $P $A/rand-2m.bin rand_bytes mir-2m 2097152
    put $P $A/text-512k.txt text_bytes mir 524288
    run mkdir "$RW$A/sub"
    put $P $A/sub/inner.txt printf 'inner\n'
    export_pool $P
    oracle $P mirror-a mirror-b
}

# makefs -t zfs is a second, independent ZFS WRITER (no OpenZFS code), so its image is a reader test of
# its own. Its pool is written already EXPORTED (label state 1) with every feature disabled, a fixed
# pool GUID, and — MEASURED, recorded in makefs.summary's directory-size cross-check — a root directory
# whose ZPL size (7) and link count (3) undercount its 6 entries / 2 subdirectories by one. A reader
# that sizes or walks directories from those fields instead of the ZAP gets this image wrong.
build_makefs() {
    _d=$(dev makefs); P=agnosmk; A=/agnosmk; _st="$TMP/mkstage"
    log "makefs: staging tree + makefs -t zfs (FreeBSD's userland ZFS writer)"
    rm -rf "$_st"; run mkdir -p "$_st/dir500" "$_st/nested/a/b/c"
    printf 'hello from makefs\n' > "$_st/hello.txt"
    rand_bytes mk-1m 1048576 > "$_st/rand-1m.bin"
    text_bytes mk 131072 > "$_st/text-128k.txt"
    _i=0
    while [ $_i -lt 500 ]; do
        _n=$(printf 'm%03d' $_i); printf '%s\n' "$_n" > "$_st/dir500/$_n"
        _i=$((_i + 1))
    done
    printf 'nested leaf\n' > "$_st/nested/a/b/c/leaf.txt"
    run ln -s hello.txt "$_st/sym"
    hash_tree "$_st" "$A" > "$OUT/$P.expect"
    _sz=$(diskinfo "$_d" | awk '{print $3}')
    rm -f "$TMP/makefs.img"
    run makefs -t zfs -s "$_sz" -o poolname=$P "$TMP/makefs.img" "$_st"
    [ "$(stat -f %z "$TMP/makefs.img")" = "$_sz" ] || die "makefs image is not exactly $_sz bytes"
    run dd if="$TMP/makefs.img" of="$_d" bs=1m 2>/dev/null
    oracle $P makefs
}

build_raidz() {
    _0=$(dev raidz-0); _1=$(dev raidz-1); _2=$(dev raidz-2); P=agnosrz; A=/agnosrz
    log "raidz: zpool create $P raidz1 (ashift=12, lz4) on $_0 $_1 $_2"
    run zpool create -o ashift=12 -O compression=lz4 -R "$RW" $P raidz1 "$_0" "$_1" "$_2"
    put $P $A/data.bin rand_bytes rz 262144
    export_pool $P
    oracle $P raidz-0 raidz-1 raidz-2
}

# RECIPE 2 — the WRITER's pools (design 2026-10-09-zfs-write.md § a.2, § h B0).
# wr: what agnos 1.57.12 must be able to write. NO snapshot of the root dataset (snapshotted datasets are refused
# until bite B9), only features on the writer's list active (oracle_wr_objects proves it), and children that each
# exercise one write gate: snap (has @s1, live data moved on), ro (readonly=on), formd (normalization=formD), utf8
# (utf8only=on), quota (quota + refquota), resv (reservation + refreservation), rs4k (recordsize=4K), dnode
# (dnodesize=auto). In the root: a microzap dir, a fat-ZAP dir (upgraded by one >= 50-byte name — the cheapest fat
# ZAP OpenZFS makes), a hard link, a short and a 300-byte symlink, an EMBEDDED file, holes, one- and multi-record
# files (multi.bin: L1 + 8 x 128 KiB L0 — the flip-data target of the B0 gate). No xattrs, no encryption: those
# lanes are main's.
# RECIPE 8 (agnos 1.57.12, B9 review — design k.103): wr's edge (recordsize=4K, four snapshots) and its clone edgec (one
# of its own) — the BOUNDARY births no other dataset holds, each a block the op list kills. A block written and then
# snapshotted with no `zpool sync` between is born IN the snapshot's own txg (the snapshot is a sync task: it joins the
# open txg holding the data and runs after the dataset's blocks are written — dsl_sync_task_common, dsl_pool_sync), so:
#   (a) birth == ds_prev_snap_txg            edge/e4.bin (@e4's txg), edgec/c1.bin (@c1's): branch B, never A
#   (b) birth == a deadlist key              edge/e3.bin (key @e3), edgec/e4.bin (key @e4): dsl_deadlist_insert's
#                                            exact match goes to the entry BEFORE the key
#   (c) birth == prev's ds_prev_snap_txg     the same two (prev @e4 / @c1): no prev-unique
#   (d) birth == dd_origin_txg               edgec/e4.bin (the origin @e4's txg): no HEAD -> SNAP
# Every one is held by oracle_wr_objects (l0birth against the snapshot's createtxg — a txg boundary that fell between
# the write and the snapshot fails the build, never a fixture without the edge). And (finding 3) the PATHS: p.bin's
# block 0 reaches four deadlist intervals — its L0 (before @e1), its L1 (block 15 rewritten before @e2), its dnode block
# (p.bin touched before @e3), the meta-dnode's chain and the objset (e4.bin's txg, @e4's: e4.bin's dnode lives in
# another dnode block); q.bin, a sparse 3-level file, the same with its L2 (block 3328 rewritten before @e3). t.bin: 16
# blocks whose upper half the CLONE rewrites after @c1 (with after.txt, so its objset and accounting ZAPs move on too):
# a truncation there frees branch-A blocks first and snapshot-owned ones after (k.99). edgec writes 1 MiB of its own
# first, so OpenZFS drops its livelist (<= 75 % shared) as it did wr/clone's — the writer refuses a clone that keeps one.
l0birth() {   # PARGS DATASET OBJ — the logical birth of the object's first L0 data block (zdb -ddddd; not the objset's BP in the header)
    # shellcheck disable=SC2086
    # the "Indirect blocks" listing: "<offset>  L0 <dva> <lsize>L/<psize>P F=<fill> B=<logical>/<physical> ..." (an
    # EMBEDDED one "B=<birth>"); the header's objset BP ("birth=...L") is not one of them
    zdb -e $1 -ddddd "$2" "$3" 2>/dev/null | awk '$2 == "L0" { for (i = 3; i <= NF; i++) if ($i ~ /^B=/) { b = $i; sub(/^B=/, "", b); sub(/\/.*/, "", b); print b; exit } }'
}
build_wr_edge() {
    _tto=$(sysctl -n vfs.zfs.txg.timeout) || die "no vfs.zfs.txg.timeout"
    run sysctl vfs.zfs.txg.timeout=300
    run zfs create -o recordsize=4K $P/edge
    _E=$A/edge
    put $P $_E/p.bin rand_bytes wr-edge-p 65536
    put $P $_E/t.bin rand_bytes wr-edge-t 65536
    run truncate -s 16M "$RW$_E/q.bin"
    rand_bytes wr-edge-q 8192 > "$TMP/edge-q" || die "wr: edge-q"
    rand_bytes wr-edge-q2 4096 > "$TMP/edge-q2" || die "wr: edge-q2"
    dd if="$TMP/edge-q" of="$RW$_E/q.bin" bs=4096 count=2 conv=notrunc 2>/dev/null || die "wr: edge/q.bin 0"
    dd if="$TMP/edge-q2" of="$RW$_E/q.bin" bs=4096 seek=3328 count=1 conv=notrunc 2>/dev/null || die "wr: edge/q.bin 13M"
    echo "$_E/q.bin $( { cat "$TMP/edge-q"; zero_bytes $((3328 * 4096 - 8192)); cat "$TMP/edge-q2";
        zero_bytes $((16777216 - 3329 * 4096)); } | sha256 -q)" >> "$OUT/$P.expect"
    _i=0
    while [ $_i -lt 64 ]; do printf 'edge filler %d\n' $_i > "$RW$_E/f$(printf '%02d' $_i)" || die "wr: edge filler"; _i=$((_i + 1)); done
    # e4.bin: a filler whose dnode is in neither p.bin's nor q.bin's dnode block (32 per 16 KiB block; object numbers
    # come from per-CPU chunks, so it is looked up, not assumed)
    _pb=$(( $(stat -f %i "$RW$_E/p.bin") / 32 )); _qb=$(( $(stat -f %i "$RW$_E/q.bin") / 32 ))
    _e4=""
    for _f in $(cd "$RW$_E" && ls f*); do
        _fb=$(( $(stat -f %i "$RW$_E/$_f") / 32 ))
        [ "$_fb" != "$_pb" ] && [ "$_fb" != "$_qb" ] && { _e4=$_f; break; }
    done
    [ -n "$_e4" ] || die "wr: no edge filler outside p.bin's and q.bin's dnode blocks"
    run mv "$RW$_E/$_e4" "$RW$_E/e4.bin"
    rand_bytes wr-edge-e4 4096 > "$TMP/edge-e4" || die "wr: edge-e4"
    put $P $_E/e4.bin cat "$TMP/edge-e4"
    rand_bytes wr-edge-p 65536 > "$TMP/edge-p" || die "wr: edge-p"
    run zpool sync $P
    put $P $_E/e1.bin rand_bytes wr-edge-e1 4096
    run zfs snapshot $P/edge@e1
    dd if="$TMP/edge-p" of="$RW$_E/p.bin" bs=4096 skip=15 seek=15 count=1 conv=notrunc 2>/dev/null || die "wr: edge/p.bin 15"
    dd if="$TMP/edge-q" of="$RW$_E/q.bin" bs=4096 skip=1 seek=1 count=1 conv=notrunc 2>/dev/null || die "wr: edge/q.bin 1"
    run zpool sync $P
    run zfs snapshot $P/edge@e2
    run touch "$RW$_E/p.bin"
    dd if="$TMP/edge-q2" of="$RW$_E/q.bin" bs=4096 seek=3328 count=1 conv=notrunc 2>/dev/null || die "wr: edge/q.bin 13M again"
    run zpool sync $P
    put $P $_E/e3.bin rand_bytes wr-edge-e3 4096
    run zfs snapshot $P/edge@e3
    run zpool sync $P
    dd if="$TMP/edge-e4" of="$RW$_E/e4.bin" bs=4096 count=1 conv=notrunc 2>/dev/null || die "wr: edge/e4.bin again"
    run zfs snapshot $P/edge@e4
    run zfs clone $P/edge@e4 $P/edgec
    put $P $A/edgec/own.bin rand_bytes wr-edgec-own 1048576
    run zpool sync $P
    put $P $A/edgec/c1.bin rand_bytes wr-edgec-c1 4096
    run zfs snapshot $P/edgec@c1
    run zpool sync $P
    rand_bytes wr-edge-t 65536 > "$TMP/edge-t" || die "wr: edge-t"
    dd if="$TMP/edge-t" of="$RW$A/edgec/t.bin" bs=4096 skip=8 seek=8 count=8 conv=notrunc 2>/dev/null || die "wr: edgec/t.bin"
    put $P $A/edgec/after.txt printf 'written in the clone after its snapshot\n'
    # (the 1.57.12 merge, design k.107) e4.bin's and c1.bin's DNODE blocks moved on past @c1 too, every build: object
    # numbers come from per-CPU chunks, so whether after.txt or t.bin shared a dnode block with them was the build's
    # luck — B9's build had both rewritten here (edgec's two writes deadlisting their data block alone, no
    # materialisation), the merge's first build neither (a dnode block born at @c1 deadlisted too, one entry
    # materialised): the op list's exact `mat` and edgec's empty_bpobj count followed the luck. Their data blocks keep
    # the births the boundaries need (oracle_wr_objects)
    run touch "$RW$A/edgec/e4.bin" "$RW$A/edgec/c1.bin"
    run zpool sync $P
    run sysctl vfs.zfs.txg.timeout="$_tto"
    _ll=$(zpool get -H -o value feature@livelist $P) || die "wr: zpool get feature@livelist"
    [ "$_ll" = enabled ] || die "wr: a clone kept its livelist (feature@livelist $_ll)"
    WR_EDGE_TXG="e1=$(zfs get -Hp -o value createtxg $P/edge@e1) e2=$(zfs get -Hp -o value createtxg $P/edge@e2) e3=$(zfs get -Hp -o value createtxg $P/edge@e3) e4=$(zfs get -Hp -o value createtxg $P/edge@e4) c1=$(zfs get -Hp -o value createtxg $P/edgec@c1)"
    log "wr: edge / edgec snapshot txgs: $WR_EDGE_TXG"
}

# RECIPE 3 (B0 review): one child per remaining dataset-level refusal of design § a.3 — clone (a clone of snap@s1; it was
# meant to keep its own livelist, but OpenZFS drops a livelist once the clone shares <= 75 % — own.txt's sync took it to
# 71 %, design k.92 — so B9 WRITES it), bmark (a bookmark and no snapshot), insens (casesensitivity=insensitive), vol (a zvol, volmode=dev
# so GEOM never tastes it) — and copies2 (copies=2: data DVAs x2, its metadata x3 — the D6 multi-copy path, and the
# lane whose ditto copies the oracle must see damaged).
build_wr() {
    _d=$(dev wr); P=agnoswr; A=/agnoswr
    log "wr: zpool create $P (ashift=12, lz4, atime=off) on $_d — the writer's pool"
    run zpool create -o ashift=12 -O compression=lz4 -O atime=off -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from the writer pool\n'
    put $P $A/empty true
    put $P $A/small.txt awk 'BEGIN { for (i = 0; i < 10; i++) printf "embedded block pointer line\n" }'
    put $P $A/rec4k.bin rand_bytes wr-4k 4096
    put $P $A/one-rec.bin rand_bytes wr-128k 131072
    put $P $A/multi.bin rand_bytes wr-1m 1048576
    put $P $A/text-300k.txt text_bytes wr-text 307200
    run truncate -s 2M "$RW$A/sparse.bin"
    rand_bytes wr-sp0 4096 | dd of="$RW$A/sparse.bin" bs=4096 seek=0 conv=notrunc 2>/dev/null || die wr-sparse0
    rand_bytes wr-sp1 4096 | dd of="$RW$A/sparse.bin" bs=4096 seek=256 conv=notrunc 2>/dev/null || die wr-sparse1
    echo "$A/sparse.bin $( { rand_bytes wr-sp0 4096; zero_bytes $((1048576 - 4096)); rand_bytes wr-sp1 4096;
        zero_bytes $((2097152 - 1048576 - 4096)); } | sha256 -q)" >> "$OUT/$P.expect"
    run ln "$RW$A/hello.txt" "$RW$A/hello-link.txt"
    echo "$A/hello-link.txt $(printf 'hello from the writer pool\n' | sha256 -q)" >> "$OUT/$P.expect"
    run ln -s hello.txt "$RW$A/sym-short"
    _t300=$(awk 'BEGIN { for (i = 0; i < 37; i++) printf "wseg-%02d/", i; printf "tail" }')
    [ ${#_t300} -eq 300 ] || die "wr sym-long target came out ${#_t300} bytes"
    run ln -s "$_t300" "$RW$A/sym-long"
    run mkdir "$RW$A/micro"
    _i=0
    while [ $_i -lt 20 ]; do put $P "$A/micro/m$(printf '%02d' $_i)" printf 'micro %d\n' $_i; _i=$((_i + 1)); done
    run mkdir "$RW$A/fat"
    put $P "$A/fat/$(awk 'BEGIN { s = "a-name-of-sixty-bytes-"; while (length(s) < 60) s = s "y"; print s }')" printf 'long name\n'
    _i=0
    while [ $_i -lt 10 ]; do put $P "$A/fat/f$_i" printf 'fat %d\n' $_i; _i=$((_i + 1)); done
    run mkdir -p "$RW$A/deep/a/b/c"
    put $P $A/deep/a/b/c/leaf.txt printf 'leaf at depth 5\n'

    log "wr: gate children"
    run zfs create $P/snap
    put $P $A/snap/keep.txt printf 'unchanged since the snapshot\n'
    printf 'before snapshot\n' > "$RW$A/snap/moved.txt" || die "wr snap/moved"
    rand_bytes wr-snap-old 131072 > "$RW$A/snap/rewritten.bin" || die "wr snap/rewritten"
    run zpool sync $P
    run zfs snapshot $P/snap@s1
    put $P $A/snap/moved.txt printf 'after snapshot\n'
    put $P $A/snap/rewritten.bin rand_bytes wr-snap-new 131072
    run zfs create $P/ro
    put $P $A/ro/frozen.txt printf 'readonly=on after this was written\n'
    run zfs create -o normalization=formD $P/formd
    put $P "$A/formd/$(printf 'caf\303\251.txt')" printf 'normalization=formD\n'
    run zfs create -o utf8only=on $P/utf8
    put $P "$A/utf8/$(printf '\303\274nicode.txt')" printf 'utf8only=on\n'
    run zfs create -o quota=64M -o refquota=32M $P/quota
    put $P $A/quota/q.bin rand_bytes wr-quota 1048576
    run zfs create -o reservation=16M -o refreservation=8M $P/resv
    put $P $A/resv/r.txt printf 'reservation + refreservation\n'
    run zfs create -o recordsize=4K $P/rs4k
    put $P $A/rs4k/r64k.bin rand_bytes wr-rs4k 65536
    run zfs create -o dnodesize=auto $P/dnode
    _i=0
    while [ $_i -lt 5 ]; do put $P "$A/dnode/d$_i" printf 'dnodesize=auto %d\n' $_i; _i=$((_i + 1)); done
    log "wr: RECIPE 3 children (clone, bookmark, casesensitivity, copies=2, zvol)"
    run zfs clone $P/snap@s1 $P/clone
    put $P $A/clone/own.txt printf 'written in the clone\n'
    run zfs create $P/bmark
    put $P $A/bmark/b.txt printf 'a dataset with a bookmark and no snapshot\n'
    run zpool sync $P
    run zfs snapshot $P/bmark@b1
    run zfs bookmark $P/bmark@b1 $P/bmark#bm1
    run zfs destroy $P/bmark@b1
    run zfs create -o casesensitivity=insensitive $P/insens
    put $P $A/insens/Mixed-Case.TXT printf 'casesensitivity=insensitive\n'
    run zfs create -o copies=2 $P/copies2
    put $P $A/copies2/c512k.bin rand_bytes wr-copies2 524288
    run zfs create -V 4M -o volmode=dev $P/vol
    # the minor node comes from a taskq (zvol_create_minors): 30 s was not enough on a loaded host (the RECIPE 5 build,
    # host load 14 on 16 cores: "never appeared") — 120
    _t=0
    while [ ! -c "/dev/zvol/$P/vol" ] && [ $_t -lt 120 ]; do sleep 1; _t=$((_t + 1)); done
    [ -c "/dev/zvol/$P/vol" ] || die "wr: /dev/zvol/$P/vol never appeared"
    rand_bytes wr-vol 1048576 | dd of="/dev/zvol/$P/vol" bs=128k 2>/dev/null || die "wr: write to the zvol"
    log "wr: RECIPE 4 children (reservation / refreservation 4 KiB above the contents) and non-zero owner ids"
    # the edges a writer crosses ON DISK (design k.37 (1)): resv4k's reservation is its used + 4 KiB (no
    # refreservation), refresv4k's refreservation its referenced + 4 KiB — so a COW of either small.txt (EMBEDDED: no
    # dsize) into an ordinary block crosses the reservation's boundary (parent_delta / CHILD_RSRV) or the
    # refreservation's (HEAD / REFRSRV). Both measured after a sync; nothing writes either dataset afterwards.
    for _rc in resv4k refresv4k; do
        run zfs create $P/$_rc
        put $P $A/$_rc/small.txt awk -v n="$_rc" 'BEGIN { for (i = 0; i < 10; i++) printf "%s: embedded block pointer\n", n }'
        put $P $A/$_rc/r8k.bin rand_bytes "wr-$_rc" 8192
        put $P $A/$_rc/text-20k.txt text_bytes "wr-$_rc" 20480
    done
    # (k.37 (2)) a file owned by uid 1001 / gid 1002 / project 1003: resv4k's user / group / project accounting ZAPs then
    # carry non-zero keys on disk beside root's / wheel's 0. ⛔ NOT in the root dataset: ZFS_WRITE_SELFTEST's in-memory
    # zfs_wst_uacct (core/zfs_write.cyr) hands a dnode of the FIRST writable dataset with user accounting — agnoswr — the
    # owner 1001:1002 as NEW keys and requires their values to be exactly that dnode's bytes; MEASURED with owned.bin in
    # the root: "zfs-wb3: FAIL uacct: the new owner's bytes" (8,704 B already there), the pool read-only, the wr and
    # wr@u0 op lists skipped. Its keys must stay new until the kernel exercise picks ids the ZAPs do not hold.
    put $P $A/resv4k/owned.bin rand_bytes wr-owned 8192
    run chown 1001:1002 "$RW$A/resv4k/owned.bin"
    [ "$(zpool get -H -o value feature@project_quota $P)" = active ] || die "wr: feature project_quota is not active"
    run zfs project -p 1003 "$RW$A/resv4k/owned.bin"
    run zpool sync $P
    _ru=$(zfs get -Hp -o value used $P/resv4k) || die "wr: zfs get used $P/resv4k"
    run zfs set reservation=$((_ru + 4096)) $P/resv4k
    _rr=$(zfs get -Hp -o value referenced $P/refresv4k) || die "wr: zfs get referenced $P/refresv4k"
    run zfs set refreservation=$((_rr + 4096)) $P/refresv4k
    run zpool sync $P
    # RECIPE 7 (agnos 1.57.12 B9): snap2 — two snapshots and nothing written after the second, so EVERY entry of its
    # head's deadlist still names the shared empty_bpobj: a snapshot clones the head's keys onto fresh empty bpobjs and
    # adds the old ds_prev_snap_txg (dsl_dataset_snapshot_sync_impl -> dsl_deadlist_clone / _add_key,
    # dsl_dataset.c:1830-1838) — {0, 1, @a}. A writer's first kill there must MATERIALISE an entry (dle_enqueue:
    # bpobj_alloc + bpobj_decr_empty): a.bin's block (born before @a: entry 1) and the objset chain b.bin's txg rewrote
    # (born between @a and @b: entry @a) — two in one txg. No other entry a writer's kill can reach on these pools names
    # it (agnostank's entry 1 and snap's became bpobjs of their own when OpenZFS wrote after the snapshot).
    run zfs create $P/snap2
    put $P $A/snap2/a.bin rand_bytes wr-snap2-a 8192
    run zpool sync $P
    run zfs snapshot $P/snap2@a
    put $P $A/snap2/b.bin rand_bytes wr-snap2-b 8192
    run zpool sync $P
    run zfs snapshot $P/snap2@b
    build_wr_edge
    # RECIPE 7: a SPREAD. agnos allocates only in metaslabs that have a space map (design k.46), and wr's gates are tuned
    # to that room — B5's 20 MiB write, B7's six-txg truncation, a burst that must run those metaslabs out of space
    # within its 250 txgs — but which metaslabs a build left one on was luck (k.69: 3 on the B7 payload's build and on
    # RECIPE 7's first, 5 on RECIPE 6's; on 3, the truncation ran out of room at its third txg). 64 MiB written into a
    # scratch dataset and destroyed gives EVERY metaslab one (OpenZFS's segment weight sends each next chunk to an
    # untouched metaslab: measured 15 of 15 — a bounded spread is not possible), and the op list caps agnos's allocation
    # at the first 5 of them (zfs_wt_msmax): the room no longer depends on the build. oracle_wr_objects holds >= 5
    run zfs create $P/spread
    dd if=/dev/random of="$RW$A/spread/fill" bs=1m count=64 2>/dev/null || die "wr: spread fill"
    run zpool sync $P
    run zfs destroy $P/spread
    timeout 600 zpool wait -t free $P || die "wr: zpool wait -t free after the spread"
    run zpool sync $P
    run zfs set readonly=on $P/ro
    export_pool $P
    oracle $P wr
}

# full: a small pool filled with incompressible data until `available` is under 2 MiB — the slop OpenZFS keeps
# back (half of a pool this small, spa_get_slop_space) is all that is left, so a later ENOSPC lane is meaningful.
# Each fill file takes half of what is left minus 1 MiB, rounded to 128 KiB, until the next would be < 128 KiB.
# RECIPE 7 (agnos 1.57.12 B8) — fz: the FAT-ZAP pool. Every fat ZAP the writer touches, made by OpenZFS, in a
# WRITABLE (snapshot-free) dataset — agnostank/dir3000 sits in the snapshotted root, refused until B9 — with room for
# B8's ~500 txgs (ashift 9: ~0.14 MB deferred each for the boot; the spread below gives every metaslab a space map, k.46):
#   dir3000/  3,000 names: OpenZFS's own microzap -> fat upgrade at the 2,048th and splits (agnostank/dir3000's twin):
#             agnos empties its smallest leaf, renames, links and long names into it
#   longn/    60 names of 255 bytes (13 name chunks: 42 entries fill a 16 KiB leaf) — fat from the first, 2 leaves:
#             agnos removes them all (both leaves emptied) and rmdirs it (a fat directory object freed)
#   micro/    20 short names, a microzap: agnos's 55-byte name upgrades it with them in it
#   uids      (a child) 1,100 files, each its own uid and gid: user- and groupused ZAPs of 2 x 1,102 keys — FAT, upgraded
#             by OpenZFS — agnos's writes and creates update keys in them, its unlinks remove the last owner's
#   uidm      (a child) 1,023 owners (uid 0 — the hidden shares directory — and the root directory's 3000 among them)
#             -> 2,046 userused keys: a 128 KiB microzap with ONE free chunk; agnos reserves two new keys per ZAP for
#             a create (it does not look them up), so its first create there upgrades it at admission (design k.78)
#   no symlink anywhere: agnos's first symlink registers a new SA layout (a LAYOUTS add)
build_fz() {
    _d=$(dev fz); P=agnosfz; A=/agnosfz
    log "fz: zpool create $P (ashift=9, lz4, atime=off) on $_d — the fat-ZAP pool"
    run zpool create -o ashift=9 -O compression=lz4 -O atime=off -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from the fat-ZAP pool\n'
    run mkdir "$RW$A/dir3000"
    _i=0
    while [ $_i -lt 3000 ]; do
        _n=$(printf 'f%04d' $_i)
        printf '%s\n' "$_n" > "$RW$A/dir3000/$_n" || die "fz: dir3000/$_n"
        _i=$((_i + 1))
    done
    run mkdir "$RW$A/longn"
    _i=0
    while [ $_i -lt 60 ]; do
        _n=$(awk -v i=$_i 'BEGIN { s = sprintf("%02d-", i); while (length(s) < 255) s = s "L"; print s }')
        printf 'long %d\n' $_i > "$RW$A/longn/$_n" || die "fz: longn/$_i"
        _i=$((_i + 1))
    done
    run mkdir "$RW$A/micro"
    _i=0
    while [ $_i -lt 20 ]; do printf 'micro %d\n' $_i > "$RW$A/micro/m$(printf '%02d' $_i)" || die "fz: micro"; _i=$((_i + 1)); done
    run zfs create $P/uids
    chown 1999:1999 "$RW$A/uids" || die "fz: chown uids"
    _i=0
    while [ $_i -lt 1100 ]; do
        printf 'u %d\n' $_i > "$RW$A/uids/u$_i" || die "fz: uids/u$_i"
        chown $((2000 + _i)):$((2000 + _i)) "$RW$A/uids/u$_i" || die "fz: chown uids/u$_i"
        _i=$((_i + 1))
    done
    # the pool's one FreeBSD symlink — in uids, owned by an owner it already has: the twin (same type and mode) the oracle
    # holds agnos's first symlink in the ROOT — a new SA layout there — to (zfs-sa-check.py, the verify's B-acl)
    ln -s u0 "$RW$A/uids/fbsym" || die "fz: ln -s"
    chown -h 2000:2000 "$RW$A/uids/fbsym" || die "fz: chown -h uids/fbsym"
    # uidm's owners: uid 0 — EVERY ZPL dataset's hidden shares directory (zfs_create_share_dir: 512 B, one object) owns
    # its two keys from birth, so a file created as root adds none —, the root directory's 3000 and m1..m1021's
    # 3001..4021: 1,023 owners, 2,046 keys, never more at any sync (OpenZFS upgrades a 128 KiB microzap of 2,047 chunks
    # at the add or update that finds it full: the first build made 1,022 files, 2,048 keys, and measured the upgrade)
    run zfs create $P/uidm
    chown 3000 "$RW$A/uidm" || die "fz: chown uidm"
    _i=1
    while [ $_i -lt 1022 ]; do
        : > "$RW$A/uidm/m$_i" || die "fz: uidm/m$_i"
        chown $((3000 + _i)) "$RW$A/uidm/m$_i" || die "fz: chown uidm/m$_i"
        _i=$((_i + 1))
    done
    run zpool sync $P
    # space maps on every metaslab (RECIPE 5's spread, as build_main)
    run zfs create $P/spread
    _av=$(zfs get -Hp -o value available $P) || die "zfs get available $P"
    _mb=$(( _av / 1048576 - 4 ))
    [ "$_mb" -gt 64 ] || die "fz: only $_mb MiB to spread over the metaslabs"
    dd if=/dev/random of="$RW$A/spread/fill" bs=1m count="$_mb" 2>/dev/null || die "fz: spread fill"
    run zpool sync $P
    run zfs destroy $P/spread
    timeout 600 zpool wait -t free $P || die "fz: zpool wait -t free after the spread"
    run zpool sync $P
    log "fz: spread $_mb MiB over the metaslabs and freed it"
    export_pool $P
    oracle $P fz
}

build_full() {
    _d=$(dev full); P=agnosfull; A=/agnosfull
    log "full: zpool create $P (ashift=12, lz4, atime=off) on $_d, then fill to the slop"
    run zpool create -o ashift=12 -O compression=lz4 -O atime=off -R "$RW" $P "$_d"
    put $P $A/hello.txt printf 'hello from the full pool\n'
    run mkdir "$RW$A/dir"
    for _n in 1 2 3; do put $P "$A/dir/s$_n.txt" printf 'small %s\n' "$_n"; done
    _fk=0          # not _k: rand_bytes owns that name
    while [ $_fk -lt 16 ]; do
        run zpool sync $P
        _av=$(zfs get -Hp -o value available $P)
        _sz=$(( (_av - 1048576) / 2 / 131072 * 131072 ))
        [ "$_av" -ge 2097152 ] && [ "$_sz" -ge 131072 ] || break
        put $P "$A/fill-$_fk.bin" rand_bytes "full-$_fk" "$_sz"
        _fk=$((_fk + 1))
    done
    run zpool sync $P
    log "full: $_fk fill file(s); available $(zfs get -Hp -o value available $P) B, $(zpool get -Hp -o value free $P) B free in the pool"
    export_pool $P
    oracle $P full
}

# =============================================================================================
# >>> VERIFY HALF — from this line to "# <<< VERIFY HALF" is the write oracle's guest side. zfs-fixture.sh hashes THIS
# FILE WITHOUT THESE LINES into the fixture's cache key (r<RECIPE>-<payload>-<build hash>): an edit anywhere else — a
# recipe, a manifest walk, a baseline capture — can never be served by a fixture an older script built, and an edit in
# here (shipped fresh on every --verify) does not force a rebuild. The helpers the verify calls that ALSO shape the
# baseline (write_manifest, write_xattrs, acct_capture, zdd_figures, bp_asize, ...) live above the marker on purpose:
# the baseline and the verify must measure with the same code, so changing one of them rebuilds the baseline.
#
# VERIFY MODE — the WRITE ORACLE (agnos 1.57.12 bite B0; design 2026-10-09-zfs-write.md § i.3).
#
# The host (`zfs-fixture.sh --verify DIR`) attaches three disks per lane, found here by serial: <S>A the image
# under test (QEMU readonly=on — phases A and B cannot change it even by accident), <S>C and <S>D host-made
# copies for the two phases that WRITE. $SEED/verify.conf, one line per lane:
#   <lane> <pool> <serial A> <serial C> <serial D> <sha256> <expected txg> <pristine best txg> <highest verifying txg>
#   <highest magic txg> <previous verifying uberblock txg> <the one before it>   ('-' where there is none)
# plus per lane: <lane>.expect (the expected manifest), <lane>.xattrs (the expected xattr listing), <lane>.base.acct and
# <lane>.base.dirsize (the pristine baselines), and optionally <lane>.touched ("<D|F|L> <manifest path>": what the
# writer touched, phase C works on it), <lane>.skipds (datasets A5 leaves out: encrypted, no key here), <lane>.leakok
# (design k.15: manifest PATHS of the objects whose stale PARENT the op list predicts — A5 tolerates exactly their
# objects, resolved with zdb -O, never a count), <lane>.mload (RECIPE 4: the ASSERT the base image's PRISTINE pool trips
# in `zdb -mmmm`'s metaslab load — logs_census's load probe; A3m then judges a lane that trips the same one with -L).
# $SEED/verify.opts: continue=0|1, force_a4=0|1.
# Every step prints `zfsfix: verify <lane> <step> PASS|FAIL|SKIP|INFO <why>` the moment it is decided — the serial log
# keeps that evidence through a guest panic — and appends the same to $OUT/verify.steps, which the host treats as
# AUTHORITATIVE whenever the results tar arrives (a console line can be lost or split by syslog writing to the same
# console; the file cannot).
#   A  zdb only, BEFORE any kernel import: a space-map defect panics the FreeBSD kernel on a writable import, zdb merely
#      reports it. A1 zdb -lu · A2 zdb -u (the uberblock an import selects == the lane's expected txg) · A3 zdb -P -bcc
#      -d -m -s -y, INCLUDING the -s vdev table's error counts · A3m zdb -mmmm (smp_alloc == entries runs only at
#      -mmmm, zdb.c:1582-1583) · A4 A3 again at -t of the two verifying uberblocks below the selected one (T-1, T-2 on
#      an agnos lane) when the lane has txgs past the pristine best (or force_a4=1) · A5 per dataset: object rows ==
#      the header's "N objects", ds_referenced == Σ dsize + the objset block (ds_check), -ddddd free of fill / type /
#      level errors, "possibly leaked" objects only those <lane>.leakok names · A6 the MOS: $MOS dd_used − (Σ dsize +
#      the uberblock rootbp) == the pristine baseline's
#   ⚠ MEASURED (design k.5 answered): FreeBSD 15.1's zdb runs with ASSERTs LIVE. A wrong smp_alloc aborts -mmmm in
#   metaslab_verify_space() (VERIFY3U sm_free_space == msp_free_space) before "INCONSISTENT" can print; a log ZAP
#   that lost an entry some U[i] names aborts every zdb in spa_ld_log_sm_metadata() (ASSERT sls != NULL) where
#   the kernel's import returns ENOENT. A zdb killed by a signal is therefore a FAIL, and the ASSERT is quoted.
#   B  read-only import of A (no -f): manifest == expected EXACTLY; no directory-size mismatch the pristine pool did not
#      have (and at least one directory checked); xattrs == expected; zpool status healthy with zero error counters;
#      the accounting identities (acct_check)
#   C  read-write round trip on copy C (no -f): scrub -w clean (zero error counters), OpenZFS appends / overwrites /
#      removes / copies / renames / long-names / links-and-unlinks / snapshots on top (each journalled), sync, export,
#      A3 + A3m again, C-k15 (OpenZFS's own stale PARENT through the k.15 machinery), then a read-only manifest of the
#      result that must equal expected + the journal (<lane>.rt.manifest; the host keeps the disk as <lane>.rt.img for
#      the agnos read-back, phase E)
#   D  destructive accounting on copy D: (1.57.12 B7) first `freeing` drained to 0 (D-drain: what the writer deferred to
#      free_bpobj, freed by OpenZFS's async destroy); every dataset but the root destroyed ONE AT A TIME (clones first, then the
#      deepest), each followed by zpool wait -t free and freeing / leaked back where they were — a dd_used error lands
#      in $FREE at the async destroy (dsl_destroy.c:990-1007) and must not cancel against another dataset's; then the
#      root emptied by OpenZFS (rm -rf, unmount, sync, wait free) and held to referenced == usedbydataset and a fresh
#      empty dataset's uid-0 object count; export, a final zdb -bcc with the -s table, ds_check of what is left.
#      ⚠ `leaked` is structurally 0 here: zfs_free_leak_on_eio defaults to B_FALSE (spa_misc.c:302), so a residual
#      stays in $FREE (dsl_scan.c:3905-3931) — `freeing` is the signal, `leaked` is read for completeness.
# A red phase A SKIPs B-D for that lane unless continue=1: a pool zdb calls broken can take the guest kernel down
# with every later lane still queued. ⛔ No pipeline may decide a verdict: every zdb / zpool status is taken from
# the command itself (vzdb), never from the far end of a `|`.

DA=/mnt/d                   # altroot of phase D's import (the root dataset is mounted there to be emptied)
VLANE=""; VFAILS=0
vstep() {      # STEP PASS|FAIL|SKIP|INFO WHY...
    _vs=$1; _vv=$2; shift 2
    echo "zfsfix: verify $VLANE $_vs $_vv $*"
    echo "$VLANE $_vs $_vv $*" >> "$OUT/verify.steps"
    [ "$_vv" = FAIL ] && VFAILS=$((VFAILS + 1))
    return 0
}

vzdb() {       # OUTFILE ARGS... — sets ZRC to zdb's own exit status (124 = timed out, > 128 = killed by a signal)
    _vzo=$1; shift
    timeout "${ZDB_TIMEOUT:-900}" zdb "$@" > "$_vzo" 2>&1
    ZRC=$?
}
zrc_why() {
    if [ "$1" = 124 ]; then echo "TIMED OUT"
    elif [ "$1" -gt 128 ]; then echo "KILLED by signal $(( $1 - 128 ))"
    else echo "exit $1"; fi
}
# Lines zdb prints for a defect (zfs-write-prior-art.md § 12; OpenZFS 2.4.2 cmd/zdb/zdb.c): "leaked space:"
# (6439), "block traversal size X != alloc Y (leaked N)" (7391 — exit status STAYS 0 for it), "Error counts"
# (7356, rc 3), "... feature refcount mismatch" / "space map refcount mismatch" (8742, 1557, rc 2), "ERROR:
# DOUBLE ALLOC/FREE" (446, 460, -y), "(ERROR: Block pointer type/level ...)" and "fill ... does not match" (2686,
# 2745, -ddddd), "INCONSISTENT" (1670, -mmmm), "MOS object N (...) leaked", "N potentially leaked objects" (4447).
# ⚠ Never the bare word "leaked": every -b run prints "Traversing all blocks to verify ... nothing leaked ...".
ZDB_RED='leaked space:|block traversal size|Error counts|mismatch|DOUBLE|ERROR|INCONSISTENT|Got error|does not match|corrupt|potentially leaked| leaked$'

# zdb -s's vdev statistics table (lib/libzpool/util.c show_vdev_stats): one row per vdev, the LAST THREE columns its
# read / write / checksum ERROR counts (nicenum: 0, 2, 1.5K). ⛔ THE ONLY PLACE A BAD DITTO COPY SHOWS (B0 review,
# CRITICAL): -cc reads every block with ZIO_FLAG_SCRUB, so the mirror-of-DVAs reads EVERY copy and counts a bad one in
# vs_checksum_errors (vdev_mirror.c:710-880) — but one good copy leaves io_error 0, so zdb prints no "Got error", no
# "Error counts", exits 0 and says "No leaks" (zdb.c:6306-6330 reports io_error only). Nothing else reads those copies:
# an ordinary read on a single-vdev pool always takes DVA[0] (every DVA loads INT_MAX at the root, vdev_mirror.c:189-191,
# and :459-473 walks back to the lowest index on the vdev), and a read-write import re-COWs the MOS root before any
# scrub. MEASURED: DVA[1] + DVA[2] of the MOS objset block XORed → every phase green, this table "cksum 2".
zdb_vtable() {  # FILE — 0 when the table is present; ZVERR = its rows with a non-zero error count ("<vdev> r/w/c; ...")
    ZVERR=$(awk '/^description +used avail +read write +read write +read write cksum$/ { t = 1; seen = 1; next }
        t && NF < 4 { t = 0; next }
        t && !($NF ~ /^[0-9.]+[KMGTPE]?$/ && $(NF - 1) ~ /^[0-9.]+[KMGTPE]?$/ && $(NF - 2) ~ /^[0-9.]+[KMGTPE]?$/) { t = 0; next }
        t && ($(NF - 2) != "0" || $(NF - 1) != "0" || $NF != "0") { printf "%s %s/%s/%s; ", $1, $(NF - 2), $(NF - 1), $NF }
        END { exit !seen }' "$1")
}
zdb_clean() {  # FILE RC NEED-NO-LEAKS(0|1) [NEED-VDEV-TABLE(0|1): the run had -s] — 0 when clean; ZWHY says why not
    _zl=$(grep -E -m1 "$ZDB_RED" "$1")
    _zt=0; zdb_vtable "$1" && _zt=1
    if [ "$2" -ne 0 ]; then
        # ⚠ MEASURED: FreeBSD 15.1's base zdb is built with ASSERTs LIVE (libzpool ZFS_DEBUG) — a defect often ends
        # in "ASSERT at <file>:<line>:<function>()" + the failed condition and SIGABRT before zdb prints its own
        # report line, so the assertion IS the evidence
        _za=$(zdb_assert "$1"); _za=${_za:+ASSERT at $_za}
        ZWHY="zdb $(zrc_why "$2")${_za:+: $_za}${_zl:+; first red line: $_zl}${ZVERR:+; -s errors: ${ZVERR%; }}"
        [ -n "$_zl" ] || [ -n "$_za" ] || ZWHY="$ZWHY; last line: $(grep -v '^[[:space:]]*$' "$1" | tail -1)"
        return 1
    fi
    [ -z "$_zl" ] || { ZWHY="zdb exit 0 but printed: $_zl${ZVERR:+; -s errors: ${ZVERR%; }}"; return 1; }
    if [ "$3" = 1 ] && ! grep -q 'No leaks (block sum matches space maps exactly)' "$1"; then
        ZWHY="zdb exit 0 without 'No leaks (block sum matches space maps exactly)'"; return 1
    fi
    if [ "${4:-0}" = 1 ]; then
        [ "$_zt" = 1 ] || { ZWHY="zdb exit 0 but no -s vdev statistics table (it is printed last; zdb stopped short)"; return 1; }
        [ -z "$ZVERR" ] || { ZWHY="zdb exit 0 and No leaks, but the -s vdev table counts I/O errors (read/write/cksum): ${ZVERR%; } — a bad copy of a multi-copy block (-cc reads every DVA; one good copy keeps zdb silent)"; return 1; }
        ZWHY="zdb exit 0, no defect line, -s vdev error counts all 0"
        return 0
    fi
    ZWHY="zdb exit 0, no defect line"
    return 0
}
# `zpool status -v` config rows (NAME STATE READ WRITE CKSUM): ZPERR = the rows with a non-zero count; 1 when there is no
# such table. A copy repaired by a scrub — or self-healed by any read since the import — is counted here, nowhere else.
zpool_errs() {  # STATUS-FILE
    ZPERR=$(awk '$1 == "NAME" && $2 == "STATE" && $3 == "READ" && $4 == "WRITE" && $5 == "CKSUM" { t = 1; seen = 1; next }
        t && NF < 5 { t = 0; next }
        t && ($3 != "0" || $4 != "0" || $5 != "0") { printf "%s %s/%s/%s; ", $1, $3, $4, $5 }
        END { exit !seen }' "$1")
}

vmap_disks() {
    : > "$OUT/disks.map"
    for _d in $(sysctl -n kern.disks); do
        case "$_d" in vtbd*) ;; *) continue ;; esac
        _id=$(diskinfo -s "$_d" 2>/dev/null) || continue
        echo "$_id $_d $(diskinfo "$_d" | awk '{print $3}')" >> "$OUT/disks.map"
    done
}
vdevof() {     # SERIAL -> /dev/vtbdN, empty unless exactly one disk carries it
    [ "$(awk -v i="$1" '$1 == i' "$OUT/disks.map" | wc -l | tr -d ' ')" = 1 ] || return 0
    awk -v i="$1" '$1 == i {print "/dev/" $2}' "$OUT/disks.map"
}
# the dataset a manifest path lives in and the path inside it (no leading slash): the longest M mount prefix of the
# lane's expected manifest — zdb -O wants exactly that pair
ds_of() {      # MANIFEST-PATH
    awk -v p="$1" '$1 == "M" { m = $2; if (p == m || m == "/" || index(p, m "/") == 1) if (b == "" || length(m) > length(b)) { b = m; d = $3 } }
        END { if (b == "") exit 1; print d, (b == "/") ? substr(p, 2) : substr(p, length(b) + 2) }' "$SEED/$VLANE.expect"
}
obj_of() {     # DEV DATASET RELPATH -> its object id (zdb -O prints the object's dump_object row), empty when unresolved
    vzdb "$TMP/obj.O" -e -p "$1" -O "$2" "$3"
    [ "$ZRC" = 0 ] || return 0
    awk '/^ +Object +lvl +iblk/ { t = 1; next } t && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1; exit }' "$TMP/obj.O"
}

# ds_check DEV DATASET FLAGGED — one dataset through zdb -P -dd and -P -ddddd (A5; C-k15 and D-zdb reuse it):
#   object rows == the header's "N objects" (the ASSERT zdb compiles in or out, zdb.c:4329); -ddddd free of fill / type /
#   level errors; and ⭐ ds_referenced_bytes (the header, exact under -P: dmu_objset_space) == Σ dsize of every object
#   row (dn_used of each tree, the meta-dnode as object 0 and the user/group/project-used objects -1..-3 included) +
#   the asize of the objset block itself (the -ddddd header's rootbp). Those are exactly the blocks reachable from
#   ds_bp, and born / every kill branch move ds_referenced by each block's dsize (dsl_dataset.c:150-376). NOTHING in zdb
#   checks ds_referenced (B0 review, MAJOR: a forged ds_referenced + 4096 passed every phase) — this does, in phase A.
#   Appends "<dataset> <object id>" of every "path not found, possibly leaked" object (zdb.c:3790-3798) to FLAGGED, a
#   one-line summary to $DSI_LOG. 0 clean / 1 with DSI_WHY.
#   (1.57.12 B7 review, finding 3) EXCEPT an object of the extended-attribute tree of an object ON THE DELETE_QUEUE: zdb's
#   path walk dies at the unlinked owner (zfs_obj_to_path_impl answers ESTALE for the owner itself only), so its xattr
#   directory and the xattrs in it read "possibly leaked" on a pool OpenZFS alone leaves so between an unlink and the
#   drain at its next mount (zfs_rmnode purges the directory then). Such an object — ZFS_XATTR (0x1) in its pflags and in
#   every parent's up to the owner, the owner on the queue — goes to FLAGGED.xt instead (the caller reports it); an
#   xattr directory whose owner is NOT on the queue (freed, or still linked) stays FLAGGED: a writer that freed the owner
#   orphaned it.
ds_check() {
    _dc=$1; _dn=$2; _dz=$_dn; [ "${_dn#*/}" = "$_dn" ] && _dz="$_dn/"      # "pool/" is the ROOT dataset; "pool" is the MOS
    DSI_WHY=""
    vzdb "$TMP/ds.dd" -e -p "$_dc" -P -dd "$_dz"; _drc=$ZRC
    _df=$(zdd_figures "$TMP/ds.dd") || _df="- - - -"
    read -r _dhb _dho _drows _dsum <<EOF
$_df
EOF
    vzdb "$TMP/ds.d5" -e -p "$_dc" -P -ddddd "$_dz"; _d5rc=$ZRC
    _drbp=$(bp_asize "$TMP/ds.d5" '^Dataset ') || _drbp=""
    awk -v d="$_dn" -v xt="$3.xt" '
        function xa(h) { return index("13579bdfBDF", substr(h, length(h), 1)) > 0 }
        /^ +Object +lvl +iblk/ { t = 1; next }
        t && NF >= 9 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { o = $1 }
        /^[[:space:]]*path[[:space:]]+path not found, possibly leaked/ { fl[++nf] = o }
        /^[[:space:]]*path[[:space:]]+on delete queue/ { dq[o] = 1 }
        /^[[:space:]]*parent[[:space:]]+[0-9]+$/ { par[o] = $2 }
        /^[[:space:]]*pflags[[:space:]]+[0-9a-fA-F]+$/ { pf[o] = $2 }
        END {
            for (i = 1; i <= nf; i++) {
                x = fl[i]; y = x; ok = 0
                for (n = 0; n < 8 && (y in pf) && xa(pf[y]) && (y in par); n++) {
                    y = par[y]
                    if (y in dq) { ok = 1; break }
                }
                if (ok) print d, x >> xt; else print d, x
            }
        }' "$TMP/ds.d5" >> "$3"
    # (1.57.12 B7) the objects zdb finds on the dataset's DELETE_QUEUE ("on delete queue", zdb.c:3790-3793 — agnos's lazy
    # unlink, design § f.5): A5 records them per dataset (DQ_LOG) for B-acct's object identity
    [ -n "${DQ_LOG:-}" ] && echo "dq $_dn $(grep -c 'on delete queue' "$TMP/ds.d5")" >> "$DQ_LOG"
    _dred=$(grep -E -v 'potentially leaked objects detected|possibly leaked' "$TMP/ds.d5" | grep -E -m1 'does not match|ERROR|corrupt')
    grep -E 'does not match|ERROR|corrupt|possibly leaked|potentially leaked' "$TMP/ds.d5" | head -50 >> "$DSI_LOG"
    [ "$_drc" = 0 ] || DSI_WHY="$DSI_WHY -dd $(zrc_why $_drc);"
    [ "$_drows" = "$_dho" ] || DSI_WHY="$DSI_WHY $_drows object rows vs the header's $_dho;"
    [ "$_d5rc" = 0 ] || DSI_WHY="$DSI_WHY -ddddd $(zrc_why $_d5rc);"
    [ -z "$_dred" ] || DSI_WHY="$DSI_WHY $_dred;"
    if [ -z "$_drbp" ] || [ "$_dsum" = - ]; then DSI_WHY="$DSI_WHY no objset block / dsize figures;"
    elif [ "$_dhb" != "$((_dsum + _drbp))" ]; then
        DSI_WHY="$DSI_WHY referenced $_dhb != Σ dsize $_dsum + objset block $_drbp (off by $((_dhb - _dsum - _drbp)));"
    fi
    echo "$_dn referenced=$_dhb sum_dsize=$_dsum objset_asize=$_drbp rows=$_drows header=$_dho${DSI_WHY:+ BAD:$DSI_WHY}" >> "$DSI_LOG"
    [ -z "$DSI_WHY" ]
}

# ---- accounting identities -------------------------------------------------------------------
# BASE / NOW are acct_capture files (BASE also carries the build's "alloc zdb" and "mos" lines), ALLOC_NOW the lane's own
# A3 "bp allocated" (A3 already demanded "No leaks", so it is every allocated byte), MOS_NOW the lane's exact $MOS
# dd_used (A6). Checked on NOW:
#   1 every dataset: used == usedbydataset + usedbysnapshots + usedbychildren + usedbyrefreservation
#   2 every non-root parent: usedbychildren == Σ over its children of max(used, reservation) (parent_delta,
#     dsl_dir.c); the ROOT's excess over that sum is its hidden children $MOS + $FREE + $LEAK (+ $ORIGIN's, measured 0)
#     and must equal $MOS (A6, exact) + freeing + leaked + the pristine residual — B0 review: this was only ">= 0" and an
#     INFO line, so moving bytes between the root's HEAD and CHILD breakdown passed every phase
#   3 every mounted dataset with user-object accounting: (Σ objused) − (objects visible in the view) is the same
#     as in BASE — the design's "uid-0 objused == manifest count" in DELTA form, because the absolute offset
#     includes objects no walk can see (the shares dir, the directories under child mountpoints); (1.57.12 B7) less the
#     objects on its DELETE_QUEUE (`dq <dataset> <n>` lines, A5's zdb: an unlinked object OpenZFS frees at its next
#     writable mount is still charged and no longer visible)
#   4 Δ allocated (zdb) == Δ (root used − Σ every dataset's usedbyrefreservation − Σ every child's max(0, reservation
#     − used)) (design § e.1; k.6) — the unused reservations are in the root's used and in no allocation, so a write
#     into a reserved dataset below its reservation moves allocated alone (1.57.12 B4: it was "Δ root used", which
#     every OpenZFS-only round trip met only because phase C writes the root dataset, which has no reservation)
#   5 every non-clone dataset: referenced == usedbydataset — born and every kill branch move ds_referenced_bytes and
#     dd_used_breakdown[HEAD] by the same dsize (dsl_dataset.c:150-376; MEASURED equal on all 28 RECIPE 2 heads,
#     snapshotted ones included). A clone's referenced also counts its origin's blocks (kills of those leave HEAD
#     alone, :355-358), so a clone's usedbydataset is the bytes born AFTER its origin it still references — exactly
#     what OpenZFS's written@<origin> derives from its referenced, the origin's and the deadlists back to it
#     (dsl_dataset_space_written_impl): a clone is held to usedbydataset == written@<origin> (the "wo" lines B-acct
#     adds to the capture). B0 review, MAJOR: ds_referenced had no oracle at all. (1.57.12 B9 review, design k.106: B9
#     held a clone WITH snapshots of its own to referenced − usedbydataset UNCHANGED — false as soon as the clone
#     kills an origin block, which RECIPE 8's edgec does: 204800 -> 167936, the 36,864 B of origin blocks it killed.)
#   6 every filesystem / volume with a numeric `written`: usedbyrefreservation == max(0, refreservation − written)
#     (1.57.12 B4 review, MAJOR) — usedbyrefreservation is dd_used_breakdown[REFRSRV], which born / kill keep at
#     max(0, refreservation − ds_unique_bytes) (parent_delta, dsl_dataset.c:121-136), and OpenZFS derives `written`
#     (since the previous snapshot, $ORIGIN for a non-clone filesystem) WITHOUT ds_unique_bytes: referenced − the
#     previous snapshot's referenced + the head's deadlist (dsl_dataset_space_written_impl, :4744-4810) — for a head
#     that is exactly its unique bytes. Identities 1, 2 and 4 sum REFRSRV back into used, so a wrong refreservation
#     split (bytes moved between HEAD / REFRSRV and the dir's used) passed them all and showed only when phase D
#     destroyed that dataset — never for a root dataset with a refreservation (negative N5). MEASURED on every
#     pristine .acct and every B4 capture first (52 heads: snapshotted, clone, zvol and encrypted ones included).
#   Zero checked is a FAIL: no dataset through 1/5, or none through 3.
acct_check() {  # BASE NOW ALLOC_NOW MOS_NOW
    awk -v an="$3" -v mn="$4" '
    { side = (FILENAME == ARGV[1]) ? 1 : 2 }
    $1 == "get" { v[side, $2, $3] = $4; if (side == 2) ds[$2] = 1; else ds1[$2] = 1 }
    $1 == "space" && $2 == "user" && $6 ~ /^[0-9]+$/ { ou[side, $3] += $6; has[side, $3] = 1 }
    $1 == "dev" { dv[side, $2] = $3 }
    $1 == "devobjs" { dobj[side, $2] = $3 }
    $1 == "dq" { dq[side, $2] = $3 }
    $1 == "alloc" && $2 == "zdb" { ab[side] = $3; ac[side] = $5 }
    $1 == "pool" { pp[side, $2] = $3 }
    $1 == "mos" && side == 1 { mb = $2 }
    $1 == "snaps" { sn[side, $2] = $3 }
    $1 == "wo" { wo[side, $2] = $3 }
    function num(x) { return (x == "-" || x == "") ? 0 : x + 0 }
    function mx(a, b) { return a > b ? a : b }
    END {
        bad = 0; root = ""; nid = 0; nobj = 0; nrr = 0
        for (d in ds) if (index(d, "/") == 0) root = d
        if (root == "") { print "BAD no root dataset in the capture"; exit 1 }
        for (d in ds) {
            u = num(v[2, d, "used"])
            s = num(v[2, d, "usedbydataset"]) + num(v[2, d, "usedbysnapshots"]) + num(v[2, d, "usedbychildren"]) + num(v[2, d, "usedbyrefreservation"])
            if (u != s) { print "BAD " d ": used " u " != usedbydataset+usedbysnapshots+usedbychildren+usedbyrefreservation " s; bad = 1 }
            nid++
            o = v[2, d, "origin"]
            if (o == "-" || o == "") {
                if (num(v[2, d, "referenced"]) != num(v[2, d, "usedbydataset"])) {
                    print "BAD " d ": referenced " num(v[2, d, "referenced"]) " != usedbydataset " num(v[2, d, "usedbydataset"]) " (a non-clone head: ds_referenced_bytes and the HEAD breakdown move together)"; bad = 1 }
            } else if (!((1, d, "referenced") in v)) {
                print "BAD clone " d " (origin " o ") is not in the baseline"; bad = 1
            } else if (!((2, d) in wo) || wo[2, d] !~ /^[0-9]+$/) {
                print "BAD clone " d ": no numeric written@" o " in the capture"; bad = 1
            } else if (num(v[2, d, "usedbydataset"]) != num(wo[2, d])) {
                # (agnos 1.57.12 B9; B9 review, k.106) its HEAD breakdown is what it wrote after its origin and still
                # holds — a kill of an ORIGIN block leaves it alone (born before dd_origin_txg, dsl_dataset.c:358-361)
                # while referenced drops; OpenZFS derives the same bytes as written@<origin> from the deadlists
                print "BAD clone " d ": usedbydataset " num(v[2, d, "usedbydataset"]) " != written@" o " " wo[2, d] " (the bytes born after its origin it still references, derived by OpenZFS from the deadlists)"; bad = 1
            }
            w6 = v[2, d, "written"]
            if (w6 ~ /^[0-9]+$/) {
                e6 = mx(0, num(v[2, d, "refreservation"]) - w6)
                if (num(v[2, d, "usedbyrefreservation"]) != e6) { print "BAD " d ": usedbyrefreservation " num(v[2, d, "usedbyrefreservation"]) " != max(0, refreservation " num(v[2, d, "refreservation"]) " - written " w6 ") = " e6 " (REFRSRV against the unique bytes OpenZFS derives from the deadlist)"; bad = 1 }
                nrr++
            }
            sum2 = 0; sum1 = 0
            for (c in ds) if (index(c, d "/") == 1 && index(substr(c, length(d) + 2), "/") == 0) sum2 += mx(num(v[2, c, "used"]), num(v[2, c, "reservation"]))
            for (c in ds1) if (index(c, d "/") == 1 && index(substr(c, length(d) + 2), "/") == 0) sum1 += mx(num(v[1, c, "used"]), num(v[1, c, "reservation"]))
            ubc = num(v[2, d, "usedbychildren"])
            if (d == root) {
                h2 = ubc - sum2; h1 = num(v[1, d, "usedbychildren"]) - sum1
                f2 = num(pp[2, "freeing"]); l2 = num(pp[2, "leaked"]); f1 = num(pp[1, "freeing"]); l1 = num(pp[1, "leaked"])
                if (mn == "" || mb == "") { print "BAD root " d ": no exact $MOS figure (now \"" mn "\" from A6, baseline \"" mb "\")"; bad = 1 }
                else {
                    r2 = h2 - mn - f2 - l2; r1 = h1 - mb - f1 - l1
                    if (r2 != r1) { print "BAD root " d ": hidden children " h2 " B (usedbychildren " ubc " - children " sum2 ") != $MOS " mn " + $FREE " f2 " + $LEAK " l2 " + the pristine residual " r1 " (off by " r2 - r1 ")"; bad = 1 }
                    else print "INFO root " d ": hidden children " h2 " B == $MOS " mn " + $FREE " f2 " + $LEAK " l2 " + residual " r1 " (pristine " h1 " == " mb " + " f1 " + " l1 " + " r1 ")"
                }
            } else if (ubc != sum2) {
                print "BAD " d ": usedbychildren " ubc " != sum over children of max(used, reservation) " sum2; bad = 1
            }
            if (has[2, d] && has[1, d] && ((2, d) in dv) && ((1, d) in dv)) {
                o2 = ou[2, d] - dobj[2, dv[2, d]] - dq[2, d]; o1 = ou[1, d] - dobj[1, dv[1, d]] - dq[1, d]
                if (o1 != o2) { print "BAD " d ": user objused minus visible objects moved from " o1 " to " o2 " (objused " ou[2, d] ", visible " dobj[2, dv[2, d]] ")"; bad = 1 }
                nobj++
            }
        }
        if (nid == 0) { print "BAD no dataset went through the identities"; bad = 1 }
        if (nrr == 0) { print "BAD no dataset had a numeric written (identity 6)"; bad = 1 }
        if (nobj == 0) { print "BAD no dataset was object-checked (no mounted dataset with user-object accounting in both captures)"; bad = 1 }
        if (an == "" || ab[1] == "") { print "BAD no zdb allocated figure to compare (now " an ", baseline " ab[1] ")"; bad = 1 }
        else if (ac[1] != "clean") { print "BAD the PRISTINE pool is not leak-free by zdb (" ac[1] ") — no allocated baseline"; bad = 1 }
        else {
            # unused reservations are in the root used but in no allocation (1.57.12 B4: a write INTO a reserved
            # dataset below its reservation moves allocated, not the root used — parent_delta 0 at the dataset
            # (refreservation: HEAD +x, REFRSRV -x) and at its dir (dd_reserved: no change reaches the parent),
            # dsl_dataset.c:121-136, dsl_dir.c:1155-1162). So the identity is on root used minus the usedbyrefreservation
            # (REFRSRV) of every dataset and max(0, reservation - used) of every child (its parent CHILD_RSRV)
            ur2 = 0; ur1 = 0
            for (d in ds) { ur2 += num(v[2, d, "usedbyrefreservation"]); if (d != root && num(v[2, d, "reservation"]) > num(v[2, d, "used"])) ur2 += num(v[2, d, "reservation"]) - num(v[2, d, "used"]) }
            for (d in ds1) { ur1 += num(v[1, d, "usedbyrefreservation"]); if (d != root && num(v[1, d, "reservation"]) > num(v[1, d, "used"])) ur1 += num(v[1, d, "reservation"]) - num(v[1, d, "used"]) }
            da = an - ab[1]; du = (num(v[2, root, "used"]) - ur2) - (num(v[1, root, "used"]) - ur1)
            if (da != du) { print "BAD delta allocated " da " B (zdb) != delta " root " used minus unused reservations " du " B (root used " num(v[1, root, "used"]) " -> " num(v[2, root, "used"]) ", unused reservations " ur1 " -> " ur2 ")"; bad = 1 }
            else print "INFO delta allocated " da " B == delta " root " used minus unused reservations " du " B (unused reservations " ur1 " -> " ur2 "); " nid " dataset(s) through used/referenced/children, " nrr " REFRSRV == max(0, refreservation - written), " nobj " object-checked"
        }
        exit bad
    }' "$1" "$2"
}

# snap_acct POOL (agnos 1.57.12 B9) — OpenZFS's own space figures for every filesystem with snapshots, against what the
# writer maintains: its usedbysnapshots (dd_used_breakdown[SNAP], moved by every deadlisted kill — dsl_dir_transfer_space)
# == what destroying all its snapshots would reclaim, and each snapshot's used (ds_unique_bytes — the previous snapshot's
# += in branch B) == what destroying it alone would: `zfs destroy -nvpd` (-d: no dependent-clone refusal in a dry run),
# lzc_snaprange_space -> dsl_dataset_space_wouldfree, summed from the DEADLISTS the writer appended to. Sets SA_N
# (figures compared), SA_BAD, SA_INFO (what OpenZFS would not size).
snap_acct() {
    SA_N=0; SA_BAD=""; SA_INFO=""
    for _fs in $(zfs list -H -o name -t filesystem -r "$1"); do
        _sl=$(zfs list -H -o name -t snapshot -s createtxg -d 1 "$_fs")
        [ -n "$_sl" ] || continue
        _f1=$(echo "$_sl" | head -1); _fl=$(echo "$_sl" | tail -1)
        _rg="$_f1"; [ "$_f1" = "$_fl" ] || _rg="$_f1%${_fl#*@}"
        _sa1 "$_fs usedbysnapshots" "$(zfs get -Hp -o value usedbysnapshots "$_fs")" "$_rg"
        for _s in $_sl; do _sa1 "$_s used" "$(zfs get -Hp -o value used "$_s")" "$_s"; done
    done
}
_sa1() {        # WHAT WANT SPEC — one figure against zfs destroy -nvpd SPEC's reclaim
    _sr=$(zfs destroy -nvpd "$3" 2> "$TMP/sa.err" | awk -F '\t' '$1 == "reclaim" { print $2 }')
    if [ -z "$_sr" ]; then SA_INFO="$SA_INFO $3 ($(head -1 "$TMP/sa.err"))"; return; fi
    SA_N=$((SA_N + 1))
    [ "$_sr" = "$2" ] || SA_BAD="$SA_BAD $1 $2 != zfs destroy -n $3's reclaim $_sr;"
}

# ---- phase C's OpenZFS writes ---------------------------------------------------------------
# On the pool imported read-write under $CA. Targets come from <lane>.touched (the writer's own files and dirs,
# so OpenZFS frees agnos's DVAs through its own space maps — a missing agnos ALLOC record panics HERE) and fall
# back to the root dataset's own entries when there are none (bite B0: a pristine lane). Every op is JOURNALLED for
# c_expect — "F <path> <size> <sha256>" (set) · "D <path>" (new dir) · "X <path>" (gone) · "R <old> <new>" (rename, the
# subtree with it) — so C-rt can demand that the round trip reads back EXACTLY expected + what OpenZFS did (B0 review:
# C-rt only counted lines, so OpenZFS reading wrong agnos data in C went unseen).
cj() { echo "$*" >> "$TMP/c.journal"; }
# c_pre PATH — $CA$PATH's bytes into $TMP/c.pre, first held to the expected manifest's size + sha256 (they are agnos's
# blocks as OpenZFS reads them; B-manifest proved the same image), so the post-op hash c_ops journals is derived from
# bytes the oracle vouched for
c_pre() {
    _cpw=$(awk -v p="$1" '$1 == "F" && $2 == p { print $3, $4; exit }' "$_cm")
    cp "$CA$1" "$TMP/c.pre" || { C_WHY="cannot read $1"; return 1; }
    [ "$(stat -f %z "$TMP/c.pre") $(sha256 -q "$TMP/c.pre")" = "$_cpw" ] \
        || { C_WHY="$1 as the round trip reads it is not the expected ${_cpw:-(no F line)}"; return 1; }
}
# c_fresh PATH — PATH, or PATH.1, PATH.2 ...: the first name neither the expected manifest nor the pool has (a writer's
# op list may well have made an "rt-new"; MEASURED on a lane that had been round-tripped once already)
c_fresh() {
    _cfn=$1; _cfi=0
    while [ -e "$CA$_cfn" ] || awk -v p="$_cfn" '$2 == p { f = 1 } END { exit !f }' "$_cm"; do
        _cfi=$((_cfi + 1)); _cfn="$1.$_cfi"
    done
    echo "$_cfn"
}
c_ops() {       # POOL — 0 / 1 with C_WHY; journal in $TMP/c.journal, the k.15 file's path in $TMP/c.k15
    _cp=$1; _cm="$SEED/$VLANE.expect"
    : > "$TMP/c.journal"; : > "$TMP/c.k15"; : > "$TMP/c.k15x"
    awk -v d="$_cp" 'NR == FNR { if ($1 == "M") mp[$2] = $3; next }
        $1 != "M" { b = ""; for (q in mp) if ($2 == q || index($2, (q == "/" ? "/" : q "/")) == 1) if (length(q) > length(b)) b = q
                    if (b != "" && mp[b] == d) print $1, $2, ($1 == "F" ? $3 : 0) }' "$_cm" "$_cm" > "$TMP/c.root"
    _crm=$(awk -v d="$_cp" '$1 == "M" && $3 == d {print $2}' "$_cm")
    [ -n "$_crm" ] || { C_WHY="the root dataset $_cp is not mounted in the expected manifest"; return 1; }
    _crn=$(c_fresh "${_crm%/}/rt-new")
    : > "$TMP/c.touched"
    [ -f "$SEED/$VLANE.touched" ] && cp "$SEED/$VLANE.touched" "$TMP/c.touched"
    # FILENAME, not NR == FNR: an EMPTY touched list must not swallow the second file
    _cf=$( { awk 'FILENAME == ARGV[1] { t[$2] = 1; next } $1 == "F" && $3 > 0 && ($2 in t) {print $3, $2}' "$TMP/c.touched" "$TMP/c.root" | sort -n;
             awk 'FILENAME == ARGV[1] { t[$2] = 1; next } $1 == "F" && $3 > 0 && !($2 in t) {print $3, $2}' "$TMP/c.touched" "$TMP/c.root" | sort -n; } \
           | awk '{print $2}')
    _capp=$(echo "$_cf" | sed -n 1p); _crmf=$(echo "$_cf" | sed -n 2p)
    _cow=$(echo "$_cf" | tail -1); [ "$_cow" = "$_capp" ] || [ "$_cow" = "$_crmf" ] && _cow=""
    [ -n "$_capp" ] && [ -n "$_crmf" ] || { C_WHY="fewer than two non-empty files in the root dataset"; return 1; }
    _cdir=$(awk -v r="$_crm" 'NR == FNR { if ($1 == "M") m[$2] = 1; next }
        $1 == "D" && $2 != r && !($2 in m) { for (q in m) if (index(q, $2 "/") == 1) next; print $2 }' "$_cm" "$TMP/c.root" \
        | awk 'FILENAME == ARGV[1] { t[$2] = 1; next } { print (($1 in t) ? 0 : 1), $1 }' "$TMP/c.touched" - | sort | awk '{print $2; exit}')
    [ -n "$_cdir" ] || { C_WHY="no directory to rename in the root dataset"; return 1; }
    C_WHY="append to $_capp"
    c_pre "$_capp" || return 1
    printf 'appended by OpenZFS in the round trip\n' >> "$TMP/c.pre"
    cj F "$_capp" "$(stat -f %z "$TMP/c.pre")" "$(sha256 -q "$TMP/c.pre")"
    printf 'appended by OpenZFS in the round trip\n' >> "$CA$_capp" || return 1
    if [ -n "$_cow" ]; then
        C_WHY="overwrite in $_cow"
        c_pre "$_cow" || return 1
        _csz=$(stat -f %z "$TMP/c.pre")
        rand_bytes rt-overwrite 4096 | dd of="$TMP/c.pre" bs=4096 seek=$(( _csz / 2 / 4096 )) conv=notrunc 2>/dev/null || return 1
        cj F "$_cow" "$(stat -f %z "$TMP/c.pre")" "$(sha256 -q "$TMP/c.pre")"
        rand_bytes rt-overwrite 4096 | dd of="$CA$_cow" bs=4096 seek=$(( _csz / 2 / 4096 )) conv=notrunc 2>/dev/null || return 1
    fi
    # (agnos 1.57.12 B5 review) OpenZFS on top of a writer state in a CHILD dataset — B5's truncations, RMWs and appends
    # live in children (rs4k at nlevels 3, big1m's truncation): the first touched file outside the root dataset gets 4 KiB
    # overwritten mid-file and a line appended, through OpenZFS's own space maps (C acted on root files only)
    _cch=$(awk 'FILENAME == ARGV[1] { if ($1 == "F" && $3 > 0) sz[$2] = 1; next } FILENAME == ARGV[2] { r[$2] = 1; next }
               $1 == "F" && ($2 in sz) && !($2 in r) { print $2; exit }' "$_cm" "$TMP/c.root" "$TMP/c.touched")
    if [ -n "$_cch" ]; then
        C_WHY="overwrite + append in $_cch (a child dataset)"
        c_pre "$_cch" || return 1
        _csz=$(stat -f %z "$TMP/c.pre")
        rand_bytes rt-child 4096 | dd of="$TMP/c.pre" bs=4096 seek=$(( _csz / 2 / 4096 )) conv=notrunc 2>/dev/null || return 1
        printf 'appended by OpenZFS in a child dataset\n' >> "$TMP/c.pre"
        cj F "$_cch" "$(stat -f %z "$TMP/c.pre")" "$(sha256 -q "$TMP/c.pre")"
        rand_bytes rt-child 4096 | dd of="$CA$_cch" bs=4096 seek=$(( _csz / 2 / 4096 )) conv=notrunc 2>/dev/null || return 1
        printf 'appended by OpenZFS in a child dataset\n' >> "$CA$_cch" || return 1
    fi
    # (1.57.12 B7) a name the writer LINKED: removing it is OpenZFS's own k.15 — the object lives on under its other name
    # with whatever PARENT the last link / rename gave it — so C-k15 tolerates that object too (by id: stat's inode)
    _crl=$(stat -f '%i %l' "$CA$_crmf" 2>/dev/null)
    [ "${_crl#* }" -gt 1 ] 2>/dev/null && { _crw=$(ds_of "$_crmf"); echo "${_crw%% *} ${_crl%% *}" >> "$TMP/c.k15x"; }
    C_WHY="rm $_crmf"; rm "$CA$_crmf" || return 1; cj X "$_crmf"
    _cav=$(zfs get -Hp -o value available "$_cp")
    _ccp=$(( _cav / 4 / 4096 * 4096 )); [ "$_ccp" -gt 3145728 ] && _ccp=3145728
    C_WHY="mkdir + copy $_ccp B"
    mkdir "$CA$_crn" && rand_bytes rt-copy "$_ccp" > "$CA$_crn/copy.bin" || return 1
    cj D "$_crn"; cj F "$_crn/copy.bin" "$_ccp" "$(rand_bytes rt-copy "$_ccp" | sha256 -q)"
    _crt=$(c_fresh "$_cdir.rt")
    C_WHY="rename $_cdir"; mv "$CA$_cdir" "$CA$_crt" || return 1; cj R "$_cdir" "$_crt"
    _cln=$(awk 'BEGIN { s = "round-trip-name-past-the-microzap-limit-"; while (length(s) < 60) s = s "z"; print s }')
    C_WHY="60-byte name in $_crt"; printf 'long name\n' > "$CA$_crt/$_cln" || return 1
    cj F "$_crt/$_cln" 10 "$(printf 'long name\n' | sha256 -q)"
    _cempty=$(awk '$1 == "D" {print $2}' "$TMP/c.touched" | while read -r _ce; do
        [ -d "$CA$_ce" ] && [ -z "$(ls -A "$CA$_ce" 2>/dev/null)" ] && { echo "$_ce"; break; }; done)
    if [ -n "$_cempty" ]; then C_WHY="rmdir $_cempty"; rmdir "$CA$_cempty" || return 1; cj X "$_cempty"
    else _cre=$(c_fresh "${_crm%/}/rt-empty"); C_WHY="mkdir + rmdir $_cre"; mkdir "$CA$_cre" && rmdir "$CA$_cre" || return 1; fi
    # design k.15 made by OpenZFS itself: link the appended file into rt-new/ and unlink that name again — FreeBSD
    # writes PARENT := rt-new on the link (zfs_dir.c:640-641) and nothing rewrites it, so the file stays live with a
    # PARENT that holds no entry for it. C-k15 then runs the A5 machinery on it.
    _ck=$_capp
    case "$_capp" in "$_cdir"/*) _ck="$_crt${_capp#"$_cdir"}" ;; esac
    C_WHY="k.15 link + unlink of $_ck"
    ln "$CA$_ck" "$CA$_crn/k15-link" && rm "$CA$_crn/k15-link" || return 1
    echo "$_ck" > "$TMP/c.k15"
    C_WHY="snapshot + destroy $_cp@rt-snap"; zfs snapshot "$_cp@rt-snap" && zfs destroy "$_cp@rt-snap" || return 1
    C_WHY="zpool sync"; zpool sync "$_cp" || return 1
    C_WHY="appended $_capp${_cow:+, overwrote 4 KiB mid-$_cow}${_cch:+, overwrote 4 KiB mid-$_cch + appended (child dataset)}, removed $_crmf, copied $_ccp B to $_crn/, renamed $_cdir to $_crt, 60-byte name in it, ${_cempty:+rmdir $_cempty}$( [ -n "$_cempty" ] || echo mkdir+rmdir ), k.15 link+unlink of $_ck, snapshot+destroy ($(wc -l < "$TMP/c.journal" | tr -d ' ') journal lines)"
    return 0
}
# c_expect EXPECTED JOURNAL — the expected manifest after the journal, in write_manifest's sort order
c_expect() {
    awk 'FILENAME == ARGV[1] { if ($1 == "M") { m[++nm] = $0; next } k = $2; t[k] = $1; l[k] = $0; next }
         $1 == "F" { t[$2] = "F"; l[$2] = "F " $2 " " $3 " " $4; next }
         $1 == "D" { t[$2] = "D"; l[$2] = "D " $2; next }
         $1 == "X" { delete t[$2]; delete l[$2]; next }
         $1 == "R" { o = $2; n = $3; nk = 0
                     for (k in t) if (k == o || index(k, o "/") == 1) mv[++nk] = k
                     for (i = 1; i <= nk; i++) { k = mv[i]; q = n substr(k, length(o) + 1)
                         nt[q] = t[k]; nl[q] = t[k] " " q substr(l[k], length(t[k]) + length(k) + 2); delete t[k]; delete l[k] }
                     for (q in nt) { t[q] = nt[q]; l[q] = nl[q] }
                     split("", nt); split("", nl) }
         END { for (k in l) print l[k]; for (i = 1; i <= nm; i++) print m[i] }' "$1" "$2" | LC_ALL=C sort -t ' ' -k2,2 -k1,1
}

# why an import failed: zpool's own "cannot import" line + the kernel's spa_load_failed() reason from the ZFS
# debug ring (sysctl kstat.zfs.misc.dbgmsg) — zpool says "no such pool or dataset" for a missing log space map,
# the ring says which txg
import_why() {   # IMPORT-OUTPUT-FILE
    _iw=$(grep -m1 'cannot import' "$1")
    _ik=$(sysctl -n kstat.zfs.misc.dbgmsg 2>/dev/null | grep 'FAILED: ' | sed 's/.*FAILED: //' | sort -u | head -3 | tr '\n' ';' | sed 's/;$//')
    echo "${_iw:-$(grep -v '^[[:space:]]*$' "$1" | head -1)}${_ik:+ — kernel: $_ik}"
}

vexport() {     # POOL — export (retrying the vnode-release lag), forcing as a last resort so the next lane starts clean
    VERIFY_MODE=1 export_ro "$1" && return 0
    zpool export -f "$1" 2>/dev/null
    return 1
}
vfree() {       # POOL -> "<freeing> <leaked>" (zpool get -Hp; a NEGATIVE $FREE wraps to ~1.8e19 — compared as strings)
    echo "$(zpool get -Hp -o value freeing "$1") $(zpool get -Hp -o value leaked "$1")"
}

# ---- phase D: one dataset at a time, then the root -------------------------------------------
# d_destroy POOL — every dataset but the root, ONE AT A TIME (B0 review, MAJOR: one batched destroy + one freeing check
# let a block charged to the wrong sibling cancel inside $FREE): the next victim is a clone if any (its origin snapshot
# cannot go while it lives), else the deepest dataset without children; `zfs destroy -r` takes its snapshots and
# bookmarks; zpool wait -t free; freeing and leaked must be exactly what they were before it. Then every remaining
# snapshot the same way. Sets D_N, D_SN, D_BAD; details in $VO.D.destroy.txt.
d_destroy() {
    D_N=0; D_SN=0; D_BAD=""; : > "$VO.D.destroy.txt"
    while [ "$D_N" -lt 400 ]; do
        _dv=$(zfs list -H -o name,origin -t filesystem,volume -r "$1" | awk -F '\t' -v p="$1" '
            { n[NR] = $1; o[NR] = $2 }
            END { best = ""; bc = -1; bd = -1
                  for (i = 1; i <= NR; i++) { if (n[i] == p) continue; leaf = 1
                      for (j = 1; j <= NR; j++) if (index(n[j], n[i] "/") == 1) leaf = 0
                      if (!leaf) continue
                      c = (o[i] != "-") ? 1 : 0; dp = gsub(/\//, "/", n[i])
                      if (c > bc || (c == bc && dp > bd)) { best = n[i]; bc = c; bd = dp } }
                  print best }')
        [ -n "$_dv" ] || break
        _dset "$1" "$_dv" "zfs destroy -r" || break
        D_N=$((D_N + 1))
    done
    for _dv in $(zfs list -H -t snapshot -o name -r "$1"); do
        _dset "$1" "$_dv" "zfs destroy" || break
        D_SN=$((D_SN + 1))
    done
}
_dset() {       # POOL VICTIM HOW — one destroy + wait + the $FREE / $LEAK check
    _db=$(vfree "$1"); _du=$(zfs get -Hp -o value used "$2" 2>/dev/null)
    # shellcheck disable=SC2086
    if ! $3 "$2" > "$TMP/d.err" 2>&1; then
        D_BAD="$D_BAD $2(destroy refused: $(head -1 "$TMP/d.err"))"; return 1
    fi
    timeout 600 zpool wait -t free "$1"; _dw=$?
    _da=$(vfree "$1")
    echo "$2 used $_du: freeing/leaked $_db -> $_da, zpool wait rc $_dw" >> "$VO.D.destroy.txt"
    if [ "$_dw" != 0 ] || [ "$_da" != "$_db" ]; then
        D_BAD="$D_BAD $2(used $_du; freeing/leaked $_db -> $_da, wait rc $_dw$( [ ${#_da} -gt 30 ] && echo '; a ~1.8e19 freeing is a NEGATIVE residual: dd_used was too small'))"
    fi
    return 0
}
# d_root POOL — OpenZFS empties the root dataset through its own kill path (rm -rf, unmount so every vnode is
# inactivated and its object freed, sync, wait free): freeing / leaked unchanged; referenced == usedbydataset; the
# uid-0 object count equals a FRESH empty dataset's (the root dir + the shares dir, nothing an rm can reach). Returns
# 0 / 1 / 2 (skip: the root cannot be mounted) with D_WHY. The absolute byte identity follows in D-zdb (ds_check).
d_root() {
    _rmp=$(zfs get -H -o value mountpoint "$1"); _rcm=$(zfs get -H -o value canmount "$1")
    if [ "$_rcm" != on ] || [ "$_rmp" = none ] || [ "$_rmp" = legacy ]; then D_WHY="root canmount=$_rcm mountpoint=$_rmp"; return 2; fi
    zfs mount "$1" 2> "$TMP/d.err" || { D_WHY="zfs mount $1: $(head -1 "$TMP/d.err")"; return 1; }
    _rmp=$(zfs get -H -o value mountpoint "$1")
    _rn=$(ls -A "$_rmp" | wc -l | tr -d ' ')
    _db=$(vfree "$1")
    ( cd "$_rmp" && ls -A | while IFS= read -r _re; do rm -rf "./$_re"; done ) 2> "$TMP/d.err"
    [ -z "$(ls -A "$_rmp")" ] || { D_WHY="rm -rf left: $(ls -A "$_rmp" | head -3 | tr '\n' ' ') ($(head -1 "$TMP/d.err"))"; return 1; }
    _rt=0
    until zfs unmount "$1" 2>/dev/null; do
        _rt=$((_rt + 1)); [ $_rt -lt 30 ] || { D_WHY="zfs unmount $1 still refused after 60 s"; return 1; }; sleep 2
    done
    zpool sync "$1"
    timeout 600 zpool wait -t free "$1"; _dw=$?
    _da=$(vfree "$1")
    _rr=$(zfs get -Hp -o value referenced "$1"); _ru=$(zfs get -Hp -o value usedbydataset "$1")
    # both MOUNTED before `zfs userspace` (an unmounted dataset makes FreeBSD build a temporary zfsvfs — the path that
    # hung, see acct_capture); the empty dataset mounts beside the root, not inside it (its mountpoint directory would be
    # one more root object)
    zfs mount "$1" 2> "$TMP/d.err" || { D_WHY="zfs mount $1 (again): $(head -1 "$TMP/d.err")"; return 1; }
    zfs create -o mountpoint=/d-empty "$1/d-empty" && zpool sync "$1" || { D_WHY="zfs create $1/d-empty failed"; return 1; }
    _ro=$(zfs userspace -Hpn -o name,objused "$1" | awk '$1 == "0" { print $2 }')
    _eo=$(zfs userspace -Hpn -o name,objused "$1/d-empty" | awk '$1 == "0" { print $2 }')
    D_WHY="removed $_rn top-level entr$( [ "$_rn" = 1 ] && echo y || echo ies) (unmount needed $_rt retr$( [ "$_rt" = 1 ] && echo y || echo ies)); freeing/leaked $_db -> $_da; referenced $_rr, usedbydataset $_ru; uid-0 objused $_ro, a fresh empty dataset's ${_eo:-?}"
    [ "$_dw" = 0 ] && [ "$_da" = "$_db" ] && [ "$_rr" = "$_ru" ] && [ -n "$_ro" ] && [ "$_ro" = "$_eo" ]
}

verify_lane() {  # LANE POOL SERIAL-A SERIAL-C SERIAL-D SHA TXG PTXG VTXG MTXG PREV1 PREV2
    VLANE=$1; VP=$2; VSHA=$6; VTXG=$7; VPTXG=$8; VVTXG=$9; VMTXG=${10}; VPREV="${11} ${12}"
    VDA=$(vdevof "$3"); VDC=$(vdevof "$4"); VDD=$(vdevof "$5")
    VO="$OUT/$VLANE"; VFAILS=0; VMOS=""
    echo "zfsfix: verify $VLANE BEGIN pool $VP, A $VDA C $VDC D $VDD, expected txg $VTXG (pristine $VPTXG)"
    if [ -z "$VDA" ] || [ -z "$VDC" ] || [ -z "$VDD" ]; then
        vstep SETUP FAIL "disk serials $3 / $4 / $5 not each found exactly once"; vend; return
    fi
    for _vd in "$VDA" "$VDC" "$VDD"; do
        _vh=$(sha256 -q "$_vd")
        [ "$_vh" = "$VSHA" ] || { vstep SETUP FAIL "$_vd sha256 $_vh != the host's $VSHA"; vend; return; }
    done
    if zpool list -H "$VP" > /dev/null 2>&1; then vstep SETUP FAIL "a pool named $VP is already imported"; vend; return; fi
    vstep SETUP PASS "A $VDA (read-only), C $VDC, D $VDD all sha256 $VSHA"

    # ---- A ----
    vzdb "$VO.A1.txt" -lu "$VDA"
    _lab=$(grep -m1 'labels = ' "$VO.A1.txt" | sed 's/^ *//; s/ *$//')
    _amx=$(awk '/^\ttxg = / { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }' "$VO.A1.txt")
    if [ "$ZRC" -ne 0 ]; then vstep A1 FAIL "zdb -lu $(zrc_why $ZRC)"
    elif [ "$_lab" != "labels = 0 1 2 3" ]; then vstep A1 FAIL "the four labels' configs are not identical ($_lab)"
    elif ! grep -q "^    state: 1\$" "$VO.A1.txt"; then vstep A1 FAIL "label state is not 1 (EXPORTED)"
    elif ! grep -q "^    name: '$VP'\$" "$VO.A1.txt"; then vstep A1 FAIL "label names another pool"
    elif [ "$_amx" != "$VMTXG" ]; then vstep A1 FAIL "zdb -lu's highest uberblock txg $_amx != the host's $VMTXG"
    elif [ "$VMTXG" != "$VVTXG" ]; then vstep A1 FAIL "a slot carries the magic at txg $VMTXG but the highest that verifies is $VVTXG — OpenZFS would ignore the newer one"
    else vstep A1 PASS "4 identical labels, state EXPORTED, name $VP, highest uberblock txg $_amx"; fi

    vzdb "$VO.A2.txt" -e -p "$VDA" -u "$VP"
    _atx=$(awk '/^\ttxg = / { print $3; exit }' "$VO.A2.txt")
    if [ "$ZRC" -ne 0 ]; then zdb_clean "$VO.A2.txt" "$ZRC" 0; vstep A2 FAIL "-u: $ZWHY"
    elif [ "$_atx" != "$VTXG" ]; then vstep A2 FAIL "the selected uberblock is txg ${_atx:-none}, the lane's expected txg is $VTXG"
    else vstep A2 PASS "selected uberblock txg $_atx == the lane's expected txg"; fi

    vzdb "$VO.A3.txt" -e -p "$VDA" -P -bcc -d -m -s -y "$VP"
    if zdb_clean "$VO.A3.txt" "$ZRC" 1 1; then vstep A3 PASS "zdb -P -bcc -d -m -s -y: No leaks, $ZWHY"
    else vstep A3 FAIL "$ZWHY"; fi
    VALLOC=$(awk '$1 == "bp" && $2 == "allocated:" { print $3; exit }' "$VO.A3.txt")
    vzdb "$VO.A3m.txt" -e -p "$VDA" -mmmm "$VP"
    if zdb_clean "$VO.A3m.txt" "$ZRC" 0; then vstep A3m PASS "zdb -mmmm: $ZWHY (smp_alloc == entries in every space map)"
    elif [ "$ZRC" -gt 128 ] && [ -s "$SEED/$VLANE.mload" ] \
        && [ "$(zdb_assert "$VO.A3m.txt" | sed 's/ failed (.*//')" = "$(sed 's/ failed (.*//' "$SEED/$VLANE.mload")" ]; then
        # RECIPE 4: OpenZFS's own pristine pool trips this very load-time ASSERT (logs_census) — the -L run still checks
        # smp_alloc == entries in every space map; A3's -bcc leak check is unaffected (its loads do not take that path)
        _a3w=$ZWHY
        vzdb "$VO.A3m.L.txt" -e -p "$VDA" -mmmm -L "$VP"
        if zdb_clean "$VO.A3m.L.txt" "$ZRC" 0; then vstep A3m PASS "zdb -mmmm -L: $ZWHY (smp_alloc == entries in every space map) — plain -mmmm: $_a3w, the ASSERT the PRISTINE image trips too (the fixture's load probe)"
        else vstep A3m FAIL "-L: $ZWHY (plain -mmmm: $_a3w)"; fi
    else vstep A3m FAIL "$ZWHY"; fi

    # (1.57.12 B10, design § c.5) A3y: the LOG SET as OpenZFS's own zdb lists it (A3's -m: "Log Spacemap object O txg T",
    # each metaslab's "unflushed txg=U") — exactly the host replay's count ($SEED/<lane>.logs), none older than the least
    # nonzero U (spa_cleanup_old_sm_logs destroys it in the txg the last U passes it: an obsolete log a writer left), every
    # nonzero U naming one (the import's ENOENT), the newest the lane's own txg (every agnos commit writes log T)
    _a3y=$(awk -v want="$(cat "$SEED/$VLANE.logs" 2>/dev/null)" -v vt="$VTXG" '
        /^[[:space:]]*unflushed txg=/ { u = $0; sub(/.*unflushed txg=/, "", u); u = u + 0; if (u > 0) { U[u] = 1; if (mu == 0 || u < mu) mu = u }; next }
        $1 == "Log" && $2 == "Spacemap" && $3 == "object" { n++; t = $6 + 0; L[t] = 1; if (lo == 0 || t < lo) lo = t; if (t > hi) hi = t; next }
        END {
            if (want == "") { print "FAIL no host count of the live log space maps"; exit }
            if (n != want + 0) { print "FAIL zdb -m lists " n " log space map(s), the host replay " want; exit }
            if (mu > 0 && lo > 0 && lo < mu) { print "FAIL log txg " lo " is older than every unflushed txg (the least is " mu ")"; exit }
            for (u in U) if (!(u in L)) { print "FAIL unflushed txg " u " names no log space map"; exit }
            if (n > 0 && hi != vt + 0) { print "FAIL the newest log is txg " hi ", the lane ends at " vt; exit }
            print "PASS " n " log space map(s), txg " lo ".." hi ", least unflushed txg " mu
        }' "$VO.A3.txt")
    case "$_a3y" in
        PASS*) vstep A3y PASS "zdb -m: ${_a3y#PASS }" ;;
        *) vstep A3y FAIL "${_a3y#FAIL }" ;;
    esac

    if [ "$VTXG" -gt "$VPTXG" ] || [ "$V_FORCE_A4" = 1 ]; then
        # The rewind targets are the two uberblocks BELOW the selected one, by what the ring actually holds — on an
        # agnos lane T-1 and T-2 (agnos writes every txg's uberblock), on an OpenZFS pool whatever its last syncs
        # left (MEASURED: empty txgs write no uberblock — main's ring jumps 62 -> 89 -> 98, so `-t 97` correctly
        # selects 89). ⚠ Only an agnos lane's T-1/T-2 are guaranteed intact (no frees are reused within a boot);
        # OpenZFS reuses space freed 2 txgs back, so --force-a4 on a pristine pool may legitimately go red on the
        # older target.
        for _at in $VPREV; do
            [ "$_at" = - ] && { vstep A4 SKIP "the ring holds no earlier verifying uberblock"; continue; }
            vzdb "$VO.A4-$_at.txt" -e -p "$VDA" -t "$_at" -u -P -bcc -d -m -s -y "$VP"
            _atx=$(awk '/^\ttxg = / { print $3; exit }' "$VO.A4-$_at.txt")
            if ! zdb_clean "$VO.A4-$_at.txt" "$ZRC" 1 1; then vstep A4 FAIL "-t $_at: $ZWHY"
            elif [ "$_atx" != "$_at" ]; then vstep A4 FAIL "-t $_at selected uberblock txg ${_atx:-none}"
            else vstep A4 PASS "-t $_at: uberblock $_atx, No leaks, $ZWHY"; fi
        done
    else
        vstep A4 SKIP "no txg beyond the pristine best $VPTXG (rewind is checked on writer lanes)"
    fi

    _a5n=0; _a5bad=""; : > "$VO.A5.txt"; : > "$TMP/a5.flagged"; : > "$TMP/a5.flagged.xt"; : > "$TMP/a5.tol"; DSI_LOG="$VO.A5.txt"; DQ_LOG="$VO.dq"; : > "$VO.dq"
    # every head filesystem AND volume (a zvol's referenced obeys the same identity; it has no ZPL objects to flag)
    awk '/^Dataset / && ($3 == "[ZPL]," || $3 == "[ZVOL],") && $2 !~ /@/ { print $2 }' "$VO.A3.txt" > "$TMP/a5.ds"
    while read -r _ads; do
        grep -qx "$_ads" "$SEED/$VLANE.skipds" 2>/dev/null && continue
        ds_check "$VDA" "$_ads" "$TMP/a5.flagged" || _a5bad="$_a5bad $_ads($DSI_WHY)"
        _a5n=$((_a5n + 1))
    done < "$TMP/a5.ds"
    # design k.15: the objects the op list predicts a stale PARENT for, by object id — a count would let a real orphan
    # stand in for an expected one (B0 review)
    if [ -s "$SEED/$VLANE.leakok" ]; then
        while IFS= read -r _lp; do
            [ -n "$_lp" ] || continue
            _lw=$(ds_of "$_lp") || { _a5bad="$_a5bad k.15 path $_lp(no dataset of the expected manifest mounts it)"; continue; }
            _lo=$(obj_of "$VDA" "${_lw%% *}" "${_lw#* }")
            if [ -n "$_lo" ]; then echo "${_lw%% *} $_lo" >> "$TMP/a5.tol"; echo "k.15 tolerated: $_lp = ${_lw%% *} object $_lo" >> "$VO.A5.txt"
            else _a5bad="$_a5bad k.15 path $_lp(zdb -O could not resolve it)"; fi
        done < "$SEED/$VLANE.leakok"
    fi
    _a5x=$(awk 'FILENAME == ARGV[1] { t[$0] = 1; next } !($0 in t)' "$TMP/a5.tol" "$TMP/a5.flagged" | sort -u | tr '\n' ',' | sed 's/,$//')
    _a5m=$(awk 'FILENAME == ARGV[1] { t[$0] = 1; next } !($0 in t)' "$TMP/a5.flagged" "$TMP/a5.tol" | sort -u | tr '\n' ',' | sed 's/,$//')
    _a5f=$(sort -u "$TMP/a5.flagged" | wc -l | tr -d ' ')
    # (B7 review, finding 3) EXACTLY the k.15 list: a predicted object zdb does not flag is a FAIL too (it was INFO) —
    # the model of where PARENT points is then wrong, and the tolerance could cover an object it should not
    _a5t=$(sort -u "$TMP/a5.flagged.xt" | tr '\n' ',' | sed 's/,$//')
    if [ "$_a5n" = 0 ]; then vstep A5 FAIL "A3's zdb -d listed no ZPL / ZVOL dataset (it did not run to completion)"
    elif [ -n "$_a5bad" ] || [ -n "$_a5x" ] || [ -n "$_a5m" ]; then vstep A5 FAIL "${_a5bad# }${_a5x:+ possibly-leaked objects NOT on the k.15 list: $_a5x}${_a5m:+ k.15 objects the op list predicts but zdb did not flag: $_a5m}"
    else vstep A5 PASS "$_a5n dataset(s): object rows == header, referenced == Σ dsize + objset block, -ddddd clean, $_a5f possibly-leaked object(s), exactly the k.15 list"; fi
    [ -z "$_a5t" ] || vstep A5 INFO "objects of the xattr tree of an object on a DELETE_QUEUE (zdb's path walk dies at the unlinked owner; OpenZFS purges them at its next mount): $_a5t"
    DQ_LOG=""
    _a5q=$(awk '$3 > 0 { printf "%s%s %d", s, $2, $3; s = ", " }' "$VO.dq")
    [ -z "$_a5q" ] || vstep A5 INFO "objects on a DELETE_QUEUE (the lazy unlink — OpenZFS frees them at its next writable mount): $_a5q"

    # A6: the MOS — its own dd_used against what its blocks occupy, held to the pristine pool's residual (the
    # baseline's "mos" line; MEASURED on RECIPE 3: see the gate log)
    vzdb "$VO.A6.txt" -e -p "$VDA" -P -dd "$VP" 0:281474976710655; _a6rc=$ZRC
    _a6f=$(zdd_figures "$VO.A6.txt") || _a6f="- - - -"
    read -r _a6m _a6o _a6rows _a6sum <<EOF
$_a6f
EOF
    _a6r=$(bp_asize "$VO.A2.txt" '^[[:space:]]*bp = ') || _a6r=""
    read -r _a6bm _a6bs _a6br <<EOF
$(awk '$1 == "mos" { print $2, $3, $4 }' "$SEED/$VLANE.base.acct")
EOF
    if [ "$_a6rc" -ne 0 ]; then zdb_clean "$VO.A6.txt" "$_a6rc" 0; vstep A6 FAIL "zdb -P -dd of the MOS: $ZWHY"
    elif [ "$_a6m" = - ]; then vstep A6 FAIL "zdb -P -dd of the MOS printed no 'Dataset mos' header"
    elif [ "$_a6rows" != "$_a6o" ]; then vstep A6 FAIL "$_a6rows MOS object rows vs the header's $_a6o"
    elif [ -z "$_a6r" ]; then vstep A6 FAIL "no rootbp DVAs in A2's zdb -u"
    elif [ -z "$_a6bm" ]; then vstep A6 FAIL "the baseline has no mos line (fixture older than RECIPE 3)"
    else
        VMOS=$_a6m
        _a6d=$((_a6m - _a6sum - _a6r)); _a6bd=$((_a6bm - _a6bs - _a6br))
        if [ "$_a6d" != "$_a6bd" ]; then vstep A6 FAIL "\$MOS dd_used $_a6m - (Σ dsize $_a6sum + MOS objset block $_a6r) = $_a6d, the pristine pool's $_a6bd"
        else vstep A6 PASS "\$MOS dd_used $_a6m == Σ dsize $_a6sum + MOS objset block $_a6r + $_a6d (pristine residual $_a6bd), $_a6rows objects"; fi
    fi

    if [ "$VFAILS" -gt 0 ] && [ "$V_CONTINUE" != 1 ]; then
        for _ph in B C D; do vstep "$_ph" SKIP "phase A failed (continue=0: an import of a broken pool can panic the guest)"; done
        vend; return
    fi

    # ---- B ----
    rm -rf "$RO"; mkdir -p "$RO"
    zpool import -o readonly=on -R "$RO" -d "$VDA" "$VP" > "$VO.B.import.txt" 2>&1
    _irc=$?
    if ! zpool list -H "$VP" > /dev/null 2>&1; then
        vstep B-import FAIL "read-only import failed (rc $_irc): $(import_why "$VO.B.import.txt")"
    else
        vstep B-import PASS "read-only import without -f (rc $_irc)"
        zfs mount -a 2>/dev/null
        if VERIFY_MODE=1 check_mounts "$VP"; then vstep B-mounts PASS "every mountable dataset mounted"
        else vstep B-mounts FAIL "$HELPER_ERR"; fi
        if VERIFY_MODE=1 write_manifest "$VP" "$OUT/$VLANE.B.manifest" "$OUT/$VLANE.B.dirsize"; then
            if cmp -s "$SEED/$VLANE.expect" "$OUT/$VLANE.B.manifest"; then
                vstep B-manifest PASS "$(wc -l < "$OUT/$VLANE.B.manifest" | tr -d ' ') lines identical to the expected manifest"
            else
                diff "$SEED/$VLANE.expect" "$OUT/$VLANE.B.manifest" > "$OUT/$VLANE.B.diff"
                vstep B-manifest FAIL "$(grep -c '^[<>]' "$OUT/$VLANE.B.diff") differing line(s), first: $(grep -m2 '^[<>]' "$OUT/$VLANE.B.diff" | cut -c1-160 | tr '\n' ' ')"
            fi
            _dnew=$(grep '^MISMATCH' "$OUT/$VLANE.B.dirsize" | while IFS= read -r _dl; do
                grep -qxF "$_dl" "$SEED/$VLANE.base.dirsize" || echo "$_dl"; done | head -3 | tr '\n' ';')
            _dok=$(grep -c '^OK' "$OUT/$VLANE.B.dirsize")
            if [ -n "$_dnew" ]; then vstep B-dirsize FAIL "$_dnew"
            elif [ "$_dok" = 0 ]; then vstep B-dirsize FAIL "no directory was size-checked (the -fstype zfs walk saw none)"
            else vstep B-dirsize PASS "$_dok directories size == entries + 2 ($(grep -c '^MISMATCH' "$OUT/$VLANE.B.dirsize") pristine exception(s))"; fi
            # (agnos 1.57.12 B6) OpenZFS's own stat(1) of every object the writer CREATED (<lane>.stat, from the op list and
            # the expected manifest): mode, uid 0, the parent directory's gid, links, size
            if [ -s "$SEED/$VLANE.stat" ]; then
                _sbad=""; _sn=0
                while read -r _sp _sm _sl _sz; do
                    _sn=$((_sn + 1))
                    _sq=${_sp%/*}; [ -n "$_sq" ] || _sq=/
                    _sw="$_sm 0 $(stat -f %g "$RO$_sq" 2>/dev/null) $_sl $_sz"
                    _sh=$(stat -f '%p %u %g %l %z' "$RO$_sp" 2>/dev/null)
                    [ "$_sh" = "$_sw" ] || _sbad="$_sbad $_sp: '$_sh' != '$_sw';"
                done < "$SEED/$VLANE.stat"
                if [ -n "$_sbad" ]; then vstep B-stat FAIL "$(echo "$_sbad" | cut -c2-400)"
                else vstep B-stat PASS "$_sn object(s) the writer created: stat(1) mode, uid 0, the parent's gid, links, size as expected"; fi
            else vstep B-stat SKIP "the op list created no object"; fi
            # (B6) OpenZFS's own NFSv4 ACL of every created object (getfacl, through zfs_acl_node_read) == the ACL it reads
            # for a FreeBSD-made TWIN of the same type and mode in the same dataset (find -x: not into child datasets;
            # the first three candidates the op list did not create) — so a wrong ACE, count or byte the stat above
            # cannot show is OpenZFS's to see, not only the host's zfs-sa-check.py
            if [ -s "$SEED/$VLANE.stat" ]; then
                _abad=""; _an=0
                awk '{ print $1 }' "$SEED/$VLANE.stat" > "$TMP/b6.made"
                while read -r _sp _sm _sl _sz; do
                    _an=$((_an + 1))
                    _amp=$(awk -v p="$_sp" '$1 == "M" && (p == $2 || index(p, ($2 == "/" ? "/" : $2 "/")) == 1) { if (length($2) > length(b)) b = $2 } END { print b }' "$SEED/$VLANE.expect")
                    _aty=f; _ah=""; case "$_sm" in 4*) _aty=d ;; 12*) _aty=l; _ah=-h ;; esac
                    { getfacl -q -n $_ah "$RO$_sp" 2>&1 || echo "getfacl failed"; } | sed "s|$RO$_sp|PATH|g" > "$TMP/acl.made"
                    _amatch=""; _atw=""
                    # (B8) an object in a NEW SA layout has no twin in its own dataset by construction (the layout was
                    # new there): then the twins come from any dataset of the pool — the ACL does not depend on it
                    _acands=$(find -x "$RO$_amp" -type "$_aty" -perm "${_sm#${_sm%???}}" 2>/dev/null | sed "s|^$RO||" | grep -vxF -f "$TMP/b6.made" | head -3)
                    [ -n "$_acands" ] || _acands=$(find "$RO" -type "$_aty" -perm "${_sm#${_sm%???}}" 2>/dev/null | sed "s|^$RO||" | grep -vxF -f "$TMP/b6.made" | head -3)
                    for _ac in $_acands; do
                        _atw="$_atw $_ac"
                        { getfacl -q -n $_ah "$RO$_ac" 2>&1 || echo "getfacl failed"; } | sed "s|$RO$_ac|PATH|g" > "$TMP/acl.twin"
                        cmp -s "$TMP/acl.made" "$TMP/acl.twin" && { _amatch=$_ac; break; }
                    done
                    if [ -z "$_atw" ]; then _abad="$_abad $_sp: no FreeBSD twin (type $_aty, mode ${_sm#${_sm%???}}) in $_amp or the pool;"
                    elif [ -z "$_amatch" ]; then _abad="$_abad $_sp: '$(tr '\n' ' ' < "$TMP/acl.made" | cut -c1-120)' != the twins'$_atw;"; fi
                done < "$SEED/$VLANE.stat"
                if [ -n "$_abad" ]; then vstep B-acl FAIL "$(echo "$_abad" | cut -c2-400)"
                else vstep B-acl PASS "$_an object(s) the writer created: getfacl == a FreeBSD-made twin's (same type, mode, dataset)"; fi
            else vstep B-acl SKIP "the op list created no object"; fi
        else
            vstep B-manifest FAIL "$HELPER_ERR"
        fi
        # extended attributes live in SA / spill / xattr dirs agnos rewrites when it touches a file (B0 review)
        write_xattrs "$OUT/$VLANE.B.xattrs"
        if cmp -s "$SEED/$VLANE.xattrs" "$OUT/$VLANE.B.xattrs"; then
            vstep B-xattrs PASS "$(wc -l < "$OUT/$VLANE.B.xattrs" | tr -d ' ') xattr line(s) identical to the expected listing"
        else
            diff "$SEED/$VLANE.xattrs" "$OUT/$VLANE.B.xattrs" > "$OUT/$VLANE.B.xdiff"
            vstep B-xattrs FAIL "$(grep -c '^[<>]' "$OUT/$VLANE.B.xdiff") differing line(s), first: $(grep -m2 '^[<>]' "$OUT/$VLANE.B.xdiff" | cut -c1-160 | tr '\n' ' ')"
        fi
        _st=$(zpool status -x "$VP" 2>&1)
        zpool status -v "$VP" > "$VO.B.status.txt" 2>&1
        if ! zpool_errs "$VO.B.status.txt"; then vstep B-status FAIL "zpool status -v has no NAME/STATE/READ/WRITE/CKSUM table"
        elif [ -n "$ZPERR" ]; then vstep B-status FAIL "error counters: ${ZPERR%; }"
        else case "$_st" in *"is healthy"*) vstep B-status PASS "$_st; every READ/WRITE/CKSUM counter 0" ;;
                            *) vstep B-status FAIL "$(echo "$_st" | head -3 | tr '\n' ' ')" ;; esac; fi
        if acct_capture "$VP" "$OUT/$VLANE.B.acct"; then
            cat "$OUT/$VLANE.B.acct" "$VO.dq" > "$TMP/b.acct" 2>/dev/null
            # (B9 review, k.106) every clone's written@<origin> — what identity 5 holds its usedbydataset to
            zfs get -H -o name,value -t filesystem,volume -r origin "$VP" 2>/dev/null | awk -F '\t' '$2 != "-" { print $1, $2 }' \
                | while read -r _cn _co; do echo "wo $_cn $(zfs get -Hp -o value "written@$_co" "$_cn" 2>/dev/null)"; done >> "$TMP/b.acct"
            if acct_check "$SEED/$VLANE.base.acct" "$TMP/b.acct" "$VALLOC" "$VMOS" > "$OUT/$VLANE.B.acctcheck"; then
                vstep B-acct PASS "$(grep '^INFO delta' "$OUT/$VLANE.B.acctcheck" | sed 's/^INFO //')"
            else
                vstep B-acct FAIL "$(grep '^BAD' "$OUT/$VLANE.B.acctcheck" | head -3 | sed 's/^BAD //' | tr '\n' ';')"
            fi
            grep '^INFO root' "$OUT/$VLANE.B.acctcheck" | sed 's/^INFO //' | while IFS= read -r _il; do vstep B-acct INFO "$_il"; done
        else
            vstep B-acct FAIL "accounting capture failed"
        fi
        # (agnos 1.57.12 B9) every snapshot's OWN contents == the pristine pool's (<image>.snaps, snap_manifests): a writer
        # must never touch what a snapshot holds — a block it freed instead of deadlisting reads back wrong once reused
        if [ -s "$SEED/$VLANE.snaps" ]; then
            if VERIFY_MODE=1 snap_manifests "$VP" "$OUT/$VLANE.B.snaps"; then
                if cmp -s "$SEED/$VLANE.snaps" "$OUT/$VLANE.B.snaps"; then
                    vstep B-snap PASS "$(grep -c '^S ' "$OUT/$VLANE.B.snaps") snapshot(s), $(grep -vc '^S ' "$OUT/$VLANE.B.snaps") line(s) identical to the pristine snapshots' own trees"
                else
                    diff "$SEED/$VLANE.snaps" "$OUT/$VLANE.B.snaps" > "$OUT/$VLANE.B.snapdiff"
                    vstep B-snap FAIL "$(grep -c '^[<>]' "$OUT/$VLANE.B.snapdiff") differing line(s), first: $(grep -m2 '^[<>]' "$OUT/$VLANE.B.snapdiff" | cut -c1-160 | tr '\n' ' ')"
                fi
            else vstep B-snap FAIL "$HELPER_ERR"; fi
        else vstep B-snap SKIP "the pool has no snapshot"; fi
        # (B9) OpenZFS's own space figures for every snapshotted filesystem against the writer's accounting (snap_acct)
        snap_acct "$VP"
        if [ "$SA_N" = 0 ]; then vstep B-snapacct SKIP "no snapshot${SA_INFO:+ OpenZFS would size:$SA_INFO}"
        elif [ -n "$SA_BAD" ]; then vstep B-snapacct FAIL "$(echo "${SA_BAD# }" | cut -c1-400)"
        else vstep B-snapacct PASS "$SA_N figure(s): every snapshotted filesystem's usedbysnapshots == zfs destroy -n of all its snapshots, every snapshot's used == zfs destroy -n of it alone (OpenZFS's dsl_dataset_space_wouldfree over the deadlists)"; fi
        vexport "$VP" || vstep B-export FAIL "$HELPER_ERR"
    fi

    # ---- C ----
    rm -rf "$CA"; mkdir -p "$CA"
    zpool import -R "$CA" -d "$VDC" "$VP" > "$VO.C.import.txt" 2>&1
    _irc=$?
    if ! zpool list -H "$VP" > /dev/null 2>&1; then
        vstep C-import FAIL "read-write import failed (rc $_irc): $(import_why "$VO.C.import.txt")"
    else
        vstep C-import PASS "read-write import of copy C without -f (rc $_irc)"
        zfs mount -a 2>/dev/null
        if ! timeout 900 zpool scrub -w "$VP"; then vstep C-scrub FAIL "zpool scrub -w did not finish"
        else
            zpool status -v "$VP" > "$VO.C.scrub.txt" 2>&1
            _sl=$(grep -m1 'scan:' "$VO.C.scrub.txt" | sed 's/^ *//')
            if ! zpool_errs "$VO.C.scrub.txt"; then vstep C-scrub FAIL "$_sl; zpool status -v has no error-counter table"
            elif [ -n "$ZPERR" ]; then vstep C-scrub FAIL "$_sl; error counters since the import: ${ZPERR%; }"
            elif grep -q 'scrub repaired 0B' "$VO.C.scrub.txt" && grep -q 'with 0 errors' "$VO.C.scrub.txt" \
                && grep -q 'No known data errors' "$VO.C.scrub.txt"; then vstep C-scrub PASS "$_sl; every READ/WRITE/CKSUM counter 0"
            else vstep C-scrub FAIL "$_sl; $(grep -m1 'errors:' "$VO.C.scrub.txt" | sed 's/^ *//')"; fi
        fi
        if c_ops "$VP"; then vstep C-ops PASS "OpenZFS on top: $C_WHY"
        else vstep C-ops FAIL "OpenZFS could not: $C_WHY"; fi
        cp "$TMP/c.journal" "$VO.C.journal" 2>/dev/null
        zpool sync "$VP" 2>/dev/null
        if vexport "$VP"; then vstep C-export PASS "exported"
        else vstep C-export FAIL "$HELPER_ERR"; fi
        vzdb "$VO.C.A3.txt" -e -p "$VDC" -P -bcc -d -m -s -y "$VP"
        _calloc=$(awk '$1 == "bp" && $2 == "allocated:" { print $3; exit }' "$VO.C.A3.txt")
        if zdb_clean "$VO.C.A3.txt" "$ZRC" 1 1; then vstep C-zdb PASS "after OpenZFS's own export (it flushes every log space map): No leaks, $ZWHY"
        else vstep C-zdb FAIL "$ZWHY"; fi
        vzdb "$VO.C.A3m.txt" -e -p "$VDC" -mmmm "$VP"
        if zdb_clean "$VO.C.A3m.txt" "$ZRC" 0; then vstep C-zdbm PASS "zdb -mmmm: $ZWHY"
        else vstep C-zdbm FAIL "$ZWHY"; fi
        # C-k15: OpenZFS made one stale-PARENT object on purpose (c_ops). The A5 machinery must flag it, and nothing in
        # the root dataset beyond it and the objects A5 already tolerated (a writer lane's own k.15 objects keep their
        # object ids in the copy; one the round trip removed simply drops out)
        : > "$TMP/c.flagged"; : > "$TMP/c.flagged.xt"; DSI_LOG="$VO.C.k15.txt"; : > "$DSI_LOG"
        _kp=$(cat "$TMP/c.k15" 2>/dev/null)
        if [ -z "$_kp" ]; then vstep C-k15 FAIL "c_ops made no k.15 link/unlink pair"
        else
            ds_check "$VDC" "$VP" "$TMP/c.flagged"; _kok=$?
            _kw=$(ds_of "$_kp"); _ko=$(obj_of "$VDC" "${_kw%% *}" "${_kw#* }")
            { cat "$TMP/a5.tol" "$TMP/c.k15x" 2>/dev/null; echo "${_kw%% *} $_ko"; } > "$TMP/c.tol"
            _kx=$(awk 'FILENAME == ARGV[1] { t[$0] = 1; next } !($0 in t)' "$TMP/c.tol" "$TMP/c.flagged" | sort -u | tr '\n' ',' | sed 's/,$//')
            if [ "$_kok" != 0 ]; then vstep C-k15 FAIL "the round-tripped root dataset: $DSI_WHY"
            elif [ -z "$_ko" ]; then vstep C-k15 FAIL "zdb -O could not resolve $_kp"
            elif ! grep -qxF "${_kw%% *} $_ko" "$TMP/c.flagged"; then vstep C-k15 FAIL "zdb -ddddd did not flag $_kp (${_kw%% *} object $_ko) — the k.15 model (PARENT := the link's directory) does not hold"
            elif [ -n "$_kx" ]; then vstep C-k15 FAIL "zdb -ddddd flags objects neither the round trip nor A5's k.15 list explain: $_kx"
            else vstep C-k15 PASS "link + unlink of the new name left $_kp (object $_ko) with a stale PARENT: zdb -ddddd flags it and nothing unexplained; the round-tripped root's referenced == Σ dsize + objset block"; fi
        fi
        rm -rf "$RO"; mkdir -p "$RO"
        zpool import -o readonly=on -R "$RO" -d "$VDC" "$VP" > /dev/null 2>&1
        if zpool list -H "$VP" > /dev/null 2>&1; then
            zfs mount -a 2>/dev/null
            if VERIFY_MODE=1 write_manifest "$VP" "$OUT/$VLANE.rt.manifest" "$OUT/$VLANE.rt.dirsize"; then
                c_expect "$SEED/$VLANE.expect" "$TMP/c.journal" > "$OUT/$VLANE.rt.expect"
                if [ ! -s "$TMP/c.journal" ]; then vstep C-rt FAIL "no journal of the round trip's ops (C-ops failed)"
                elif cmp -s "$OUT/$VLANE.rt.expect" "$OUT/$VLANE.rt.manifest"; then
                    vstep C-rt PASS "$(wc -l < "$OUT/$VLANE.rt.manifest" | tr -d ' ')-line $VLANE.rt.manifest == expected + the round trip's $(wc -l < "$TMP/c.journal" | tr -d ' ') journalled change(s) ($(grep -c '^MISMATCH' "$OUT/$VLANE.rt.dirsize") dir-size mismatch(es))"
                else
                    diff "$OUT/$VLANE.rt.expect" "$OUT/$VLANE.rt.manifest" > "$OUT/$VLANE.rt.diff"
                    vstep C-rt FAIL "$(grep -c '^[<>]' "$OUT/$VLANE.rt.diff") line(s) differ from expected + journal, first: $(grep -m2 '^[<>]' "$OUT/$VLANE.rt.diff" | cut -c1-160 | tr '\n' ' ')"
                fi
                _rtu=$(zfs get -Hp -o value used "$VP")
                _bu=$(awk -v p="$VP" '$1 == "get" && $2 == p && $3 == "used" { print $4 }' "$SEED/$VLANE.base.acct")
                if [ -n "$_calloc" ] && [ -n "$VALLOC" ] && [ -n "$_bu" ]; then
                    _rbu=$(awk -v p="$VP" '$1 == "get" && $2 == p && $3 == "used" { print $4 }' "$OUT/$VLANE.B.acct" 2>/dev/null)
                    vstep C-k6 INFO "OpenZFS-only round trip: delta allocated $((_calloc - VALLOC)) B (zdb), delta root used $((_rtu - ${_rbu:-$_bu})) B — design k.6, not gating"
                fi
            else
                vstep C-rt FAIL "$HELPER_ERR"
            fi
            vexport "$VP" || vstep C-rt FAIL "$HELPER_ERR"
        else
            vstep C-rt FAIL "read-only re-import of the round-tripped copy failed"
        fi
    fi

    # ---- D ----
    rm -rf "$DA"; mkdir -p "$DA"
    zpool import -N -R "$DA" -d "$VDD" "$VP" > "$VO.D.import.txt" 2>&1
    _irc=$?
    if ! zpool list -H "$VP" > /dev/null 2>&1; then
        vstep D-import FAIL "read-write import failed (rc $_irc): $(import_why "$VO.D.import.txt")"
    else
        # (1.57.12 B7) what the writer DEFERRED to free_bpobj (a gang / dedup / clone block's kill, charged to $FREE —
        # design § e.2) is OpenZFS's async destroy's to free from its first txgs (dsl_process_async_destroys): `freeing`
        # (B's read-only view: $FREE as the writer left it) must drain to 0 with `leaked` 0 — before any destroy, so the
        # per-dataset freeing checks below start from 0. A pool nothing was deferred on passes trivially (0 -> 0).
        _dfb=$(awk '$1 == "pool" && $2 == "freeing" { print $3 }' "$OUT/$VLANE.B.acct" 2>/dev/null)
        timeout 600 zpool wait -t free "$VP"; _dfw=$?
        _dfa=$(vfree "$VP")
        if [ "$_dfw" = 0 ] && [ "$_dfa" = "0 0" ]; then vstep D-drain PASS "freeing ${_dfb:-?} B in B's read-only view -> 0 after the writable import's async destroy (zpool wait -t free), leaked 0"
        else vstep D-drain FAIL "freeing ${_dfb:-?} B in B's view -> freeing/leaked $_dfa after zpool wait -t free (rc $_dfw)"; fi
        d_destroy "$VP"
        if [ -n "$D_BAD" ]; then vstep D-destroy FAIL "${D_BAD# }"
        elif [ "$D_N" = 0 ] && [ "$D_SN" = 0 ]; then vstep D-destroy SKIP "no dataset but the root and no snapshot (D-root covers the root)"
        else vstep D-destroy PASS "$D_N dataset(s) (clones first, then the deepest; each with its snapshots) + $D_SN snapshot(s), ONE AT A TIME: after each, zpool wait -t free left freeing and leaked where they were"; fi
        # (agnos 1.57.12 B9) every snapshot is gone now — each destroy processed the DEADLISTS the writer appended to
        # (dsl_destroy_snapshot_sync_impl frees what was born after the snapshot's own previous one and moves the rest) —
        # so a scrub reads every block still referenced: one the writer deadlisted while the head still used it was freed
        # by those destroys (and D-zdb's leak check counts it too)
        if ! timeout 900 zpool scrub -w "$VP"; then vstep D-scrub FAIL "zpool scrub -w did not finish"
        else
            zpool status -v "$VP" > "$VO.D.scrub.txt" 2>&1
            _sl=$(grep -m1 'scan:' "$VO.D.scrub.txt" | sed 's/^ *//')
            if ! zpool_errs "$VO.D.scrub.txt"; then vstep D-scrub FAIL "$_sl; zpool status -v has no error-counter table"
            elif [ -n "$ZPERR" ]; then vstep D-scrub FAIL "$_sl; error counters since the import: ${ZPERR%; }"
            elif grep -q 'scrub repaired 0B' "$VO.D.scrub.txt" && grep -q 'with 0 errors' "$VO.D.scrub.txt" \
                && grep -q 'No known data errors' "$VO.D.scrub.txt"; then vstep D-scrub PASS "after the destroys: $_sl; every READ/WRITE/CKSUM counter 0"
            else vstep D-scrub FAIL "$_sl; $(grep -m1 'errors:' "$VO.D.scrub.txt" | sed 's/^ *//')"; fi
        fi
        d_root "$VP"; _drr=$?
        if [ "$_drr" = 0 ]; then vstep D-root PASS "$D_WHY"
        elif [ "$_drr" = 2 ]; then vstep D-root SKIP "$D_WHY"
        else vstep D-root FAIL "$D_WHY"; fi
        _df=$(vfree "$VP")
        if [ "$_df" = "0 0" ]; then vstep D-free PASS "freeing 0, leaked 0 at the end"
        else vstep D-free FAIL "freeing/leaked $_df at the end"; fi
        if vexport "$VP"; then
            vzdb "$VO.D.zdb.txt" -e -p "$VDD" -P -bcc -d -s "$VP"
            zdb_clean "$VO.D.zdb.txt" "$ZRC" 1 1; _dzc=$?; _dzw=$ZWHY
            : > "$TMP/d.flagged"; : > "$TMP/d.flagged.xt"; DSI_LOG="$VO.D.ds.txt"; : > "$DSI_LOG"; _ddb=""; _ddn=0
            for _ddd in $(awk '/^Dataset / && ($3 == "[ZPL]," || $3 == "[ZVOL],") && $2 !~ /@/ { print $2 }' "$VO.D.zdb.txt"); do
                ds_check "$VDD" "$_ddd" "$TMP/d.flagged" || _ddb="$_ddb $_ddd($DSI_WHY)"; _ddn=$((_ddn + 1))
            done
            [ -s "$TMP/d.flagged" ] && _ddb="$_ddb possibly-leaked objects left: $(sort -u "$TMP/d.flagged" | tr '\n' ',' | sed 's/,$//')"
            if [ "$_dzc" != 0 ]; then vstep D-zdb FAIL "$_dzw"
            elif [ "$_ddn" = 0 ] || [ -n "$_ddb" ]; then vstep D-zdb FAIL "ds_check of what is left (${_ddn} dataset(s)):${_ddb:- none listed}"
            else vstep D-zdb PASS "final zdb -P -bcc -d -s: No leaks, $_dzw; $_ddn remaining dataset(s): referenced == Σ dsize + objset block"; fi
        else
            vstep D-zdb FAIL "export failed: $HELPER_ERR"
        fi
    fi
    vend
}

vend() {
    if zpool list -H "$VP" > /dev/null 2>&1; then
        zpool export -f "$VP" 2>/dev/null
        # a pool that will not leave makes every later lane of the same pool name VOID at SETUP — so it is THIS
        # lane's defect, and red here (B0 review)
        zpool list -H "$VP" > /dev/null 2>&1 && vstep CLEANUP FAIL "pool $VP is still imported after export -f (every later lane of this pool will be VOID)"
    fi
    if [ "$VFAILS" -eq 0 ]; then echo "zfsfix: verify $VLANE DONE PASS"
    else echo "zfsfix: verify $VLANE DONE FAIL ($VFAILS failed step(s))"; fi
    echo "$VLANE DONE $([ "$VFAILS" -eq 0 ] && echo PASS || echo FAIL)" >> "$OUT/verify.steps"
}

verify_main() {
    VERIFY_MODE=1
    V_CONTINUE=$(awk -F= '$1 == "continue" {print $2}' "$SEED/verify.opts" 2>/dev/null); V_CONTINUE=${V_CONTINUE:-0}
    V_FORCE_A4=$(awk -F= '$1 == "force_a4" {print $2}' "$SEED/verify.opts" 2>/dev/null); V_FORCE_A4=${V_FORCE_A4:-0}
    : > "$OUT/verify.steps"
    vmap_disks
    # Heartbeat: every 60 s, what has been running longest — so a slow step can be told from a hung one on the console
    # (B0 review). The host's silence deadline does NOT count these lines as progress: a hang still trips it, now with
    # the hung command named in the log.
    ( while sleep 60; do
          _hb=$(ps -ax -o etime= -o command= | awk '{ c = $2; sub(/.*\//, "", c) }
              c ~ /^(zfs|zpool|zdb|find|stat|sha256|lsextattr|getextattr|rm|dd|cp|timeout|awk|sort|diff|ln|mv)$/ { print }' \
              | sort -r | head -3 | tr -s ' ' | cut -c1-140 | tr '\n' ';')
          echo "zfsfix: heartbeat $(date +%T) ${_hb:-nothing long-running}" > /dev/console
      done ) &
    _hbpid=$!
    log "verify begin: $(wc -l < "$SEED/verify.conf" | tr -d ' ') lane(s), continue=$V_CONTINUE force_a4=$V_FORCE_A4"
    while read -r _l _p _sa _sc _sd _sh _t _pt _vt _mt _p1 _p2; do
        [ -n "$_l" ] || continue
        verify_lane "$_l" "$_p" "$_sa" "$_sc" "$_sd" "$_sh" "$_t" "$_pt" "$_vt" "$_mt" "${_p1:--}" "${_p2:--}" < /dev/null
    done < "$SEED/verify.conf"
    kill "$_hbpid" 2>/dev/null
    [ "$(zpool list -H 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || log "WARNING: a pool is still imported at the end"
    echo OK > "$OUT/STATUS"
    log "verify end — every lane ran; the verdicts are the 'verify <lane> ...' lines (STATUS OK only means that)"
}
# <<< VERIFY HALF

# ---------------------------------------------------------------------------------------------
mkdir -p "$OUT" "$RW" "$TMP" || exit 1
log "guest $(uname -rm), $(zfs version | head -1)"
{
    uname -a; zfs version; echo
    sysctl vfs.zfs.version vfs.zfs.metaslab.force_ganging vfs.zfs.metaslab.force_ganging_pct \
        vfs.zfs.bclone_enabled vfs.zfs.xattr_compat vfs.zfs.vdev.min_auto_ashift \
        vfs.zfs.keep_log_spacemaps_at_export vfs.zfs.min_metaslabs_to_flush vfs.zfs.unflushed_log_block_min \
        vfs.zfs.unflushed_log_txg_max 2>&1
} > "$OUT/guest-info.txt"
if [ "$GUEST_MODE" = verify ]; then
    verify_main
    exit 0
fi
: > "$OUT/images.sha256"
map_disks

build_main
build_ashift9
build_v28
build_mirror
build_makefs
build_raidz
build_wr
build_full
build_logs
build_fz

[ "$(zpool list -H 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || die "a pool is still imported at the end"
echo OK > "$OUT/STATUS"
log "all pools built, exported and described — STATUS OK"
