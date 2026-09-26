#!/bin/bash
# ICMP echo / ping smoke (ICMP_SELFTEST=1) — the 1.35.x hermetic build arm plus the 1.57.7 S6 arms
# (issue 2026-09-23-sock-send-and-connect-hold-the-cpu, #55/#100 block only their caller):
#   "icmp: build PASS"  — an echo request is built, its checksum stored, and the whole message re-checksummed to 0.
#   "icmp: slots PASS"  — the PER-PROCESS reply slots: two armed pids each get their own reply, a stale sequence
#                         matches none, icmp_rx +2 (M-S8: matching the global sequence only -> FAIL).
#   "icmp: wake PASS"   — a pinger BLOCKED directly in icmp_block is woken by the reply net_tick delivers from the
#                         loopback queue, well before its 2 s deadline (M-S11: no WK_ICMP wake -> FAIL).
# Informational (host ICMP permissions): "icmp: gw reply ticks=N" — a live echo of the SLIRP gateway (10.0.2.2).
#
# 1.57.7 (S6): banner-gated retry (qemu_dwell_kernel; exit 2 on a firmware VOID), PASS/FAIL per check, the shared
# latched-invariant deny ($SMOKE_INVARIANT_DENY), dwell 120 s on `icmp: selftest done`, and two boots: -smp 1 (TCG)
# and a GATED -smp 4 (smoke_accel: KVM when writable, else tcg,thread=multi). ICMP_SMP overrides (default "1 4").
# Gated by scripts/sweep.sh (ICMP_SELFTEST=1) since 1.57.7.
# Requires: a kernel built with ICMP_SELFTEST=1, qemu, OVMF, mtools, parted, gnoboot.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"     # qemu_dwell_kernel, qemu_assert_booted, smoke_accel, SMOKE_INVARIANT_DENY
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found — this gate measured NOTHING" >&2
    exit 1
fi
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="${SMOKE_KERNEL:-$ROOT/build/agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "icmp: selftest done"; then
    echo "ERROR: kernel was not built with ICMP_SELFTEST=1 — rebuild: ICMP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/icmp-smoke"
LOGS="$ROOT/build/icmp-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
# ⛔⛔ 1.56.51 — the ESP recipe that hands off: a 128 MB disk, ESP at 1-33 MiB, on NVMe (see edge-abi-smoke.sh).
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS ICMP echo / ping smoke ==="
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"
pass=0
fail=0
void=0
check() {
    if grep -qa "$1" "$LOG"; then echo "PASS: [$SMP] $2"; pass=$((pass + 1));
    else echo "FAIL: [$SMP] '$1' not found — $3"; fail=$((fail + 1)); fi
}
deny() {
    if grep -qaE "$1" "$LOG"; then echo "FAIL: [$SMP] $2"; grep -aE "$1" "$LOG" | head -3 | sed 's/^/        /'; fail=$((fail + 1));
    else echo "PASS: [$SMP] $3"; pass=$((pass + 1)); fi
}
for SMP in ${ICMP_SMP:-1 4}; do
    LOG="$LOGS/icmp-smp$SMP.log"
    ACCEL="$(smoke_accel "$SMP")"
    echo ""
    echo "--- boot: -smp $SMP  accel: $ACCEL ---"
    qemu_dwell_kernel "$LOG" "icmp: selftest done" "${QEMU_TIMEOUT:-120}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
        -netdev "user,id=u1" -device "virtio-net-pci,netdev=u1" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    echo "--- serial log (icmp: lines) ---"
    grep -aE "icmp:" "$LOG" || echo "(no icmp lines captured)"
    echo "--------------------------------"
    check "icmp: build PASS"     "hermetic ICMP echo build + checksum (message sums to 0)"                 "ICMP build/checksum regression"
    check "icmp: slots PASS"     "S6: per-process reply slots (each pid its own reply; a stale seq matches none)" "M-S8"
    check "icmp: wake PASS"      "S6: a blocked pinger is woken by its reply (WK_ICMP|pid)"                "M-S11"
    check "icmp: selftest done"  "the block ran to its last line"                                          "the selftest block did not finish"
    deny "icmp: [a-z]+ FAIL|icmp: [a-z]+ SKIP" "an arm printed FAIL or SKIP" "no arm printed FAIL or SKIP"
    deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant"
    if grep -qa "icmp: gw reply ticks=" "$LOG"; then echo "INFO: [$SMP] live gateway ping — $(grep -am1 'icmp: gw reply' "$LOG")"
    else echo "INFO: [$SMP] live gateway ping no-reply (SLIRP ICMP unavailable — not required)"; fi
done

echo ""
echo "=== icmp-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
