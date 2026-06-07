#!/bin/bash
# FB ANSI/CSI/SGR parser smoke (1.43.1).
#
# Boots the agnos kernel under qemu-system-x86_64 + OVMF + gnoboot with
# FB_ANSI_SELFTEST=1, which feeds escape sequences through fb_ansi_feed() right
# after fb_console_init() and asserts the resulting colour/cursor STATE via serial
# markers. This is the deterministic gate for the console ANSI interpreter that
# makes anuenue's colours render + agnsh's `clear` work (no pixel inspection).
#
# Gate (hermetic — no disk/network needed; the selftest is pure parser state):
#   9× "fb-ansi: PASS <case>"  — SGR 16-colour / reset / 256-colour / truecolour
#                        fg + bg, CUP cursor positioning, ED 2J clear-homes-cursor
#   "fb-ansi: selftest done"   — the selftest ran to completion
#   and ZERO "fb-ansi: FAIL".
#
# Requires: qemu-system-x86_64, OVMF firmware, mtools, parted, gnoboot built.
# Build first:  FB_ANSI_SELFTEST=1 ./scripts/build.sh
# Exit 0 if all 9 checks pass with no FAIL; 1 otherwise.

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
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not on PATH" >&2
        exit 1
    fi
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }

if ! strings "$AGNOS" | grep -q "fb-ansi: selftest done"; then
    echo "ERROR: kernel was not built with FB_ANSI_SELFTEST=1" >&2
    echo "       rebuild: FB_ANSI_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/fb-ansi-smoke"
LOGS="$ROOT/build/fb-ansi-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"

ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI
mmd -i "$ESP"@@1048576 ::EFI/BOOT
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mmd -i "$ESP"@@1048576 ::boot
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS FB ANSI/SGR parser smoke ==="
echo "  agnos:     $AGNOS ($(stat -c %s "$AGNOS") B)"
echo "  OVMF code: $OVMF_CODE"
echo "  log dir:   $LOGS"
echo ""

QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
LOG="$LOGS/fb-ansi.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"
chmod +w "$WORK/vars.fd"

timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- serial log (fb-ansi lines) ---"
grep -E "fb-ansi:" "$LOG" || echo "(no fb-ansi lines captured)"
echo "----------------------------------"

PASS_N=$(grep -c "fb-ansi: PASS " "$LOG")
FAIL_N=$(grep -c "fb-ansi: FAIL " "$LOG")
DONE=$(grep -c "fb-ansi: selftest done" "$LOG")

rc=0
if [ "$DONE" -lt 1 ]; then
    echo "FAIL: selftest did not run to completion ('fb-ansi: selftest done' missing)"; rc=1
fi
if [ "$FAIL_N" -ne 0 ]; then
    echo "FAIL: $FAIL_N parser check(s) failed"; rc=1
fi
if [ "$PASS_N" -ne 9 ]; then
    echo "FAIL: expected 9 'fb-ansi: PASS' checks, got $PASS_N"; rc=1
fi

echo ""
if [ "$rc" -eq 0 ]; then
    echo "=== fb-ansi-smoke: PASS ($PASS_N/9 parser checks, 0 fail) ==="
else
    echo "=== fb-ansi-smoke: FAIL ($PASS_N pass, $FAIL_N fail) ==="
fi
exit "$rc"
