#!/bin/sh
# RUNG 9a of the 3D arc - the #92 op 0x08 EDGE_COV ABI battery, in QEMU, at ZERO BURNS.
#
# WHY THIS EXISTS
# ---------------
# Rung 9 is the first real rasteriser, and its failure table has four outcomes that must stay
# distinguishable: all-sentinel (dead write-back or a guard that rejected every lane), wrong shape
# (edge setup), right shape / wrong edge pixels (fill rule), some tiles right (tgid mapping). A bug in
# the ABI - a field silently ignored, a slot never size-checked - produces symptoms that read as ANY
# of those four. So the ABI is proven first, separately, and on the host.
#
# THIS RUNS THE SHIPPED gpo_validate_edge. Not a host copy. The single largest risk in a split like
# this is two artifacts that differ in name but not behaviour - the ATOM_DRY defect class - and the
# only real defence is that there is exactly one implementation.
#
# WHAT PASSES: 16 of 16, AND the well-formed record reaching GPO_E_ARM. That second half is the part
# that matters: a validator that rejected everything would score 15 of 16 and look nearly right.
#
# Build first: EDGE_ABI_SELFTEST=1 sh scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built.

set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
if ! strings "$AGNOS" | grep -q "edge-abi: ---- #92 op 0x08 "; then
    echo "ERROR: kernel not built with EDGE_ABI_SELFTEST=1 — rebuild:" >&2
    echo "       EDGE_ABI_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/edge-abi-smoke"; LOGS="$ROOT/build/edge-abi-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

LOG="$LOGS/edge-abi.log"
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
echo "=== AGNOS rung 9a - #92 op 0x08 EDGE_COV ABI battery (EDGE_ABI_SELFTEST, -m 256M) ==="
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 256M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$ESP,format=raw,if=none,id=esp0" \
    -device "virtio-blk-pci,drive=esp0" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- edge-abi lines ---"
# ⚠ THE DISPLAY CAP MUST EXCEED THE BATTERY. It sat at head -40 while the battery grew to 58,
# which silently truncated the 0x0B block AND the verdict line — the run looked like the kernel had
# stopped printing mid-battery. An instrument that clips its own evidence reads exactly like the
# thing under test failing. Keep this comfortably ahead of the case count.
strings "$LOG" | grep -E "edge-abi:" | head -110
echo "----------------"

pass=0; fail=0
chk() { if grep -q "$1" "$LOG"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $3"; fail=$((fail+1)); fi; }
nchk() { if grep -q "$1" "$LOG"; then echo "FAIL: '$1' present — $3"; fail=$((fail+1)); else echo "PASS: $2"; pass=$((pass+1)); fi; }

chk "edge-abi: 93 of 93 cases correct" \
    "every one of the 93 ABI cases returned the reason the ABI specifies" \
    "not 93/93 - read the named FAIL line(s) above; each names its case, want and got"
chk "edge-abi: PASS -- the 0x08/0x09/0x0A/0x0B/0x0C ABIs reject every malformed record" \
    "the battery's own verdict line is PASS" \
    "verdict line absent or FAIL"
# THE 9a ORACLE. The single WELL-FORMED record must reach residency and be told NOT YET. If this case
# were absent the battery would still print 16/16 while proving only that malformed records are
# rejected - which a function that rejected EVERYTHING would also satisfy.
chk "edge-abi: PASS well-formed record" \
    "a well-formed record is ACCEPTED, or correctly reports GPO_E_ARM where there is no GPU" \
    "the valid record did not validate; a reject fired on a record that should have passed"
# Three rejects a size-only validator would MISS, called out individually because each is a distinct
# class and a shared pass count would let one regress behind the other fifteen.
chk "edge-abi: PASS edge and dst are the SAME slot" \
    "aliasing input onto output is refused (GPO_E_ALIAS, its own code)" \
    "an aliased record was accepted - that is a data race presenting as a wrong triangle"
chk "edge-abi: PASS dstxy set (undefined for this op)" \
    "a dword this op does not define is refused, not ignored" \
    "dstxy was accepted and would have been silently dropped"
chk "edge-abi: PASS n_edges 2 (cannot enclose area)" \
    "a 2-edge path is refused rather than rasterising to a silent all-zero mask" \
    "2 edges accepted - an empty mask is indistinguishable from a dead shader"
# The table must be left clean. A dirty shm table surfaces far from here as "shm_create returns -1".
nchk "edge-abi: REFUSED" \
    "the battery was able to seed its slots (nothing else owned them)" \
    "the seed slots were already in use - boot ordering changed"
# B3 - the coordinate domain. The two REJECTS and the two BOUNDARY cases are asserted
# separately, because they fail in opposite directions and a single count hides that.
chk "edge-abi: PASS coord above +2^28" \
    "an edge endpoint past the domain is refused (GPO_E_COORD, its own code)" \
    "out-of-domain geometry was accepted - the reference has no defined value there"
chk "edge-abi: PASS coord at +2^28 exactly is IN range" \
    "the domain bound is INCLUSIVE - legal geometry on the boundary is not rejected" \
    "an off-by-one in the comparison is rejecting geometry that is in range"
chk "edge-abi: PASS coord below -2^28" \
    "a negative endpoint past the domain is refused" \
    "the lower bound did not fire"
# THE SIGN-EXTENSION WITNESS. load32 zero-extends in Cyrius, so a missing sign-extend makes
# every negative coordinate read as ~4.03e9 and trips the UPPER bound - the reject cases would
# still pass, for the wrong reason. Only the negative BOUNDARY case distinguishes them.
chk "edge-abi: PASS coord at -2^28 exactly is IN range" \
    "negative coordinates are SIGN-EXTENDED, not zero-extended, before the bound check" \
    "a legal negative coordinate was rejected - load32 zero-extension is not being undone"
chk "edge-abi: PASS rule EVENODD is refused" \
    "an unimplemented winding rule is REFUSED at the ABI, not accepted then silently failed" \
    "rule 1 was accepted - the ABI now promises behaviour no oracle covers"
chk "edge-abi: PASS n_edges over the ABI max of 256" \
    "the ABI edge maximum is enforced at the validator" \
    "the edge maximum is not enforced"
# ⭐ THE MEASURED WORK BOUND (1.56.19). The old edge-only cap PERMITTED 4096^2 x E=64 at ~639 ms
# against a ~94 ms watchdog, and FORBADE 64^2 x E=256 at ~0.65 ms. Both directions are gated.
chk "edge-abi: PASS 4096x4096 x 64 edges exceeds the work budget" \
    "the envelope that would blow the dispatch watchdog is REFUSED (GPO_E_WORK, its own code)" \
    "a ~639 ms envelope was accepted -- the work bound is not enforced"
chk "edge-abi: PASS 64x64 x 16 edges is INSIDE the budget" \
    "the envelope the OLD edge-cap wrongly FORBADE (~0.65 ms) is now ACCEPTED" \
    "a measured-fast envelope was rejected; the bound is too tight to use"
chk "AGNOS shell" \
    "boot completed past the battery (no fault)" \
    "boot did not reach shell"

echo ""
[ "$fail" -eq 0 ] && { echo "=== edge-abi-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== edge-abi-smoke: $pass passed, $fail failed ==="; exit 1
