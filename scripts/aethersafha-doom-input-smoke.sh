#!/bin/sh
# aethersafha-doom-input-smoke.sh — prove DOOM gets FULL key events (press + release)
# on the sovereign desktop, via setu 0.5.0 SETU_SURF_FULL_KEYS.
#
# Same setup as aethersafha-doom-smoke.sh (doom seeded as the first-resident setu client
# on an AETHERSAFHA_SETU_SELFTEST kernel), but with a QEMU USB-xHCI keyboard so HMP
# `sendkey` injects real keystrokes: QEMU key -> agnos USB HID -> bhumi make/break ->
# aethersafha forward_key -> setu -> doom. doom opted into FULL_KEYS, so aethersafha now
# forwards BOTH press and release (previously key-UP was dropped); doom emits a marker per
# event (dsetu-press / dsetu-release). A "dsetu-release" line is the proof: the release is
# no longer dropped, so doom can track HELD keys. TABs are interleaved so focus visits doom
# (aethersafha focuses the last-connected client, which is doom, but be robust).
#
# Gates: doom booted + presented (window on the desktop) AND doom's serial shows BOTH a
# "dsetu-press" and a "dsetu-release" — full make/break delivery end-to-end.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AE_ROOT="${AE_ROOT:-$ROOT/../aethersafha}"
DOOM_ROOT="${DOOM_ROOT:-$ROOT/../cyrius-doom}"
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
WAD="$DOOM_ROOT/wad/DOOM1.WAD"
CRAB="$CRAB_ROOT/build/crab-agnos"
for f in "$GNOBOOT" "$AE" "$WAD" "$CRAB" "$DOOM_ROOT/src/main.cyr"; do [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }; done

# Build DOOM with the key-log diagnostic (DOOM_SETU_KEYLOG) so the serial reports each
# received press/release. The #define must LEAD the compilation unit to reach the #ifdef in
# setu_present.cyr (cyrius -D doesn't cross includes), so prepend it to a temp entry file at
# the doom repo root (where main.cyr's relative includes resolve).
echo "[0/4] Building /bin/puka = DOOM with DOOM_SETU_KEYLOG..."
DOOM="$DOOM_ROOT/build/doom-agnos-keylog"
if ! ( cd "$DOOM_ROOT" && { printf '#define DOOM_SETU_KEYLOG\n'; cat src/main.cyr; } > .keylog-main.cyr \
       && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build --agnos .keylog-main.cyr build/doom-agnos-keylog; r=$?; rm -f .keylog-main.cyr; exit $r ) >/tmp/doom-keylog-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/doom-keylog-build.log)"; tail -8 /tmp/doom-keylog-build.log; exit 1
fi
[ -f "$DOOM" ] || { echo "  ERROR: doom keylog build missing"; exit 1; }
echo "  /bin/puka = doom-agnos-keylog $(stat -c %s "$DOOM") B"

echo "[1/4] Building AETHERSAFHA_SETU_SELFTEST kernel..."
if ! env AETHERSAFHA_SETU_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/ae-doom-in-build.log 2>&1; then
    echo "  BUILD-FAIL (see /tmp/ae-doom-in-build.log)"; tail -5 /tmp/ae-doom-in-build.log; exit 1
fi
echo "  build/agnos $(stat -c %s "$AGNOS") B"

WORK="$ROOT/build/ae-doom-input-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-ae-doom-in.img"; SLOG="$WORK/serial.log"; MON="$WORK/mon.sock"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding ext2 (/bin/puka=DOOM + /DOOM1.WAD + /bin/crab)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AE" "$SEED/bin/aethersafha"; cp "$DOOM" "$SEED/bin/puka"; cp "$WAD" "$SEED/DOOM1.WAD"; cp "$CRAB" "$SEED/bin/crab"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F; mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI; mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AE-DIN -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting with a USB-xHCI keyboard; waiting for DOOM, then injecting keys..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM=""; [ -e /dev/kvm ] && KVM="-enable-kvm -cpu host"; [ -z "$KVM" ] && KVM="-cpu max"
qemu-system-x86_64 -machine q35 -m 512M $KVM \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AE-DIN" \
    -device "qemu-xhci,id=xhci" -device "usb-kbd,bus=xhci.0" \
    -monitor "unix:$MON,server,nowait" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

# Wait until DOOM has PRESENTED its first frame. aethersafha mints a window (and moves
# focus to it) only on PRESENT, not on connect — so keys route to doom only once its
# surface exists. Two clients present here (crab, then doom), so wait for the 2nd
# "presented surface" line; doom is then the last-added window and holds focus.
for i in $(seq 1 120); do
    sleep 1
    [ "$(grep -ac 'setu client presented surface' "$SLOG" 2>/dev/null)" -ge 2 ] && break
    kill -0 $QPID 2>/dev/null || break
done
sleep 3

# Inject a burst of keys via HMP sendkey. Each sendkey = one make + one break, so a single
# key already exercises press AND release. doom is focused (last-connected), so no TAB
# needed. w/up/a/s/d/left/right/ret are keys doom maps.
python3 - "$MON" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.6)
def drain():
    s.setblocking(False)
    try:
        while True:
            if not s.recv(65536): break
    except Exception: pass
    s.setblocking(True)
drain()
def hmp(cmd):
    s.sendall((cmd + "\n").encode()); time.sleep(1.3); drain()
# Hold each key ~400ms so bhumi reliably polls the key-DOWN (press) during the hold AND
# the key-UP (release) after it — a fast default tap can slip its release between polls.
for k in ["w","up","a","s","d","left","right","w","up","w"]:
    hmp("sendkey " + k + " 400")
time.sleep(1.0); s.close()
PY
sleep 2
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null

echo "[4/4] Checks..."
echo "  --- doom / setu key lines ---"
strings "$SLOG" | grep -aE "cyrius-doom|wad loaded|presented surface|dsetu-press|dsetu-release" | sort | uniq -c | sed 's/^/  /' | head -12

rc=0
strings "$SLOG" | grep -q "cyrius-doom" && echo "  PASS: DOOM booted as the resident" || { echo "  FAIL: doom never booted"; rc=1; }
strings "$SLOG" | grep -q "setu client presented surface" && echo "  PASS: DOOM presented its window" || { echo "  FAIL: doom never presented"; rc=1; }
NP=$(strings "$SLOG" | grep -c "dsetu-press"); NR=$(strings "$SLOG" | grep -c "dsetu-release")
echo "  key events reaching doom: $NP press, $NR release"
[ "${NP:-0}" -gt 0 ] && echo "  PASS: DOOM received key PRESS events over setu" || { echo "  FAIL: doom received no key presses (focus? usb-kbd?)"; rc=1; }
if [ "${NR:-0}" -gt 0 ]; then
    echo "  PASS: DOOM received key RELEASE events over setu — the fix works (key-UP no longer dropped; held keys are trackable)"
else
    echo "  FAIL: doom received NO release events — the full-key fix did not deliver key-UP"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "aethersafha-doom-input-smoke: PASS — DOOM gets full make/break key events on the desktop" || echo "aethersafha-doom-input-smoke: FAIL"
exit $rc
