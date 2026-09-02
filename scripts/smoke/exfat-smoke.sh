#!/bin/bash
# exFAT read smoke (agnos 1.34.1 bite 2 — mount + multi-cluster chain read).
#
# Boots the EXFAT_SELFTEST kernel against a GPT disk: p1 = a FAT32 ESP
# (gnoboot + agnos, the boot path), p2 = a Microsoft-Basic-Data partition
# formatted exFAT by mkfs.exfat -c 512. exFAT has no mtools-equivalent and
# this box has no non-interactive root / fuse, so we DON'T seed a file —
# instead we validate the read substrate against the structures mkfs.exfat
# itself writes into an empty volume:
#     exfat: mounted ...            (boot-region parse + MSFT-Basic probe)
#     exfatu: upcase-checksum OK    (read the up-case table back over its
#                                    FAT chain → reproduce the TableChecksum
#                                    mkfs.exfat baked into the 0x82 entry,
#                                    an INDEPENDENT multi-cluster-read oracle)
#
# Optional file readback: if you seed EXFTEST.BIN (3000 B, byte[i]=i&0xFF)
# into the exFAT volume (e.g. via `sudo mount -t exfat`), the kernel also
# prints `exfatr: file-read OK`. Not required for this smoke to PASS — but
# ⚠ EXFAT_SEED=1 IS ALL-OR-NOTHING: arming that lane and failing to seed is a
# hard error (exit 1), never a downgrade to the unseeded lane. See the seed
# block below for the run that scored PASS by seeding nothing.
#
# Build first:  EXFAT_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools (mformat/mmd/
#           mcopy for the ESP), mkfs.exfat (exfatprogs), dd, strings.
#           gnoboot at ../gnoboot/build/. EXFAT_SEED=1 additionally needs
#           sudo + cmp.
# Exit 0 if every assertion the run's lane promises passed; 1 otherwise; 2 if
# QEMU produced no output at all (launch failure, not an exFAT result).

set -u

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

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.exfat dd strings awk; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run EXFAT_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/exfat-smoke"
LOGS="$ROOT/build/exfat-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-exfat.img"

echo "Building GPT disk (FAT32 ESP + exFAT MSFT-Basic partition)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart exfatdata 33MiB 100MiB
# Force p2's type GUID to Microsoft Basic Data (EBD0A0A2-...) so AGNOS's
# exfat probe gate (ESP | MSFT-Basic) matches it regardless of parted's
# fs-type hint.
sgdisk -t 2:0700 "$IMG" >/dev/null

# ESP = FAT32, seeded with gnoboot + agnos (boot path).
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

# p2 = exFAT. mkfs.exfat can't format a partition-inside-a-file without a
# loop device (root), so format a standalone file of the partition's exact
# size, then dd it into the image at the partition offset (no root).
P2_FIRST=$(sgdisk -i 2 "$IMG" | awk '/First sector:/ {print $3}')
P2_SECTORS=$(sgdisk -i 2 "$IMG" | awk '/Partition size:/ {print $3}')
[ -n "$P2_FIRST" ] && [ -n "$P2_SECTORS" ] || { echo "ERROR: could not read p2 geometry"; exit 1; }
echo "  p2: first_lba=$P2_FIRST sectors=$P2_SECTORS"

EXPART="$WORK/exfat.part"
dd if=/dev/zero of="$EXPART" bs=512 count="$P2_SECTORS" status=none
# -c 512 → 512-byte clusters (1 sector/cluster): the up-case table (5836 B)
# then spans ~12 clusters, so reading it back exercises the multi-cluster
# FAT-chain read path the gate validates.
mkfs.exfat -c 512 "$EXPART" >/dev/null 2>&1 || { echo "ERROR: mkfs.exfat failed"; exit 1; }

