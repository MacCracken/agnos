#!/bin/sh
# H2 — the arm-once modeset latch. A failed modeset must cost exactly ONE bad boot, not a reflash.
#
# THE CLAIM: boot 1 arms the latch and wedges (the real failure shape: cli; hlt; jmp $). Boot 2, on the SAME
# disk with the SAME binary, finds the latch, REFUSES the modeset, and comes up as a normal log-capturing
# agnos — recovered with the power button, no reflash.
#
# ⚠ WHAT THIS DOES **NOT** PROVE — read before quoting it as validation:
#   * DURABILITY. qemu's `-drive file=...` defaults to cache=writeback, so a guest write lands in the HOST
#     page cache and survives a SIGKILL whether or not a FLUSH was issued. A kernel with blk_flush_on and one
#     without are byte-identical here. This asserts the flush was CALLED, in order, before the risky step —
#     not that a physical platter took it. Durability rests on the code review, not on this script.
#   * THAT BOOT 2's CONSOLE IS ALIVE. QEMU has no DCN; the risky step is synthetic and everything is observed
#     over serial. The iron oracle is separate: boot 2's /klug.txt, read from Linux by mounting
#     /dev/nvme0n1p2 ro, must contain the SKIPPED line. Treating a green run here as validation of the
#     recovery claim is the D-lane mistake in a new costume.
#
# ⚠ IT TAKES TWO RUNS TO GET A GREEN, AND THAT IS DELIBERATE. The wedge lanes need a binary that wedges;
# the disarm lane needs one that does not, so no single invocation can assert both halves. Each run scores
# its own lane and leaves a receipt (build/modeset-latch-receipts/, keyed on VERSION); exit 0 means BOTH
# lanes are green at this version. A run that covered one half exits 3 (PARTIAL) — never 0. See the
# "VACUITY FLOOR — LANE COVERAGE" block below for what a green used to mean before 1.56.58.
#   MODESET_LATCH_SELFTEST=1 sh scripts/build.sh && sh scripts/smoke/modeset-latch-smoke.sh   # wedge lane
#   MODESET_LATCH_DISARM=1   sh scripts/build.sh && sh scripts/smoke/modeset-latch-smoke.sh   # disarm lane
# Exit codes: 0 both lanes green · 1 an assertion failed · 2 HARD FAIL (fail-open) · 3 PARTIAL (one lane).
#
# Build first: MODESET_LATCH_SELFTEST=1 sh scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, debugfs, dd, strings.

set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
# ⚠ `strings` IS IN THIS LIST BECAUSE TWO DECISIONS ARE MADE WITH IT — the MODESET_LATCH_SELFTEST guard
# immediately below, and the lane selection at "TWO BUILDS, TWO LANE SETS". With strings absent from PATH
# the guard's `! strings … | grep -q` is true for the wrong reason (the pipeline died, it did not fail to
# match) and the script tells the operator to rebuild a binary that was already correct; the lane selector
# has no `!` and would silently pick the wedge lane for a disarm binary.
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
# ⚠ Necessary, NOT sufficient — a strings guard cannot prove the call was emitted; that exact false pass
# already shipped once. Every real gate below is a RUNTIME assertion.
if ! strings "$AGNOS" | grep -q "modeset: RISKY STEP entered"; then
    echo "ERROR: kernel not built with MODESET_LATCH_SELFTEST=1" >&2
    echo "       MODESET_LATCH_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/modeset-latch-smoke"; LOGS="$ROOT/build/modeset-latch-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
PART_OFFSET=$(( 33 * 1048576 )); PART_BLOCKS=$(( 67 * 1048576 / 4096 ))
SEED="$WORK/seed"; mkdir -p "$SEED"; echo "modeset latch seed" > "$SEED/hello.txt"

