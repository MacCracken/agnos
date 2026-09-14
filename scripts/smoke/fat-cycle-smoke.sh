#!/bin/bash
# FAT / exFAT chain-cycle budget smoke (1.57.2 — the regression GATE for the per-walk step budgets).
#
# THE DEFECT: fat_next_cluster / exfat_next_cluster end a chain on an out-of-range next cluster and
# on a SELF-reference (A -> A). A MULTI-NODE cycle (A -> B -> A, both entries in range) is invisible
# from one step, and before 1.57.2 every chain WALK spun forever on it — a boot hang driven by
# mounted media. The remedy is a per-WALK fetch counter checked against the volume's cluster count
# (fat_chain_overrun / exfat_chain_overrun: no legitimate chain is longer than the volume has
# clusters). This smoke boots a kernel against media that CARRIES such a cycle in both filesystems
# and proves the walks terminate: the post-walk markers print, and the boot then reaches the shell.
#
# ⛔ WHY THE CYCLE IS IN A DIRECTORY CHAIN, NOT A FILE CHAIN. fatfs_read has carried its own
# volume-bounded guard since 1.41.5 and is capped by maxlen, so a cyclic FILE chain returns from
# the file reader with or without the budget — a file-chain cycle cannot distinguish a kernel whose
# predicate is stubbed from a fixed one (by construction, read fatfs_read: its `guard > max_cluster`
# is a local of its own and the `total >= maxlen` exit fires after 3000 B of A/B/A/B; it never calls
# fat_chain_overrun). The 1.57.2 budgets guard the DIRECTORY walks (root / subdir
# chains, plus the two truncate walks), so the media cycles a directory chain, and every cluster on
# the ring is 100% populated — a directory walk stops at the first 0x00 entry, so a half-empty
# cluster would end the walk before the ring is ever crossed and the gate would pass on nothing.
#
# MEDIA (both arms live on ONE 128 MB GPT disk, ONE boot, ONE kernel):
#   p1 = FAT32 ESP exactly as fat-smoke builds it (1MiB..33MiB, mformat -F, gnoboot + agnos +
#        FATTEST.BIN + CATTEST.TXT) plus a subdir CYC holding 62 empty 8.3 files: with `.` and
#        `..` that is 64 entries = exactly two 1024-byte clusters (spc=2 — READ from the BPB, not
#        assumed), no end-of-dir marker. The FAT is then patched (both copies, 32-bit LE at
#        reserved_sectors*512) so CYC's chain is A -> B -> A.
#   p2 = exFAT (mkfs.exfat -c 512 on a standalone partition-sized file, dd'd in at 33MiB, MSFT
#        Basic Data type — exfat-smoke's recipe, but 8 MiB instead of 67: the budgeted walk costs
#        the volume's WHOLE cluster count of uncached sector reads and four root walks cross the
#        ring during this boot, so 12,288 clusters (~5 s) instead of 133,120 (~57 s, MEASURED).
#        The FAT32 side cannot be shrunk the same way — mformat sizes the ESP to the image file and
#        that recipe is the only one that boots — so its single ring walk is the long pole: 129,023
#        fetches x 2 sectors, ~28 s under TCG.) mkfs.exfat's root directory is a FAT-chained run
#        whose first cluster is RootDirectoryCluster (boot sector +96); its free slots are filled
#        with the not-in-use 0x20 placeholder mkfs.exfat itself uses, a second cluster B is
#        allocated (bitmap + FAT) and filled the same way, and the FAT is patched so
#        root -> B -> root.
#   Construction floor: fsck.fat -n must report "Circular cluster chain" for CYC and fsck.exfat -n
#   must report the root chain "cyclic" — and both must have been CLEAN one patch earlier. A smoke
#   whose media does not carry the cycle is not testing the budget; it aborts instead of booting.
#
# KERNEL SIDE (compile-gated, in main.cyr under the existing #ifdef blocks):
#   FATFS_SELFTEST — searches CYC for a name that is NOT there (fatfs_find_in_dir must walk until the
#     budget trips) and prints `fatc: cycle-walk returned rc=N` AFTER the call; also pins the
#     predicate's off-by-one contract (`fatc: predicate count->0 count+1->1 OK`).
#   EXFAT_SELFTEST — exfat_init's exfat_locate_system_files walks the cyclic root BEFORE printing
#     `exfat: mounted`, so that line is the post-walk marker; exfat_ls / exfat_find / the shell ls
#     cross the same ring afterwards. The predicate contract prints as `exfatc: predicate ... OK`.
#   Both arms then require `AGNOS shell v` — the boot got past every walk.
#
# ⭐ MUTATION-PROVEN 2026-09-13 — the gate goes RED against a kernel whose budget is neutralised
# (predicate stubbed to `return 0` via a temporary cyim edit, the source restored byte-exact after):
#   fat_chain_overrun stubbed:   the serial log ENDS at `[    5.495566] fatc: cycle-walk start
#     dir_clus=2005`; `fatc: cycle-walk returned` and `AGNOS shell v` never appear in the 180 s
#     dwell, and the contract line reads `fatc: predicate off-by-one FAIL` -> verdict FAIL, exit 1.
#   exfat_chain_overrun stubbed: the serial log ENDS at `[    0.341672] fat: mounted FAT32 backend=2
#     partition_lba=2048` — the next thing in the boot is exfat_init's root walk; `exfat: mounted`
#     never appears -> verdict FAIL, exit 1.
#   Restored source: `fatc: cycle-walk returned rc=0` at 33.9 s, `exfat: mounted` at 1.5 s,
#     `AGNOS shell v1.57.1` at 43.1 s -> PASS, 8/8, exit 0.
#
# Build first:  FATFS_SELFTEST=1 EXFAT_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, parted, sgdisk, mtools (mformat/mmd/mcopy), mkfs.exfat +
#           fsck.exfat (exfatprogs), fsck.fat (dosfstools), python3, dd, strings, awk.
#           gnoboot at ../gnoboot/build/.
# Env: QEMU_TIMEOUT (default 180 — a PASS reaches the prompt in ~45 s under TCG (see the p2 note
#      above for where the time goes); the budget is ~4x that so a loaded host cannot truncate a
#      good run into a false FAIL, and a hung walk burns all of it — that is the RED path).
# Exit 0 iff every assertion passed; 1 on any FAIL; 2 when the run is VOID (the kernel never ran).

