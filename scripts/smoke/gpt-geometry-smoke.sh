#!/bin/sh
# gpt-geometry-smoke (1.57.12) — gpt.cyr reads a GPT in units of the DEVICE's logical block and walks the whole
# entry array; it refuses an entry size that is not 128 x 2^n.
#
# Until 1.57.12 the four array walkers read each 4 KB chunk as 8 LBAs at entries_lba + chunk x 8 — right only for
# 512 B LBAs — and stopped after 4 chunks (16 KB). Measured on that kernel with this smoke's disks:
#   4kn   (a 4096 B-LBA NVMe namespace, GPT written by sfdisk --sector-size 4096): every chunk read put 8 x 4 KB into
#         the one 4 KB page gpt_array_buf; the 28 KB past it held the NVMe queues — 63 "nvme: I/O stray CID 0
#         discarded", two 5 s poll timeouts, "nvme: late completion lost", the controller DISABLED, "array read failed",
#         no partition listed, the boot 20 s late.
#   e256  (128 x 256 B entries = a 32 KB array): "parts=2/128 ... arr-CRC-BAD", entry [100] never listed.
#   e384  (384 B entries, not 128 x 2^n): accepted, walked out of phase from chunk 1 on, entry [11] never listed.
# The fixed kernel lists every lane's partitions exactly as the host computes them and refuses e384 by name.
# Three more lanes from the adversarial review of those fixes (1.57.12, M1-M3), each measured RED on the kernel before
# them:
#   bad-primary  the primary's SizeOfPartitionEntry damaged to 384, its CRC NOT recomputed (the backup intact): the
#                geometry was refused BEFORE the CRC was checked, so the backup was never tried — "header declares an
#                unusable partition-entry geometry", no GPT. Now: CRC mismatch, the backup, both partitions listed.
#   big          16384 x 128 B entries (a 2 MiB array) — refused outright by the 1 MiB bound. Now walked TRUNCATED to
#                its first 1 MiB with a "table truncated" line (arr-CRC-UNVERIFIED): [0] [1] [8191] listed, [8192] and
#                [16383] (past the bound) not.
#   many         4096 used entries: the boot dump printed all 4096 and the framebuffer console's backlog paint started
#                kybernet at 155 s (TCG). Now the first 16 and "... and 4080 more"; this lane's 60 s dwell is the bound.
# Two more (1.57.12, the GPT defects D1 / D2), each measured RED on the kernel before its fix:
#   sparse       one used entry, in slot [100] — a Linux-FS partition holding an e2fsck-clean ext2. The FAT / exFAT /
#                ext2 / ZFS probes looped `pi < gpt_partition_count` (USED entries) over SLOT indices, so they probed
#                slot 0 only: `parts=1/128`, [100] listed, no ext2 mount. Now gpt.cyr's used-entry list (gpt_used_info):
#                "ext2: probe matched backend=2 partition_lba=2048" and "ext2: mounted".
#   bad-alt      the primary's AlternateLBA damaged to 77777 (zeros there), CRC not recomputed, the backup intact at the
#                last LBA: the kernel followed the failing header's pointer — "trying backup @ LBA 77777" — and booted
#                with NO GPT. Now the backup is read at the device's last LBA (UEFI 2.10 §5.3.2), its MyLBA and
#                AlternateLBA cross-checked: "trying backup @ LBA 131071 (the device's last LBA)", both partitions.
#
# Every lane boots the PLAIN kernel from a 512 B ESP disk on the SECOND NVMe controller (bootindex=0) with the test
# disk on the FIRST — the controller agnos registers as its block device (nvme_probe takes the lowest PCI index) and
# so the disk gpt_init parses. Lanes (disk 64 MiB; who wrote the table; what the kernel must print):
#   4kn       4096 B LBAs, sfdisk --sector-size 4096: [0] Linux FS 256-2303, [1] MSFT Basic, [2] Linux swap
#   4kn-e512  4096 B LBAs, gpt-image.py: 64 x 512 B entries (8 LBAs, 8 entries per chunk), [0] and the LAST entry [63]
#   e256      512 B LBAs, gpt-image.py: 128 x 256 B entries (32 KB), [0] [1] and [100] (chunk 6)
#   e384      512 B LBAs, gpt-image.py: 128 x 384 B entries -> "gpt: header declares an unusable partition-entry geometry"
#             (its CRC VERIFIES: a valid header with an unusable geometry is still refused outright)
#   bad-primary  512 B LBAs, 128 x 128 B: [0] [1]; then the primary damaged (gpt-image.py damage), the backup intact
#   big       512 B LBAs, 16384 x 128 B (2 MiB): [0] [1] [8191] and, past the 1 MiB walk bound, [8192] [16383]
#   many      512 B LBAs, 4096 x 128 B, all 4096 used (16 LBAs each): 16 listed, then "... and 4080 more"
#   sparse    512 B LBAs, 128 x 128 B, ONE entry, [100] (LBAs 2048-34815, an ext2 built by mke2fs + e2fsck -fn on its
#             own file, then copied in and compared back): the ext2 must mount at partition_lba=2048
#   bad-alt   512 B LBAs, 128 x 128 B: [0] [1]; then the primary's AlternateLBA damaged to 77777 (gpt-image.py damage
#             --at 32), the backup intact — recovered from the LAST LBA, and no "LBA 77777" anywhere in the log
# Host oracles, before any boot: gpt-image.py verify (both headers, both arrays, every CRC, the backup mirror) on every
# lane, and sfdisk -d (libfdisk — a second, independent GPT reader) must list the same partitions at the same LBAs.
# The kernel's expected lines come from gpt-image.py expect (gpt_print_summary / gpt_print_all_partitions' format).
# Denied in every lane: "array read failed", "nvme: I/O stray CID", "nvme: I/O poll timeout", "late completion lost",
# "blk: REFUSED", PANIC / Double Fault / #PF / #GP.
# Env: GPTG_LANES (default "4kn 4kn-e512 e256 e384 bad-primary big many sparse bad-alt"), QEMU_TIMEOUT (default 60),
# QEMU_TRIES.
# Exit: 0 PASS · 1 FAIL · 2 VOID (the firmware never handed off). Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT="${GNOBOOT_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/gnoboot}/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
GPTI="$ROOT/scripts/smoke/lib/gpt-image.py"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"