mk_img() {  # $1 = output path, $2 = mkfs feature set
    dd if=/dev/zero of="$1" bs=1M count=128 status=none
    parted -s "$1" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB
    sgdisk -t 2:8300 "$1" >/dev/null
    mformat -i "$1"@@1048576 -F
    mmd -i "$1"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$1"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$1"@@1048576 "$AGNOS" ::boot/agnos
    mkfs.ext2 -F -q -L AGNOS-MLATCH -b 4096 -m 0 -O "$2" -d "$SEED" -E offset=$PART_OFFSET "$1" $PART_BLOCKS
}
RW_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"
# uninit_bg sets ro_compat 0x10 -> agnos mounts READ-ONLY (ext2_write_ok = 0). That is the fail-closed lane.
RO_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,uninit_bg"

boot() {  # $1 = img, $2 = vars, $3 = logfile, $4 = timeout ; echoes exit code
    # ⚠ `-serial file:` NOT `-serial stdio`. Boot 1 ends in a deliberate wedge and is killed with SIGKILL;
    # under stdio the last lines sit in QEMU's HOST-side buffer and die with it, truncating exactly the
    # lines that prove the arm happened. A guest-side delay cannot fix that — the bytes have already left
    # the guest. file: writes straight through, so the capture survives the kill.
    timeout -s KILL "$4" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$2" \
        -drive "file=$1,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-MLATCH" \
        -serial "file:$3" -display none -no-reboot >/dev/null 2>&1
    echo $?
}
latch_payload() {  # $1 = img -> stdout
    dd if="$1" bs=1M skip=33 count=67 of="$WORK/part.img" status=none
    debugfs -R "cat /.modeset-armed" "$WORK/part.img" 2>/dev/null
}

# ⚠ TWO BUILDS, TWO LANE SETS. The wedge lanes need a binary that WEDGES; the disarm lane needs one that
# does not. Running both sets against either binary produces failures that mean nothing except "wrong
# build" — which is noise that trains you to ignore red. Detect the build and run only its lanes.
DISARM_BUILD=0
strings "$AGNOS" | grep -q "modeset: pathmatch positive OK" && DISARM_BUILD=1
if [ "$DISARM_BUILD" = 1 ]; then LANE=disarm; OTHER=wedge; else LANE=wedge; OTHER=disarm; fi

# ⛔⛔ VACUITY FLOOR — LANE COVERAGE. THE ORACLE FOR *WHICH ASSERTIONS RUN* IS READ OUT OF THE BINARY
# UNDER TEST, so the artifact gets a vote on which assertions are allowed to judge it. Until 1.56.58 the
# unselected half was a bare `echo "SKIP: …"` that touched neither `pass` nor `fail`, and the verdict line
# could not tell a lane that held from a lane that never ran:
#   · a disarm-marked binary retired the whole wedge/control/read-only block — ~31 assertions INCLUDING
#     the read-only lane's fail-CLOSED gate, which is the ONLY assertion in this file that can set hard=1
#     and exit 2 — and the run still printed "8 passed, 0 failed" and exited 0. "The fail-open detector
#     held" and "the fail-open detector was never run" came out the same colour, which is the header's own
#     D-lane mistake wearing a third costume.
#   · the default SELFTEST build retired the disarm lane's 8 assertions the same silent way.
#   · and a lane that DID run but scored nothing — a renamed log path, boots that all died before writing,
#     a helper that stopped being called — printed "0 passed, 0 failed" and exited 0 as well.
# ⇒ Three changes, none of which alter what any assertion tests:
#   (1) each lane counts the assertions it actually scored and is held to a FLOOR;
#   (2) the count and the floor are PRINTED, not implied — a run that says "the wedge lane scored 2
#       assertion(s)" is reporting that its own enumeration broke, not that the kernel is clean;
#   (3) exit 0 requires BOTH lanes green. No single invocation can assert both halves — they need two
#       different binaries — so the other half's green is carried in a RECEIPT under
#       build/modeset-latch-receipts/, keyed on VERSION and rewritten (or DELETED) by every run of that
#       lane. A run covering one half exits 3 (PARTIAL) and prints no success token, because
#       "we could not test it" and "it works" must never be the same colour
#       (scripts/smoke/console-line-smoke.sh:15-17, which resolves the same fork the same way).
#
# ⚠ FLOORS ARE FLOORS, NOT EQUALITIES, and they are deliberately close under the real counts (31-32 and 8
# on a healthy run) so that losing a whole sub-lane — boot 2, control B, the read-only lane — trips them.
# Adding assertions may raise them; a change that LOWERS one is removing coverage and should say so.
WEDGE_MIN=28
DISARM_MIN=7
# ⚠ Receipts live under build/ but NOT under $WORK/$LOGS, which are rm -rf'd at the top of every run — the
# whole point is that they outlive the rebuild the other lane requires. scripts/build.sh only `mkdir -p`s
# build/ and removes named artifacts, so a rebuild does not clear them; build/ is gitignored (line 2), so
# they are never committed. Keyed on VERSION because the two lanes are two builds of the SAME source cut:
# a version bump correctly invalidates both halves and forces them to be re-run.
VER="$(cat "$ROOT/VERSION" 2>/dev/null)"
[ -n "$VER" ] || { echo "ERROR: cannot read $ROOT/VERSION — lane receipts are keyed on it" >&2; exit 1; }
RECEIPTS="$ROOT/build/modeset-latch-receipts"; mkdir -p "$RECEIPTS"

