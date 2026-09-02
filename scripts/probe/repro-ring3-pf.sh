#!/bin/bash
# repro-ring3-pf.sh — boots the REAL agnsh kernel N times under qemu `-d int`
# and tallies ring-3 page faults (the CR2=0x10000000 / CR2=0x8 faults that
# freeze agnsh after its banner, per
# docs/development/issue/2026-06-04-agnsh-ring3-pf-pmm-fragmentation.md).
#
# A ring-3 #PF in QEMU's `-d int` trace is a `v=0e` (vector 14 = #PF) record
# whose CPL is 3. QEMU prints the exception header then a register dump that
# includes `CPL=N`; we treat a #PF record as ring-3 when its block reports
# CPL=3. We also independently tally the two signature CR2 values from the
# issue (0x10000000 = the present-supervisor arena fault, 0x8 = the NULL chain).
#
# Usage: sh scripts/probe/repro-ring3-pf.sh <label> <N>
# Reuses one disk image across all N boots; only KASLR (RDRAND-seeded per boot)
# varies, which is exactly the run-to-run layout nondeterminism under test.
#
# Exit: 0 = PASS (no ring-3 #PF across at least one boot that produced evidence)
#       1 = REPRODUCED (at least one boot took a ring-3 #PF)
#       2 = INCONCLUSIVE (no boot produced evidence — nothing was measured)
# ⚠ Until 1.56.58 the verdict was a trailing `[ ... ] && echo PASS || echo REPRO`,
# so the exit status was the echo's — 0 in BOTH branches. A caller could not tell
# a clean 20-boot sweep from a 20-boot reproduction. It can now.
#
# ⚠ VACUITY FLOOR. This probe's verdict is "count of ring-3 #PF boots == 0", which
# is the archetypal assertion that scores PASS on an empty input set. Three ways
# it did exactly that before 1.56.58, all reproduced with a stubbed qemu:
#   · qemu never launched (bad args, `-d int` unsupported by the build, killed in
#     firmware by QEMU_TIMEOUT). `$INT` is never created; `grep -c ... 2>/dev/null`
#     on a missing file yields nothing, the `[ -z ]` guard turns that into 0, every
#     boot scores "clean", and the run printed
#         TALLY [empty] N=5 : ring3-PF-boots=0  clean-boots=5  reached-exec=0
#         REPRO: 0 ring-3 #PF / 5 boots — PASS
#     having read five files that do not exist. Note `reached-exec=0` printing one
#     line above the word PASS: the script already COMPUTED the non-vacuity counter
#     and then never tested it.
#   · the guest booted and traced, but never reached the agnsh exec. The fault under
#     test is a RING-3 fault inside agnsh; a boot that never entered agnsh cannot
#     exhibit it, so scoring it "clean" is a false negative, not a clean boot.
#   · N=0, or an N that is not a number (`seq: invalid floating point argument`).
#     Zero iterations, zero faults, "REPRO: 0 ring-3 #PF / 0 boots — PASS".
# So each boot must now PROVE it was observable before it is allowed to vote, and a
# sweep in which no boot proved that exits 2 instead of announcing a clean tree.
set -u

LABEL="${1:-repro}"
N="${2:-20}"

# ⚠ N IS THE ENUMERATION, AND AN ENUMERATION OF ZERO IS THE VACUITY. Floor it here
# rather than letting `seq 1 "$N"` fail into an empty loop, which is silent (seq's
# error goes to stderr, the tally prints zeros, and the verdict says PASS).
case "$N" in
    ''|*[!0-9]*) echo "ERROR: N must be a positive integer, got '$N'" >&2; exit 2 ;;
esac
[ "$N" -ge 1 ] || { echo "ERROR: N must be >= 1; a 0-boot sweep proves nothing" >&2; exit 2; }

# ⚠ MEASURED, NOT GUESSED. Every one of the 20 real `-d int` logs left behind by the
# 1.56.x integrated sweep (build/repro-ring3-logs/integrated-*.int) carries between
# 3901 and 3907 `v=NN` exception records and weighs ~5.2 MB — OVMF alone emits
# thousands before the kernel is even loaded. A log with fewer than 100 is not a
# quiet boot, it is a boot that did not happen. Set two orders of magnitude below
# the measured floor so this can never cry wolf on a genuinely quiet run.
# ⚠ DELIBERATELY NOT `${TRACE_FLOOR:-100}`. An env override on a vacuity floor is a
# way to switch the vacuity back on: `TRACE_FLOOR=0` restores, exactly, the bug this
# constant exists to close. A floor a caller can lower to zero is not a floor.
TRACE_FLOOR=100

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built ($AGNSH)"; exit 1; }

WORK="$ROOT/build/repro-ring3"; LOGS="$ROOT/build/repro-ring3-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-agnsh.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AGNSH" "$SEED/bin/agnsh"
echo "seeded /bin/agnsh ($(stat -c%s "$SEED/bin/agnsh") bytes)"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AGNSH -b 4096 -m 0 \
    -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

