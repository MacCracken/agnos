#!/bin/sh
# xhci-shadow-smoke.sh — 1.57.8: the xHCI / HID / MSC drivers reach their DMA pages through the DIRECT MAP,
# never through the identity VA a ring-3 PT_LOAD can shadow.
#
# The class (docs/development/issues/archived/2026-09-25-dma-cpu-pointers-still-use-identity-vas.md, xHCI half): pmm_alloc
# draws from [0x400000, 0x10000000), which is exactly the window a ring-3 ELF's PT_LOAD may map under its own CR3,
# and hid_poll runs from the 0x51 MSI-X ISR / BSP tick and msc_blk_* from syscalls under whatever CR3 is live. A
# driver that uses a DMA page's PHYS as a CPU pointer then reads or writes the process's page, not its ring.
#
# The instrument (XHCI_SHADOW_SELFTEST, msc.cyr xhci_shadow_selftest) builds that CR3 deliberately — the whole
# pool window PD[2..127] mapped onto one 2 MB junk region — and under it drives a No-Op command, an EP0
# GET_DESCRIPTOR, an MSC READ(10) of LBA 0 and a keyboard TRB arm + report fold; back on CR3 0x1000 every result
# must be byte-exact and the junk region untouched. Needs a usb-kbd AND a usb-storage stick (seeded MSCLBA0!).
#
# -smp 1 then -smp 4 (KVM when /dev/kvm is writable, else multi-threaded TCG — printed). Banner-gated retry
# (qemu_dwell_kernel); a VOID boot is never scored (exit 2). The shared latched-invariant deny applies.
# Discrimination (1.57.8 XHCI step report): each converted site reverted by hand turns its check RED.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
[ -f "$GNOBOOT" ]   || { echo "ERROR: gnoboot not built at $GNOBOOT — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "ERROR: OVMF_CODE not found at $OVMF_CODE — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_VARS" ] || { echo "ERROR: OVMF_VARS not found at $OVMF_VARS — this gate measured NOTHING"; exit 1; }
for t in qemu-system-x86_64 parted mformat mmd mcopy strings; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not installed — this gate measured NOTHING"; exit 1; }
done
LOGS="$ROOT/build/xhci-shadow-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0; void=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
klines() { strings "$1" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //'; }   # strip the klog prefix
want()   { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantk()  { if klines "$LOG" | grep -qxF -- "$1"; then ok "$2"; else bad "$2 (no kernel line that is exactly: $1)"; fi; }
die()    { echo "ERROR: $1 — a harness fault, not the kernel; this gate measured NOTHING"; exit 1; }
deny()   { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

echo "=== xHCI shadow-CR3 smoke (command / EP0 / MSC bulk / HID under a shadowed pool window) ==="

echo "[build] XHCI_SHADOW_SELFTEST=1, then plain (the tree is left plain)"
XHCI_SHADOW_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-shadow.log" 2>&1 \
    || { echo "ERROR: XHCI_SHADOW_SELFTEST build failed ($LOGS/build-shadow.log)"; sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-shadow"
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 \
    || { echo "ERROR: plain build failed ($LOGS/build-plain.log) — this gate measured NOTHING"; exit 1; }

echo "[C] the instrument is present in the test kernel and absent from production"
if strings "$WORK/agnos-shadow" | grep -qF 'xshadow: PASS'; then ok "the test kernel carries the instrument"
else bad "the test kernel does NOT carry the instrument — XHCI_SHADOW_SELFTEST never reached the source"; fi
if strings "$ROOT/build/agnos" | grep -qF 'xshadow:'; then bad "the PLAIN production kernel carries the shadow instrument"
else ok "the shadow instrument is compiled out of production"; fi

boot() {   # $1 kernel copy, $2 smp, $3 label; sets LOG; returns 1 on VOID
    W="$WORK/$3"; mkdir -p "$W"
    IMG="$W/d.img"; USB="$W/usb.img"; LOG="$LOGS/$3.log"
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none                              || die "[$3] image: dd of the 128 MB disk failed"
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1 || die "[$3] image: parted failed"
    mformat -i "$IMG"@@1048576 -F                                                      || die "[$3] image: mformat of the ESP failed"
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot                                     || die "[$3] image: mmd failed"
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI                         || die "[$3] image: copying gnoboot onto the ESP failed"
    mcopy -i "$IMG"@@1048576 "$1" ::boot/agnos                                         || die "[$3] image: copying the kernel onto the ESP failed"
    mcopy -n -i "$IMG"@@1048576 ::boot/agnos "$W/agnos.readback" && cmp -s "$W/agnos.readback" "$1" \
        || die "[$3] image: the kernel read back from the ESP is not the kernel under test"
    rm -f "$W/agnos.readback"
    dd if=/dev/zero of="$USB" bs=1M count=8 status=none                                || die "[$3] stick: dd of the 8 MB stick failed"
    printf 'MSCLBA0!' | dd of="$USB" bs=1 conv=notrunc status=none                   || die "[$3] stick: seeding LBA 0 failed"
    [ "$(head -c 8 "$USB")" = "MSCLBA0!" ] || die "[$3] stick: LBA 0 does not read back as the MSCLBA0! seed"
    ACC=$(smoke_accel "$2")
    [ "$2" -gt 1 ] && echo "  accel: $ACC"
    qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-120}" "$W/vars.fd" "$OVMF_VARS" \
        qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$2" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" \
        -device "nvme,drive=d0,serial=AGNOS-XSHD,bootindex=0" \
        -device qemu-xhci,id=xhci \
        -device "usb-kbd,bus=xhci.0" \
        -drive "file=$USB,format=raw,if=none,id=stick" \
        -device "usb-storage,bus=xhci.0,drive=stick" \
        -serial stdio -display none -no-reboot
    rm -f "$IMG" "$USB"
    if ! qemu_assert_booted "$LOG"; then echo "  VOID: [$3] the kernel never ran — no assertion scored"; void=1; return 1; fi
    return 0
}

for SMP in ${XHCI_SHADOW_SMP:-1 4}; do
    echo "[smp$SMP] shadow kernel, -smp $SMP"
    if boot "$WORK/agnos-shadow" "$SMP" "shadow-smp$SMP"; then
        want  "mass-storage device(s) detected"                                     "[smp$SMP] the usb-storage stick enumerated"
        want  "hid: keyboard configured"                                            "[smp$SMP] the usb-kbd bound"
        wantk "xshadow: shadow CR3 built - pool window PD[2..127] -> one junk 2 MB region" "[smp$SMP] the shadow address space was built"
        wantk "xshadow: No-Op command + completion event under shadow OK"          "[smp$SMP] command ring + event ring are CPU-addressed through the direct map"
        wantk "xshadow: EP0 GET_DESCRIPTOR under shadow byte-exact OK"             "[smp$SMP] EP0 ring, slot tables and descriptor page"
        wantk "xshadow: MSC READ(10) LBA0 under shadow byte-exact OK"              "[smp$SMP] MSC bulk rings, CBW, CSW and data page"
        wantk "xshadow: HID TRB arm + report fold under shadow OK"                 "[smp$SMP] keyboard transfer ring + report buffer"
        wantk "xshadow: shadow region untouched (no identity-VA store) OK"         "[smp$SMP] no CPU store went through an identity VA"
        wantk "xshadow: PASS"                                                      "[smp$SMP] the selftest passed"
        deny  "xshadow: (FAIL|VOID)|WRONG under shadow|FAILED under shadow|WRITTEN through" "[smp$SMP] no xshadow failure line"
        deny  "$SMOKE_INVARIANT_DENY"                                              "[smp$SMP] no latched kernel invariant fired (whole boot)"
        klines "$LOG" | grep -E '^xshadow:' | sed 's/^/        /'
    fi
done

echo "=== xhci-shadow-smoke: $pass passed, $fail failed$( [ "$void" = 1 ] && echo ', VOID boot(s)') — logs in $LOGS ==="
if [ "$fail" -gt 0 ]; then echo "xhci-shadow-smoke: FAIL"; exit 1; fi
if [ "$void" = 1 ]; then echo "xhci-shadow-smoke: VOID"; exit 2; fi
echo "xhci-shadow-smoke: PASS"
exit 0
