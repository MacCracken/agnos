#!/bin/bash
# repro-ring3-pf.sh — boots the REAL agnsh kernel N times under qemu `-d int`
# and tallies ring-3 page faults (the CR2=0x10000000 / CR2=0x8 faults that
# freeze agnsh after its banner, per
# docs/development/issue/2026-06-04-agnsh-ring3-pf-pmm-fragmentation.md).
#
# A ring-3 #PF in QEMU's `-d int` trace is a `v=0e` (vector 14 = #PF) record
# whose CPL is 3. QEMU prints the exception header then a register dump that
# includes `CPL=N`; we treat a #PF record as ring-3 when its block reports
# CPL=3. We also independently tally the two signature CR2 values from the
# issue (0x10000000 = the present-supervisor arena fault, 0x8 = the NULL chain).
#
# Usage: sh scripts/repro-ring3-pf.sh <label> <N>
# Reuses one disk image across all N boots; only KASLR (RDRAND-seeded per boot)
# varies, which is exactly the run-to-run layout nondeterminism under test.
set -u

LABEL="${1:-repro}"
N="${2:-20}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
AGNOSHI="${AGNOSHI_ROOT:-$ROOT/../agnoshi}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
AGNSH="${AGNSH_BIN:-$AGNOSHI/build/agnsh_agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run ./scripts/build.sh"; exit 1; }
[ -f "$AGNSH" ]   || { echo "ERROR: agnsh-agnos not built ($AGNSH)"; exit 1; }

WORK="$ROOT/build/repro-ring3"; LOGS="$ROOT/build/repro-ring3-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
IMG="$WORK/agnos-agnsh.img"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 67 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$AGNSH" "$SEED/bin/agnsh"
echo "seeded /bin/agnsh ($(stat -c%s "$SEED/bin/agnsh") bytes)"

dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-AGNSH -b 4096 -m 0 \
    -O "$EXT2_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

pf3=0; cr2_10=0; cr2_8=0; clean=0; reached=0
echo "Booting $N times (label=$LABEL), -d int, tallying ring-3 #PF..."
for run in $(seq 1 "$N"); do
    cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
    SER="$LOGS/$LABEL-$run.serial"
    INT="$LOGS/$LABEL-$run.int"
    timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
        -serial "file:$SER" -display none -no-reboot \
        -d int -D "$INT" >/dev/null 2>&1

    # Did the kernel reach the agnsh exec at all this boot?
    if strings "$SER" 2>/dev/null | grep -q "kybernet: exec /bin/agnsh"; then
        reached=$((reached+1))
    fi

    # Ring-3 #PF detection: in this QEMU's `-d int` format every exception is a
    # single header line, e.g.
    #   N: v=0e e=0007 i=0 cpl=3 IP=... pc=... SP=... env->regs[R_EAX]=...
    # so a ring-3 page fault is one line matching BOTH `v=0e` and `cpl=3`.
    r3=$(grep -c "v=0e .* cpl=3" "$INT" 2>/dev/null); [ -z "$r3" ] && r3=0

    # The faulting address (CR2) is dumped separately by QEMU only on a real
    # #PF service; tally the two signature values from the issue independently.
    c10=$(grep -c "CR2=0000000010000000" "$INT" 2>/dev/null); [ -z "$c10" ] && c10=0
    c8=$(grep -c  "CR2=0000000000000008" "$INT" 2>/dev/null); [ -z "$c8" ]  && c8=0

    if [ "$r3" -gt 0 ]; then
        pf3=$((pf3+1))
        printf '  run %2d: RING-3 #PF (records=%s, CR2=10000000:%s CR2=8:%s)\n' "$run" "$r3" "$c10" "$c8"
    else
        clean=$((clean+1))
        printf '  run %2d: clean\n' "$run"
    fi
    cr2_10=$((cr2_10 + c10))
    cr2_8=$((cr2_8 + c8))
done

echo ""
echo "TALLY [$LABEL] N=$N : ring3-PF-boots=$pf3  clean-boots=$clean  reached-exec=$reached"
echo "        signature CR2 records across all boots: CR2=0x10000000:$cr2_10  CR2=0x8:$cr2_8"
[ "$pf3" -eq 0 ] && echo "REPRO: 0 ring-3 #PF / $N boots — PASS" || echo "REPRO: $pf3 ring-3 #PF boots / $N — see logs in $LOGS"
