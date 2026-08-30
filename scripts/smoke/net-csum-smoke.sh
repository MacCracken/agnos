#!/bin/sh
# net-csum-smoke — receive-side checksum verification, BOTH directions.
#
# ⛔ WHY A DEDICATED SMOKE. The existing network gates (loopback / dns / ntp / icmp / tcp) all prove
# that GOOD frames still pass, which is necessary and not sufficient: nothing anywhere in the tree
# ever presents a CORRUPT frame, so a check that was inverted, or absent, or that dropped everything
# would still let every one of them pass. Before 1.56.52 agnos verified NO checksum on ingress at any
# layer — a corrupted TCP segment whose seq happened to match RCV.NXT was appended to the receive
# ring and ACKed to the peer as delivered.
#
# NET_CSUM_SELFTEST drives net_demux_frame directly with a synthetic IPv4/UDP frame and asserts three
# things: a well-formed frame is ACCEPTED, a one-bit-corrupted IPv4 header checksum is DROPPED and
# COUNTED, and a non-zero-but-wrong UDP checksum is DROPPED and COUNTED. The first arm is what keeps
# the other two honest — without it, "drop everything" would score a pass.
#
# ⚠ The UDP arm matters specifically because the agnos TX path hardcodes checksum 0 ("not computed",
# RFC 768), so the non-zero verification branch is never exercised by agnos's own traffic.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
[ -f "$GNOBOOT" ] || { echo "SKIP: gnoboot not built"; exit 0; }
[ -f "$OVMF_CODE" ] || { echo "SKIP: OVMF not found"; exit 0; }
LOGS="$ROOT/build/net-csum-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
LOG="$LOGS/csum.log"

echo "=== receive-checksum verification smoke ==="
NET_CSUM_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }

# ⚠ Retry ONLY on an absent kernel banner — OVMF intermittently never hands off, and such a run
# measures NOTHING. Retrying a real assertion failure would retry a regression away.
a=1
while [ "$a" -le 3 ]; do
    W=$(mktemp -d); IMG="$W/d.img"
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1
    mformat -i "$IMG"@@1048576 -F
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$IMG"@@1048576 "$ROOT/build/agnos" ::boot/agnos
    cp "$OVMF_VARS" "$W/vars.fd"; chmod +w "$W/vars.fd"
    timeout "${QEMU_TIMEOUT:-45}" qemu-system-x86_64 -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" -device "nvme,drive=d0,serial=AGNOS-CSUM" \
        -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' > "$LOG"
    rm -rf "$W"
    grep -q 'AGNOS kernel v' "$LOG" && break
    echo "  (firmware never handed off — retry $a/3)"
    a=$((a+1))
done
if ! grep -q 'AGNOS kernel v' "$LOG"; then
    echo "  UEFI never handed off in 3 attempts — INFRASTRUCTURE, not the kernel. VOID, not a failure."
    exit 1
fi

rc=0
if grep -q 'csum: RX verification OK' "$LOG"; then
    echo "  PASS: good frame accepted; corrupt IPv4 header and bad UDP checksum both dropped + counted;"
    echo "        MF and non-zero-offset fragments rejected + counted; a DF packet still accepted"
else
    echo "  FAIL: receive-checksum verification did not report OK — named arms above:"
    # ⚠ BOTH PREFIXES. The selftest reports checksum arms as `csum:` and fragment arms as `frag:`;
    # grepping only the first showed a bare "RX verification FAIL" with no indication of which arm,
    # which is the same defect this cut fixed in sweep.sh's own run_gate filter.
    grep -E 'csum:|frag:' "$LOG" || echo "        (no csum:/frag: line at all — the selftest never ran)"
    rc=1
fi
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1   # leave a plain production build behind
[ "$rc" = "0" ] && echo "net-csum-smoke: PASS" || echo "net-csum-smoke: FAIL"
exit $rc
