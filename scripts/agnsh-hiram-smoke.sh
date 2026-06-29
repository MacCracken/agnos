#!/bin/bash
# agnsh-hiram-smoke (1.49.12) — boot-to-agnsh at LARGE RAM, the >256 MB regression guard.
#
# WHY: the 1.49.11 >256 MB RAM extension lets pmm_alloc_2mb hand out 2 MB user pages
# above the 256 MB identity ceiling, reached by the kernel via the direct-map
# (pmm_kva_for_access). The default smokes (agnsh/exec/mmap) all boot at <=1 GB, so
# they NEVER cross 256 MB and never exercise that path — which is exactly how the
# raw-physical-address #PF in sys_mmap/elf_load (the 1.49.12 fix) reached the 64 GB
# iron burn uncaught (agnsh locked up the moment its heap mmap returned a >256 MB
# region). This boots the SAME agnsh rootfs at -m ${HIRAM_MB:-8192}M and asserts
# kybernet launches /bin/agnsh and the shell reaches its prompt — i.e. agnsh's heap
# mmap of a >256 MB region was zeroed + mapped without faulting.
#
# Requires KVM (TCG at 8 GB is impractically slow) + a host with enough RAM. SKIPs
# cleanly (exit 0) when KVM is unavailable so CI without /dev/kvm doesn't break.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HIRAM_MB="${HIRAM_MB:-8192}"

if [ ! -r /dev/kvm ]; then
    echo "SKIP: /dev/kvm not available — agnsh-hiram-smoke needs KVM (TCG at ${HIRAM_MB}M is too slow)."
    exit 0
fi

# Reuse agnsh-smoke's disk builder: it stages /bin/agnsh on ext2 + boots once at
# 512M (the baseline). We then re-boot that exact image at large RAM.
if ! sh "$ROOT/scripts/agnsh-smoke.sh" >/dev/null 2>&1; then
    echo "FAIL: agnsh-smoke (the 512M baseline + disk build) did not pass — fix that first."
    exit 1
fi

W="$ROOT/build/agnsh-smoke"
IMG="$W/agnos-agnsh.img"
[ -f "$IMG" ] || { echo "FAIL: agnsh disk image not found at $IMG"; exit 1; }

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
[ -n "$OVMF_CODE" ] || { echo "FAIL: OVMF firmware not found"; exit 1; }

LOG="$W/hiram-${HIRAM_MB}.ser.log"
cp "$W/vars.fd" "$W/vars-hiram.fd"; chmod +w "$W/vars-hiram.fd"

echo "=== AGNOS agnsh boot-to-prompt at -m ${HIRAM_MB}M (>256 MB direct-map exec/mmap path) ==="
timeout "${QEMU_TIMEOUT:-90}" qemu-system-x86_64 \
    -machine q35 -m "${HIRAM_MB}M" -enable-kvm -cpu host -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$W/vars-hiram.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
    -serial file:"$LOG" -display none -no-reboot >/dev/null 2>&1

RAM_LINE=$(strings "$LOG" | grep -oE "RAM: usable=[0-9]+MB" | head -1)
TOP_LINE=$(strings "$LOG" | grep -oE "PMM: 2mb_top_region=[0-9]+" | head -1)
echo "  ${RAM_LINE:-RAM: usable=?}  ${TOP_LINE:-2mb_top_region=?}"

# 2mb_top_region must have lifted past the 128-region (256 MB) bootstrap cap, proving
# the migration ran — otherwise this isn't actually testing the >256 MB path.
TOP=$(echo "$TOP_LINE" | grep -oE "[0-9]+$")
if [ -z "${TOP:-}" ] || [ "$TOP" -le 128 ]; then
    echo "FAIL: PMM 2mb_top_region did not lift past 128 — the bitmap migration didn't run, so the >256 MB path is untested."
    exit 1
fi

if strings "$LOG" | grep -q "ASSIST"; then
    echo "PASS: kybernet launched /bin/agnsh and the shell reached its prompt at ${HIRAM_MB}M (>256 MB heap mmap zeroed via the direct-map, no raw-phys #PF)."
    echo "=== agnsh-hiram-smoke: PASS ==="
    exit 0
fi

echo "  --- boot tail (kybernet onward) ---"
strings "$LOG" | sed -n '/kybernet: starting init/,$p' | tail -6 | sed 's/^/  /'
echo "FAIL: agnsh did NOT reach its prompt at ${HIRAM_MB}M — likely a >256 MB access regression (raw phys instead of pmm_kva_for_access). Reproduce: boot the agnsh disk at -m 8G and read RIP/CR2 from the QMP monitor."
echo "=== agnsh-hiram-smoke: FAIL ==="
exit 1
