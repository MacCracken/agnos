#!/bin/bash
# Full-RAM-init probe smoke for the AGNOS kernel (1.49.1 bite 1).
#
# The always-on boot probe (pmm_probe_memmap, main.cyr) reads the UEFI memory
# map gnoboot passes in boot_info and logs "RAM: usable=<N>MB top=<addr>".
# This boots the SAME kernel twice under different QEMU -m sizes and asserts
# the reported RAM SCALES with -m — proving it reads the real machine memory,
# not the old hardcoded 128 MB (32768-page) bitmap.
#
# No special build flag — the probe is always on. Just build normally first.
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

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
for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)." >&2
    exit 1
fi
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "RAM: usable"; then
    echo "ERROR: kernel has no RAM probe — rebuild (sh scripts/build.sh)" >&2
    exit 1
fi

WORK="$ROOT/build/ram-probe-smoke"
LOGS="$ROOT/build/ram-probe-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"

# Boot once at a given -m and echo the reported usable MB (or empty).
boot_mb() {
    local mem="$1"; local log="$LOGS/ram-$mem.log"
    cp "$OVMF_VARS_SRC" "$WORK/vars-$mem.fd"; chmod +w "$WORK/vars-$mem.fd"
    timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -m "$mem" -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$mem.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "virtio-blk-pci,drive=esp0" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$log"
    strings "$log" | grep -oE "RAM: usable=[0-9]+" | head -1 | grep -oE "[0-9]+"
}

echo "=== AGNOS full-RAM-init probe smoke ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
echo ""

MB_SMALL=$(boot_mb 256M)
MB_LARGE=$(boot_mb 1024M)
echo "  -m 256M  -> usable ${MB_SMALL:-?} MB"
echo "  -m 1024M -> usable ${MB_LARGE:-?} MB"
echo ""

fail=0
if [ -z "$MB_SMALL" ] || [ -z "$MB_LARGE" ]; then
    echo "FAIL: probe line not captured at one or both sizes (boot didn't complete?)"
    fail=1
else
    # (1) reads real RAM, not the old hardcoded 128 MB: the 256M boot must exceed 128.
    if [ "$MB_SMALL" -gt 128 ]; then echo "PASS: 256M boot reports ${MB_SMALL} MB (> 128 — reads real memmap, not the hardcoded bitmap)"
    else echo "FAIL: 256M boot reports ${MB_SMALL} MB (<= 128 — looks hardcoded)"; fail=1; fi
    # (2) scales with -m: the 1024M boot must report meaningfully more than the 256M boot.
    if [ "$MB_LARGE" -gt "$((MB_SMALL * 2))" ]; then echo "PASS: 1024M boot reports ${MB_LARGE} MB (> 2x the 256M boot — scales with -m)"
    else echo "FAIL: 1024M boot reports ${MB_LARGE} MB (not > 2x ${MB_SMALL} — doesn't scale)"; fail=1; fi
    # (3) the kernel direct-map (1.49.7, validation corrected 1.49.10): a TRUE >256 MB access. The
    #     1024M boot round-trips phys 320 MB through DIRECTMAP_BASE + 320 MB *under the kernel CR3 0x1000*
    #     (the context consumers run in — NOT gnoboot's boot CR3, whose PDPT[8] is a 1 GB identity page to
    #     unbacked phys 8 GB; that was the 1.49.9 false-positive that got mis-blamed on cyrius). The 256M
    #     boot has no >256 MB RAM so it reports the structural "directmap: installed" instead.
    if strings "$LOGS/ram-1024M.log" | grep -q "directmap: >256MB OK (kernel CR3)"; then echo "PASS: >256 MB direct-map round-trips under kernel CR3 (phys 320 MB via DIRECTMAP_BASE — the real test)"
    else echo "FAIL: 'directmap: >256MB OK (kernel CR3)' not found in 1024M boot (direct-map >256 MB access broken)"; fail=1; fi
    if strings "$LOGS/ram-256M.log" | grep -q "directmap: installed"; then echo "PASS: 256M boot installs the direct-map PDPT[8] (structural check)"
    else echo "FAIL: 'directmap: installed' not found in 256M boot"; fail=1; fi
fi

echo ""
[ "$fail" -eq 0 ] && { echo "=== ram-probe-smoke: PASS ==="; exit 0; }
echo "=== ram-probe-smoke: FAIL ==="; exit 1
