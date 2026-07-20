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
#   4. require dumpe2fs "Filesystem state: clean" — proof it worked.
#
# ⚠⚠ THE ORACLE IS `dumpe2fs`, NOT `e2fsck`'s EXIT CODE. e2fsck -fn EXITS 0 on an
# unclean-but-structurally-consistent filesystem — the "not cleanly unmounted"
# notice goes to stdout while the status stays 0. An earlier version of this smoke
# gated on that exit code and reported PASS for a control kernel that had left
# s_state=0x0000; only `dumpe2fs -h` ("Filesystem state: not clean") and the raw
# byte at SB+0x3A told the truth. A gate that returns success for the case it
# exists to catch is worse than no gate. Structural consistency is checked
# separately — it is a different question from cleanliness.
#
# VERIFIED BOTH WAYS (2026-07-19): with the barrier, flush line present + state
# clean; with power_flush() removed from boot_finish.cyr, flush line absent +
# state "not clean". The delta is the evidence.
#
# The run must also DIRTY the filesystem before stopping (it types `touch
# /shutmark`), because a never-written ext2 is clean either way — and the write
# needs kriya staged, or `touch` silently fails "not found" and the gate is
# vacuous again.
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, e2fsck,
#           dumpe2fs. Stage first: scripts/stage-agnsh.sh --build + stage-tools.sh.
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

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 e2fsck dumpe2fs dd strings python3; do
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