for tool in qemu-system-x86_64 mformat mmd mcopy parted sfdisk python3 strings truncate mke2fs e2fsck cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool' — this gate measured NOTHING"; exit 1; }
done
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT — this gate measured NOTHING"; exit 1; }
OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/gpt-geometry-smoke"; LOGS="$ROOT/build/gpt-geometry-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
echo "=== gpt-geometry smoke (4Kn GPT, 256/512 B entries, 384 B refused, backup recovery, > 1 MiB, 4096 used, sparse, bad AlternateLBA) ==="
echo "[1/3] Building the plain kernel..."
sh "$ROOT/scripts/build.sh" > "$LOGS/build.log" 2>&1 || { echo "  ERROR: kernel build failed ($LOGS/build.log) — this gate measured NOTHING"; exit 1; }
smoke_require_image "$AGNOS" ""
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

fail=0; pass=0; void=0
ok()  { echo "  PASS: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*"; fail=$((fail + 1)); }

# lane_disk LANE IMG -> writes the lane's table onto IMG and prints its LBA size
lane_disk() {
    truncate -s 64M "$2"
    case "$1" in
        4kn)
            printf 'label: gpt\nstart=256, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="alpha"\nstart=2304, size=2048, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="beta"\nstart=4352, size=4096, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F, name="gamma"\n' \
                | sfdisk -q --sector-size 4096 "$2" >/dev/null 2>&1 || return 1
            echo 4096 ;;
        4kn-e512)
            python3 -I "$GPTI" write "$2" --lba 4096 --esize 512 --nents 64 --part 0:linux:256:2303:alpha \
                --part 63:msft:2304:4351:last >/dev/null || return 1
            echo 4096 ;;
        e256)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 256 --nents 128 --part 0:linux:2048:4095:alpha \
                --part 1:msft:4096:6143:beta --part 100:swap:6144:8191:far >/dev/null || return 1
            echo 512 ;;
        e384)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 384 --nents 128 --part 0:linux:2048:4095:alpha \
                --part 1:msft:4096:6143:beta --part 11:swap:6144:8191:eleven >/dev/null || return 1
            echo 512 ;;
        bad-primary)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 128 --nents 128 --part 0:linux:2048:4095:alpha \
                --part 1:msft:4096:6143:beta >/dev/null || return 1
            echo 512 ;;
        big)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 128 --nents 16384 --part 0:linux:4098:6145:alpha \
                --part 1:msft:6146:8193:beta --part 8191:swap:8194:10241:edge --part 8192:linux:10242:12289:past \
                --part 16383:linux:12290:14337:omega >/dev/null || return 1
            echo 512 ;;
        many)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 128 --nents 4096 --fill 4096:linux:1026:16 >/dev/null || return 1
            echo 512 ;;
        sparse)
            # ONE used entry, in slot [100] — a Linux-FS partition carrying a real ext2 (mke2fs on its own file,
            # e2fsck-clean, then copied in at its first LBA). LBAs 2048-34815 = 16 MiB.
            python3 -I "$GPTI" write "$2" --lba 512 --esize 128 --nents 128 --part 100:linux:2048:34815:data \
                >/dev/null || return 1
            mkdir -p "$WORK/seed"; printf 'gpt-geometry sparse lane: slot 100\n' > "$WORK/seed/hello.txt"
            rm -f "$WORK/sparse-ext2.img"; truncate -s 16M "$WORK/sparse-ext2.img"
            mke2fs -t ext2 -F -q -b 4096 -L gpt-sparse -d "$WORK/seed" "$WORK/sparse-ext2.img" >/dev/null 2>&1 || return 1
            e2fsck -fn "$WORK/sparse-ext2.img" >/dev/null 2>&1 || return 1
            dd if="$WORK/sparse-ext2.img" of="$2" bs=512 seek=2048 conv=notrunc status=none || return 1
            echo 512 ;;
        bad-alt)
            python3 -I "$GPTI" write "$2" --lba 512 --esize 128 --nents 128 --part 0:linux:2048:4095:alpha \
                --part 1:msft:4096:6143:beta >/dev/null || return 1
            echo 512 ;;
        *) return 1 ;;
    esac
}

