#!/bin/bash
# Read-only ZFS smoke (agnos 1.57.11) — the kernel against pools that REAL OpenZFS built.
#
# Seven lanes, one boot each, every one against an image from scripts/tool/zfs-fixture.sh (a FreeBSD 15.1 guest
# with OpenZFS in base builds the pools and writes what `zpool import -o readonly=on -R` + `zfs mount -a` shows):
#   main      ashift 12, every default feature: lz4 / gzip / lzjb / zle / off, 1 MiB records, sha256 + sha512
#             datasets, forced gang blocks, embedded blocks, holes, large dnodes + SA xattrs/spill, a pre-SA
#             (ZPL 4) dataset, a 3,000-entry fat-ZAP directory, symlinks incl. 400-char targets, a custom /
#             canmount=off / legacy mountpoint layout, and the refusals: skein / edonr / blake3 / encrypted
#             datasets and zstd data
#   ashift9   ashift 9 (1 KiB uberblock slots)
#   v28       pool version 28 — no feature flags, lzjb metadata, ZPL 4 child
#   mirror-a  one side of a two-way mirror, read alone
#   mirror-b  the other side, read alone
#   makefs    FreeBSD makefs -t zfs — a second, independent ZFS writer
#   raidz-0   one child of a raidz1 — must be REFUSED by name with no pool mounted
# Each manifest lane boots the ZFS_SELFTEST kernel (core/zfs.cyr zfs_selftest: every grafted dir / symlink /
# file, each file SHA-256'd through the read#5 path) and scripts/smoke/lib/zfs-manifest-diff.py demands an EXACT
# reproduction of the manifest — the only tolerated differences are the refusals the pool's own properties
# explain (see that script's header).
#
# Build first:  ZFS_SELFTEST=1 sh scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools, python3, gnoboot at $GNOBOOT_ROOT/build/; the
# fixture (cached under ${ZFS_FIXTURE_DIR:-~/.cache/agnos/zfs-fixtures}; a cold build downloads the FreeBSD
# image once and needs KVM — see scripts/tool/zfs-fixture.sh). The fixture carries tests/zfs's exerciser as
# its payload (scripts/harness/zfs-ring3-test.py runs it), so both gates share ONE fixture.
# Exit 0 every lane PASS · 1 a lane failed · 2 infrastructure (no fixture, a VOID boot).

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
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
[ -f "$AGNOS" ] || { echo "ERROR: agnos not built — run ZFS_SELFTEST=1 sh scripts/build.sh"; exit 2; }
smoke_require_image "$AGNOS" "ZFS_SELFTEST"

WORK="$ROOT/build/zfs-smoke"
LOGS="$ROOT/build/zfs-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# The payload: tests/zfs's exerciser, rebuilt every run (a stale binary would key a stale fixture).
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

rc=0; lanes=0; voids=0
# lane <image> <marker> [--expect-refusal TEXT]
lane() {
    _img="$1"; _mark="$2"; shift 2
    _fi="$FIX/$_img.img"
    [ -f "$_fi" ] || { echo "  FAIL [$_img]: $_fi missing from the fixture"; rc=1; lanes=$((lanes + 1)); return; }
    _d="$WORK/$_img.disk"
    _sec=$(( $(stat -c %s "$_fi") / 512 ))
    truncate -s $(( (67584 + _sec + 2048) * 512 )) "$_d"
    parted -s "$_d" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart zfs 67584s $((67584 + _sec - 1))s
    sgdisk -t 2:a504 "$_d" >/dev/null                      # FreeBSD ZFS (the probe reads the label, not the type)
    mformat -i "$_d"@@1048576 -F
    mmd -i "$_d"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$_d"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$_d"@@1048576 "$AGNOS" ::boot/agnos
    dd if="$_fi" of="$_d" bs=512 seek=67584 conv=notrunc status=none
    _log="$LOGS/$_img.log"
    # shellcheck disable=SC2086 # ACCEL is deliberately word-split
    qemu_dwell_kernel "$_log" "$_mark" "${QEMU_TIMEOUT:-300}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 1024M $ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$_d,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-ZFS" \
        -serial stdio -display none -no-reboot
    lanes=$((lanes + 1))
    if [ "$(qemu_boot_class "$_log")" = "void" ]; then
        echo "  VOID [$_img]: the firmware never handed off — infrastructure, not ZFS ($_log)"; voids=$((voids + 1)); rm -f "$_d"; return
    fi
    echo "  --- $_img ---"
    strings "$_log" | grep -E "^(\[[^]]*\] )?zfs: (pool|dataset|vdev|this device|pool needs)" | sed 's/^/    /'
    if python3 -I "$ROOT/scripts/smoke/lib/zfs-manifest-diff.py" "$_log" "$FIX/$_img.manifest" "$FIX/$_img.summary" "$@"; then
        echo "  PASS: $_img"
    else
        echo "  FAIL: $_img ($_log)"; rc=1
    fi
    rm -f "$_d"
}

lane main      "zfs-walk: done"
lane ashift9   "zfs-walk: done"
lane v28       "zfs-walk: done"
lane mirror-a  "zfs-walk: done"
lane mirror-b  "zfs-walk: done"
lane makefs    "zfs-walk: done"
lane raidz-0   "zfs-walk: no pool"  --expect-refusal "vdev type raidz unsupported"

# ⚠ VACUITY FLOOR (the exfat-smoke rule): a lane that silently did not run must not read as a pass.
EXPECT=7
echo ""
echo "  lanes scored: $lanes/$EXPECT  (VOID: $voids)"
[ "$lanes" -lt "$EXPECT" ] && { echo "  FAIL: only $lanes of $EXPECT lanes ran"; rc=1; }
echo "=========================================="
if [ "$rc" = "0" ] && [ "$voids" = "0" ]; then
    echo "ZFS read smoke: PASS — $lanes lanes against OpenZFS-built pools ($FIX)"
elif [ "$rc" = "0" ]; then
    echo "ZFS read smoke: VOID — $voids lane(s) never booted"; rc=2
else
    echo "ZFS read smoke: FAIL"
fi
echo "Logs: $LOGS"
echo "=========================================="
exit $rc
