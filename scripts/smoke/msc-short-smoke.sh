#!/bin/sh
# msc-short-smoke — the MSC short-data-phase reject, and THE TREE'S FIRST usb-storage COVERAGE.
#
# ⛔⛔ WHY THIS EXISTS. Before 1.56.52 not one QEMU invocation anywhere under scripts/ attached a
# usb-storage device — every one is qemu-xhci plus usb-kbd/usb-mouse. So the entire MSC transport
# (msc.cyr, ~1500 lines, five block-layer entry points) had ZERO automated coverage, and every gate in
# check.sh and sweep.sh passed identically whether its short-read handling was correct, inverted or
# absent. That is the "would the named smoke pass regardless" trap, and it applied to a whole driver.
#
# ⚠ THE DEVICE IS REACHABLE — the absence was in the harness, not the capability. Attaching
# `-device usb-storage,bus=xhci.0` enumerates and registers as a tertiary block device on the first
# boot that tries it. The one catch: OVMF then offers the stick as a boot option and stops at the
# menu, so the NVMe drive needs an explicit `bootindex=0` or nothing boots at all.
#
# THE A/B. A short data phase cannot be provoked from a well-behaved QEMU device, so the reject path
# is driven by MSC_SHORT_INJECT (msc.cyr), which shortens the recorded IN count by 64 bytes:
#   ARM 1 (injected): READ(10) MUST be refused, and MUST say so with both counts and the residue.
#   ARM 2 (plain):    the SAME read MUST succeed — without this the test is satisfied by any
#                     unconditional refusal, which would break every real stick.
# ⛔ 1.57.7 — ARM 2 USED TO ASSERT ONLY AN ABSENCE (no `READ(10) short data phase` line), so it passed
# when the stick never enumerated or when READ(10) failed outright. Nothing in the tree asserted a
# production READ(10) success. It now requires the enumeration, the LBA-0 bytes of the stick, which the
# harness seeds with "MSCLBA0!" (`LBA0 first 8 bytes: 77 83 67 76 66 65 48 33` — a READ(10) that moved
# real data; an all-zero stick cannot tell that from a read that moved none), and the absence of
# `READ(10) LBA0 failed`, and both arms deny the latched kernel invariants over the whole boot.
# ⚠ 1.57.7 fix pass — THAT LBA-0 LINE IS MATCHED EXACTLY, ON THE MSC EMITTER (`msc: slot N LBA0 first 8
# bytes: ...`, klog prefix stripped). The bare phrase `LBA0 first 8 bytes:` is also printed by nvme.cyr and
# ahci.cyr, so an unanchored match can be satisfied by another driver's line — the all-zero form matched
# the NVMe boot disk's line on every boot. And every image/stick step is checked (a failed seed used to be
# scored "a production READ(10) ... FAIL", a harness fault blamed on the kernel — measured with the seed
# write failing); a harness fault is ERROR, exit 1, before any boot.
#
# BOOTS go through qemu-dwell.sh (qemu_dwell_kernel: 6 banner-gated tries, a fresh vars.fd per try,
# stop at the `agnos>` prompt — every assertion here prints before it). Until 1.57.7 this file had its
# own 3-try loop that exited 1 on VOID (~34% all-VOID arms at the measured ~30% hand-off rate, vs ~12% at
# 6). Exit: 1 on any FAIL; else 2 if an arm was VOID; else 0. sweep.sh still scores exit 2 as FAIL, by
# design (sweep.sh run_gate: a VOID must not hide a real failure there).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
# ⛔ 1.56.55 — A MISSING PREREQUISITE EXITS 1, NOT 0. These guards used to `exit 0`, and sweep.sh
# scores a gate on exit status alone, so "this gate measured NOTHING" was rendered as a green tick.
# Thirteen such guards across six smokes, five of them in the sweep table. Same doctrine as
# syscall-abi-check.sh: a check that quietly passes when it could not find one of its inputs is a
# false green. An absent prerequisite is not a pass and must not read as one.
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "ERROR: OVMF not found — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_VARS" ] || { echo "ERROR: OVMF_VARS not found — this gate measured NOTHING"; exit 1; }
for t in qemu-system-x86_64 parted mformat mmd mcopy strings; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not installed — this gate measured NOTHING"; exit 1; }
done
LOGS="$ROOT/build/msc-short-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"

