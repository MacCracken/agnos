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
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
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
LOGS="$ROOT/build/msc-short-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"

boot_once() {   # $1 = log path
    W=$(mktemp -d)
    IMG="$W/d.img"; USB="$W/usb.img"
    # The only measured-working ESP recipe (1.56.51): 128 MB disk, 1MiB..33MiB, nvme.
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
    mformat -i "$IMG"@@1048576 -F
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$IMG"@@1048576 "$ROOT/build/agnos" ::boot/agnos
    dd if=/dev/zero of="$USB" bs=1M count=8 status=none
    cp "$OVMF_VARS" "$W/vars.fd"; chmod +w "$W/vars.fd"
    timeout "${QEMU_TIMEOUT:-45}" qemu-system-x86_64 -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" \
        -device "nvme,drive=d0,serial=AGNOS-MSCS,bootindex=0" \
        -device qemu-xhci,id=xhci \
        -drive "file=$USB,format=raw,if=none,id=stick" \
        -device "usb-storage,bus=xhci.0,drive=stick" \
        -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' > "$1"
    rm -rf "$W"
}

# ⚠ Retry ONLY when the kernel banner is absent. OVMF intermittently never hands off (~1 run in 4),
# and that run measures NOTHING — retrying on a real assertion failure would retry a regression away.
boot_arm() {    # $1 = log path, $2 = label
    a=1
    while [ "$a" -le 3 ]; do
        boot_once "$1"
        if grep -q 'AGNOS kernel v' "$1"; then return 0; fi
        echo "  ($2: firmware never handed off — retry $a/3)"
        a=$((a+1))
    done
    echo "  UEFI never handed off in 3 attempts — INFRASTRUCTURE, not the kernel. Treat as VOID."
    return 1
}

rc=0
echo "=== MSC short-data-phase smoke (usb-storage on qemu-xhci) ==="

echo "[1/2] injected build (MSC_SHORT_INJECT=1) — READ(10) must be REFUSED..."
MSC_SHORT_INJECT=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }
boot_arm "$LOGS/injected.log" injected || exit 1
if grep -q 'mass-storage device(s) detected' "$LOGS/injected.log"; then
    echo "  PASS: the usb-storage device enumerated (MSC transport is exercised at all)"
else
    echo "  FAIL: no MSC device enumerated — the stick never attached, so nothing below is measured"; rc=1
fi
if grep -q 'READ(10) short data phase' "$LOGS/injected.log"; then
    echo "  PASS: a short data phase is REFUSED, and reports both counts + the device residue"
else
    echo "  FAIL: short data phase NOT refused — a short read would be reported as success"; rc=1
fi

echo "[2/2] plain build — the same READ(10) must SUCCEED..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }
boot_arm "$LOGS/plain.log" plain || exit 1
if grep -q 'READ(10) short data phase' "$LOGS/plain.log"; then
    echo "  FAIL: healthy device refused — the check fires unconditionally and would break every stick"; rc=1
else
    echo "  PASS: a healthy device is NOT refused (the control that makes arm 1 meaningful)"
fi

[ "$rc" = "0" ] && echo "msc-short-smoke: PASS" || echo "msc-short-smoke: FAIL"
exit $rc
