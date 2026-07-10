#!/bin/bash
# agnova-boot-smoke — the native-install arc CLOSER. agnova (the sovereign AGNOS installer)
# writes the ENTIRE boot medium natively — GPT + FAT32 ESP + a journal-less ext2 root, plus
# all staging — with NO parted / mformat / mcopy / mkfs.ext2 shell-out. A PRODUCTION kernel
# then boots that medium and kybernet (PID 1) execs /bin/agnsh from the ext2 root that AGNOS's
# own installer built. This is "AGNOS installs AGNOS, then boots what it wrote."
#
# Contrast with agnsh-smoke.sh (which builds the same medium via parted+mformat+mkfs.ext2 -d):
# here every byte of GPT, FAT, and ext2 comes from agnova/diskfmt. Same PASS bar.
#
# PASS = kybernet reaches "exec /bin/agnsh" AND does NOT print "emergency shell".
#
# Build first:  ./scripts/build.sh                          (plain production kernel)
#               (in agnova) cyrius build src/main.cyr build/agnova
#               (in agnoshi) cyrius build --agnos src/agnsh.cyr build/agnsh_agnos
#               (in gnoboot) the BOOTX64.EFI
# Requires: qemu-system-x86_64, OVMF, dd, strings — NO parted/mtools/mkfs (that's the point).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"
AGNOVA_ROOT="${AGNOVA_ROOT:-$ROOT/../agnova}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
AGNOVA="$AGNOVA_ROOT/build/agnova"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built ($AGNSH)"; exit 1; }
[ -x "$AGNOVA" ]  || { echo "ERROR: agnova not built ($AGNOVA) — 'cyrius build src/main.cyr build/agnova' in agnova"; exit 1; }

WORK="$ROOT/build/agnova-boot-smoke"; LOGS="$ROOT/build/agnova-boot-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-agnova.img"

# 1 GiB target — agnova's default layout is a 512 MiB ESP + root filling the rest; the ext2 root
# fs caps at one block-group (128 MiB), which comfortably holds /bin/agnsh.
dd if=/dev/zero of="$IMG" bs=1M count=1024 status=none

echo "agnova execute --disk-backend=native-file --until bootloader (sovereign GPT+FAT+ext2, no parted/mkfs) ..."
"$AGNOVA" execute --device "$IMG" --disk-backend=native-file --until bootloader \
    --user test --i-mean-it \
    --gnoboot-src "$GNOBOOT" --kernel-src "$AGNOS" --agnsh-src "$AGNSH" 2>&1 | sed 's/^/  /'

cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/agnova-boot.log"
echo ""
echo "Booting production kernel against the agnova-written medium (NVMe)..."
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AGNOVA" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | sed 's/^/  /'
echo ""

rc=0
if strings "$LOG" | grep -q "kybernet: exec /bin/agnsh"; then
    echo "  PASS: kybernet reached exec /bin/agnsh (from the agnova-written ext2 root)"
else
    echo "  FAIL: kybernet did not reach the agnsh exec"; rc=1
fi
if strings "$LOG" | grep -q "kybernet: emergency shell"; then
    echo "  FAIL: fell back to the in-kernel emergency shell (agnsh did not launch)"; rc=1
else
    echo "  PASS: did NOT fall back to the emergency shell"
fi
echo ""
if [ "$rc" -eq 0 ]; then
    echo "agnova-boot-smoke: PASS — AGNOS installed AGNOS natively (no parted/mkfs) and booted what it wrote"
else
    echo "agnova-boot-smoke: FAIL"
fi
exit $rc
