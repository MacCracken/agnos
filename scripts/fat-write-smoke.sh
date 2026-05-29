#!/bin/bash
# FAT-family write smoke (1.34.x FAT-family arc — bite 3: FAT write).
#
# Boots the FATFS_WRITE_SELFTEST kernel against a GPT disk with a FAT32
# ESP (mformat -F) holding the real boot files (gnoboot + agnos). The
# self-test creates an empty 8.3 file (NEWFILE.TXT) in the mounted FAT
# root. Then, on the post-boot image:
#   - fsck.fat -n on the ESP is CLEAN (the new dirent didn't corrupt the
#     FAT or the coexisting boot files — the stringent part), and
#   - mdir shows NEWFILE.TXT present.
# This is the FAT analogue of the ext2 arc's e2fsck + debugfs gate.
#
# NOTE: bite 3a creates an EMPTY file (no cluster allocation) — a zero-
# length file is fsck.fat-clean on its own. Content write (cluster
# allocator + chain) is bite 3b.
#
# Build first:  FATFS_WRITE_SELFTEST=1 FAT_ALLOW_ESP_WRITE=1 ./scripts/build.sh
#               (this smoke writes the ESP test image, so it overrides the
#                ESP-write safety guard — that override is for test images ONLY)
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, fsck.fat
#           (dosfstools), dd, strings. gnoboot at ../gnoboot/build/.
# Exit 0 if create + fsck-clean + mdir all pass; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

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

for tool in qemu-system-x86_64 parted mformat mmd mcopy mdir sgdisk fsck.fat dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run FATFS_WRITE_SELFTEST=1 FAT_ALLOW_ESP_WRITE=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/fat-write-smoke"
LOGS="$ROOT/build/fat-write-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-fatw.img"

# Reference pattern for WTEST.BIN (3000 B, byte[i] = i & 0xFF) — the
# kernel writes the same; we mtype the result back and cmp byte-exact.
{ for i in $(seq 0 2999); do printf "\\$(printf '%03o' $((i % 256)))"; done; } > "$WORK/pattern.bin"

echo "Building GPT disk (FAT32 ESP + boot files)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos

echo "Booting FATFS_WRITE_SELFTEST kernel (NVMe + GPT, FAT32 ESP)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/fat-write-selftest.log"
timeout "${QEMU_TIMEOUT:-30}" qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FATW" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- fat lines from boot log ---"
strings "$LOG" | grep -E "^fat: mounted|^fatw:" | sed 's/^/  /'
echo ""

rc=0

# 1. self-test reported clean create (3a) + write (3b)
if strings "$LOG" | grep -q "fatw: create NEWFILE.TXT rc=0"; then
    echo "  PASS: fatfs_create (empty file) rc=0"
else
    echo "  FAIL: create (no 'fatw: create NEWFILE.TXT rc=0' in log)"; rc=1
fi
if strings "$LOG" | grep -q "fatw: write WTEST.BIN rc=0"; then
    echo "  PASS: fatfs_write_file (multi-cluster content) rc=0"
else
    echo "  FAIL: write (no 'fatw: write WTEST.BIN rc=0' in log)"; rc=1
fi

# 2. post-boot ESP is fsck.fat-clean. NB: `mformat -i img@@1MiB -F` (no
#    size) formats the FAT32 to the END of the 128 MiB image (~127 MiB,
#    not the 32 MiB GPT partition), so extract from 1 MiB to end-of-image
#    or fsck reads past a truncated slice. The writes sit in the first
#    MiB; fsck validates the whole 127 MiB FS (FAT chains + dirents).
dd if="$IMG" bs=1M skip=1 of="$WORK/esp.img" status=none
if fsck.fat -n "$WORK/esp.img" >"$LOGS/fsck.log" 2>&1; then
    echo "  PASS: fsck.fat -n clean (writes didn't corrupt FAT / boot files)"
else
    echo "  FAIL: fsck.fat -n flagged the post-boot ESP (see $LOGS/fsck.log)"; rc=1
fi

# 3. NEWFILE.TXT present (empty-file create persisted)
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "NEWFILE"; then
    echo "  PASS: NEWFILE.TXT present on disk (create persisted)"
else
    echo "  FAIL: NEWFILE.TXT absent (mdir)"; rc=1
fi

