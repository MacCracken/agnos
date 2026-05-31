#!/bin/bash
# ext2 WRITE-path smoke (1.33.x WRITE arc — W1 primitives .. W5 mkdir/rmdir).
#
# Boots the EXT2_WRITE_SELFTEST kernel against a deliberately write-
# friendly ext2 partition (no metadata_csum / 64bit / dir_index — the
# profile the 1.33.x write path targets per the prior-art doc § 8/§10),
# and gates on TWO things:
#
#   1. The self-test's identity write-back checks pass on the serial log:
#        ext2w: block id write-back OK
#        ext2w: inode id put OK
#      (read a metadata block + inode 2, write each back UNCHANGED, re-read,
#       byte-compare — exercises ext2_write_block + ext2_put_inode).
#   2. `e2fsck -fn` on the POST-BOOT image is clean (exit 0, no FIXED) —
#      proving the write primitives didn't corrupt the FS.
#
# Bonus: cross-checks the self-test's reported superblock free-block count
# against `debugfs -R stats` on the pristine image.
#
# Build the kernel first:  EXT2_WRITE_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2,
#           debugfs, e2fsck, dd, strings. gnoboot at ../gnoboot/build/.
#
# Exit 0 if the W1 gate passes; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/ext2-write-smoke"
LOGS="$ROOT/build/ext2-write-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-write.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 67 * 1048576 ))             # 67 MiB ext2 partition
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Feature profile is parameterized (1.33.1 metadata_csum + 64bit arc, audit
# § 14.6): the default is the 1.33.0 write-friendly stripped set; override
# EXT2_SMOKE_FEATURES to gate a bite against a checksummed/64bit image, e.g.
#   64bit-only:   EXT2_SMOKE_FEATURES="^resize_inode,^dir_index,^metadata_csum,64bit,extent,^uninit_bg"
#   csum+64bit:   EXT2_SMOKE_FEATURES="^resize_inode,^dir_index,metadata_csum,64bit,extent,^uninit_bg"
# NOTE: `64bit` REQUIRES `extent` — mkfs errors out ("Extents MUST be enabled
# for a 64-bit filesystem") if you enable 64bit without it. The real-partition
# profile is `metadata_csum,64bit,extent` (matches default `mkfs.ext4`).
# The self-test-line + e2fsck gates below are feature-agnostic, so the same
# script proves every bite — only the image profile changes.
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
echo "Building ext2 image (mkfs -O $EXT2_SMOKE_FEATURES)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "agnos write arc W1 seed" > "$SEED/hello.txt"
mkdir -p "$SEED/etc"; echo "archaemenid" > "$SEED/etc/hostname"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null         # Linux-FS GUID 0FC63DAF-…
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-WTEST -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

# --- pristine baseline (debugfs stats on the partition slice) ---
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-pre.img" status=none
BASE_FREE=$(debugfs -R stats "$WORK/part-pre.img" 2>/dev/null | grep -m1 "Free blocks:" | grep -oE "[0-9]+")
echo "  host debugfs baseline: Free blocks = ${BASE_FREE:-?}"

# --- boot the self-test kernel ---
echo "Booting EXT2_WRITE_SELFTEST kernel (NVMe + GPT partition)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/write-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-WTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- ext2w self-test lines from boot log ---"
strings "$LOG" | grep -E "^ext2w:" | sed 's/^/  /'
echo ""

# Wrong-build guard. The ext2 write self-test only exists in a kernel built
# with EXT2_WRITE_SELFTEST=1; a production / other-selftest build boots fine
# but emits ZERO `ext2w:` lines, so the gates below cascade red as if the ext2
# backend were broken (the exFAT analogue was misfiled as the mkfs-1.3.2-drift
# issue). Distinguish "kernel booted but selftest absent" from a real result.
if ! strings "$LOG" | grep -q "^ext2w:"; then
    echo "  ERROR: kernel booted but produced NO 'ext2w:' lines — this build does"
    echo "         NOT contain the ext2 write self-test. Rebuild with the flag:"
    echo "             EXT2_WRITE_SELFTEST=1 ./scripts/build.sh"
    echo "         (a leftover production / other-selftest build/agnos is the usual cause). Log: $LOG"
    exit 2
fi

rc=0

# Bite 2 (1.33.1): crc32c Castagnoli primitive — known iSCSI vector.
if strings "$LOG" | grep -q "ext2w: crc32c selftest OK"; then
    echo "  PASS: crc32c primitive (Castagnoli iSCSI vector 0x1CF96D7C)"
else
    echo "  FAIL: crc32c primitive self-test"; rc=1
fi

# Bite 2: when metadata_csum is on, cross-check the kernel's UUID-derived
# csum seed against the host (crc32c(~0, uuid[16], 16)). On non-csum images
# this is skipped (csum on=0). kprint_hex emits lowercase, no 0x, no pad.
if strings "$LOG" | grep -q "ext2w: csum on=1"; then
    K_SEED=$(strings "$LOG" | sed -nE 's/.*csum on=1 seed=([0-9a-f]+).*/\1/p' | head -1)
    UUID=$(dumpe2fs -h "$WORK/part-pre.img" 2>/dev/null | sed -nE 's/.*Filesystem UUID:[[:space:]]+([0-9a-f-]+).*/\1/p')
    H_SEED=$(python3 - "$UUID" <<'PY'
import sys
u = bytes.fromhex(sys.argv[1].replace('-', ''))
c = 0xffffffff
for x in u:
    c ^= x
    for _ in range(8):
        c = ((c >> 1) ^ 0x82f63b78) if (c & 1) else (c >> 1)
        c &= 0xffffffff
print('%x' % c)
PY
)
    if [ -n "$K_SEED" ] && [ "$K_SEED" = "$H_SEED" ]; then
        echo "  PASS: csum seed matches host UUID-derived (0x$K_SEED)"
    else
        echo "  FAIL: csum seed kernel=0x$K_SEED host=0x$H_SEED"; rc=1
    fi

    # Bite 3: SB + group-desc checksum routines reproduce the on-disk
    # (e2fsprogs-written) values — compute-and-compare, no write needed.
    if strings "$LOG" | grep -q "ext2w: SB csum match"; then
        echo "  PASS: superblock s_checksum matches disk (ext2_sb_csum_compute)"
    else
        echo "  FAIL: superblock s_checksum mismatch"; strings "$LOG" | grep "SB csum" | sed 's/^/        /'; rc=1
    fi
    if strings "$LOG" | grep -q "ext2w: grp0 csum match"; then
        echo "  PASS: group-0 bg_checksum matches disk (ext2_grp_csum_compute)"
    else
        echo "  FAIL: group-0 bg_checksum mismatch"; strings "$LOG" | grep "grp0 csum" | sed 's/^/        /'; rc=1
    fi

    # Bite 4: block + inode bitmap checksums reproduce on-disk values.
    if strings "$LOG" | grep -q "ext2w: blk-bitmap csum match"; then
        echo "  PASS: block-bitmap csum matches disk (ext2_set_block_bitmap_csum)"
    else
        echo "  FAIL: block-bitmap csum mismatch"; rc=1
    fi
    if strings "$LOG" | grep -q "ext2w: ino-bitmap csum match"; then
        echo "  PASS: inode-bitmap csum matches disk (span=inodes_per_group/8)"
    else
        echo "  FAIL: inode-bitmap csum mismatch"; rc=1
    fi

    # Bite 5: inode checksum reproduces the on-disk value (root inode 2).
    if strings "$LOG" | grep -q "ext2w: inode2 csum match"; then
        echo "  PASS: inode csum matches disk (ext2_inode_csum_calc, root inode)"
    else
        echo "  FAIL: inode csum mismatch"; strings "$LOG" | grep "inode2 csum" | sed 's/^/        /'; rc=1
    fi

    # Bite 6: directory-leaf checksum reproduces the on-disk det_checksum.
    if strings "$LOG" | grep -q "ext2w: rootdir csum match"; then
        echo "  PASS: dir-leaf csum matches disk (ext2_dir_leaf_csum, root block)"
    else
        echo "  FAIL: dir-leaf csum mismatch"; strings "$LOG" | grep "rootdir csum" | sed 's/^/        /'; rc=1
    fi
fi

# Gate 1: identity write-back checks passed.
if strings "$LOG" | grep -q "ext2w: block id write-back OK"; then
    echo "  PASS: block identity write-back (ext2_write_block)"
else
    echo "  FAIL: block identity write-back"; rc=1
fi
if strings "$LOG" | grep -q "ext2w: inode id put OK"; then
    echo "  PASS: inode identity put (ext2_put_inode)"
else
    echo "  FAIL: inode identity put"; rc=1
fi

# W2: block + inode allocator round-trip (alloc 3 blocks + 1 inode, free
# them, free-counts must return to baseline). Absent on a read-only FS.
if strings "$LOG" | grep -q "ext2w: W2 alloc/free round-trip OK"; then
    echo "  PASS: W2 allocator round-trip (alloc/free block+inode)"
elif strings "$LOG" | grep -q "ext2w: read-only FS"; then
    echo "  SKIP: W2 allocator round-trip (FS mounted read-only for write)"
else
    echo "  FAIL: W2 allocator round-trip"; rc=1
fi

# W3: file-data write (ext2_write_at) + sparse-block alloc + truncate.
for w3 in "W3 write/read 200" "W3 sparse-alloc write" "W3 truncate-to-zero"; do
    if strings "$LOG" | grep -q "ext2w: $w3 OK"; then
        echo "  PASS: $w3"
    else
        echo "  FAIL: $w3"; rc=1
    fi
done

# W4a: dirent insert/remove + create/unlink.
for w4 in "W4 create+write" "W4 unlink round-trip"; do
    if strings "$LOG" | grep -q "ext2w: $w4 OK"; then
        echo "  PASS: $w4"
    else
        echo "  FAIL: $w4"; rc=1
    fi
done

# W5: mkdir + rmdir (FS layer).
for w5 in "W5 mkdir" "W5 rmdir round-trip"; do
    if strings "$LOG" | grep -q "ext2w: $w5 OK"; then
        echo "  PASS: $w5"
    else
        echo "  FAIL: $w5"; rc=1
    fi
done

# Wrename: rename / mv (1.33.3 bite 1) — file rename, cross-parent dir
# move (".." repoint + parent link-count shift), and dst-exists refusal.
for wr in "Wren file" "Wren xdir" "Wren refuse"; do
    if strings "$LOG" | grep -q "ext2w: $wr OK"; then
        echo "  PASS: $wr"
    else
        echo "  FAIL: $wr"; rc=1
    fi
done

# Whardlink: ln (1.33.3 bite 2) — second dirent + i_links_count++; unlink
# one link leaves the other; dir-hardlink refused.
for wh in "Whard link" "Whard refuse-dir"; do
    if strings "$LOG" | grep -q "ext2w: $wh OK"; then
        echo "  PASS: $wh"
    else
        echo "  FAIL: $wh"; rc=1
    fi
done

# Wsymlink: ln -s (1.33.3 bite 3) — fast (inline target, 0 blocks) + slow
# (target in a data block) symlink creation.
for ws in "Wsym fast" "Wsym slow"; do
    if strings "$LOG" | grep -q "ext2w: $ws OK"; then
        echo "  PASS: $ws"
    else
        echo "  FAIL: $ws"; rc=1
    fi
done

# Wsymres: symlink RESOLUTION (1.33.4 bite 2) — ext2_path_lookup follows a
# fast symlink to its target inode, a relative symlink, and bails on ELOOP.
if strings "$LOG" | grep -q "ext2w: Wsymres resolve OK"; then
    echo "  PASS: Wsymres (resolve fast/relative symlink + ELOOP cap)"
else
    echo "  FAIL: Wsymres symlink resolution"; rc=1
fi

# Wsync: s_state dirty/clean + sync (1.33.3 bite 4) — first write cleared
# EXT2_VALID_FS (dirty), sync set it back (clean).
if strings "$LOG" | grep -q "ext2w: Wsync state OK"; then
    echo "  PASS: Wsync state (dirty-on-write → clean-on-sync)"
else
    echo "  FAIL: Wsync state"; rc=1
fi

# W4b: shell write verbs driven headlessly via sh_exec. The proof is the
# `cat` of the echo-redirected file printing "SHELL-WROTE-IT" back.
if strings "$LOG" | grep -q "SHELL-WROTE-IT"; then
    echo "  PASS: W4b shell echo-redirect + cat (vfs_write arm + mkdir/touch/rm)"
else
    echo "  FAIL: W4b shell write verbs (no SHELL-WROTE-IT in cat output)"; rc=1
fi

# Bonus: free-block count cross-check (self-test sb total vs host debugfs).
ST_FREE=$(strings "$LOG" | sed -nE 's/.*sb free_blk=([0-9]+).*/\1/p' | head -1)
if [ -n "$ST_FREE" ] && [ -n "${BASE_FREE:-}" ] && [ "$ST_FREE" = "$BASE_FREE" ]; then
    echo "  PASS: free-block count matches host ($ST_FREE)"
else
    echo "  WARN: free-block count self-test=$ST_FREE host=${BASE_FREE:-?} (compare manually)"
fi

# Gate 2: post-boot e2fsck clean (the identity writes must not corrupt).
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
echo ""
echo "  --- e2fsck -fn on POST-BOOT partition ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (exit 0)"
else
    echo "  FAIL: e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

# W3 host verification — the writes/truncate reached the platter (debugfs
# reads files without mounting). /etc/hostname grew to 8292 (12 + hole +
# 100 @ 8192); /hello.txt truncated to 0.
echo ""
echo "  --- host debugfs W3 verification ---"
ehsize=$(debugfs -R "stat /w3b.txt" "$WORK/part-post.img" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | grep -oE "[0-9]+")
[ "$ehsize" = "8292" ] && echo "  PASS: /w3b.txt size=8292 on disk (write_at + sparse alloc)" || { echo "  FAIL: /w3b.txt size=${ehsize:-?} (want 8292)"; rc=1; }
hhsize=$(debugfs -R "stat /w3a.txt" "$WORK/part-post.img" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | grep -oE "[0-9]+")
[ "$hhsize" = "0" ] && echo "  PASS: /w3a.txt size=0 on disk (truncate)" || { echo "  FAIL: /w3a.txt size=${hhsize:-?} (want 0)"; rc=1; }

# W4 host verification: /w4keep.txt persisted with content (create+write+
# dirent-insert reached disk); /w4tmp.txt absent (unlink reached disk).
w4content=$(debugfs -R "cat /w4keep.txt" "$WORK/part-post.img" 2>/dev/null)
[ "$w4content" = "AGNOS-W4-WROTE" ] && echo "  PASS: /w4keep.txt content persisted on disk (\"$w4content\")" || { echo "  FAIL: /w4keep.txt content='$w4content' (want AGNOS-W4-WROTE)"; rc=1; }
if debugfs -R "stat /w4tmp.txt" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /w4tmp.txt still present on disk (unlink didn't persist)"; rc=1
else
    echo "  PASS: /w4tmp.txt absent on disk (unlink persisted)"
fi

# W5 host verification: /w5keep is a directory on disk; /w5tmp gone.
w5type=$(debugfs -R "stat /w5keep" "$WORK/part-post.img" 2>/dev/null | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}')
[ "$w5type" = "directory" ] && echo "  PASS: /w5keep is a directory on disk (mkdir persisted)" || { echo "  FAIL: /w5keep type='$w5type' (want directory)"; rc=1; }
if debugfs -R "stat /w5tmp" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /w5tmp still present on disk (rmdir didn't persist)"; rc=1
else
    echo "  PASS: /w5tmp absent on disk (rmdir persisted)"
fi

# W4b host verification: the shell-created dir + echo-redirected file
# persisted with the right content; the shell touch+rm tmp file is gone.
shcontent=$(debugfs -R "cat /shdir/keep.txt" "$WORK/part-post.img" 2>/dev/null)
[ "$shcontent" = "SHELL-WROTE-IT" ] && echo "  PASS: /shdir/keep.txt = shell-written content on disk" || { echo "  FAIL: /shdir/keep.txt='$shcontent' (want SHELL-WROTE-IT)"; rc=1; }

# Wrename host verification: file rename + cross-parent dir move reached
# the platter (link counts already validated by e2fsck -fn above).
if debugfs -R "stat /rndst.txt" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  PASS: /rndst.txt present on disk (file rename persisted)"
else
    echo "  FAIL: /rndst.txt absent (file rename didn't persist)"; rc=1
fi
if debugfs -R "stat /rnsrc.txt" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /rnsrc.txt still present (old name not removed)"; rc=1
else
    echo "  PASS: /rnsrc.txt absent on disk (old name removed)"
fi
rnptype=$(debugfs -R "stat /rnp/rnd" "$WORK/part-post.img" 2>/dev/null | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}')
[ "$rnptype" = "directory" ] && echo "  PASS: /rnp/rnd is a directory on disk (cross-parent dir move persisted)" || { echo "  FAIL: /rnp/rnd type='$rnptype' (want directory)"; rc=1; }
if debugfs -R "stat /rnd" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /rnd still present in root (dir move didn't remove old entry)"; rc=1
else
    echo "  PASS: /rnd absent from root (dir move removed old entry)"
fi

# Whardlink host verification: /hl_b.txt survives the unlink of /hl_a.txt
# with content intact (link count handled); /hl_a.txt gone; no /hl_d2.
hlb=$(debugfs -R "cat /hl_b.txt" "$WORK/part-post.img" 2>/dev/null)
[ "$hlb" = "HL" ] && echo "  PASS: /hl_b.txt = \"HL\" on disk (hardlink survived unlink of other name)" || { echo "  FAIL: /hl_b.txt='$hlb' (want HL)"; rc=1; }
if debugfs -R "stat /hl_a.txt" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /hl_a.txt still present (unlinked hardlink name persisted)"; rc=1
else
    echo "  PASS: /hl_a.txt absent on disk (unlinked hardlink name removed)"
fi
if debugfs -R "stat /hl_d2" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /hl_d2 present (dir hardlink was not refused)"; rc=1
else
    echo "  PASS: /hl_d2 absent on disk (dir hardlink refused)"
fi

# Wsymlink host verification: /sl_f + /sl_s are symlinks; the fast one's
# inline target is /hl_b.txt (debugfs prints "Fast link dest").
slftype=$(debugfs -R "stat /sl_f" "$WORK/part-post.img" 2>/dev/null | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}')
[ "$slftype" = "symlink" ] && echo "  PASS: /sl_f is a symlink on disk (fast)" || { echo "  FAIL: /sl_f type='$slftype' (want symlink)"; rc=1; }
if debugfs -R "stat /sl_f" "$WORK/part-post.img" 2>/dev/null | grep -q "/hl_b.txt"; then
    echo "  PASS: /sl_f fast-link target = /hl_b.txt"
else
    echo "  FAIL: /sl_f fast-link target not /hl_b.txt"; rc=1
fi
slstype=$(debugfs -R "stat /sl_s" "$WORK/part-post.img" 2>/dev/null | grep -oE "Type: [a-z]+" | head -1 | awk '{print $2}')
[ "$slstype" = "symlink" ] && echo "  PASS: /sl_s is a symlink on disk (slow)" || { echo "  FAIL: /sl_s type='$slstype' (want symlink)"; rc=1; }

# Wsync host verification: `sync` left the on-disk superblock marked clean.
fsstate=$(debugfs -R "show_super_stats -h" "$WORK/part-post.img" 2>/dev/null | grep -i "Filesystem state:" | head -1)
if echo "$fsstate" | grep -q "clean"; then
    echo "  PASS: on-disk superblock state = clean (sync set EXT2_VALID_FS)"
else
    echo "  FAIL: superblock state not clean after sync ('$fsstate')"; rc=1
fi
if debugfs -R "stat /shtmp" "$WORK/part-post.img" 2>&1 | grep -q "Inode:"; then
    echo "  FAIL: /shtmp still present (shell rm didn't persist)"; rc=1
else
    echo "  PASS: /shtmp absent on disk (shell rm persisted)"
fi

echo ""
echo "=========================================="
[ $rc -eq 0 ] && echo "ext2 WRITE smoke (W1-W5): PASS" || echo "ext2 WRITE smoke (W1-W5): FAIL"
echo "Logs: $LOGS"
echo "=========================================="
exit $rc
