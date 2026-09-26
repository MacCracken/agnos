#!/bin/sh
# kvm-net-boot-smoke.sh — 1.57.8 (KVMCON): a PLAIN kernel with a virtio-net NIC boots at normal speed UNDER KVM.
#
# ⛔ WHAT THIS GUARDS. Through 1.57.7 a KVM boot with `-device virtio-net-pci` drew every console line in ~1.45 s and
# reached `kybernet: exec` at ~80 s (vs ~10 s without the NIC, and under TCG either way). Root cause (measured): the
# virtio cap walk hands every vendor cap's BAR to vmm_remap_uc_2mb, the PCI_CFG cap (cfg_type 5) names BAR0 with
# offset = length = 0, virtio-net's BAR0 is the LEGACY I/O BAR, and pci_bar_64 answered its port base (0x6060) —
# so PD[0] (phys 0-2 MB: the boot page tables and the kernel's first megabyte of CODE, fb console included) went
# UC. TCG ignores memory types, which is why only KVM ever showed it. Fixed at the root (pci_bar_64 is MMIO-only:
# an I/O BAR answers 0) with a backstop (vmm_remap_uc_2mb refuses phys < 4 MB and prints a SMOKE_INVARIANT_DENY
# line). The same boot also carried ~2 s of dead air before the console: chan_region_reserve zeroed its band
# through the direct map while still on gnoboot's CR3 (8 GB + phys = unbacked -> one unassigned-MMIO exit per
# store under KVM, and the band never zeroed); it now runs after cr3_load(0x1000).
#
# Boots -smp 1 THEN -smp 4, BOTH under KVM (`-enable-kvm -cpu host` — this gate is ABOUT KVM, so a host without a
# writable /dev/kvm is an ERROR: the gate measured nothing), each with `-netdev user -device virtio-net-pci`.
# /bin/agnsh is a 131-byte ELF that exits 0 (the milestone is kybernet's exec, not the shell). Per boot:
#   - the NIC was really driven (`VirtIO-net: MAC=`) — otherwise nothing here was exercised
#   - `kybernet: exec` at a KERNEL timestamp <= KVMNET_BUDGET s (default 20; RED at ~80 s before the fix). The
#     kernel's own clock, not the host's wall time, so host load cannot flip it.
#   - the pre-console window `PMM: 2mb_top_region` -> `kernel CR3: own PML4` <= KVMNET_PRE_MS ms (default 500;
#     ~2000 ms before the chan move): a direct-map access under gnoboot's CR3 costs seconds under KVM.
#   - DENIES `PANIC`, `emergency shell` and the shared SMOKE_INVARIANT_DENY (incl. `vmm: UC remap of the kernel low
#     4 MB`, which a regression of the pci_bar_64 contract prints).
# Every boot is banner-gated (no "AGNOS kernel v" = VOID, re-run, never scored).
# Env: KVMNET_SMP (default "1 4"), KVMNET_BUDGET, KVMNET_PRE_MS, QEMU_TIMEOUT (per boot, default 150 s — long enough
# that a slow kernel is scored on its timestamp rather than on a missing marker).
# Exit: 0 every check PASS · 1 any FAIL (or KVM/tools missing) · 2 VOID. Leaves a PLAIN build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== kvm-net-boot smoke (virtio-net under KVM: console speed, pre-console window) ==="
[ -w /dev/kvm ] || { echo "  ERROR: /dev/kvm is not writable — this gate is about KVM and measured NOTHING"; exit 1; }
ring3_seed_init || exit 1

