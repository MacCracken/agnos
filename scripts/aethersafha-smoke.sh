#!/bin/sh
# aethersafha-smoke.sh — boot AGNOS and render the aethersafha compositor.
#
# DROP-IN for agnos/scripts/ (an exact mirror of doom-smoke.sh). Stages
# /bin/aethersafha (aethersafha built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with an AETHERSAFHA_SELFTEST kernel that runs /bin/aethersafha
# from disk, then screendumps the live framebuffer.
#
# PREREQ — the AETHERSAFHA_SELFTEST kernel hook (see ../README.md), two lines:
#   scripts/build.sh:      [ -n "$AETHERSAFHA_SELFTEST" ] && echo '#define AETHERSAFHA_SELFTEST'
#   kernel/core/main.cyr:  #ifdef AETHERSAFHA_SELFTEST
#                          kprintln("exec: running /bin/aethersafha", 30);
#                          sh_exec("run /bin/aethersafha", 20);
#                          kprintln("exec: aethersafha returned", 26);
#                          #endif
#
# Gates: serial shows "aethersafha: bhumi backend up" + "aethersafha: desktop up"
# (bhumi seam + compositor came up on agnos), and the framebuffer screendump is
# non-blank (the desktop rendered via fbinfo#38 / blit#39). aethersafha parks in
# its compositor loop (the agnos `while running` path), so the boot stays here
# while it renders — just like DOOM_SELFTEST.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"                 # agnos repo root
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AE_ROOT="${AE_ROOT:-$ROOT/../aethersafha}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AE="$AE_ROOT/build/aethersafha-agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AE" ]      || { echo "ERROR: aethersafha-agnos not built — (cd $AE_ROOT && cyrius build --agnos src/main.cyr build/aethersafha-agnos)"; exit 1; }

echo "[1/4] Building AETHERSAFHA_SELFTEST kernel..."
if ! env AETHERSAFHA_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/ae-smoke-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/ae-smoke-build.log)"; tail -5 /tmp/ae-smoke-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/ae-smoke"; LOGS="$ROOT/build/ae-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-ae.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/aethersafha ($(stat -c %s "$AE") B)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AE" "$SEED/bin/aethersafha"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AE -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting (gnoboot+OVMF+NVMe) and running /bin/aethersafha..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
SLOG="$LOGS/serial.log"; : > "$SLOG"
qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AE" \
    -vnc "unix:$WORK/vnc.sock" \
    -monitor "unix:$WORK/mon.sock,server,nowait" \
    -serial "file:$SLOG" -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

# Wait for aethersafha to start, then give it time to init bhumi + render.
for i in $(seq 1 30); do
    sleep 1
    grep -aq "exec: running /bin/aethersafha" "$SLOG" 2>/dev/null && break
done
sleep "${AE_RENDER_WAIT:-8}"

echo "[4/4] Screendump + checks..."
PPM="$WORK/aethersafha.ppm"
python3 - "$WORK/mon.sock" "$PPM" <<'PY'
import socket, sys, time
sock, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); time.sleep(0.4)
try: s.recv(65536)
except Exception: pass
s.sendall(("screendump %s\n" % out).encode()); time.sleep(2.0)
s.close()
PY

kill $QPID 2>/dev/null; trap - EXIT

echo ""
echo "  --- aethersafha serial lines ---"
strings "$SLOG" | grep -E "aethersafha|bhumi|desktop|exec:|PANIC|FAULT|#PF" | sed 's/^/  /' | head -20

rc=0
if strings "$SLOG" | grep -q "aethersafha: bhumi backend up"; then
    echo "  PASS: bhumi backend up (the platform seam initialized on agnos)"
else
    echo "  FAIL: bhumi backend never came up"; rc=1
fi
if strings "$SLOG" | grep -q "aethersafha: desktop up"; then
    echo "  PASS: desktop up (compositor + leaf managers wired on agnos)"
else
    echo "  FAIL: 'desktop up' absent (compositor init failed)"; rc=1
fi

# Non-blank framebuffer: the desktop is backdrop + 2 window frames + shell panel
# bars — several distinct colors, vs a near-uniform blank/console screen.
if [ -f "$PPM" ]; then
    DISTINCT=$(python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
i=d.find(b'\n',d.find(b'\n',d.find(b'\n')+1)+1)+1  # skip P6\n W H\n 255\n
px=d[i:]
seen=set()
for k in range(0,len(px)-2,3):
    seen.add(px[k:k+3])
    if len(seen)>400: break
print(len(seen))
PY
)
    echo "  framebuffer: $DISTINCT distinct colors in screendump"
    if [ "${DISTINCT:-0}" -gt 8 ]; then
        echo "  PASS: framebuffer non-blank ($DISTINCT colors — the desktop rendered)"
    else
        echo "  FAIL: framebuffer near-blank ($DISTINCT colors — nothing rendered)"; rc=1
    fi
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$PPM" "$WORK/aethersafha.png" 2>/dev/null && echo "  PNG: $WORK/aethersafha.png"
    fi
else
    echo "  FAIL: no screendump captured"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "aethersafha-smoke: PASS — the compositor renders on AGNOS" || echo "aethersafha-smoke: FAIL"
exit $rc
