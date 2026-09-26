#!/bin/sh
# image-layout-check.sh — the kernel image vs the BSP boot stack: LOAD end <= 0x390000 (0x370000 until 1.57.7).
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
# ⭐⭐ 1.57.7 (IMG step) — THE BSP BOOT STACK MOVED UP, 0x380000 -> 0x3A0000, AND THE BOUND WITH IT,
# 0x370000 -> 0x390000. Measured, not guessed: the 1.57.7 plan's ten steps estimated ~+59.2 KB of image
# against 59,240 B of headroom (4 B of margin; two steps' STOP rules tripped on paper), and the P0 flag
# table (handoff baseline/flag-load-ends.txt) found THREE flag builds the smokes boot ALREADY past
# 0x370000 on the 1.57.6 tree — RING3_SELFTEST=1 (sweep's ring3-smoke row) 0x375850, EDGE_ABI_SELFTEST=1
# (sweep's edge-abi-smoke row) 0x371260, EXEC+EXT2_WRITE+RING3 (exec-smoke's ring-3 variant) 0x37B288 —
# because this gate only ever measured the PLAIN image. This is NOT "raising the ceiling": the ceiling is
# re-derived from a MOVED stack, which stays in region 1 (the reasons below still hold). The new region-1
# map above the image:
#     [0x390000, 0x3A0000)  BSP boot stack — 64 KB budget, grows down from 0x3A0000
#     [0x3A0000, 0x3B0000)  UNUSED 64 KB guard gap (nothing in the tree references it — verified by grep
#                           of every spelling at 1.57.7: 0x38xxxx/0x39xxxx/0x3Axxxx, decimal, shifted,
#                           the asm byte forms; handoff logs/IMG-fix/preverify.log)
#     [0x3B0000, 0x3C0000)  BSP TSS.RSP0 window (gdt.cyr tss_kernel_stack)
# ⛔ WHAT KEEPS THE WINDOW FREE IS THE FIRMWARE, NOT gnoboot OR pmm (corrected by the IMG-fix pass — IMG wrote
# "gnoboot allocates only the image's own pages", which is false). pmm_init's 0-4 MB reservation is the kernel's
# own bookkeeping, made long after the shim's first push. gnoboot pins only the kernel image (ET_EXEC
# AllocateAddress); it ALSO allocates the /initramfs and /cmdline blobs with AllocateAnyPages (EfiLoaderData),
# and boot_info + the memory-map buffer are globals inside gnoboot's own image (EfiLoaderCode), wherever the
# firmware loaded BOOTX64.EFI. Nothing reserves [0x390000, 0x3A0000) before the first push — exactly as nothing
# reserved the old [0x370000, 0x380000). On OVMF the whole span is free RAM (a gdbstub paint of phys
# [0x370000, 0x3C0000) before OVMF's first instruction survives the firmware untouched outside the stack's own
# writes). On IRON it is now OBSERVABLE: kmain checks the UEFI map it was handed (mbi.cyr
# bootstack_window_check) and prints either "boot: BSP stack span 0x390000-0x3C0000 is free RAM in the UEFI map
# OK" or the denied "boot: BSP stack window not free RAM in the UEFI map - type 0x.. at 0x.." (SMOKE_INVARIANT_DENY;
# agnsh-smoke requires the OK line). Built, gated, NOT burned.
# ⚠ A LOAD end below the bound is necessary, not sufficient: the boot stack's DEPTH is not measured by any
# build (no flag paints it; KSTACK_HW paints only the region-7 per-process stacks). Measured from outside at
# 1.57.7, IMG-fix (handoff logs/IMG-fix/m4-paint-probe.py): phys [0x370000, 0x3C0000) PAINTED with a 64-bit
# pattern over the gdbstub while QEMU is held at reset, then booted and pmemsave'd — the lowest qword that is no
# longer paint is a TRUE high-water mark (IMG's first number read the lowest NON-ZERO byte of a zero-filled
# window, a lower bound: at -smp 4 the deepest qword written was a zero, 16 B below what that method sees).
# To the agnsh prompt: 2,088 B and 2,312 B (-smp 1, two boots), 2,328 B (-smp 4, KVM); through doom-smoke's
# pre-scheduler IF=0 run 5,288 B — one boot each, well inside the 64 KB budget every other kernel stack gets.
# The control windows (image headroom, guard gap, RSP0 window) stayed paint in every run.
#
# WHAT IT ASSERTS:
#   (1) from `build/agnos` (the ELF64 the bootloader loads): LOAD end (p_vaddr + p_memsz of the single
#       PT_LOAD) <= BSP_BOOT_TOP - 64 KB = 0x390000. memsz is filesz + a 64 KB zero-fill, and it counts.
#       Above the bound the boot path walks into the image on QEMU AND iron: hard FAIL, no exception, do
#       not raise the number without MOVING the stack (and this gate's BSP_BOOT_TOP with it): the BSP boot
#       stack cannot leave region 1. ⚠ WHY IT CANNOT (corrected at the 1.57.3 review — this header first
#       said "the boot shim's page tables map only 0-4 MB", which is the LEGACY multiboot1 shim's step 4;
#       the production ELF64 shim this gate measures builds no page tables and runs on UEFI's identity
#       map, under which region 7's identity VA does resolve): the boot stack is live from the shim's
#       first instruction, before any kernel page table exists — the direct map (the only VA gdt.cyr's
#       ⛔ rule allows a region-7 stack) is built by pmm_setup_directmap and live only from
#       cr3_load(0x1000), and region 7's identity VA is forbidden by that rule (ark's per-proc PD[7]
#       override; kmain is proc 0 and is switched out on this stack under per-proc CR3s). Region 1
#       (PD[1]) is the window every CR3 from power-on onward maps.
#   (2) (1.57.7) the three boot-stack immediates in kernel/arch/x86_64/boot_shim.cyr — the legacy
#       `mov esp` (step 1), the legacy `mov rsp` (step 12) and the ELF64 `mov rsp` (step 1) — decoded from
#       their BYTES (not their comments) all equal BSP_BOOT_TOP, and each line's `# mov ..., 0x...`
#       comment agrees with its bytes. The two legacy ones are not in the ELF64 image, so this source
#       check is the only thing that can see them drift from the bound this gate enforces.
#   (3) (1.57.7) the image's .text carries `mov rsp, imm64` (48 BC) = BSP_BOOT_TOP, and no `mov rsp` to
#       any OTHER 64 KB-aligned region-1 address (a stale or mismatched top built into the image).
#   (4) (1.57.7 IMG-fix, review A4) the region-1 map this gate PRINTS is checked against the tree, not just
#       against itself: every BSP TSS.RSP0 site (gdt.cyr `var tss_kernel_stack`, tss_get_cpu_stack(0),
#       proc.cyr proc_rsp0_top's unassigned-slot fallback) equals BSP_RSP0_TOP — so the RSP0 window stays above
#       the guard gap and a CPL3->CPL0 entry through the fallback can never land on kmain's switched-out
#       boot-stack frames — and the kernel's own runtime span check (mbi.cyr bsw_lo/bsw_hi and main.cyr's OK
#       line) names [CEIL, BSP_RSP0_TOP).
#   The BSP TSS.RSP0 window is reported, never reachable by the image while the boot-stack bound holds.
#   ⚠ WHERE AN AP STACK ACTUALLY IS is not this gate's business and cannot be: a static grep of the
#   trampoline's hex would be brittle. The runtime guard is SMP_STACK_SELFTEST — scripts/smoke/
#   ap-stack-smoke.sh (-smp 4) samples each AP's live RSP against the region-7 window, reads each AP's
#   TSS.RSP0 back against the exact window top (the gdt.cyr half — dead until a ring-3 proc lands there,
#   so nothing else can see it regress), and re-hashes the chunk literals in place after the wake.
#   Together: the image stays under the BSP stack, and the APs stay out of the image.
#
# WHO RUNS IT: check.sh gate 34 on the plain build; ⭐ 1.57.7 scripts/build.sh after EVERY x86_64 build —
# a build that set any flag FAILS (image moved to build/agnos.layout-refused; also when python3 is missing, since
# an unmeasured flag image must not be booted), a plain build WARNS on stderr and keeps the image so gate 34 can
# score it; bench.sh on its rewritten-source bench kernel; and (IMG-fix, review A5) CI — ci.yml and release.yml
# run it right after their plain build, because CI never runs check.sh and the release artifact is plain.
#
# ⚠ VACUITY: the caller must hand this the binary THIS run built (check.sh gates it behind the arity
# build's rc exactly as the size gate is). A fossil build/agnos measures a different tree.
# Mutation record:
#   1.57.3 (on a scratch copy of the plain build): p_memsz bumped so the LOAD end lands at 0x370001 ->
#   "FAIL: LOAD end 0x370001 exceeds 0x370000 ..."; the shipped tree PASSED with LOAD end 0x35E8B0.
#   1.57.7 (IMG, 2026-09-24; each RED, then restored GREEN on the md5-identical file):
#   M1 plain image forced past the bound (a temporary `var pad[30000]`, +240,000 B) -> check.sh gate 34
#      "FAIL: LOAD end 0x39c220 exceeds 0x390000 ..." (the size gate and test.sh trip too);
#   M2 the same pad under `#ifdef FORK_SELFTEST` -> `FORK_SELFTEST=1 sh scripts/build.sh` exits 1 with
#      "FAIL: LOAD end 0x39c598 exceeds 0x390000". ⚠ That first RED ran an EARLIER build.sh (it moved the image
#      to build/agnos.over-bound); the guard was renamed afterwards. RE-RUN on the build.sh that ships (IMG-fix,
#      handoff logs/IMG-fix/M2-red-build-final.log): rc=1, "FAIL: LOAD end 0x39ccc8 exceeds 0x390000", `ls`
#      shows build/agnos ABSENT and build/agnos.layout-refused PRESENT; GREEN restored (M2-green-build-final.log);
#   M3a the legacy `mov esp` reverted to 0x380000 (bytes + comment) -> "FAIL: boot_shim.cyr:58 `mov esp,
#      0x380000` disagrees with BSP_BOOT_TOP" while the ELF64 image stays byte-identical — only (2) sees it;
#   M3b the ELF64 `mov rsp` reverted -> (2) plus both (3) lines (the image is then byte-identical to the
#      1.57.6-layout build: rsp = 0x380000 @0x22230f), and a TCP_SELFTEST flag build is refused;
#   M3d a comment-only drift (`# mov rsp, 0x380000` over 0x3A bytes) -> the comment-vs-bytes FAIL.
#   The 1.57.6-layout plain binary run through this gate FAILs (3) twice. Shipped by IMG: LOAD end 0x361898,
#   headroom 0x2E768 = 190,312 B.
#   1.57.7 IMG-fix: A4 proc.cyr's proc_rsp0_top fallback set to 0x3A0000 -> "(4) FAIL: proc.cyr proc_rsp0_top
#      fallback is 0x3a0000 ..." (the IMG-era gate PASSED it); A3 mbi.cyr bsw_lo/bsw_hi pointed at the kernel
#      image -> (4) FAILs both, and at boot the kernel prints the denied "not free RAM ... type 0x1 at 0x100000";
#      A5 the M1 pad on a PLAIN build -> build.sh prints the FAIL block + "WARNING: this PLAIN image fails ..." and
#      leaves the image; B4 a flag build with no python3 on PATH -> refused (the IMG-era guard exited 0 unmeasured).
#   Shipped by IMG-fix (the runtime span check adds 1,856 B): LOAD end 0x361fd8, headroom 0x2E028 = 188,456 B.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGNOS="${1:-$ROOT/build/agnos}"
SHIM="$ROOT/kernel/arch/x86_64/boot_shim.cyr"
KDIR="$ROOT/kernel"

