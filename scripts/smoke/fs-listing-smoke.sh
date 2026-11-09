#!/bin/bash
# fs-listing-smoke — agnos 1.57.18 (track T3): readlink#70 truncates like Linux, readdir#81 / readdir_at#101 mark a
# cut name, and lseek#58 repositions a directory fd — on ext2 AND on the ZFS mount, at -smp 1 and -smp 4.
#
# Issues: 2026-11-06-readlink-refuses-a-buffer-shorter-than-the-target (thoth 0.55.1: cyrius's is_symlink, an 8-byte
#         readlink probe, read every link with a longer target as "not a link") and
#         2026-11-08-readdir-cuts-a-long-name-and-says-nothing (crab 0.11.3: a 70-byte name listed as its 62-byte
#         sibling, and Delete removed the sibling; a tree walk could not resume getdents#29 without one fd per level).
# Design: kernel/core/ext2.cyr ext2_readlink_core / rd_rec_put / ext2_dir_snap, kernel/core/zfs.cyr
#         zfs_readlink_core / zfs_dir_next, the lseek#58 arm in kernel/core/syscall.cyr; ABI § the #58 / #70 / #81 /
#         #101 rows and § 3.6 (docs/development/agnos-userland-abi.md).
#
# ONE image: the ESP · an ext2 root built HERE (tests/readdir rdlong seeded as /bin/agnsh, the /ln names, the /tw tree,
# /etc/hostname, the symlinks /fl (fast), /sl (slow, 100 bytes) and two CRAFTED with debugfs — /el4k: i_size exactly
# its 4096-byte block, legal; /evil: i_size 5000, over its one block and over the kernel follower's 4096-byte buffer,
# the block holding "/etc/hostname" + slashes, which a TRUNCATING follower would resolve to /etc/hostname) · the
# OpenZFS fixture's main pool (scripts/tool/zfs-fixture.sh, the payload zfs-smoke and zfs-ring3-smoke use, so all three
# share one cached fixture) as a third partition, mounted at /mnt/zfs. The PLAIN kernel boots it; kybernet runs rdlong
# as /bin/agnsh (ring3-seed.sh); the RDL-* markers below are the verdict (header of tests/readdir/rdlong.cyr).
#
# Env: FSL_SMP (default "1 4"); FSL_KERNEL=<plain kernel> uses a prebuilt one and skips the build (the falsification
#      hook); QEMU_TRIES; QEMU_TIMEOUT (default 600); SMOKE_KVM (0 = TCG for every boot).
# Exit 0 = every check of every boot PASSED; 1 = any FAIL; 2 = a boot never booted (firmware VOID) or no fixture, and
# nothing failed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== fs-listing smoke (readlink#70 truncation, the readdir#81/#101 cut bit, lseek#58 on a directory fd; ext2 + ZFS) ==="
ring3_seed_init || exit 1
for t in debugfs python3 cyrius truncate; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/fslist-smoke"; LOGS="$ROOT/build/fslist-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# ── the kernel ──
if [ -n "${FSL_KERNEL:-}" ]; then
    KERNEL="$FSL_KERNEL"
    echo "  using the PREBUILT kernel $KERNEL (the falsification hook)"
else
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    smoke_require_image "$ROOT/build/agnos" ""
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi

# ── the probe (⛔ rebuilt every run: the stale-artifact lesson) ──
( cd "$ROOT/tests/readdir" && rm -f build/rdlong && cyrius build --agnos rdlong.cyr build/rdlong ) > "$LOGS/rdlong-build.log" 2>&1 \
    || { echo "  ERROR: rdlong build failed (see $LOGS/rdlong-build.log)"; exit 1; }

# ── the ZFS fixture: zfs-smoke's / zfs-ring3-smoke's payload, so the three gates share ONE cached fixture ──
( cd "$ROOT/tests/zfs" && rm -f build/zfsx && cyrius build --agnos zfsx.cyr build/zfsx ) > "$LOGS/payload-build.log" 2>&1 \
    || { echo "  ERROR: tests/zfs did not build (see $LOGS/payload-build.log)"; exit 1; }
mkdir -p "$WORK/payload" && cp "$ROOT/tests/zfs/build/zfsx" "$WORK/payload/zfsx"
# ⚠ A fixture already built (its DONE stamp) is used directly: --ensure takes the cache lock even for a hit, so it
# waits out ANY other fixture build on the box — a parallel tree building a different payload's fixture held this
# gate ~8 min for a fixture it never needed. This gate only reads main.img (it boots a copy); a missing fixture is
# still built through --ensure, under the lock.
FIXKEY=$(bash "$ROOT/scripts/tool/zfs-fixture.sh" --fixture-key --payload "$WORK/payload" 2>/dev/null | tail -1)
FIXDIR="${ZFS_FIXTURE_DIR:-$HOME/.cache/agnos/zfs-fixtures}/$FIXKEY"
if [ -n "$FIXKEY" ] && [ -f "$FIXDIR/DONE" ]; then
    FIX="$FIXDIR"
