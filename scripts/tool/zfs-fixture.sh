#!/bin/bash
# ZFS fixture generator — the test ORACLE for AGNOS's read-only ZFS driver.
#
# This box has no ZFS tooling (no zpool/zfs/zdb/makefs) and a ZFS reader checked only against
# itself proves nothing, so the pools are built by a REAL OpenZFS: a throwaway FreeBSD 15.1 guest
# (OpenZFS in base) under QEMU/KVM builds every recipe pool directly on whole raw disk files, re-reads
# each one through a read-only import, records a manifest of what that import shows, and exports it.
# The kernel smoke boots AGNOS against the images and compares what the kernel reads to the manifest.
#
# usage: scripts/tool/zfs-fixture.sh [--ensure | --rebuild] [--payload DIR]
#   --ensure     (default) reuse the fixture if its DONE stamp exists, else build it
#   --rebuild    always build (the old fixture is replaced only once the new one has verified)
#   --payload D  also put D's files (recursive, regular files + dirs, mode 0755) in agnostank/payload
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
#            r<RECIPE>-<payloadhash>/   one fixture; payloadhash = 12 hex of sha256 over the payload's
#                                       sorted "sha256  relpath" listing, or `nopayload`
# Fixture: <image>.img        main ashift9 v28 mirror-a mirror-b makefs raidz-0 raidz-1 raidz-2
#          <image>.manifest   THE CONTRACT — lines sorted bytewise by path, then type letter; paths are
#                             relative to the read-only import's altroot, which is "/":
#                               D <path>                  directory (the altroot itself is "D /")
#                               F <path> <size> <sha256>  regular file (hard links under every name)
#                               L <path> <target>         symlink; target verbatim to end of line
#                               M <path> <dataset>        mount point of every MOUNTED dataset
#                             i.e. exactly what `zpool import -o readonly=on -R /mnt/m -d <disk(s)>
#                             <pool>` + `zfs mount -a` shows. Multi-disk pools (mirror, raidz) carry
#                             an identical copy under every member image's name.
#          <image>.summary    zpool/zfs properties, feature@ states, zdb -l / -C / -uuu / -d / -bb, and for
#                             main the zdb -dddd(d) object dumps (EMBEDDED, fat ZAP, gang, SA/spill)
#          <image>.xattrs     X <path> user <name> <len> <sha256>  (not part of the manifest contract)
#          <image>.objects    <object id> <path> — stat's inode is the ZFS object id within its dataset
#          INDEX, SHA256SUMS, RECIPE, log/ (serial + guest logs, the expected-content registries), DONE
#
# Bump RECIPE whenever zfs-fixture-guest.sh (or the disk set below) changes what gets built: the
# fixture directory is keyed on it, so a stale cache can never satisfy --ensure for a new recipe.

set -u

RECIPE=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUEST_SCRIPT="$ROOT/scripts/tool/zfs-fixture-guest.sh"
FIXROOT="${ZFS_FIXTURE_DIR:-$HOME/.cache/agnos/zfs-fixtures}"
GUEST_TIMEOUT="${ZFS_FIXTURE_TIMEOUT:-1200}"     # seconds; a healthy cold build takes a few minutes

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
"
RESULTS_MB=64

say() { echo "zfs-fixture: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

MODE=ensure
PAYLOAD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ensure)  MODE=ensure ;;
        --rebuild) MODE=rebuild ;;
        --payload) [ $# -ge 2 ] || die "--payload needs a directory"; PAYLOAD="$2"; shift ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
        *) die "unknown argument '$1' (usage: zfs-fixture.sh [--ensure | --rebuild] [--payload DIR])" ;;
    esac
    shift
done

for tool in qemu-system-x86_64 qemu-img mkfs.vfat mcopy xz curl sha256sum tar python3 truncate awk; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool '$tool'"
done
[ -f "$GUEST_SCRIPT" ] || die "guest script not found at $GUEST_SCRIPT"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm is not read-write for $(id -un) — the guest needs KVM"

# ---------------------------------------------------------------------------------------------
# Payload identity. The manifest is whitespace-separated, so a payload name it cannot represent is
# refused here rather than discovered as a corrupt manifest line later.
PHASH=nopayload
if [ -n "$PAYLOAD" ]; then
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

mkdir -p "$FIXROOT" || die "cannot create $FIXROOT"
FIXROOT="$(cd "$FIXROOT" && pwd)"          # the printed path must be absolute
FIX="$FIXROOT/r$RECIPE-$PHASH"

# One builder at a time per cache (parallel sweep rows may --ensure together): the second waits, then
# finds DONE.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$FIXROOT/.lock" || die "cannot open $FIXROOT/.lock"
    flock -n 9 || { say "another zfs-fixture build holds $FIXROOT/.lock — waiting"; flock 9; }
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
# Work directory: everything for this build lives here until it has verified.
for stale in "$FIX".work.* "$FIX".old.*; do
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