echo "[2/3] Host oracles + boots..."
for lane in ${GPTG_LANES:-4kn 4kn-e512 e256 e384 bad-primary big many sparse bad-alt}; do
    IMG="$WORK/$lane.img"; LOG="$LOGS/$lane.log"
    echo "--- lane $lane ---"
    LB=$(lane_disk "$lane" "$IMG") || { bad "$lane: the test disk could not be written"; continue; }
    # Host oracle 1: our own reader — every CRC, the backup mirror.
    if python3 -I "$GPTI" verify "$IMG" --lba "$LB" > "$LOGS/$lane.verify" 2>&1; then
        ok "$lane: host verify — $(tail -1 "$LOGS/$lane.verify")"
    else
        bad "$lane: host verify — $(tail -1 "$LOGS/$lane.verify")"; continue
    fi
    # Host oracle 2: libfdisk lists the same partitions at the same LBAs (start + size - 1 = last).
    WANT=$(grep -E '^  \[' "$LOGS/$lane.verify" | sed 's/^  \[\([0-9]*\)\] \([0-9]*\)-\([0-9]*\) .*/\1 \2 \3/')
    HAVE=$(sfdisk --sector-size "$LB" -d "$IMG" 2>/dev/null | sed -n 's/^.*\.img\([0-9]*\) : start= *\([0-9]*\), size= *\([0-9]*\),.*/\1 \2 \3/p' \
        | awk '{ print $1 - 1, $2, $2 + $3 - 1 }')
    if [ -n "$WANT" ] && [ "$WANT" = "$HAVE" ]; then ok "$lane: sfdisk -d agrees ($(printf '%s' "$WANT" | tr '\n' ';' | cut -c1-120))"
    else bad "$lane: sfdisk -d disagrees — host verify [$WANT] vs sfdisk [$HAVE]"; continue; fi
    if [ "$lane" = "sparse" ]; then
        # Host oracle 3: the ext2 the kernel must mount is in slot [100]'s LBAs, byte for byte (verify above re-read
        # every GPT CRC after the copy, so the copy did not touch the table either).
        dd if="$IMG" bs=512 skip=2048 count=32768 status=none | cmp -s - "$WORK/sparse-ext2.img" \
            && ok "$lane: slot [100]'s LBAs 2048-34815 hold the e2fsck-clean ext2" \
            || { bad "$lane: the ext2 is not at slot [100]'s LBAs"; continue; }
    fi
    if [ "$lane" = "bad-primary" ] || [ "$lane" = "bad-alt" ]; then
        # bad-primary: the PRIMARY header's SizeOfPartitionEntry (offset 84) damaged to 384 without fixing its CRC: bad
        # geometry AND a bad CRC. bad-alt: its AlternateLBA (offset 32) pointed at LBA 77777 — zeros, inside the disk —
        # without fixing its CRC: the backup pointer of a header that does not verify is garbage, and the backup is
        # the device's LAST LBA (UEFI 2.10 §5.3.2). The host must now refuse the primary on its CRC, and libfdisk must
        # recover the same partitions from the backup.
        DMG="--at 84 --u32 384"; [ "$lane" = "bad-alt" ] && DMG="--at 32 --u32 77777"
        python3 -I "$GPTI" damage "$IMG" --lba "$LB" $DMG > /dev/null || { bad "$lane: damage failed"; continue; }
        if python3 -I "$GPTI" verify "$IMG" --lba "$LB" > "$LOGS/$lane.verify-damaged" 2>&1; then
            bad "$lane: the damaged primary still verifies on the host"; continue
        fi
        grep -q "FAIL: header CRC at LBA 1" "$LOGS/$lane.verify-damaged" \
            && ok "$lane: host verify after the damage — $(tail -1 "$LOGS/$lane.verify-damaged")" \
            || { bad "$lane: host verify after the damage — $(tail -1 "$LOGS/$lane.verify-damaged")"; continue; }
        HAVE=$(sfdisk --sector-size "$LB" -d "$IMG" 2>/dev/null | sed -n 's/^.*\.img\([0-9]*\) : start= *\([0-9]*\), size= *\([0-9]*\),.*/\1 \2 \3/p' \
            | awk '{ print $1 - 1, $2, $2 + $3 - 1 }')
        [ "$WANT" = "$HAVE" ] && ok "$lane: sfdisk -d recovers the same partitions from the backup" \
            || { bad "$lane: sfdisk -d after the damage [$HAVE], want [$WANT]"; continue; }
    fi
    if [ "$lane" = "e384" ]; then
        EXP="gpt: header declares an unusable partition-entry geometry"
    else
        EXP=$(python3 -I "$GPTI" expect "$IMG" --lba "$LB") || { bad "$lane: gpt-image.py expect failed"; continue; }
    fi
    # sparse: the filesystem probes must reach slot [100] — ext2 mounts it (gpt.cyr's used-entry list, 1.57.12 D1).
    if [ "$lane" = "sparse" ]; then
        EXP="$EXP