# Optional file seed (EXFAT_SEED=1) — exFAT has no userspace file-injector
# (no mtools-equivalent), so seeding a file needs the in-kernel exfat driver
# + a privileged loop mount. This will prompt for your sudo password. When
# seeded, the smoke also gates on `exfatr: file-read OK` (the 0x85/0xC0/0xC1
# file-set read path). Without it the smoke validates mount + the upcase
# chain-read oracle only. The seed runs on the standalone exfat.part BEFORE
# it's dd'd into the image, so it survives.
#
# ⛔ ASKING FOR THE SEED AND NOT GETTING IT IS A HARD ERROR, NOT A WARNING. Until 1.56.58 a failed
# loop mount printed "WARNING: seed mount failed — continuing without a seeded file", left SEEDED=0,
# and fell through to the unseeded lane — which SKIPS both hard gates the seed exists to arm (the
# byte-exact 0x85/0xC0/0xC1 file-set readback and the ls-name reconstruction) and then prints
# "exFAT read smoke: PASS". MEASURED 2026-09-02 with the loop mount forced to fail: exit 0, verdict
# PASS, two gates silently gone, and the only trace was a WARNING that scrolled past. The smoke
# passed BECAUSE the setup it needed had failed. A stale loop mount from a killed earlier run
# (`losetup -a`) is the common cause on this box, so the failure mode is not hypothetical — and it
# converts an explicitly-armed run into an unarmed one that still scores green. If the operator
# armed this lane, a lane that cannot arm is a failure of THIS RUN.
# ⛔ AND THE MOUNT SUCCEEDING IS NOT THE SEED SUCCEEDING. `sudo cp … && sync` had its status
# discarded, so a cp that failed (ENOSPC, a read-only mount) still reached SEEDED=1 — and the two
# hard gates then FAILED against a volume with no file in it, blaming the kernel for a host seeding
# failure. Same measurement: FAKE cp failure -> "FAIL: seeded file readback", verdict FAIL, kernel
# entirely innocent. The producer is now verified by reading the file back THROUGH the mount, which
# is the only window in which it is readable at all.
SEEDED=0
if [ -n "${EXFAT_SEED:-}" ]; then
    echo "Seeding EXFTEST.BIN (3000 B, byte[i]=i%256) via in-kernel exfat mount (sudo)..."
    # The verifier is a prerequisite of the lane, not an optional nicety: if `cmp` is missing we
    # cannot tell a landed seed from an empty volume, and "assume it worked" is the exact shape
    # this block was just fixed for.
    command -v cmp >/dev/null 2>&1 || {
        echo "ERROR: EXFAT_SEED=1 needs 'cmp' to verify the seed actually landed."; exit 1; }
    python3 - "$WORK/EXFTEST.BIN" <<'PY'
import sys
open(sys.argv[1], 'wb').write(bytes(i % 256 for i in range(3000)))
PY
    sudo modprobe exfat 2>/dev/null || true
    MNT="$WORK/mnt"; mkdir -p "$MNT"
    if sudo mount -t exfat -o loop "$EXPART" "$MNT"; then
        sudo cp "$WORK/EXFTEST.BIN" "$MNT"/EXFTEST.BIN && sync
        # ⚠ VERIFY WHILE STILL MOUNTED. After umount that path is an ordinary empty directory and
        # every check against it would pass on nothing — the vacuity this whole block is about.
        if sudo cmp -s "$WORK/EXFTEST.BIN" "$MNT"/EXFTEST.BIN; then SEED_OK=1; else SEED_OK=0; fi
        # umount runs whatever the verifier said: a volume left mounted leaks the loop device that
        # makes the NEXT run's mount fail. Report the seed verdict only after it is released.
        if sudo umount "$MNT"; then
            :
        else
            echo "ERROR: seed umount failed — $MNT still mounted (would leak a loop device). Aborting."
            exit 1
        fi
        if [ "$SEED_OK" = "1" ]; then
            SEEDED=1
            echo "  seeded — EXFTEST.BIN verified byte-exact (3000 B) through the mount."
        else
            echo "ERROR: seed did not land — EXFTEST.BIN on the mounted volume is missing or differs"
            echo "       from the source. EXFAT_SEED=1 was requested, so the file-set read gates this"
            echo "       run was armed for cannot be exercised. Aborting rather than downgrading to"
            echo "       the unseeded lane, which would score PASS having verified strictly less."
            exit 1
        fi
    else
        echo "ERROR: seed mount failed — EXFAT_SEED=1 was requested and the 0x85/0xC0/0xC1 file-set"
        echo "       read gates CANNOT run without it. NOT continuing unseeded: that path scores"
        echo "       'exFAT read smoke: PASS' with both of those gates skipped."
        echo "       Common cause is a stale loop mount from an earlier run — check:"
        echo "         losetup -a ; mount | grep exfat"
        exit 1
    fi
