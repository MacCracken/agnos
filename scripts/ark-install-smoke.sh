#!/bin/bash
# ark-install-smoke — the ark v2 M3 milestone: an on-agnos install of a prebuilt
# `.ark` that CARRIES A SYMLINK, end to end.
#
# Stages the real ~16 MB ark binary + a takumi-built symlink-bearing `.ark`
# (`/lib/libfoo.so.1` regular file + `/lib/libfoo.so` -> `libfoo.so.1` symlink) on
# an ext2 root, and the ARK_INSTALL_SELFTEST kernel hook runs
# `ark install --root /arkroot /symlink-test.ark`. ark reads + verifies the
# package, lays the file down (pass 1), then in pass 2 calls `ark_symlink` -> the
# cyrius `sys_symlink`#63 agnos peer -> kernel `symlink`#63 -> `ext2_symlink`,
# creating the symlink ON THE AGNOS-FS. PASS = host-side the installed tree under
# `/arkroot/lib` has `libfoo.so` as a symlink -> `libfoo.so.1`, the file is
# present, and the partition is e2fsck-clean ([[feedback_qemu_test_agnos_userland]]).
#
# Prereqs:  ARK_INSTALL_SELFTEST=1 ./scripts/build.sh
#           ark agnos build at ../ark/build/ark_agnos (cyrius build --agnos)
#           fixture at ../takumi/build/fixture/symlink-test.ark (tests/mkfixture)
# KVM strongly recommended (16 MB load); set ARK_NO_KVM=1 to force TCG.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
ARK_BIN="${ARK_BIN:-$ROOT/../ark/build/ark_agnos}"
FIXTURE="${FIXTURE:-$ROOT/../takumi/build/fixture/symlink-test.ark}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ARK_INSTALL_SELFTEST=1 ./scripts/build.sh"; exit 1; }
[ -f "$ARK_BIN" ] || { echo "ERROR: ark agnos build not at $ARK_BIN"; exit 1; }
[ -f "$FIXTURE" ] || { echo "ERROR: fixture not at $FIXTURE (build it with takumi tests/mkfixture)"; exit 1; }

KVM_ARGS="-enable-kvm -cpu host"
{ [ -n "${ARK_NO_KVM:-}" ] || [ ! -e /dev/kvm ]; } && KVM_ARGS="-cpu max"

WORK="$ROOT/build/ark-install-smoke"; LOGS="$ROOT/build/ark-install-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-ark-install.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BLOCKS=$(( 95 * 1048576 / 4096 ))
FEAT="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

# Seed: /bin/ark (the installer) + /symlink-test.ark (the package). /arkroot is
# created by ark's apkg_mkdir_parents during the install.
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ARK_BIN" "$SEED/bin/ark"; chmod +x "$SEED/bin/ark"
cp "$FIXTURE" "$SEED/symlink-test.ark"
echo "Staging ark ($(stat -c%s "$SEED/bin/ark") B) + fixture ($(stat -c%s "$SEED/symlink-test.ark") B); building image..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-ARKI -b 4096 -m 0 -O "$FEAT" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting ARK_INSTALL_SELFTEST kernel ($KVM_ARGS)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/ark-install.log"
timeout "${QEMU_TIMEOUT:-150}" qemu-system-x86_64 -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-ARKI" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""; echo "  --- install lines from boot log ---"
strings "$LOG" | grep -E "exec: .*ark install|Installed|ark: |run: exit|#PF|PANIC|^fault:" | sed 's/^/  /'
echo ""

rc=0
# Serial signal (secondary): ark reported a successful install.
if strings "$LOG" | grep -q "Installed libfoo"; then
    echo "  PASS: ark reported 'Installed libfoo' on agnos"
else
    echo "  WARN: no 'Installed libfoo' on serial (host-side symlink check is the load-bearing gate)"
fi
if strings "$LOG" | grep -qE "#PF|PANIC|^fault:"; then
    echo "  FAIL: fault/panic during the install:"; strings "$LOG" | grep -E "#PF|PANIC|^fault:|CR2|RIP" | sed 's/^/        /' | head; rc=1
fi

# --- host verification: the install laid the file + symlink onto the agnos-fs ---
dd if="$IMG" bs=1M skip=33 count=95 of="$WORK/part-post.img" status=none
echo "  --- host debugfs: /arkroot/lib ---"
debugfs -R "ls -l /arkroot/lib" "$WORK/part-post.img" 2>/dev/null | sed 's/^/  /'
SL="$(debugfs -R "stat /arkroot/lib/libfoo.so" "$WORK/part-post.img" 2>/dev/null)"
FILE_OK=$(debugfs -R "stat /arkroot/lib/libfoo.so.1" "$WORK/part-post.img" 2>&1 | grep -c "Inode:")
if echo "$SL" | grep -q "Type: symlink"; then
    echo "  PASS: /arkroot/lib/libfoo.so is a symlink on the agnos-fs (ark pass-2 -> sys_symlink#63)"
else
    echo "  FAIL: /arkroot/lib/libfoo.so is not a symlink (the install did not create it)"; rc=1
fi
if echo "$SL" | grep -q 'Fast link dest: "libfoo.so.1"'; then
    echo "  PASS: symlink target == \"libfoo.so.1\""
else
    echo "  FAIL: symlink target is not \"libfoo.so.1\""; rc=1
fi
if [ "$FILE_OK" = "1" ]; then
    echo "  PASS: /arkroot/lib/libfoo.so.1 (the regular file) was laid down"
else
    echo "  FAIL: /arkroot/lib/libfoo.so.1 missing (pass-1 file install failed)"; rc=1
fi
echo ""; echo "  --- e2fsck -fn ---"
if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then
    echo "  PASS: e2fsck -fn clean (the install didn't corrupt the FS)"
else
    echo "  FAIL: e2fsck problems:"; sed 's/^/        /' "$LOGS/e2fsck.log"; rc=1
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "ark-install-smoke: PASS — ark M3: on-agnos .ark-with-symlinks install round-trip"
else
    echo "ark-install-smoke: FAIL (full serial: $LOG)"
fi
exit $rc
