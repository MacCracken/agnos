#!/bin/bash
# whirl-smoke — boot a production AGNOS kernel in QEMU with the full rootfs
# (/bin/agnsh + /bin/whirl + the net-tools family), bring up virtio-net under
# SLIRP user-mode networking, then drive agnsh through a USB-xHCI keyboard to
# (1) exec /bin/whirl --help  — proves the 1.1 MB binary exec-from-disk + ring-3
#     run + sys_write output (the large-binary de-risk), and
# (2) whirl http://example.com — proves the sovereign net stack end-to-end:
#     taar DNS (udp_*#51-54 → SLIRP → host resolver) + TCP (sock_*#47-50 →
#     SLIRP NAT) + whirl's HTTP framing, fetching a real page.
#
# SLIRP gives the guest 10.0.2.15/24 (the kernel sets this statically when
# virtio-net is present); outbound NAT forwards to the host (which must have
# internet). NOT Docker — Docker can't give raw sockets; QEMU hands the kernel
# its own NIC, so this is the same path that runs on iron.
#
# Build first:  ./scripts/build.sh            (production kernel)
#               ./scripts/burn/stage-agnsh.sh --build && ./scripts/burn/stage-tools.sh --build
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools,
#           sgdisk, mkfs.ext2, python3, strings.
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
ROOTFS="$ROOT/build/rootfs"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$ROOTFS/bin/agnsh" ] || { echo "ERROR: $ROOTFS/bin/agnsh missing — run stage-agnsh.sh --build"; exit 1; }
[ -f "$ROOTFS/bin/whirl" ] || { echo "ERROR: $ROOTFS/bin/whirl missing — run stage-tools.sh --build"; exit 1; }

WORK="$ROOT/build/whirl-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-whirl.img"; SER="$WORK/serial.log"; MON="/tmp/agnos-whirl-mon.sock"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 95 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="${EXT2_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

echo "=== building disk image (ESP + ext2 rootfs with /bin/whirl) ==="
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-WHIRL -b 4096 -m 0 -O "$EXT2_FEATURES" \
    -d "$ROOTFS" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS
echo "  seeded /bin: $(ls "$ROOTFS/bin" | tr '\n' ' ')"

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SER"; rm -f "$MON"

KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"
[ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"

echo "=== booting QEMU (virtio-net + SLIRP; $( [ -e /dev/kvm ] && echo KVM || echo TCG )) ==="
qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-WHIRL" \
    -netdev "user,id=u1" -device "virtio-net-pci,netdev=u1" \
    -device "qemu-xhci,id=xhci" -device "usb-kbd,bus=xhci.0" \
    -serial "file:$SER" -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" >/dev/null 2>&1 &
QPID=$!

python3 - "$SER" "$MON" "$WORK/result.txt" <<'PYEOF'
import socket, sys, time
SER, MON, RES = sys.argv[1], sys.argv[2], sys.argv[3]
def ser():
    try: return open(SER,"rb").read().decode("latin1")
    except OSError: return ""
s=None
for _ in range(80):
    try: s=socket.socket(socket.AF_UNIX); s.connect(MON); break
    except OSError: time.sleep(0.25)
if s is None: print("FAIL: no QEMU monitor"); sys.exit(1)
s.settimeout(1.0)
def drain():
    try:
        while True: s.recv(65536)
    except OSError: pass
# wait for the agnsh banner
ok=False
for _ in range(160):
    if "agnoshi" in ser(): ok=True; break
    time.sleep(0.25)
print("banner seen:", ok)
km={' ':'spc','\n':'ret','-':'minus','.':'dot','/':'slash',':':'shift-semicolon','_':'shift-minus'}
def typ(word, settle):
    # prime: the first sendkey after an idle gap is dropped by the xHCI HID warmup,
    # so lead with a throwaway `ret` (harmless on an empty prompt). The real command
    # then rides the warmed path — its first char survives.
    s.sendall(b"sendkey ret\n"); time.sleep(0.10); drain()
    for ch in word:
        s.sendall(("sendkey "+km.get(ch,ch)+"\n").encode()); time.sleep(0.10); drain()
    time.sleep(settle)
def fetch(cmd, label, tries):
    # sendkey drops random chars on long bursts (xHCI HID flakiness). Only JUDGE
    # an attempt whose echoed command line is exactly right — otherwise a typo'd
    # domain ("connection failed" for a wrong host) would masquerade as a TLS
    # failure. Retry on typo; on a clean type, body=OK, "connection failed"=real.
    # ⚠ THE CLEAN-TYPED TALLY RIDES BACK OUT WITH THE VERDICT and is written into
    # result.txt. NOCLEAN is a FAILURE in the shell below (it means the command never
    # reached the guest, so the property was never exercised) — and "0 of 12 attempts
    # typed cleanly" is the line that tells the reader it was the KEYBOARD that never
    # landed a command, not TLS that broke. A bare "FAIL" with no denominator would
    # send the next reader hunting the net stack for a host-load artifact.
    print(">>>", label, "(judging only clean-typed attempts)")
    clean=0; used=0
    for attempt in range(tries):
        used=attempt+1
        a0=len(ser())
        typ(cmd+"\n", 16.0)
        d=ser()[a0:]
        if cmd not in d:
            print("  "+label+": attempt", attempt+1, "TYPO (dropped key) — retry"); continue
        clean+=1
        if "Example Domain" in d:
            print("  "+label+": OK — clean type, page body fetched (attempt", attempt+1, ")"); return "OK", clean, used, tries
        if "connection failed" in d:
            print("  "+label+": clean type but CONNECTION FAILED (real)"); return "CONNFAIL", clean, used, tries
        print("  "+label+": clean type, no body yet (attempt", attempt+1, ") — retry")
    # NOCLEAN is the only exit that consumed the whole budget, so here used == tries; that is what
    # makes "0/12" in the shell's NOCLEAN arm a true denominator rather than a guess.
    return "NOCLEAN", clean, used, tries
m1=len(ser()); print(">>> whirl --help"); typ("whirl --help\n", 4.0)
m2=len(ser())
hr, hclean, hused, htries = fetch("whirl http://example.com",  "HTTP fetch",  4)
m3=len(ser())
sr, sclean, sused, stries = fetch("whirl https://example.com", "HTTPS fetch", 12)
end=len(ser())
print("WHIRL-HTTP-RESULT:",  hr, "(%d of %d attempts typed cleanly, budget %d)"%(hclean,hused,htries))
print("WHIRL-HTTPS-RESULT:", sr, "(%d of %d attempts typed cleanly, budget %d)"%(sclean,sused,stries))
# Key names are load-bearing: the shell reads these with anchored greps ('^HTTP=', '^HTTPS=',
# '^HTTPS_CLEAN='), and '^HTTP=' deliberately does NOT match 'HTTP_CLEAN=' or 'HTTPS='.
open(RES,"w").write("HTTP=%s\nHTTPS=%s\nHTTP_CLEAN=%d\nHTTP_TRIES=%d\nHTTPS_CLEAN=%d\nHTTPS_TRIES=%d\n"
                    %(hr,sr,hclean,htries,sclean,stries))
print("===== serial after 'whirl --help' ====="); print(ser()[m1:m2])
print("===== serial after HTTP fetch ====="); print(ser()[m2:m3][-1200:])
print("===== serial after HTTPS fetch ====="); print(ser()[m3:end][-1600:])
try: s.sendall(b"quit\n")
except OSError: pass
PYEOF
# The driver's exit status is kept so the verdict can name WHY there is no verdict. Its own
# `sys.exit(1)` on "no QEMU monitor" writes no result.txt at all, and until 1.56.58 that state
# reached the HTTPS case arm as an empty string and was printed as a WARN.
DRV_RC=$?

sleep 1; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
echo ""
echo "=== verdict ==="
rc=0
RES="$WORK/result.txt"
HTTP_R="$(grep '^HTTP='  "$RES" 2>/dev/null | cut -d= -f2)"
HTTPS_R="$(grep '^HTTPS=' "$RES" 2>/dev/null | cut -d= -f2)"
HTTPS_CLEAN="$(grep '^HTTPS_CLEAN=' "$RES" 2>/dev/null | cut -d= -f2)"
HTTPS_TRIES="$(grep '^HTTPS_TRIES=' "$RES" 2>/dev/null | cut -d= -f2)"
if grep -qiE "curl . wget|usage: whirl|sovereign Cyrius" "$SER"; then echo "  PASS: whirl exec-from-disk ran (--help output captured)"; else echo "  FAIL: no whirl --help output (exec or render failed)"; rc=1; fi
if [ "$HTTP_R" = "OK" ];  then echo "  PASS: whirl HTTP  fetched example.com over the sovereign stack (page body captured)"; else echo "  FAIL: whirl HTTP  fetch did not land a page body ($HTTP_R)"; rc=1; fi

# ⚠ VACUITY FLOOR — "WE COULD NOT TEST IT" IS NOT "IT WORKS".
# Until 1.56.58 the catch-all arm below printed `WARN: ... inconclusive` and left rc ALONE, so the
# two states that mean THIS GATE ASSERTED NOTHING both exited 0 and turned the sweep gate green:
#   · NOCLEAN — the driver's 12 sendkey attempts each dropped a character (python `return "NOCLEAN"`
#     above), so `whirl https://example.com` never reached the guest and NO TLS connection was ever
#     opened. Under host load or an xHCI HID stall that is the ordinary outcome, not a rare one.
#   · ""      — result.txt does not exist, or no longer carries a line matching `^HTTPS=`. The
#     driver's own `sys.exit(1)` on "no QEMU monitor" takes the first path, the `2>/dev/null` on the
#     grep above swallows the missing file, and a renamed key would take the second silently. A
#     driver that never ran produced an empty verdict that the old catch-all called a warning.
# The rule this violated was already written down elsewhere in this directory —
# console-line-smoke.sh:15-17, "'we could not test it' and 'it works' must never be the same
# colour" — and implemented there at :42 with `exit 1`. Both states are failures here too.
# ⭐ AND THE DENOMINATOR IS PRINTED, NOT IMPLIED. A run that says "0/12 attempts typed cleanly" is
# reporting that its own driver never reached the assertion; one that says "3/12" is reporting a
# real TLS result. A bare FAIL would send the next reader hunting the net stack for a keyboard bug.
case "$HTTPS_R" in
  OK)       echo "  PASS: whirl HTTPS fetched example.com (tls_native over taar; cert-verified)";;
  CONNFAIL) echo "  FAIL: whirl HTTPS clean-typed but connection failed — real TLS-over-sock issue"; rc=1;;
  NOCLEAN)  echo "  FAIL: whirl HTTPS never got a clean-typed attempt (${HTTPS_CLEAN:-0}/${HTTPS_TRIES:-?} attempts typed cleanly, keyboard drops) — the TLS path was NEVER EXERCISED; inconclusive is not a pass, see serial.log"; rc=1;;
  *)        echo "  FAIL: whirl HTTPS has no verdict at all (driver rc=${DRV_RC:-unknown}; no '^HTTPS=' line in $RES) — the driver did not finish, so nothing was tested"; rc=1;;
esac
echo "  --- net diagnostics from serial ---"
strings "$SER" | grep -iE "VirtIO-net|Net: 10|dhcp: ACK|whirl:|connection|bad URL|Example Domain" | sed 's/^/    /' | tail -20
echo "  full serial: $SER"
exit $rc
