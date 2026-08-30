#!/bin/sh
# userwin-smoke — does "user pointer" mean the CALLER'S memory, or merely a low address?
#
# ⛔ THE MEASUREMENT THAT MADE THIS NECESSARY (1.56.52). is_user_ptr / is_user_range were pure VA
# bounds checks — "inside [2 MB, 1 GB)" — and their comment reasoned only about what lies ABOVE the
# ceiling. Under every per-process CR3 what lies INSIDE it is the kernel: proc_create_address_space
# copies kernel PD[0..127] (0-256 MB, identity, U/S=0) into each address space. Measured on a fresh
# one: va=0x300000 (kernel image), 0xe00000 (proc_rsp0 pool), 0xf10000 (CPU0 SYSCALL kernel stack)
# and 0x8000000 all returned is_user_range=1 with present=1 user=0. A syscall runs at CPL0 with AC=1
# from the entry STAC, so SMAP is inert and any arm doing a raw load8/store8 on a validated pointer
# read or wrote kernel memory for ring 3 — write(1,(void*)0x300000,4096) discloses the kernel image;
# read(fd,(void*)0xF08000,0x8000) writes file bytes over the syscall kernel stack.
#
# The check is now a page-table walk requiring PRESENT + U/S=1 on every 2 MB page under the live CR3.
# ⭐ AND THAT IS WHAT LETS THE HIGH mmap ARENA IN: sys_mmap spills big allocations to [128 GB, 512 GB)
# and the old 1 GB ceiling rejected every pointer into it, so a process could obtain high memory and
# never pass it to a syscall. Widening the window alone would have been catastrophic — the direct map
# owns PDPT[8..511] — so the floor is DERIVED from what pmm_setup_directmap installed, and the walk
# refuses supervisor pages regardless.
#
# The gate runs under a REAL per-process CR3 (under the boot CR3 is_user_range takes its documented
# exemption and every arm would score a meaningless pass) and checks BOTH directions: kernel memory
# inside the low window is rejected, and pages the address space genuinely owns — low arena and high
# arena both — are accepted. Without those accept arms, "reject everything" would pass.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
[ -f "$GNOBOOT" ] || { echo "SKIP: gnoboot not built"; exit 0; }
[ -f "$OVMF_CODE" ] || { echo "SKIP: OVMF not found"; exit 0; }
LOGS="$ROOT/build/userwin-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
LOG="$LOGS/userwin.log"

echo "=== user-pointer window smoke ==="
USERWIN_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; exit 1; }

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
        -drive "file=$IMG,format=raw,if=none,id=d0" -device "nvme,drive=d0,serial=AGNOS-UWIN" \
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
if grep -q 'userwin: user pointers mean OWNED pages' "$LOG"; then
    echo "  PASS: kernel image / rsp0 pool / SYSCALL kstack / identity window all rejected; owned low"
    echo "        and high arena pages both accepted; wrap, over-run and direct-map VAs rejected"
else
    echo "  FAIL: user-window gate did not report OK — named arms above:"
    grep 'userwin:' "$LOG" || echo "        (no userwin: line at all — the selftest never ran)"
    rc=1
fi
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1   # leave a plain production build behind
[ "$rc" = "0" ] && echo "userwin-smoke: PASS" || echo "userwin-smoke: FAIL"
exit $rc
