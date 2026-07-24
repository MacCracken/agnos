#!/bin/sh
# H1 — klug_spill: the kernel writes its own log ring to agnos-fs, and the spill matches the serial log.
#
# WHY THIS EXISTS
# ---------------
# A bite whose failure blanks the console loses its diagnostic with it. The 1.56.x D lane burned five iron
# flashes for one result and **two produced no evidence at all**. Every risk row in the modeset plan (R1,
# R2, R6) claims "log survives — spilled per group"; that claim is only true once this works.
#
# THE GATE: boot with KLUG_SPILL_SELFTEST, let the kernel write /klug.txt on the ext2 partition, then read
# that file back FROM THE HOST with debugfs (no mounting) and prove it is the same bytes the serial console
# emitted. A spill that merely "returns a byte count" proves nothing — the count is the kernel agreeing with
# itself. The comparison against an INDEPENDENT capture is the whole point
# (cf. [[feedback_echo_vs_answer_registers]]).
#
# Build first: KLUG_SPILL_SELFTEST=1 sh scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, debugfs, e2fsck, dd.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 debugfs e2fsck dd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
# ⚠ Necessary, NOT sufficient — this string lives in the CALL SITE's kprint, but a build guard can never
# prove the call executed. The log assertions below are the real gate.
# See [[feedback_ifdef_bites_name_their_build_flags]].
if ! strings "$AGNOS" | grep -q "klug: spilled "; then
    echo "ERROR: kernel not built with KLUG_SPILL_SELFTEST=1 — rebuild:" >&2
    echo "       KLUG_SPILL_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/klug-spill-smoke"; LOGS="$ROOT/build/klug-spill-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-klug.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 67 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

echo "Building ext2 image (mkfs -O $FEATURES)..."
SEED="$WORK/seed"; mkdir -p "$SEED"
echo "klug spill seed" > "$SEED/hello.txt"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-KLUG -b 4096 -m 0 -O "$FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting KLUG_SPILL_SELFTEST kernel (NVMe + GPT partition)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/klug-spill.log"
timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-KLUG" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo "--- klug lines ---"
grep -aE "klug:" "$LOG" | head -5
echo "------------------"

# --- pull the spill back off the platter, WITHOUT mounting ---
dd if="$IMG" bs=1M skip=33 count=67 of="$WORK/part-post.img" status=none
debugfs -R "cat /klug.txt" "$WORK/part-post.img" > "$WORK/spill.bin" 2>/dev/null || true
SPILL_BYTES=$(wc -c < "$WORK/spill.bin" 2>/dev/null || echo 0)

