#!/bin/sh
# gpt-boot-smoke.sh — Phase 4 ARC-CLOSER (Bite 9): boot a disk that AGNOS partitioned,
# formatted, and populated ITSELF, with zero host parted/mkfs.fat/mcopy.
#
# Two QEMU boots:
#   BOOT 1 (write): a GPT_WRITE_SELFTEST kernel on a live 1 GiB disk runs /bin/gptwr, which
#     builds a complete GPT + FAT32 ESP in the disk's UNALLOCATED TAIL and copies gnoboot ->
#     \EFI\BOOT\BOOTX64.EFI and a PRODUCTION kernel -> \boot\agnos into it (reading both from
#     the rootfs). Gate: "run: exit 97".
#   BOOT 2 (prove): dd that tool-written region out to a fresh standalone image, seed its P2
#     rootfs with /bin/agnsh (host mkfs.ext2 -d), and boot it. UEFI runs the TOOL-WRITTEN
#     gnoboot, which loads the TOOL-WRITTEN \boot\agnos, which boots -> kybernet (PID 1) mounts
#     the rootfs (via the kernel's real GPT reader + ext2 Linux-FS-GUID gate, on tool-authored
#     bytes) and execs /bin/agnsh.
#
# PASS = "kybernet: exec /bin/agnsh" AND no "emergency shell" AND no fault, on the second boot.
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, strings, cyrius.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"
BLK_ROOT="$ROOT/blk-test"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built at $AGNSH"; exit 1; }

