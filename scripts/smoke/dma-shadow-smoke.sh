#!/bin/bash
# dma-shadow-smoke.sh — block + HDA DMA under a SHADOWED identity window (DMA_SHADOW_SELFTEST=1), 1.57.8.
# Issue: docs/development/issues/2026-09-25-dma-cpu-pointers-still-use-identity-vas.md
# Invariant: docs/architecture/dma-cpu-pointers.md
#
# Two halves:
#   STATIC  no load/store in virtio_blk.cyr / nvme.cyr / ahci.cyr / hda.cyr takes a `*_phys` value as its address
#           (the 1.57.7 S4 §2.5 grep shape): a phys belongs in a device register, an SQE/PRP/CTBA/PRDT field or a
#           descriptor address, never in a CPU dereference.
#   BOOT    dma_shadow_selftest (core/selftests.cyr) builds a CR3 whose PD[2..127] — the whole pmm identity window
#           [4 MB, 256 MB) — all map ONE 2 MB region of 0xA5 (what a ring-3 PT_LOAD over that window does), then, IF=0
#           under it: single-sector + 8-sector + FLUSH on virtio-blk, NVMe and AHCI, NVMe's 24-sector PRP-list path, and
#           two HDA verbs. Every transfer must be byte-exact and the verb must return the vendor read before the switch.
#           RED on a driver that still reaches a pmm DMA page through phys == VA (its descriptor / SQE / CORB entry goes
#           into the shadow; the device never sees it).
#   "dmash: shadow PASS"   the identity VA of a pmm page reads the shadow and its direct-map alias the real page —
#                          the self-check that the window really is shadowed (without it the test proves nothing).
#   "dmash: virtio PASS" / "nvme PASS" / "nvme-prp PASS" / "ahci PASS" / "hda PASS", then "dmash: done".
#
# Banner-gated retry (qemu_dwell_kernel; exit 2 on a firmware VOID), PASS/FAIL per check, the shared latched-invariant
# deny ($SMOKE_INVARIANT_DENY), two boots: -smp 1 (TCG) and a GATED -smp 4 (smoke_accel). DSH_SMP overrides ("1 4").
# Gated by scripts/sweep.sh (DMA_SHADOW_SELFTEST=1). Requires: a kernel built with DMA_SHADOW_SELFTEST=1, qemu, OVMF,
# mtools, parted, gnoboot. DESTRUCTIVE on its own scratch disks only (fresh per boot).
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"     # qemu_dwell_kernel, qemu_assert_booted, smoke_accel, SMOKE_INVARIANT_DENY
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

pass=0
fail=0
void=0

# ---- STATIC: no CPU dereference of a *_phys value in the four drivers ----
echo "=== AGNOS DMA shadow smoke ==="
DRV="kernel/core/virtio_blk.cyr kernel/core/nvme.cyr kernel/core/ahci.cyr kernel/core/hda.cyr"
HITS=$(cd "$ROOT" && grep -nE '(load|store)(8|16|32|64) *\( *[A-Za-z_]*_phys\b' $DRV | grep -vE '^[^:]+:[0-9]+: *#')
if [ -z "$HITS" ]; then
    echo "PASS: [static] no load/store takes a *_phys address in virtio_blk/nvme/ahci/hda"; pass=$((pass + 1))
else
    echo "FAIL: [static] a CPU dereference of a *_phys value:"; echo "$HITS" | head -10 | sed 's/^/        /'; fail=$((fail + 1))
fi

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "ERROR: OVMF firmware not found — this gate measured NOTHING" >&2
    exit 1
fi
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not on PATH" >&2; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="${SMOKE_KERNEL:-$ROOT/build/agnos}"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos kernel not built at $AGNOS" >&2; exit 1; }
[ -n "${SMOKE_KERNEL:-}" ] || smoke_require_image "$AGNOS" "DMA_SHADOW_SELFTEST"

WORK="$ROOT/build/dma-shadow-smoke"
LOGS="$ROOT/build/dma-shadow-smoke-logs"
rm -rf "$WORK" "$LOGS"
mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
echo "  agnos: $AGNOS ($(stat -c %s "$AGNOS") B)"