pf3=0; cr2_10=0; cr2_8=0; clean=0; reached=0; notrace=0; noexec=0
echo "Booting $N times (label=$LABEL), -d int, tallying ring-3 #PF..."
for run in $(seq 1 "$N"); do
    cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
    SER="$LOGS/$LABEL-$run.serial"
    INT="$LOGS/$LABEL-$run.int"
    timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
        -serial "file:$SER" -display none -no-reboot \
        -d int -D "$INT" >/dev/null 2>&1

    # ⚠ FLOOR 1 — DID THIS BOOT LEAVE A TRACE TO READ? Everything below greps
    # "$INT"; on a missing or truncated file every one of those greps returns 0,
    # which is indistinguishable from "traced thousands of events, none of them a
    # ring-3 #PF". Count the exception records first and make the absence of a
    # trace its own verdict rather than a clean bill of health.
    ev=$(grep -cE 'v=[0-9a-fA-F]{2}' "$INT" 2>/dev/null); [ -z "$ev" ] && ev=0

    # Did the kernel reach the agnsh exec at all this boot?
    if strings "$SER" 2>/dev/null | grep -q "kybernet: exec /bin/agnsh"; then
        reached=$((reached+1)); got_exec=1
    else
        got_exec=0
    fi

    # Ring-3 #PF detection: in this QEMU's `-d int` format every exception is a
    # single header line, e.g.
    #   N: v=0e e=0007 i=0 cpl=3 IP=... pc=... SP=... env->regs[R_EAX]=...
    # so a ring-3 page fault is one line matching BOTH `v=0e` and `cpl=3`.
    r3=$(grep -c "v=0e .* cpl=3" "$INT" 2>/dev/null); [ -z "$r3" ] && r3=0

    # The faulting address (CR2) is dumped separately by QEMU only on a real
    # #PF service; tally the two signature values from the issue independently.
    c10=$(grep -c "CR2=0000000010000000" "$INT" 2>/dev/null); [ -z "$c10" ] && c10=0
    c8=$(grep -c  "CR2=0000000000000008" "$INT" 2>/dev/null); [ -z "$c8" ]  && c8=0

    # ⚠ ORDER MATTERS: a boot only earns the word "clean" after it has proved it
    # was observable. "Inconclusive" is not a softer "clean"; it is the absence of
    # a measurement, and it must not be able to add up to a PASS.
    if [ "$ev" -lt "$TRACE_FLOOR" ]; then
        notrace=$((notrace+1))
        printf '  run %2d: INCONCLUSIVE — no -d int trace (%s v= records, floor %s)\n' "$run" "$ev" "$TRACE_FLOOR"
    elif [ "$got_exec" -eq 0 ]; then
        # ⚠ FLOOR 2 — the fault under test is a RING-3 fault taken by agnsh. A boot
        # that traced fine but never reached `kybernet: exec /bin/agnsh` never
        # opened the window in which that fault can occur, so its zero is a
        # statement about the boot, not about the bug.
        noexec=$((noexec+1))
        printf '  run %2d: INCONCLUSIVE — traced %s exceptions, never reached the agnsh exec\n' "$run" "$ev"
    elif [ "$r3" -gt 0 ]; then
        pf3=$((pf3+1))
        printf '  run %2d: RING-3 #PF (records=%s, CR2=10000000:%s CR2=8:%s)\n' "$run" "$r3" "$c10" "$c8"
    else
        clean=$((clean+1))
        printf '  run %2d: clean (%s traced exceptions)\n' "$run" "$ev"
    fi
    cr2_10=$((cr2_10 + c10))
    cr2_8=$((cr2_8 + c8))
done

usable=$((clean + pf3))
inconc=$((notrace + noexec))

echo ""
echo "TALLY [$LABEL] N=$N : ring3-PF-boots=$pf3  clean-boots=$clean  reached-exec=$reached"
echo "        usable boots (traced AND reached the exec): $usable / $N"
echo "        inconclusive: $inconc  (no -d int trace: $notrace, never reached exec: $noexec)"
echo "        signature CR2 records across all boots: CR2=0x10000000:$cr2_10  CR2=0x8:$cr2_8"

# ⚠ THE DENOMINATOR IS THE POINT. The old verdict divided by $N — the number of
# boots REQUESTED — which is a constant this script chooses, not a measurement.
# Divide by the number of boots that produced evidence, so a sweep whose guests
# all died reads as 0/0 and is refused rather than reading as a clean 0/20.
if [ "$usable" -eq 0 ]; then
    echo "REPRO: INCONCLUSIVE — 0 of $N boots produced evidence; this run measured NOTHING"
    echo "  Neither PASS nor repro can be claimed. Check that qemu launched, that this"
    echo "  build supports -d int, and that QEMU_TIMEOUT (${QEMU_TIMEOUT:-40}s) outlasts firmware."
    echo "  Logs (such as they are) in $LOGS"
    exit 2
fi

if [ "$pf3" -gt 0 ]; then
    echo "REPRO: $pf3 ring-3 #PF boots / $usable usable (of $N requested) — see logs in $LOGS"
    exit 1
fi

[ "$inconc" -gt 0 ] && echo "  ⚠ $inconc of $N boots were inconclusive — the sweep is thinner than it looks."
echo "REPRO: 0 ring-3 #PF / $usable usable boots (of $N requested) — PASS"
exit 0
