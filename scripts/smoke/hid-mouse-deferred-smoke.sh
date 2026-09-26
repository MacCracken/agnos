#!/bin/sh
# hid-mouse-deferred-smoke.sh — 1.57.8: mouse reports that complete while NOBODY drains are all delivered by the one
# drain that follows (issue docs/development/issues/archived/2026-09-25-hid-mouse-reports-share-one-buffer.md).
#
# The defect: every interrupt-IN TRB on a mouse row DMAed into ONE report buffer, so when two reports completed before
# the drain ran, each Transfer Event folded the LAST report — the first report's motion and button edge were lost and
# the last one's deltas counted twice. 1.57.7 (S3d) fixed the keyboard (per-TRB 16-byte slots); 1.57.8 fixes the mouse
# rows the same way (hid.cyr hid_slot_buf / hid_row_evt_buf).
#
# The instrument (HID_MOUSE_DEFER_SELFTEST, hid.cyr hid_mouse_defer_selftest): on the BSP, before the APs, with the
# xHCI MSI-X armed, it masks interrupts AND holds hid_poll_lock (so no tick or MSI-X on any CPU can drain), prints
# `hidmdf: window open`, and waits until four mouse Transfer Events are posted. This script's injector sees that line
# and sends, over the QEMU monitor, `mouse_move 5 0`, `mouse_move 0 7`, `mouse_button 1`, `mouse_button 0` (0.3 s
# apart, so each completes its own TRB). Then ONE hid_poll runs and dx must be 5, dy 7, the press seen and the button
# released. RED on the shared buffer: every event folds the last (all-zero) report.
#
# -smp 1 then -smp 4 (KVM when /dev/kvm is writable, else multi-threaded TCG — printed). Banner-gated retry
# (qemu_dwell_kernel); a VOID boot is never scored (exit 2). The shared latched-invariant deny applies.
# Env: HID_MDF_SMP (default "1 4"), QEMU_TIMEOUT, QEMU_TRIES, SMOKE_KVM.
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
for t in qemu-system-x86_64 parted mformat mmd mcopy strings python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not installed — this gate measured NOTHING"; exit 1; }
done
LOGS="$ROOT/build/hid-mouse-deferred-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
WORK=$(mktemp -d); INJ_PID=""
trap '[ -n "$INJ_PID" ] && kill "$INJ_PID" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0; void=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
klines() { strings "$1" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //'; }   # strip the klog prefix
want()   { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantk()  { if klines "$LOG" | grep -qxF -- "$1"; then ok "$2"; else bad "$2 (no kernel line that is exactly: $1)"; fi; }
die()    { echo "ERROR: $1 — a harness fault, not the kernel; this gate measured NOTHING"; exit 1; }
deny()   { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# The injector: waits for the kernel's window line in the (per-attempt, rewritten) serial log, then drives the HMP
# monitor. A VOID attempt never prints the line, so the injector simply keeps waiting for the next attempt.
cat > "$WORK/inject.py" <<'PYEOF'
import os, socket, sys, time
log, sock, done = sys.argv[1], sys.argv[2], sys.argv[3]
deadline = time.time() + 900
while time.time() < deadline:
    try:
        data = open(log, "rb").read()
    except OSError:
        data = b""
    if b"hidmdf: window open" in data:
        break
    time.sleep(0.1)
else:
    sys.exit(1)
time.sleep(0.5)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.settimeout(0.2)
def drain():
    try:
        while s.recv(4096):
            pass
    except OSError:
        pass
drain()
for cmd in ("mouse_move 5 0", "mouse_move 0 7", "mouse_button 1", "mouse_button 0"):
    s.sendall((cmd + "\n").encode())
    time.sleep(0.3)
    drain()
s.close()
open(done, "w").write("sent\n")
PYEOF

echo "=== HID mouse deferred-drain smoke (four reports complete before one drain; every one is delivered) ==="

echo "[build] HID_MOUSE_DEFER_SELFTEST=1, then plain (the tree is left plain)"
HID_MOUSE_DEFER_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-mdf.log" 2>&1 \
    || { echo "ERROR: HID_MOUSE_DEFER_SELFTEST build failed ($LOGS/build-mdf.log)"; sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-mdf"
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 \
    || { echo "ERROR: plain build failed ($LOGS/build-plain.log) — this gate measured NOTHING"; exit 1; }

echo "[C] the instrument is present in the test kernel and absent from production"
if strings "$WORK/agnos-mdf" | grep -qF 'hidmdf: PASS'; then ok "the test kernel carries the instrument"
else bad "the test kernel does NOT carry the instrument — HID_MOUSE_DEFER_SELFTEST never reached the source"; fi
if strings "$ROOT/build/agnos" | grep -qF 'hidmdf:'; then bad "the PLAIN production kernel carries the deferred-drain instrument"
else ok "the deferred-drain instrument is compiled out of production"; fi

boot() {   # $1 kernel copy, $2 smp, $3 label; sets LOG; returns 1 on VOID
    W="$WORK/$3"; mkdir -p "$W"
    IMG="$W/d.img"; LOG="$LOGS/$3.log"; MON="$W/mon.sock"; DONE="$W/injected"
    dd if=/dev/zero of="$IMG" bs=1M count=64 status=none                               || die "[$3] image: dd of the 64 MB disk failed"
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1 || die "[$3] image: parted failed"
    mformat -i "$IMG"@@1048576 -F                                                      || die "[$3] image: mformat of the ESP failed"
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot                                     || die "[$3] image: mmd failed"
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI                         || die "[$3] image: copying gnoboot onto the ESP failed"
    mcopy -i "$IMG"@@1048576 "$1" ::boot/agnos                                         || die "[$3] image: copying the kernel onto the ESP failed"
    mcopy -n -i "$IMG"@@1048576 ::boot/agnos "$W/agnos.readback" && cmp -s "$W/agnos.readback" "$1" \
        || die "[$3] image: the kernel read back from the ESP is not the kernel under test"
    rm -f "$W/agnos.readback" "$DONE"
    python3 "$WORK/inject.py" "$LOG" "$MON" "$DONE" &
    INJ_PID=$!
    ACC=$(smoke_accel "$2")
    [ "$2" -gt 1 ] && echo "  accel: $ACC"
    qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-150}" "$W/vars.fd" "$OVMF_VARS" \
        qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$2" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" \
        -device "nvme,drive=d0,serial=AGNOS-HMDF,bootindex=0" \
        -device qemu-xhci,id=xhci \
        -device "usb-kbd,bus=xhci.0" \
        -device "usb-mouse,bus=xhci.0" \
        -monitor "unix:$MON,server,nowait" \
        -serial stdio -display none -no-reboot
    kill "$INJ_PID" 2>/dev/null; wait "$INJ_PID" 2>/dev/null; INJ_PID=""
    rm -f "$IMG"
    if ! qemu_assert_booted "$LOG"; then echo "  VOID: [$3] the kernel never ran — no assertion scored"; void=1; return 1; fi
    if strings "$LOG" | grep -qF "hidmdf: window open" && [ ! -f "$DONE" ]; then
        die "[$3] the window opened but the injector never reached the QEMU monitor ($MON)"
    fi
    return 0
}

for SMP in ${HID_MDF_SMP:-1 4}; do
    echo "[smp$SMP] deferred-drain kernel, -smp $SMP"
    if boot "$WORK/agnos-mdf" "$SMP" "mdf-smp$SMP"; then
        want  "hid: mouse configured"                                                "[smp$SMP] the usb-mouse bound"
        wantk "hidmdf: window open - IF=0 and the drain held; inject now"           "[smp$SMP] the held window opened"
        if [ -f "$DONE" ]; then ok "[smp$SMP] the injector sent the four mouse events"; else bad "[smp$SMP] the injector never ran"; fi
        wantk "hidmdf: dx of the first report delivered OK"                         "[smp$SMP] the first report's motion survived the second"
        wantk "hidmdf: dy of the second report delivered once OK"                   "[smp$SMP] the second report's motion was folded once, not per event"
        wantk "hidmdf: the press edge inside the window delivered OK"               "[smp$SMP] a press inside the gap was delivered"
        wantk "hidmdf: the release edge delivered last OK"                          "[smp$SMP] the release was delivered last"
        wantk "hidmdf: PASS"                                                        "[smp$SMP] the selftest passed"
        deny  "hidmdf: (FAIL|VOID)"                                                 "[smp$SMP] no hidmdf failure line"
        deny  "$SMOKE_INVARIANT_DENY"                                               "[smp$SMP] no latched kernel invariant fired (whole boot)"
        klines "$LOG" | grep -E '^hidmdf:' | sed 's/^/        /'
    fi
done

echo "=== hid-mouse-deferred-smoke: $pass passed, $fail failed$( [ "$void" = 1 ] && echo ', VOID boot(s)') — logs in $LOGS ==="
if [ "$fail" -gt 0 ]; then echo "hid-mouse-deferred-smoke: FAIL"; exit 1; fi
if [ "$void" = 1 ]; then echo "hid-mouse-deferred-smoke: VOID"; exit 2; fi
echo "hid-mouse-deferred-smoke: PASS"
exit 0
