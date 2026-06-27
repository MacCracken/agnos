#!/bin/bash
# kaslr-smoke.sh (1.47.4 — full-binary KASLR). Validates that the PIE kernel loads at a DIFFERENT,
# RDRAND-randomized, 2 MB-aligned physical base on each boot (gnoboot bite 2b), and that the slid
# kernel boots correctly (RIP-relative code under UEFI's identity map + the per-proc CR3's 0-256 MB
# identity window).
#
# Build first:  CYRIUS_PIE=1 ./scripts/build.sh        (an ET_DYN kernel; gnoboot slides it)
#   The kernel prints `KASLR: kernel_base=<hex>` from boot_info+0x70 right after its banner.
#
# PASS (exit 0): the observed bases are all in [32 MB, 254 MB), 2 MB-aligned, and NOT all identical
#               (the slide is live). FAIL (exit 1): out-of-window, misaligned, stuck base, or no
#               probe line at all (a non-PIE ET_EXEC kernel — KASLR needs the CYRIUS_PIE build).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings readelf; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run CYRIUS_PIE=1 ./scripts/build.sh"; exit 1; }
# KASLR is a no-op on a fixed ET_EXEC kernel; require the PIE (ET_DYN) build.
if readelf -h "$AGNOS" 2>/dev/null | grep -qE "Type:[[:space:]]+EXEC"; then
    echo "ERROR: build/agnos is ET_EXEC (non-PIE) — KASLR needs: CYRIUS_PIE=1 ./scripts/build.sh"; exit 1
fi

WORK="$ROOT/build/kaslr-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-kaslr.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BLOCKS=$(( (67 * 1048576) / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
SEED="$WORK/seed"; mkdir -p "$SEED"; echo "kaslr seed" > "$SEED/hello.txt"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-KASLR -b 4096 -m 0 -O "$EXT2_SMOKE_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

# Boot once with fresh OVMF NVRAM; echo the kernel_base hex (empty on no-probe).
boot_once() {
    local tag="$1"
    cp "$OVMF_VARS_SRC" "$WORK/vars-$tag.fd"; chmod +w "$WORK/vars-$tag.fd"
    timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$tag.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-KASLR" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$WORK/boot-$tag.log"
    strings "$WORK/boot-$tag.log" | grep -oE "KASLR: kernel_base=[0-9a-fA-F]+" | head -1 | sed 's/.*=//'
}

echo "Booting PIE kernel (expect RDRAND-slid, per-boot-varying kernel_base)..."
B1=$(boot_once 1); echo "  boot 1: kernel_base=0x${B1:-<none>}"
B2=$(boot_once 2); echo "  boot 2: kernel_base=0x${B2:-<none>}"
BASES="$B1 $B2"
# A ~1/111 RDRAND collision would tie two boots; a 3rd boot disambiguates without a false FAIL.
if [ -n "$B1" ] && [ "$B1" = "$B2" ]; then
    B3=$(boot_once 3); echo "  boot 3: kernel_base=0x${B3:-<none>} (tie-break)"; BASES="$B1 $B2 $B3"
fi

rc=0
[ -n "$B1" ] && [ -n "$B2" ] || { echo "  FAIL: no 'KASLR: kernel_base' probe — is this the CYRIUS_PIE build?"; exit 1; }
LO=$((0x2000000)); HI=$((0xFE00000)); ALIGN=$((0x200000))
for h in $BASES; do
    [ -n "$h" ] || continue
    d=$((16#$h))
    [ "$d" -ge "$LO" ] && [ "$d" -lt "$HI" ] || { echo "  FAIL: base 0x$h outside [32MB,254MB)"; rc=1; }
    [ $(( d % ALIGN )) -eq 0 ] || { echo "  FAIL: base 0x$h not 2 MB-aligned"; rc=1; }
done
NUNIQ=$(echo "$BASES" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
if [ "$NUNIQ" -ge 2 ]; then
    echo "  PASS: kernel base varies across boots (full-binary KASLR slide is live)"
else
    echo "  FAIL: identical base every boot — the slide is stuck (no entropy)"; rc=1
fi
[ $rc -eq 0 ] && echo "kaslr-smoke: PASS" || echo "kaslr-smoke: FAIL"
exit $rc
