#!/bin/sh
# shutdown-smoke — does stopping agnos leave the filesystem clean?
#
# The gate for the 1.55.x shutdown arc's bite 1 (power_flush, the durability
# barrier). Until it landed, exiting the shell fell straight into `cli; hlt; jmp $`
# with ext2's superblock still marked dirty, so a normal shutdown corrupted the
# mount. This proves the delta rather than asserting it:
#
#   1. build a GPT + FAT-ESP + ext2 image and boot it under OVMF,
#   2. drive agnsh to `exit` via HMP `sendkey` (agnsh reads scancodes from kb_buf,
#      NOT the serial line — piping stdin does nothing, which is why this needs
#      the monitor socket; same mechanism as agnsh-type-test.py),
#   3. require `power: filesystems flushed` in the log — proof the barrier ran,
#   4. require `e2fsck -fn` clean on the extracted partition — proof it worked.
#
# CONTROL: run with SHUTDOWN_SMOKE_CONTROL=1 against a kernel built BEFORE the
# barrier. Step 3 must fail and e2fsck must report "not cleanly unmounted". A pass
# with no control run is not evidence — a freshly-mkfs'd ext2 that was never
# written to is clean whether or not anything flushed it, so this smoke DIRTIES
# the filesystem first (it boots, which journals + writes) and only then stops.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, e2fsck.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 e2fsck dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run sh scripts/build.sh"; exit 1; }

WORK="$ROOT/build/shutdown-smoke"
LOGS="$ROOT/build/shutdown-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-shutdown.img"
LOG="$LOGS/serial.log"
MON="$WORK/mon.sock"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))

EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
echo "shutdown smoke seed" > "$SEED/hello.txt"
[ -f "$ROOT/../agnoshi/build/agnsh" ] && cp "$ROOT/../agnoshi/build/agnsh" "$SEED/bin/agnsh"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-SHUT -b 4096 -m 0 -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"

echo "=========================================="
echo "  agnos shutdown smoke"
echo "=========================================="

# Baseline: the freshly-built image must already be clean, otherwise a "clean"
# verdict at the end proves nothing about the barrier.
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-pre.img" status=none
if e2fsck -fn "$WORK/part-pre.img" > "$LOGS/fsck-pre.log" 2>&1; then
    echo "  ok: baseline image is clean before boot"
else
    echo "  ERROR: baseline image is already dirty — the smoke cannot prove anything"; exit 1
fi

qemu-system-x86_64 -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$WORK/OVMF_VARS.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-SHUT" \
    -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
    -monitor "unix:$MON,server,nowait" \
    -serial "file:$LOG" -display none -no-reboot &
QPID=$!
# shellcheck disable=SC2064
trap "kill $QPID 2>/dev/null || true" EXIT INT TERM

python3 - "$MON" "$LOG" <<'PY'
import socket, sys, time, os
mon, log = sys.argv[1], sys.argv[2]

def logtext():
    try:
        with open(log, 'rb') as f:
            return f.read().decode('utf-8', 'replace')
    except OSError:
        return ''

def wait_for(needle, timeout, what):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if needle in logtext():
            print(f"  ok: {what}")
            return True
        time.sleep(0.5)
    print(f"  TIMEOUT waiting for {what} ({needle!r})")
    return False

# Wait for EITHER shell. agnsh ('[ASSIST] >') is the normal path; if it fails to
# start, kybernet drops to the in-kernel recovery REPL ('agnos>'). Both reach the
# barrier the same way — the REPL ends, kybernet returns, boot_finish flushes —
# so either is a valid driver. The verb differs: agnsh takes 'exit', the recovery
# shell takes 'halt'.
verb = None
t0 = time.time()
while time.time() - t0 < 120:
    txt = logtext()
    if '[ASSIST]' in txt:
        verb = 'exit'; print('  ok: agnsh reached its prompt'); break
    if 'agnos>' in txt:
        verb = 'halt'; print('  ok: recovery shell reached its prompt (agnsh did not start)'); break
    time.sleep(0.5)
if verb is None:
    print('  TIMEOUT: neither agnsh nor the recovery shell reached a prompt')
    sys.exit(2)

for _ in range(60):
    if os.path.exists(mon):
        break
    time.sleep(0.5)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(mon)
time.sleep(1.0)
for ch in list(verb) + ['ret']:
    s.sendall(('sendkey ' + ch + '\n').encode())
    time.sleep(0.25)

# The barrier's own line. This is the load-bearing assertion: without it the
# e2fsck result below would only be telling us the FS was never dirtied.
ok = wait_for('power: filesystems flushed', 60, 'power_flush ran on the exit path')
sys.exit(0 if ok else 3)
PY
PYRC=$?

sleep 2
kill $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

rc=0
if [ "$PYRC" != "0" ]; then
    echo "  FAIL: the shell-exit path did not reach the flush (see $LOG)"; rc=1
fi

dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/fsck-post.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean after shutdown"
else
    echo "  FAIL: e2fsck flagged the post-shutdown image (see $LOGS/fsck-post.log)"
    grep -iE "not cleanly|dirty|VALID" "$LOGS/fsck-post.log" | head -3 | sed 's/^/         /'
    rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "  SHUTDOWN SMOKE: PASS"; else echo "  SHUTDOWN SMOKE: FAIL"; fi
echo "=========================================="
exit $rc