[ -f "$AGNOS" ] || { echo "FAIL: $AGNOS not found — no image to measure"; exit 1; }
[ -f "$SHIM" ] || { echo "FAIL: $SHIM not found — the boot-stack immediates cannot be checked"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available — the ELF cannot be parsed"; exit 1; }

python3 - "$AGNOS" "$SHIM" "$KDIR" <<'EOF'
import re, struct, sys
agnos, shim, kdir = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(agnos, 'rb').read()
BSP_BOOT_TOP = 0x3A0000                 # boot_shim.cyr legacy steps 1 + 12, ELF64 step 1 (grows down); 0x380000 until 1.57.7
CEIL = BSP_BOOT_TOP - 0x10000           # 0x390000: the BSP boot stack keeps the per-CPU 64 KB budget
BSP_RSP0_TOP = 0x3C0000                 # gdt.cyr tss_kernel_stack; window [0x3B0000, 0x3C0000)
RSP0_BOT = BSP_RSP0_TOP - 0x10000
# The constants themselves must describe a legal layout: the stack in region 1, not inside the RSP0 window.
assert 0x200000 < CEIL < BSP_BOOT_TOP <= RSP0_BOT < BSP_RSP0_TOP <= 0x400000, "image-layout-check: constants inconsistent"
fails = []
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
# section spans, for the report (and .text for check 3)
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
print("  region-1 stacks: BSP boot top 0x%x (ceiling 0x%x = top - 64 KB)  guard gap [0x%x, 0x%x)  BSP TSS.RSP0 window [0x%x, 0x%x)  AP1-3: region 7 (ap-stack-smoke.sh)" % (BSP_BOOT_TOP, CEIL, BSP_BOOT_TOP, RSP0_BOT, RSP0_BOT, BSP_RSP0_TOP))

# (2) boot_shim.cyr: decode the boot-stack immediates from their bytes.
found = []   # (line, kind, value)
for ln, raw in enumerate(open(shim, encoding='utf-8'), 1):
    code, _, comment = raw.partition('#')
    toks = [t.strip() for t in code.split(';') if t.strip()]
    if not toks or not all(re.fullmatch(r'0x[0-9A-Fa-f]{1,2}', t) for t in toks):
        continue
    b = [int(t, 16) for t in toks]
    kind = None
    if len(b) == 5 and b[0] == 0xBC:
        kind, val = 'mov esp', b[1] | b[2] << 8 | b[3] << 16 | b[4] << 24
    elif len(b) == 10 and b[0] == 0x48 and b[1] == 0xBC:
        kind, val = 'mov rsp', int.from_bytes(bytes(b[2:10]), 'little')
    elif b[0] == 0xBC or (b[0] == 0x48 and len(b) > 1 and b[1] == 0xBC):
        fails.append("FAIL: boot_shim.cyr:%d carries a 0xBC (mov esp/rsp, imm) in a shape this gate cannot decode: %s — keep each stack load on its own line" % (ln, code.strip()))
        continue
    if kind is None:
        continue
    found.append((ln, kind, val))
    m = re.search(r'mov\s+[er]sp,\s*(0x[0-9A-Fa-f]+)', comment)
    if not m or int(m.group(1), 16) != val:
        fails.append("FAIL: boot_shim.cyr:%d `%s` bytes load 0x%x but its comment says %r — fix the comment or the bytes" % (ln, kind, val, comment.strip()))
kinds = [k for _, k, _ in found]
print("  boot_shim.cyr immediates: " + ", ".join("%s 0x%x (:%d)" % (k, v, l) for l, k, v in found))
if kinds.count('mov esp') != 1 or kinds.count('mov rsp') != 2:
    fails.append("FAIL: boot_shim.cyr: expected 3 boot-stack immediates (legacy `mov esp` step 1, legacy `mov rsp` step 12, ELF64 `mov rsp` step 1), found %d mov esp + %d mov rsp — teach this gate the new shape rather than dropping the check" % (kinds.count('mov esp'), kinds.count('mov rsp')))
for l, k, v in found:
    if v != BSP_BOOT_TOP:
        fails.append("FAIL: boot_shim.cyr:%d `%s, 0x%x` disagrees with BSP_BOOT_TOP 0x%x — the bound this gate enforces (0x%x) assumes that top; move all three immediates AND BSP_BOOT_TOP together" % (l, k, v, BSP_BOOT_TOP, CEIL))

# (3) the built image: `mov rsp, imm64` in .text.
if '.text' in secs:
    ta, ts = secs['.text']
    lo, hi = ta - p_vaddr, ta - p_vaddr + ts
else:
    lo, hi = 0, p_filesz
hits = []
i = d.find(b'\x48\xbc', lo, hi)
while i >= 0:
    if i + 10 <= len(d):
        v = struct.unpack_from('<Q', d, i + 2)[0]
        if 0x200000 <= v <= 0x400000 and v % 0x10000 == 0:
            hits.append((i + p_vaddr, v))
    i = d.find(b'\x48\xbc', i + 1, hi)
print("  image `mov rsp, imm64` to region 1: " + (", ".join("0x%x @0x%x" % (v, a) for a, v in hits) or "none"))
if not any(v == BSP_BOOT_TOP for _, v in hits):
    fails.append("FAIL: the image's .text has no `mov rsp, 0x%x` (48 BC imm64) — the ELF64 shim's boot stack is not the top this gate's bound assumes (a stale build, or boot_shim.cyr's ELF64 step 1 changed)" % BSP_BOOT_TOP)
for a, v in hits:
    if v != BSP_BOOT_TOP:
        fails.append("FAIL: the image loads rsp = 0x%x at 0x%x — a region-1 stack top other than BSP_BOOT_TOP 0x%x" % (v, a, BSP_BOOT_TOP))

# (4) (1.57.7 IMG-fix, review A4) the OTHER half of the region-1 map this gate prints: every BSP TSS.RSP0 site in
# the tree must equal BSP_RSP0_TOP (so the RSP0 window sits above the guard gap and can never overlap kmain's
# boot-stack frames — a CPL3->CPL0 entry through the fallback RSP0 would land on them), and the kernel's own
# runtime check of the span (mbi.cyr bootstack_window_check + its main.cyr OK line) must name the same span.
def body_of(path, fn):
    src = open(path, encoding='utf-8').read()
    m = re.search(r'^fn ' + re.escape(fn) + r'\(.*?^\}', src, re.S | re.M)
    return src, (m.group(0) if m else None)
def lit(path, text, pat, what):
    ms = re.findall(pat, text or '')
    if len(ms) != 1:
        fails.append("FAIL: %s: expected exactly one %s, found %d — teach this gate the new shape rather than dropping the check" % (path, what, len(ms)))
        return None
    return int(ms[0], 16)
gdt = kdir + '/arch/x86_64/gdt.cyr'; proc = kdir + '/core/proc.cyr'; mbi = kdir + '/arch/x86_64/mbi.cyr'; kmain = kdir + '/core/main.cyr'
gsrc, gfn = body_of(gdt, 'tss_get_cpu_stack')
_, pfn = body_of(proc, 'proc_rsp0_top')
_, bfn = body_of(mbi, 'bootstack_window_check')
msrc = open(kmain, encoding='utf-8').read()
sites = [
    ('gdt.cyr `var tss_kernel_stack`', lit(gdt, gsrc, r'(?m)^var tss_kernel_stack = (0x[0-9A-Fa-f]+);', '`var tss_kernel_stack = 0x...;`'), BSP_RSP0_TOP),
    ('gdt.cyr tss_get_cpu_stack(0)', lit(gdt, gfn, r'cpu_id == 0\) \{ return (0x[0-9A-Fa-f]+);', 'BSP return in tss_get_cpu_stack'), BSP_RSP0_TOP),
    ('proc.cyr proc_rsp0_top fallback', lit(proc, pfn, r'if \(r == 0\) \{ return (0x[0-9A-Fa-f]+);', 'unassigned-slot fallback in proc_rsp0_top'), BSP_RSP0_TOP),
    ('mbi.cyr bootstack_window_check bsw_lo', lit(mbi, bfn, r'var bsw_lo = (0x[0-9A-Fa-f]+);', '`var bsw_lo = 0x...;`'), CEIL),
    ('mbi.cyr bootstack_window_check bsw_hi', lit(mbi, bfn, r'var bsw_hi = (0x[0-9A-Fa-f]+);', '`var bsw_hi = 0x...;`'), BSP_RSP0_TOP),
]
mm = re.findall(r'boot: BSP stack span (0x[0-9A-Fa-f]+)-(0x[0-9A-Fa-f]+) is free RAM', msrc)
if len(mm) != 1:
    fails.append("FAIL: main.cyr: expected exactly one 'boot: BSP stack span 0x...-0x... is free RAM' line, found %d" % len(mm))
else:
    sites.append(('main.cyr OK line (span bottom)', int(mm[0][0], 16), CEIL))
    sites.append(('main.cyr OK line (span top)', int(mm[0][1], 16), BSP_RSP0_TOP))
print("  RSP0 / span sites: " + ", ".join("%s 0x%x" % (n, v) for n, v, _ in sites if v is not None))
for n, v, want in sites:
    if v is not None and v != want:
        fails.append("FAIL: %s is 0x%x but this gate's map needs 0x%x — the region-1 map (boot stack [0x%x, 0x%x), guard gap, RSP0 window [0x%x, 0x%x)) no longer describes the tree; move the site, or move the map (BSP_BOOT_TOP / BSP_RSP0_TOP) and every site with it" % (n, v, want, CEIL, BSP_BOOT_TOP, RSP0_BOT, BSP_RSP0_TOP))

# (1) the bound.
if end > CEIL:
    fails.append("FAIL: LOAD end 0x%x exceeds 0x%x — the BSP boot stack (top 0x%x) would have under 64 KB before it walks into the image. Shrink or move the image; do not raise the ceiling without moving the stack (the BSP boot stack is live from the shim's first instruction, before the direct map exists, so it cannot leave region 1 — see the header)." % (end, CEIL, BSP_BOOT_TOP))
if fails:
    for f in fails:
        print(f)
    sys.exit(1)
print("  PASS: LOAD end 0x%x <= 0x%x — headroom to the BSP boot stack's 64 KB budget 0x%x = %d B; boot-stack immediates agree (0x%x); BSP TSS.RSP0 window bottom 0x%x is %d B further up (64 KB of it an unused guard gap)" % (end, CEIL, CEIL - end, CEIL - end, BSP_BOOT_TOP, RSP0_BOT, RSP0_BOT - CEIL))
sys.exit(0)
EOF