ext2: probe matched backend=2 partition_lba=2048
ext2: mounted (blocksize=4096"
    fi
    printf '%s\n' "$EXP" > "$LOGS/$lane.expect"
    QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp|Please select boot device}" \
    qemu_dwell_kernel "$LOG" "kybernet: emergency shell" "${QEMU_TIMEOUT:-60}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=t0" \
        -device "nvme,drive=t0,serial=GPT-$lane,logical_block_size=$LB,physical_block_size=$LB" \
        -drive "file=$ESP,format=raw,if=none,id=b0" -device "nvme,drive=b0,serial=GPT-BOOT,bootindex=0" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "  VOID: lane $lane — the kernel never ran"; void=$((void + 1)); continue; fi
    TXT=$(strings "$LOG")
    printf '%s\n' "$TXT" | grep -aE "nvme: ns1 NSZE|gpt: |partitions \(|^\[[^]]*\]   \[[0-9]+\]" | sed 's/^/    /'
    printf '%s\n' "$TXT" | grep -q "nvme: ns1 NSZE=[0-9]* LBAS=${LB}B" \
        && ok "$lane: the test disk is the registered NVMe namespace, ${LB} B LBAs" \
        || { bad "$lane: no 'nvme: ns1 ... LBAS=${LB}B' — the kernel did not register the test disk"; continue; }
    miss=0
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        printf '%s\n' "$TXT" | grep -qF -- "$want" || { bad "$lane: missing kernel line: $want"; miss=1; }
    done < "$LOGS/$lane.expect"
    [ "$miss" = 0 ] && ok "$lane: kernel printed all $(grep -c . "$LOGS/$lane.expect") expected line(s)"
    if [ "$lane" = "e384" ]; then
        printf '%s\n' "$TXT" | grep -q "gpt: present" && bad "$lane: the kernel accepted a 384 B entry size" \
            || ok "$lane: no 'gpt: present' — the table was refused, not walked"
    else
        # Exactly the expected partition lines — nothing more.
        n_exp=$(grep -c '^  \[' "$LOGS/$lane.expect"); n_got=$(printf '%s\n' "$TXT" | grep -cE '^\[[^]]*\]   \[[0-9]+\] ')
        [ "$n_exp" = "$n_got" ] && ok "$lane: $n_got partition line(s), as expected" \
            || bad "$lane: $n_got partition line(s), expected $n_exp"
    fi
    # bad-alt: the garbage AlternateLBA is never followed (1.57.12 D2).
    if [ "$lane" = "bad-alt" ]; then
        printf '%s\n' "$TXT" | grep -q "LBA 77777" && bad "$lane: the kernel followed the failing primary's AlternateLBA" \
            || ok "$lane: the failing primary's AlternateLBA (77777) was not followed"
    fi
    DENY=$(printf '%s\n' "$TXT" | grep -aE "array read failed|nvme: I/O stray CID|nvme: I/O poll timeout|late completion lost|blk: REFUSED|PANIC|Double Fault|#PF|#GP" | head -3)
    [ -z "$DENY" ] && ok "$lane: no denied line (array read / stray CID / poll timeout / PANIC / fault)" \
        || bad "$lane: denied line(s): $(printf '%s' "$DENY" | tr '\n' '|')"
    printf '%s\n' "$TXT" | grep -q "kybernet: starting init" \
        && ok "$lane: boot continued to kybernet" || bad "$lane: the boot never reached kybernet"
done

echo "[3/3] Verdict"
echo "=== gpt-geometry-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