else
    FIX=$(bash "$ROOT/scripts/tool/zfs-fixture.sh" --ensure --payload "$WORK/payload" 2>"$LOGS/fixture.log" | tail -1)
fi
if [ -z "$FIX" ] || [ ! -f "$FIX/DONE" ] || [ ! -f "$FIX/main.img" ]; then
    echo "  VOID: no OpenZFS fixture (scripts/tool/zfs-fixture.sh — $LOGS/fixture.log)"; exit 2
fi
POOL="$FIX/main.img"
echo "  fixture: $FIX"

# ── the ext2 seed ──
SEED="$WORK/seed"
mkdir -p "$SEED/bin" "$SEED/etc"
cp "$ROOT/tests/readdir/build/rdlong" "$SEED/bin/agnsh"; chmod +x "$SEED/bin/agnsh"
printf 'archaemenid\n' > "$SEED/etc/hostname"
python3 -I - "$SEED" <<'PYSEED' || { echo "  ERROR: seed generation failed"; exit 1; }
import os, sys
seed = os.fsencode(sys.argv[1])
def put(rel, body=b""):
    with open(os.path.join(seed, rel), "wb") as f:
        f.write(body)
# /ln — the issue's five rows, four UTF-8 cuts, a cut directory and a short one (tests/readdir/rdlong.cyr ln_name)
ln = os.path.join(seed, b"ln")
os.makedirs(ln)
rows = [
    (b"a" * 70, b"LONG-70"), (b"a" * 62, b"SIBLING-62"), (b"b" * 62 + b"-one", b"B-ONE"), (b"b" * 62 + b"-two", b"B-TWO"),
    (b"short.txt", b"SHORT"),
    (b"c" * 61 + "é".encode() + b"x" * 5, b"U2"),          # é at 61-62: the cut backs off to 61
    (b"d" * 60 + "€".encode() + b"zz", b"U3"),             # € at 60-62: to 60
    (b"e" * 59 + "😀".encode() + b"q", b"U4"),             # a 4-byte character at 59-62: to 59
    (b"f" * 60 + "é".encode() + b"y" * 4, b"U1"),          # é at 60-61: the cut at 62 is a boundary already
]
for n, body in rows:
    put(os.path.join(b"ln", n), body)
os.makedirs(os.path.join(ln, b"g" * 70))
os.makedirs(os.path.join(ln, b"sub"))
# /tw — the tree the resumed walk must visit exactly as the one-fd-per-level walk does
tw = os.path.join(seed, b"tw")
os.makedirs(os.path.join(tw, b"many"))
for i in range(300):
    put(os.path.join(b"tw", b"many", b"m%03d-" % i + b"x" * (i % 37)))
os.makedirs(os.path.join(tw, b"a"))
for i in range(40):
    put(os.path.join(b"tw", b"a", b"a%02d" % i))
put(os.path.join(b"tw", b"a", b"L" * 200), b"L")
os.makedirs(os.path.join(tw, b"b", b"c", b"d"))
os.makedirs(os.path.join(tw, b"b", b"c", b"e"))
for i in range(30):
    put(os.path.join(b"tw", b"b", b"b%02d-" % i + b"y" * (i * 7)))
for i in range(60):
    put(os.path.join(b"tw", b"b", b"c", ("ü%02d-ß" % i).encode() + b"z" * (i % 50)))
for i in range(5):
    put(os.path.join(b"tw", b"b", b"c", b"e", b"e%d" % i))
os.symlink(b"a", os.path.join(tw, b"link"))
# the symlinks: fast (13 bytes), slow (100), and two slow placeholders the smoke crafts with debugfs
os.symlink(b"/etc/hostname", os.path.join(seed, b"fl"))
os.symlink(b"/etc" + b"/" * 88 + b"hostname", os.path.join(seed, b"sl"))
os.symlink(b"/etc/hostname" + b"/" * 82, os.path.join(seed, b"evil"))
os.symlink(b"/etc/hostname" + b"/" * 82, os.path.join(seed, b"el4k"))
# the 4096-byte block both crafted links get: "/etc/hostname" + 4083 slashes — no NUL, so a truncating follower
# resolves it to /etc/hostname
with open(os.path.join(seed, b"..", b"evil.blk"), "wb") as f:
    f.write(b"/etc/hostname" + b"/" * 4083)
