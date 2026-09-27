#!/bin/sh
# vtd-smoke.sh — 1.57.10 (VTD): boot kernel/arch/x86_64/iommu.cyr with Intel VT-d DMA translation ON and prove xHCI (the
# keyboard + a USB stick), NVMe, virtio-blk, virtio-net, AHCI and HDA DMA all keep working through it.
# Issue: docs/development/issues/archived/2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted.md. Until 1.57.10 NO boot had
# ever enabled translation (QEMU's DMAR included — iommu_init failed at its first step), so the pre-init grant replay, the
# post-TE invalidation under Caching Mode, the table walker, the per-bus context tables and every driver's grants were
# gated by reading only. docs/architecture/dma-cpu-pointers.md § "VT-d: the grant model".
#
# The smoke wraps scripts/harness/vtd-iommu-test.py (the console-line / wait-kbd precedent: a harness that must TYPE, via
# the HMP monitor). It builds a VTD_SELFTEST kernel (iommu.cyr vtd_selftest: an ungranted page is BLOCKED with the fault
# recorded; a grant made after TE gets exactly the invalidation CM needs; the granted page then works byte-exact) and
# boots it twice — A: -smp 1 TCG, caching-mode=on, aw-bits=39 (3-level); B: -smp 4 KVM (else multi-threaded TCG),
# caching-mode=off, aw-bits=48 (4-level), the xHCI behind a pcie-root-port (bus 1). Banner-gated retries (a boot that never
# handed off is VOID, never scored), the shared SMOKE_INVARIANT_DENY (through _invdeny.py), and QEMU's OWN trace
# (vtd_dmar_fault / vtd_iotlb_page_update / vtd_reg_write) cross-checked against the kernel's lines. See the harness header.
# The tree is left with a PLAIN build/agnos; the plain kernel must carry the production lines and not the instrument.
# Env: VTD_CONFIGS (default "A B"), SMOKE_KVM, QEMU_TRIES.
# Exit: 0 all PASS · 1 any FAIL · 2 VOID (or the harness could not be set up).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== VT-d smoke (iommu.cyr with DMA translation ON: xHCI / NVMe / virtio / AHCI / HDA through the IOMMU) ==="
LOGS="$ROOT/build/vtd-smoke-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
WORK="$ROOT/build/vtd-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "[build] VTD_SELFTEST=1, then plain (the tree is left plain)"
VTD_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-vtd.log" 2>&1 \
    || { echo "  ERROR: VTD_SELFTEST build failed ($LOGS/build-vtd.log) — this gate measured NOTHING"; sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-vtd"
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 \
    || { echo "  ERROR: plain build failed ($LOGS/build-plain.log) — this gate measured NOTHING"; exit 1; }

echo "[C] the instrument is in the test kernel only; the production VT-d lines are in both"
if strings "$WORK/agnos-vtd" | grep -qF 'vtdst: blocked PASS'; then ok "the test kernel carries the VTD_SELFTEST instrument"
else bad "the test kernel does NOT carry the instrument — VTD_SELFTEST never reached the source"; fi
if strings "$ROOT/build/agnos" | grep -qF 'vtdst:'; then bad "the PLAIN production kernel carries the VTD_SELFTEST instrument"
else ok "the instrument is compiled out of production"; fi
for line in 'IOMMU: boot DMA check - faults=' 'IOMMU: VT-d unit 0x'; do
    if strings "$ROOT/build/agnos" | grep -qF "$line"; then ok "production carries '$line'"
    else bad "production lacks '$line' — the VT-d report is not in the shipped kernel"; fi
done

echo "[boot] scripts/harness/vtd-iommu-test.py"
VTD_KERNEL="$WORK/agnos-vtd" python3 "$ROOT/scripts/harness/vtd-iommu-test.py" > "$LOGS/harness.log" 2>&1
rc=$?
cat "$LOGS/harness.log"
for d in "$WORK"/A* "$WORK"/B*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    for f in serial.log trace.log qemu-stderr.log; do [ -f "$d/$f" ] && cp "$d/$f" "$LOGS/$n-$f"; done
done
echo "=== vtd-smoke: static $pass passed, $fail failed; harness rc=$rc — logs in $LOGS ==="
if [ "$fail" -gt 0 ] || [ "$rc" = 1 ]; then echo "vtd-smoke: FAIL"; exit 1; fi
if [ "$rc" = 2 ]; then echo "vtd-smoke: VOID (a boot never handed off, or the harness could not be set up)"; exit 2; fi
echo "vtd-smoke: PASS"
exit 0
