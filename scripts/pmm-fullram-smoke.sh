#!/bin/bash
# Full-RAM-init PMM-extension smoke for the AGNOS kernel (1.49.2 bite 2).
#
# Boots the PMM_FULLRAM_SELFTEST kernel under QEMU and asserts that the 4 KB
# allocator now serves the region ABOVE the old 16 MB cap, AND that the kernel
# still reaches its shell (proving pmm_extend_to_memmap's KASLR'd-kernel-image
# reservation didn't let top-down allocation clobber the kernel).
#
# Gates:
#   1. "PMM: alloc_top=" page > 4095   — the cap was raised past 16 MB.
#   2. "PMM ext: >16MB alloc OK"        — two 4 KB allocs landed > 16 MB, distinct, freed.
#   3. "AGNOS shell"                    — boot completed past the extension (no self-clobber).
#
# Build first: PMM_FULLRAM_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not on PATH" >&2; exit 1; }; done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "PMM ext:"; then
    echo "ERROR: kernel not built with PMM_FULLRAM_SELFTEST=1 — rebuild: PMM_FULLRAM_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/pmm-fullram-smoke"; LOGS="$ROOT/build/pmm-fullram-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/pmm-fullram.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS full-RAM PMM-extension smoke (-m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- PMM / KASLR / shell lines ---"
strings "$LOG" | grep -E "KASLR: kernel_base|RAM: usable|PMM: alloc_top|PMM ext:|PMM 2mb:|AGNOS shell" | head
echo "---------------------------------"

pass=0; fail=0
chk() { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }

TOP=$(strings "$LOG" | grep -oE "PMM: alloc_top=[0-9]+" | head -1 | grep -oE "[0-9]+")
echo ""
if [ -n "$TOP" ] && [ "$TOP" -gt 32767 ]; then echo "PASS: alloc_top=${TOP} (> 32767 — cap raised past the old 128 MB bitmap into the 256 MB window)"; pass=$((pass+1));
else echo "FAIL: alloc_top=${TOP:-?} not raised past 32767 (256 MB extension regressed to <= 128 MB)"; fail=$((fail+1)); fi
chk "PMM ext: >16MB alloc OK" "two 4 KB allocs landed > 16 MB, distinct, freed" "PMM extension alloc regression"
chk "PMM 2mb: >128MB OK"      "pmm_alloc_2mb (user pages) reaches above the old 128 MB cap into 128-256 MB" "2 MB user-page allocator still capped at 128 MB"
chk "AGNOS shell"             "kernel booted to shell with the extension (kernel image not clobbered)" "boot did not reach shell — possible self-clobber"

echo ""
[ "$fail" -eq 0 ] && { echo "=== pmm-fullram-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== pmm-fullram-smoke: $pass passed, $fail failed ==="; exit 1
