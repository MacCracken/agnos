#!/bin/sh
# net-tool-smoke.sh — boots a NET_SELFTEST kernel against an ext2 rootfs holding
# /bin/dig (+ /bin/agnsh) with SLIRP virtio-net, so kybernet's NET_SELFTEST hook
# runs `dig @10.0.2.3 example.com` — the FIRST end-to-end exercise of the ring-3
# UDP syscalls (#51-54) by a real userland net tool. Combines agnsh-smoke's
# ESP+ext2 image with dns-smoke's virtio-net.
#
# Build the kernel first:  NET_SELFTEST=1 sh scripts/build.sh
# Stage dig:               sh scripts/stage-tools.sh   (puts build/rootfs/bin/dig)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
DIG="$ROOT/build/rootfs/bin/dig"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$DIG" ]     || { echo "ERROR: /bin/dig not staged ($DIG) — run scripts/stage-tools.sh"; exit 1; }
if ! strings "$AGNOS" | grep -q "NET_SELFTEST exec /bin/dig"; then
    echo "ERROR: kernel not built with NET_SELFTEST=1 — rebuild: NET_SELFTEST=1 sh scripts/build.sh"; exit 1
fi

WORK="$ROOT/build/net-tool-smoke"; LOGS="$ROOT/build/net-tool-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-net.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="${EXT2_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$DIG" "$SEED/bin/dig"
[ -f "$AGNSH" ] && cp "$AGNSH" "$SEED/bin/agnsh"
echo "seeded /bin/dig ($(stat -c%s "$SEED/bin/dig") bytes)$([ -f "$SEED/bin/agnsh" ] && echo ' + /bin/agnsh')"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-NET -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/net.log"
echo "=== AGNOS net-tool smoke (dig @10.0.2.3 example.com over the ring-3 UDP syscalls) ==="
echo "Booting NET_SELFTEST kernel (ext2 /bin/dig + SLIRP virtio-net)..."
timeout "${QEMU_TIMEOUT:-45}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-NET" \
    -netdev "user,id=u1" \
    -device "virtio-net-pci,netdev=u1" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "--- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | sed 's/^/  /'
echo "-----------------------------------"

pass=0; fail=0
if strings "$LOG" | grep -q "kybernet: NET_SELFTEST exec /bin/dig"; then
    echo "PASS: kybernet launched /bin/dig"; pass=$((pass+1))
else
    echo "FAIL: kybernet did not reach the dig launch"; fail=$((fail+1))
fi
if strings "$LOG" | grep -q "kybernet: NET_SELFTEST dig done"; then
    echo "PASS: /bin/dig ran to completion (exec-from-disk + ring-3 run OK)"; pass=$((pass+1))
else
    echo "FAIL: dig did not run to completion (crash / hang in the agnos backend?)"; fail=$((fail+1))
fi
echo ""
echo "--- any dig output captured on serial (resolved record?) ---"
strings "$LOG" | grep -iE "example\.com|ANSWER|IN[[:space:]]+A|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v "10.0.2" | head -10 || echo "(none on serial — dig output may be FB-only)"
echo "============================================================"
echo "net-tool-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
