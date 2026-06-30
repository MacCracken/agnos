#!/bin/bash
# symlink-smoke — on-agnos symlink#63 round-trip (ark v2 / agnova item (a)).
#
# The DO-FIRST item of the 1.51.x sovereign-package-manager kernel surface is
# TWO-SIDED: the agnos kernel symlink#63 (ext2_symlink, 1.51.0) is a no-op to
# userland until the cyrius `sys_symlink` peer (lib/syscalls_x86_64_agnos.cyr,
# #63) exposes the number — that peer landed cyrius 6.3.6. This smoke is the
# on-agnos round-trip the item's done-criteria demands
# ([[feedback_qemu_test_agnos_userland]] — compiling != working):
#
#   1. A REAL `--agnos` program (tests/symlink/symtest.cyr) calls the cyrius
#      sys_symlink PEER to create /hn_link -> "/etc/hostname", then open()s the
#      symlink and reads it back — the kernel's ext2_path_lookup FOLLOWS the link
#      to /etc/hostname (seeded "archaemenid"). It prints SYMLINK-CREATE-OK and
#      SYMLINK-TRAVERSE-OK and exits 0.
#   2. Host-side, the symlink must land on the agnos-fs as a real symlink whose
#      target is "/etc/hostname", and the partition must survive `e2fsck -fn`.
#
# Build the kernel first:  SYMLINK_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2,
#           debugfs, e2fsck, dd, strings, cyrius. gnoboot at ../gnoboot/build/.
#
# Exit 0 if the create + traverse markers, the on-disk symlink target, and the
# e2fsck pass all hold; 1 otherwise.

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

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run SYMLINK_SELFTEST=1 ./scripts/build.sh"; exit 1; }

# --- build the cyrius --agnos exerciser (the cyrius sys_symlink peer consumer) ---
SYMTEST_DIR="$ROOT/tests/symlink"
echo "Building symtest exerciser (cyrius build --agnos)..."
( cd "$SYMTEST_DIR" && cyrius build --agnos symtest.cyr build/symtest ) \
    || { echo "ERROR: symtest (agnos) build failed"; exit 1; }
SYMTEST="$SYMTEST_DIR/build/symtest"
case "$(file -b "$SYMTEST" 2>/dev/null)" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $SYMTEST is not a static x86-64 ELF64"; exit 1 ;;
esac

WORK="$ROOT/build/symlink-smoke"
LOGS="$ROOT/build/symlink-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-symlink.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 67 * 1048576 ))             # 67 MiB ext2 partition
PART_BLOCKS=$(( PART_BYTES / 4096 ))

# Write-friendly ext2 (the 1.33.x write path's profile — no csum/64bit).
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

# Seed: /bin/symtest (the exerciser the kernel runs) + /etc/hostname (the symlink
# TARGET symtest points /hn_link at; symtest asserts its first 11 bytes).
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp "$SYMTEST" "$SEED/bin/symtest"; chmod +x "$SEED/bin/symtest"
printf 'archaemenid\n' > "$SEED/etc/hostname"

echo "Building symlink-smoke image (mkfs -O $EXT2_SMOKE_FEATURES)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-SYM -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting SYMLINK_SELFTEST kernel (NVMe + GPT ext2)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/symlink-selftest.log"
timeout "${QEMU_TIMEOUT:-60}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-SYM" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- symlink lines from boot log ---"
strings "$LOG" | grep -E "^SYMLINK-|^exec: .*symtest|^exec: symlink|^run: exit" | sed 's/^/  /'
echo ""

rc=0
# Gate 1: the exerciser created the symlink via the cyrius sys_symlink peer.
if strings "$LOG" | grep -q "^SYMLINK-CREATE-OK"; then
    echo "  PASS: sys_symlink peer created /hn_link (cyrius #63 -> kernel symlink#63 -> ext2_symlink)"
else
    echo "  FAIL: no 'SYMLINK-CREATE-OK' (sys_symlink did not return 0 on agnos)"; rc=1
fi
# Gate 2: the kernel followed the symlink on open() and read the target file.
if strings "$LOG" | grep -q "^SYMLINK-TRAVERSE-OK"; then
    echo "  PASS: open('/hn_link') followed the symlink to /etc/hostname (ext2_path_lookup follow)"
else
    echo "  FAIL: no 'SYMLINK-TRAVERSE-OK' (open didn't resolve through the symlink to the target bytes)"; rc=1
fi
# Gate 3: clean ring-3 exit (0 = both stages passed inside the program).
if strings "$LOG" | grep -q "^run: exit 0"; then
    echo "  PASS: symtest exited 0 (both stages passed in ring 3)"
else
    echo "  WARN: no 'run: exit 0' marker (the two stage markers above are the load-bearing gate)"
fi

# --- host verification: the symlink landed on the platter + e2fsck clean ---
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none

echo ""
echo "  --- host debugfs: /hn_link inode ---"
SLINK_STAT="$(debugfs -R "stat /hn_link" "$WORK/part-post.img" 2>/dev/null)"
echo "$SLINK_STAT" | grep -E "Type:|Fast link dest:|Inode:" | sed 's/^/  /'
if echo "$SLINK_STAT" | grep -q "Type: symlink"; then
    echo "  PASS: /hn_link is a symlink on the agnos-fs"
else
    echo "  FAIL: /hn_link is not a symlink on disk (sys_symlink didn't persist a S_IFLNK inode)"; rc=1
fi
# Fast symlink (target < 60 B) inlines the dest; debugfs prints `Fast link dest: "..."`.
if echo "$SLINK_STAT" | grep -q 'Fast link dest: "/etc/hostname"'; then
    echo "  PASS: on-disk symlink target == \"/etc/hostname\""
else
    echo "  FAIL: on-disk symlink target is not \"/etc/hostname\""; rc=1
fi

echo ""
echo "  --- e2fsck -fn on POST-BOOT partition ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (exit 0) — the symlink create didn't corrupt the FS"
else
    echo "  FAIL: e2fsck -fn reported problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "symlink-smoke: PASS — on-agnos sys_symlink round-trip (create + traverse + e2fsck-clean)"
else
    echo "symlink-smoke: FAIL"
fi
exit $rc
