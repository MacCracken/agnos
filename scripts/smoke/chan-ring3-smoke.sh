#!/bin/sh
# chan-ring3-smoke.sh — the RING-3 half of the channel band (`#97 chan_op`), and the only place
# §9.9's two kill criteria can actually be tested.
#
# ⛔ THE BOOT SELFTEST CANNOT CLOSE EITHER OF THEM, which is why this exists as a separate gate:
#
#   1. Region reachability is claimed "from a SPAWNED CLIENT'S CR3". The boot selftest runs under the
#      kernel's own CR3, so a green there says nothing about a per-proc page table. `CH_CAPS` re-probes
#      the region live on every call, so calling it from a ring-3 proc IS the test.
#   2. ⭐ THE PRIMARY CRITERION — an INHERITED channel fd must be inert in a spawned child. The boot
#      selftest can only fake that by corrupting the owner field, which tests the CHECK, not the
#      INHERITANCE. agnos copies the whole fd table at spawn (no CLOEXEC), so only a real
#      `spawn_path #43` child holds the handle the criterion is about.
#
# ⛔ AND THE CHILD MUST *TRY*. A test where the child never receives a usable fd number proves nothing.
# The parent passes the fd it minted, by number, on the child's argv.
#
# ⛔ THE INVERSE ASSERTION IS LOAD-BEARING TOO: the child mints and uses its OWN channel successfully.
# Without that, a kernel that simply refused every `chan_op` from any non-first process would pass the
# inertness test while being badly wrong — "refused" and "refused for the right reason" are different
# claims, and only the pair distinguishes them.
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHANX_DIR="$ROOT/tests/chan"
WORK="$ROOT/build/chan-ring3"; LOGS="$ROOT/build/chan-ring3-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
AGNOS="$ROOT/build/agnos"
IMG="$WORK/agnos-chan.img"
PART_OFFSET=$((33 * 1024 * 1024))
PART_BLOCKS=$(( (100 - 33) * 1024 * 1024 / 4096 ))

echo "=== chan ring-3 smoke (#97 kill criteria: region-from-ring3 + inherited-fd inertness) ==="

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "  SKIP: $tool not found"; exit 0; }
done
[ -f "$GNOBOOT" ] || { echo "  SKIP: gnoboot not built at $GNOBOOT"; exit 0; }
[ -f "$AGNOS" ]   || { echo "  SKIP: build/agnos missing — run scripts/build.sh"; exit 0; }

echo "Building chanx exerciser (cyrius build --agnos)..."
( cd "$CHANX_DIR" && cyrius build --agnos chanx.cyr build/chanx ) >/dev/null 2>&1 \
    || { echo "  FAIL: chanx (agnos) build failed"; exit 1; }

SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$CHANX_DIR/build/chanx" "$SEED/bin/chanx"; chmod +x "$SEED/bin/chanx"

echo "Building image..."
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 100MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-CHAN -b 4096 -m 0 \
    -O "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting (CHAN_RING3_SELFTEST runs /bin/chanx)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/chan-ring3.log"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
# ⛔ MARKER IS `CHANX-DONE`, A LINE THAT CAN ONLY BE LAST — not a verdict and not the shell prompt.
# An earlier cut matched `CHANX-INH-`, which fired on the FIRST inherited-fd verdict and killed QEMU
# before the second assertion ran; the truncated log then read as a failing test rather than a cut-off
# one. This is the exact hazard qemu-dwell.sh's header warns about, met in practice.
qemu_dwell_kernel "$LOG" "CHANX-DONE" "${QEMU_TIMEOUT:-60}" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 \
    -machine q35 -m 512M -cpu max \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-CHAN" \
    -serial stdio -display none -no-reboot

echo ""
echo "  --- CHANX lines ---"
strings "$LOG" | grep -E "^CHANX-" | sed 's/^/  /' || echo "  (none)"
echo ""

rc=0
want() {
    if strings "$LOG" 2>/dev/null | grep -q "$1"; then echo "  PASS: $2"; else echo "  FAIL: $2"; rc=1; fi
}
# ⛔ A `deny` IS VACUOUS UNLESS THE CHILD ACTUALLY RAN. Absence of "record accepted" is satisfied just
# as well by an arm that never ran — which is exactly what happened on the first run of this
# smoke (a `sched_yield` spin that §9.4 documents as a no-op under a foreground `run`), and both denies
# reported PASS on silence. On the PRIMARY kill criterion that is the worst possible failure mode, so
# every deny now requires positive evidence the child executed.
deny() {
    if ! strings "$LOG" 2>/dev/null | grep -q "CHANX-INH-"; then
        echo "  FAIL: $2 — VACUOUS: the inherit arm produced no output at all, so this proves nothing"
        rc=1
        return 0
    fi
    if strings "$LOG" 2>/dev/null | grep -q "$1"; then echo "  FAIL: $2"; rc=1; else echo "  PASS: $2"; fi
}

want "CHANX-REGION-REACHABLE-FROM-RING3" "kill criterion 1: the 2 MB region resolves from a RING-3 proc's CR3"
want "CHANX-ROUNDTRIP-OK"                "a ring-3 proc mints a channel and round-trips a record"
want "CHANX-INH-SEND-REFUSED"            "kill criterion 2: an INHERITED fd refuses SEND (owner is another, live proc)"
want "CHANX-INH-RECV-REFUSED"            "kill criterion 2: an INHERITED fd refuses RECV (owner is another, live proc)"
deny "CHANX-INH-SEND-ACCEPTED-INHERITED-FD" "no record ACCEPTED from an inherited fd (inert-by-construction holds)"
deny "CHANX-INH-RECV-ACCEPTED-INHERITED-FD" "no record DELIVERED to an inherited fd (inert-by-construction holds)"
want "CHANX-INH-OWN-CHANNEL-OK"          "the same proc's OWN channel works — inertness is the CLAIM's property, not a blanket refusal"
want "CHANX-INH-ENDOWED-FD-WORKS"        "bite 5: an ENDOWED fd WORKS in the same proc whose INHERITED fd is inert"
want "CHANX-INH-PASS"                    "inherited-fd verdict"

echo ""
if [ "$rc" -eq 0 ]; then echo "chan-ring3-smoke: PASS"; else echo "chan-ring3-smoke: FAIL"; fi
echo "Log: $LOG"
exit $rc