pass=0; fail=0; hard=0
P() { echo "PASS: $1"; pass=$((pass+1)); }
F() { echo "FAIL: $1"; fail=$((fail+1)); }
has() { grep -aq "$2" "$1"; }
want()  { if has "$1" "$2"; then P "$3"; else F "$4"; fi; }
wantno(){ if has "$1" "$2"; then F "$4"; else P "$3"; fi; }

WEDGE_SCORED=0; DISARM_SCORED=0
_scored_before=$((pass+fail))
if [ "$LANE" = disarm ]; then
    echo "NOT RUN: wedge/control/read-only lanes — this binary carries the MODESET_LATCH_DISARM marker."
    echo "         That retires ~31 assertions, the fail-CLOSED gate among them. Scored as coverage lost,"
    echo "         not as a skip — see '=== lane coverage ===' below."
else
echo "=== BOOT 1 — fresh disk: arm, then wedge ==="
mk_img "$WORK/main.img" "$RW_FEATURES"
cp "$OVMF_VARS_SRC" "$WORK/vars1.fd"; chmod +w "$WORK/vars1.fd"
RC1=$(boot "$WORK/main.img" "$WORK/vars1.fd" "$LOGS/boot1.log" 25)
grep -aE "^(\[[^]]*\] )?modeset:" "$LOGS/boot1.log" | sed 's/^/  /'

want   "$LOGS/boot1.log" "modeset: no latch -- proceeding" "boot1: no latch on a fresh disk" "boot1: expected 'no latch -- proceeding'"
# ⛔ 1.56.38 — A BOOT WITH NO GPU MUST NOT ARM THE LATCH. main.cyr now runs mdo_native() at boot to take
# the console native; under QEMU there is no DCN, so it must refuse at the gpu_present gate BEFORE
# modeset_arm(11). If it ever armed here, every headless/QEMU boot would strand a latch and the NEXT boot
# would refuse modesets for a write that never happened — the exact friction this cut exists to remove,
# reintroduced from the other end.
wantno "$LOGS/boot1.log" "modeset: latch armed at site=11" \
       "boot1: the boot-native modeset did NOT arm the latch with no GPU (gpu_present precedes the arm)" \
       "boot1: boot-native armed the latch under QEMU — a headless boot would strand a latch every time"
# 1.56.38: the boot-time PAN arms at site 12 and must be gated identically. It only runs after a successful
# native modeset, so with no GPU it should never be reached at all — but assert it rather than infer it,
# because "unreachable" is exactly the kind of claim that stops being true when a call site moves.
wantno "$LOGS/boot1.log" "modeset: latch armed at site=12" \
       "boot1: the boot-time pan did NOT arm the latch with no GPU" \
       "boot1: boot-pan armed the latch under QEMU — a headless boot would strand a latch every time"
