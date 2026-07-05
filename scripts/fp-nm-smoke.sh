#!/bin/bash
# Lazy-#NM FP-context-switch smoke for the AGNOS kernel (1.53.x FP/SIMD arc, bite B3a).
#
# Boots the FP_NM_SELFTEST kernel under QEMU and asserts the #NM (vector 7) handler
# services a forced FP-trap end to end:
#   1. "fp: #NM serviced" — CR0.TS was set, an SSE op #NM'd, nm_handler cleared TS +
#                           FXRSTOR'd, the op retried and completed, latch set.
#   2. NOT "fp: #NM MISSED" and NOT a hang — no infinite #NM loop / #DF.
#   3. "AGNOS shell"       — boot completed past the probe.
#
# The production kernel has EXACTLY 2 sanctioned FP ops (the fxsave/fxrstor leaf
# helpers) and is otherwise FP-free; this smoke uses the FP_NM_SELFTEST build, which
# additionally forces CR0.TS + runs a probe movsd.
#
# Build first: FP_NM_SELFTEST=1 ./scripts/build.sh
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
if ! strings "$AGNOS" | grep -q "fp: #NM serviced"; then
    echo "ERROR: kernel not built with FP_NM_SELFTEST=1 — rebuild: FP_NM_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/fp-nm-smoke"; LOGS="$ROOT/build/fp-nm-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/fp-nm.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS lazy-#NM FP smoke (FP_NM_SELFTEST, -m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- #NM / shell lines ---"
strings "$LOG" | grep -E "fp: #NM|Invalid Opcode|Double Fault|#NM|#DF|AGNOS shell" | head
echo "-------------------------"

pass=0; fail=0
chk()  { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }
nchk() { if grep -q "$1" "$LOG"; then echo "FAIL: '$1' present — $3"; fail=$((fail+1)); else echo "PASS: $2"; pass=$((pass+1)); fi; }

chk  "fp: #NM serviced" "#NM fired on the forced FP-trap, nm_handler serviced it, the op retried + completed" "the #NM path did not service — gate not installed, or FXSAVE/FXRSTOR faulted"
nchk "fp: #NM MISSED"   "the latch was set (nm_handler ran) — no missed service"                              "nm_handler did not run (movsd didn't #NM, or handler never reached the latch)"
chk  "AGNOS shell"      "boot completed past the #NM probe — no infinite #NM loop / #DF took the box down"     "boot did not reach shell — possible #NM loop or #DF"

echo ""
[ "$fail" -eq 0 ] && { echo "=== fp-nm-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== fp-nm-smoke: $pass passed, $fail failed ==="; exit 1
