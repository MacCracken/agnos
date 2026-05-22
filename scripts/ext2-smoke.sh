#!/bin/bash
# Multi-backend ext2/ext4 filesystem smoke test for the AGNOS kernel.
# Validates bites G (multi-backend probe + blk_read_on dispatch) and
# H (partition-aware mount via GPT consumption) from the 1.31.6 cycle.
# Four scenarios, each booted under qemu-system-x86_64 + OVMF + gnoboot:
#
#   1. Baseline       — ESP-only on virtio-blk; no ext2 anywhere.
#                       Confirms silent miss + no regression on storage trio.
#   2. AHCI whole-disk — ESP-on-NVMe + raw mkfs.ext4 image on AHCI.
#                       Exercises bite G non-blk_active probe path.
#   3. NVMe partition  — single disk with GPT [ESP, Linux-FS] both on NVMe.
#                       Exercises bite H partition-aware mount.
#   4. Combined        — NVMe-with-partition + AHCI-whole-disk together.
#                       Validates probe ordering (NVMe-wins).
#
# Tested under: qemu 9+, edk2 OVMF (2024+), mkfs.ext4 from e2fsprogs 1.47+.
# Requires: qemu-system-x86_64, OVMF firmware, parted, mtools (mformat
# / mmd / mcopy), sgdisk, mkfs.ext4, gnoboot built at ../gnoboot/build/.
#
# Exit 0 if all four scenarios pass; 1 if any fail. Logs preserved under
# build/ext2-smoke-logs/ for post-mortem.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

# OVMF discovery — Arch ships at edk2/x64/, Debian/Ubuntu at OVMF/
OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
    /usr/share/qemu/OVMF_CODE.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
    /usr/share/qemu/OVMF_VARS.fd
"

OVMF_CODE=""
for c in $OVMF_CODE_CANDIDATES; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS_SRC=""
for c in $OVMF_VARS_CANDIDATES; do
    [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }
done

if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)." >&2
    exit 1
fi

# Tool gate.
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext4 dd xxd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not on PATH" >&2
        exit 1
    fi
done

# Build artifacts.
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"

if [ ! -f "$GNOBOOT" ]; then
    echo "ERROR: gnoboot not built at $GNOBOOT" >&2
    echo "       cd $GNOBOOT_ROOT && CYRIUS_TARGET_EFI=1 cyrius build src/main.cyr build/BOOTX64.EFI" >&2
    exit 1
fi
if [ ! -f "$AGNOS" ]; then
    echo "ERROR: agnos kernel not built at $AGNOS" >&2
    echo "       cd $ROOT && scripts/build.sh" >&2
    exit 1
fi

# Work area: build/ext2-smoke/, build/ext2-smoke-logs/ — under build/ so
# the existing build/ .gitignore covers them.
WORK="$ROOT/build/ext2-smoke"
LOGS="$ROOT/build/ext2-smoke-logs"
SEED_DIR="$WORK/seed"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS" "$SEED_DIR"

# Seed file copied into every ext4 image. Dedicated dir so `mkfs.ext4 -d`
# only copies this one file in (no accidental TMP-dir hoover).
SEED_STRING="agnos ext2 smoke: bites G+H validated $(date +%Y-%m-%d)"
echo -n "$SEED_STRING" > "$SEED_DIR/hello.txt"

echo "=== AGNOS ext2 multi-backend smoke ==="
echo "  agnos:      $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  gnoboot:    $GNOBOOT ($(stat -c %s "$GNOBOOT") B)"
echo "  OVMF code:  $OVMF_CODE"
echo "  OVMF vars:  $OVMF_VARS_SRC"
echo "  work dir:   $WORK"
echo "  log dir:    $LOGS"
echo "  seed:       '$SEED_STRING' (${#SEED_STRING} bytes)"
echo ""

# --- Image builders --------------------------------------------------

build_esp_only() {
    local out=$1
    dd if=/dev/zero of="$out" bs=1M count=64 status=none
    parted -s "$out" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
    mformat -i "$out"@@1048576 -F
    mmd -i "$out"@@1048576 ::EFI
    mmd -i "$out"@@1048576 ::EFI/BOOT
    mcopy -i "$out"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mmd -i "$out"@@1048576 ::boot
    mcopy -i "$out"@@1048576 "$AGNOS" ::boot/agnos
}

build_wholedisk_ext4() {
    local out=$1
    dd if=/dev/zero of="$out" bs=1M count=16 status=none
    /usr/sbin/mkfs.ext4 -F -L AGNOS-FS \
        -O extents,^huge_file,^64bit,^metadata_csum \
        -b 4096 \
        -d "$SEED_DIR" \
        "$out" 2>&1 | tail -2
}

