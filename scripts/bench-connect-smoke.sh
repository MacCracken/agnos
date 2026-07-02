#!/bin/bash
# bench-connect-smoke — measure agnos hoosh CONNECT latency (post-1.51.3 busy-poll)
# through the real net stack, to compare against Linux native. Boots hoosh (--agnos)
# in QEMU with virtio-net + SLIRP and runs its `bench` connect loop against a host
# listener reachable at 10.0.2.2:18085 (SLIRP forwards the guest's 10.0.2.2 to the
# host's 127.0.0.1). Reads "bench: … avg=Nus/connect" off the serial log.
#
# Build the kernel first:  BENCH_CONNECT_SELFTEST=1 ./scripts/build.sh
# Stage the agnos hoosh:    cyrius build --agnos src/main.cyr build/hoosh_agnos  (in hoosh)
# KVM recommended (a ~15 MB load under TCG is slow): ARK_NO_KVM=1 forces TCG.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
HOOSH_BIN="${HOOSH_BIN:-$ROOT/../hoosh/build/hoosh_agnos}"
PORT=18085
N="${N:-2000}"                                   # connects per bench run
TARGET="${TARGET:-http://10.0.2.100}"            # guestfwd addr (→ host 127.0.0.1:$PORT), port 80 default

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run BENCH_CONNECT_SELFTEST=1 ./scripts/build.sh"; exit 1; }
[ -f "$HOOSH_BIN" ] || { echo "ERROR: hoosh agnos build not at $HOOSH_BIN"; exit 1; }
strings "$AGNOS" | grep -q "running probe-cmd" || { echo "ERROR: kernel not built with BENCH_CONNECT_SELFTEST=1"; exit 1; }

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${ARK_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || KVM_ARGS="-cpu max"

WORK="$ROOT/build/bench-connect-smoke"; LOGS="$ROOT/build/bench-connect-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-bench.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 95 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp "$HOOSH_BIN" "$SEED/bin/probe"; chmod +x "$SEED/bin/probe"
printf 'archaemenid\n' > "$SEED/etc/hostname"
printf 'run /bin/probe bench %s %s\n' "$TARGET" "$N" > "$SEED/etc/probe-cmd"
echo "Staging hoosh ($(stat -c%s "$SEED/bin/probe") bytes) + /etc/probe-cmd='run /bin/probe bench $TARGET $N' + building image..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-BENCH -b 4096 -m 0 -O "$EXT2_SMOKE_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

# Host listener the guest reaches at 10.0.2.2:PORT (SLIRP → host 127.0.0.1:PORT).
python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$PORT)); s.listen(4096)
while True:
    try: c,_=s.accept(); c.close()
    except Exception: break
" 2>/dev/null &
SVPID=$!
trap 'kill $SVPID 2>/dev/null' EXIT

echo "Booting BENCH kernel ($KVM_ARGS) — virtio-net + SLIRP, hoosh bench → 10.0.2.2:$PORT..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/bench.log"
timeout "${QEMU_TIMEOUT:-160}" qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-BENCH" \
    -netdev "user,id=u1,guestfwd=tcp:10.0.2.100:80-tcp:127.0.0.1:$PORT" -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"
kill $SVPID 2>/dev/null

echo ""
echo "  --- net / bench lines from boot log ---"
strings "$LOG" | grep -E "dhcp: ACK|dhcp:|RAM:|running /bin/probe bench|bench:|#PF|PANIC|^fault:" | sed 's/^/  /'
echo ""
if strings "$LOG" | grep -qE "bench:.*avg="; then
    echo "PASS: agnos hoosh connect bench ran through the net stack:"
    strings "$LOG" | grep -oE "bench:.*avg=[0-9]+us/connect" | tail -1 | sed 's/^/    agnos: /'
    exit 0
else
    echo "FAIL: no 'bench: … avg=' on serial (full log: $LOG)"
    exit 1
fi
