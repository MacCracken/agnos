#!/bin/bash
# Two-proc FP-preservation stress smoke for the AGNOS kernel (1.53.x FP/SIMD arc, B5).
#
# Boots the FP_CTXSW_SELFTEST kernel and asserts two co-scheduled ring-3 f64 procs each
# preserve their own distinct XMM pattern across the OTHER proc's FP use — the correctness
# proof for B3's lazy #NM save/restore. Each proc: write pattern to xmm3+xmm15 → set its
# handshake flag → yield#44 → spin until the peer's flag shows the peer wrote ITS pattern
# → re-read + compare. SURVIVED (own pattern) proves B3 saved+restored; a mismatch (peer's
# pattern) is CORRUPT. The handshake guarantees the peer overwrote the physical XMM
# between this proc's write and re-read (no no-switch false-green).
#
#   Single-core (modes a timer + b cooperative-yield) — HARD gate:
#     "fp: ctxsw A OK" + "fp: ctxsw B OK", no CORRUPT/STUCK, no #PF/#GP/#UD/#NM-loop/PANIC.
#   -smp 4 (mode c migration) — SOFT gate: reports "fp: ctxsw migrations=N" (>0 = a real
#     cross-core f64 migration witnessed; the dispositive B3 SMP gate rides the iron burn).
#
# Build first: FP_CTXSW_SELFTEST=1 ./scripts/build.sh
# Requires: qemu-system-x86_64, OVMF, mtools, parted, gnoboot built.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }
for tool in qemu-system-x86_64 mformat mmd mcopy parted; do command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not on PATH" >&2; exit 1; }; done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"; AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT" >&2; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built at $AGNOS" >&2; exit 1; }
if ! strings "$AGNOS" | grep -q "fp: ctxsw done"; then
    echo "ERROR: kernel not built with FP_CTXSW_SELFTEST=1 — rebuild: FP_CTXSW_SELFTEST=1 sh scripts/build.sh" >&2
    exit 1
fi

WORK="$ROOT/build/fp-ctxsw-smoke"; LOGS="$ROOT/build/fp-ctxsw-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
ESP="$WORK/esp.img"
dd if=/dev/zero of="$ESP" bs=1M count=64 status=none
parted -s "$ESP" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
mformat -i "$ESP"@@1048576 -F
mmd -i "$ESP"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$ESP"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP"@@1048576 "$AGNOS" ::boot/agnos

# Each round BURNs ~16M iters to span a 10ms timer tick and force a real inter-proc switch.
# That's ~16ms/round under KVM but MUCH slower under TCG — so prefer KVM (realistic timing +
# fast) and fall back to TCG with a longer timeout when /dev/kvm is absent (e.g. CI).
if [ -w /dev/kvm ]; then ACCEL="-enable-kvm -cpu host"; DEF_TIMEOUT=50; else ACCEL="-cpu max"; DEF_TIMEOUT=180; fi
boot_once() {   # $1 = extra qemu args (e.g. "-smp 4"), $2 = log path
    cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
    timeout "${QEMU_TIMEOUT:-$DEF_TIMEOUT}" qemu-system-x86_64 \
        -machine q35 -m 256M $ACCEL $1 \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
        -drive "file=$ESP,format=raw,if=none,id=esp0" \
        -device "virtio-blk-pci,drive=esp0" \
        -serial stdio -display none -no-reboot 2>/dev/null > "$2"
}

pass=0; fail=0
chk()  { if grep -q "$1" "$3"; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: '$1' — $4"; fail=$((fail+1)); fi; }
nchk() { if grep -q "$1" "$3"; then echo "FAIL: '$1' present — $4"; fail=$((fail+1)); else echo "PASS: $2"; pass=$((pass+1)); fi; }

echo "=== [1/2] single-core (modes a timer + b cooperative-yield) — HARD gate ==="
SC="$LOGS/single.log"; boot_once "-smp 1" "$SC"
strings "$SC" | grep -E "fp: ctxsw" | sed 's/^/  /' | head
chk  "fp: ctxsw A OK" "proc A's xmm3+xmm15 survived B's FP use across real inter-proc switches" "$SC" "A saw corruption or never interleaved (CORRUPT/STUCK)"
chk  "fp: ctxsw B OK" "proc B's xmm3+xmm15 survived A's FP use"                                  "$SC" "B saw corruption or never interleaved"
nchk "fp: ctxsw A CORRUPT" "A never read the peer's leaked pattern" "$SC" "B3 save/restore corrupted A's XMM"
nchk "fp: ctxsw B CORRUPT" "B never read the peer's leaked pattern" "$SC" "B3 save/restore corrupted B's XMM"
nchk "fp: ctxsw A STUCK" "A actually interleaved (>=5 survived rounds)" "$SC" "A never co-scheduled with B (false-green risk)"
strings "$SC" | grep -qE "#PF|#GP|#UD|PANIC|Double Fault" \
    && { echo "  FAIL: a fault/panic appeared (the FXSAVE-of-previous-owner limb faulted)"; fail=$((fail+1)); } \
    || { echo "  PASS: no #PF/#GP/#UD/PANIC — the two-proc FP limb is fault-free"; pass=$((pass+1)); }

echo ""
echo "=== [2/2] -smp 4 (mode c migration) — SOFT gate (report, don't fail) ==="
MP="$LOGS/smp.log"; boot_once "-smp 4" "$MP"
strings "$MP" | grep -E "fp: ctxsw|smp: cpus online" | sed 's/^/  /' | head
chk "fp: ctxsw A OK" "A survived under -smp (APs scheduling real f64 procs)" "$MP" "A corrupt/stuck under -smp"
chk "fp: ctxsw B OK" "B survived under -smp"                                  "$MP" "B corrupt/stuck under -smp"
MIG="$(strings "$MP" | grep -oE 'fp: ctxsw migrations=[0-9]+' | grep -oE '[0-9]+$' | head -1)"
if [ "${MIG:-0}" -gt 0 ]; then echo "  REPORT: ${MIG} cross-core FP migration(s) witnessed under -smp (soft — real proof is the iron burn)";
else echo "  REPORT: 0 migrations witnessed under QEMU -smp (expected — TCG affinity is sticky; the dispositive migration proof is the archaemenid -smp iron burn)"; fi

echo ""
[ "$fail" -eq 0 ] && { echo "=== fp-ctxsw-smoke: $pass passed, 0 failed — two f64 procs preserve XMM across real switches ==="; exit 0; }
echo "=== fp-ctxsw-smoke: $pass passed, $fail failed ==="; exit 1
