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
#           dumpe2fs. Stage first: scripts/burn/stage-agnsh.sh --build + stage-tools.sh.
set -e

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
# through to the in-kernel recovery REPL. stage-agnsh.sh --build produces the agnos-ABI binary.
#
# ⚠ 1.56.60 — THIS COMMENT USED TO CLAIM THE RECOVERY REPL IS DEAF ON A USB-ONLY KEYBOARD
# ("reads keystrokes via kb_has_key() (PS/2 IRQ1) ... the smoke cannot drive it"). THAT IS FALSE
# and it argued against the one capability this smoke most needs. kb_has_key() calls hid_poll()
# directly (arch/x86_64/keyboard.cyr:87-97), the PS/2 path was DELETED on 2026-08-08
# (core/boot_finish.cyr:11-13), and this script's own recovery-shell arm already drives that REPL
# by sendkey. Do not restore the claim.
ROOTFS="$ROOT/build/rootfs"
[ -f "$ROOTFS/bin/agnsh" ] || { echo "ERROR: $ROOTFS/bin/agnsh missing — run scripts/burn/stage-agnsh.sh --build"; exit 1; }
[ -e "$ROOTFS/bin/touch" ] || { echo "ERROR: $ROOTFS/bin/touch missing — run scripts/burn/stage-tools.sh --build"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
echo "shutdown smoke seed" > "$SEED/hello.txt"
# Stage the WHOLE bin tree, not just agnsh. The e2fsck gate is only meaningful if
# the run actually dirties the filesystem, and the write is done with `touch` —
# a kriya symlink. With agnsh alone the touch silently fails "not found", the FS
# stays pristine, and the control run passes e2fsck with the barrier REMOVED,
# which is how this gate was caught being a tautology. -a preserves the symlinks.
cp -a "$ROOTFS/bin/." "$SEED/bin/"

# ⭐ 1.56.60 — SHUTDOWN_SMOKE_NO_AGNSH=1 DRIVES THE IN-KERNEL RECOVERY SHELL INSTEAD OF agnsh.
# Omitting /bin/agnsh makes kybernet_exec_agnsh() fail and kybernet fall through to the recovery
# REPL — the exact state an operator lands in when the userland shell will not start, and the
# state the 2026-09-03 archaemenid report came from. Without this knob the recovery shell's stop
# verbs had NO gate at all: every arm of this smoke drove agnsh, so `halt` in the kernel shell
# could be (and was) a loop-exit sentinel that never touched the power subsystem while every
# gate stayed green. Reproduces the operator's console signature exactly:
#     kybernet: emergency shell (exec rc=-1)
if [ "${SHUTDOWN_SMOKE_NO_AGNSH:-0}" = "1" ]; then
    rm -f "$SEED/bin/agnsh"
    echo "  SHUTDOWN_SMOKE_NO_AGNSH=1: /bin/agnsh omitted — kybernet must fall to the recovery REPL"
fi

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

# Invocation deliberately mirrors scripts/smoke/whirl-smoke.sh, which is the known-good
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
# SHUTDOWN_SMOKE_VERB=reboot exercises the bite-7 reset ladder instead of the plain
# exit path. The oracle is QEMU itself: with -no-reboot it EXITS when the guest
# resets, so "the qemu process is gone" is direct evidence the platform actually
# reset rather than a log line claiming it did.
VERB="${SHUTDOWN_SMOKE_VERB:-exit}"
# -u: python block-buffers stdout when redirected to a file, so every diagnostic
# print is lost if the driver is killed — which is exactly when you need them.
python3 -u - "$MON" "$LOG" "$VERB" "$QPID" <<'PY'
import socket, sys, time, os
mon, log = sys.argv[1], sys.argv[2]
want_verb = sys.argv[3] if len(sys.argv) > 3 else 'exit'
qpid = int(sys.argv[4]) if len(sys.argv) > 4 else 0

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
in_recovery = False
t0 = time.time()
while time.time() - t0 < 120:
    txt = logtext()
    if '[ASSIST]' in txt:
        verb = want_verb; print('  ok: agnsh reached its prompt'); break
    if 'agnos>' in txt:
        # ⭐ 1.56.60 — HONOUR want_verb HERE. This line used to be an unconditional
        # `verb = 'halt'`, which SILENTLY DISCARDED a requested reboot/poweroff and
        # replaced it with the one verb whose oracle asserts nothing. Combined with the
        # halt arm's flush-only assertions, that made this smoke report PASS on exactly
        # the defect the 2026-09-03 operator report describes: a recovery-shell `halt`
        # that flushed, quiesced and then spin-halted a fully powered box. The recovery
        # shell now has real reboot/poweroff/halt builtins (kernel/user/shell.cyr), so
        # pass the request through. It has no `exit` verb — `halt` is its equivalent
        # stop — and any OTHER verb it cannot deliver is a hard FAIL, never a silent
        # substitution: a gate that quietly runs something else than it was asked to
        # is not a gate.
        in_recovery = True
        if want_verb in ('halt', 'poweroff', 'reboot'):
            verb = want_verb
        elif want_verb == 'exit':
            verb = 'halt'
        else:
            print(f'  FAIL: recovery shell cannot deliver verb {want_verb!r}')
            sys.exit(2)
        print(f'  ok: recovery shell reached its prompt (agnsh did not start); driving {verb!r}'); break
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
            # recv() returning EMPTY means the peer CLOSED — it does not raise. On a
            # successful reboot QEMU exits and this loop would otherwise spin forever
            # on b'', hanging the driver at exactly the moment it succeeded.
            if s.recv(65536) == b'':
                return
    except OSError:
        pass

# HMP sendkey takes key NAMES, not characters — a bare space or slash is rejected
# silently, which reads as "the guest ignored the keyboard".
KM = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash',
      '_': 'shift-minus', ':': 'shift-semicolon', '>': 'shift-dot'}

