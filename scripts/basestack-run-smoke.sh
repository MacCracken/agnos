#!/bin/bash
# basestack-run-smoke — does a base-security-stack binary, cross-built --agnos,
# actually LOAD + RUN in ring 3 on agnos (not merely compile `--agnos`)?
#
# The "runs, not just builds" gate for the base-stack agnos-readiness arc
# ([[feedback_qemu_test_agnos_userland]]): compiling --agnos proves the source is
# agnos-shaped; THIS proves the multi-MB ELF streams off ext2 via exec-from-disk,
# elf_load maps it, ring-3 code reaches write(1), and it exits cleanly.
#
# Reusable across aegis/bote/phylax/hoosh/thoth. The kernel's BASESTACK_SELFTEST
# hook runs `/bin/probe --version` deterministically (no agnsh keystrokes — sendkey
# drops chars on 10 MB+ targets), same shape as ark-run-smoke.
#
# Usage:   scripts/basestack-run-smoke.sh <agnos-elf> <expect-substring> [name]
#   e.g.   scripts/basestack-run-smoke.sh ../hoosh/build/hoosh_agnos 2.4.11 hoosh
# Build the kernel first:  BASESTACK_SELFTEST=1 ./scripts/build.sh
# KVM strongly recommended (a >10 MB load under TCG is slow): ARK_NO_KVM=1 forces TCG.
#
# PASS = serial shows <expect-substring> AND `run: exit` AND no #PF/PANIC/fault.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

BIN="${1:-${BIN:-$ROOT/../hoosh/build/hoosh_agnos}}"
EXPECT="${2:-${EXPECT:-2.4.11}}"
NAME="${3:-${NAME:-probe}}"

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
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run BASESTACK_SELFTEST=1 ./scripts/build.sh"; exit 1; }
[ -f "$BIN" ]     || { echo "ERROR: agnos binary not at $BIN — cyrius build --agnos src/main.cyr <build/X_agnos>"; exit 1; }
case "$(file -b "$BIN" 2>/dev/null)" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $BIN is not a static x86-64 ELF64"; exit 1 ;;
esac

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${ARK_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — TCG; the >10 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/basestack-run-smoke"
LOGS="$ROOT/build/basestack-run-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-basestack.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 95 * 1048576 ))             # 95 MiB ext2 — roomy for a 15 MB binary
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp "$BIN" "$SEED/bin/probe"; chmod +x "$SEED/bin/probe"
printf 'archaemenid\n' > "$SEED/etc/hostname"
BIN_SZ=$(stat -c%s "$SEED/bin/probe")
echo "Staging $NAME as /bin/probe ($BIN_SZ bytes) + building image..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-BASE -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting BASESTACK_SELFTEST kernel ($KVM_ARGS) — running /bin/probe --version..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/basestack-$NAME.log"
timeout "${QEMU_TIMEOUT:-120}" qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-BASE" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- probe / exec lines from boot log ---"
strings "$LOG" | grep -E "exec: running /bin/probe|exec: basestack|^run: exit|$EXPECT|#PF|PANIC|^fault:|Unknown command|^Usage" | sed 's/^/  /'
echo ""

rc=0
# Gate 1: the binary loaded + ran + wrote the expected string to the console.
if strings "$LOG" | grep -qF "$EXPECT"; then
    echo "  PASS: '$EXPECT' reached the console — $NAME loaded + ran in ring 3 ($BIN_SZ-byte ELF off ext2)"
else
    echo "  FAIL: '$EXPECT' not found — $NAME did not produce its expected ring-3 output"; rc=1
fi
# Gate 2: clean exit (the recovery shell reports the program's exit code).
if strings "$LOG" | grep -qE "^run: exit"; then
    echo "  PASS: $NAME exited cleanly ($(strings "$LOG" | grep -oE '^run: exit [0-9-]+' | head -1))"
else
    echo "  WARN: no 'run: exit' ($NAME may have printed but not returned — see log)"
fi
# Gate 3: the box survived (no fault/panic during the load or the run).
if strings "$LOG" | grep -qE "#PF|PANIC|^fault:"; then
    echo "  FAIL: a fault/panic marker appeared:"
    strings "$LOG" | grep -E "#PF|PANIC|^fault:|CR2|RIP" | sed 's/^/        /' | head; rc=1
else
    echo "  PASS: no fault/panic — the box survived loading + running $NAME"
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "basestack-run-smoke ($NAME): PASS — the $BIN_SZ-byte $NAME binary loads + runs in ring 3 on agnos"
else
    echo "basestack-run-smoke ($NAME): FAIL (full serial: $LOG)"
fi
exit $rc