check() {
    if grep -qa "$1" "$LOG"; then echo "PASS: [$SMP] $2"; pass=$((pass + 1));
    else echo "FAIL: [$SMP] '$1' not found — $3"; fail=$((fail + 1)); fi
}
deny() {
    if grep -qaE "$1" "$LOG"; then echo "FAIL: [$SMP] $2"; grep -aE "$1" "$LOG" | head -3 | sed 's/^/        /'; fail=$((fail + 1));
    else echo "PASS: [$SMP] $3"; pass=$((pass + 1)); fi
}
for SMP in ${DSH_SMP:-1 4}; do
    # FRESH disks per boot. ⛔⛔ 1.56.51 — the ESP recipe that hands off: a 128 MB disk, ESP at 1-33 MiB, on NVMe (see
    # edge-abi-smoke.sh); the selftest writes NVMe LBAs from nsze/2 (the unpartitioned half). virtio-blk and AHCI get
    # blank 16 MB scratch disks (sectors 64..95 written).
    dd if=/dev/zero of="$ESP" bs=1M count=128 status=none
    parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
    mformat -i "$ESP"@@1048576 -F
    mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos
    dd if=/dev/zero of="$WORK/vblk.img" bs=1M count=16 status=none
    dd if=/dev/zero of="$WORK/sata.img" bs=1M count=16 status=none
    LOG="$LOGS/dma-shadow-smp$SMP.log"
    ACCEL="$(smoke_accel "$SMP")"
    echo ""
    echo "--- boot: -smp $SMP  accel: $ACCEL ---"
    qemu_dwell_kernel "$LOG" "dmash: done" "${QEMU_TIMEOUT:-150}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
        qemu-system-x86_64 -machine q35 -m 512M $ACCEL -smp "$SMP" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "nvme,drive=esp0,serial=AGNOS-DSH" \
        -drive "file=$WORK/vblk.img,format=raw,if=none,id=vb0" \
        -device "virtio-blk-pci,drive=vb0" \
        -drive "file=$WORK/sata.img,format=raw,if=none,id=sd0" \
        -device "ich9-ahci,id=ahci0" \
        -device "ide-hd,drive=sd0,bus=ahci0.0" \
        -audiodev "none,id=snd0" \
        -device "intel-hda,id=hda0" \
        -device "hda-duplex,bus=hda0.0,audiodev=snd0" \
        -serial stdio -display none -no-reboot
    if ! qemu_assert_booted "$LOG"; then echo "VOID: -smp $SMP never booted"; void=$((void + 1)); continue; fi
    echo "--- serial log (dmash lines) ---"
    grep -aE "dmash:|nvme: (late|I/O)|virtio_blk|vblk" "$LOG" | head -20 || echo "(no dmash lines captured)"
    echo "--------------------------------"
    check "dmash: shadow PASS"   "the identity window is shadowed and the direct map is intact (self-check)" "the test proves nothing"
    check "dmash: virtio PASS"   "virtio-blk: 1 + 8 sectors + FLUSH byte-exact under the shadow"   "virtio-blk rings reached by identity VA"
    check "dmash: nvme PASS"     "NVMe: 1 + 8 sectors + FLUSH byte-exact under the shadow"          "NVMe SQ/CQ/scratch reached by identity VA"
    check "dmash: nvme-prp PASS" "NVMe: 24-sector PRP-list transfer byte-exact under the shadow"    "NVMe PRP list written by identity VA"
    check "dmash: ahci PASS"     "AHCI: 1 + 8 sectors + FLUSH byte-exact under the shadow"          "AHCI CL/CT reached by identity VA"
    check "dmash: hda PASS"      "HDA: CORB/RIRB verb round-trip under the shadow"                  "CORB/RIRB reached by identity VA"
    check "dmash: done"          "the selftest ran to its last line"                                "the selftest did not finish"
    deny "dmash: [a-z-]+ (FAIL|SKIP)" "an arm printed FAIL or SKIP" "no arm printed FAIL or SKIP"
    deny "$SMOKE_INVARIANT_DENY" "a latched kernel invariant fired" "no latched invariant"
done

echo ""
echo "=== dma-shadow-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