set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

for tool in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.exfat fsck.exfat fsck.fat python3 dd strings awk; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run FATFS_SELFTEST=1 EXFAT_SELFTEST=1 ./scripts/build.sh"; exit 1; }

WORK="$ROOT/build/fat-cycle-smoke"
LOGS="$ROOT/build/fat-cycle-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-fat-cycle.img"

# --- p1: the FAT32 ESP, byte-for-byte the fat-smoke recipe (the ONLY geometry that boots) ---------
echo "Generating FATTEST.BIN (3000 B, byte[i]=i&0xFF) + CATTEST.TXT..."
python3 - "$WORK/FATTEST.BIN" <<'PY'
import sys
open(sys.argv[1], 'wb').write(bytes(i % 256 for i in range(3000)))
PY
printf 'VFS-CAT-FAT-OK\n' > "$WORK/CATTEST.TXT"
# 62 EMPTY files with UPPERCASE 8.3 names: mtools writes exactly ONE short entry per file (no LFN
# entries), no data cluster (size 0), so `.` + `..` + 62 = 64 entries = two full 1024 B clusters.
mkdir -p "$WORK/cyc"
for i in $(seq -w 1 62); do : > "$WORK/cyc/F$i.TXT"; done

echo "Building GPT disk (FAT32 ESP + exFAT MSFT-Basic partition)..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart exfatdata 33MiB 41MiB
sgdisk -t 2:0700 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mcopy -i "$IMG"@@1048576 "$WORK/FATTEST.BIN" ::FATTEST.BIN
mcopy -i "$IMG"@@1048576 "$WORK/CATTEST.TXT" ::CATTEST.TXT
mmd -i "$IMG"@@1048576 ::CYC
mcopy -i "$IMG"@@1048576 "$WORK"/cyc/F*.TXT ::CYC/