# 4. WTEST.BIN content byte-exact (the multi-cluster write actually landed)
mtype -i "$WORK/esp.img" ::WTEST.BIN > "$WORK/got.bin" 2>/dev/null
if cmp -s "$WORK/got.bin" "$WORK/pattern.bin"; then
    echo "  PASS: WTEST.BIN content byte-exact (3000 B multi-cluster write)"
else
    echo "  FAIL: WTEST.BIN content mismatch ($(wc -c < "$WORK/got.bin" 2>/dev/null) B vs 3000)"; rc=1
fi

# 5. delete + truncate reported clean (3c)
if strings "$LOG" | grep -q "fatw: delete DELME.BIN wrc=0 drc=0"; then
    echo "  PASS: fatfs_delete rc=0 (write + unlink)"
else
    echo "  FAIL: delete (no 'fatw: delete DELME.BIN wrc=0 drc=0' in log)"; rc=1
fi
if strings "$LOG" | grep -q "fatw: trunc TRUNC.BIN wrc=0 trc=0"; then
    echo "  PASS: fatfs_truncate_zero rc=0 (write + truncate)"
else
    echo "  FAIL: truncate (no 'fatw: trunc TRUNC.BIN wrc=0 trc=0' in log)"; rc=1
fi

# 6. DELME.BIN gone from disk (delete removed the dirent; fsck check #2
#    above also proves its chain was freed with no leaked clusters)
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "DELME"; then
    echo "  FAIL: DELME.BIN still present (delete didn't remove dirent)"; rc=1
else
    echo "  PASS: DELME.BIN absent (delete persisted, chain freed per fsck)"
fi

# 7. TRUNC.BIN is now zero-length (truncate freed the chain + zeroed size)
mtype -i "$WORK/esp.img" ::TRUNC.BIN > "$WORK/trunc.bin" 2>/dev/null
if [ -s "$WORK/trunc.bin" ]; then
    echo "  FAIL: TRUNC.BIN not empty ($(wc -c < "$WORK/trunc.bin") B)"; rc=1
else
    echo "  PASS: TRUNC.BIN truncated to 0 bytes"
fi

# 8. LFN create (3d): self-test rc + mtools reconstructs the long name.
#    mdir showing the exact long name means the LFN entry chain + the 8.3
#    alias checksum are correct (mtools/fsck validate the checksum link).
if strings "$LOG" | grep -q "fatw: lfn create rc=0"; then
    echo "  PASS: fatfs_create_lfn rc=0"
else
    echo "  FAIL: lfn create (no 'fatw: lfn create rc=0' in log)"; rc=1
fi
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "LongFileName12345.txt"; then
    echo "  PASS: long name 'LongFileName12345.txt' reconstructed by mtools (LFN chain + checksum OK)"
else
    echo "  FAIL: long name not reconstructed (LFN chain/checksum wrong)"; rc=1
fi

# 9. overwrite-existing (3e): rc + WOVER.BIN is the 2000 B second write
#    (not the 1000 B first, not 3000 B appended) — old chain freed/replaced
if strings "$LOG" | grep -q "fatw: overwrite WOVER.BIN rc1=0 rc2=0"; then
    echo "  PASS: overwrite rc1=0 rc2=0"
else
    echo "  FAIL: overwrite (no 'fatw: overwrite WOVER.BIN rc1=0 rc2=0' in log)"; rc=1
fi
mtype -i "$WORK/esp.img" ::WOVER.BIN > "$WORK/wover.bin" 2>/dev/null
if head -c 2000 "$WORK/pattern.bin" | cmp -s - "$WORK/wover.bin"; then
    echo "  PASS: WOVER.BIN = 2000 B second write byte-exact (overwrite replaced content)"
else
    echo "  FAIL: WOVER.BIN mismatch ($(wc -c < "$WORK/wover.bin" 2>/dev/null) B; want 2000)"; rc=1
fi

# 10. arbitrary truncate (3e): TRUNC2.BIN written 3000 B, truncated to 1000 B
if strings "$LOG" | grep -q "fatw: trunc2 TRUNC2.BIN wrc=0 trc=0"; then
    echo "  PASS: arbitrary truncate wrc=0 trc=0"
else
    echo "  FAIL: truncate (no 'fatw: trunc2 TRUNC2.BIN wrc=0 trc=0' in log)"; rc=1