# seed disk (NoCloud). FreeBSD's nuageinit (rc.d/nuageinit, 15.1) probes /dev/msdosfs/[cC][iI][dD][aA][tT][aA]
# and mounts it READ-WRITE — a read-only QEMU drive makes that mount fail and nuageinit silently does
# nothing. meta-data must be valid YAML; a user-data starting `#!` is run once at rc 'local' time.
cat > "$WORK/seed/meta-data" <<'EOF'
instance-id: agnos-zfs-fixture
local-hostname: zfsfix
EOF
cat > "$WORK/seed/user-data" <<'EOF'
#!/bin/sh
# AGNOS zfs-fixture user-data: hand off to zfs-fixture-guest.sh, then ALWAYS ship OUT back on the
# results disk and power off, so even a guest script that dies reports why.
OUT=/var/tmp/zfsfix-out
SEED=/var/tmp/zfsfix-seed
mkdir -p "$OUT" "$SEED"
echo "zfsfix: user-data started" > /dev/console
if mount_msdosfs -o ro /dev/msdosfs/CIDATA "$SEED"; then
    sh "$SEED/zfs-fixture-guest.sh" "$SEED" "$OUT" 2>&1 | tee "$OUT/guest.log" > /dev/console
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
cp "$GUEST_SCRIPT" "$WORK/seed/zfs-fixture-guest.sh" || die "copy guest script"
echo "$RECIPE $PHASH" > "$WORK/seed/recipe.conf"
SEED_MB=16
if [ -n "$PAYLOAD" ]; then
    # payload travels as a tar on the seed: VFAT would fold case, mangle names and drop modes
    tar --format=pax --sort=name --owner=0 --group=0 --numeric-owner -cf "$WORK/seed/payload.tar" \
        -C "$PAYLOAD" . || die "cannot tar the payload"
    SEED_MB=$(( $(stat -c %s "$WORK/seed/payload.tar") / 1048576 * 11 / 10 + 16 ))
fi
truncate -s $((SEED_MB * 1048576)) "$WORK/seed.img" || die "truncate seed.img"
mkfs.vfat -n CIDATA "$WORK/seed.img" >/dev/null || die "mkfs.vfat seed.img"
( cd "$WORK/seed" && mcopy -i "$WORK/seed.img" * ::/ ) || die "mcopy onto seed.img"

qemu-img create -q -f qcow2 -b "$QCOW" -F qcow2 "$WORK/overlay.qcow2" || die "cannot create the overlay"

# ---------------------------------------------------------------------------------------------
say "booting FreeBSD 15.1 (KVM, 4 vCPU, 4 GiB; timeout ${GUEST_TIMEOUT}s; serial log $WORK/log/serial.log)"
SERIAL="$WORK/log/serial.log"
: > "$SERIAL"
qemu-system-x86_64 -name agnos-zfs-fixture \
    -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
    -display none -monitor none -serial "file:$SERIAL" -nic none -no-reboot \
    -drive "if=none,id=sys,file=$WORK/overlay.qcow2,format=qcow2" \
    -device "virtio-blk-pci,drive=sys,bootindex=0,serial=AGNSYS" \
    -drive "if=none,id=seed,file=$WORK/seed.img,format=raw" \
    -device "virtio-blk-pci,drive=seed,serial=AGNSEED" \
    -drive "if=none,id=res,file=$WORK/results.img,format=raw" \
    -device "virtio-blk-pci,drive=res,serial=AGNRESULT" \
    "${DRIVES[@]}" \
    > "$WORK/log/qemu.log" 2>&1 &
QPID=$!
# an interrupted or failed run must not leave the VM behind holding the work dir's images
trap 'kill "$QPID" 2>/dev/null' EXIT

serial_tail() {
    say "---- last 60 lines of the guest serial log ($SERIAL) ----"
    tr -d '\r' < "$SERIAL" | tail -60 >&2
    say "---- end serial log ----"
}

# relay the guest's `zfsfix:` progress lines while waiting; enforce the deadline ourselves
seen=0
deadline=$(( $(date +%s) + GUEST_TIMEOUT ))
while kill -0 "$QPID" 2>/dev/null; do
    sleep 2
    lines=$(wc -l < "$SERIAL")
    if [ "$lines" -gt "$seen" ]; then
        tail -n +$((seen + 1)) "$SERIAL" | head -n $((lines - seen)) | tr -d '\r' \
            | grep '^zfsfix: ' | sed 's/^zfsfix: /  guest: /' >&2
        seen=$lines
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        kill "$QPID" 2>/dev/null; sleep 2; kill -9 "$QPID" 2>/dev/null
        serial_tail
        die "guest did not power off within ${GUEST_TIMEOUT}s (work dir kept: $WORK)"
    fi
done
wait "$QPID"
QRC=$?
tail -n +$((seen + 1)) "$SERIAL" | tr -d '\r' | grep '^zfsfix: ' | sed 's/^zfsfix: /  guest: /' >&2
if [ "$QRC" -ne 0 ]; then
    cat "$WORK/log/qemu.log" >&2
    serial_tail
    die "QEMU exited with status $QRC (work dir kept: $WORK)"
fi

# ---------------------------------------------------------------------------------------------
# Results. The tar comes from a guest, so its member names are checked before anything is extracted:
# the guest's OUT dir is flat by construction, anything else is refused.
tar -tf "$WORK/results.img" > "$WORK/log/results.list" 2>/dev/null \
    || { serial_tail; die "results disk holds no readable tar — the guest never shipped results (work dir: $WORK)"; }
bad=$(grep -v -E '^\./([A-Za-z0-9._@+-]+)?$' "$WORK/log/results.list" | head -3)
[ -z "$bad" ] || die "results tar has unexpected member names: $bad"
tar -xf "$WORK/results.img" -C "$WORK/out" --no-same-owner --no-same-permissions \
    || die "cannot extract the results tar"
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
    for ext in manifest summary xattrs objects; do
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
mv "$WORK"/out/*.manifest "$WORK"/out/*.summary "$WORK"/out/*.xattrs "$WORK"/out/*.objects "$WORK/" \
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
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) in $(( $(date +%s) - T0 ))s"
} > "$WORK/RECIPE"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/DONE"

OLD=""
if [ -e "$FIX" ]; then OLD="$FIX.old.$$"; mv "$FIX" "$OLD" || die "cannot move the old fixture aside"; fi
mv "$WORK" "$FIX" || die "cannot rename $WORK to $FIX"
[ -n "$OLD" ] && rm -rf "$OLD"
say "fixture built in $(( $(date +%s) - T0 ))s: $FIX"
echo "$FIX"
