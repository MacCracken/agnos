#!/bin/sh
# H3 — /bin/modeset + syscall #93 gpu_modeset_op. The ring-3 modeset seam, end to end under QEMU.
#
# THE CLAIM: a ring-3 tool reaches the kernel over #93, the kernel validates a descriptor array and writes
# the modeset caps back, and the tool's exit code is decisive with NO GPU present. Under QEMU there is no AMD
# GPU, so the caps report display DARK / seam live and the tool exits 96 — the informational "no lit display
# here" code, distinct from an ABI error (97) or a real iron result (95).
#
# This is the ABI + tool proof. The ACTUAL modeset (M-lane: dump / measure / OTG re-commit / transmitter) is
# iron work added as new op codes to this SAME #93 behind the H2 arm-once latch — no new syscall number.
#
# Build first:  MODESET_TOOL_SELFTEST=1 sh scripts/build.sh
#               ( and the tool: cd gpu-test && cyrius build --agnos modeset.cyr build/modeset_agnos )
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, cyrius.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "modeset: running /bin/modeset"; then
    echo "ERROR: kernel not built with MODESET_TOOL_SELFTEST=1 — rebuild:" >&2
    echo "       MODESET_TOOL_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

# Build the ring-3 tool (agnos target). Uses sys_gpu_modeset_op (#93), which only exists on the agnos target.
TOOL="$ROOT/gpu-test/build/modeset_agnos"
echo "Building /bin/modeset (agnos)..."
( cd "$ROOT/gpu-test" && cyrius build --agnos modeset.cyr build/modeset_agnos ) >/dev/null 2>&1 \
    || { echo "ERROR: tool build failed" >&2; exit 1; }
[ -f "$TOOL" ] || { echo "ERROR: tool binary not produced at $TOOL" >&2; exit 1; }

WORK="$ROOT/build/modeset-tool-smoke"; LOGS="$ROOT/build/modeset-tool-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
PART_OFFSET=$(( 33 * 1048576 )); PART_BLOCKS=$(( 67 * 1048576 / 4096 ))

# Seed the ext2 FS with the tool at /bin/modeset.
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$TOOL" "$SEED/bin/modeset"
echo "modeset tool seed" > "$SEED/hello.txt"

IMG="$WORK/agnos-modeset.img"
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-MSET -b 4096 -m 0 -O "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting MODESET_TOOL_SELFTEST kernel..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/modeset-tool.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-MSET" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- modeset tool output ---"
grep -aE "^modeset:|^run:" "$LOG" | sed 's/^/  /'
echo "---------------------------"

pass=0; fail=0
want()  { if grep -aq "$2" "$1"; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $4"; fail=$((fail+1)); fi; }
wantno(){ if grep -aq "$2" "$1"; then echo "FAIL: $4"; fail=$((fail+1)); else echo "PASS: $3"; pass=$((pass+1)); fi; }

# The tool reached ring 3 and produced its own output — proves exec-from-disk + the tool ran.
want "$LOG" "modeset: caps OK" \
     "the tool ran in ring 3 and #93 returned a valid caps read" \
     "no 'caps OK' — the tool did not run or #93 failed (see error lines above)"
# The op-support mask must be exactly 31 (bit0 NOP + bit1 CAPS + bit2 DUMP + bit3 LOCK + bit4 VTOTAL). A 0 here would mean a constant collapsed.
want "$LOG" "modeset: opmask=31" \
     "the op-support mask is 31 (NOP + CAPS + DUMP + LOCK + VTOTAL) — the kernel wrote real caps, not zeros" \
     "opmask != 31 — the caps write is wrong or a constant read 0"
# Under QEMU there is no AMD GPU, so the display must read DARK — this is what makes exit 96 the right answer.
want "$LOG" "modeset: display DARK" \
     "the caps honestly report no lit display under QEMU" \
     "display not reported DARK — the caps flags are wrong"
# ⛔ An ABI error line must NOT appear — that would mean the descriptor array was rejected.
wantno "$LOG" "modeset: #93 error" \
     "no #93 ABI/validation error" \
     "#93 rejected the descriptor — the record layout or validation is wrong"
# THE decisive oracle: the klug-capturable exit code. 96 = seam live, no lit display (the QEMU result).
want "$LOG" "run: exit 96" \
     "★ run: exit 96 — the modeset seam is live end to end (ring-3 tool -> #93 -> caps), no GPU present" \
     "not 'run: exit 96' — read the exit code above (95=lit iron, 97=ABI err, 98=latch blocked, 99=unexpected)"
# --dump arg path (M1/M2/M3). Proves argv reaches the tool and routes to the DUMP op. Under QEMU there is no
# DCN, so the dump op returns reason 1 (no GPU) — which is itself the proof the op DISPATCHED (a #93 ABI
# error would be reason 2/11/12; a broken argv would fall through to caps and never print a dump line).
want "$LOG" "modeset: #93 dump error idx=0 reason=1" \
     "★ --dump routed to the DUMP op and returned reason 1 (no DCN under QEMU) — argv works, op dispatched" \
     "--dump did not reach the DUMP op — argv broken, or the op rejected the record (not reason 1)"
# --lock arg path (M4 OTG-lock proof). Under QEMU there is no DCN, so mdo_lock refuses at the gpu_present
# gate and returns reason 1 — BEFORE arming the latch or writing anything. Same shape as --dump: reason 1
# proves the LOCK op DISPATCHED (an ABI error would be reason 2/11/12; a broken argv would fall to caps).
want "$LOG" "modeset: #93 lock error idx=0 reason=1" \
     "★ --lock routed to the LOCK op and returned reason 1 (no DCN under QEMU) — the M4 write op dispatched, no register touched" \
     "--lock did not reach the LOCK op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ Under QEMU the latch must NOT have armed — the gpu_present gate precedes modeset_arm, so a latch-armed
# line here would mean M4 armed before refusing (arming with nothing to protect).
wantno "$LOG" "modeset: latch armed at site=4" \
     "the M4 op refused BEFORE arming the latch under QEMU (gpu_present gate precedes the arm)" \
     "M4 armed the latch under QEMU — the gpu_present gate must precede modeset_arm"
# --vtotal arg path (M5 first real modeset). Under QEMU there is no DCN, so mdo_vtotal refuses at gpu_present
# and returns reason 1 BEFORE arming or writing — proving the VTOTAL op dispatched without risking a modeset.
want "$LOG" "modeset: #93 vtotal error idx=0 reason=1" \
     "★ --vtotal routed to the VTOTAL op and returned reason 1 (no DCN under QEMU) — the M5 modeset op dispatched, no register touched" \
     "--vtotal did not reach the VTOTAL op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ Under QEMU M5 must NOT have armed either — the gpu_present gate precedes modeset_arm(5).
wantno "$LOG" "modeset: latch armed at site=5" \
     "the M5 op refused BEFORE arming the latch under QEMU (gpu_present gate precedes the arm)" \
     "M5 armed the latch under QEMU — the gpu_present gate must precede modeset_arm"
# The recovery boot must still reach the shell (the tool runs must not wedge the boot).
want "$LOG" "Launching kybernet" \
     "the boot reached the shell (the tool runs did not wedge)" \
     "boot did not reach kybernet"

echo ""
[ "$fail" -eq 0 ] && { echo "=== modeset-tool-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== modeset-tool-smoke: $pass passed, $fail failed ==="; exit 1