wantno "$LOGS/boot1.log" "gpu: boot console PANS in hardware" \
       "boot1: no false 'boot console PANS' with no DCN present" \
       "boot1: claimed a hardware-panned console under QEMU — mdo_pan returned 0 with no GPU"
# And it must not claim a native console it could not have produced.
wantno "$LOGS/boot1.log" "gpu: boot console is NATIVE" \
       "boot1: no false 'boot console is NATIVE' with no DCN present" \
       "boot1: claimed a native boot console under QEMU — mdo_native returned 0 with no GPU"
want   "$LOGS/boot1.log" "modeset: latch consts BLOCKED=1 ARMED=1 TOKEN=1297040453" \
       "boot1: module constants are intact (not collapsed to 0 by the gvar-init defect)" \
       "boot1: the constants line is missing or changed — a constant may read 0"
want   "$LOGS/boot1.log" "modeset: latch flushed" "boot1: the durability flush was CALLED before the risky step" "boot1: no flush — the latch write was never barriered"
# These two lines are emitted immediately before the wedge, so they may be lost to FIFO truncation. The
# DECISIVE evidence that both happened is on the platter (an ARMED record) and in rc1=137 (it hung).
want   "$LOGS/boot1.log" "modeset: latch armed at site=5" "boot1: the latch armed" "boot1: the arm line did not survive the wedge (see platter assertions below)"
want   "$LOGS/boot1.log" "modeset: RISKY STEP entered" "boot1: the risky step ran" "boot1: the risky-step line did not survive the wedge (see rc1)"
wantno "$LOGS/boot1.log" "modeset: last session did not end cleanly" "boot1: did NOT report a stale latch" "boot1: reported a stale latch on a fresh disk"
# Load-bearing: proves the wedge happened MID-BOOT rather than after everything already succeeded.
wantno "$LOGS/boot1.log" "Launching kybernet" "boot1: wedged before the boot tail (the wedge really wedged)" "boot1: reached kybernet — the wedge did not wedge"
if [ "$RC1" = 137 ]; then P "boot1: killed by SIGKILL (rc=137) — it hung as intended"; else F "boot1: rc=$RC1, expected 137 — qemu exited on its own, so nothing wedged"; fi

P1=$(latch_payload "$WORK/main.img")
# ⚠ 63, not 64: command substitution strips the record's trailing newline. Assert the on-disk SIZE
# separately via debugfs stat, which sees the real byte count.
if [ "${#P1}" = 63 ]; then P "boot1: the on-disk record body is 63 chars + the stripped trailing newline"; else F "boot1: on-disk record body is ${#P1} chars, expected 63"; fi
RSZ=$(debugfs -R "stat /.modeset-armed" "$WORK/part.img" 2>/dev/null | grep -oE "Size: [0-9]+" | head -1 | grep -oE "[0-9]+")
if [ "${RSZ:-0}" = 64 ]; then P "boot1: the on-disk file is exactly 64 bytes"; else F "boot1: on-disk file is ${RSZ:-?} bytes, expected 64"; fi
case "$P1" in
  "AGNOS-MODESET-LATCH1 A site=0000000005 ticks="*) P "boot1: the platter holds an ARMED record with site=5" ;;
  *) F "boot1: unexpected on-disk record: [$P1]" ;;