# Patch p1's FAT: CYC's chain A -> B -> EOC becomes A -> B -> A, in EVERY FAT copy. All geometry is
# read from the BPB (mformat sizes the volume to the file behind the offset, not the partition, so
# nothing about it may be assumed). Refuses — exit 1 — unless the chain is exactly two clusters and
# both are 100% populated, because a walk that meets a 0x00 entry ends before crossing the ring.
echo "Patching FAT32 CYC chain into a 2-node cycle..."
python3 - "$IMG" <<'PY' || exit 1
import struct, sys
PART = 1048576
fn = sys.argv[1]
f = open(fn, 'r+b'); f.seek(PART); bs = f.read(512)
bps  = struct.unpack_from('<H', bs, 11)[0]; spc = bs[13]
rsvd = struct.unpack_from('<H', bs, 14)[0]; nfats = bs[16]
fatsz = struct.unpack_from('<I', bs, 36)[0]; root = struct.unpack_from('<I', bs, 44)[0]
tot = struct.unpack_from('<I', bs, 32)[0]
data_start = rsvd + nfats * fatsz
count = (tot - data_start) // spc
if count < 65525: print(f"ERROR: volume is not FAT32 (count_of_clusters={count})"); sys.exit(1)
def coff(c): return PART + (data_start + (c - 2) * spc) * bps
def fat(c):
    f.seek(PART + rsvd * bps + c * 4); return struct.unpack_from('<I', f.read(4))[0] & 0x0FFFFFFF
f.seek(coff(root)); rd = f.read(spc * bps)
cyc = None
for e in range(0, len(rd), 32):
    if rd[e] == 0: break
    if rd[e:e+11] == b'CYC        ' and rd[e+11] & 0x10:
        cyc = struct.unpack_from('<H', rd, e+26)[0] | (struct.unpack_from('<H', rd, e+20)[0] << 16)
if cyc is None: print("ERROR: CYC not in the root directory"); sys.exit(1)
chain = [cyc]; c = cyc
while True:
    n = fat(c)
    if n >= 0x0FFFFFF8: break
    if n < 2 or n > count + 1 or n in chain: print(f"ERROR: CYC chain already malformed at {c}->{n}"); sys.exit(1)
    chain.append(n); c = n
if len(chain) != 2: print(f"ERROR: CYC chain is {len(chain)} clusters, want exactly 2: {chain}"); sys.exit(1)
for c in chain:
    f.seek(coff(c)); d = f.read(spc * bps)
    nz = sum(1 for e in range(0, len(d), 32) if d[e] != 0)
    if nz != len(d) // 32: print(f"ERROR: cluster {c} has {nz}/{len(d)//32} populated entries — a 0x00 entry would end the walk early"); sys.exit(1)
A, B = chain
for n in range(nfats):
    f.seek(PART + (rsvd + n * fatsz) * bps + B * 4); f.write(struct.pack('<I', A))
f.flush()
for n in range(nfats):
    f.seek(PART + (rsvd + n * fatsz) * bps + B * 4)
    if struct.unpack_from('<I', f.read(4))[0] & 0x0FFFFFFF != A: print(f"ERROR: FAT copy {n} readback != {A}"); sys.exit(1)
print(f"  FAT32: bps={bps} spc={spc} (cluster={spc*bps} B) reserved={rsvd} nfats={nfats} count_of_clusters={count}")
print(f"  FAT32: CYC chain {A} -> {B} -> {A}  (both clusters {spc*bps//32}/{spc*bps//32} populated; {nfats} FAT copies patched)")
PY

# Construction floor #1: dosfstools must SEE the cycle (and must have had nothing to say about the
# volume one patch earlier — the smoke's own filler is verified the same way the kernel is).
dd if="$IMG" of="$WORK/esp.fat" bs=1M skip=1 status=none
FSCK_FAT=$(fsck.fat -n "$WORK/esp.fat" 2>&1); FSCK_FAT_RC=$?
if [ "$FSCK_FAT_RC" = 0 ] || ! printf '%s\n' "$FSCK_FAT" | grep -q "Circular cluster chain"; then
    echo "ERROR: fsck.fat does not see a circular chain on CYC (rc=$FSCK_FAT_RC) — the media carries no cycle;"
    echo "       a boot against it would test nothing. fsck.fat said:"
    printf '%s\n' "$FSCK_FAT" | sed 's/^/         /'
    exit 1