pass=0; fail=0
chk() { if [ "$1" = 1 ]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $3"; fail=$((fail+1)); fi; }

grep -aq "klug: spill file ready at /klug.txt" "$LOG" && r=1 || r=0
chk "$r" "the spill file was pre-created AND pre-allocated at mount time" \
        "'spill file ready' absent — prepare failed, so the spill would have had to run the allocator"

REPORTED=$(grep -aoE "klug: spilled [0-9]+ bytes" "$LOG" | head -1 | grep -oE "[0-9]+")
[ -n "${REPORTED:-}" ] && [ "${REPORTED:-0}" -gt 0 ] && r=1 || r=0
chk "$r" "the kernel reported a non-zero spill (${REPORTED:-0} bytes)" \
        "the kernel reported no spill — klug_spill() returned 0"

[ "${SPILL_BYTES:-0}" -gt 0 ] && r=1 || r=0
chk "$r" "/klug.txt exists on the platter and is non-empty ($SPILL_BYTES bytes read by debugfs)" \
        "debugfs could not read /klug.txt — the spill never reached the disk"

# The file is pre-allocated to the full 64 KB ring, so its SIZE is 65536; the meaningful check is that the
# first REPORTED bytes match the serial capture.
# ⚠ These two are LINEAR-MODE ONLY. When KLUG_SPILL_WRAPTEST is also built in, it re-spills a deliberately
# wrapped ring over the same file, so /klug.txt legitimately holds 64 KB of wrap padding rather than the
# boot log — the banner and late-line checks would fail for a correct kernel. Wrap mode is verified by the
# ordering block below instead. Running them anyway is how a mode-specific assertion becomes a false alarm.
if grep -aq "klug: wraptest count=" "$LOG"; then
    echo "SKIP: linear-spill content checks (wraptest re-spilled a wrapped ring over /klug.txt)"
elif [ "${REPORTED:-0}" -gt 0 ] && [ "${SPILL_BYTES:-0}" -ge "${REPORTED:-1}" ]; then
    head -c "$REPORTED" "$WORK/spill.bin" > "$WORK/spill-head.bin"
    # Independent oracle: a distinctive early boot line and a late one must BOTH appear in the spilled
    # bytes. Early proves the ring was not rotated by the wrap handling; late proves it is current.
    grep -aq "AGNOS kernel v" "$WORK/spill-head.bin" && r=1 || r=0
    chk "$r" "the spill contains the early boot banner (wrap order is chronological)" \
            "the banner is missing — the ring was spilled rotated, or truncated"
    grep -aq "klug: spill file ready" "$WORK/spill-head.bin" && r=1 || r=0
    chk "$r" "the spill contains a late line (it is the CURRENT ring, not a stale prealloc)" \
            "no late line — /klug.txt still holds the mount-time preallocation, not the spill"
    # Byte-level: every line in the spill must be a line the serial console actually emitted.
    miss=$(grep -a "^klug: " "$WORK/spill-head.bin" | while read -r l; do grep -aqF "$l" "$LOG" || echo X; done | wc -l)
    [ "${miss:-1}" = 0 ] && r=1 || r=0
    chk "$r" "every klug line on disk also appears in the serial capture (independent oracle)" \
            "$miss line(s) on disk were never emitted on serial — the spill is not the same log"
else
    echo "FAIL: nothing to compare — spill absent or shorter than reported"; fail=$((fail+1))
fi

# --- WRAP ORDERING (only when built with KLUG_SPILL_WRAPTEST) ------------------------------------------
# The wrapped branch of klug_spill() reorders the ring to chronological: [head,64K) then [0,head). A normal
# boot never wraps (QEMU ~2.5 KB, iron ~16-20 KB, ring 64 KB), so without this the branch would ship having
# never run — and it fails SILENTLY, producing a log that is merely rotated.
if grep -aq "klug: wraptest count=" "$LOG"; then
    echo "  --- wrap ordering ---"
    grep -aoE "klug: wraptest count=[0-9]+ head=[0-9]+ spilled=[0-9]+" "$LOG" | head -1 | sed 's/^/  /'
    WCOUNT=$(grep -aoE "wraptest count=[0-9]+" "$LOG" | head -1 | grep -oE "[0-9]+")
    [ "${WCOUNT:-0}" -ge 65536 ] && r=1 || r=0
    chk "$r" "the ring actually WRAPPED (count=${WCOUNT:-0} saturated at 65536)" \
            "count=${WCOUNT:-0} — the ring never wrapped, so the wrapped branch still did not execute"

    posA=$(grep -abo "KLUG-WRAP-AAA" "$WORK/spill.bin" 2>/dev/null | head -1 | cut -d: -f1)
    posB=$(grep -abo "KLUG-WRAP-BBB" "$WORK/spill.bin" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "${posA:-}" ] && [ -n "${posB:-}" ] && r=1 || r=0
    chk "$r" "both ordering markers survived the wrap (A@${posA:--} B@${posB:--})" \
            "a marker is missing from the spilled file — the wrap dropped live data"

    if [ -n "${posA:-}" ] && [ -n "${posB:-}" ]; then
        [ "$posA" -lt "$posB" ] && r=1 || r=0
        chk "$r" "★ the spill is CHRONOLOGICAL — older marker precedes newer ($posA < $posB)" \
                "the spill is ROTATED: A@$posA came after B@$posB, so the wrapped branch reorders wrongly"
    fi
fi

if e2fsck -fn "$WORK/part-post.img" > "$LOGS/e2fsck.log" 2>&1; then r=1; else r=0; fi
chk "$r" "e2fsck clean after the spill (the non-journaled write left a consistent FS)" \
        "e2fsck reported problems — see $LOGS/e2fsck.log"

echo ""
[ "$fail" -eq 0 ] && { echo "=== klug-spill-smoke: $pass passed, 0 failed ==="; exit 0; }
echo "=== klug-spill-smoke: $pass passed, $fail failed ==="; exit 1
