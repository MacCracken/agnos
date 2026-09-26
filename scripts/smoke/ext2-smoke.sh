#!/bin/bash
# Multi-backend ext2/ext4 filesystem smoke test for the AGNOS kernel.
# Validates bites G (multi-backend probe + blk_read_on dispatch) + H
# (partition-aware mount via GPT consumption) from the 1.31.6 cycle and
# bite A (ext4 64BIT support / Phase 5) from the 1.31.7 cycle.
# Five scenarios, each booted under qemu-system-x86_64 + OVMF + gnoboot:
#
#   1. Baseline        — ESP-only on NVMe (boot) + a blank non-boot virtio-blk
#                        disk; no ext2 anywhere. Confirms the silent miss across
#                        backends (virtio-blk registered AND probed, no match line).
#   2. AHCI whole-disk — ESP-on-NVMe + raw mkfs.ext4 image on AHCI.
#                        Exercises bite G non-blk_active probe path.
#   3. NVMe partition  — single disk with GPT [ESP, Linux-FS] both on NVMe.
#                        Exercises bite H partition-aware mount (legacy 32 B BGDT).
#   4. Combined        — NVMe-with-partition + AHCI-whole-disk together.
#                        Validates probe ordering (NVMe wins).
#   5. 64BIT partition — same shape as smoke 3 but mkfs.ext4 -O 64bit.
#                        Exercises 1.31.7 bite A Phase 5 desc_size=64 stride.
#
# Tested under: qemu 9+, edk2 OVMF (2024+), mkfs.ext4 from e2fsprogs 1.47+.
# Requires: qemu-system-x86_64, OVMF firmware, parted, mtools (mformat
# / mmd / mcopy), sgdisk, mkfs.ext4, gnoboot built at ../gnoboot/build/.
#
# Exit 0 if all five scenarios pass; 1 if any FAIL; else 2 if any arm was VOID
# (the firmware never handed off in the banner-gated tries — the kernel never ran).
# Logs preserved under build/ext2-smoke-logs/ (per tree, one per arm, VOID
# attempts kept beside them as <arm>.log.attemptN) for post-mortem.
#
# ⛔ 1.57.9 (SMOKES3 — issue archived/2026-09-25-three-smokes-score-void-as-fail-or-skip-smp4.md):
#   · A VOID WAS A FAIL, TWICE. Each arm booted once under `timeout 30` with no
#     banner gate, so a firmware hand-off failure (the kernel never ran) failed
#     the arm's regex AND again in the "reached shell" cross-check. Arms now boot
#     through qemu_dwell_kernel (banner-gated retries, fresh vars.fd per try,
#     stop at the shell banner) and qemu_assert_booted; a VOID arm is its own
#     tally, is excluded from the cross-check, and its reason is printed.
#   · ARM 1 NEVER BOOTED ON THIS HOST. It put the ESP on virtio-blk, which the
#     edge-abi-smoke 2x2 (1.56.51) measured never hands off, on a 64 MB
#     1MiB..100% ESP that also fails on NVMe; it scored the OVMF boot menu as a
#     shell regression. Arm 1 is not reclassified as a standing VOID (a
#     documented arm that nothing runs reads as coverage): the ESP moves to the
#     one measured-working recipe (128 MB, ESP 1..33 MiB, NVMe bootindex=0) and
#     virtio-blk becomes a second, blank, NON-boot disk, so the arm still drives
#     the virtio-blk probe path it was written for, now asserted (the
#     `VirtIO-blk: N sectors` line and no `ext2: probe matched`). Arm 2 shares
#     esp-only.img and so moved to the same recipe.

set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext4 dd xxd strings; do
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
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # qemu_dwell_kernel, qemu_assert_booted, smoke_require_image
# Every arm expects the PLAIN production kernel; refuse a selftest image left in build/ by another smoke.
smoke_require_image "$AGNOS" ""

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