def key(name):
    # A SUCCESSFUL reboot kills the monitor socket underneath us — QEMU exits the
    # moment the guest resets. That is the PASS condition, not an error, so a dead
    # socket must not raise out of the driver. Swallow it and let the caller's own
    # oracle decide.
    try:
        s.sendall(('sendkey ' + name + '\n').encode())
    except OSError:
        return False
    time.sleep(0.10); drain()
    return True

def typ(word):
    # Prime with a throwaway `ret`: the first sendkey after an idle gap is dropped
    # by the xHCI HID warmup, so the real first character would be eaten. Harmless
    # on an empty prompt. Cadence and drain per scripts/smoke/whirl-smoke.sh, which
    # documents both quirks.
    key('ret')
    for ch in word:
        key(KM.get(ch, ch))
    key('ret')

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
# ⭐ 1.56.60 — DIRTY FROM THE RECOVERY SHELL TOO. This was `if verb == 'exit':`, so a
# recovery-shell run reached the e2fsck arm over a filesystem nothing had written — exactly
# the vacuity the comment above says the write exists to prevent, reintroduced for the one
# shell whose stop path had no gate. ⚠ agnsh has `touch`; the recovery REPL does NOT — it has
# `echo >` redirect (kernel/user/shell.cyr:549). Type whichever the DRIVING shell owns, or the
# write silently fails and the gate goes vacuous again in a way that reads as a pass.
if verb == 'exit' or in_recovery:
    write_cmd = 'echo x > /shutmark' if in_recovery else 'touch /shutmark'
    mark = len(logtext())
    if not type_verified(write_cmd, 3.0, 'a filesystem write'):
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
if not ok:
    sys.exit(3)

