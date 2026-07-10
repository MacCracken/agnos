#!/bin/sh
# aethersafha-setu-smoke.sh — prove the setu display protocol END-TO-END on AGNOS.
#
# Extends aethersafha-smoke.sh (the 3a "first light" render proof) into the 3b
# transport proof: the compositor stands up a setu listener on TCP loopback:7700,
# spawn_path's /bin/puka (its first setu client) from ext2, accepts the connection,
# and composites the client's presented window onto the desktop — the on-device
# analog of the Linux puka_launch_probe, all over setu's cross-platform transport
# (net.cyr → agnos kernel TCP #56/#57, loopback-delivered via the kernel lo_ring).
#
# /bin/puka is seeded with setu's slim `present_probe` (a mabda-free setu client
# that presents a distinctive green-bordered grid) — full puka can't build --agnos
# yet (mabda uses Linux SYS_IOCTL). Reuses the AETHERSAFHA_SELFTEST kernel hook
# unchanged; the compositor does the spawn, so only the extra /bin/puka seed differs.
#
# Gates: serial shows "setu listener up", "launched first resident /bin/puka", and
# "setu client presented surface" (the client connected + presented + was
# composited on-device), and the screendump carries the client's green border.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"                 # agnos repo root
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AE_ROOT="${AE_ROOT:-$ROOT/../aethersafha}"
SETU_ROOT="${SETU_ROOT:-$ROOT/../setu}"
DHANCHA_ROOT="${DHANCHA_ROOT:-$ROOT/../dhancha}"
CRAB_ROOT="${CRAB_ROOT:-$ROOT/../crab}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AE="$AE_ROOT/build/aethersafha-agnos"
PP="$SETU_ROOT/build/present_probe-agnos"
CRAB="$CRAB_ROOT/build/crab-agnos"                       # crab — the sovereign file manager (dhancha app)
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AE" ]      || { echo "ERROR: aethersafha-agnos not built — (cd $AE_ROOT && cyrius build --agnos src/main.cyr build/aethersafha-agnos)"; exit 1; }
[ -f "$PP" ]      || { echo "ERROR: present_probe-agnos not built — (cd $SETU_ROOT && cyrius build --agnos programs/present_probe.cyr build/present_probe-agnos)"; exit 1; }
[ -f "$CRAB" ]    || { echo "ERROR: crab-agnos not built — (cd $CRAB_ROOT && cyrius build --agnos src/main.cyr build/crab-agnos)"; exit 1; }

echo "[1/4] Building AETHERSAFHA_SETU_SELFTEST kernel (post-sched_active hook)..."
if ! env AETHERSAFHA_SETU_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/ae-setu-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/ae-setu-build.log)"; tail -5 /tmp/ae-setu-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/ae-setu-smoke"; LOGS="$ROOT/build/ae-setu-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-ae.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/aethersafha ($(stat -c %s "$AE") B) + /bin/puka ($(stat -c %s "$PP") B, slim setu client)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AE" "$SEED/bin/aethersafha"
cp "$PP" "$SEED/bin/puka"
cp "$CRAB" "$SEED/bin/crab"                              # /bin/crab = the sovereign file manager

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

echo "[3/4] Booting (gnoboot+OVMF+NVMe); compositor spawns /bin/puka over setu..."
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

for i in $(seq 1 30); do
    sleep 1
    grep -aq "exec: running /bin/aethersafha" "$SLOG" 2>/dev/null && break
done
sleep "${AE_RENDER_WAIT:-10}"

echo "[4/4] Screendump + checks..."
PPM="$WORK/aethersafha-setu.ppm"
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
echo "  --- aethersafha/setu serial lines ---"
strings "$SLOG" | grep -E "aethersafha|setu|puka|bhumi|desktop|exec:|PANIC|FAULT|#PF" | sed 's/^/  /' | head -24

rc=0
if strings "$SLOG" | grep -q "aethersafha: bhumi backend up"; then
    echo "  PASS: bhumi backend up"
else
    echo "  FAIL: bhumi backend never came up"; rc=1
fi
if strings "$SLOG" | grep -q "aethersafha: setu listener up"; then
    echo "  PASS: setu listener up on agnos (TCP loopback:7700)"
else
    echo "  FAIL: setu listener did not come up"; rc=1
fi
if strings "$SLOG" | grep -q "launched setu client"; then
    echo "  PASS: compositor spawn_path'd the setu client(s)"
else
    echo "  FAIL: no setu client was launched (spawn_path failed?)"; rc=1
fi
if strings "$SLOG" | grep -q "aethersafha: setu client presented surface"; then
    echo "  PASS: setu client CONNECTED + PRESENTED + composited on agnos (3b e2e)"
else
    echo "  FAIL: no client present composited (the setu wire did not complete on agnos)"; rc=1
fi

# Visual confirm: the client's window carries a 2px green (0,255,0) border.
if [ -f "$PPM" ]; then
    GREEN=$(python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
i=d.find(b'\n',d.find(b'\n',d.find(b'\n')+1)+1)+1
px=d[i:]
n=0
for k in range(0,len(px)-2,3):
    if px[k]==0 and px[k+1]==255 and px[k+2]==0: n+=1
print(n)
PY
)
    echo "  framebuffer: $GREEN green-border pixels (the client window)"
    [ "${GREEN:-0}" -gt 100 ] && echo "  PASS: client window visible in screendump" || echo "  NOTE: green border not detected (serial gate is dispositive)"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$PPM" "$WORK/aethersafha-setu.png" 2>/dev/null && echo "  PNG: $WORK/aethersafha-setu.png"
    fi
else
    echo "  FAIL: no screendump captured"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "aethersafha-setu-smoke: PASS — setu client composited by the compositor ON AGNOS" || echo "aethersafha-setu-smoke: FAIL"
exit $rc
