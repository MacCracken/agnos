#!/bin/sh
# zfs-fixture-guest.sh — the FreeBSD half of scripts/tool/zfs-fixture.sh. NEVER run this on the host.
#
# Runs INSIDE the throwaway FreeBSD 15.1 guest, as root, once: nuageinit's user-data (written by
# zfs-fixture.sh) mounts the CIDATA seed read-only and hands off here, then ships OUT back on the
# results disk and powers off whatever this script did. It builds every recipe pool with the guest's
# own OpenZFS on WHOLE raw virtio disks, then re-reads each pool through a read-only import under an
# altroot and writes the manifest the AGNOS ZFS smoke compares the kernel's view against.
#
# usage: sh zfs-fixture-guest.sh SEED_DIR OUT_DIR
#   SEED_DIR  the mounted CIDATA disk: this script, disks.conf, recipe.conf, optional payload.tar
#   OUT_DIR   flat results directory (no subdirectories: the host extracts it with a name check)
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

set -u

SEED=${1:?usage: zfs-fixture-guest.sh SEED_DIR OUT_DIR}
OUT=${2:?usage: zfs-fixture-guest.sh SEED_DIR OUT_DIR}
RW=/mnt/rw                  # altroot while building (keeps the guest's own / untouched)
RO=/mnt/m                   # altroot of the read-only re-import: the manifest's "/"
TMP=/var/tmp/zfsfix         # UFS scratch: makefs staging, payload staging
SECRET_PASS="agnos-zfs-fixture-passphrase"
RECIPE_IMAGES="main ashift9 v28 mirror-a mirror-b makefs raidz-0 raidz-1 raidz-2"

log() { echo "zfsfix: $*"; }
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
write_manifest() {   # POOL OUTFILE
    _pool=$1; _mf=$2; _t="$TMP/mf.$_pool"
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
    ) || die "manifest walk of $_pool failed"
    zfs list -H -o name,mountpoint,mounted -r "$_pool" | awk -F '\t' -v ro="$RO" '
        $3 == "yes" { p = $2; if (p == ro) p = "/"; else if (index(p, ro "/") == 1) p = substr(p, length(ro) + 1);
                      else { print "BAD mountpoint outside altroot: " $0 > "/dev/stderr"; exit 1 }
                      print "M " p " " $1 }' > "$_t/m" || die "mount list of $_pool failed"
    cat "$_t/d" "$_t/f" "$_t/l" "$_t/m" | LC_ALL=C sort -t ' ' -k2,2 -k1,1 > "$_mf"
    grep -q '^F .* $' "$_mf" && die "manifest of $_pool has an F line without a hash"
    # directory-size cross-check: every ZFS directory's (st_size - 2) vs its children in the manifest
    awk 'NR == FNR { if ($1 == "M" || $2 == "/") next
                     p = $2; sub(/\/[^\/]*$/, "", p); if (p == "") p = "/"; n[p]++; next }
         { d = $2; sub(/^\./, "", d); if (d == "") d = "/"
           printf "%s %s size=%d entries=%d\n", (($1 - 2) == n[d] + 0 ? "OK      " : "MISMATCH"), d, $1, n[d] + 0 }' \
        "$_mf" "$_t/dsz" | LC_ALL=C sort -b -k2,2 > "$OUT/$_pool.dirsize"
    log "  manifest: $(grep -c '^D ' "$_mf") D, $(grep -c '^F ' "$_mf") F, $(grep -c '^L ' "$_mf") L, $(grep -c '^M ' "$_mf") M"
    if grep -q '^MISMATCH' "$OUT/$_pool.dirsize"; then
        grep '^MISMATCH' "$OUT/$_pool.dirsize" | sed 's/^/zfsfix:   dir size /'
        # makefs's own directory accounting is checked against, not trusted (see build_makefs); an
        # OpenZFS-written pool whose directory sizes disagree with the walk means the WALK is wrong
        [ "$_pool" = agnosmk ] || die "$_pool: directory sizes disagree with the manifest walk"
    fi
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
        END { exit bad }' || die "read-only import of $1 did not mount the expected set of datasets"
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
    check_expect "$_pool" "$_mf"
    ( cd "$RO" && find . -links +0 -exec stat -f '%i %N' {} + ) | sed 's| \./| /|; s| \.$| /|' | LC_ALL=C sort -k2 > "$OUT/$_first.objects"

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
    # shellcheck disable=SC2086
    zdb_sec "$_s" -e $_pargs -bb "$_pool"
    if [ "$_pool" = agnostank ]; then
        oracle_main_objects "$_s" "$_pargs" "$_OBJS"
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
    for _i in $_imgs; do
        echo "$_i $(sha256 -q "$(dev "$_i")")" >> "$OUT/images.sha256"
        if [ "$_i" != "$_first" ]; then
            cp "$_mf" "$OUT/$_i.manifest"; cp "$_s" "$OUT/$_i.summary"
            cp "$OUT/$_first.xattrs" "$OUT/$_i.xattrs"; cp "$OUT/$_first.objects" "$OUT/$_i.objects"
        fi
    done
    log "$_pool: exported, labels state=EXPORTED, oracle written"
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
    log "  main: small.txt EMBEDDED, dir3000 fat ZAP, gang.bin $_g/$_gt L0 BPs gang"
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
        [ $_try -lt 30 ] || { zpool export "$1"; die "zpool export $1 still refused after 60 s"; }
        sleep 2
    done
    [ $_try -eq 0 ] || log "  (export of the read-only $1 needed $_try retr$( [ $_try -eq 1 ] && echo y || echo ies) — vnode release lag)"
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

    export_pool $P
    oracle $P main
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
    export_pool $P
    oracle $P ashift9
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

# ---------------------------------------------------------------------------------------------
mkdir -p "$OUT" "$RW" "$TMP" || exit 1
: > "$OUT/images.sha256"
log "guest $(uname -rm), $(zfs version | head -1)"
{
    uname -a; zfs version; echo
    sysctl vfs.zfs.version vfs.zfs.metaslab.force_ganging vfs.zfs.metaslab.force_ganging_pct \
        vfs.zfs.bclone_enabled vfs.zfs.xattr_compat vfs.zfs.vdev.min_auto_ashift 2>&1
} > "$OUT/guest-info.txt"
map_disks

build_main
build_ashift9
build_v28
build_mirror
build_makefs
build_raidz

[ "$(zpool list -H 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || die "a pool is still imported at the end"
echo OK > "$OUT/STATUS"
log "all pools built, exported and described — STATUS OK"