esac
# Cross-check two INDEPENDENT channels: the ticks the kernel logged vs the ticks on the platter.
# ⚠ The PLATTER is the authority here, not boot 1's log. A wedge can truncate the tail of the serial
# capture (the UART FIFO dies with the CPU), so an assertion keyed on the log would be testing the harness.
TDRAW=$(echo "$P1" | sed -n 's/.*ticks=\([0-9]\{10\}\).*/\1/p')
TD=$(echo "$TDRAW" | sed 's/^0*//')
if [ -n "$TDRAW" ]; then P "boot1: the platter record carries a ticks field ($TD)"; else F "boot1: no ticks field in the on-disk record"; fi
# If the log DID survive, cross-check the two independent channels. If it did not, say so rather than fail.
T1=$(grep -ao "armed at site=5 ticks=[0-9]*" "$LOGS/boot1.log" | head -1 | sed 's/.*ticks=//')
if [ -n "$T1" ]; then
    if [ "$T1" = "$TD" ]; then P "boot1: logged ticks ($T1) == platter ticks ($TD) — two independent channels agree"; else F "boot1: logged ticks [$T1] != platter ticks [$TD]"; fi
elif has "$LOGS/boot1.log" "modeset: latch armed at site=5"; then
    # ⛔ NOT the truncation case. The arm line IS in the capture and the `ticks=<digits>` field could not be
    # read out of it — that is a FORMAT CHANGE, and it silently retires the only two-independent-channel
    # cross-check in this file (the grep at the top of this block is keyed on the literal
    # `armed at site=5 ticks=`). Before 1.56.58 both outcomes fell into the same unscored NOTE, so a
    # renamed field turned the cross-check into a no-op that neither passed nor failed and left the run
    # green — exactly the rot this cross-check exists to catch.
    F "boot1: the arm line survived but carries no parsable 'ticks=<digits>' — the cross-channel check has rotted, not been truncated"
else
    # The genuinely inconclusive case: the UART FIFO died with the CPU. This is NOT scored here and does
    # not need to be — the surviving-arm-line assertion above (want 'modeset: latch armed at site=5')
    # has already recorded a FAIL for the same capture, so the run cannot be green on the strength of
    # this branch. Say which oracle is authoritative and move on.
    echo "NOTE: boot1's arm line did not survive the wedge in the serial capture; the platter record is the oracle."
fi

echo ""
echo "=== BOOT 2 — SAME disk, SAME binary: must skip ==="
RC2=$(boot "$WORK/main.img" "$WORK/vars1.fd" "$LOGS/boot2.log" 40)
grep -aE "^(\[[^]]*\] )?modeset:" "$LOGS/boot2.log" | sed 's/^/  /'

want   "$LOGS/boot2.log" "modeset: last session did not end cleanly -- modeset SKIPPED this boot" "boot2: ★ the latch was found and the modeset SKIPPED" "boot2: the latch was not detected — H2 does not work"
want   "$LOGS/boot2.log" "modeset: RISKY STEP refused by latch" "boot2: ★ the risky step was REFUSED" "boot2: the risky step was not refused"
wantno "$LOGS/boot2.log" "modeset: RISKY STEP entered" "boot2: ★ the risky step did NOT run" "boot2: the risky step RAN AGAIN — this is the unbounded-loop failure"
wantno "$LOGS/boot2.log" "modeset: latch armed at site=" "boot2: did not re-arm" "boot2: re-armed while blocked"
wantno "$LOGS/boot2.log" "modeset: verified good, latch cleared" "boot2: ★ the kernel did NOT auto-disarm" "boot2: the kernel auto-disarmed — that is the oscillator failure"
# ⭐ 1.56.38 — the recovery line changed MEANING, not just wording. It used to read "recover by typing:
# rm /.modeset-armed", i.e. a chore handed to the operator; the disarm now happens at clean shutdown
# (power.cyr), so a surviving latch states a FACT — the last session did not end cleanly — and tells the
# operator what this boot will do about it. Asserting the new line keeps the guarantee that a blocked boot
# still EXPLAINS ITSELF, without re-teaching the habit of clearing a safety interlock by hand.
want   "$LOGS/boot2.log" "modeset: this boot runs the inherited mode; a clean shutdown clears it" \
       "boot2: ★ the blocked boot explains itself AND names the automatic way out (clean shutdown)" \
       "boot2: the blocked boot printed no explanation of what happens next"