fi
mtype -i "$WORK/esp.img" ::TRUNC2.BIN > "$WORK/trunc2.bin" 2>/dev/null
if head -c 1000 "$WORK/pattern.bin" | cmp -s - "$WORK/trunc2.bin"; then
    echo "  PASS: TRUNC2.BIN = first 1000 B byte-exact (tail freed, size updated)"
else
    echo "  FAIL: TRUNC2.BIN mismatch ($(wc -c < "$WORK/trunc2.bin" 2>/dev/null) B; want 1000)"; rc=1
fi

# 11. LFN-with-content (1.34.3 bite 1): LongContent12345.bin written 3000 B
#     via the long name; mtools reconstructs the long name AND the content
#     byte-exact (the 8.3-alias entry points at the cluster chain).
if strings "$LOG" | grep -q "fatw: lfn-content rc=0"; then
    echo "  PASS: fatfs_write_file_lfn rc=0 (LFN + content)"
else
    echo "  FAIL: lfn-content (no 'fatw: lfn-content rc=0' in log)"; rc=1
fi
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "LongContent12345.bin"; then
    echo "  PASS: long name 'LongContent12345.bin' reconstructed by mtools"
else
    echo "  FAIL: LFN-content long name not reconstructed"; rc=1
fi
mtype -i "$WORK/esp.img" ::LongContent12345.bin > "$WORK/lfnc.bin" 2>/dev/null
if cmp -s "$WORK/lfnc.bin" "$WORK/pattern.bin"; then
    echo "  PASS: LongContent12345.bin content byte-exact (3000 B multi-cluster LFN write)"
else
    echo "  FAIL: LFN-content mismatch ($(wc -c < "$WORK/lfnc.bin" 2>/dev/null) B; want 3000)"; rc=1
fi

# 12. LFN-name overwrite-match (1.34.3 bite 2): LfnOver12345.bin written
#     3000 B then overwritten 2000 B BY ITS LONG NAME. If overwrite-match
#     worked → ONE entry, 2000 B. If find missed the long name → a duplicate
#     under a fresh ~N alias (count 2) and mtype returns the stale 3000 B.
if strings "$LOG" | grep -q "fatw: lfn-overwrite rc1=0 rc2=0"; then
    echo "  PASS: fatfs_write_file_lfn overwrite rc1=0 rc2=0"
else
    echo "  FAIL: lfn-overwrite (no 'fatw: lfn-overwrite rc1=0 rc2=0' in log)"; rc=1
fi
LO_COUNT=$(mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -c "LfnOver12345.bin")
if [ "$LO_COUNT" = "1" ]; then
    echo "  PASS: LfnOver12345.bin is a SINGLE dir entry (overwrite-match, no duplicate)"
else
    echo "  FAIL: LfnOver12345.bin appears $LO_COUNT times (overwrite-match missed → duplicate long name)"; rc=1
fi
mtype -i "$WORK/esp.img" ::LfnOver12345.bin > "$WORK/lfno.bin" 2>/dev/null
if head -c 2000 "$WORK/pattern.bin" | cmp -s - "$WORK/lfno.bin"; then
    echo "  PASS: LfnOver12345.bin = 2000 B second write byte-exact (overwrote in place)"
else
    echo "  FAIL: LfnOver12345.bin mismatch ($(wc -c < "$WORK/lfno.bin" 2>/dev/null) B; want 2000)"; rc=1
fi

# 13. grow-truncate (1.34.3 bite 3): GROW.BIN written 1000 B then grown to
#     3000 B — the grown region [1000,3000) must read as zeros (data + hole).
if strings "$LOG" | grep -q "fatw: grow GROW.BIN w=0 t=0"; then
    echo "  PASS: fatfs_truncate grow w=0 t=0"
else
    echo "  FAIL: grow (no 'fatw: grow GROW.BIN w=0 t=0' in log)"; rc=1
fi
head -c 1000 "$WORK/pattern.bin" > "$WORK/grow_exp.bin"
dd if=/dev/zero bs=1 count=2000 status=none >> "$WORK/grow_exp.bin"
mtype -i "$WORK/esp.img" ::GROW.BIN > "$WORK/grow.bin" 2>/dev/null
if cmp -s "$WORK/grow.bin" "$WORK/grow_exp.bin"; then
    echo "  PASS: GROW.BIN = 3000 B, [0,1000)=data + [1000,3000)=zeros (grow zero-filled)"