# The measured-working ESP recipe (1.56.51 edge-abi 2x2; msc-short/msc-cdb): 128 MB, ESP 1..33 MiB, on NVMe.
# 64 MB with ESP 1MiB..100% did not hand off on either backend in that 2x2.
build_esp_only() {
    local out=$1
    dd if=/dev/zero of="$out" bs=1M count=128 status=none
    parted -s "$out" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
    mformat -i "$out"@@1048576 -F
    mmd -i "$out"@@1048576 ::EFI
    mmd -i "$out"@@1048576 ::EFI/BOOT
    mcopy -i "$out"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mmd -i "$out"@@1048576 ::boot
    mcopy -i "$out"@@1048576 "$AGNOS" ::boot/agnos
}

# Arm 1's non-boot virtio-blk disk: 16 MB of zeroes = 32768 sectors (the kernel prints the count).
build_blank_virtio() {
    dd if=/dev/zero of="$1" bs=1M count=16 status=none
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

# 1.31.7 bite A: 64BIT-flagged variant of the partition image. Same
# layout as build_esp_plus_ext4_partition but DROPS `^64bit` from the
# -O list, so mkfs.ext4 emits a 64BIT-enabled superblock (s_desc_size=64,
# BGDT entries 64 B, INCOMPAT bit 0x80). Exercises the Phase 5 mount path.
build_esp_plus_ext4_64bit_partition() {
    local out=$1
    dd if=/dev/zero of="$out" bs=1M count=128 status=none
    parted -s "$out" mklabel gpt \
        mkpart ESP fat32 1MiB 33MiB set 1 esp on \
        mkpart agnos-fs ext4 33MiB 100MiB
    sgdisk -t 2:8300 "$out" >/dev/null
    mformat -i "$out"@@1048576 -F
    mmd -i "$out"@@1048576 ::EFI
    mmd -i "$out"@@1048576 ::EFI/BOOT
    mcopy -i "$out"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mmd -i "$out"@@1048576 ::boot
    mcopy -i "$out"@@1048576 "$AGNOS" ::boot/agnos
    local p2_offset=34603008
    local p2_blocks=$(( (67 * 1048576) / 4096 ))
    /usr/sbin/mkfs.ext4 -F -L AGNOS-64BIT \
        -O 64bit,extents,^huge_file,^metadata_csum,^has_journal,^orphan_file,^resize_inode \
        -b 4096 \
        -d "$SEED_DIR" \
        -E offset=$p2_offset \
        "$out" $p2_blocks 2>&1 | tail -2
}

# --- Smoke runner ----------------------------------------------------

# The budget only bounds a boot that never gets there: the dwell ends at the shell banner, which every
# asserted line (the boot-time ext2 probe, the storage trio) precedes.
QEMU_TIMEOUT="${QEMU_TIMEOUT:-90}"
pass=0
fail=0
void=0
BOOTED=""        # arms whose kernel ran — the only ones the cross-check may score
VOIDS=""         # "<arm> (<why>)" — xfstests' separate not-run list
VOIDNAMES=""

# run_smoke <name> <regex> <qemu args...> — returns 1 if the arm was VOID (nothing scored).
run_smoke() {
    local name=$1
    local expect=$2     # PCRE-ish regex to grep for in the log to count as PASS
    shift 2
    local log="$LOGS/$name.log"
    LOG="$log"

    QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @|BootManagerMenuApp|Please select boot device}" \
    qemu_dwell_kernel "$log" "AGNOS shell v" "$QEMU_TIMEOUT" "$WORK/vars-$name.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$name.fd" \
        "$@" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$log" >/dev/null; then
        local why; why=$(qemu_void_why "$log")
        echo "  VOID: $name — the kernel never ran ($why); nothing scored, attempts kept as $log.attempt*"
        void=$((void + 1)); VOIDNAMES="$VOIDNAMES $name"; VOIDS="$VOIDS
    $name ($why)"
        return 1
    fi
    BOOTED="$BOOTED $name"

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
    return 0
}