fi
echo "  fsck.fat -n: $(printf '%s\n' "$FSCK_FAT" | grep -m1 'Circular cluster chain' | sed 's/^ *//') (rc=$FSCK_FAT_RC) — cycle confirmed on p1"
rm -f "$WORK/esp.fat"

# --- p2: exFAT, formatted standalone (mkfs.exfat needs no loop device that way), then dd'd in ------
P2_FIRST=$(sgdisk -i 2 "$IMG" | awk '/First sector:/ {print $3}')
P2_SECTORS=$(sgdisk -i 2 "$IMG" | awk '/Partition size:/ {print $3}')
[ -n "$P2_FIRST" ] && [ -n "$P2_SECTORS" ] || { echo "ERROR: could not read p2 geometry"; exit 1; }
echo "  p2: first_lba=$P2_FIRST sectors=$P2_SECTORS"
EXPART="$WORK/exfat.part"
dd if=/dev/zero of="$EXPART" bs=512 count="$P2_SECTORS" status=none
# -c 512 → 1 sector per cluster: the cheapest possible fetch, since the budgeted walk is the
# volume's whole cluster count of them.
mkfs.exfat -c 512 "$EXPART" >/dev/null 2>&1 || { echo "ERROR: mkfs.exfat failed"; exit 1; }

# Fill the root cluster, allocate + fill a second cluster B, chain root -> B -> EOC (a VALID
# two-cluster root — checked by fsck.exfat below), then close the ring: FAT[B] = root.
echo "Patching exFAT root chain into a 2-node cycle..."
python3 - "$EXPART" <<'PY' || exit 1
import struct, sys
fn = sys.argv[1]
f = open(fn, 'r+b'); bs = f.read(512)
fat_off = struct.unpack_from('<I', bs, 80)[0]; heap = struct.unpack_from('<I', bs, 88)[0]
cc = struct.unpack_from('<I', bs, 92)[0]; root = struct.unpack_from('<I', bs, 96)[0]
bps = 1 << bs[108]; spc = 1 << bs[109]; nfats = bs[110]
def coff(c): return (heap + (c - 2) * spc) * bps
def fat(c):
    f.seek(fat_off * bps + c * 4); return struct.unpack_from('<I', f.read(4))[0]
def setfat(c, v):
    for n in range(nfats):
        f.seek((fat_off + n * struct.unpack_from('<I', bs, 84)[0]) * bps + c * 4); f.write(struct.pack('<I', v))
if fat(root) < 0xFFFFFFF8: print(f"ERROR: mkfs.exfat root chain is not a single cluster (FAT[{root}]={fat(root):#x})"); sys.exit(1)
f.seek(coff(root)); rd = bytearray(f.read(spc * bps))
bm_first = bm_len = None
for e in range(0, len(rd), 32):
    if rd[e] == 0x81:
        bm_first = struct.unpack_from('<I', rd, e+20)[0]; bm_len = struct.unpack_from('<Q', rd, e+24)[0]