def qemu_gone(pid):
    # ⚠ os.kill(pid, 0) is NOT a liveness test here. QEMU is a SIBLING of this
    # process — a child of the shell running the smoke — so when it exits it becomes
    # a ZOMBIE until the shell reaps it, and signal 0 to a zombie SUCCEEDS. The
    # obvious check therefore never fires and the arm times out even on a perfect
    # reset. Read the process state instead: 'Z' (or a vanished entry) means gone.
    try:
        with open(f'/proc/{pid}/stat', 'rb') as f:
            fields = f.read().decode('latin1').rsplit(')', 1)[1].split()
        return fields[0] == 'Z'
    except OSError:
        return True

if verb == 'reboot' or verb == 'poweroff':
    # QEMU runs with -no-reboot, so a real platform reset makes it EXIT. An ACPI S5
    # soft-off exits it too. ⚠ For poweroff this proves the PLUMBING ONLY: QEMU's
    # _S5_ package is all zeroes, so SLP_TYP=0 is exactly what it wants and a
    # completely broken decode would pass here. The decode itself is validated
    # against real firmware in prior-art/acpi-s5-known-good-archaemenid-0719.txt. Watching the
    # process die is direct evidence; a log line would only be a claim.
    t0 = time.time()
    while time.time() - t0 < 40:
        if qemu_gone(qpid):
            print(f'  ok: guest {verb} took effect -- qemu exited')
            sys.exit(0)
        time.sleep(0.5)
    print(f'  FAIL: platform never {verb}ed (qemu still running after 40s)')
    if 'power: platform did not reset' in logtext():
        print('         every rung of the reset ladder was tried and declined')
    sys.exit(4)
# Gate on the storage quiesce too, rather than racing it: nvme_shutdown() budgets
# up to ~5 s for CSTS.SHST, so killing the machine a couple of seconds after the
# flush line truncates the log before any of it lands and the absence looks like
# dead code. Not fatal on its own — a box with no NVMe/AHCI still shuts down.
wait_for('power: storage quiesced', 30, 'storage quiesce completed')

# ⭐ 1.56.60 — A REAL STOP ORACLE FOR THE ARMS WHERE QEMU DOES NOT EXIT.
#
# QEMU does not exit on a `hlt` loop, so qemu_gone() above cannot serve these arms and
# until now they asserted NOTHING about the machine stopping — only 'filesystems flushed'
# and 'storage quiesced'. THE BUGGY PATH EMITTED BOTH. A recovery-shell `halt` that
# flushed, quiesced and then spin-halted a powered box with a dead USB keyboard scored a
# clean PASS here, which is why five months of green gates never caught the defect the
# 2026-09-03 archaemenid burn found in one try. That is the "oracle derived from the
# artifact under test" shape the vacuous-gates sweep catalogues.
#
# The fix is to assert a terminus string that ONLY the correct path can emit:
#   'power: halted'   — printed by power_sys (core/power.cyr:428) and NOWHERE else, so it
#                       is positive evidence the verb reached the power subsystem rather
#                       than merely exiting a REPL.
#   'power: stopped --' — printed by power_stop_final (core/power.cyr) on the boot_finish
#                       tail that agnsh `exit` unwinds to. Also unique.
# Neither can be produced by the flush/quiesce pair, which is exactly the point.
if verb == 'halt':
    term = 'power: halted'
    what = 'power_sys reached its halt terminus (the verb entered the power subsystem)'
else:
    term = 'power: stopped --'
    what = 'boot_finish reached power_stop_final (named terminus, latch disarmed)'
if not wait_for(term, 30, what):
    print(f'  FAIL: the machine never reached a named stop terminus ({term!r}) -- it may have '
          f'flushed and quiesced and then simply wedged, which is what this arm used to pass on')
    sys.exit(5)
sys.exit(0)
PY
PYRC=$?
set -e

sleep 12
kill $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

rc=0
if [ "$PYRC" != "0" ]; then
    echo "  FAIL: the shell-exit path did not reach the flush (see $LOG)"; rc=1
fi

dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
# e2fsck's exit code is NOT the cleanliness oracle (see the ⚠ block below) — but it is
# the only signal that separates "checked the filesystem and reached a verdict" from
# "never ran / died mid-pass", and the structural gate at the bottom needs to know the
# difference before it believes its own silence. So CAPTURE it rather than launder it
# away with a bare `|| true`.
FSCKRC=0
e2fsck -fn "$WORK/part-post.img" > "$LOGS/fsck-post.log" 2>&1 || FSCKRC=$?
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
#
# ⚠ VACUITY FLOOR. The damage grep below used to sit inside an `if` whose condition was a
# FORMAT MATCH over e2fsck's own report — and both halves go empty together, so the check
# reported neither PASS nor FAIL and rc was never touched. Reproduced end to end
# (2026-09-02) with nothing but `truncate -s 34M` on the image, i.e. a partition copy
# shorter than the filesystem its superblock describes — a short dd, a full build disk:
#
#     Pass 1: Checking inodes, blocks, and sizes
#     Error reading block 1076 (Attempt to read block ... resulted in short read). ...
#     Error while scanning inodes (3968): Can't read next inode
#     e2fsck: aborted                                    <- exit 8, no Pass 5, no N/M files
#
# Neither `^Pass 5` nor `N/M files` is in that, so the outer if was FALSE, the inner grep
# never ran, and the tail printed NOTHING between the FSSTATE line and the verdict. Worse:
# dumpe2fs still read the (clean) superblock at +1024, so FSSTATE said `clean` and the
# whole smoke exited 0 over a filesystem e2fsck could not read at all. That abort text
# even contains the word "corrupt", which the damage grep matches — the format gate
# short-circuited away the one assertion that would have caught it.
#
# So: prove the check RAN before believing that it found nothing, and PRINT the evidence
# (exit status, report line count, marker) rather than implying it — a run that says
# "0 line(s) of report" is telling you its own parse broke, not that the disk is healthy.
# "We could not check it" and "it is undamaged" must never be the same colour.
#
# The exit status is used ONLY as that liveness signal, never as the damage oracle: 0/1/2/4
# all mean e2fsck finished and judged (the control run — barrier removed, s_state=0x0000 —
# completes and exits 0, so this arm cannot fire on it), while 8 (operational error),
# 16 (usage), 32 (cancelled) and 128+n (killed by a signal) are exactly the statuses under
# which the report goes missing.
FSCKREPORT=0
if grep -qiE "^(\[[^]]*\] )?(Pass 5|.*: [0-9]+/[0-9]+ files)" "$LOGS/fsck-post.log"; then FSCKREPORT=1; fi
FSCKRAN=0
case "$FSCKRC" in 0|1|2|4) FSCKRAN=1 ;; esac
FSCKLINES="$(grep -c . "$LOGS/fsck-post.log" 2>/dev/null || true)"
[ -n "$FSCKLINES" ] || FSCKLINES=0
echo "  e2fsck: exit $FSCKRC, $FSCKLINES line(s) of report, completion marker=$FSCKREPORT"
if [ "$FSCKREPORT" = 1 ] && [ "$FSCKRAN" = 1 ]; then
    if grep -qiE "FIXED|UNEXPECTED|corrupt|Inode .* is invalid" "$LOGS/fsck-post.log"; then
        echo "  FAIL: e2fsck reported structural damage (see $LOGS/fsck-post.log)"; rc=1
    else
        echo "  ok: e2fsck found no structural damage"
    fi
else
    echo "  FAIL: e2fsck never produced a complete report — structural integrity is UNVERIFIED"
    echo "        (exit $FSCKRC, $FSCKLINES line(s), completion marker=$FSCKREPORT; see $LOGS/fsck-post.log)"
    echo "        A missing report is not a clean one. If e2fsck's output format moved, repair the"
    echo "        completion pattern above — do not delete this arm."
    rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "  SHUTDOWN SMOKE: PASS"; else echo "  SHUTDOWN SMOKE: FAIL"; fi
echo "=========================================="
exit $rc