else
    echo "  FAIL: GROW.BIN grow mismatch ($(wc -c < "$WORK/grow.bin" 2>/dev/null) B; want 3000 w/ zero tail)"; rc=1
fi

# 14. FAT32 root extension + cross-sector LFN runs (1.34.4 FAT side): 40
#     LFN-named files (120 dir entries) past the 16-entry root cluster force
#     AGNOS to extend the root + sets to straddle cluster boundaries. All
#     create rc=0 + fsck.fat -n clean + the long names reconstruct + readback.
if strings "$LOG" | grep -q "fatw: fatrootext 40 lfn files nfail=0"; then
    echo "  PASS: 1.34.4 FAT32 root extension (40 LFN files created past 16-entry root)"
else
    echo "  FAIL: 1.34.4 FAT root extension (some LFN creates failed)"; rc=1
fi
if strings "$LOG" | grep -q "fatw: fatrootext readback OK"; then
    echo "  PASS: 1.34.4 extended-root LFN file readback byte-exact"
else
    echo "  FAIL: 1.34.4 fatrootext readback"; rc=1
fi
LF_CNT=$(mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -c "Lf[0-9][0-9]_longx.dat")
if [ "$LF_CNT" -ge 40 ] 2>/dev/null; then
    echo "  PASS: 1.34.4 all 40 long names reconstructed by mtools (count=$LF_CNT)"
else
    echo "  FAIL: 1.34.4 only $LF_CNT/40 long names present (root-extension lost entries)"; rc=1
fi

# 1.39.3 VFS-lift bite 3: the shell write verbs reach FAT. The kernel ran
# `touch SHTOUCH.TXT` + `echo SHELL-FAT-WROTE > SHECHO.TXT` via sh_exec ->
# sh_cmd_touch / sh_echo_redirect -> vfs_create_secondary / vfs_write_secondary
# -> fatfs_create / fatfs_write_file. Verify both landed on disk + content.
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "SHTOUCH"; then
    echo "  PASS: shell 'touch' created SHTOUCH.TXT on FAT (vfs_create_secondary)"
else
    echo "  FAIL: shell touch over FAT (SHTOUCH.TXT absent on disk)"; rc=1
fi
mtype -i "$WORK/esp.img" ::SHECHO.TXT > "$WORK/shecho.txt" 2>/dev/null
if grep -q "SHELL-FAT-WROTE" "$WORK/shecho.txt" 2>/dev/null; then
    echo "  PASS: shell 'echo >' wrote SHECHO.TXT content on FAT (vfs_write_secondary)"
else
    echo "  FAIL: shell echo> over FAT (SHECHO.TXT content missing 'SHELL-FAT-WROTE')"; rc=1
fi
# 1.39.4 VFS-lift bite 4: shell `rm` over FAT. The kernel ran
# `touch SHRMTGT.TXT` then `rm SHRMTGT.TXT` (vfs_delete_secondary ->
# fatfs_delete). The target must be ABSENT on disk (+ fsck-clean above
# proves the chain/dirent were freed with no leak).
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "SHRMTGT"; then
    echo "  FAIL: shell rm over FAT (SHRMTGT.TXT still present)"; rc=1
else
    echo "  PASS: shell 'rm' removed SHRMTGT.TXT on FAT (vfs_delete_secondary)"
fi
# 1.39.5 VFS-lift bite 5: shell mkdir/rmdir over FAT. SHKEEP must be a
# navigable directory (mdir can descend into it → it has valid ./.. +
# cluster); SHRMD (mkdir then rmdir) must be gone. fsck-clean above proves
# the dir cluster + chains are structurally sound.
if mdir -i "$WORK/esp.img" ::SHKEEP >/dev/null 2>&1; then
    echo "  PASS: shell 'mkdir' created navigable SHKEEP dir on FAT (vfs_mkdir_secondary)"
else
    echo "  FAIL: shell mkdir over FAT (SHKEEP not a navigable directory)"; rc=1
fi
if mdir -i "$WORK/esp.img" :: 2>/dev/null | grep -q "SHRMD"; then
    echo "  FAIL: shell rmdir over FAT (SHRMD still present)"; rc=1
else
    echo "  PASS: shell 'rmdir' removed SHRMD dir on FAT (vfs_rmdir_secondary)"
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "FAT write smoke (3a-3e + 1.34.3 LFN-content): PASS"; else echo "FAT write smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