if bm_first is None: print("ERROR: no 0x81 allocation bitmap entry in the root"); sys.exit(1)
f.seek(coff(bm_first)); bm = bytearray(f.read(bm_len))
def bit(c): i = c - 2; return (bm[i // 8] >> (i % 8)) & 1
B = root + 1
while B <= cc + 1 and (bit(B) or fat(B) != 0): B += 1
if B > cc + 1: print("ERROR: no free cluster after the root"); sys.exit(1)
# 0x20 = a not-in-use (InUse bit clear) Volume GUID slot — the placeholder mkfs.exfat itself writes
# into the root. Skipped silently by every exFAT walk in the kernel, invisible to fsck.
filler = bytes([0x20]) + bytes(31)
for e in range(0, len(rd), 32):
    if rd[e] == 0: rd[e:e+32] = filler
f.seek(coff(root)); f.write(rd)
f.seek(coff(B)); f.write(filler * (spc * bps // 32))
i = B - 2; bm[i // 8] |= 1 << (i % 8)
f.seek(coff(bm_first)); f.write(bm)
setfat(root, B); setfat(B, 0xFFFFFFFF)
f.flush()
print(f"  exFAT: cluster_count={cc} bps={bps} spc={spc} nfats={nfats} fat_offset={fat_off} heap={heap}")
print(f"  exFAT: root={root} B={B} (both clusters {spc*bps//32}/{spc*bps//32} populated) — chain root -> B -> EOC written, cycle NOT yet closed")
open(fn + '.cycle', 'w').write(f"{root} {B} {fat_off} {bps} {nfats} {struct.unpack_from('<I', bs, 84)[0]}\n")
PY
# Construction floor #2a: the filled two-cluster root must be VALID before the ring is closed, so
# that what fsck objects to next is the cycle and nothing else.
if ! fsck.exfat -n "$EXPART" >/dev/null 2>&1; then
    echo "ERROR: fsck.exfat rejects the filled (not yet cyclic) exFAT root — the filler is wrong, not the kernel:"
    fsck.exfat -n "$EXPART" 2>&1 | sed 's/^/         /'
    exit 1
fi
read -r EX_ROOT EX_B EX_FATOFF EX_BPS EX_NFATS EX_FATLEN < "$EXPART.cycle"
# Close the ring: FAT[B] = root, in every FAT copy, then read it back.
python3 - "$EXPART" "$EX_ROOT" "$EX_B" "$EX_FATOFF" "$EX_BPS" "$EX_NFATS" "$EX_FATLEN" <<'PY' || exit 1
import struct, sys
fn, root, B, fat_off, bps, nfats, fat_len = sys.argv[1], *map(int, sys.argv[2:8])
f = open(fn, 'r+b')
for n in range(nfats):
    f.seek((fat_off + n * fat_len) * bps + B * 4); f.write(struct.pack('<I', root))
f.flush()
for n in range(nfats):
    f.seek((fat_off + n * fat_len) * bps + B * 4)
    if struct.unpack_from('<I', f.read(4))[0] != root: print(f"ERROR: FAT copy {n} readback != {root}"); sys.exit(1)
print(f"  exFAT: FAT[{B}] = {root} written ({nfats} FAT copies) — ring closed: {root} -> {B} -> {root}")
PY
# Construction floor #2b: exfatprogs must SEE the cycle.
FSCK_EX=$(fsck.exfat -n "$EXPART" 2>&1); FSCK_EX_RC=$?
if [ "$FSCK_EX_RC" = 0 ] || ! printf '%s\n' "$FSCK_EX" | grep -qi "cyclic"; then
    echo "ERROR: fsck.exfat does not see a cyclic root chain (rc=$FSCK_EX_RC) — the media carries no cycle;"
    echo "       a boot against it would test nothing. fsck.exfat said:"
    printf '%s\n' "$FSCK_EX" | sed 's/^/         /'
    exit 1
fi
echo "  fsck.exfat -n: $(printf '%s\n' "$FSCK_EX" | grep -im1 'cyclic' | sed 's/^ *//') (rc=$FSCK_EX_RC) — cycle confirmed on p2 (root -> $EX_B -> root)"
dd if="$EXPART" of="$IMG" bs=512 seek="$P2_FIRST" conv=notrunc status=none

# --- boot -------------------------------------------------------------------------------------------
echo "Booting FATFS_SELFTEST+EXFAT_SELFTEST kernel against the cyclic media (NVMe + GPT)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/fat-cycle.log"
# Every assertion below is a BOOT-TIME selftest line, all of which land before the first `agnos>`
# (the same argument fat-smoke.sh makes), so the prompt is the safe dwell marker. A kernel that
# hangs in a walk never prints it and burns the whole budget — that is the RED path, by design.
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-180}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-FATCYCLE" \
    -serial stdio -display none -no-reboot

# ⛔ NON-VACUITY FLOOR: did the kernel run at all? qemu_dwell_kernel retries a firmware hand-off
# that never reaches the banner; if it STILL is not there, nothing below describes the kernel.
# VOID is neither PASS nor FAIL — say so, and exit non-zero so a caller cannot score it green.
if ! strings "$LOG" 2>/dev/null | grep -q "AGNOS kernel v"; then
    echo ""
    echo "  VOID: kernel banner never appeared — UEFI did not hand off; the kernel under test did not execute."
    echo "        Not a chain-cycle result. Log: $LOG"
    echo "=========================================="
    echo "FAT/exFAT chain-cycle smoke: VOID (kernel never ran)"
    echo "=========================================="
    exit 2
fi

echo ""
echo "  --- cycle lines from boot log ---"
strings "$LOG" | grep -E "^(\[[^]]*\] )?(fat: mounted|fatc:|fatr: chain-read|exfat: mounted|exfatc:|exfatr: no seeded|AGNOS shell)" | sed 's/^/  /'
echo ""

rc=0
# ⚠ VACUITY FLOOR (the exfat-smoke pattern): every verdict is counted and the count is checked
# against what this smoke promises, so a renamed marker cannot turn an assertion into silence.
gates=0
gpass() { echo "  PASS: $*"; gates=$((gates + 1)); }
gfail() { echo "  FAIL: $*"; rc=1; gates=$((gates + 1)); }
has() { strings "$LOG" | grep -q "^\(\[[^]]*\] \)\{0,1\}$1"; }

# --- FAT32 arm ---
if has "fat: mounted FAT32"; then gpass "FAT32 ESP mounted (partition-aware probe)"
else gfail "FAT32 mount (no 'fat: mounted FAT32' in log)"; fi
if has "fatc: predicate count->0 count+1->1 OK"; then gpass "fat_chain_overrun off-by-one contract (count -> 0, count+1 -> 1)"
else gfail "fat_chain_overrun contract (no 'fatc: predicate count->0 count+1->1 OK' — a chain EXACTLY count long must not be overrun)"; fi
if has "fatc: cycle-walk returned"; then gpass "FAT32 directory walk over CYC's A -> B -> A ring TERMINATED ($(strings "$LOG" | grep -m1 'fatc: cycle-walk returned' | sed 's/.*fatc: //'))"
else
    if has "fatc: cycle-walk start"; then gfail "FAT32 cycle walk HUNG — 'fatc: cycle-walk start' printed, 'fatc: cycle-walk returned' never did (the budget did not trip)"
    elif has "fatc: no CYC dir"; then gfail "FAT32 cycle lane not staged — kernel found no CYC directory (media construction, not the budget)"
    else gfail "FAT32 cycle walk (no 'fatc: cycle-walk' lines at all — selftest hook missing or boot died earlier)"; fi
fi
# The budget's other edge: a VALID 3-cluster chain on the same volume still reads byte-exact —
# the failure mode the ⛔ in fatfs.cyr warns of (an inherited count truncating a good file).
if has "fatr: chain-read OK"; then gpass "valid 3-cluster FATTEST.BIN still reads byte-exact on the cyclic volume (no false overrun)"
else gfail "valid chain read (no 'fatr: chain-read OK' — the budget must not truncate a legitimate chain)"; fi

# --- exFAT arm ---
if has "exfat: mounted"; then gpass "exFAT root walk (exfat_locate_system_files over root -> $EX_B -> root) TERMINATED — 'exfat: mounted' printed after it"
else gfail "exFAT mount HUNG or failed (no 'exfat: mounted' — the mount's root-directory walk is the first ring crossing)"; fi
if has "exfatc: predicate count->0 count+1->1 OK"; then gpass "exfat_chain_overrun off-by-one contract (count -> 0, count+1 -> 1)"
else gfail "exfat_chain_overrun contract (no 'exfatc: predicate count->0 count+1->1 OK')"; fi
if has "exfatr: no seeded file"; then gpass "exfat_find over the cyclic root TERMINATED ('exfatr: no seeded file' printed after it)"
else gfail "exfat_find over the cyclic root (no 'exfatr: no seeded file' after the walk)"; fi

# --- both: the boot got past every walk ---
if has "AGNOS shell v"; then gpass "boot reached the shell after every cyclic walk (no hang)"
else gfail "boot never reached the shell (no 'AGNOS shell v' — a walk hung or the kernel died)"; fi

EXPECT_GATES=8
echo ""
echo "  assertions scored: $gates/$EXPECT_GATES"
if [ "$gates" -lt "$EXPECT_GATES" ]; then
    echo "  FAIL: only $gates of $EXPECT_GATES assertions ran — a gate was SKIPPED, not passed."
    rc=1
fi

echo ""
echo "=========================================="
if [ "$rc" = "0" ]; then echo "FAT/exFAT chain-cycle smoke: PASS — $gates assertions"; else echo "FAT/exFAT chain-cycle smoke: FAIL"; fi
echo "Logs: $LOG"
echo "=========================================="
exit $rc