want   "$LOGS/boot2.log" "Launching kybernet" "boot2: ★ reached the boot tail — the recovery boot is a NORMAL boot" "boot2: did not reach kybernet — recovery boot is not usable"
# Proves boot 2 read boot 1's BYTES, not merely its own intent.
if grep -a "modeset: latch was" "$LOGS/boot2.log" | grep -q "ticks=${TDRAW:-__none__}"; then P "boot2: ★ re-emitted boot 1's record verbatim (ticks=$TD) — it read the PLATTER, not its own intent"; else F "boot2: the re-emitted record does not carry boot 1's platter ticks ($TDRAW)"; fi
P2=$(latch_payload "$WORK/main.img")
if [ "$P2" = "$P1" ]; then P "boot2: the latch is still on the platter, byte-identical"; else F "boot2: the latch changed or vanished"; fi
# S7 — boot 2 must not erase boot 1's spilled log.
if debugfs -R "stat /klug-2.txt" "$WORK/part.img" 2>&1 | grep -q "Inode:"; then P "boot2: spilled to /klug-2.txt, leaving boot 1's log intact (S7)"; else F "boot2: no /klug-2.txt — boot 2 would have overwritten boot 1's log"; fi

echo ""
echo "=== CONTROL B — fresh disk, SAME firmware NVRAM: must NOT skip ==="
# If this boot skips, the latch is riding in something other than the filesystem and the design is not what
# it claims. This is the control the whole mechanism turns on.
mk_img "$WORK/fresh.img" "$RW_FEATURES"
RCB=$(boot "$WORK/fresh.img" "$WORK/vars1.fd" "$LOGS/ctlB.log" 25)
want   "$LOGS/ctlB.log" "modeset: no latch -- proceeding" "controlB: a fresh disk with the SAME firmware NVRAM does NOT skip — the latch lives on the filesystem" "controlB: skipped on a fresh disk — the latch is persisting somewhere else"
wantno "$LOGS/ctlB.log" "modeset: last session did not end cleanly" "controlB: no stale-latch report" "controlB: reported a stale latch on a fresh disk"

echo ""
echo "=== READ-ONLY LANE — the fail-closed gate ==="
mk_img "$WORK/ro.img" "$RO_FEATURES"
cp "$OVMF_VARS_SRC" "$WORK/varsro.fd"; chmod +w "$WORK/varsro.fd"
RCR=$(boot "$WORK/ro.img" "$WORK/varsro.fd" "$LOGS/ro.log" 40)
grep -aE "^(\[[^]]*\] )?modeset:" "$LOGS/ro.log" | sed 's/^/  /'
want   "$LOGS/ro.log" "modeset: latch fs not writable -- REFUSING modeset" "ro: refused because the latch surface is not writable" "ro: did not refuse — the lane may not have achieved a read-only mount"
if has "$LOGS/ro.log" "modeset: RISKY STEP entered"; then
    echo ""
    echo "############################################################"
    echo "## FAIL-OPEN: the risky step ran with NO usable latch.     ##"
    echo "## The design is fail-OPEN and MUST NOT be flashed,        ##"
    echo "## regardless of how green the two-boot lane is.           ##"
    echo "############################################################"
    fail=$((fail+1)); hard=1
else
    P "ro: ★ the risky step did NOT run without a usable latch (fail-CLOSED)"
fi
want   "$LOGS/ro.log" "Launching kybernet" "ro: refusing did not itself wedge the boot" "ro: refusing wedged the boot"

fi   # end wedge/control/ro lanes
WEDGE_SCORED=$((pass+fail-_scored_before))

