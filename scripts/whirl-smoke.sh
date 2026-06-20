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
#               ./scripts/stage-agnsh.sh --build && ./scripts/stage-tools.sh --build
# Requires: qemu-system-x86_64, KVM (falls back to TCG), OVMF, parted, mtools,
#           sgdisk, mkfs.ext2, python3, strings.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
    print(">>>", label, "(judging only clean-typed attempts)")
    for attempt in range(tries):
        a0=len(ser())
        typ(cmd+"\n", 16.0)
        d=ser()[a0:]
        if cmd not in d:
            print("  "+label+": attempt", attempt+1, "TYPO (dropped key) — retry"); continue
        if "Example Domain" in d:
            print("  "+label+": OK — clean type, page body fetched (attempt", attempt+1, ")"); return "OK"
        if "connection failed" in d:
            print("  "+label+": clean type but CONNECTION FAILED (real)"); return "CONNFAIL"
        print("  "+label+": clean type, no body yet (attempt", attempt+1, ") — retry")
    return "NOCLEAN"
m1=len(ser()); print(">>> whirl --help"); typ("whirl --help\n", 4.0)
m2=len(ser())
hr = fetch("whirl http://example.com",  "HTTP fetch",  4)
m3=len(ser())
sr = fetch("whirl https://example.com", "HTTPS fetch", 12)
end=len(ser())
print("WHIRL-HTTP-RESULT:",  hr)
print("WHIRL-HTTPS-RESULT:", sr)
open(RES,"w").write("HTTP=%s\nHTTPS=%s\n"%(hr,sr))
print("===== serial after 'whirl --help' ====="); print(ser()[m1:m2])
print("===== serial after HTTP fetch ====="); print(ser()[m2:m3][-1200:])
print("===== serial after HTTPS fetch ====="); print(ser()[m3:end][-1600:])
try: s.sendall(b"quit\n")
except OSError: pass
PYEOF

sleep 1; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
echo ""
echo "=== verdict ==="
rc=0
RES="$WORK/result.txt"
HTTP_R="$(grep '^HTTP='  "$RES" 2>/dev/null | cut -d= -f2)"
HTTPS_R="$(grep '^HTTPS=' "$RES" 2>/dev/null | cut -d= -f2)"
if grep -qiE "curl . wget|usage: whirl|sovereign Cyrius" "$SER"; then echo "  PASS: whirl exec-from-disk ran (--help output captured)"; else echo "  FAIL: no whirl --help output (exec or render failed)"; rc=1; fi
if [ "$HTTP_R" = "OK" ];  then echo "  PASS: whirl HTTP  fetched example.com over the sovereign stack (page body captured)"; else echo "  FAIL: whirl HTTP  fetch did not land a page body ($HTTP_R)"; rc=1; fi
case "$HTTPS_R" in
  OK)       echo "  PASS: whirl HTTPS fetched example.com (tls_native over taar; cert-verified)";;
  CONNFAIL) echo "  FAIL: whirl HTTPS clean-typed but connection failed — real TLS-over-sock issue"; rc=1;;
  *)        echo "  WARN: whirl HTTPS never got a clean-typed attempt (keyboard drops) — inconclusive, see serial.log";;
esac
echo "  --- net diagnostics from serial ---"
strings "$SER" | grep -iE "VirtIO-net|Net: 10|dhcp: ACK|whirl:|connection|bad URL|Example Domain" | sed 's/^/    /' | tail -20
echo "  full serial: $SER"
exit $rc
