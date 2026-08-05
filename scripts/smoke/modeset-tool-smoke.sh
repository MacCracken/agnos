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
#               ( and the tool: cd tests/gpu && cyrius build --agnos modeset.cyr build/modeset_agnos )
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, cyrius.

set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
TOOL="$ROOT/tests/gpu/build/modeset_agnos"
echo "Building /bin/modeset (agnos)..."
# ⚠ tests/gpu since the 1.56.22 move (was gpu-test/). This line still pointed at the old directory
# and the `cd` failed, so the smoke aborted with "tool build failed" — a build error that reads like
# the TOOL being broken rather than the path. Found by the cross-repo path sweep, not by a run.
( cd "$ROOT/tests/gpu" && cyrius build --agnos modeset.cyr build/modeset_agnos ) >/dev/null 2>&1 \
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
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
qemu_dwell "$LOG" "agnos>" "${QEMU_TIMEOUT:-40}" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-MSET" \
    -serial stdio -display none -no-reboot

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
# The op-support mask must be EXACTLY the value this build's flags call for, and the two legal values are
# not interchangeable — the mask is the ABI's self-description, so a wrong one is a lie the tool believes.
#  7807 = the plain set: NOP CAPS DUMP LOCK VTOTAL RECOMMIT TRANSMIT PIXCLK CRCCAL NATIVE PAN  (no M9 arms)
#  8191 = the above + AUDIO_PRE + AUDIO_POST                                                       (MODESET_AUDIO_ARMS)
# ⚠ These were 127 / 511 until 1.56.33 added MDO_OP_PIXCLK (bit 9, +512), then 1663 / 2047 with CRCCAL
# (bit 10, +1024), and 1.56.36 added MDO_OP_NATIVE (bit 11, +2048) and MDO_OP_PAN (bit 12, +4096) to BOTH.
# Neither carries any audio content, so gating either on MODESET_AUDIO_ARMS would have put the
# native-resolution and console-pan paths in the audio-experiment kernel only — the exact "advertised in
# one build" defect this pair of assertions exists for.
# PIXCLK is advertised UNCONDITIONALLY on the TRANSMIT precedent — the op IS implemented and a kernel that cannot derive
# a PLL answers with the specific MDO_E_NOPLL rather than a generic "unknown op". ⛔ If you are here
# because this assertion failed, check whether an op was added WITHOUT updating both values: the
# mask is the ABI's self-description and a stale expectation here trains the operator to ignore it.
# ⚠ Checking BOTH directions matters more than checking either. If this only ever asserted 127, a build that
# forgot MODESET_AUDIO_ARMS would advertise the audio arms as ABSENT and the tool would report "wrong
# kernel" — but a build that wrongly advertised them would sail through, and the operator would spend a burn
# running a "treatment" the kernel cannot actually perform. The `wantno` below is what closes that.
# ⚠ The expectation is derived from the KERNEL BINARY, never from the environment this script happens to be
# invoked with. The env says what someone MEANT to build; only the artifact says what got built, and the
# whole ATOM_DRY lesson is that those two diverge silently. `MODESET_AUDIO_ARMS` is by construction
# MODESET_AUDIO ∧ ATOM_TX_CYCLE, so testing for one string from each conjunct reconstructs it exactly.
K_AUDIO=0; K_CYCLE=0
strings "$AGNOS" | grep -q "ARM 1 CONTROL: unmute BEFORE the edge" && K_AUDIO=1
strings "$AGNOS" | grep -q "ATOM #76 CYCLE: DISABLE then ENABLE" && K_CYCLE=1
echo "  (kernel flags read from the binary: MODESET_AUDIO=$K_AUDIO ATOM_TX_CYCLE=$K_CYCLE)"
if [ "$K_AUDIO" = 1 ] && [ "$K_CYCLE" = 1 ]; then
  want "$LOG" "modeset: opmask=8191" \
       "the op-support mask is 8191 — the M9 audio arms ARE advertised, as MODESET_AUDIO_ARMS requires" \
       "opmask != 8191 — MODESET_AUDIO_ARMS did not reach MDO_OP_SUPPORTED, so --audio-pre/--audio-post cannot dispatch"
  wantno "$LOG" "modeset: opmask=7807" \
       "the mask is not the un-armed 7807 — the widening is real, not a stale constant" \
       "opmask=7807 in an ARMED build — the derived flag never took"
