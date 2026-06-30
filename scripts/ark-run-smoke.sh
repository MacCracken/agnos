#!/bin/bash
# ark-run-smoke — does the real ~16 MB ark binary LOAD + RUN in ring 3 on agnos?
#
# Server-stage probe for the ark v2 M3 on-agnos `.ark` install: ark is by far the
# largest binary attempted on agnos (kriya 934 KB / doom 589 KB are the prior
# ceiling; a 6.1.14 pin once miscompiled a 934 KB binary). Step 1 is just whether
# exec-from-disk + elf_load can stream a 15.9 MB ELF (with ~14 MB static .bss) and
# have its ring-3 code reach write(1). Driven DETERMINISTICALLY by the kernel's
# ARK_SELFTEST hook (`run /bin/ark`) — NOT agnsh keystrokes, which dropped chars on
# a 16 MB target. ark with no args prints "Unknown command. Available: ..." + exits.
#
# Build the kernel first:  ARK_SELFTEST=1 ./scripts/build.sh
# Stage the agnos ark:     cp <ark>/build/ark_agnos build/ark-rootfs/bin/ark
# KVM strongly recommended (a 16 MB load under TCG is very slow): set ARK_NO_KVM=1
# to force TCG.  Requires: qemu, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, strings.
#
# PASS = serial shows ark's command list ("Available:" + "install") AND the box
# survives (no #PF/PANIC/fault). Exit 0 if so; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
ARK_REPO="${ARK_REPO:-$ROOT/../ark}"

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
ARK_BIN="${ARK_BIN:-$ARK_REPO/build/ark_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ARK_SELFTEST=1 ./scripts/build.sh"; exit 1; }
[ -f "$ARK_BIN" ] || { echo "ERROR: ark agnos build not at $ARK_BIN — cyrius build --agnos src/main.cyr build/ark_agnos in ark"; exit 1; }
case "$(file -b "$ARK_BIN" 2>/dev/null)" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $ARK_BIN is not a static x86-64 ELF64"; exit 1 ;;
esac

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${ARK_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — falling back to TCG; the 16 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/ark-run-smoke"
LOGS="$ROOT/build/ark-run-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-ark.img"
PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
PART_BYTES=$(( 95 * 1048576 ))             # 95 MiB ext2 — roomy for the 16 MB ark
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp "$ARK_BIN" "$SEED/bin/ark"; chmod +x "$SEED/bin/ark"
printf 'archaemenid\n' > "$SEED/etc/hostname"
ARK_SZ=$(stat -c%s "$SEED/bin/ark")
echo "Staging ark ($ARK_SZ bytes) + building image..."

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

echo "Booting ARK_SELFTEST kernel ($KVM_ARGS)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/ark-selftest.log"
timeout "${QEMU_TIMEOUT:-120}" qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-ARK" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- ark / exec lines from boot log ---"
strings "$LOG" | grep -E "^exec: .*ark|^run: exit|Available:|Unknown command|^Usage|#PF|PANIC|^fault:" | sed 's/^/  /'
echo ""

rc=0
# Gate 1: ark loaded + ran + wrote its CLI output to the console. ark with no
# command argument prints "No command specified. Usage: ark ..."; an unknown
# command prints "Unknown command. Available: ...". Either proves the 15.9 MB ELF
# loaded, ran in ring 3, parsed argv, and reached write(1).
if strings "$LOG" | grep -qE "No command specified|Usage: ark|Available:|Unknown command"; then
    echo "  PASS: ark loaded + ran in ring 3 — its CLI output reached the console (15.9 MB ELF off ext2)"
else
    echo "  FAIL: no ark CLI output — ark did not produce ring-3 output"; rc=1
fi
# Gate 2: clean exit (the recovery shell reports the program's exit code).
if strings "$LOG" | grep -qE "^run: exit"; then
    echo "  PASS: ark exited cleanly ($(strings "$LOG" | grep -oE '^run: exit [0-9-]+' | head -1))"
else
    echo "  WARN: no 'run: exit' (ark may have produced output but not returned — see log)"
fi
# Gate 3: the box survived (no fault/panic during the 16 MB load or ark's run).
if strings "$LOG" | grep -qE "#PF|PANIC|^fault:"; then
    echo "  FAIL: a fault/panic marker appeared (16 MB exec stressed exec-from-disk/elf_load):"
    strings "$LOG" | grep -E "#PF|PANIC|^fault:|CR2|RIP" | sed 's/^/        /' | head; rc=1
else
    echo "  PASS: no fault/panic — the box survived loading + running the 16 MB binary"
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "ark-run-smoke: PASS — the 15.9 MB ark binary loads + runs in ring 3 on agnos"
else
    echo "ark-run-smoke: FAIL (full serial: $LOG)"
fi
exit $rc
