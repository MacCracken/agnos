#!/bin/bash
# FB ANSI/SGR VISUAL confirmation (1.43.1) — boots the FB_ANSI_VISUAL kernel,
# which paints colour swatches through the real render path (fb_putc → the CSI/SGR
# parser → coloured glyphs) then cli/hlt-loops, and captures a QEMU screendump so
# the colours can be eyeballed (the headless fb-ansi-smoke.sh only checks parser
# STATE). Output: build/fb-ansi-screendump/ansi.png.
#
# Build first:  FB_ANSI_VISUAL=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted/mtools, python3, ffmpeg, gnoboot built.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
OVMF_VARS=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
    [ -f "$c" ] && { OVMF_VARS="$c"; break; }
done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF not found" >&2; exit 1; }
for t in qemu-system-x86_64 parted mformat mmd mcopy python3 ffmpeg; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool '$t'" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "fb-ansi-visual"; then
    echo "ERROR: kernel was not built with FB_ANSI_VISUAL=1" >&2
    echo "       rebuild: FB_ANSI_VISUAL=1 ./scripts/build.sh" >&2
    exit 1
fi

W="$ROOT/build/fb-ansi-screendump"
rm -rf "$W"; mkdir -p "$W"
ESP="$W/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
cp "$OVMF_VARS" "$W/vars.fd"; chmod +w "$W/vars.fd"

echo "=== AGNOS FB ANSI/SGR visual screendump ==="
qemu-system-x86_64 -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$W/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" -device "virtio-blk-pci,drive=esp0" \
    -vnc "unix:$W/vnc.sock" \
    -monitor "unix:$W/mon.sock,server,nowait" \
    -serial "file:$W/serial.log" -no-reboot >/dev/null 2>&1 &
QPID=$!

# Wait for the kernel to paint + halt (the marker is the signal), then screendump
# via the HMP monitor socket (HMP needs no QMP handshake — just send the command).
for i in $(seq 1 20); do
    sleep 1
    grep -aq "fb-ansi-visual: painted" "$W/serial.log" 2>/dev/null && break
done
python3 - "$W/mon.sock" "$W/ansi.ppm" <<'PY'
import socket, sys, time
sock, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); time.sleep(0.4)
try: s.recv(8192)
except Exception: pass
s.sendall(("screendump %s\n" % out).encode()); time.sleep(1.5)
s.close()
PY
sleep 1; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null

[ -f "$W/ansi.ppm" ] || { echo "FAIL: no screendump produced" >&2; exit 1; }
ffmpeg -y -loglevel error -i "$W/ansi.ppm" "$W/ansi.png"
echo "  serial: $(grep -a 'fb-ansi-visual' "$W/serial.log" | head -1)"
echo "  PNG:    $W/ansi.png ($(file -b "$W/ansi.png"))"
echo "=== open build/fb-ansi-screendump/ansi.png to eyeball the colours ==="
