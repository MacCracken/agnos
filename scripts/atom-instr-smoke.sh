#!/bin/sh
# H4 — ATOM instrument pack: prove every abnormal interpreter exit is DISTINCT and NON-ZERO.
#
# WHY THIS EXISTS
# ---------------
# Before H4, a table that hit a reserved opcode, ran off the end of its code, took an unimplemented I/O
# mode, or addressed a register outside the BAR5 window returned **rc = 0** — indistinguishable from a clean
# EOT. So "rc=0" was NOT evidence a table ran, and every ATOM bite carried a silent false-pass channel.
#
# The gate from the plan: "a deliberate desync (execute a data table) must return NON-ZERO where it returns
# 0 today." Running the real interpreter needs a VBIOS and QEMU has no AMD GPU, so the selftest SYNTHESISES
# one in RAM: four tiny command tables whose first opcode drives each exit path. Only EOT / opcode 0 /
# opcode 127 are ever executed, so no MMIO is reachable — safe anywhere, never needs iron.
#
# ⚠ This smoke asserts on the REPORTER'S OWN OUTPUT ("STOPPED rc=61" etc.), not just the pass count, and
# that is load-bearing: the first version of H4 defined its rc codes as module-scope `var X = 0 - 61;`,
# which in an included Cyrius module silently initializes to 0. Every code was 0, so the selftest compared
# 0 against 0 and reported 4/4 PASS — a false pass inside the bite meant to kill false passes. Only the
# missing reporter lines exposed it. Never reduce this to a pass-count check.
#
# Build first: HDMI_ATOM=1 ATOM_INSTR_SELFTEST=1 sh scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not on PATH" >&2; exit 1; }; done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
# Verify the FLAG LANDED, not just that a build exists. A mode flag whose #define was never emitted ships a
# silent no-op — that is exactly how ATOM_DRY blacked the display twice. See
# [[feedback_ifdef_bites_name_their_build_flags]].
#
# ⚠ THIS CHECK IS NECESSARY BUT NOT SUFFICIENT, and the first run of this smoke proved it: the string below
# lives in the FUNCTION BODY, so it appears in the binary as soon as the function compiles — even if nothing
# ever CALLS it. On that run the call sat inside an unrelated `#ifdef HDA_HDMI` nest that was not set, this
# guard passed, and the sweep silently never executed. **String present is not code called.** The log
# assertions below are the real gate; keep them, and never downgrade this to a build-only check.
if ! strings "$AGNOS" | grep -q "atom: H4 selftest "; then
    echo "ERROR: kernel not built with ATOM_INSTR_SELFTEST=1 — rebuild:" >&2
    echo "       HDMI_ATOM=1 ATOM_INSTR_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/atom-instr-smoke"; LOGS="$ROOT/build/atom-instr-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/atom-instr.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS H4 ATOM instrument pack (ATOM_INSTR_SELFTEST, -m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- H4 lines ---"
strings "$LOG" | grep -E "atom: H4" | head -40
echo "----------------"

pass=0; fail=0
chk() { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }
nchk() { if grep -q "$1" "$LOG"; then echo "FAIL: '$1' present — $3"; fail=$((fail+1)); else echo "PASS: $2"; pass=$((pass+1)); fi; }

chk "atom: H4 selftest 4 passed, 0 failed" \
    "all 4 exit paths return their own distinct rc" \
    "did not report 4/0 — read the per-case 'got rc/want rc' lines above"
chk "atom: H4 PASS every abnormal exit is distinct" \
    "the pack's own verdict line is PASS" \
    "verdict line absent or FAIL"
# The three abnormal exits must each be REPORTED, not just counted. These lines come from
# atom_execute_table_locked's H4(a) reporter, and their absence means a table stopped silently — the exact
# false-pass channel this bite closes.
chk "STOPPED rc=61" \
    "the reserved-opcode desync reported itself (rc=-61) — THE GATE" \
    "executing a data table did NOT report a reserved-opcode stop"
chk "STOPPED rc=62" \
    "the out-of-range opcode reported itself (rc=-62)" \
    "running off the end of the code did not report"
chk "BAD HEADER" \
    "the impossible table header was refused before execution (rc=-64)" \
    "a table with size < 6 was not refused"
# The negative check: a per-case line only prints on a MISMATCH, so its presence is the failure signal.
nchk "atom: H4 case " \
    "no per-case rc mismatch was printed" \
    "at least one exit path returned the wrong rc"
chk "AGNOS shell" \
    "boot completed past the pack (no fault)" \
    "boot did not reach shell — the synthetic tables may have faulted the box"

echo ""
[ "$fail" -eq 0 ] && { echo "=== atom-instr-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== atom-instr-smoke: $pass passed, $fail failed ==="; exit 1
