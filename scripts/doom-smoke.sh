#!/bin/sh
# doom-smoke.sh — boot AGNOS and render cyrius-doom (the first real userland app).
#
# Stages /bin/doom (cyrius-doom built --agnos) + /DOOM1.WAD onto the agnos-fs
# ext2 root, boots gnoboot+OVMF+NVMe with a DOOM_SELFTEST kernel that runs
# `/bin/doom` from disk, then screendumps the live framebuffer.
#
# Gates: doom prints "cyrius-doom v0.28.0" (started) + "wad loaded" (the
# in-memory WAD slurp + parse succeeded — the load-bearing port claim), and the
# framebuffer screendump is non-blank (something rendered). Saves a PNG for eyes.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
DOOM_ROOT="${DOOM_ROOT:-$ROOT/../cyrius-doom}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
DOOM="$DOOM_ROOT/build/doom_agnos"
WAD="$DOOM_ROOT/wad/DOOM1.WAD"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$DOOM" ]    || { echo "ERROR: doom_agnos not built — (cd $DOOM_ROOT && cyrius build --agnos src/main.cyr build/doom_agnos)"; exit 1; }
[ -f "$WAD" ]     || { echo "ERROR: DOOM1.WAD not found at $WAD"; exit 1; }

# Build the DOOM_SELFTEST kernel (runs /bin/doom from disk at boot).
echo "[1/4] Building DOOM_SELFTEST kernel..."
if ! env DOOM_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/doom-smoke-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/doom-smoke-build.log)"; tail -5 /tmp/doom-smoke-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/doom-smoke"; LOGS="$ROOT/build/doom-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-doom.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/doom ($(stat -c %s "$DOOM") B) + /DOOM1.WAD ($(stat -c %s "$WAD") B)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$DOOM" "$SEED/bin/doom"
cp "$WAD"  "$SEED/DOOM1.WAD"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-DOOM -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting (gnoboot+OVMF+NVMe) and running /bin/doom..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
SLOG="$LOGS/serial.log"; : > "$SLOG"
qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-DOOM" \
    -vnc "unix:$WORK/vnc.sock" \
    -monitor "unix:$WORK/mon.sock,server,nowait" \
    -serial "file:$SLOG" -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

# Wait for doom to start, then give it time to slurp the 4 MB WAD + render.
for i in $(seq 1 30); do
    sleep 1
    grep -aq "exec: running /bin/doom" "$SLOG" 2>/dev/null && break
done
sleep "${DOOM_RENDER_WAIT:-10}"

echo "[4/4] Screendump + checks..."
PPM="$WORK/doom.ppm"
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
echo "  --- doom serial lines ---"
strings "$SLOG" | grep -E "doom|wad|cyrius-doom|exec:|PANIC|FAULT|#PF" | sed 's/^/  /' | head -20

rc=0
if strings "$SLOG" | grep -q "cyrius-doom v0.28.0"; then
    echo "  PASS: /bin/doom started (584 KB ELF exec'd from disk in ring 3)"
else
    echo "  FAIL: doom never started (exec-from-disk of the 584 KB binary failed)"; rc=1
fi
if strings "$SLOG" | grep -q "wad loaded"; then
    echo "  PASS: WAD loaded — the in-memory 4 MB DOOM1.WAD slurp + parse worked on agnos"
else
    echo "  FAIL: 'wad loaded' absent (WAD open/slurp/parse failed — heap or ext2 read)"; rc=1
fi

# Non-blank framebuffer check (DOOM renders many distinct colors; a blank/console
# screen is near-uniform).
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
    if [ "${DISTINCT:-0}" -gt 64 ]; then
        echo "  PASS: framebuffer is non-blank ($DISTINCT colors — content rendered)"
    else
        echo "  FAIL: framebuffer near-blank ($DISTINCT colors — nothing rendered)"; rc=1
    fi
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$PPM" "$WORK/doom.png" 2>/dev/null && echo "  PNG: $WORK/doom.png"
    fi
else
    echo "  FAIL: no screendump captured"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "doom-smoke: PASS — DOOM renders on AGNOS" || echo "doom-smoke: FAIL"
exit $rc