# --- Tool-side geometry (MUST match gptwr.cyr) ---
SCRATCH_BASE=524288          # gptwr SCRATCH
SYN_SECTORS=131072           # gptwr synthetic N'
P2_FIRST=71680               # rootfs partition first LBA (gptwr RF_S)
P2_LAST=131038               # rootfs partition last LBA (gptwr RF_E = N'-34)
P2_OFFSET=$(( P2_FIRST * 512 ))
P2_BLOCKS=$(( (P2_LAST - P2_FIRST + 1) * 512 / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[1/6] Building gptwr (--agnos) + a PRODUCTION kernel + a GPT_WRITE_SELFTEST kernel..."
( cd "$BLK_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build gptwr.cyr build/gptwr --agnos ) >/tmp/gptb-tool.log 2>&1 || { echo "  BUILD-FAIL (gptwr)"; tail -8 /tmp/gptb-tool.log; exit 1; }
sh "$ROOT/scripts/build.sh" >/tmp/gptb-prod.log 2>&1 || { echo "  BUILD-FAIL (production kernel)"; tail -8 /tmp/gptb-prod.log; exit 1; }
cp "$ROOT/build/agnos" "$ROOT/build/agnos-prod"
env GPT_WRITE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/gptb-st.log 2>&1 || { echo "  BUILD-FAIL (selftest kernel)"; tail -8 /tmp/gptb-st.log; exit 1; }
GPTWR="$BLK_ROOT/build/gptwr"; AGNOS_ST="$ROOT/build/agnos"; AGNOS_PROD="$ROOT/build/agnos-prod"
echo "  gptwr $(stat -c %s "$GPTWR") B  |  selftest-kernel $(stat -c %s "$AGNOS_ST") B  |  production-kernel $(stat -c %s "$AGNOS_PROD") B  |  agnsh $(stat -c %s "$AGNSH") B"

WORK="$ROOT/build/gpt-boot-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/live.img"; SLOG1="$WORK/serial-write.log"

echo "[2/6] Seeding a live 1 GiB GPT disk: ESP boots the SELFTEST kernel; rootfs holds gptwr + the blobs..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/stage"
cp "$GPTWR" "$SEED/bin/gptwr"
cp "$GNOBOOT" "$SEED/stage/bootx64.efi"     # gptwr writes this -> the tool ESP's \EFI\BOOT\BOOTX64.EFI
cp "$AGNOS_PROD" "$SEED/stage/kernel"       # gptwr writes this -> the tool ESP's \boot\agnos (PRODUCTION)
dd if=/dev/zero of="$IMG" bs=1M count=1024 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS_ST" ::boot/agnos            # live boot runs the SELFTEST kernel
mkfs.ext2 -F -q -L AGNOS-GPTB -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$(( 33 * 1048576 )) "$IMG" $(( 200 * 1048576 / 4096 ))

echo "[3/6] BOOT 1 (write): running /bin/gptwr — building the tool-authored ESP in the tail..."
cp "$OVMF_VARS_SRC" "$WORK/vars1.fd"; chmod +w "$WORK/vars1.fd"; : > "$SLOG1"
KVM=""; [ -e /dev/kvm ] && KVM="-enable-kvm -cpu host"; [ -z "$KVM" ] && KVM="-cpu max"
H1=240; [ -e /dev/kvm ] || H1=420
qemu-system-x86_64 -machine q35 -m 512M $KVM \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars1.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-GPTB" \
    -serial "file:$SLOG1" -display none -no-reboot &
Q1=$!; trap 'kill $Q1 2>/dev/null' EXIT
i=0; while [ $i -lt $H1 ]; do sleep 1; i=$((i+1)); grep -aq "exec: gptwr returned" "$SLOG1" 2>/dev/null && { sleep 1; break; }; kill -0 $Q1 2>/dev/null || break; done
kill $Q1 2>/dev/null; trap - EXIT; wait $Q1 2>/dev/null; sync
if strings "$SLOG1" | grep -q "run: exit 97"; then
    echo "  PASS: gptwr wrote the complete ESP (run: exit 97)"
else
    echo "  FAIL: gptwr did not reach exit 97 — the tool ESP was not written"; strings "$SLOG1" | grep -aE "run: exit|#PF|#GP|PANIC" | head -4 | sed 's/^/    /'; exit 1
fi

echo "[4/6] Extracting the tool-written region -> a fresh standalone GPT disk..."
BOOTIMG="$WORK/tool-built.img"
dd if="$IMG" of="$BOOTIMG" bs=512 skip=$SCRATCH_BASE count=$SYN_SECTORS status=none
# Sanity: an independent parser must accept the extracted GPT before we try to boot it.
sgdisk -v "$BOOTIMG" >"$WORK/sgdisk.out" 2>&1
grep -aqi "No problems found" "$WORK/sgdisk.out" && echo "  PASS: sgdisk accepts the extracted GPT" || { echo "  FAIL: extracted GPT is invalid"; sed 's/^/    /' "$WORK/sgdisk.out" | head -4; exit 1; }
# Sanity: the tool-written \boot\agnos must be the production kernel byte-for-byte.
if mcopy -i "$BOOTIMG"@@1048576 ::/boot/agnos "$WORK/out-agnos" 2>/dev/null && cmp -s "$WORK/out-agnos" "$AGNOS_PROD"; then
    echo "  PASS: the ESP's \\boot\\agnos == the production kernel byte-for-byte"
else
    echo "  FAIL: the tool-written kernel does not match the production kernel"; exit 1
fi

echo "[5/6] Seeding the extracted image's P2 rootfs with /bin/agnsh (offset $P2_OFFSET, $P2_BLOCKS blocks)..."
SEED2="$WORK/seed2"; mkdir -p "$SEED2/bin"; cp "$AGNSH" "$SEED2/bin/agnsh"
mkfs.ext2 -F -q -L AGNOS-BOOT -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED2" -E offset=$P2_OFFSET "$BOOTIMG" $P2_BLOCKS

echo "[6/6] BOOT 2 (prove): booting the disk AGNOS built itself..."
SLOG2="$WORK/serial-boot.log"; cp "$OVMF_VARS_SRC" "$WORK/vars2.fd"; chmod +w "$WORK/vars2.fd"; : > "$SLOG2"
H2=60; [ -e /dev/kvm ] || H2=120
qemu-system-x86_64 -machine q35 -m 512M $KVM \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars2.fd" \
    -drive "file=$BOOTIMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-BOOT" \
    -serial "file:$SLOG2" -display none -no-reboot &
Q2=$!; trap 'kill $Q2 2>/dev/null' EXIT
i=0; while [ $i -lt $H2 ]; do sleep 1; i=$((i+1)); grep -aqE "kybernet: exec /bin/agnsh|kybernet: emergency shell|agnsh" "$SLOG2" 2>/dev/null && { sleep 2; break; }; kill -0 $Q2 2>/dev/null || break; done
kill $Q2 2>/dev/null; trap - EXIT; wait $Q2 2>/dev/null; sync

echo ""
echo "  --- second-boot tail (the disk gptwr built) ---"
strings "$SLOG2" | sed -n '/kybernet: starting init/,$p' | head -14 | sed 's/^/    /'
[ -s "$SLOG2" ] && strings "$SLOG2" | grep -aqE "kybernet" || { echo "    (no kybernet output — showing last lines)"; strings "$SLOG2" | tail -8 | sed 's/^/    /'; }
echo ""
rc=0
strings "$SLOG2" | grep -q "kybernet: starting init" \
    && echo "  PASS: the tool-written kernel booted to kybernet (gnoboot loaded \\boot\\agnos from the FAT gptwr wrote)" \
    || { echo "  FAIL: kybernet never started — the tool-written ESP did not boot"; rc=1; }
if strings "$SLOG2" | grep -q "kybernet: exec /bin/agnsh"; then
    echo "  PASS: kybernet mounted the rootfs (real GPT reader + ext2 Linux-FS-GUID gate on TOOL bytes) and exec'd /bin/agnsh"
else
    echo "  FAIL: kybernet did not reach the /bin/agnsh exec"; rc=1
fi
strings "$SLOG2" | grep -q "kybernet: emergency shell" \
    && { echo "  FAIL: fell back to the emergency shell (agnsh did not launch)"; rc=1; } \
    || echo "  PASS: no emergency-shell fallback"
strings "$SLOG2" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared during the boot"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC during the boot"

echo ""
[ "$rc" -eq 0 ] && echo "gpt-boot-smoke: PASS — a disk AGNOS partitioned, formatted, and populated ITSELF booted to /bin/agnsh (1.53.x Phase 4 Bite 9, ARC-CLOSER)" || echo "gpt-boot-smoke: FAIL"
exit $rc