else
  want "$LOG" "modeset: opmask=7807" \
       "the op-support mask is 7807 (the full plain op set incl. NATIVE + PAN) — the kernel wrote real caps, not zeros" \
       "opmask != 7807 — the caps write is wrong or a constant read 0"
  wantno "$LOG" "modeset: opmask=8191" \
       "⛔ the M9 audio arms are ABSENT from this build — an unarmed kernel must not advertise them" \
       "opmask=8191 without MODESET_AUDIO+ATOM_TX_CYCLE — the kernel is advertising ops whose experiment does not exist"
fi
# --pixclk arg path (1.56.33 ATOM #12). ⛔ THIS ASSERTION WAS MISSING FOR THE WHOLE OF 1.56.33 — the cut
# that added the flag — while the file's own selftest comment states the rule: exercise every flag the
# operator is told to type. Under QEMU mdo_pixclk refuses at gpu_present (reason 1) before deriving
# anything or reaching gpu_pixclk_source_check, so reason 1 proves the PIXCLK op DISPATCHED.
want "$LOG" "modeset: #93 pixclk idx=0 reason=1" \
     "★ --pixclk routed to the PIXCLK op and returned reason 1 (no DCN under QEMU) — the ATOM #12 seam dispatched, no table run" \
     "--pixclk did not reach the PIXCLK op — argv broken, or the op rejected the record (not reason 1)"
# --crccal arg path (1.56.34, the CRC null calibration). Under QEMU mdo_crccal refuses at gpu_present
# (reason 1) BEFORE hda_hdmi_feed_stop() — so reason 1 proves the CRCCAL op dispatched with the codec feed
# and the AFMT block untouched. ⚠ This op STOPS AND STARTS THE CODEC FEED on real hardware; a dispatch bug
# discovered on iron would be discovered mid-experiment, which is what this gate exists to prevent.
want "$LOG" "modeset: #93 crccal idx=0 reason=1" \
     "★ --crccal routed to the CRCCAL op and returned reason 1 (no DCN under QEMU) — the calibration op dispatched, codec feed untouched" \
     "--crccal did not reach the CRCCAL op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ And the calibration must NOT have run its phases under QEMU — a refusal that still stopped the feed
# would be a refusal in name only. None of the three phase banners may appear.
wantno "$LOG" "CRCCAL -- N1: the NULL case" \
     "⛔ the CRCCAL phases did NOT run under QEMU — it refused before touching the codec feed" \
     "CRCCAL ran its NULL phase with no GPU present — the gpu_present gate does not precede the feed stop"
# --native arg path (1.56.36, NATIVE RESOLUTION). Under QEMU mdo_native refuses at gpu_present (reason 1)
# BEFORE reading boot_info, before arming, and before any OTG or HUBP write — so reason 1 proves the NATIVE
# op dispatched with the pipe untouched. Same rule as --pixclk before it: exercise every flag the operator
# is told to type, or the iron burn is the first place a dispatch bug is found.
want "$LOG" "modeset: #93 native idx=0 reason=1" \
     "★ --native routed to the NATIVE op and returned reason 1 (no DCN under QEMU) — the native-resolution op dispatched, pipe not touched" \
     "--native did not reach the NATIVE op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ And it must have refused BEFORE the envelope: no arm, and above all no OTG_MASTER_EN write. This op
# disables the live pipe and reprograms HUBP geometry — the write class that hung this box once already —
# so "it refused at the gpu_present gate" has to be provable, not assumed.
wantno "$LOG" "modeset: latch armed at site=11" \
     "the NATIVE op refused BEFORE arming the latch under QEMU (gpu_present gate precedes the arm)" \
     "NATIVE armed the latch under QEMU — the gpu_present gate must precede modeset_arm"
wantno "$LOG" "modeset: native -- OTG_MASTER_EN 0" \
     "the NATIVE op did NOT disable the pipe under QEMU (refused at the gpu_present gate first)" \
     "NATIVE disabled the pipe under QEMU — the gpu_present gate must precede any OTG write"