PYSEED
TW_N="$(find "$SEED/tw" -mindepth 1 | wc -l)"
echo "  seed: /ln 11 names, /tw $TW_N entries, /fl /sl /evil /el4k"

# ── the ext2 partition, built as a file and crafted ──
PART="$WORK/ext2.part"
PART_BYTES=$(( 67 * 1048576 ))
truncate -s "$PART_BYTES" "$PART"
mkfs.ext2 -F -q -L AGNOS-FSL -b 4096 -m 0 \
    -O "${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}" \
    -d "$SEED" "$PART" > "$LOGS/mkfs.log" 2>&1 || { echo "  ERROR: mkfs.ext2 failed (see $LOGS/mkfs.log)"; exit 1; }
craft() {   # craft <link> <i_size>: the 4096-byte block written over the link's one block, then i_size set
    _blk="$(debugfs -R "blocks /$1" "$PART" 2>/dev/null | tr -d ' \n')"
    case "$_blk" in ''|*[!0-9]*) echo "  ERROR: /$1 is not a one-block slow symlink (blocks: '$_blk')"; return 1 ;; esac
    dd if="$WORK/evil.blk" of="$PART" bs=4096 seek="$_blk" conv=notrunc status=none || return 1
    debugfs -w -R "sif /$1 size $2" "$PART" > "$LOGS/craft-$1.log" 2>&1 || return 1
    _sz="$(debugfs -R "stat /$1" "$PART" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | awk '{print $2}')"
    [ "$_sz" = "$2" ] || { echo "  ERROR: /$1 i_size is '$_sz' after the craft, want $2"; return 1; }
    echo "  crafted /$1: block $_blk, i_size $2"
    return 0
}
craft evil 5000 || exit 1
craft el4k 4096 || exit 1

# ── the disk: ESP 1-33 MiB · ext2 33-100 MiB · the pool from 100 MiB, exactly its size ──
IMG="$WORK/fsl.img"
PSEC=$(( $(stat -c %s "$POOL") / 512 ))
Z_START=$(( 100 * 2048 ))
truncate -s $(( (Z_START + PSEC + 2048) * 512 )) "$IMG"
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB mkpart zfs "${Z_START}s" "$(( Z_START + PSEC - 1 ))s" || { echo "  ERROR: parted"; exit 1; }
sgdisk -t 2:8300 -t 3:a504 "$IMG" >/dev/null || { echo "  ERROR: sgdisk"; exit 1; }
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$R3_GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$KERNEL" ::boot/agnos
dd if="$PART" of="$IMG" bs=1M seek=33 conv=notrunc status=none
dd if="$POOL" of="$IMG" bs=512 seek="$Z_START" conv=notrunc status=none