WORK="$ROOT/build/kvm-net-boot-smoke"; LOGS="${KVMNET_LOGS:-$ROOT/build/kvm-net-boot-smoke-logs}"
rm -rf "$WORK"; mkdir -p "$WORK/seed/bin" "$LOGS"
echo "Building the PLAIN kernel..."
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-plain"
# exit(0): mov edi,0 ; xor eax,eax ; syscall ; jmp $ — the lifecycle-smoke ELF shape with one PT_LOAD.
python3 - "$WORK/seed/bin/agnsh" <<'PYEOF' || { echo "  ERROR: seed ELF generation"; exit 1; }
import struct, sys
code = bytes.fromhex("bf0000000031c00f05ebfe")
e = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
e += struct.pack("<HHIQQQIHHHHHH", 2, 0x3E, 1, 0x400078, 64, 0, 0, 64, 56, 1, 0, 0, 0)
e += struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 0x78 + len(code), 0x78 + len(code), 0x200000)
e += code
open(sys.argv[1], "wb").write(e)
PYEOF
ring3_seed_image "$WORK/K.img" "$WORK/agnos-plain" "$WORK/seed" "AGNOS-KVMNET" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
# ts <fixed string> -> the kernel timestamp of its first line, in ms ("" when absent)
ts() { strings "$LOG" | grep -F -- "$1" | head -1 | grep -oE '\[ *[0-9]+\.[0-9]{6}\]' | sed 's/^\[ *\([0-9]*\)\.\([0-9]\{3\}\).*/\1\2/; s/^0*\([0-9]\)/\1/'; }

BUDGET_MS=$(( ${KVMNET_BUDGET:-20} * 1000 ))
PRE_MS="${KVMNET_PRE_MS:-500}"
export R3_ACCEL="-enable-kvm -cpu host"
for smp in ${KVMNET_SMP:-1 4}; do
    LOG="$LOGS/kvm-net-smp$smp.log"
    echo ""
    echo "Boot -smp $smp  accel=$R3_ACCEL  nic=virtio-net-pci"
    cp "$WORK/K.img" "$WORK/K-$smp.img"
    ring3_seed_boot "$WORK/K-$smp.img" "$LOG" "kybernet: exec" "${QEMU_TIMEOUT:-150}" "$WORK" -smp "$smp" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    if [ $? -eq 2 ]; then void=$((void + 1)); echo "  VOID (no kernel banner) — not scored"; continue; fi
    if strings "$LOG" | grep -qF "VirtIO-net: MAC="; then ok "[smp$smp] virtio-net driven (VirtIO-net: MAC=)"; else bad "[smp$smp] virtio-net was not driven — nothing measured"; fi
    t_exec=$(ts "kybernet: exec")
    if [ -z "$t_exec" ]; then bad "[smp$smp] kybernet: exec never reached"
    elif [ "$t_exec" -le "$BUDGET_MS" ]; then ok "[smp$smp] kybernet: exec at ${t_exec} ms <= ${BUDGET_MS} ms"
    else bad "[smp$smp] kybernet: exec at ${t_exec} ms > ${BUDGET_MS} ms (the console runs slow under KVM)"; fi
    t_a=$(ts "PMM: 2mb_top_region"); t_b=$(ts "kernel CR3: own PML4")
    if [ -z "$t_a" ] || [ -z "$t_b" ]; then bad "[smp$smp] pre-console window lines missing (PMM: 2mb_top_region / kernel CR3: own PML4)"
    elif [ $((t_b - t_a)) -le "$PRE_MS" ]; then ok "[smp$smp] pre-console window $((t_b - t_a)) ms <= $PRE_MS ms"
    else bad "[smp$smp] pre-console window $((t_b - t_a)) ms > $PRE_MS ms (a direct-map access before cr3_load(0x1000)?)"; fi
    for pat in "PANIC" "emergency shell" "$SMOKE_INVARIANT_DENY"; do
        if strings "$LOG" | grep -qE -- "$pat"; then bad "[smp$smp] denied line present"; strings "$LOG" | grep -E -- "$pat" | head -3 | sed 's/^/        /'
        else ok "[smp$smp] no denied line ($(echo "$pat" | cut -c1-40)...)"; fi
    done
done

sh "$ROOT/scripts/build.sh" > /dev/null 2>&1 || echo "  WARN: final plain rebuild failed"
echo ""
echo "=== kvm-net-boot-smoke: $pass passed, $fail failed, $void void ==="
if [ $fail -gt 0 ]; then echo "kvm-net-boot-smoke: FAIL"; exit 1; fi
if [ $void -gt 0 ]; then echo "kvm-net-boot-smoke: VOID"; exit 2; fi
echo "kvm-net-boot-smoke: PASS"
exit 0
