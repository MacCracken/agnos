#!/bin/bash
# bote-mcp-smoke — does /bin/bote (the MCP core, cross-built --agnos) actually
# SERVE the JSON-RPC MCP protocol on the REAL agnos kernel under QEMU — not just
# LOAD (basestack-run-smoke) and not merely under mirshi's host-kernel syscall
# emulation? The BOTE_SELFTEST kernel hook (kernel/core/main.cyr) stands up two
# kernel pipes, PRELOADS an MCP `initialize` + `tools/call bote_echo` request into
# bote's stdin, points the child's fd0/fd1 at the pipes, runs it to EOF, and paints
# bote's JSON responses to serial. This exercises the freelist `mmap#27` fix on the
# ACTUAL agnos mmap (bote's libro chain_new -> sha256 -> fl_alloc was the crash on
# the stale 6.3.15 pin). PASS = serial shows bote's `serverInfo` (initialize reply)
# AND the echoed `agnos-kernel` argument (tools/call reply) AND no fault/panic.
#
# Build bote:  cyrius build --agnos src/main.cyr build/bote-agnos   (in ../bote)
# KVM strongly recommended (a ~16 MB load under TCG is slow): ARK_NO_KVM=1 forces TCG.
# Requires: qemu, OVMF, parted, mtools, sgdisk, mkfs.ext2, dd, strings.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
BOTE_REPO="${BOTE_REPO:-$ROOT/../bote}"
BOTE_BIN="${BOTE_BIN:-$BOTE_REPO/build/bote-agnos}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$BOTE_BIN" ] || { echo "ERROR: bote agnos build not at $BOTE_BIN — run 'cyrius build --agnos src/main.cyr build/bote-agnos' in bote"; exit 1; }
case "$(file -b "$BOTE_BIN" 2>/dev/null)" in
    *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
    *) echo "ERROR: $BOTE_BIN is not a static x86-64 ELF"; exit 1 ;;
esac

# Build the BOTE_SELFTEST kernel (unless BOTE_NO_BUILD=1 and build/agnos is present).
if [ -z "${BOTE_NO_BUILD:-}" ]; then
    echo "Building BOTE_SELFTEST kernel..."
    BOTE_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "ERROR: kernel build failed"; exit 1; }
fi
[ -f "$AGNOS" ] || { echo "ERROR: agnos kernel not built — run BOTE_SELFTEST=1 ./scripts/build.sh"; exit 1; }

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${ARK_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — falling back to TCG; the ~16 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/bote-mcp-smoke"
LOGS="$ROOT/build/bote-mcp-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

IMG="$WORK/agnos-bote.img"
PART_OFFSET=$(( 33 * 1048576 ))
PART_BYTES=$(( 95 * 1048576 ))
PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp "$BOTE_BIN" "$SEED/bin/bote"; chmod +x "$SEED/bin/bote"
printf 'archaemenid\n' > "$SEED/etc/hostname"
BOTE_SZ=$(stat -c%s "$SEED/bin/bote")
echo "Staging bote ($BOTE_SZ bytes) + building image..."

dd if=/dev/zero of="$IMG" bs=1M count=160 status=none
parted -s "$IMG" mklabel gpt \
    mkpart ESP fat32 1MiB 33MiB set 1 esp on \
    mkpart agnos-fs ext2 33MiB 128MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-BOTE -b 4096 -m 0 \
    -O "$EXT2_SMOKE_FEATURES" \
    -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "Booting BOTE_SELFTEST kernel ($KVM_ARGS)..."
cp "$OVMF_VARS_SRC" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
LOG="$LOGS/bote-selftest.log"
timeout "${QEMU_TIMEOUT:-120}" qemu-system-x86_64 \
    -machine q35 -m 1G $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" \
    -device "nvme,drive=disk0,serial=AGNOS-BOTE" \
    -serial stdio -display none -no-reboot 2>/dev/null > "$LOG"

echo ""
echo "  --- bote / mcp lines from boot log ---"
strings "$LOG" | grep -E "^bote:|serverInfo|jsonrpc|agnos-kernel|^run: exit|#PF|PANIC|^fault:" | sed 's/^/  /'
echo ""

rc=0
# Gate 1: bote SERVED — initialize reply carries serverInfo (bote's MCP handshake
# response), proving the crypto/dispatch path ran on the real kernel.
if strings "$LOG" | grep -qE 'serverInfo'; then
    echo "  PASS: bote served MCP — 'serverInfo' initialize reply reached the console"
else
    echo "  FAIL: no 'serverInfo' — bote did not serve the MCP handshake on the real kernel"; rc=1
fi
# Gate 2: tools/call actually EXECUTED — bote_echo echoes back our argument.
if strings "$LOG" | grep -qE 'agnos-kernel'; then
    echo "  PASS: tools/call executed — bote_echo echoed the 'agnos-kernel' argument"
else
    echo "  FAIL: no echoed 'agnos-kernel' — tools/call did not execute"; rc=1
fi
# Gate 3: the box survived (no fault/panic during load, crypto, or serve).
if strings "$LOG" | grep -qE "#PF|PANIC|^fault:"; then
    echo "  FAIL: a fault/panic marker appeared:"
    strings "$LOG" | grep -E "#PF|PANIC|^fault:|CR2|RIP" | sed 's/^/        /' | head; rc=1
else
    echo "  PASS: no fault/panic — the box survived loading + serving bote"
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "bote-mcp-smoke: PASS — bote serves MCP (initialize + tools/call) on the real agnos kernel"
else
    echo "bote-mcp-smoke: FAIL (full serial: $LOG)"
fi
exit $rc