# Seed from the staged rootfs, never by copying ../agnoshi/build/agnsh directly:
# that path is the HOST (Linux-ABI) build, and deploying it makes /bin/agnsh die on
# its first ring-3 syscall ("alloc_init: mmap failed"), after which kybernet falls
# through to the in-kernel recovery REPL. That REPL reads keystrokes via
# kb_has_key() (PS/2 IRQ1) while hid_poll() — the xHCI USB-HID drain — is on
# agnsh's read path, so on a USB-only QEMU keyboard the recovery shell is deaf and
# the smoke cannot drive it. stage-agnsh.sh --build produces the agnos-ABI binary.
ROOTFS="$ROOT/build/rootfs"
[ -f "$ROOTFS/bin/agnsh" ] || { echo "ERROR: $ROOTFS/bin/agnsh missing — run scripts/stage-agnsh.sh --build"; exit 1; }
[ -e "$ROOTFS/bin/touch" ] || { echo "ERROR: $ROOTFS/bin/touch missing — run scripts/stage-tools.sh --build"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
echo "shutdown smoke seed" > "$SEED/hello.txt"
# Stage the WHOLE bin tree, not just agnsh. The e2fsck gate is only meaningful if
# the run actually dirties the filesystem, and the write is done with `touch` —
# a kriya symlink. With agnsh alone the touch silently fails "not found", the FS
# stays pristine, and the control run passes e2fsck with the barrier REMOVED,
# which is how this gate was caught being a tautology. -a preserves the symlinks.
cp -a "$ROOTFS/bin/." "$SEED/bin/"

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

# Invocation deliberately mirrors scripts/whirl-smoke.sh, which is the known-good
# keyboard-driving harness in this tree — same pflash form, same xhci+usb-kbd pair.
KVM_ARGS=""
[ -w /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"

qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/OVMF_VARS.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-SHUT" \
    -device "qemu-xhci,id=xhci" -device "usb-kbd,bus=xhci.0" \
    -serial "file:$LOG" -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" &
QPID=$!
# shellcheck disable=SC2064
trap "kill $QPID 2>/dev/null || true" EXIT INT TERM

# set -e must not abort here: a FAILING driver is the whole point of the control
# run, and the e2fsck verdict below is the evidence we most need when it fails.
set +e
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

s = None
for _ in range(80):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(mon); break
    except OSError:
        time.sleep(0.25)
if s is None:
    print('  FAIL: no QEMU monitor'); sys.exit(2)
s.settimeout(1.0)

def drain():
    # Read back the monitor's replies. Without this the socket buffer fills and
    # later sendkeys silently stall — the failure looks exactly like "the guest
    # is ignoring the keyboard".
    try:
        while True:
            s.recv(65536)
    except OSError:
        pass

# HMP sendkey takes key NAMES, not characters — a bare space or slash is rejected
# silently, which reads as "the guest ignored the keyboard".
KM = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash',
      '_': 'shift-minus', ':': 'shift-semicolon'}

def typ(word):
    # Prime with a throwaway `ret`: the first sendkey after an idle gap is dropped
    # by the xHCI HID warmup, so the real first character would be eaten. Harmless
    # on an empty prompt. Cadence and drain per scripts/whirl-smoke.sh, which
    # documents both quirks.
    s.sendall(b'sendkey ret\n'); time.sleep(0.10); drain()
    for ch in word:
        s.sendall(('sendkey ' + KM.get(ch, ch) + '\n').encode()); time.sleep(0.10); drain()
    s.sendall(b'sendkey ret\n'); time.sleep(0.10); drain()

# sendkey drops random characters on bursts, so confirm the verb actually echoed
# before judging the result — a dropped key would otherwise read as "the barrier
# never ran" when in truth the command was never typed.
def type_verified(word, settle, label):
    for attempt in range(4):
        mark = len(logtext())
        typ(word)
        time.sleep(settle)
        if word in logtext()[mark:]:
            print(f'  ok: typed {label} (attempt {attempt + 1})')
            return True
        print(f'  retry: {label} did not echo cleanly (attempt {attempt + 1}, dropped key)')
    print(f'  FAIL: could not type {label} into the shell')
    return False

# DIRTY THE FILESYSTEM FIRST. Without this the e2fsck gate below is vacuous: a
# freshly-mkfs'd ext2 that was only ever read comes back clean whether or not
# anything flushed it, so barrier-present and barrier-absent runs are
# indistinguishable. Proven the hard way — the first control run passed e2fsck
# with the barrier removed. Only the write makes the oracle discriminate.
if verb == 'exit':
    mark = len(logtext())
    if not type_verified('touch /shutmark', 3.0, 'a filesystem write'):
        sys.exit(2)
    # Echoing the command is NOT evidence the write happened — a missing binary
    # echoes fine and then fails. That is precisely how this gate was vacuous.
    after = logtext()[mark:]
    bad = [m for m in ('not found', 'No such', 'unknown:', 'cannot') if m in after]
    if bad:
        print(f'  FAIL: the filesystem write did not take ({bad[0]!r} in the reply) '
              f'-- the e2fsck gate below would be meaningless')
        sys.exit(2)
    print('  ok: filesystem dirtied (no error from the write)')

if not type_verified(verb, 2.0, repr(verb)):
    sys.exit(2)

# The barrier's own line. This is the load-bearing assertion: without it the
# e2fsck result below would only be telling us the FS was never dirtied.
ok = wait_for('power: filesystems flushed', 60, 'power_flush ran on the exit path')
sys.exit(0 if ok else 3)
PY
PYRC=$?
set -e

sleep 2
kill $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

rc=0
if [ "$PYRC" != "0" ]; then
    echo "  FAIL: the shell-exit path did not reach the flush (see $LOG)"; rc=1
fi

dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
e2fsck -fn "$WORK/part-post.img" > "$LOGS/fsck-post.log" 2>&1 || true
dumpe2fs -h "$WORK/part-post.img" > "$LOGS/dumpe2fs-post.log" 2>&1 || true

# ⚠ THE ORACLE IS `dumpe2fs`'s "Filesystem state", NOT e2fsck's exit code.
# e2fsck -fn EXITS 0 on an unclean-but-structurally-consistent filesystem: the
# "not cleanly unmounted" notice goes to stdout while the status stays 0. Gating on
# the exit code therefore reports a PASS for exactly the case this smoke exists to
# catch — verified the hard way, a control kernel with the barrier removed left
# s_state=0x0000 ("not clean") and still "passed". Read the state bit instead.
FSSTATE="$(grep -i '^Filesystem state:' "$LOGS/dumpe2fs-post.log" | sed 's/.*: *//')"
echo "  filesystem state after shutdown: ${FSSTATE:-<unreadable>}"
case "$FSSTATE" in
    clean*)
        echo "  PASS: superblock marked cleanly unmounted" ;;
    *)
        echo "  FAIL: superblock is '$FSSTATE' — the durability barrier did not run or did not take"
        rc=1 ;;
esac
# Structural consistency is a separate question from cleanliness; report it too.
if grep -qiE "^(Pass 5|.*: [0-9]+/[0-9]+ files)" "$LOGS/fsck-post.log"; then
    if grep -qiE "FIXED|UNEXPECTED|corrupt|Inode .* is invalid" "$LOGS/fsck-post.log"; then
        echo "  FAIL: e2fsck reported structural damage (see $LOGS/fsck-post.log)"; rc=1
    else
        echo "  ok: e2fsck found no structural damage"
    fi
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "  SHUTDOWN SMOKE: PASS"; else echo "  SHUTDOWN SMOKE: FAIL"; fi
echo "=========================================="
exit $rc