fi

dd if="$EXPART" of="$IMG" bs=512 seek="$P2_FIRST" conv=notrunc status=none

echo "Booting EXFAT_SELFTEST kernel (NVMe + GPT, exFAT MSFT-Basic p2)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/exfat-selftest.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"   # qemu_assert_booted
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-EXFATTEST" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"
# ⛔ DID THE KERNEL RUN AT ALL? Without this, an OVMF hand-off failure makes every assertion
# below evaluate against an empty log and print a wall of failures naming real properties.
# See qemu_assert_booted in the lib for the measured rate and the log signature.
qemu_assert_booted "$LOG" || exit 1

# A 0-byte log = QEMU never produced serial output (launch failure / host
# hiccup), NOT an exfat result. Report that honestly instead of emitting
# misleading per-gate FAILs. Common cause: a stale exfat loop-mount holding
# a loop device — check `losetup -a` / `mount | grep exfat`.
if [ ! -s "$LOG" ]; then
    echo "  ERROR: QEMU produced NO boot output (0-byte log) — launch failure, not an exFAT result."
    echo "         Check for stale loop mounts:  losetup -a ; mount | grep exfat"
    echo "         then re-run. Log: $LOG"
    exit 2
fi

echo ""
echo "  --- exfat lines from boot log ---"
strings "$LOG" | grep -E "^(\[[^]]*\] )?exfat:|^exfatr:|^exfatu:" | sed 's/^/  /'
echo ""

rc=0

# ⚠ VACUITY FLOOR — the pattern is scripts/check/toolchain-pin-check.sh, which asserts and PRINTS
# its manifest count so that "1 manifest" reports a broken enumeration rather than a clean tree.
# The same disease has a different vector here: `rc` only ever moves when a branch RUNS, so a gate
# that is SKIPPED is indistinguishable in the verdict from a gate that passed. Two shapes were
# MEASURED doing exactly that against this file at 1.56.57, each by replaying a canned serial log:
#   · the kernel's file-read verdict marker renamed ("no seeded file" -> "no seed file"): the
#     if/elif chain below fell off its end, printed NOTHING AT ALL for that lane, and the smoke
#     reported PASS/exit 0. The assertion did not fail — it stopped existing, silently.
#   · a log carrying "exfatr: file-read FAIL" — the kernel's OWN readback-broken verdict, which
#     that chain never named: same result, PASS/exit 0 over an explicit kernel failure.
# So every verdict below is counted, the count is PRINTED next to the one the lane promises, and a
# run that scores fewer FAILS. This cannot catch a check that is wrong, only one that is absent —
# which is the failure this file actually had, twice.
gates=0
gpass() { echo "  PASS: $*"; gates=$((gates + 1)); }
gfail() { echo "  FAIL: $*"; rc=1; gates=$((gates + 1)); }
ginfo() { echo "  (info) $*"; gates=$((gates + 1)); }

if strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfat: mounted"; then
    gpass "exFAT mount (boot-region parse + MSFT-Basic probe)"
else
    gfail "exFAT mount (no 'exfat: mounted' in log)"
fi
if strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfatu: upcase-checksum OK"; then
    gpass "multi-cluster FAT-chain read (upcase TableChecksum reproduced)"
else
    gfail "upcase-checksum (chain read) — see log"
fi
# File readback: a hard gate when we seeded a file, informational otherwise.
# ⛔ THE CHAIN MUST END IN A FAILING else. main.cyr:2031-2034 prints exactly one of three verdicts
# on this lane — "exfatr: file-read OK", "exfatr: file-read FAIL", "exfatr: no seeded file …" — and
# the old chain named only the first and the third. Matching none of them meant matching nothing:
# no line printed, no rc touched, verdict PASS. That covered BOTH a renamed marker and the kernel
# saying outright that the readback was broken.
if [ "$SEEDED" = "1" ]; then
    if strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfatr: file-read OK"; then
        gpass "seeded EXFTEST.BIN readback byte-exact (0x85/0xC0/0xC1 file-set read)"
    else
        gfail "seeded file readback (no 'exfatr: file-read OK' in log)"
    fi
