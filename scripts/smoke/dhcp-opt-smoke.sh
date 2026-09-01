#!/bin/sh
# dhcp-opt-smoke — a DHCP option shorter than its reader must be refused, not handed over.
#
# ⛔ THE ATTACK, AND WHY IT NEEDED A HERMETIC GATE. Until 1.56.52 `dhcp_find_option` validated only
# that an option's DECLARED length FITS the blob, never that it is large enough for whoever reads it.
# All five call sites then read a fixed width: 1 byte for option 53, 4 bytes for 54/1/3/6 via
# `dhcp_load_u32_be`, which is four unguarded load8s. A server — or anyone who can spoof one on-link
# during the boot exchange, the xid/chaddr match being the only barrier — sends a 1024-byte reply
# whose LAST option declares len 0. The option sits at i = opts_len-2, the old bound passes exactly,
# the returned offset IS opts_len, and the 4-byte read starts at &rx + n: past the end of
# `var rx[1024]`, which is FUNCTION-LOCAL and therefore 1024 BYTES. Those bytes become net_gateway /
# net_dns_server and are PRINTED to the console and the klug ring. Remote ring-0 stack disclosure,
# filed as a P2.
#
# The real trigger needs a hostile DHCP server on the boot exchange, which no smoke can arrange — and
# that is exactly why it sat unfixed. But `dhcp_find_option` is a PURE function over a caller-supplied
# buffer, so the whole attack is reproducible as an in-memory blob with no network at all.
#
# Five arms. #3 is the attack (last option, len 0). #4 is the in-bounds SILENT mis-parse a gate
# testing only #3 would miss. #1, #2 and the minimum-vs-equality check are the honesty arms: without
# them "always return -1" scores a pass and DHCP simply stops working.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
# ⛔ 1.56.55 — A MISSING PREREQUISITE EXITS 1, NOT 0. These guards used to `exit 0`, and sweep.sh
# scores a gate on exit status alone, so "this gate measured NOTHING" was rendered as a green tick.
# Thirteen such guards across six smokes, five of them in the sweep table. Same doctrine as
# syscall-abi-check.sh: a check that quietly passes when it could not find one of its inputs is a
# false green. An absent prerequisite is not a pass and must not read as one.
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "ERROR: OVMF not found — this gate measured NOTHING"; exit 1; }
LOGS="$ROOT/build/dhcp-opt-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
LOG="$LOGS/dhcpopt.log"

echo "=== DHCP option-length smoke ==="
DHCP_OPT_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }

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
        -drive "file=$IMG,format=raw,if=none,id=d0" -device "nvme,drive=d0,serial=AGNOS-DHCPO" \
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
if grep -q 'dhcpopt: option lengths are checked against the reader' "$LOG"; then
    echo "  PASS: zero-length and short options refused for a 4-byte reader; well-formed options still"
    echo "        found; need is a MINIMUM not an equality; over-long declared length still refused"
else
    echo "  FAIL: DHCP option-length gate did not report OK — named arms above:"
    grep 'dhcpopt:' "$LOG" || echo "        (no dhcpopt: line at all — the selftest never ran)"
    rc=1
fi
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1   # leave a plain production build behind
[ "$rc" = "0" ] && echo "dhcp-opt-smoke: PASS" || echo "dhcp-opt-smoke: FAIL"
exit $rc
