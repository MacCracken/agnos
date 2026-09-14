#!/bin/sh
# image-layout-check.sh — the kernel image vs the BSP boot stack: LOAD end <= 0x370000.
#
# ⛔⛔ WHY THIS EXISTS (2026-09-13, 1.57.2 -> 1.57.3). Every fixed kernel stack in PMM region 1 was placed
# by reading the image end off a build and choosing a number above it, and nothing re-checked those
# placements when the image grew. The 1.57.2 kernel-embedded face added ~410 KB of .rodata and moved the
# LOAD end from ~0x2FA2xx to 0x35E770 — straight across the AP1-3 boot/TSS stack window [0x310000,
# 0x340000), so CPUs 1-3 pushed every boot and CPL0 timer frame INTO kernel .rodata through the 2 MB RW
# identity pages (no fault, no signal, every -smp 1 gate green). This tree had already paid for the
# identical class twice on iron (gdt.cyr: RSP0 0x200000 inside live .bss -> triple fault; boot_shim.cyr:
# the 0x200000 boot stack overwrote "exfatu: upcase-checksum OK", found by gdb watchpoint) and both fixes
# were "pick a higher number" with a comment quoting an image end that has been stale ever since.
# History: docs/development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md.
#
# 1.57.3 RELOCATED the AP stacks into region 7 (phys [0xFD0000, 0x1000000) through the direct map —
# gdt.cyr tss_get_cpu_stack carries the map; smp.cyr's trampoline computes the same VA), a pmm-reserved
# region the image can never reach. ⭐ So the 1.57.2 tolerated-overlap branch this script carried (decode
# the rekha chunk literals, prove every byte under the AP window was a dead chunk byte, lock the literals'
# single reader chain) is GONE — it described a layout that no longer exists, and keeping a PASS path
# that reasons about dead bytes under a stack would invite the next arc to lean on it. The image's ONLY
# remaining region-1 neighbour is the BSP boot stack, so this gate is about exactly one number.
#
# WHAT IT ASSERTS, from `build/agnos` (the ELF64 the bootloader loads):
#   LOAD end (p_vaddr + p_memsz of the single PT_LOAD) <= 0x370000.
#   The BSP boot stack grows DOWN from 0x380000 (boot_shim.cyr step 12 / ELF64 step 1) and keeps the same
#   64 KB budget every per-CPU window gets, i.e. [0x370000, 0x380000). The BSP TSS.RSP0 window sits above
#   it, [0x3B0000, 0x3C0000) (gdt.cyr tss_kernel_stack) — reported, never reachable by the image while
#   the boot-stack bound holds. Above 0x370000 the boot path walks into the image on QEMU AND iron: hard
#   FAIL, no exception, do not raise the number: the BSP boot stack cannot leave region 1, so the image is
#   what has to give (or move). ⚠ WHY IT CANNOT (corrected at the 1.57.3 review — this header first said
#   "the boot shim's page tables map only 0-4 MB", which is the LEGACY multiboot1 shim's step 4; the
#   production ELF64 shim this gate measures builds no page tables and runs on UEFI's identity map, under
#   which region 7's identity VA does resolve): the boot stack is live from the shim's first instruction,
#   before any kernel page table exists — the direct map (the only VA gdt.cyr's ⛔ rule allows a region-7
#   stack) is built by pmm_setup_directmap and live only from cr3_load(0x1000), and region 7's identity
#   VA is forbidden by that rule (ark's per-proc PD[7] override; kmain is proc 0 and is switched out on
#   this stack under per-proc CR3s). Region 1 (PD[1]) is the window every CR3 from power-on onward maps.
#   ⚠ WHERE AN AP STACK ACTUALLY IS is not this gate's business and cannot be: a static grep of the
#   trampoline's hex would be brittle. The runtime guard is SMP_STACK_SELFTEST — scripts/smoke/
#   ap-stack-smoke.sh (-smp 4) samples each AP's live RSP against the region-7 window, reads each AP's
#   TSS.RSP0 back against the exact window top (the gdt.cyr half — dead until a ring-3 proc lands there,
#   so nothing else can see it regress), and re-hashes the chunk literals in place after the wake.
#   Together: the image stays under the BSP stack, and the APs stay out of the image.
#
# ⚠ VACUITY: the caller must hand this the binary THIS run built (check.sh gates it behind the arity
# build's rc exactly as the size gate is). A fossil build/agnos measures a different tree.
# Mutation-tested 2026-09-13 (1.57.3, on a scratch copy of the plain build): p_memsz bumped so the LOAD
# end lands at 0x370001 -> "FAIL: LOAD end 0x370001 exceeds 0x370000 ..."; the shipped tree PASSES with
# LOAD end 0x35E8B0 and 0x11750 (71,504) B of headroom (was 0x35E860 / 0x117A0 before the review strengthened the
# smp_start_aps guard).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGNOS="${1:-$ROOT/build/agnos}"