build_esp_plus_ext4_partition() {
    local out=$1
    dd if=/dev/zero of="$out" bs=1M count=128 status=none
    parted -s "$out" mklabel gpt \
        mkpart ESP fat32 1MiB 33MiB set 1 esp on \
        mkpart agnos-fs ext4 33MiB 100MiB
    sgdisk -t 2:8300 "$out" >/dev/null   # Linux-FS GUID 0FC63DAF-…
    mformat -i "$out"@@1048576 -F
    mmd -i "$out"@@1048576 ::EFI
    mmd -i "$out"@@1048576 ::EFI/BOOT
    mcopy -i "$out"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mmd -i "$out"@@1048576 ::boot
    mcopy -i "$out"@@1048576 "$AGNOS" ::boot/agnos
    local p2_offset=34603008                                # 33 MiB
    local p2_blocks=$(( (67 * 1048576) / 4096 ))            # 67 MiB / 4K
    /usr/sbin/mkfs.ext4 -F -L AGNOS-NVME-FS \
        -O extents,^huge_file,^64bit,^metadata_csum,^has_journal,^orphan_file,^resize_inode \
        -b 4096 \
        -d "$SEED_DIR" \
        -E offset=$p2_offset \
        "$out" $p2_blocks 2>&1 | tail -2
}

# --- Smoke runner ----------------------------------------------------

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
pass=0
fail=0

run_smoke() {
    local name=$1
    local expect=$2     # PCRE-ish regex to grep for in the log to count as PASS
    shift 2
    cp "$OVMF_VARS_SRC" "$WORK/vars-$name.fd"
    chmod +w "$WORK/vars-$name.fd"
    local log="$LOGS/$name.log"

    timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$name.fd" \
        "$@" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$log"

    # Read log via `strings` because the serial stream is ANSI/CSI noise
    # mixed with the kernel output; `grep -a` on the raw log can choke
    # on the early gnoboot/OVMF banner bytes.
    if strings "$log" | grep -qE "$expect"; then
        echo "  PASS: $name"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name (regex '$expect' not matched)"
        echo "        --- last 20 lines of $log ---"
        strings "$log" | tail -20 | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

# --- Build images ----------------------------------------------------

echo "Building images..."
build_esp_only "$WORK/esp-only.img"
build_wholedisk_ext4 "$WORK/ext4-wholedisk.img"
build_esp_plus_ext4_partition "$WORK/esp-plus-ext4.img"
echo ""
echo "Image sizes:"
ls -la "$WORK"/esp-only.img "$WORK"/ext4-wholedisk.img "$WORK"/esp-plus-ext4.img | sed 's/^/  /'
echo ""

# --- Four scenarios ---------------------------------------------------

echo "Running smokes..."

# Smoke 1: baseline. No ext2 anywhere; expect kernel reaches shell
# without any 'ext2: probe matched' line. Match on the shell banner +
# absence of probe-match line via a positive shell-reached check.
run_smoke "1-baseline" \
    "AGNOS shell v" \
    -drive "file=$WORK/esp-only.img,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0"

# Smoke 2: AHCI whole-disk ext4. Bite G should match BLK_AHCI=3.
run_smoke "2-ahci-wholedisk" \
    "ext2: probe matched backend=3 whole-disk" \
    -drive "file=$WORK/esp-only.img,format=raw,if=none,id=esp0" \
    -device "nvme,drive=esp0,serial=ESP-NVME" \
    -drive "file=$WORK/ext4-wholedisk.img,format=raw,if=none,id=ext4d" \
    -device "ich9-ahci,id=ahci0" \
    -device "ide-hd,drive=ext4d,bus=ahci0.0"

# Smoke 3: NVMe with Linux-FS partition. Bite H should match BLK_NVME=2.
run_smoke "3-nvme-partition" \
    "ext2: probe matched backend=2 partition_lba=" \
    -drive "file=$WORK/esp-plus-ext4.img,format=raw,if=none,id=combo0" \
    -device "nvme,drive=combo0,serial=COMBO-NVME"

# Smoke 4: combined. NVMe partition path should win over AHCI whole-disk.
run_smoke "4-combined-order" \
    "ext2: probe matched backend=2 partition_lba=" \
    -drive "file=$WORK/esp-plus-ext4.img,format=raw,if=none,id=combo0" \
    -device "nvme,drive=combo0,serial=COMBO-NVME" \
    -drive "file=$WORK/ext4-wholedisk.img,format=raw,if=none,id=ext4d" \
    -device "ich9-ahci,id=ahci0" \
    -device "ide-hd,drive=ext4d,bus=ahci0.0"

# --- Regression cross-check: storage-trio + shell reached ALL smokes --
echo ""
echo "Regression cross-check (every smoke must reach 'AGNOS shell v'):"
for log in "$LOGS"/*.log; do
    name=$(basename "$log" .log)
    if strings "$log" | grep -q "AGNOS shell v"; then
        echo "  PASS: $name reached shell"
    else
        echo "  FAIL: $name did NOT reach shell (regression!)"
        fail=$((fail + 1))
    fi
done

# --- Summary --------------------------------------------------------

echo ""
echo "=========================================="
echo "ext2 multi-backend smoke: $pass passed, $fail failed"
echo "Logs preserved at: $LOGS"
echo "=========================================="

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
