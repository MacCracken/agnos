#!/bin/bash
# de-smoke — does a ring-3 DIVIDE BY ZERO kill the process, or the machine?
#
# ⭐ THIS TEST EXISTS BECAUSE A BURN FOUND THE BUG. On the rung-10 flash (2026-07-25)
# /bin/gputri --bench divided by a zero timing and archaemenid FROZE mid-line — no fault
# message, no CMOS stamp, no prompt, hard power cycle. Vector 0 (#DE) sat in idt.cyr's
# "deliberately NOT installed" list, so the bare-iretq default returned straight to the
# faulting idiv, which divided by zero again, forever.
#
# ⛔ A userland arithmetic mistake must never halt the kernel. PASS = the deliberate #DE kills
# the proc and BOOT CONTINUES to a prompt. A regression here is a HANG, which is exactly why
# this is an automated gate rather than something anyone re-checks by hand.
#
# ⚠ It needs a REAL ext2 agnos-fs (the DE_SELFTEST hook writes /bin/divz and execs it), so this
# clones de-smoke's image builder rather than the ESP-only one — the first attempt used an
# ESP-only image, ext2_active stayed 0, and the selftest returned silently with its strings
# present in the binary. String present is not code called.
#
# Build first:  DE_SELFTEST=1 sh scripts/build.sh
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run DE_SELFTEST=1 ./scripts/build.sh"; exit 1; }
# ⛔ VERIFY THE FLAG LANDED, not merely that a build exists. A mode flag whose #define was never
# emitted ships a silent no-op. ⚠ NECESSARY BUT NOT SUFFICIENT — the string lives in the
# function body, so it appears as soon as the function COMPILES even if nothing CALLS it. That
# is exactly how the first run of this smoke passed the guard while the hook never ran (it was
# called ~450 lines too early, before ext2 was mounted). The log assertions are the real gate.
if ! strings "$AGNOS" | grep -q "de: ring-3 divide by zero"; then
    echo "ERROR: kernel not built with DE_SELFTEST=1 — rebuild:"
    echo "       DE_SELFTEST=1 sh scripts/build.sh"
    exit 1
fi

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${DE_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — falling back to TCG; the 16 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/de-smoke"
LOGS="$ROOT/build/de-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-de.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 95 * 1048576 ))             # 95 MiB ext2 — roomy for the 16 MB ark
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
printf 'archaemenid\n' > "$SEED/etc/hostname"
echo "Building the ext2 image (the DE hook creates /bin/divz itself)..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-ARK -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting DE_SELFTEST kernel ($KVM_ARGS)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/de.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
qemu_dwell "$LOG" "agnos>" "${QEMU_TIMEOUT:-120}" \
    qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-ARK" \
    -serial stdio -display none -no-reboot

echo ""
echo "  --- #DE lines from the boot log ---"
strings "$LOG" | grep -E "^de:|^run: exit|#PF|PANIC|^fault:|AGNOS shell|agnos>" | sed 's/^/  /'
echo ""

pass=0; fail=0
chk() { if strings "$LOG" | grep -q "$1"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $3"; fail=$((fail+1)); fi; }

chk "de: ring-3 divide by zero" \
    "the DE_SELFTEST hook actually RAN (string present is not code called)" \
    "the hook never ran -- check ext2_active and the call site, not the #define"
chk "de: SURVIVED" \
    "⭐ the kernel is STILL RUNNING after a ring-3 divide by zero" \
    "THE KERNEL HUNG on the #DE. Vector 0 is not reaching the ring3-kill path -- this is the exact freeze that took archaemenid down on the rung-10 burn."
chk "de: PASS proc slot reclaimed" \
    "the faulting proc was killed and its slot reclaimed -- no leak" \
    "the proc slot leaked after the #DE kill"

echo ""
[ "$fail" -eq 0 ] && { echo "=== de-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== de-smoke: $pass passed, $fail failed ==="; exit 1