rc=0; void=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; rc=1; }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
klines() { strings "$1" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //'; }   # strip the klog prefix
wantkre() { if klines "$LOG" | grep -qxE -- "$1"; then ok "$2"; else bad "$2 (no kernel line that is exactly: $1)"; fi; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM
die() { echo "ERROR: $1 — a harness fault, not the kernel; this gate measured NOTHING"; exit 1; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# One arm: the image and the stick are built ONCE (outside the retry); qemu_dwell_kernel refreshes
# vars.fd on every attempt and retries only while the kernel banner is absent.
boot_arm() {    # $1 = log path, $2 = label, $3 = kernel copy; sets LOG; returns 1 on VOID
    LOG="$1"
    W="$WORK/$2"; mkdir -p "$W"
    IMG="$W/d.img"; USB="$W/usb.img"
    # The only measured-working ESP recipe (1.56.51): 128 MB disk, 1MiB..33MiB, nvme.
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none                              || die "[$2] image: dd of the 128 MB disk failed"
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1 || die "[$2] image: parted failed"
    mformat -i "$IMG"@@1048576 -F                                                      || die "[$2] image: mformat of the ESP failed"
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot                                     || die "[$2] image: mmd failed"
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI                         || die "[$2] image: copying gnoboot onto the ESP failed"
    mcopy -i "$IMG"@@1048576 "$3" ::boot/agnos                                         || die "[$2] image: copying the kernel onto the ESP failed"
    mcopy -n -i "$IMG"@@1048576 ::boot/agnos "$W/agnos.readback" && cmp -s "$W/agnos.readback" "$3" \
        || die "[$2] image: the kernel read back from the ESP is not the kernel under test"
    dd if=/dev/zero of="$USB" bs=1M count=8 status=none                                || die "[$2] stick: dd of the 8 MB stick failed"
    # ⛔ SEED LBA 0 WITH A KNOWN NON-ZERO PATTERN. On an all-zero stick `LBA0 first 8 bytes: 0 0 0 0 0 0 0 0`
    # is also what a READ(10) that moved NO data prints: the kernel zeroes the page first, and QEMU's
    # usb-storage pads a data phase the CDB did not ask for (measured 1.57.7 with the transfer-length byte
    # removed from msc_build_rw10_cdb — the zero assertion stayed green). "MSCLBA0!" = 77 83 67 76 66 65 48 33.
    printf 'MSCLBA0!' | dd of="$USB" bs=1 conv=notrunc status=none                   || die "[$2] stick: seeding LBA 0 failed"
    [ "$(head -c 8 "$USB")" = "MSCLBA0!" ] || die "[$2] stick: LBA 0 does not read back as the MSCLBA0! seed"
    qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-60}" "$W/vars.fd" "$OVMF_VARS" \
        qemu-system-x86_64 -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" \
        -device "nvme,drive=d0,serial=AGNOS-MSCS,bootindex=0" \
        -device qemu-xhci,id=xhci \
        -drive "file=$USB,format=raw,if=none,id=stick" \
        -device "usb-storage,bus=xhci.0,drive=stick" \
        -serial stdio -display none -no-reboot
    rm -rf "$W"
    if ! qemu_assert_booted "$LOG"; then echo "  VOID: [$2] the kernel never ran — no assertion scored"; void=1; return 1; fi
    return 0
}

echo "=== MSC short-data-phase smoke (usb-storage on qemu-xhci) ==="

# ⚠ 1.57.7 fix pass — BOTH KERNELS ARE BUILT FIRST AND BOOTED FROM COPIES, PLAIN BUILT LAST. This file
# used to build MSC_SHORT_INJECT into build/agnos and rebuild plain only for arm 2, so any exit in between
# (a harness ERROR, a VOID-then-FAIL, ^C) left the fault-injecting kernel in build/ for the next smoke to
# boot — measured: an aborted run left the 2,431,592-byte inject kernel there (agnsh-smoke boots whatever
# build/agnos is). The tree is now plain before the first boot. (msc-cdb-smoke's pattern.)
echo "[build] MSC_SHORT_INJECT=1, then plain (each arm boots a copy; the tree is plain before any boot)"
MSC_SHORT_INJECT=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-injected.log" 2>&1 \
    || { echo "  BUILD FAILED (MSC_SHORT_INJECT=1, $LOGS/build-injected.log)"; sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-injected"
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  BUILD FAILED (plain, $LOGS/build-plain.log)"; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-plain"

echo "[1/2] injected kernel (MSC_SHORT_INJECT=1) — READ(10) must be REFUSED..."
if boot_arm "$LOGS/injected.log" injected "$WORK/agnos-injected"; then
    if strings "$LOG" | grep -q 'mass-storage device(s) detected'; then
        echo "  PASS: the usb-storage device enumerated (MSC transport is exercised at all)"
    else
        bad "no MSC device enumerated — the stick never attached, so nothing below is measured"
    fi
    if strings "$LOG" | grep -q 'READ(10) short data phase'; then
        echo "  PASS: a short data phase is REFUSED, and reports both counts + the device residue"
    else
        bad "short data phase NOT refused — a short read would be reported as success"
    fi
    deny "$SMOKE_INVARIANT_DENY" "no latched kernel invariant fired (whole boot)"
fi

echo "[2/2] plain kernel — the same READ(10) must SUCCEED..."
if boot_arm "$LOGS/plain.log" plain "$WORK/agnos-plain"; then
    if strings "$LOG" | grep -q 'READ(10) short data phase'; then
        bad "healthy device refused — the check fires unconditionally and would break every stick"
    else
        echo "  PASS: a healthy device is NOT refused (the control that makes arm 1 meaningful)"
    fi
    want "mass-storage device(s) detected"     "the usb-storage device enumerated in the plain arm"
    wantkre "msc: slot [0-9]+ LBA0 first 8 bytes: 77 83 67 76 66 65 48 33"  "a production READ(10) SUCCEEDED and returned the seeded LBA 0 bytes (the MSC line, not nvme/ahci's)"
    deny "READ(10) LBA0 failed"                "the production READ(10) of LBA 0 did not fail"
    deny "$SMOKE_INVARIANT_DENY"               "no latched kernel invariant fired (whole boot)"
fi

if [ "$rc" != "0" ]; then echo "msc-short-smoke: FAIL"; exit 1; fi
if [ "$void" = "1" ]; then echo "msc-short-smoke: VOID"; exit 2; fi
echo "msc-short-smoke: PASS"
exit 0
