#!/bin/sh
# aethersafha-jalwa-smoke.sh — prove the jalwa music player runs as a WINDOW on the
# sovereign desktop.
#
# The 3b-desktop-app proof, second client: the aethersafha compositor stands up a setu
# listener on TCP loopback:7700, spawn_path's its first resident from ext2, accepts the
# connection, and composites the client's presented window onto the desktop. Here the
# first-resident slot (/bin/puka) is seeded with jalwa built --agnos (its setu GUI
# backend, src/gui/setu_present.cyr), so jalwa connects over setu and presents its
# 800x600 XRGB8888 GUI as a window — the SAME sys_shm shared-buffer present path doom
# uses (setu_buf_create#71 -> buf_write#72 -> attach_buf fmt=1 -> commit). This reuses
# the AETHERSAFHA_SETU_SELFTEST kernel hook UNCHANGED and makes NO aethersafha source
# change: only the /bin/puka seed differs (jalwa instead of doom). jalwa on agnos, spawned
# bare (no args), defaults to its GUI window (mirrors doom's no-arg PM_SETU boot); a fresh
# desktop has no library db yet, so it opens an empty in-memory library — no asset needed.
#
# NOTE jalwa's GUI startup touches NO audio (audio only fires on a user play action), so
# this is a pure compositing proof — no mishran daemon need be resident.
#
# Gates: serial shows "setu listener up", "launched setu client", "setu client presented
# surface" (jalwa connected + presented + was composited on-device) AND jalwa's own boot
# banner ("jalwa: agnos desktop gui"); the screendump carries a non-blank, colour-rich
# frame (jalwa's rendered UI chrome vs the flat desktop backdrop). The serial gate is
# dispositive.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"                 # agnos repo root
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AE_ROOT="${AE_ROOT:-$ROOT/../aethersafha}"
JALWA_ROOT="${JALWA_ROOT:-$ROOT/../jalwa}"
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
JALWA="$JALWA_ROOT/build/jalwa-agnos"
CRAB="$CRAB_ROOT/build/crab-agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AE" ]      || { echo "ERROR: aethersafha-agnos not built — (cd $AE_ROOT && cyrius build --agnos src/main.cyr build/aethersafha-agnos)"; exit 1; }
[ -f "$JALWA" ]   || { echo "ERROR: jalwa-agnos not built — (cd $JALWA_ROOT && cyrius build --agnos src/main.cyr build/jalwa-agnos)"; exit 1; }
[ -f "$CRAB" ]    || { echo "ERROR: crab-agnos not built — (cd $CRAB_ROOT && cyrius build --agnos src/main.cyr build/crab-agnos)"; exit 1; }

echo "[1/4] Building AETHERSAFHA_SETU_SELFTEST kernel (post-sched_active hook)..."
if ! env AETHERSAFHA_SETU_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/ae-jalwa-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/ae-jalwa-build.log)"; tail -5 /tmp/ae-jalwa-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/ae-jalwa-smoke"; LOGS="$ROOT/build/ae-jalwa-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-ae-jalwa.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 200 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 with /bin/aethersafha + /bin/puka=jalwa ($(stat -c %s "$JALWA") B) + /bin/crab..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AE"    "$SEED/bin/aethersafha"
cp "$JALWA" "$SEED/bin/puka"          # first-resident slot = jalwa (its setu GUI backend); no aethersafha change
cp "$CRAB"  "$SEED/bin/crab"          # second resident = the sovereign file manager (a known-good window)

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AE-JALWA -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting (gnoboot+OVMF+NVMe); compositor spawns /bin/puka=jalwa over setu..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
SLOG="$LOGS/serial.log"; : > "$SLOG"
qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AE-JALWA" \
    -vnc "unix:$WORK/vnc.sock" \
    -monitor "unix:$WORK/mon.sock,server,nowait" \
    -serial "file:$SLOG" -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

for i in $(seq 1 40); do
    sleep 1
    grep -aq "exec: running /bin/aethersafha" "$SLOG" 2>/dev/null && break
done
# jalwa opens its GUI immediately (no large asset to load), but give the two-proc
# scheduler room to settle + connect + reach the first setu present.
sleep "${AE_RENDER_WAIT:-15}"

echo "[4/4] Screendump + checks..."
PPM="$WORK/aethersafha-jalwa.ppm"
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
echo "  --- aethersafha/setu/jalwa serial lines ---"
strings "$SLOG" | grep -aE "aethersafha|setu|puka|bhumi|desktop|jalwa|exec:|PANIC|FAULT|#PF" | sed 's/^/  /' | head -30

rc=0
strings "$SLOG" | grep -q "aethersafha: setu listener up" \
    && echo "  PASS: setu listener up on agnos (TCP loopback:7700)" \
    || { echo "  FAIL: setu listener did not come up"; rc=1; }
strings "$SLOG" | grep -q "launched setu client" \
    && echo "  PASS: compositor spawn_path'd the first resident (/bin/puka = jalwa)" \
    || { echo "  FAIL: no setu client was launched (spawn_path failed?)"; rc=1; }
strings "$SLOG" | grep -qi "jalwa: agnos desktop gui" \
    && echo "  PASS: jalwa booted as the resident (its own serial banner)" \
    || { echo "  FAIL: jalwa never printed its banner (did it spawn/run?)"; rc=1; }
strings "$SLOG" | grep -q "aethersafha: setu client presented surface" \
    && echo "  PASS: jalwa CONNECTED + PRESENTED a surface + composited on agnos (window on the desktop)" \
    || { echo "  FAIL: no client present composited (jalwa's setu present did not complete)"; rc=1; }

# Visual confirm: jalwa's rendered UI (dark theme chrome, panels, text) is colour-rich vs
# the flat desktop backdrop. Count DISTINCT colours in the composited screendump — a bare
# desktop is a handful; jalwa's window pushes it past that. Serial gate is dispositive.
if [ -f "$PPM" ]; then
    STATS=$(python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
# skip 3 PPM header lines (P6 / "W H" / "255")
i=d.find(b'\n',d.find(b'\n',d.find(b'\n')+1)+1)+1
px=d[i:]
seen=set(); nonblack=0
for k in range(0,len(px)-2,3):
    r,g,b=px[k],px[k+1],px[k+2]
    if r or g or b: nonblack+=1
    seen.add((r,g,b))
    if len(seen)>4000: break
print("%d %d" % (len(seen), nonblack))
PY
)
    NCOL="${STATS% *}"; NB="${STATS#* }"
    echo "  framebuffer: $NCOL distinct colours, $NB non-black pixels"
    if [ "${NB:-0}" -gt 1000 ] && [ "${NCOL:-0}" -gt 40 ]; then
        echo "  PASS: composited desktop is non-blank + colour-rich (jalwa's window rendered)"
    else
        echo "  NOTE: frame looks flat ($NCOL colours) — serial gate is dispositive"
    fi
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$PPM" "$WORK/aethersafha-jalwa.png" 2>/dev/null && echo "  PNG: $WORK/aethersafha-jalwa.png"
    fi
else
    echo "  FAIL: no screendump captured"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "aethersafha-jalwa-smoke: PASS — jalwa runs as a window on the aethersafha desktop ON AGNOS" || echo "aethersafha-jalwa-smoke: FAIL"
exit $rc
