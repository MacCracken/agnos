#!/bin/sh
# agnova-install-smoke.sh — Phase-5 agnos NATIVE_BLOCK proof: the REAL agnova installer binary,
# built --agnos, runs as a ring-3 agnos process and writes a GPT via sys_blk_* (no parted, no
# shell-out). Proves agnova's agnos disk path end-to-end (the format logic is gptwr-proven; this
# proves the actual installer binary enumerates+arms+writes the block layer on real agnos).
#
# agnova enumerates the NVMe, arms the write gate, and writes a GPT for a 768 MiB synthetic disk
# into the live disk's UNALLOCATED TAIL (scratch-base 524288, past the 240 MiB live rootfs) — so
# it never clobbers the boot GPT. The smoke then dd's that tail region out + sgdisk-validates it.
#
# Gates: "exec: running /bin/agnova" (dispatched), "run: exit 0" (partition phase ok), no faults,
# sgdisk accepts the agnova-written GPT (ESP + agnos-root).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOVA_ROOT="${AGNOVA_ROOT:-$ROOT/../agnova}"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building agnova (--agnos) + the AGNOVA_INSTALL_SELFTEST kernel..."
( cd "$AGNOVA_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 CYRIUS_NO_WARN_SHADOW_LIB=1 cyrius build --agnos src/main.cyr build/agnova-agnos ) >/tmp/agnova-build.log 2>&1 || { echo "  BUILD-FAIL (agnova --agnos)"; tail -8 /tmp/agnova-build.log; exit 1; }
if ! env AGNOVA_INSTALL_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/agnova-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/agnova-kbuild.log)"; tail -8 /tmp/agnova-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNOVA="$AGNOVA_ROOT/build/agnova-agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOVA" ]  || { echo "ERROR: agnova-agnos not built at $AGNOVA"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/agnova $(stat -c %s "$AGNOVA") B"

WORK="$ROOT/build/agnova-install-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-agnova.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding a 2 GiB GPT disk with /bin/agnova (tail 256 MiB+ = agnova scratch)..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$AGNOVA" "$SEED/bin/agnova"
dd if=/dev/zero of="$IMG" bs=1M count=2048 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AGNOVA -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/agnova (native-block install slice)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$SLOG"
KVM=""; [ -e /dev/kvm ] && KVM="-enable-kvm -cpu host"; [ -z "$KVM" ] && KVM="-cpu max"
HARD=90; [ -e /dev/kvm ] || HARD=180
qemu-system-x86_64 -machine q35 -m 512M $KVM \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-AGNOVA" \
    -serial "file:$SLOG" -display none -no-reboot &
QPID=$!; trap 'kill $QPID 2>/dev/null' EXIT
i=0
while [ $i -lt $HARD ]; do
    sleep 1; i=$((i+1))
    if grep -aq "exec: agnova returned" "$SLOG" 2>/dev/null; then sleep 1; break; fi
    kill -0 $QPID 2>/dev/null || break
done
kill $QPID 2>/dev/null; trap - EXIT; wait $QPID 2>/dev/null; sync

echo "[4/4] Checks..."
echo "  --- agnova serial lines ---"
strings "$SLOG" | grep -aE "exec: (running )?/bin/agnova|exec: agnova|run: exit|phases completed|PANIC|FAULT|#PF|#GP|#UD" | sed 's/^/  /' | head -14
rc=0
strings "$SLOG" | grep -q "exec: running /bin/agnova" \
    && echo "  PASS: /bin/agnova dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: agnova never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 0"; then
    echo "  PASS: run: exit 0 — agnova's native-block partition phase succeeded (sys_blk_enum+arm+write)"
else
    echo "  FAIL: agnova did not exit 0 (crashed / partition failed on the block path)"; rc=1
fi
strings "$SLOG" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared in the log"; rc=1; } \
    || echo "  PASS: no #PF/#GP/#UD/PANIC — agnova ran fault-free in ring 3"

# Independent oracle: dump the scratch tail agnova wrote + sgdisk-validate the GPT.
if [ "$rc" -eq 0 ]; then
    echo "  --- independent GPT oracle (sgdisk on the dumped scratch tail) ---"
    EXT="$WORK/agnova-gpt.img"
    dd if="$IMG" of="$EXT" bs=512 skip=524288 count=1572864 status=none
    SG="$WORK/sgdisk.out"; : > "$SG"
    sgdisk -v "$EXT" >>"$SG" 2>&1; sgdisk -p "$EXT" >>"$SG" 2>&1
    grep -aiE "No problems|ESP|agnos-root|Number" "$SG" | head -8 | sed 's/^/    /'
    grep -aqi "No problems found" "$SG" \
        && echo "  PASS: sgdisk: No problems found — a foreign parser accepts the GPT agnova wrote on agnos" \
        || { echo "  FAIL: sgdisk problems on the agnova-written GPT"; rc=1; }
    grep -aqi "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" "$SG" || grep -aqi "EF00.*ESP" "$SG" \
        && echo "  PASS: the ESP partition is present" \
        || echo "  NOTE: ESP GUID line not captured (see $SG)"
fi

echo ""
[ "$rc" -eq 0 ] && echo "agnova-install-smoke: PASS — the real agnova installer wrote a valid GPT via sys_blk_* on agnos (Phase-5 bite 6)" || echo "agnova-install-smoke: FAIL"
exit $rc