echo ""
echo "=== DISARM LANE (separate binary) ==="
_scored_before=$((pass+fail))
if [ "$LANE" = disarm ]; then
    mk_img "$WORK/dis.img" "$RW_FEATURES"
    cp "$OVMF_VARS_SRC" "$WORK/varsd.fd"; chmod +w "$WORK/varsd.fd"
    RCD=$(boot "$WORK/dis.img" "$WORK/varsd.fd" "$LOGS/disarm.log" 40)
    grep -aE "^(\[[^]]*\] )?modeset:" "$LOGS/disarm.log" | sed 's/^/  /'
    want "$LOGS/disarm.log" "modeset: pathmatch positive OK" "disarm: the path predicate accepts the latch path" "disarm: the path predicate rejected its own path"
    want "$LOGS/disarm.log" "modeset: pathmatch negative OK" "disarm: the path predicate REJECTS a neighbouring path" "disarm: the predicate matched a non-latch path — every rm would become a disarm"
    want "$LOGS/disarm.log" "modeset: verified good, latch cleared" "disarm: ★ the latch was removed, flushed and verified gone" "disarm: the disarm did not complete"
    # ⛔⛔ THE ASSERTION THIS LANE WAS MISSING UNTIL 2026-07-31, AND ITS ABSENCE COST TWO IRON BOOTS.
    # Everything above proves the CLEANUP. None of it asks the only question an operator cares about:
    # after the recovery the kernel itself prints — `rm /.modeset-armed` — does arming work again?
    # It did not, in two independent ways, and both were invisible to a file-is-gone check:
    #   (1) modeset_disarm left modeset_latch_blocked = 1, so on a BLOCKED boot every later arm refused
    #       with "latch already blocked this boot" — right after printing "verified good, latch cleared";
    #   (2) it zeroed modeset_latch_ino and nothing re-created it, so even on a CLEAN boot every later
    #       arm refused with "latch surface unusable".
    # ⇒ Assert the RECOVERED state, not the cleanup. A recovery path nobody re-arms after is untested.
    want   "$LOGS/disarm.log" "modeset: re-arm after disarm OK" "disarm: ★★ arming WORKS again after the operator's rm — the printed recovery is real" "disarm: arming is DEAD after a disarm — the recovery the kernel advertises does not recover"
    wantno "$LOGS/disarm.log" "modeset: re-arm after disarm FAILED" "disarm: no re-arm failure reported" "disarm: the kernel itself reported that re-arming is broken"
    wantno "$LOGS/disarm.log" "modeset: arm refused -- latch surface unusable" "disarm: the latch surface survived the disarm (re-created on demand)" "disarm: the surface was destroyed by the disarm and never re-created"
    # ⛔ THIS EXTRACTION IS UNCONDITIONAL, AND THAT IS THE FIX. Until 1.56.58 the outer test here read
    # $WORK/part.img BEFORE extracting it — and in a disarm build $WORK/part.img has never been written,
    # because latch_payload() is only ever called from the wedge lane, which by construction did not run.
    # $WORK is rm -rf'd at the top of every run, so the file was simply absent: debugfs printed no
    # "Inode:", the `else` fired, and the lane scored `P "gone from the platter"` having read no image at
    # all. It asserted the absence of a file in a filesystem that was not there.
    dd if="$WORK/dis.img" bs=1M skip=33 count=67 of="$WORK/part.img" status=none
    # ⚠ POSITIVE CONTROL, for the same reason. "debugfs found no /.modeset-armed" and "debugfs could not
    # read this image at all" produce identical output, so the absence only means something once a file we
    # KNOW is there has been seen. mk_img seeds /hello.txt into every image via $SEED; if that is not
    # visible, the platter read is broken and the disarm verdict below would be vacuous.
    if debugfs -R "stat /hello.txt" "$WORK/part.img" 2>&1 | grep -q "Inode:"; then
        P "disarm: the platter is readable (the seeded /hello.txt is visible) — an absence here means something"
        if debugfs -R "stat /.modeset-armed" "$WORK/part.img" 2>&1 | grep -q "Inode:"; then F "disarm: /.modeset-armed still on the platter"; else P "disarm: /.modeset-armed is gone from the platter"; fi
    else
        F "disarm: cannot read the disarm image's filesystem (seeded /hello.txt not found) — 'the latch is gone' would be unprovable"
    fi