# --- Build images ----------------------------------------------------

echo "Building images..."
build_esp_only "$WORK/esp-only.img"
build_blank_virtio "$WORK/blank-virtio.img"
build_wholedisk_ext4 "$WORK/ext4-wholedisk.img"
build_esp_plus_ext4_partition "$WORK/esp-plus-ext4.img"
build_esp_plus_ext4_64bit_partition "$WORK/esp-plus-ext4-64bit.img"
echo ""
echo "Image sizes:"
ls -la "$WORK"/esp-only.img "$WORK"/ext4-wholedisk.img "$WORK"/esp-plus-ext4.img "$WORK"/esp-plus-ext4-64bit.img | sed 's/^/  /'
echo ""

# --- Five scenarios ---------------------------------------------------

echo "Running smokes..."

# Smoke 1: baseline. No ext2 anywhere: NVMe carries the ESP, a blank virtio-blk
# disk is attached but not bootable. Expect the shell, the virtio-blk backend
# registered (so ext2's probe walked it), and NO 'ext2: probe matched' line.
if run_smoke "1-baseline" \
    "AGNOS shell v" \
    -drive "file=$WORK/esp-only.img,format=raw,if=none,id=esp0" \
    -device "nvme,drive=esp0,serial=ESP-NVME,bootindex=0" \
    -drive "file=$WORK/blank-virtio.img,format=raw,if=none,id=vb0" \
    -device "virtio-blk-pci,drive=vb0"; then
    if strings "$LOG" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //' | grep -qxF "VirtIO-blk: 32768 sectors"; then
        echo "  PASS: 1-baseline virtio-blk registered (VirtIO-blk: 32768 sectors) — the probe had a second backend to miss on"
        pass=$((pass + 1))
    else
        echo "  FAIL: 1-baseline no kernel line 'VirtIO-blk: 32768 sectors' — the virtio-blk path this arm exists for never ran"
        fail=$((fail + 1))
    fi
    if strings "$LOG" | grep -q "ext2: probe matched"; then
        echo "  FAIL: 1-baseline 'ext2: probe matched' on a disk set with no ext2 anywhere:"
        strings "$LOG" | grep "ext2: probe matched" | head -3 | sed 's/^/        /'
        fail=$((fail + 1))
    else
        echo "  PASS: 1-baseline silent miss — no 'ext2: probe matched' across NVMe + virtio-blk"
        pass=$((pass + 1))
    fi
fi

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

# Smoke 5: 64BIT-flagged ext4 partition (1.31.7 bite A). Same shape as
# smoke 3 but the ext4 image has INCOMPAT_64BIT set; mount must succeed
# with the Phase 5 desc_size=64 BGDT-stride code path. Validates the
# bg_inode_table_hi guard implicitly (hi field is zero on this test image).
run_smoke "5-64bit-partition" \
    "ext2: probe matched backend=2 partition_lba=" \
    -drive "file=$WORK/esp-plus-ext4-64bit.img,format=raw,if=none,id=combo0" \
    -device "nvme,drive=combo0,serial=COMBO64-NVME"

# --- Regression cross-check: storage-trio + shell reached ALL smokes --
echo ""
echo "Regression cross-check (every BOOTED smoke must reach 'AGNOS shell v'; a VOID arm is not scored twice):"
for name in $BOOTED; do
    log="$LOGS/$name.log"
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
echo "ext2 multi-backend smoke: $pass passed, $fail failed, $void void"
[ "$void" -gt 0 ] && echo "Not run (VOID — the kernel never executed):$VOIDS"
echo "Logs preserved at: $LOGS"
echo "=========================================="

if [ "$fail" -gt 0 ]; then
    echo "ext2-smoke: FAIL"
    exit 1
fi
if [ "$void" -gt 0 ]; then
    echo "ext2-smoke: VOID ($void arm(s) never ran:$VOIDNAMES — reasons listed above)"
    exit 2
fi
echo "ext2-smoke: PASS"
exit 0