for smp in ${FSL_SMP:-1 4}; do
    LOG="$LOGS/fsl-smp$smp.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$smp")"; export R3_ACCEL
    R3_MEM=2048M; export R3_MEM
    P="[smp$smp]"
    echo ""
    echo "Boot $P: -smp $smp  accel: $R3_ACCEL"
    cp "$IMG" "$WORK/fsl-$smp.img"
    ring3_seed_boot "$WORK/fsl-$smp.img" "$LOG" "RDL-DONE" "${QEMU_TIMEOUT:-600}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "RDL-|kybernet: (exec|emergency)|zfs: .*refused" | sed 's/^/    /'
    want "kybernet: exec /bin/agnsh"           "$P kybernet launched rdlong"
    want "zfs: pool agnostank txg [0-9]+ "     "$P the fixture's pool mounted"
    want "zfs: agnostank rw"                   "$P ... read-write (the /ln names are created on it)"
    # L — readdir#81 / readdir_at#101 records (ext2)
    want "RDL-L81-EXT2-OK"                     "$P L  #81 on ext2: the five rows + four UTF-8 cuts + two dirs, kept bytes / NUL / RD_DIR|RD_CUT exact (clear on the exact-62 sibling)"
    want "RDL-L101-EXT2-OK"                    "$P L  #101 on ext2 (3 a call): the same eleven records"
    want "RDL-L29-EXT2-OK"                     "$P L  getdents#29 on ext2: every name whole"
    # R — readlink#70 truncates
    want "RDL-RL-EXT2-FAST-OK"                 "$P R  ext2 fast link: cap 1 / 8 / 12 -> that many bytes, 13 / 64 -> 13, nothing past the count written"
    want "RDL-RL-EXT2-SLOW-OK"                 "$P R  ext2 slow link (100 B): cap 8 / 99 -> that many, 100 / 4096 -> 100"
    want "RDL-RL-EXT2-4K-OK"                   "$P R  ext2 slow link of exactly one block (4096 B): cap 8 -> 8, 8192 -> 4096"
    want "RDL-RL-REFUSALS-OK"                  "$P R  cap 0 -> -1; a file -> -1"
    want "RDL-ISLINK-PROBE-OK"                 "$P R  cyrius is_symlink's 8-byte probe succeeds on a 100-byte and a 13-byte target"
    # F — the kernel follower
    want "RDL-FOLLOW-REFUSED-OK"               "$P F  /evil (i_size 5000 > the follower's 4096-byte buffer, its block a path to /etc/hostname) is NOT followed by open#7 / stat#33"
    want "RDL-EVIL-READLINK-REFUSED-OK"        "$P F  readlink#70 refuses /evil at cap 8192 and 8 (a slow target is bounded by its one block)"
    want "RDL-FOLLOW-LEGAL-OK"                 "$P F  /el4k (4096 B), /sl (100 B) and /fl (13 B) are followed to /etc/hostname"
    # G — getdents#29 never answers 'end' for a short buffer
    want "RDL-G-EXT2-OK"                       "$P G  ext2 getdents with a 16-byte buffer: -1 at the first longer record, position unchanged"
    # S — lseek#58 on an ext2 directory fd
    want "RDL-S-EXT2-RESUME-OK"                "$P S  /tw/many (302 records, 3 blocks) in 300-byte batches, fd closed + reopened + lseek(cookie) each time == one pass"
    want "RDL-S-EXT2-SNAP-OK"                  "$P S  a cookie + 1..12 resumes at the NEXT record (ext2_validate_entry), + 0 at the record"
    want "RDL-S-EXT2-REFUSE-OK"                "$P S  negative SEEK_SET / SEEK_CUR and SEEK_END refused, position kept; past the end lists nothing"
    want "RDL-S-EXT2-RA-SNAP-OK"               "$P S  readdir_at#101: cursor + 4 snaps to the next record; + 1 is still -5"
    want "RDL-S-EXT2-TREE-OK"                  "$P S  /tw walked with no fd held across a descent == the one-fd-per-level walk"
    want "RDL-TW-EXT2 n=$TW_N nres=$TW_N same=1 err=0" "$P S  ... and both visited every one of the seed's $TW_N entries"
    # Z — the ZFS mount
    want "RDL-Z-CREATE-OK"                     "$P Z  the eleven /ln names created on agnostank/custom (writer)"
    want "RDL-L81-ZFS-OK"                      "$P Z  #81 on ZFS: the same eleven records"
    want "RDL-L101-ZFS-OK"                     "$P Z  #101 on ZFS (3 a call): the same eleven records"
    want "RDL-L29-ZFS-OK"                      "$P Z  getdents#29 on ZFS: every name whole"
    want "RDL-G-ZFS-OK"                        "$P Z  ZFS getdents with a 16-byte buffer: -1, position unchanged"
    want "RDL-Z81-ROOT-OK"                     "$P Z  #81 of /mnt/zfs/agnostank: its 255-byte name the one RD_CUT record, 'long-' + 57 x"
    want "RDL-RL-ZFS-OK"                       "$P Z  readlink#70 on ZFS: sym-short cap 4 / 9 / 64, sym-long (400 B) cap 8 / 399 / 400 / 2048"
    want "RDL-ISLINK-ZFS-OK"                   "$P Z  the is_symlink probe shape on ZFS (8 of 400 bytes); a ZFS file is -1"
    want "RDL-S-ZFS-RESUME-OK"                 "$P Z  dir3000 (fat ZAP, 3002 records) resumed across close/reopen in 300-byte batches == one pass"
    want "RDL-S-ZFS-HOSTILE-OK"                "$P Z  cookies -1 / SEEK_END refused; a fat-ZAP position, past the ZAP, past the extras, 1: only genuine names"
    want "RDL-S-ZFS-TREE-OK"                   "$P Z  /mnt/zfs/agnostank (micro + fat ZAPs, child datasets) walked with no fd held == one fd per level"
    want "RDL-DONE pass=28 fail=0"             "$P RDL-DONE pass=28 fail=0"
    deny "RDL-FAIL-"                           "$P no FAIL marker"
    deny "kybernet: emergency"                 "$P rdlong exited 0"
    deny "$SMOKE_INVARIANT_DENY"               "$P no latched invariant"
    rm -f "$WORK/fsl-$smp.img"
done

echo ""
echo "=== fs-listing-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