else
    echo "NOT RUN: the disarm lane — this binary has no MODESET_LATCH_DISARM marker."
    echo "         Scored as coverage lost, not as a skip — see '=== lane coverage ===' below."
fi
DISARM_SCORED=$((pass+fail-_scored_before))

echo ""
echo "=== lane coverage ==="
if [ "$LANE" = wedge ]; then
    SCORED=$WEDGE_SCORED; MIN=$WEDGE_MIN
    OTHER_MIN=$DISARM_MIN
    OTHER_CMD="MODESET_LATCH_DISARM=1 sh scripts/build.sh && sh scripts/smoke/modeset-latch-smoke.sh"
else
    SCORED=$DISARM_SCORED; MIN=$DISARM_MIN
    OTHER_MIN=$WEDGE_MIN
    OTHER_CMD="MODESET_LATCH_SELFTEST=1 sh scripts/build.sh && sh scripts/smoke/modeset-latch-smoke.sh"
fi
echo "  lane run:  $LANE — $SCORED assertion(s) scored (floor $MIN)"
if [ "$SCORED" -lt "$MIN" ]; then
    F "lane coverage: the $LANE lane scored $SCORED assertion(s), floor is $MIN — it ran and enumerated (almost) nothing, which is a broken harness, not a clean kernel"
fi
[ "$LANE" = disarm ] && echo "  ⚠ this run says NOTHING about fail-open: the read-only lane's fail-CLOSED gate is in the other lane."

# A run that is not green must not leave a green receipt behind for the next run to inherit.
if [ "$fail" -eq 0 ] && [ "$hard" = 0 ]; then
    printf 'lane=%s version=%s scored=%s date=%s\n' \
        "$LANE" "$VER" "$SCORED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RECEIPTS/$LANE"
    echo "  receipt:   wrote $RECEIPTS/$LANE"
else
    rm -f "$RECEIPTS/$LANE"
    echo "  receipt:   REMOVED $RECEIPTS/$LANE (this run was not green)"
fi

OTHER_OK=0
if [ -f "$RECEIPTS/$OTHER" ]; then
    OTHER_LINE="$(cat "$RECEIPTS/$OTHER" 2>/dev/null)"
    OTHER_VER="$(printf '%s' "$OTHER_LINE" | sed -n 's/.*version=\([^ ]*\).*/\1/p')"
    OTHER_SCORED="$(printf '%s' "$OTHER_LINE" | sed -n 's/.*scored=\([0-9]*\).*/\1/p')"
    echo "  other lane ($OTHER): $OTHER_LINE"
    if [ "$OTHER_VER" = "$VER" ] && [ -n "$OTHER_SCORED" ] && [ "$OTHER_SCORED" -ge "$OTHER_MIN" ]; then
        OTHER_OK=1
    elif [ "$OTHER_VER" != "$VER" ]; then
        echo "  other lane ($OTHER): receipt is for version $OTHER_VER, this tree is $VER — stale, not counted"
    else
        echo "  other lane ($OTHER): receipt scored ${OTHER_SCORED:-?}, below its floor $OTHER_MIN — not counted"
    fi
else
    echo "  other lane ($OTHER): NO RECEIPT — that half has never been green at $VER"
fi

echo ""
[ "$hard" = 1 ] && { echo "=== modeset-latch-smoke: HARD FAIL (fail-open) ==="; exit 2; }
[ "$fail" -ne 0 ] && { echo "=== modeset-latch-smoke: $pass passed, $fail failed ==="; exit 1; }
if [ "$OTHER_OK" != 1 ]; then
    echo "=== modeset-latch-smoke: PARTIAL — the $LANE lane is green ($SCORED assertions), the $OTHER lane has not run at $VER ==="
    echo "    Half the property is untested, so this is not a green. Build the other half and run again:"
    echo "      $OTHER_CMD"
    exit 3
fi
echo "=== modeset-latch-smoke: $pass passed, 0 failed — both lanes green at $VER ==="
exit 0
