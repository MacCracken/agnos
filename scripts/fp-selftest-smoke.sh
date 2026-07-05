#!/bin/bash
# FP/SSE-enable smoke for the AGNOS kernel (1.53.x FP/SIMD arc, bite B1).
#
# Boots the FP_SELFTEST kernel under QEMU and asserts that SSE is enabled per
# core (CR0.EM off, CR4.OSFXSR on) so ring-0/ring-3 f64 stops #UD-ing:
#   1. "SSE enabled"   — fpu_enable() ran on the BSP after pt_init().
#   2. "fp: movsd OK"  — a raw `movsd xmm0,xmm0` executed (did NOT #UD) → SSE live.
#   3. "fp: ring0 OK"  — a cyrius scalar-f64 multiply (3.0*2.0) computed 6.0 on xmm.
#   4. "AGNOS shell"   — boot completed past the FP proof (no fault took the box down).
#
# The production kernel stays FP-free (objdump grep -c xmm == 0); this smoke uses
# the FP_SELFTEST build, which is the ONLY build carrying xmm/f64.
#
# Build first: FP_SELFTEST=1 ./scripts/build.sh
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
if ! strings "$AGNOS" | grep -q "fp: movsd OK"; then
    echo "ERROR: kernel not built with FP_SELFTEST=1 — rebuild: FP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/fp-selftest-smoke"; LOGS="$ROOT/build/fp-selftest-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/fp-selftest.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS FP/SSE-enable smoke (FP_SELFTEST, -m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- FP / SSE / shell lines ---"
strings "$LOG" | grep -E "SSE enabled|fp: movsd|fp: ring0|Invalid Opcode|#UD|AGNOS shell" | head
echo "------------------------------"

pass=0; fail=0
chk() { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }

chk "SSE enabled"  "fpu_enable() ran on the BSP after pt_init()" "SSE enable not reached — fpu_enable never ran or faulted"
chk "fp: movsd OK" "raw movsd executed (no #UD) — SSE is live"    "movsd #UD'd — CR4.OSFXSR/CR0.EM not set correctly"
chk "fp: ring0 OK" "cyrius scalar-f64 mul computed 6.0 on xmm"    "ring-0 f64 mul wrong/absent — f64 codegen or comisd path broke"
chk "AGNOS shell"  "boot completed past the FP proof (no fault)"  "boot did not reach shell — an FP fault may have taken the box down"

echo ""
[ "$fail" -eq 0 ] && { echo "=== fp-selftest-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== fp-selftest-smoke: $pass passed, $fail failed ==="; exit 1