# --pan arg path (1.56.36, the console hardware pan). Under QEMU mdo_pan refuses at gpu_present (reason 1)
# BEFORE reading the viewport, allocating the pan buffer or writing the surface address.
want "$LOG" "modeset: #93 pan idx=0 reason=1" \
     "★ --pan routed to the PAN op and returned reason 1 (no DCN under QEMU) — the pan op dispatched, scanout not touched" \
     "--pan did not reach the PAN op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ And it must have refused BEFORE arming: no pan buffer allocated, no scanout re-point. A pan armed with
# no GPU would move fb_console's paint base to an address nothing is scanning — an invisible console.
wantno "$LOG" "modeset: PAN ARMED" \
     "the PAN op did NOT arm under QEMU (refused at the gpu_present gate first)" \
     "PAN armed with no GPU present — fb_console would paint into a buffer nothing scans"

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
# --recommit arg path (M6 OTG envelope). Under QEMU there is no DCN, so mdo_recommit refuses at gpu_present
# and returns reason 1 BEFORE arming or disabling the pipe — proving the RECOMMIT op dispatched with no risk.
want "$LOG" "modeset: #93 recommit error idx=0 reason=1" \
     "★ --recommit routed to the RECOMMIT op and returned reason 1 (no DCN under QEMU) — the M6 envelope op dispatched, pipe not touched" \
     "--recommit did not reach the RECOMMIT op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ Under QEMU M6 must NOT have armed either — the gpu_present gate precedes modeset_arm(6). Critically, it
# must NOT have disabled the pipe (no OTG_MASTER_EN write) with no GPU present.
wantno "$LOG" "modeset: latch armed at site=6" \
     "the M6 op refused BEFORE arming the latch under QEMU (gpu_present gate precedes the arm)" \
     "M6 armed the latch under QEMU — the gpu_present gate must precede modeset_arm"
wantno "$LOG" "modeset: recommit -- OTG_MASTER_EN 0" \
     "the M6 op did NOT disable the pipe under QEMU (refused at the gpu_present gate first)" \
     "M6 disabled the pipe under QEMU — the gpu_present gate must precede any OTG write"
# --transmitter arg path (M8 the transmitter). Under QEMU mdo_transmit refuses at gpu_present (reason 1)
# before arming, before the envelope and before any ATOM table — proving the TRANSMIT op dispatched with the
# PHY untouched. (A production kernel on real iron answers reason 18 = no HDMI_ATOM; both are safe refusals.)
want "$LOG" "modeset: #93 transmit error idx=0 reason=1" \
     "★ --transmitter routed to the TRANSMIT op and returned reason 1 (no DCN under QEMU) — the M8 op dispatched, PHY untouched" \
     "--transmitter did not reach the TRANSMIT op — argv broken, or the op rejected the record (not reason 1)"
# ⛔ THE SAFETY ASSERTIONS. M8 is the bite that can blank the panel, so the smoke proves that with no GPU the
# op touched NOTHING: no latch armed, no OTG envelope opened, and above all NO ATOM TABLE EXECUTED.
wantno "$LOG" "modeset: latch armed at site=8" \
     "the M8 op refused BEFORE arming the latch under QEMU (gpu_present gate precedes the arm)" \
     "M8 armed the latch under QEMU — the gpu_present gate must precede modeset_arm"
wantno "$LOG" "modeset: transmit -- OTG_MASTER_EN 0" \
     "the M8 op did NOT open the envelope under QEMU (refused before disabling the pipe)" \
     "M8 disabled the pipe under QEMU — the gpu_present gate must precede any OTG write"
wantno "$LOG" "modeset: transmit -- ATOM #4" \
     "⛔ the M8 op ran NO ATOM table under QEMU (the encoder command was never reached)" \
     "M8 executed ATOM #4 under QEMU — an ATOM table must never run behind a failed gate"
wantno "$LOG" "DIG1TransmitterControl ENABLE (LIVE PHY EDGE)" \
     "⛔ the LIVE #76 transmitter edge is ABSENT from this build (ATOM_RUN_TRANSMITTER not set)" \
     "the live #76 PHY edge is present in a default build — ATOM_RUN_TRANSMITTER must gate it"
# The recovery boot must still reach the shell (the tool runs must not wedge the boot).
want "$LOG" "Launching kybernet" \
     "the boot reached the shell (the tool runs did not wedge)" \
     "boot did not reach kybernet"

echo ""
[ "$fail" -eq 0 ] && { echo "=== modeset-tool-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== modeset-tool-smoke: $pass passed, $fail failed ==="; exit 1