[ -f "$AGNOS" ] || { echo "FAIL: $AGNOS not found — no image to measure"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available — the ELF cannot be parsed"; exit 1; }

python3 - "$AGNOS" <<'EOF'
import struct, sys
agnos = sys.argv[1]
d = open(agnos, 'rb').read()
BSP_BOOT_TOP = 0x380000                 # boot_shim.cyr step 12 / ELF64 step 1 (grows down)
CEIL = BSP_BOOT_TOP - 0x10000           # 0x370000: the BSP boot stack keeps the per-CPU 64 KB budget
BSP_RSP0_TOP = 0x3C0000                 # gdt.cyr tss_kernel_stack; window [0x3B0000, 0x3C0000)
if d[:4] != b'\x7fELF' or d[4] != 2:
    print("FAIL: not an ELF64 image"); sys.exit(1)
phoff = struct.unpack_from('<Q', d, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', d, 54)
loads = []
for i in range(phnum):
    o = phoff + i * phentsize
    p_type = struct.unpack_from('<I', d, o)[0]
    if p_type == 1:
        p_offset, p_vaddr, _pa, p_filesz, p_memsz = struct.unpack_from('<QQQQQ', d, o + 8)
        loads.append((p_offset, p_vaddr, p_filesz, p_memsz))
if len(loads) != 1:
    print("FAIL: expected exactly one PT_LOAD, found %d — this gate's VA<->file mapping assumes cycc's flat image" % len(loads)); sys.exit(1)
p_offset, p_vaddr, p_filesz, p_memsz = loads[0]
if p_offset != 0 or p_vaddr != 0x100000:
    print("FAIL: PT_LOAD is offset 0x%x vaddr 0x%x — expected the flat 0 -> 0x100000 mapping (VA = 0x100000 + file offset)" % (p_offset, p_vaddr)); sys.exit(1)
end = p_vaddr + p_memsz
# section spans, for the report
shoff = struct.unpack_from('<Q', d, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 58)
secs = {}
if shnum:
    so = shoff + shstrndx * shentsize
    stroff, strsz = struct.unpack_from('<QQ', d, so + 24)
    strtab = d[stroff:stroff + strsz]
    for i in range(shnum):
        o = shoff + i * shentsize
        name_off = struct.unpack_from('<I', d, o)[0]
        addr, off, size = struct.unpack_from('<QQQ', d, o + 16)
        name = strtab[name_off:strtab.find(b'\0', name_off)].decode()
        secs[name] = (addr, size)
print("  LOAD 0x%x..0x%x (filesz 0x%x memsz 0x%x)" % (p_vaddr, end, p_filesz, p_memsz))
for n in ('.text', '.bss', '.rodata'):
    if n in secs:
        a, s = secs[n]; print("  %-8s 0x%x..0x%x" % (n, a, a + s))
print("  region-1 stacks: BSP boot top 0x%x (ceiling 0x%x = top - 64 KB)  BSP TSS.RSP0 window [0x%x, 0x%x)  AP1-3: region 7 (ap-stack-smoke.sh)" % (BSP_BOOT_TOP, CEIL, BSP_RSP0_TOP - 0x10000, BSP_RSP0_TOP))
if end > CEIL:
    print("FAIL: LOAD end 0x%x exceeds 0x%x — the BSP boot stack (top 0x%x) would have under 64 KB before it walks into the image. Shrink or move the image; do not raise the ceiling (the BSP boot stack is live from the shim's first instruction, before the direct map exists, so it cannot leave region 1 — see the header)." % (end, CEIL, BSP_BOOT_TOP))
    sys.exit(1)
print("  PASS: LOAD end 0x%x <= 0x%x — headroom to the BSP boot stack's 64 KB budget 0x%x = %d B (BSP TSS.RSP0 window bottom 0x%x is %d B further up)" % (end, CEIL, CEIL - end, CEIL - end, BSP_RSP0_TOP - 0x10000, (BSP_RSP0_TOP - 0x10000) - CEIL))
sys.exit(0)
EOF
