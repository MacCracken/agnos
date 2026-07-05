#!/bin/bash
# Per-proc FP-state-area smoke for the AGNOS kernel (1.53.x FP/SIMD arc, bite B2).
#
# Boots the FP_AREA_SELFTEST kernel under QEMU and asserts that fpu_area_init()
# seeded all 16 per-proc FXSAVE areas correctly:
#   1. "fp: area OK"  — every pid's fpu_area(pid) is 16-byte aligned AND carries the
#                       fninit-equivalent default (FCW=0x037F, MXCSR=0x1F80).
#   2. "AGNOS shell"  — boot completed past the FP-area init (pure memory init, no fault).
#
# B2 is additive state only — no fxsave/fxrstor yet — so the production kernel stays
# FP-free (objdump -Ec 'xmm|fxsave|fxrstor' == 0); the areas feed B3's lazy #NM restore.
#
# Build first: FP_AREA_SELFTEST=1 ./scripts/build.sh
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
if ! strings "$AGNOS" | grep -q "fp: area OK"; then
    echo "ERROR: kernel not built with FP_AREA_SELFTEST=1 — rebuild: FP_AREA_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/fp-area-smoke"; LOGS="$ROOT/build/fp-area-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/fp-area.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS per-proc FP-state-area smoke (FP_AREA_SELFTEST, -m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- FP-area / shell lines ---"
strings "$LOG" | grep -E "fp: area|AGNOS shell" | head
echo "-----------------------------"

pass=0; fail=0
chk() { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }

chk "fp: area OK" "all 16 fpu_area(pid) are 16-aligned + carry the default FCW=0x037F / MXCSR=0x1F80" "an area was misaligned or the default image is wrong"
chk "AGNOS shell" "boot completed past fpu_area_init (no fault)" "boot did not reach shell"

echo ""
[ "$fail" -eq 0 ] && { echo "=== fp-area-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== fp-area-smoke: $pass passed, $fail failed ==="; exit 1