elif strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfatr: file-read OK"; then
    gpass "(bonus) unseeded run found a file and read it back byte-exact"
elif strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfatr: file-read FAIL"; then
    gfail "file readback (kernel printed 'exfatr: file-read FAIL' — a file was present and read back WRONG)"
elif strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}exfatr: no seeded file"; then
    ginfo "no seeded file — file-set read path compiled, run EXFAT_SEED=1 to exercise it"
else
    gfail "file-read lane produced NO recognised verdict — expected one of 'exfatr: file-read OK'"
    echo "        / 'exfatr: file-read FAIL' / 'exfatr: no seeded file' (main.cyr:2031-2034)."
    echo "        The lane did not run, or its marker was renamed and this check silently stopped"
    echo "        asserting anything. exfatr lines actually seen:"
    strings "$LOG" | grep "^\(\[[^]]*\] \)\{0,1\}exfatr:" | sed 's/^/          /' || true
fi
# 1.39.2 VFS-lift bite 2: the shell `ls` verb reaches exFAT via
# vfs_print_dir_secondary → exfat_print_dir. Dispatch must run clean (marker
# printed AND boot reaches the shell after, so exfat_print_dir returned);
# when seeded, the reconstructed name must list.
if strings "$LOG" | grep -q "vfsls: shell ls over exFAT" && strings "$LOG" | grep -q "AGNOS shell"; then
    gpass "shell 'ls' dispatches to exFAT (exfat_print_dir ran clean, boot completed)"
else
    gfail "shell ls over exFAT (no 'vfsls' marker or boot didn't complete)"
fi
if [ "$SEEDED" = "1" ]; then
    if strings "$LOG" | grep -q "EXFTEST.BIN"; then
        gpass "shell 'ls' lists exFAT name (exfat_print_dir reconstruction)"
    else
        gfail "exFAT ls name (no 'EXFTEST.BIN' in log)"
    fi
fi

# Four verdicts in every run — mount / upcase chain-read / file-read lane / shell-ls dispatch —
# plus the ls-name reconstruction when the seeded lane is armed. Below that the run skipped
# something and its verdict describes fewer properties than the reader will assume.
EXPECT_GATES=4
LANE="NOT ARMED"
if [ "$SEEDED" = "1" ]; then
    EXPECT_GATES=5
    LANE="ARMED (seed verified byte-exact)"
else
    # ⚠ "SKIP:" IS THE LOAD-BEARING WORD, NOT DECORATION. sweep.sh's transcript filter is
    # `grep -iE "PASS:|FAIL:|smoke:|ERROR|SKIP|VOID|handed off"` — a line that matches none of
    # those is invisible in the only place these gates are normally read, which is how a lane
    # nothing arms stayed unnoticed. This line and the verdict below are the two that get through.
    echo "  SKIP: seeded file-set lane — EXFAT_SEED unset, so the 0x85/0xC0/0xC1 readback and the"
    echo "        ls-name reconstruction were NOT scored by this run."
fi
echo ""
echo "  assertions scored: $gates/$EXPECT_GATES   seeded file-set lane: $LANE"
if [ "$gates" -lt "$EXPECT_GATES" ]; then
    echo "  FAIL: only $gates of $EXPECT_GATES assertions ran — a gate was SKIPPED, not passed."
    echo "        This smoke is vacuous below $EXPECT_GATES. Treat the verdict as void and fix the"
    echo "        enumeration; a renamed kernel marker is the usual cause."
    rc=1
fi

echo ""
echo "=========================================="
# ⚠ THE SKIP BELONGS IN THE VERDICT LINE. sweep.sh:104 runs this gate with EXFAT_SELFTEST=1 and no
# EXFAT_SEED (`grep -rn EXFAT_SEED scripts/` matches only this file), so EVERY automated run takes
# the unarmed lane — the file-set read path this smoke is named for is never exercised by the
# sweep. That is a caller-side gap and cannot be fixed from here (seeding needs an interactive
# sudo loop mount, which is why it is opt-in), but it must not be INVISIBLE: a transcript reading
# "PASS" with no qualifier is what let it stay unnoticed.
if [ "$rc" = "0" ]; then
    echo "exFAT read smoke: PASS — $gates assertions, seeded file-set lane: $LANE"
else
    echo "exFAT read smoke: FAIL"
fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
