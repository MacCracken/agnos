#!/bin/bash
# TCP hermetic smoke (TCP_SELFTEST=1) — the 1.35.1 B1-B4 arms plus the 1.57.7 S4 arms: tcp: locks (the four
# IRQ-saved net lock wrappers), net: lo-inplace (N-2), net: txslots (virtio TX slots N-1 + ring KVAs N-6),
# tcp: claim / gen / syncap (pool, claim, gen, hardening (a), C11, C7, SYN cap 4 + reserve 1), tcp: eof and
# tcp: halfclose (issue 2026-09-23-sock-recv-never-reports-eof-after-peer-fin, D12(ii)), plus the 1.57.7 S6 arms
# (issue 2026-09-23-sock-send-and-connect-hold-the-cpu): rebase, tickretx, ticklo (net_tick), wndopen, persist,
# partack, wndstale (send-side correctness), ackwake, rstwake (the WK_TCP wakes), legacyif, finretx, finfold, finboth,
# orphan (graceful close), connfail (#47's release), stall (D6 + one in flight). Every arm prints PASS or FAIL;
# `tcp: selftest done` is the LAST line of the block and the dwell marker.
# 1.57.7 (S6): two boots — -smp 1 (TCG) and a GATED -smp 4 (smoke_accel: KVM when writable, else tcg,thread=multi);
# dwell 120 s (the arms block on real deadlines). TCP_SMP overrides the list (default "1 4").
#
# 1.57.7 (S4.1): banner-gated retry (qemu_dwell_kernel), exit 2 on a firmware VOID (the kernel never ran), a
# PASS/FAIL line per check, and the shared latched-invariant deny ($SMOKE_INVARIANT_DENY, incl. the S4
# `net: lock overlap|net: lock missing` witnesses). Gated by scripts/sweep.sh (TCP_SELFTEST=1) since 1.57.7.
# Requires: a kernel built with TCP_SELFTEST=1 (sweep's run_gate builds it), qemu, OVMF, mtools, parted, gnoboot.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"     # qemu_dwell_kernel, qemu_assert_booted, SMOKE_INVARIANT_DENY
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
if ! strings "$AGNOS" | grep -q "tcp: selftest done"; then
    echo "ERROR: kernel was not built with TCP_SELFTEST=1 — rebuild: TCP_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/tcp-smoke"
LOGS="$ROOT/build/tcp-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

echo "=== AGNOS TCP hermetic smoke ==="
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
for SMP in ${TCP_SMP:-1 4}; do
    LOG="$LOGS/tcp-smp$SMP.log"
    ACCEL="$(smoke_accel "$SMP")"
    echo ""
    echo "--- boot: -smp $SMP  accel: $ACCEL ---"
    qemu_dwell_kernel "$LOG" "tcp: selftest done" "${QEMU_TIMEOUT:-120}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "nvme,drive=esp0,serial=AGNOS-SMOKE" \
        -netdev "user,id=u1" -device "virtio-net-pci,netdev=u1" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi

    echo "--- serial log (tcp:/net: lines) ---"
    grep -aE "tcp:|net: " "$LOG" || echo "(no tcp lines captured)"
    echo "------------------------------------"

    check "tcp: ring PASS"        "B1 in-order receive ring (FIFO + wrap), fake slot claimed + released through the pool" "ring regression"
    check "tcp: retx PASS"        "B2 retransmit in µs (RTO backoff, arm/disarm, resend at the held seq, give-up)"    "retransmit regression"
    check "tcp: mss PASS"         "B3 MSS option"                                                                     "MSS regression"
    check "tcp: wnd PASS"         "B4 send-chunk sizing + release discipline (CLOSED, ring unbound, retx buf kept)"   "window/release regression"
    check "tcp: locks PASS"       "net lock wrappers: IF=0 inside, the real global taken, preempt +1, all restored"   "lock wrapper regression"
    check "net: lo-inplace PASS"  "lo drain demuxes IN PLACE (N-2): one drop with a full queue, 8 replies"            "lo drain regression"
    check "net: txslots PASS"     "virtio TX slot per descriptor (N-1) + ring CPU pointers in the direct map (N-6)"   "virtio TX regression"
    check "tcp: claim PASS"       "pool + claim (gen, publish last) + hardening (a) + C11 + C7(a)"                    "claim regression"
    check "tcp: gen PASS"         "tcp_conn_check / tcp_connect_wait: recycled = -1, CLOSE_WAIT = connected (N-4, N-8)" "gen regression"
    check "tcp: syncap PASS"      "SYN_RCVD cap 4 + passive reserve 1 + LISTEN close RSTs its children"             "backlog regression"
    check "tcp: eof PASS"         "EOF = dead, or CLOSE_WAIT with an empty ring; data before EOF"                     "EOF regression"
    check "tcp: halfclose PASS"   "FIN before accept kept; accept 2|4; send in CLOSE_WAIT; re-ACK; LAST_ACK held until ACKed; RST in 4" "half-close regression"
    check "tcp: rebase PASS"      "S6: a future retx stamp (the tsc_calibrate step) is rebased, not stuck"             "M-REBASE"
    check "tcp: tickretx PASS"    "S6: net_tick retransmits with no net_poll (a blocked sender's resend)"            "M-S5"
    check "tcp: ticklo PASS"      "S6: net_tick drains the loopback queue"                                           "M-S6"
    check "tcp: wndopen PASS"     "S6: a window-opening ACK makes the held probe due now"                            "M-S4"
    check "tcp: persist PASS"     "S6: a zero-window ACK caps the retry count (a live reader is never declared dead)" "M-S7"
    check "tcp: partack PASS"     "S6: a partial ACK trims the held segment"                                         "M-TRIM"
    check "tcp: wndstale PASS"    "S6: a stale ACK does not overwrite the window"                                    "M-WSTALE"
    check "tcp: ackwake PASS"     "S6: a blocked sender is woken by the covering ACK (WK_TCP)"                       "M-S1"
    check "tcp: rstwake PASS"     "S6: a blocked connect is woken by the RST"                                        "M-RSTWAKE"
    check "tcp: legacyif PASS"    "S6: the legacy step leaves IF as it found it"                                     "M-LEGIF"
    check "tcp: finretx PASS"     "S6: graceful close — held FIN slot, retransmit, FIN_WAIT_2, LAST_ACK, exhaustion" "M-FIN1"
    check "tcp: finfold PASS"     "ENDFIX S6-R1: a close over a held data segment folds the FIN in (data kept, resent, then FIN)" "M-FOLD"
    check "tcp: finboth PASS"     "S6: a both-sides close ACKs both FINs and releases both slots"                   "M-FW2"
    check "tcp: orphan PASS"      "S6: an orphan FIN slot is reclaimed; the free count matches the claim"            "M-ORPHAN / M-FREECOUNT"
    check "tcp: connfail PASS"    "S6: every -1 exit of #47 releases its slot (RST and timeout)"                     "M-LEAK"
    check "tcp: stall PASS"       "S6: D6 + one segment in flight at entry"                                          "M-S2"
    check "tcp: selftest done"    "the block ran to its last line"                                                     "the selftest block did not finish"
    deny "tcp: [a-z0-9]+ FAIL|net: [a-z-]+ FAIL|SKIP" "an arm printed FAIL or SKIP" "no arm printed FAIL or SKIP"
    deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant (incl. net: lock overlap/missing)"
done

echo ""
echo "=== tcp-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
